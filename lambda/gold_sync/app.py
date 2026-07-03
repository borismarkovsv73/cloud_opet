import json
import os
import tempfile
from collections import defaultdict
from datetime import date

import boto3


TABLE_CONFIG = {
    "fact_daily_item_counts": {
        "prefix": "gold/daily_item_counts",
        "columns": ["date", "platform", "item_type", "item_count"],
        "keys": ["date", "platform", "item_type"],
    },
    "fact_daily_users": {
        "prefix": "gold/daily_users",
        "columns": ["date", "platform", "total_users", "new_users"],
        "keys": ["date", "platform"],
    },
    "fact_user_rankings": {
        "prefix": "gold/user_rankings",
        "columns": ["date", "platform", "ranking_type", "rank", "user_id", "username", "score_value"],
        "keys": ["date", "platform", "ranking_type", "rank"],
    },
    "fact_post_rankings": {
        "prefix": "gold/post_rankings",
        "columns": ["date", "platform", "item_type", "rank", "post_id", "author_user_id", "title", "score_value", "url"],
        "keys": ["date", "platform", "item_type", "rank"],
    },
    "fact_data_quality": {
        "prefix": "gold/data_quality",
        "columns": ["date", "platform", "dataset_name", "total_rows", "rows_without_null_values", "data_quality_score"],
        "keys": ["date", "platform", "dataset_name"],
    },
}
def make_s3_client():
    endpoint_url = os.environ.get("AWS_ENDPOINT_URL")
    return boto3.client("s3", endpoint_url=endpoint_url) if endpoint_url else boto3.client("s3")


def make_secrets_client():
    endpoint_url = os.environ.get("AWS_ENDPOINT_URL")
    return boto3.client("secretsmanager", endpoint_url=endpoint_url) if endpoint_url else boto3.client("secretsmanager")


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


def read_table_rows(bucket_name, prefix):
    rows = []
    for key in list_objects(bucket_name, prefix):
        if key.endswith(".parquet"):
            rows.extend(read_parquet_rows(bucket_name, key))
    return rows


def get_postgres_connection_details():
    secret_arn = os.environ.get("POSTGRES_SECRET_ARN")
    if secret_arn:
        secret_response = make_secrets_client().get_secret_value(SecretId=secret_arn)
        secret_payload = json.loads(secret_response["SecretString"])
        return {
            "host": secret_payload["host"],
            "port": int(secret_payload.get("port", 5432)),
            "database": secret_payload.get("dbname") or secret_payload.get("database"),
            "user": secret_payload.get("username") or secret_payload.get("user"),
            "password": secret_payload["password"],
        }

    return {
        "host": os.environ["POSTGRES_HOST"],
        "port": int(os.environ.get("POSTGRES_PORT", "5432")),
        "database": os.environ["POSTGRES_DATABASE"],
        "user": os.environ["POSTGRES_USER"],
        "password": os.environ["POSTGRES_PASSWORD"],
    }


def connect_postgres():
    import pg8000

    details = get_postgres_connection_details()
    return pg8000.connect(
        host=details["host"],
        port=details["port"],
        database=details["database"],
        user=details["user"],
        password=details["password"],
    )


def ensure_schema(cursor):
    statements = [
        """
        CREATE TABLE IF NOT EXISTS dim_date (
            date DATE PRIMARY KEY,
            year INTEGER NOT NULL,
            quarter INTEGER NOT NULL,
            month INTEGER NOT NULL,
            day INTEGER NOT NULL,
            day_of_week INTEGER NOT NULL,
            day_name TEXT NOT NULL,
            week_of_year INTEGER NOT NULL,
            is_weekend BOOLEAN NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS dim_platform (
            platform TEXT PRIMARY KEY,
            description TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS dim_item_type (
            item_type TEXT PRIMARY KEY,
            description TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS dim_ranking_type (
            ranking_type TEXT PRIMARY KEY,
            description TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS dim_dataset (
            dataset_name TEXT PRIMARY KEY,
            description TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS fact_daily_item_counts (
            date DATE NOT NULL REFERENCES dim_date(date),
            platform TEXT NOT NULL REFERENCES dim_platform(platform),
            item_type TEXT NOT NULL REFERENCES dim_item_type(item_type),
            item_count INTEGER NOT NULL,
            PRIMARY KEY (date, platform, item_type)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS fact_daily_users (
            date DATE NOT NULL REFERENCES dim_date(date),
            platform TEXT NOT NULL REFERENCES dim_platform(platform),
            total_users INTEGER NOT NULL,
            new_users INTEGER NOT NULL,
            PRIMARY KEY (date, platform)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS fact_user_rankings (
            date DATE NOT NULL REFERENCES dim_date(date),
            platform TEXT NOT NULL REFERENCES dim_platform(platform),
            ranking_type TEXT NOT NULL REFERENCES dim_ranking_type(ranking_type),
            rank INTEGER NOT NULL,
            user_id TEXT NOT NULL,
            username TEXT NOT NULL,
            score_value NUMERIC NOT NULL,
            PRIMARY KEY (date, platform, ranking_type, rank)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS fact_post_rankings (
            date DATE NOT NULL REFERENCES dim_date(date),
            platform TEXT NOT NULL REFERENCES dim_platform(platform),
            item_type TEXT NOT NULL REFERENCES dim_item_type(item_type),
            rank INTEGER NOT NULL,
            post_id TEXT NOT NULL,
            author_user_id TEXT,
            title TEXT,
            score_value NUMERIC NOT NULL,
            url TEXT,
            PRIMARY KEY (date, platform, item_type, rank)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS fact_data_quality (
            date DATE NOT NULL REFERENCES dim_date(date),
            platform TEXT NOT NULL REFERENCES dim_platform(platform),
            dataset_name TEXT NOT NULL REFERENCES dim_dataset(dataset_name),
            total_rows INTEGER NOT NULL,
            rows_without_null_values INTEGER NOT NULL,
            data_quality_score NUMERIC(6,2) NOT NULL,
            PRIMARY KEY (date, platform, dataset_name)
        )
        """,
    ]

    for statement in statements:
        cursor.execute(statement)


def upsert_dimension_rows(cursor, table_name, rows, columns):
    if not rows:
        return

    placeholders = ", ".join(["%s"] * len(columns))
    assignments = ", ".join([f"{column} = EXCLUDED.{column}" for column in columns[1:]])
    insert_sql = f"INSERT INTO {table_name} ({', '.join(columns)}) VALUES ({placeholders}) ON CONFLICT ({columns[0]}) DO UPDATE SET {assignments}"
    cursor.executemany(insert_sql, [[row[column] for column in columns] for row in rows])


def delete_existing_fact_rows(cursor, table_name, key_columns, rows):
    if not rows:
        return

    unique_keys = sorted({tuple(row[column] for column in key_columns) for row in rows})
    for key in unique_keys:
        where_clause = " AND ".join([f"{column} = %s" for column in key_columns])
        cursor.execute(f"DELETE FROM {table_name} WHERE {where_clause}", key)


def insert_fact_rows(cursor, table_name, columns, rows):
    if not rows:
        return

    placeholders = ", ".join(["%s"] * len(columns))
    insert_sql = f"INSERT INTO {table_name} ({', '.join(columns)}) VALUES ({placeholders})"
    cursor.executemany(insert_sql, [[row[column] for column in columns] for row in rows])


def build_dimension_rows(fact_rows):
    date_rows = {}
    platform_rows = {}
    item_type_rows = {}
    ranking_type_rows = {}
    dataset_rows = {}

    def add_date_row(date_value):
        date_obj = date.fromisoformat(date_value)
        date_rows[date_value] = {
            "date": date_value,
            "year": date_obj.year,
            "quarter": ((date_obj.month - 1) // 3) + 1,
            "month": date_obj.month,
            "day": date_obj.day,
            "day_of_week": date_obj.isoweekday(),
            "day_name": date_obj.strftime("%A"),
            "week_of_year": date_obj.isocalendar().week,
            "is_weekend": date_obj.isoweekday() in (6, 7),
        }

    def add_platform_row(platform_value):
        platform_rows[platform_value] = {
            "platform": platform_value,
            "description": "Hacker News" if platform_value == "hackernews" else "X (Twitter)" if platform_value == "x" else platform_value,
        }

    def add_item_type_row(item_type_value):
        item_type_rows[item_type_value] = {
            "item_type": item_type_value,
            "description": item_type_value.replace("_", " ").title(),
        }

    def add_ranking_type_row(ranking_type_value):
        ranking_type_rows[ranking_type_value] = {
            "ranking_type": ranking_type_value,
            "description": ranking_type_value.replace("_", " ").title(),
        }

    def add_dataset_row(dataset_name_value):
        dataset_rows[dataset_name_value] = {
            "dataset_name": dataset_name_value,
            "description": dataset_name_value.replace("_", " ").title(),
        }

    for row in fact_rows.get("fact_daily_item_counts", []):
        add_date_row(row["date"])
        add_platform_row(row["platform"])
        add_item_type_row(row["item_type"])

    for row in fact_rows.get("fact_daily_users", []):
        add_date_row(row["date"])
        add_platform_row(row["platform"])

    for row in fact_rows.get("fact_user_rankings", []):
        add_date_row(row["date"])
        add_platform_row(row["platform"])
        add_ranking_type_row(row["ranking_type"])

    for row in fact_rows.get("fact_post_rankings", []):
        add_date_row(row["date"])
        add_platform_row(row["platform"])
        add_item_type_row(row["item_type"])

    for row in fact_rows.get("fact_data_quality", []):
        add_date_row(row["date"])
        add_platform_row(row["platform"])
        add_dataset_row(row["dataset_name"])

    return {
        "dim_date": list(date_rows.values()),
        "dim_platform": list(platform_rows.values()),
        "dim_item_type": list(item_type_rows.values()),
        "dim_ranking_type": list(ranking_type_rows.values()),
        "dim_dataset": list(dataset_rows.values()),
    }


def lambda_handler(event, context):
    gold_bucket = os.environ["GOLD_BUCKET"]

    fact_rows = {}
    for table_name, config in TABLE_CONFIG.items():
        fact_rows[table_name] = read_table_rows(gold_bucket, config["prefix"])

    conn = connect_postgres()
    try:
        cursor = conn.cursor()
        ensure_schema(cursor)

        dimension_rows = build_dimension_rows(fact_rows)
        upsert_dimension_rows(cursor, "dim_date", dimension_rows["dim_date"], ["date", "year", "quarter", "month", "day", "day_of_week", "day_name", "week_of_year", "is_weekend"])
        upsert_dimension_rows(cursor, "dim_platform", dimension_rows["dim_platform"], ["platform", "description"])
        upsert_dimension_rows(cursor, "dim_item_type", dimension_rows["dim_item_type"], ["item_type", "description"])
        upsert_dimension_rows(cursor, "dim_ranking_type", dimension_rows["dim_ranking_type"], ["ranking_type", "description"])
        upsert_dimension_rows(cursor, "dim_dataset", dimension_rows["dim_dataset"], ["dataset_name", "description"])

        for table_name, config in TABLE_CONFIG.items():
            rows = fact_rows[table_name]
            if not rows:
                continue
            delete_existing_fact_rows(cursor, table_name, config["keys"], rows)
            insert_fact_rows(cursor, table_name, config["columns"], rows)

        conn.commit()
    finally:
        conn.close()

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "loaded_tables": {table_name: len(rows) for table_name, rows in fact_rows.items()},
            }
        ),
    }
