from transformers import AutoModelForCausalLM, AutoTokenizer, AutoModelForSequenceClassification
import torch

# Initialize boto3 client at global scope for connection reuse
tokenizer = AutoTokenizer.from_pretrained("microsoft/DialoGPT-medium")
model = AutoModelForCausalLM.from_pretrained("microsoft/DialoGPT-medium")

ranker = AutoModelForSequenceClassification.from_pretrained('microsoft/DialogRPT-human-vs-machine')
# ranker = AutoModelForSequenceClassification.from_pretrained('microsoft/DialogRPT-updown')

# Let's chat for 5 lines
for step in range(5):
    # encode the new user input, add the eos_token and return a tensor in Pytorch
    new_user_input_ids = tokenizer.encode(input(">> User:") + tokenizer.eos_token, return_tensors='pt')

    # generated a response while limiting the total chat history to 1000 tokens, 
    chat_history_ids = model.generate(
        new_user_input_ids, max_length=1000, 
        pad_token_id=tokenizer.eos_token_id,
        top_k=80, top_p=0.9, temperature=1, repetition_penalty=.6, 
        num_beams=4, num_beam_groups=1,
        num_return_sequences=4,
        early_stopping=True)

    with torch.no_grad():
        ranker_results = ranker(chat_history_ids, return_dict=True)
        ranker_results = torch.sigmoid(ranker_results.logits)[0] 
        print(ranker_results)

    # pretty print last ouput tokens from bot
    responses = chat_history_ids[:, new_user_input_ids.shape[-1]:]
    responses = [responses[int(torch.argmax(ranker_results))]]
    for it in responses:
        response = tokenizer.decode(it, skip_special_tokens=True)
        print("DialoGPT: {}".format(str(response))) 
