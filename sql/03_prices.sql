-- Model prices. Fetching a JSON file is a job for url(), not a UDF.
-- LiteLLM maintains a public price list; a refreshable MV re-pulls it daily.
CREATE TABLE model_prices
(
    model                        String,
    provider                     LowCardinality(String),
    input_cost_per_token         Float64,
    output_cost_per_token        Float64,
    cache_read_input_token_cost  Float64,
    updated_at                   DateTime
)
ENGINE = MergeTree
ORDER BY model;

CREATE MATERIALIZED VIEW model_prices_mv
REFRESH EVERY 1 DAY
TO model_prices
AS
SELECT
    kv.1                                                   AS model,
    JSONExtractString(kv.2, 'litellm_provider')            AS provider,
    JSONExtractFloat(kv.2, 'input_cost_per_token')         AS input_cost_per_token,
    JSONExtractFloat(kv.2, 'output_cost_per_token')        AS output_cost_per_token,
    JSONExtractFloat(kv.2, 'cache_read_input_token_cost')  AS cache_read_input_token_cost,
    now()                                                  AS updated_at
FROM
(
    SELECT arrayJoin(JSONExtractKeysAndValuesRaw(json)) AS kv
    FROM url('https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json',
             JSONAsString, 'json String')
)
WHERE JSONHas(kv.2, 'input_cost_per_token');

CREATE DICTIONARY model_prices_dict
(
    model                        String,
    input_cost_per_token         Float64,
    output_cost_per_token        Float64,
    cache_read_input_token_cost  Float64
)
PRIMARY KEY model
SOURCE(CLICKHOUSE(TABLE 'model_prices'))
LIFETIME(MIN 3600 MAX 7200)
LAYOUT(COMPLEX_KEY_HASHED());
