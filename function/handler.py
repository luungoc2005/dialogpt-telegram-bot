import os
try:
    import unzip_requirements
except ImportError:
    pass

import torch
import requests
from requests.adapters import HTTPAdapter
from requests.packages.urllib3.util.retry import Retry
from transformers import AutoModelForCausalLM, AutoTokenizer, AutoModelForSequenceClassification
import urllib.parse
import json
import logging
import random
import time
import boto3
from boto3.dynamodb.conditions import Key
from decimal import Decimal

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize boto3 client at global scope for connection reuse
# client = boto3.client('ssm')

api_token = os.getenv('TELEGRAM_API_KEY')
giphy_api_key = os.getenv('GIPHY_API_KEY')
giphy_weirdness = int(os.getenv('giphy_weirdness', 5))
model_name = 'microsoft/DialoGPT-medium'
history_max_length = 1000 - 256 # assuming query + response = 128 max
history_turns = 0
# 0: prior, 1: ranker
ranker_models = [
    ('microsoft/DialogRPT-human-vs-rand', .5, 0),
    # ('microsoft/DialogRPT-human-vs-machine', .5, 0),
    # ('microsoft/DialogRPT-updown', 1, 1),
    # ('microsoft/DialogRPT-depth', 0.48, 1),
    # ('microsoft/DialogRPT-width', -0.5, 1),
]

dynamodb = boto3.resource('dynamodb')


# tag = model or tokenizer
def save_load_pretrained(model_class, model_name, tag='model'):
    model_file_name = f'model_cache_{model_name.replace("/", "_")}/'
    model_path = os.path.join(os.getenv('MNT_DIR'), model_file_name)
    if os.path.isdir(model_path):
        if len(os.listdir(model_path)) > 0:
            logger.info('Loading cached model')
            return model_class.from_pretrained(model_path)
        else:
            os.rmdir(model_path)

    cache_dir = os.path.join(os.path.join(os.getenv('MNT_DIR'), 'models_cache/'))
    if not os.path.isdir(cache_dir):
        os.makedirs(cache_dir)

    ret = model_class.from_pretrained(model_name, cache_dir=cache_dir)
    ret.save_pretrained(model_path)

    # remove the cache
    import shutil
    shutil.rmtree(cache_dir, ignore_errors=True)

    return ret


tokenizer = save_load_pretrained(AutoTokenizer, model_name, tag='tokenizer')
model = save_load_pretrained(AutoModelForCausalLM, model_name, tag='model')

rankers = [
    (save_load_pretrained(AutoModelForSequenceClassification, item, tag='model'), weight, ranker_type)
    for (item, weight, ranker_type) in ranker_models
]


def send_typing(chat_id):
    URL = "https://api.telegram.org/bot{}/".format(api_token)
    url = URL + "sendChatAction?action=typing&chat_id={}".format(chat_id)
    r = requests.get(url)
    logger.info(r.text)


def send_message(text, chat_id):
    logger.info(text)
    URL = "https://api.telegram.org/bot{}/".format(api_token)
    text = urllib.parse.quote(text)
    url = URL + "sendMessage?text={}&chat_id={}".format(text, chat_id)
    r = requests.get(url)
    logger.info(r.text)


def send_gif(gif_url, chat_id):
    logger.info(gif_url)
    URL = "https://api.telegram.org/bot{}/".format(api_token)
    gif_url = urllib.parse.quote(gif_url)
    url = URL + "sendDocument?document={}&chat_id={}".format(gif_url, chat_id)
    r = requests.get(url)
    logger.info(r.text)


def translate_message_to_gif(message):
    from urllib.parse import urlencode

    retry_strategy = Retry(
        total=3,
        status_forcelist=[429, 500, 502, 503, 504],
        method_whitelist=["HEAD", "GET", "OPTIONS"],
        backoff_factor=.3
    )
    adapter = HTTPAdapter(max_retries=retry_strategy)
    session = requests.Session()
    session.mount('http://', adapter)
    session.mount('https://', adapter)

    params = {
        'api_key': giphy_api_key,
        's': message,
        'weirdness': giphy_weirdness
    }
    url = "http://api.giphy.com/v1/gifs/translate?" + urlencode(params)
    response = session.get(url)
    return response.json()['data']['images']['fixed_height']['url']


def predict(question):
    logger.info(f"Predicting query: {question}")
    new_user_input_ids = tokenizer.encode(question + tokenizer.eos_token, return_tensors='pt')

    # generated a response while limiting the total chat history to 1000 tokens, 
    num_return_sequences=8
    chat_history_ids = model.generate(
        new_user_input_ids, max_length=1000, 
        pad_token_id=tokenizer.eos_token_id,
        top_k=100, top_p=0.7, temperature=0.7, repetition_penalty=1, 
        no_repeat_ngram_size=3,
        num_beams=num_return_sequences,
        num_return_sequences=num_return_sequences)

    responses = chat_history_ids[:, new_user_input_ids.shape[-1]:]

    # log the candidates
    logger.info('Candidates:')
    for response in responses:
        logger.info(tokenizer.decode(response, skip_special_tokens=True))

    # rank the responses
    if num_return_sequences > 1:
        max_idx = 0
        with torch.no_grad():
            prior_results = torch.zeros((num_return_sequences,))
            cond_results = torch.zeros((num_return_sequences,))
            has_prior = False
            has_cond = False
            for (ranker, weight, ranker_type) in rankers:
                ranker_results = ranker(chat_history_ids, return_dict=True)
                ranker_results = torch.sigmoid(ranker_results.logits)[0]
                logger.info(ranker_results)
                if ranker_type == 1:
                    prior_results += weight * ranker_results
                    has_prior = True
                else:
                    cond_results += weight * cond_results
                    has_cond = True

            total_results = None
            if has_cond and has_prior:
                total_results = prior_results * cond_results
            elif has_cond:
                total_results = cond_results
            else:
                total_results = prior_results

            max_idx = int(torch.argmax(total_results))
        responses = [responses[max_idx]]

    # pretty print last ouput tokens from bot
    response = tokenizer.decode(responses[0], skip_special_tokens=True)
    return response


def handle_record(message):
    table = dynamodb.Table('telegram-chat-history')
    
    update_id = message['update_id']
    chat_id = message['message']['chat']['id']
    message_text = message['message']['text'].strip()


    # fetch history text
    history_texts = ""
    if history_turns > 0:
        response = table.query(
            KeyConditionExpression=Key('chat_id').eq(chat_id),
            Limit=history_turns * 2,
            ScanIndexForward=False, # descending
        )
        logger.info(str(response['Items']))

        history_texts = [item.get('message', '') for item in response['Items']]

        if len(history_texts) > 0:
            history_texts = history_texts[::-1] # reverse the list to chronological order
            history_texts = str(tokenizer.eos_token).join(history_texts)
            history_texts += tokenizer.eos_token
            history_texts = history_texts[-history_max_length:]

    table.put_item(Item={
        "update_id": update_id,
        "chat_id": chat_id,
        "message": message_text,
        "from": 0,
        "gif_url": "",
        "timestamp": Decimal(time.time())
    })

    return_gif = (random.uniform(0, 1) < .1)
    if '@gif' in message_text:
        # Return gif
        return_gif = True
        message_text = message_text.replace('@gif', '').strip()

    send_typing(chat_id)
    reply = predict(history_texts + message_text)
    send_message(reply, chat_id)

    gif_url = ""
    if return_gif:
        try:
            gif_url = translate_message_to_gif(reply)
            send_gif(gif_url, chat_id)
        except:
            pass

    table.put_item(Item={
        "update_id": update_id,
        "chat_id": chat_id,
        "message": reply,
        "from": 1,
        "gif_url": gif_url,
        "timestamp": Decimal(time.time())
    })



def lambda_handler(event, context):
    for record in event['Records']:
        logger.info(str(record))
        logger.info(record["body"])
        body = json.loads(record["body"])
        handle_record(body['body-json'])

    # message = json.loads(event['body'])

    # return {
    #     "statusCode": 200,
    # }

    # Use this code if you don't use the http event with the LAMBDA-PROXY
    # integration
    """
    return {
        "message": "Go Serverless v1.0! Your function executed successfully!",
        "event": event
    }
    """
