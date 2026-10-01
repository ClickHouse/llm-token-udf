-- Quality evals as a cron job, in SQL: every 10 minutes, judge a 2% sample of
-- the last 10 minutes of completions with the network-enabled judge_response UDF.
CREATE TABLE llm_evals
(
    ts          DateTime,
    trace_id    String,
    span_id     String,
    feature     LowCardinality(String),
    model       LowCardinality(String),
    score       UInt8,
    verdict     LowCardinality(String),   -- pass | partial | fail | error
    reason      String,
    judged_at   DateTime
)
ENGINE = MergeTree
ORDER BY (feature, ts);

CREATE MATERIALIZED VIEW llm_evals_mv
REFRESH EVERY 10 MINUTE
APPEND TO llm_evals
AS
WITH judge_response(
        concat(system_prompt, '\n\n', retrieved_context, '\n\nUser: ', user_prompt),
        completion
     ) AS j
SELECT
    ts, trace_id, span_id, feature, model,
    j.1   AS score,
    j.2   AS verdict,
    j.3   AS reason,
    now() AS judged_at
FROM llm_spans
WHERE ts >= now() - INTERVAL 10 MINUTE
  AND cityHash64(trace_id) % 100 < 2;       -- deterministic 2% sample
