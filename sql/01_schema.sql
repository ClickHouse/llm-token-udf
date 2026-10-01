-- Raw LLM call spans, as your gateway / OTel collector / Langfuse exporter lands them.
-- Column names loosely follow the OpenTelemetry GenAI semantic conventions.
CREATE TABLE llm_spans
(
    ts                      DateTime,
    trace_id                String,
    span_id                 String,
    service                 LowCardinality(String),
    feature                 LowCardinality(String),   -- which product surface made the call
    customer_id             LowCardinality(String),
    model                   LowCardinality(String),   -- gen_ai.request.model
    system_prompt           String,
    retrieved_context       String,                   -- RAG chunks, tool results, history
    user_prompt             String,
    completion              String,
    latency_ms              UInt32,
    streamed                UInt8,
    -- What the provider reported. NULL more often than you'd think:
    -- streamed responses, proxies that drop usage, self-hosted models.
    provider_input_tokens   Nullable(UInt32),         -- gen_ai.usage.input_tokens
    provider_output_tokens  Nullable(UInt32)          -- gen_ai.usage.output_tokens
)
ENGINE = MergeTree
ORDER BY (service, feature, ts);
