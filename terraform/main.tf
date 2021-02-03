# provider
provider "aws" {
  region                  = "ap-southeast-1"
  shared_credentials_file = "~/.aws/credentials"
  profile                 = "telegram-test-bot"
}

data "aws_region" "current" {}

# get all available availability zones

data "aws_vpc" "default" {
  cidr_block           = var.cidr_block
}

resource "aws_internet_gateway" "default" {
  vpc_id = data.aws_vpc.default.id
}

resource "aws_route_table" "private" {
  count = length(var.private_subnet_cidr_blocks)

  vpc_id = data.aws_vpc.default.id
}

resource "aws_route" "private" {
  count = length(var.private_subnet_cidr_blocks)

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.default[count.index].id
}

resource "aws_route_table" "public" {
  vpc_id = data.aws_vpc.default.id
}

resource "aws_route" "public" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.default.id
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidr_blocks)

  vpc_id                  = data.aws_vpc.default.id
  cidr_block              = var.public_subnet_cidr_blocks[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
}


resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidr_blocks)

  vpc_id            = data.aws_vpc.default.id
  cidr_block        = var.private_subnet_cidr_blocks[count.index]
  availability_zone = var.availability_zones[count.index]
}

resource "aws_route_table_association" "private" {
  count = length(var.private_subnet_cidr_blocks)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "public" {
  count = length(var.public_subnet_cidr_blocks)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# NAT
resource "aws_eip" "nat" {
  count = length(var.public_subnet_cidr_blocks)

  vpc = true
}


resource "aws_nat_gateway" "default" {
  depends_on = [aws_internet_gateway.default]

  count = length(var.public_subnet_cidr_blocks)

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
}

# EFS File System

resource "aws_efs_file_system" "efs" {
  creation_token = "telegram-test-bot"
}

# Access Point

resource "aws_efs_access_point" "access_point" {
  file_system_id = aws_efs_file_system.efs.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/lambda"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "0777"
    }
  }
}

# Mount Targets

resource "aws_efs_mount_target" "efs_targets" {
  count = length(var.private_subnet_cidr_blocks)
  subnet_id      = aws_subnet.private[count.index].id
  file_system_id = aws_efs_file_system.efs.id
}

#
# SQS
#
resource "aws_sqs_queue" "telegram_bot_queue" {
  name                       = "telegram_bot_queue"
  delay_seconds              = 0
  max_message_size           = 262144
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 10
  visibility_timeout_seconds = 900
}

#
# SSM Parameter for serverless
#

resource "aws_ssm_parameter" "efs_access_point" {
  name      = "/efs/accessPoint/id"
  type      = "String"
  value     = aws_efs_access_point.access_point.id
  overwrite = true
}

resource "aws_ssm_parameter" "sqs_queue_arn" {
  name      = "/sqs/arn"
  type      = "String"
  value     = aws_sqs_queue.telegram_bot_queue.arn
  overwrite = true
}

#
# API Gateway
#

resource "aws_iam_role" "apiSQS" {
  name = "apigateway_sqs"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "apigateway.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

data "template_file" "gateway_policy" {
  template = file("policies/api-gateway-permission.json")

  vars = {
    sqs_arn   = aws_sqs_queue.telegram_bot_queue.arn
  }
}

resource "aws_iam_policy" "api_policy" {
  name = "api-sqs-cloudwatch-policy"

  policy = data.template_file.gateway_policy.rendered
}


resource "aws_iam_role_policy_attachment" "api_exec_role" {
  role       =  aws_iam_role.apiSQS.name
  policy_arn =  aws_iam_policy.api_policy.arn
}
resource "aws_api_gateway_rest_api" "apiGateway" {
  name        = "api-gateway-sqs-telegram-bot"
  description = "POST records to SQS queue"
}

resource "aws_api_gateway_resource" "get_reply" {
    rest_api_id = aws_api_gateway_rest_api.apiGateway.id
    parent_id   = aws_api_gateway_rest_api.apiGateway.root_resource_id
    path_part   = "get-reply"
}

resource "aws_api_gateway_method" "method_get_reply" {
  rest_api_id   = aws_api_gateway_rest_api.apiGateway.id
  resource_id   = aws_api_gateway_resource.get_reply.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "api" {
  rest_api_id             = aws_api_gateway_rest_api.apiGateway.id
  resource_id             = aws_api_gateway_resource.get_reply.id
  http_method             = aws_api_gateway_method.method_get_reply.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  credentials             = aws_iam_role.apiSQS.arn
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:sqs:path/${aws_sqs_queue.telegram_bot_queue.name}"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  # Request Template for passing Method, Body, QueryParameters and PathParams to SQS messages
  request_templates = {
    "application/json" = <<EOF
Action=SendMessage&MessageBody={
  "method": "$context.httpMethod",
  "body-json" : $input.json('$'),
  "queryParams": {
    #foreach($param in $input.params().querystring.keySet())
    "$param": "$util.escapeJavaScript($input.params().querystring.get($param))" #if($foreach.hasNext),#end
  #end
  },
  "pathParams": {
    #foreach($param in $input.params().path.keySet())
    "$param": "$util.escapeJavaScript($input.params().path.get($param))" #if($foreach.hasNext),#end
    #end
  }
}
EOF
  }

  depends_on = [
    aws_iam_role_policy_attachment.api_exec_role
  ]
}

# Mapping SQS Response
resource "aws_api_gateway_method_response" "http200" {
 rest_api_id = aws_api_gateway_rest_api.apiGateway.id
 resource_id = aws_api_gateway_resource.get_reply.id
 http_method = aws_api_gateway_method.method_get_reply.http_method
 status_code = 200
}

resource "aws_api_gateway_integration_response" "http200" {
 rest_api_id       = aws_api_gateway_rest_api.apiGateway.id
 resource_id       = aws_api_gateway_resource.get_reply.id
 http_method       = aws_api_gateway_method.method_get_reply.http_method
 status_code       = aws_api_gateway_method_response.http200.status_code
 selection_pattern = "^2[0-9][0-9]"                                       // regex pattern for any 200 message that comes back from SQS

 depends_on = [
   aws_api_gateway_integration.api
   ]
}

resource "aws_api_gateway_deployment" "api" {
 rest_api_id = aws_api_gateway_rest_api.apiGateway.id

 stage_name  = var.environment

 depends_on = [
   aws_api_gateway_integration.api,
 ]

 # Redeploy when there are new updates
 triggers = {
   redeployment = sha1(join(",", list(
     jsonencode(aws_api_gateway_integration.api),
   )))
 }

 lifecycle {
   create_before_destroy = true
 }
}

#
# DynamoDB
#
resource "aws_dynamodb_table" "table" {
  name              = "telegram-chat-history"
  billing_mode      = "PAY_PER_REQUEST"
  hash_key          = "chat_id"
  range_key         = "timestamp"

  # attribute {
  #   name = "update_id"
  #   type = "S"
  # }

  # attribute {
  #   name = "from"
  #   type = "B"
  # }

  # attribute {
  #   name = "message"
  #   type = "S" 
  # }

  attribute {
    name = "timestamp"
    type = "N"
  }

  attribute {
    name = "chat_id"
    type = "N" 
  }
}