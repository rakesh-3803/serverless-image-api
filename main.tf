provider "aws" {
  region = "us-east-1"
}

############################
# RANDOM SUFFIX
############################
resource "random_id" "suffix" {
  byte_length = 4
}

############################
# S3 BUCKET
############################
resource "aws_s3_bucket" "image_bucket" {
  bucket = "image-bucket-${random_id.suffix.hex}"
}

############################
# DYNAMODB TABLE
############################
resource "aws_dynamodb_table" "image_table" {
  name         = "image-metadata"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "image_name"

  attribute {
    name = "image_name"
    type = "S"
  }

  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  timeouts {
    create = "5m"
  }
}

############################
# IAM ROLE
############################
resource "aws_iam_role" "lambda_role" {
  name = "image_lambda_role_${random_id.suffix.hex}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

############################
# BASIC PERMISSION
############################
resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

############################
# FULL ACCESS POLICY
############################
resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:*",
          "s3:*"
        ]
        Resource = "*"
      }
    ]
  })
}

############################
# LAMBDA 1 - INGESTION
############################
resource "aws_lambda_function" "ingestion_lambda" {
  function_name = "image_ingestion"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.11"
  handler       = "lambda.lambda_handler"

  filename         = "ingestion.zip"
  source_code_hash = filebase64sha256("ingestion.zip")

  timeout = 30

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.image_table.name
    }
  }
}

############################
# LAMBDA 2 - STREAM PROCESSOR
############################
resource "aws_lambda_function" "stream_lambda" {
  function_name = "image_stream_processor"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.11"
  handler       = "lambda.lambda_handler"

  filename         = "stream.zip"
  source_code_hash = filebase64sha256("stream.zip")

  timeout = 30

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.image_bucket.bucket
    }
  }
}

############################
# LAMBDA 3 - RETRIEVAL
############################
resource "aws_lambda_function" "retrieval_lambda" {
  function_name = "image_retrieval"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.11"
  handler       = "lambda.lambda_handler"

  filename         = "retrieval.zip"
  source_code_hash = filebase64sha256("retrieval.zip")

  timeout = 30

  environment {
    variables = {
      TABLE_NAME  = aws_dynamodb_table.image_table.name
      BUCKET_NAME = aws_s3_bucket.image_bucket.bucket
    }
  }
}

############################
# DYNAMODB STREAM TRIGGER
############################
resource "aws_lambda_event_source_mapping" "ddb_stream" {
  event_source_arn  = aws_dynamodb_table.image_table.stream_arn
  function_name     = aws_lambda_function.stream_lambda.arn
  starting_position = "LATEST"

  depends_on = [
    aws_dynamodb_table.image_table,
    aws_lambda_function.stream_lambda
  ]
}

############################
# API GATEWAY
############################
resource "aws_api_gateway_rest_api" "api" {
  name = "image-serverless-api"
}

############################
# /image_url (POST)
############################
resource "aws_api_gateway_resource" "image_url" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "image_url"
}

resource "aws_api_gateway_method" "post_image" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.image_url.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "ingestion_integration" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.image_url.id
  http_method = aws_api_gateway_method.post_image.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.ingestion_lambda.invoke_arn
}

############################
# /get-image (GET)
############################
resource "aws_api_gateway_resource" "get_image" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "get-image"
}

resource "aws_api_gateway_method" "get_image" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.get_image.id
  http_method   = "GET"
  authorization = "NONE"

  request_parameters = {
    "method.request.querystring.image_name" = true
  }
}

resource "aws_api_gateway_integration" "retrieval_integration" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.get_image.id
  http_method = aws_api_gateway_method.get_image.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.retrieval_lambda.invoke_arn
}

############################
# DEPLOYMENT
############################
resource "aws_api_gateway_deployment" "deploy" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  depends_on = [
    aws_api_gateway_integration.ingestion_integration,
    aws_api_gateway_integration.retrieval_integration
  ]
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.deploy.id
  stage_name    = "prod"
}

############################
# PERMISSIONS
############################
resource "aws_lambda_permission" "apigw_ingestion" {
  statement_id  = "AllowAPIGWInvoke1"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingestion_lambda.function_name
  principal     = "apigateway.amazonaws.com"
}

resource "aws_lambda_permission" "apigw_retrieval" {
  statement_id  = "AllowAPIGWInvoke2"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.retrieval_lambda.function_name
  principal     = "apigateway.amazonaws.com"
}