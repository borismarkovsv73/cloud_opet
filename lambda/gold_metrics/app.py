import json
import os
import tempfile
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone

import boto3


def make_s3_client():
    endpoint_url = os.environ.get("AWS_ENDPOINT_URL")
    return boto3.client("s3", endpoint_url=endpoint_url) if endpoint_url else boto3.client("s3")


s3 = make_s3_client()


def list_objects(bucket_name, prefix):
    paginator = s3.get_paginator("list_objects_v2")
    keys = []
    normalized_prefix = prefix.rstrip("/") + "/"
    for page in paginator.paginate(Bucket=bucket_name, Prefix=normalized_prefix):
        for item in page.get("Contents", []):
            keys.append(item["Key"])
    return keys


def read_parquet_rows(bucket_name, key):
    import pyarrow.parquet as pq

    with tempfile.NamedTemporaryFile(suffix=".parquet", delete=False) as temp_file:
        temp_path = temp_file.name

    try:
        s3.download_file(bucket_name, key, temp_path)
        table = pq.read_table(temp_path)
        return table.to_pylist()
    finally:
        try:
            os.remove(temp_path)
        except OSError:
            pass


def read_dataset(bucket_name, prefix):
    rows = []
    for key in list_objects(bucket_name, prefix):
        if key.endswith(".parquet"):
            rows.extend(read_parquet_rows(bucket_name, key))
    return rows


def write_partitioned_parquet(bucket_name, target_prefix, rows, columns, partition_cols):
    if not rows:
        return 0

    import pyarrow as pa
    import pyarrow.parquet as pq

    partitions = defaultdict(list)
    for row in rows:
        partition_key = tuple(str(row.get(column) or "unknown") for column in partition_cols)
        partitions[partition_key].append(row)

    written_files = 0
    for partition_key, partition_rows in partitions.items():
        partition_path = target_prefix.rstrip("/")
        for column, value in zip(partition_cols, partition_key):
            partition_path += f"/{column}={value}"

        table_rows = [{column: row.get(column) for column in columns} for row in partition_rows]
        table = pa.Table.from_pylist(table_rows)

        with tempfile.NamedTemporaryFile(suffix=".parquet", delete=False) as temp_file:
            temp_path = temp_file.name

        try:
            pq.write_table(table, temp_path, compression="snappy")
            s3.upload_file(temp_path, bucket_name, f"{partition_path}/part-00000.parquet")
            written_files += 1
        finally:
            try:
                os.remove(temp_path)
            except OSError:
                pass

    return written_files


def parse_date(value):
    if not value:
        return None
    if isinstance(value, datetime):
        return value.date().isoformat()
    if isinstance(value, str):
        return value[:10]
    return str(value)


def latest_event_date(posts):
    dates = [parse_date(row.get("event_date") or row.get("created_at")) for row in posts]
    dates = [value for value in dates if value]
    return max(dates) if dates else datetime.now(timezone.utc).date().isoformat()


def build_daily_item_counts(posts):
    grouped = defaultdict(int)
    for row in posts:
        date_value = parse_date(row.get("event_date"))
        if not date_value:
            continue
        platform = row.get("platform") or "unknown"
        item_type = row.get("post_type") or "unknown"
        grouped[(date_value, platform, item_type)] += 1

    results = []
    for (date_value, platform, item_type), count in sorted(grouped.items()):
        results.append(
            {
                "date": date_value,
                "platform": platform,
                "item_type": item_type,
                "item_count": int(count),
            }
        )
    return results


def build_daily_users(posts):
    authors_by_day = defaultdict(set)
    first_seen = {}

    for row in posts:
        date_value = parse_date(row.get("event_date"))
        platform = row.get("platform") or "unknown"
        author_id = row.get("author_user_id") or row.get("author")
        if not date_value or not author_id:
            continue

        authors_by_day[(date_value, platform)].add(author_id)
        first_seen_key = (platform, author_id)
        if first_seen_key not in first_seen or date_value < first_seen[first_seen_key]:
            first_seen[first_seen_key] = date_value

    results = []
    for (date_value, platform), authors in sorted(authors_by_day.items()):
        new_users = sum(1 for author_id in authors if first_seen.get((platform, author_id)) == date_value)
        results.append(
            {
                "date": date_value,
                "platform": platform,
                "total_users": int(len(authors)),
                "new_users": int(new_users),
            }
        )

    return results


def fetch_hn_user_profile(user_id):
    fixture_dir = os.environ.get("HN_USER_FIXTURE_DIR")
    if fixture_dir:
        fixture_path = os.path.join(fixture_dir, f"{user_id}.json")
        if os.path.isfile(fixture_path):
            with open(fixture_path, "r", encoding="utf-8") as fixture_file:
                payload = json.load(fixture_file)
            return payload if isinstance(payload, dict) else None

    url_template = os.environ.get("HN_USER_API_TEMPLATE", "https://hacker-news.firebaseio.com/v0/user/{user_id}.json")
    url = url_template.format(user_id=urllib.parse.quote(str(user_id)))
    request = urllib.request.Request(url, headers={"User-Agent": "gold-metrics-lambda/1.0"})

    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception:
        return None

    return payload if isinstance(payload, dict) else None


def build_user_rankings(posts, users, report_date):
    rankings = []
    hn_scores = [
        {
            "date": report_date,
            "platform": "hackernews",
            "ranking_type": "top_hn_karma",
            "user_id": str(row.get("user_id") or "unknown"),
            "username": str(row.get("username") or row.get("user_id") or "unknown"),
            "score_value": int(row.get("karma_score") or 0),
        }
        for row in users
        if row.get("platform") == "hackernews" and row.get("karma_score") is not None
    ]

    for rank, row in enumerate(sorted(hn_scores, key=lambda item: (-item["score_value"], item["username"]))[:10], start=1):
        rankings.append({**row, "rank": rank})

    for rank, row in enumerate(sorted(hn_scores, key=lambda item: (item["score_value"], item["username"]))[:10], start=1):
        rankings.append({**row, "rank": rank, "ranking_type": "bottom_hn_karma"})

    x_users = [row for row in users if row.get("platform") == "x" and row.get("follower_count") is not None]
    x_sorted = sorted(
        x_users,
        key=lambda item: (-(int(item.get("follower_count") or 0)), str(item.get("username") or item.get("user_id"))),
    )
    for rank, row in enumerate(x_sorted[:10], start=1):
        rankings.append(
            {
                "date": report_date,
                "platform": "x",
                "ranking_type": "top_x_followers",
                "rank": rank,
                "user_id": str(row.get("user_id") or "unknown"),
                "username": str(row.get("username") or row.get("user_id") or "unknown"),
                "score_value": int(row.get("follower_count") or 0),
            }
        )

    return rankings


def build_post_rankings(posts, report_date):
    rankings = []
    hn_posts = [row for row in posts if row.get("platform") == "hackernews"]

    for post_type in ("job", "story"):
        rows = [row for row in hn_posts if row.get("post_type") == post_type]
        sorted_rows = sorted(
            rows,
            key=lambda item: (-(int(item.get("score") or 0)), str(item.get("created_at") or ""), str(item.get("post_id") or "")),
        )

        for rank, row in enumerate(sorted_rows[:10], start=1):
            rankings.append(
                {
                    "date": report_date,
                    "platform": "hackernews",
                    "item_type": post_type,
                    "rank": rank,
                    "post_id": str(row.get("post_id") or "unknown"),
                    "author_user_id": str(row.get("author_user_id") or "unknown"),
                    "title": row.get("title"),
                    "score_value": int(row.get("score") or 0),
                    "url": row.get("url"),
                }
            )

    return rankings


def is_complete_row(row):
    return all(value is not None for value in row.values())


def build_data_quality(rows_by_dataset, report_date):
    results = []

    for dataset_name, rows in rows_by_dataset.items():
        if not rows:
            continue

        grouped = defaultdict(list)
        for row in rows:
            grouped[row.get("platform") or "unknown"].append(row)

        for platform, platform_rows in grouped.items():
            total_rows = len(platform_rows)
            clean_rows = sum(1 for row in platform_rows if is_complete_row(row))
            score = round((clean_rows / total_rows) * 100, 2) if total_rows else 0.0
            results.append(
                {
                    "date": report_date,
                    "platform": platform,
                    "dataset_name": dataset_name,
                    "total_rows": int(total_rows),
                    "rows_without_null_values": int(clean_rows),
                    "data_quality_score": float(score),
                }
            )

    return results


def lambda_handler(event, context):
    silver_bucket = os.environ["SILVER_BUCKET"]
    gold_bucket = os.environ["GOLD_BUCKET"]
    silver_users_prefix = os.environ.get("SILVER_USERS_PREFIX", "silver/users")
    silver_posts_prefix = os.environ.get("SILVER_POSTS_PREFIX", "silver/posts")
    silver_relations_prefix = os.environ.get("SILVER_RELATIONS_PREFIX", "silver/post_relations")
    gold_prefix = os.environ.get("GOLD_PREFIX", "gold")

    users = read_dataset(silver_bucket, silver_users_prefix)
    posts = read_dataset(silver_bucket, silver_posts_prefix)
    relations = read_dataset(silver_bucket, silver_relations_prefix)

    report_date = None
    if isinstance(event, dict):
        report_date = event.get("report_date")
    report_date = report_date or latest_event_date(posts)

    daily_item_counts = build_daily_item_counts(posts)
    daily_users = build_daily_users(posts)
    user_rankings = build_user_rankings(posts, users, report_date)
    post_rankings = build_post_rankings(posts, report_date)
    data_quality = build_data_quality(
        {
            "silver_users": users,
            "silver_posts": posts,
            "silver_post_relations": relations,
        },
        report_date,
    )

    written_files = {
        "daily_item_counts": write_partitioned_parquet(
            gold_bucket,
            f"{gold_prefix}/daily_item_counts",
            daily_item_counts,
            ["date", "platform", "item_type", "item_count"],
            ["platform", "date"],
        ),
        "daily_users": write_partitioned_parquet(
            gold_bucket,
            f"{gold_prefix}/daily_users",
            daily_users,
            ["date", "platform", "total_users", "new_users"],
            ["platform", "date"],
        ),
        "user_rankings": write_partitioned_parquet(
            gold_bucket,
            f"{gold_prefix}/user_rankings",
            user_rankings,
            ["date", "platform", "ranking_type", "rank", "user_id", "username", "score_value"],
            ["platform", "date"],
        ),
        "post_rankings": write_partitioned_parquet(
            gold_bucket,
            f"{gold_prefix}/post_rankings",
            post_rankings,
            ["date", "platform", "item_type", "rank", "post_id", "author_user_id", "title", "score_value", "url"],
            ["platform", "date"],
        ),
        "data_quality": write_partitioned_parquet(
            gold_bucket,
            f"{gold_prefix}/data_quality",
            data_quality,
            ["date", "platform", "dataset_name", "total_rows", "rows_without_null_values", "data_quality_score"],
            ["platform", "date"],
        ),
    }

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "report_date": report_date,
                "written_files": written_files,
                "daily_item_counts_rows": len(daily_item_counts),
                "daily_users_rows": len(daily_users),
                "user_rankings_rows": len(user_rankings),
                "post_rankings_rows": len(post_rankings),
                "data_quality_rows": len(data_quality),
            }
        ),
    }
