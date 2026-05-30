import json
import os
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import boto3


def make_s3_client():
    endpoint_url = os.environ.get("AWS_ENDPOINT_URL")
    return boto3.client("s3", endpoint_url=endpoint_url) if endpoint_url else boto3.client("s3")


s3 = make_s3_client()


def http_get_bytes(url: str):
    request = urllib.request.Request(url, headers={"User-Agent": "bronze-x-collector/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def safe_filename_from_url(url: str, default_name: str):
    parsed = urllib.parse.urlparse(url)
    filename = os.path.basename(parsed.path)
    return filename or default_name


def put_raw_object(bucket: str, key: str, payload: bytes, content_type: str | None = None):
    kwargs = {
        "Bucket": bucket,
        "Key": key,
        "Body": payload,
    }
    if content_type:
        kwargs["ContentType"] = content_type
    s3.put_object(**kwargs)


def generated_raw_dataset():
    now = datetime.now(timezone.utc).isoformat()
    return [
        {
            "id": "x-gen-001",
            "created_at": now,
            "author_id": "sample-user-01",
            "text": "Generated raw social post for Bronze bootstrap",
            "lang": "en",
            "public_metrics": {
                "retweet_count": 0,
                "reply_count": 0,
                "like_count": 0,
                "quote_count": 0,
            },
        },
        {
            "id": "x-gen-002",
            "created_at": now,
            "author_id": "sample-user-02",
            "text": "Second generated Bronze record for the X source",
            "lang": "en",
            "public_metrics": {
                "retweet_count": 1,
                "reply_count": 0,
                "like_count": 3,
                "quote_count": 0,
            },
        },
    ]


def lambda_handler(event, context):
    bucket = os.environ["BUCKET_NAME"]
    prefix = os.environ.get("PREFIX", "bronze/x")
    dataset_urls = [url.strip() for url in os.environ.get("X_DATASET_URLS", "").split(",") if url.strip()]
    ingest_date = datetime.now(timezone.utc).date().isoformat()

    if dataset_urls:
        ingested = []
        for index, url in enumerate(dataset_urls, start=1):
            raw_bytes = http_get_bytes(url)
            filename = safe_filename_from_url(url, f"dataset-{index}.json")
            key = f"{prefix}/source=external/ingest_date={ingest_date}/{index:03d}-{filename}"
            content_type = "application/octet-stream"
            if filename.endswith(".json") or filename.endswith(".jsonl"):
                content_type = "application/json"
            elif filename.endswith(".csv"):
                content_type = "text/csv"
            put_raw_object(bucket, key, raw_bytes, content_type=content_type)
            ingested.append(key)

        return {
            "statusCode": 200,
            "body": json.dumps({"bucket": bucket, "prefix": prefix, "mode": "url", "objects": ingested}),
        }

    raw_records = generated_raw_dataset()
    raw_payload = "\n".join(json.dumps(record, separators=(",", ":"), ensure_ascii=False) for record in raw_records).encode("utf-8")
    key = f"{prefix}/source=generated/ingest_date={ingest_date}/sample.jsonl"
    put_raw_object(bucket, key, raw_payload, content_type="application/x-ndjson")

    return {
        "statusCode": 200,
        "body": json.dumps({"bucket": bucket, "prefix": prefix, "mode": "generated", "object": key}),
    }
