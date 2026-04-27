import json
import boto3
import urllib.request
import time
import os

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ.get("TABLE_NAME", "image-metadata"))

def lambda_handler(event, context):
    try:
        # Call external API
        with urllib.request.urlopen("https://jsonplaceholder.typicode.com/photos?_limit=1") as response:
            data = json.loads(response.read().decode())

        image = data[0]

        image_name = str(image["id"]) + ".jpg"
        image_url = "https://picsum.photos/200"
        # Store in DynamoDB
        table.put_item(
            Item={
                "image_name": image_name,
                "image_url": image_url,
                "timestamp": int(time.time())
            }
        )

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "Image stored successfully",
                "image_name": image_name
            })
        }

    except Exception as e:
        return {
            "statusCode": 500,
            "body": str(e)
        }