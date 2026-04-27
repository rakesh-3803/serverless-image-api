import json
import boto3
import os
from decimal import Decimal

dynamodb = boto3.resource('dynamodb')
s3 = boto3.client('s3')

TABLE_NAME = os.environ.get("TABLE_NAME")
BUCKET = os.environ.get("BUCKET_NAME")

table = dynamodb.Table(TABLE_NAME)

def convert_decimal(obj):
    if isinstance(obj, Decimal):
        return int(obj)
    raise TypeError

def lambda_handler(event, context):
    try:
        print("EVENT:", event)

        params = event.get('queryStringParameters') or {}
        image_name = params.get('image_name')

        if not image_name:
            return {
                "statusCode": 400,
                "body": "Missing image_name"
            }

        response = table.get_item(
            Key={"image_name": image_name}
        )

        item = response.get("Item")

        if not item:
            return {
                "statusCode": 404,
                "body": "Image not found"
            }

        if not BUCKET:
            return {
                "statusCode": 500,
                "body": "BUCKET_NAME not set"
            }

        url = s3.generate_presigned_url(
            "get_object",
            Params={
                "Bucket": BUCKET,
                "Key": image_name
            },
            ExpiresIn=3600
        )

        return {
            "statusCode": 200,
            "body": json.dumps({
                "image_url": url,
                "timestamp": item.get("timestamp")
            }, default=convert_decimal)
        }

    except Exception as e:
        print("ERROR:", str(e))
        return {
            "statusCode": 500,
            "body": str(e)
        }