import boto3
import os
import urllib.request

s3 = boto3.client('s3')
BUCKET = os.environ.get("BUCKET_NAME")

def lambda_handler(event, context):

    print("EVENT:", event)

    for record in event['Records']:

        if record['eventName'] in ['INSERT', 'MODIFY']:

            new_image = record['dynamodb']['NewImage']

            image_name = new_image['image_name']['S']
            image_url = new_image['image_url']['S']

            try:
                with urllib.request.urlopen(image_url) as response:
                    image_data = response.read()

                s3.put_object(
                    Bucket=BUCKET,
                    Key=image_name,
                    Body=image_data,
                    ContentType='image/jpeg'
                )

                print("UPLOADED:", image_name)

            except Exception as e:
                print("ERROR:", str(e))

    return {"statusCode": 200}