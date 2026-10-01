-- Q1. Where did the money go? Cost per feature per day, using the provider's
--     numbers when it gave us any and our own count when it didn't.
SELECT
    toDate(ts)                                                     AS day,
    feature,
    round(sum(coalesce(provider_input_tokens, system_tokens + context_tokens + user_tokens)
            * dictGet('model_prices_dict', 'input_cost_per_token', model)
          + coalesce(provider_output_tokens, completion_tokens)
            * dictGet('model_prices_dict', 'output_cost_per_token', model)), 2)  AS est_cost_usd,
    countIf(provider_input_tokens IS NULL)                         AS spans_filled_by_udf,
    count()                                                        AS spans
FROM llm_span_tokens
GROUP BY day, feature
ORDER BY day DESC, est_cost_usd DESC;

-- Q2. How much of each feature's input spend is the system prompt?
--     (Static text sent on every call: the first thing to cache.)
SELECT
    feature,
    sum(system_tokens)                                              AS sys_tokens,
    sum(system_tokens + context_tokens + user_tokens)               AS input_tokens,
    round(sys_tokens / input_tokens * 100, 1)                       AS system_pct,
    round(sum(system_tokens
              * (dictGet('model_prices_dict', 'input_cost_per_token', model)
                 - dictGet('model_prices_dict', 'cache_read_input_token_cost', model))), 2)
                                                                    AS usd_saved_if_cached
FROM llm_span_tokens
WHERE ts >= now() - INTERVAL 7 DAY
GROUP BY feature
ORDER BY usd_saved_if_cached DESC;

-- Q3. Context bloat: is the retrieval layer sending more than it used to?
SELECT
    toStartOfDay(ts)                            AS day,
    feature,
    quantile(0.5)(context_tokens)               AS p50_context_tokens,
    quantile(0.95)(context_tokens)              AS p95_context_tokens,
    round(avg(context_tokens > 2000) * 100, 1)  AS pct_over_2k
FROM llm_span_tokens
WHERE feature != 'summarizer'
GROUP BY day, feature
ORDER BY day, feature;

-- Q4. Sanity check: where the provider did report usage, how far off are we?
--     The gap is the chat-template overhead (role markers etc.), not tokenizer error.
SELECT
    model,
    count()                                                               AS spans,
    quantile(0.5)(provider_input_tokens - (system_tokens + context_tokens + user_tokens))  AS p50_gap,
    quantile(0.99)(provider_input_tokens - (system_tokens + context_tokens + user_tokens)) AS p99_gap
FROM llm_span_tokens
WHERE provider_input_tokens IS NOT NULL
GROUP BY model
ORDER BY spans DESC;

-- Q5. Dashboards hit this one every 30 seconds. Because count_tokens is marked
--     deterministic, the query cache is allowed to serve it. (The date is a
--     literal on purpose: today()/now() are themselves non-deterministic.)
SELECT
    feature,
    sum(count_tokens(model, system_prompt)) AS system_tokens
FROM llm_spans
WHERE toDate(ts) = '2026-10-01'
GROUP BY feature
SETTINGS use_query_cache = 1;

-- Q5b. Did the cache actually serve it? Run Q5 twice, then:
SELECT
    query_duration_ms,
    ProfileEvents['QueryCacheHits']                            AS QueryCacheHits,
    ProfileEvents['QueryCacheMisses']                          AS QueryCacheMisses,
    ProfileEvents['ExecutableUserDefinedFunctionInvocations']  AS udf_invocations
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE '%sum(count_tokens(model, system_prompt))%'
  AND query NOT LIKE '%query_log%'
ORDER BY event_time_microseconds;

-- Q6. Eval results, by feature and model.
SELECT
    feature,
    model,
    count()                                      AS judged,
    round(avg(score), 2)                         AS avg_score,
    round(countIf(verdict = 'fail') / judged * 100, 1) AS fail_pct
FROM llm_evals
WHERE verdict != 'error'
GROUP BY feature, model
ORDER BY fail_pct DESC;

-- Q7. What did the UDF cost us? Per-query UDF accounting from the new ProfileEvents
--     (ClickHouse 26.6+). Wall time, pool wait, CPU, bytes over the pipe.
SELECT
    event_time,
    query_duration_ms,
    ProfileEvents['ExecutableUserDefinedFunctionInvocations']                AS udf_invocations,
    round(ProfileEvents['ExecutableUserDefinedFunctionElapsedMicroseconds'] / 1e6, 2)   AS udf_wall_s,
    round(ProfileEvents['ExecutableUserDefinedFunctionPoolWaitMicroseconds'] / 1e6, 2)  AS udf_pool_wait_s,
    round((ProfileEvents['ExecutableUserDefinedFunctionUserTimeMicroseconds']
         + ProfileEvents['ExecutableUserDefinedFunctionSystemTimeMicroseconds']) / 1e6, 2) AS udf_cpu_s,
    formatReadableSize(ProfileEvents['ExecutableUserDefinedFunctionInputBytes'])  AS udf_in,
    formatReadableSize(ProfileEvents['ExecutableUserDefinedFunctionOutputBytes']) AS udf_out
FROM system.query_log
WHERE type = 'QueryFinish'
  AND ProfileEvents['ExecutableUserDefinedFunctionInvocations'] > 0
ORDER BY event_time DESC
LIMIT 10;

-- Q7b. The language comparison in the post. Run the MV's workload once per implementation:
--   SELECT count(), sum(count_tokens_rs(model, system_prompt) + count_tokens_rs(model, retrieved_context)
--                     + count_tokens_rs(model, user_prompt) + count_tokens_rs(model, completion)) AS rs_tokens
--   FROM llm_spans SETTINGS max_threads = 4;
--   (same for count_tokens_py -> py_tokens, count_tokens -> go_tokens)
-- then compare them from query_log:
SELECT
    extract(query, 'AS (\\w+)_tokens')                                            AS impl,
    query_duration_ms,
    ProfileEvents['ExecutableUserDefinedFunctionInvocations']                     AS invocations,
    round(ProfileEvents['ExecutableUserDefinedFunctionElapsedMicroseconds'] / 1e6, 2) AS udf_wall_s,
    round((ProfileEvents['ExecutableUserDefinedFunctionUserTimeMicroseconds']
         + ProfileEvents['ExecutableUserDefinedFunctionSystemTimeMicroseconds']) / 1e6, 2) AS udf_cpu_s,
    formatReadableSize(ProfileEvents['ExecutableUserDefinedFunctionInputBytes'])  AS udf_in
FROM system.query_log
WHERE type = 'QueryFinish' AND ProfileEvents['ExecutableUserDefinedFunctionInvocations'] > 0
ORDER BY event_time_microseconds;

-- Q8. How much memory are the UDF pool processes holding right now, across the service?
SELECT
    metric,
    if(metric LIKE '%Bytes', formatReadableSize(value), toString(value)) AS value
FROM system.asynchronous_metrics
WHERE metric IN ('ExecutableUserDefinedFunctionMemoryResidentBytes', 'ExecutableUserDefinedFunctionProcesses');
