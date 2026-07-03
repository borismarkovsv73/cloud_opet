# Silver Layer

Silver normalizes the Bronze data into Parquet.

## Tables

### users

- `user_id`
- `platform`
- `username`
- `karma_score`
- `follower_count`
- `is_verified`
- `created_at`
- `about_text`

Partition: `platform`

### posts

- `post_id`
- `platform`
- `post_type`
- `author_user_id`
- `parent_post_id`
- `title`
- `content_text`
- `url`
- `created_at`
- `score`
- `descendants`
- `language`
- `event_date`

Partition: `platform`, `event_date`

### post_relations

- `platform`
- `parent_post_id`
- `child_post_id`
- `relation_type`
- `child_order`
- `event_date`

Partition: `platform`, `event_date`

## Notes

- HN HTML tags are removed from text fields.
- HN and X timestamps are normalized to UTC.
- Nested HN `kids` and `parts` fields are turned into a relation table.
- Duplicate rows are removed before writing Parquet.
- Output is written with `awswrangler` as partitioned Parquet datasets.