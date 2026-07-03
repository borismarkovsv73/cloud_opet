import json
import os
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

import boto3


def make_s3_client():
    endpoint_url = os.environ.get("AWS_ENDPOINT_URL")
    return boto3.client("s3", endpoint_url=endpoint_url) if endpoint_url else boto3.client("s3")


s3 = make_s3_client()


def http_get_json(url: str):
    request = urllib.request.Request(url, headers={"User-Agent": "bronze-hn-collector/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        raw_bytes = response.read()
    return raw_bytes, json.loads(raw_bytes)


def put_raw_object(bucket: str, key: str, payload: bytes):
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=payload,
        ContentType="application/json",
    )


def read_fixture_bytes(fixture_dir: str, source_name: str):
    fixture_path = os.path.join(fixture_dir, f"{source_name}.json")
    if not os.path.isfile(fixture_path):
        return None

    with open(fixture_path, "rb") as fixture_file:
        return fixture_file.read()


def previous_day_window(now_utc: datetime):
    day_start = datetime(now_utc.year, now_utc.month, now_utc.day, tzinfo=timezone.utc) - timedelta(days=1)
    day_end = day_start + timedelta(days=1)
    return day_start, day_end


def collect_source_pages(bucket: str, prefix: str, source_name: str, algolia_tag: str, day_start: datetime, day_end: datetime, query: str | None = None):
    """
    Pull pages from hn.algolia.com using search_by_date, restricted to the previous UTC day.
    The raw page response is stored unchanged in S3.
    """
    fixture_dir = os.environ.get("HN_FIXTURE_DIR")
    if fixture_dir:
        fixture_bytes = read_fixture_bytes(fixture_dir, source_name)
        if fixture_bytes is not None:
            data = json.loads(fixture_bytes)
            hits = data.get("hits", [])
            key = f"{prefix}/raw/algolia_source={source_name}/ingest_date={day_start.date().isoformat()}/page=0.json"
            put_raw_object(bucket, key, fixture_bytes)
            return len(hits)

    page = 0
    ingested = 0

    day_start_ts = int(day_start.timestamp())
    day_end_ts = int(day_end.timestamp())

    while True:
        params = {
            "tags": algolia_tag,
            "page": page,
            "hitsPerPage": 100,
            "numericFilters": f"created_at_i>={day_start_ts},created_at_i<{day_end_ts}",
        }
        if query:
            params["query"] = query

        query_string = urllib.parse.urlencode(params)
        url = f"https://hn.algolia.com/api/v1/search_by_date?{query_string}"
        raw, data = http_get_json(url)
        hits = data.get("hits", [])
        if not hits:
            break

        key = f"{prefix}/raw/algolia_source={source_name}/ingest_date={day_start.date().isoformat()}/page={page}.json"
        put_raw_object(bucket, key, raw)
        ingested += len(hits)

        page += 1

    return ingested


def lambda_handler(event, context):
    bucket = os.environ["BUCKET_NAME"]
    prefix = os.environ.get("PREFIX", "bronze/hackernews")

    day_start, day_end = previous_day_window(datetime.now(timezone.utc))

    stories = collect_source_pages(bucket, prefix, "story", "story", day_start, day_end)
    asks = collect_source_pages(bucket, prefix, "ask", "story", day_start, day_end, query="Ask HN")
    comments = collect_source_pages(bucket, prefix, "comment", "comment", day_start, day_end)
    jobs = collect_source_pages(bucket, prefix, "job", "job", day_start, day_end)
    polls = collect_source_pages(bucket, prefix, "poll", "poll", day_start, day_end)

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "bucket": bucket,
                "prefix": prefix,
                "window_start_utc": day_start.isoformat(),
                "window_end_utc": day_end.isoformat(),
                "stories_pages": stories,
                "asks_pages": asks,
                "comments_pages": comments,
                "jobs_ingested": jobs,
                "polls_ingested": polls,
            }
        ),
    }
