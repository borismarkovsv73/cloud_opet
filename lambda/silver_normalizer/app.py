import csv
import html
import json
import os
import re
import tempfile
from datetime import UTC, datetime

import boto3


HTML_TAG_RE = re.compile(r"<[^>]+>")


def make_s3_client():
    endpoint_url = os.environ.get("AWS_ENDPOINT_URL")
    return boto3.client("s3", endpoint_url=endpoint_url) if endpoint_url else boto3.client("s3")


s3 = make_s3_client()


def clean_text(value):
    if value is None:
        return None

    text = html.unescape(str(value))
    text = HTML_TAG_RE.sub(" ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text or None


def parse_datetime(value):
    if value is None or value == "":
        return None

    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value, tz=UTC)

    if isinstance(value, str):
        normalized = value.replace("Z", "+00:00")
        try:
            dt = datetime.fromisoformat(normalized)
            return dt if dt.tzinfo else dt.replace(tzinfo=UTC)
        except ValueError:
            return None

    return None


def ensure_list(value):
    return value if isinstance(value, list) else []


def bronze_key_prefix(bucket_name, prefix):
    return f"s3://{bucket_name}/{prefix.rstrip('/')}/"


def list_objects(bucket_name, prefix):
    paginator = s3.get_paginator("list_objects_v2")
    keys = []
    for page in paginator.paginate(Bucket=bucket_name, Prefix=prefix.rstrip("/") + "/"):
        for item in page.get("Contents", []):
            keys.append(item["Key"])
    return keys


def read_json_object(bucket_name, key):
    response = s3.get_object(Bucket=bucket_name, Key=key)
    payload = response["Body"].read().decode("utf-8")
    return json.loads(payload)


def read_text_object(bucket_name, key):
    response = s3.get_object(Bucket=bucket_name, Key=key)
    return response["Body"].read().decode("utf-8")


def extract_ingest_date_from_key(key):
    match = re.search(r"ingest_date=(\d{4}-\d{2}-\d{2})", key)
    return match.group(1) if match else None


def source_from_hn_key(key):
    match = re.search(r"algolia_source=([^/]+)", key)
    return match.group(1) if match else "unknown"


def fetch_hn_user_profile(user_id):
    fixture_dir = os.environ.get("HN_USER_FIXTURE_DIR")
    if fixture_dir:
        fixture_path = os.path.join(fixture_dir, f"{user_id}.json")
        if os.path.isfile(fixture_path):
            with open(fixture_path, "r", encoding="utf-8") as fixture_file:
                payload = json.load(fixture_file)
            return payload if isinstance(payload, dict) else None

    if not user_id:
        return None

    import urllib.parse
    import urllib.request

    url_template = os.environ.get("HN_USER_API_TEMPLATE", "https://hacker-news.firebaseio.com/v0/user/{user_id}.json")
    url = url_template.format(user_id=urllib.parse.quote(str(user_id)))
    request = urllib.request.Request(url, headers={"User-Agent": "silver-normalizer/1.0"})

    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception:
        return None

    return payload if isinstance(payload, dict) else None


def collect_hn_records(bucket_name, bronze_prefix):
    users = []
    posts = []
    relations = []
    user_profiles = {}

    for key in list_objects(bucket_name, bronze_prefix):
        if not key.endswith(".json"):
            continue

        source_name = source_from_hn_key(key)
        ingest_date = extract_ingest_date_from_key(key)
        document = read_json_object(bucket_name, key)

        for hit in document.get("hits", []):
            post_id = str(hit.get("objectID") or hit.get("id"))
            author_id = hit.get("author")
            created_at = parse_datetime(hit.get("created_at") or hit.get("created_at_i") or hit.get("time"))
            event_date = (created_at.date().isoformat() if created_at else ingest_date)

            if author_id and author_id not in user_profiles:
                user_profiles[author_id] = fetch_hn_user_profile(author_id)

            profile = user_profiles.get(author_id) or {}

            users.append(
                {
                    "user_id": author_id,
                    "platform": "hackernews",
                    "username": author_id,
                    "karma_score": profile.get("karma"),
                    "is_verified": False,
                    "created_at": parse_datetime(profile.get("created") or profile.get("created_at")),
                    "about_text": clean_text(profile.get("about")),
                }
            )

            posts.append(
                {
                    "post_id": post_id,
                    "platform": "hackernews",
                    "post_type": source_name,
                    "author_user_id": author_id,
                    "parent_post_id": str(hit.get("parent")) if hit.get("parent") is not None else None,
                    "title": clean_text(hit.get("title")),
                    "content_text": clean_text(hit.get("story_text") or hit.get("comment_text") or hit.get("text")),
                    "url": hit.get("url"),
                    "created_at": created_at,
                    "score": hit.get("points") or hit.get("score"),
                    "descendants": hit.get("num_comments") or hit.get("descendants"),
                    "language": None,
                    "event_date": event_date,
                }
            )

            for order, child_id in enumerate(ensure_list(hit.get("kids"))):
                relations.append(
                    {
                        "platform": "hackernews",
                        "parent_post_id": post_id,
                        "child_post_id": str(child_id),
                        "relation_type": "kid",
                        "child_order": order,
                        "event_date": event_date,
                    }
                )

            for order, part_id in enumerate(ensure_list(hit.get("parts"))):
                relations.append(
                    {
                        "platform": "hackernews",
                        "parent_post_id": post_id,
                        "child_post_id": str(part_id),
                        "relation_type": "part",
                        "child_order": order,
                        "event_date": event_date,
                    }
                )

    return users, posts, relations


def load_x_records(bucket_name, key):
    if key.endswith((".jsonl", ".ndjson")):
        records = []
        for line in read_text_object(bucket_name, key).splitlines():
            line = line.strip()
            if line:
                records.append(json.loads(line))
        return records

    if key.endswith(".csv"):
        reader = csv.DictReader(read_text_object(bucket_name, key).splitlines())
        return list(reader)

    document = read_json_object(bucket_name, key)
    if isinstance(document, list):
        return document

    for field_name in ("data", "records", "items", "tweets", "posts"):
        nested_records = document.get(field_name)
        if isinstance(nested_records, list):
            return nested_records

    return [document]


def collect_x_records(bucket_name, bronze_prefix):
    users = []
    posts = []

    for key in list_objects(bucket_name, bronze_prefix):
        if not key.endswith((".json", ".jsonl", ".ndjson", ".csv")):
            continue

        ingest_date = extract_ingest_date_from_key(key)
        records = load_x_records(bucket_name, key)

        for raw in records:
            post_id = str(raw.get("id") or raw.get("tweet_id") or raw.get("post_id") or raw.get("object_id"))
            author_id = str(raw.get("author_id") or raw.get("user_id") or raw.get("username") or raw.get("author") or raw.get("screen_name") or "unknown")
            username = str(raw.get("username") or raw.get("screen_name") or author_id)
            created_at = parse_datetime(raw.get("created_at") or raw.get("timestamp") or raw.get("date"))
            event_date = created_at.date().isoformat() if created_at else ingest_date
            metrics = raw.get("public_metrics") or {}

            users.append(
                {
                    "user_id": author_id,
                    "platform": "x",
                    "username": username,
                    "karma_score": None,
                    "follower_count": raw.get("followers_count") or metrics.get("followers_count"),
                    "is_verified": bool(raw.get("verified") or raw.get("is_verified") or False),
                    "created_at": None,
                    "about_text": clean_text(raw.get("about") or raw.get("description")),
                }
            )

            posts.append(
                {
                    "post_id": post_id,
                    "platform": "x",
                    "post_type": "tweet",
                    "author_user_id": author_id,
                    "parent_post_id": None,
                    "title": None,
                    "content_text": clean_text(raw.get("text") or raw.get("content") or raw.get("body")),
                    "url": raw.get("url"),
                    "created_at": created_at,
                    "score": metrics.get("like_count") or raw.get("score"),
                    "descendants": metrics.get("reply_count") or raw.get("reply_count"),
                    "language": raw.get("lang") or raw.get("language"),
                    "event_date": event_date,
                }
            )

    return users, posts


def normalize_value(value):
    if isinstance(value, datetime):
        return value.astimezone(UTC)
    return value


def dedupe_rows(rows, columns, dedupe_columns):
    seen = set()
    deduped = []
    for row in rows:
        dedupe_key = tuple(row.get(column) for column in dedupe_columns)
        if dedupe_key in seen:
            continue
        seen.add(dedupe_key)
        deduped.append({column: normalize_value(row.get(column)) for column in columns})
    return deduped


def write_partitioned_parquet(bucket_name, target_prefix, rows, columns, partition_cols):
    if not rows:
        return

    import pyarrow as pa
    import pyarrow.parquet as pq

    partitions = {}
    for row in rows:
        partition_key = tuple(str(row.get(column) or "unknown") for column in partition_cols)
        partitions.setdefault(partition_key, []).append(row)

    for partition_key, partition_rows in partitions.items():
        partition_path = target_prefix.rstrip("/")
        for column, value in zip(partition_cols, partition_key):
            partition_path += f"/{column}={value}"

        table_rows = [{column: normalize_value(row.get(column)) for column in columns} for row in partition_rows]
        table = pa.Table.from_pylist(table_rows)

        with tempfile.NamedTemporaryFile(suffix=".parquet", delete=False) as temp_file:
            temp_path = temp_file.name

        try:
            pq.write_table(table, temp_path, compression="snappy")
            s3.upload_file(temp_path, bucket_name, f"{partition_path}/part-00000.parquet")
        finally:
            try:
                os.remove(temp_path)
            except OSError:
                pass


def lambda_handler(event, context):
    bronze_bucket = os.environ["BRONZE_BUCKET"]
    silver_bucket = os.environ["SILVER_BUCKET"]
    hn_prefix = os.environ.get("BRONZE_HN_PREFIX", "bronze/hackernews/raw")
    x_prefix = os.environ.get("BRONZE_X_PREFIX", "bronze/x")

    hn_users, hn_posts, hn_relations = collect_hn_records(bronze_bucket, hn_prefix)
    x_users, x_posts = collect_x_records(bronze_bucket, x_prefix)

    user_columns = ["user_id", "platform", "username", "karma_score", "follower_count", "is_verified", "created_at", "about_text"]
    post_columns = [
        "post_id",
        "platform",
        "post_type",
        "author_user_id",
        "parent_post_id",
        "title",
        "content_text",
        "url",
        "created_at",
        "score",
        "descendants",
        "language",
        "event_date",
    ]
    relation_columns = ["platform", "parent_post_id", "child_post_id", "relation_type", "child_order", "event_date"]

    users_rows = dedupe_rows(hn_users + x_users, user_columns, ["platform", "user_id"])
    posts_rows = dedupe_rows(hn_posts + x_posts, post_columns, ["platform", "post_id"])
    relations_rows = dedupe_rows(hn_relations, relation_columns, ["platform", "parent_post_id", "child_post_id", "relation_type", "child_order"])

    write_partitioned_parquet(silver_bucket, "silver/users", users_rows, user_columns, ["platform"])
    write_partitioned_parquet(silver_bucket, "silver/posts", posts_rows, post_columns, ["platform", "event_date"])
    write_partitioned_parquet(silver_bucket, "silver/post_relations", relations_rows, relation_columns, ["platform", "event_date"])

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "silver_users_rows": int(len(users_rows)),
                "silver_posts_rows": int(len(posts_rows)),
                "silver_relations_rows": int(len(relations_rows)),
            }
        ),
    }