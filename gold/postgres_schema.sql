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
);

CREATE TABLE IF NOT EXISTS dim_platform (
    platform TEXT PRIMARY KEY,
    description TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_item_type (
    item_type TEXT PRIMARY KEY,
    description TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_ranking_type (
    ranking_type TEXT PRIMARY KEY,
    description TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_dataset (
    dataset_name TEXT PRIMARY KEY,
    description TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS fact_daily_item_counts (
    date DATE NOT NULL REFERENCES dim_date(date),
    platform TEXT NOT NULL REFERENCES dim_platform(platform),
    item_type TEXT NOT NULL REFERENCES dim_item_type(item_type),
    item_count INTEGER NOT NULL,
    PRIMARY KEY (date, platform, item_type)
);

CREATE TABLE IF NOT EXISTS fact_daily_users (
    date DATE NOT NULL REFERENCES dim_date(date),
    platform TEXT NOT NULL REFERENCES dim_platform(platform),
    total_users INTEGER NOT NULL,
    new_users INTEGER NOT NULL,
    PRIMARY KEY (date, platform)
);

CREATE TABLE IF NOT EXISTS fact_user_rankings (
    date DATE NOT NULL REFERENCES dim_date(date),
    platform TEXT NOT NULL REFERENCES dim_platform(platform),
    ranking_type TEXT NOT NULL REFERENCES dim_ranking_type(ranking_type),
    rank INTEGER NOT NULL,
    user_id TEXT NOT NULL,
    username TEXT NOT NULL,
    score_value NUMERIC NOT NULL,
    PRIMARY KEY (date, platform, ranking_type, rank)
);

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
);

CREATE TABLE IF NOT EXISTS fact_data_quality (
    date DATE NOT NULL REFERENCES dim_date(date),
    platform TEXT NOT NULL REFERENCES dim_platform(platform),
    dataset_name TEXT NOT NULL REFERENCES dim_dataset(dataset_name),
    total_rows INTEGER NOT NULL,
    rows_without_null_values INTEGER NOT NULL,
    data_quality_score NUMERIC(6,2) NOT NULL,
    PRIMARY KEY (date, platform, dataset_name)
);
