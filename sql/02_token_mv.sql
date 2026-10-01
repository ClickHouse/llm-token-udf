-- One row per span with every prompt component counted separately.
-- This is the only place count_tokens() runs: once per span, at insert time.
CREATE TABLE llm_span_tokens
(
    ts                      DateTime,
    trace_id                String,
    span_id                 String,
    service                 LowCardinality(String),
    feature                 LowCardinality(String),
    customer_id             LowCardinality(String),
    model                   LowCardinality(String),
    system_tokens           UInt32,
    context_tokens          UInt32,
    user_tokens             UInt32,
    completion_tokens       UInt32,
    provider_input_tokens   Nullable(UInt32),
    provider_output_tokens  Nullable(UInt32),
    system_prompt_hash      UInt64        -- to spot identical system prompts across spans
)
ENGINE = MergeTree
ORDER BY (service, feature, ts);

CREATE MATERIALIZED VIEW llm_span_tokens_mv TO llm_span_tokens AS
SELECT
    ts, trace_id, span_id, service, feature, customer_id, model,
    count_tokens(model, system_prompt)     AS system_tokens,
    count_tokens(model, retrieved_context) AS context_tokens,
    count_tokens(model, user_prompt)       AS user_tokens,
    count_tokens(model, completion)        AS completion_tokens,
    provider_input_tokens,
    provider_output_tokens,
    sipHash64(system_prompt)               AS system_prompt_hash
FROM llm_spans;
