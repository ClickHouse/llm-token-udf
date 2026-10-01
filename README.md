# llm-token-udf

Companion code for the "Executable UDFs are now generally available on ClickHouse Cloud" post.
Token accounting and quality evals for LLM traces, done inside ClickHouse with two executable UDFs.

```
llm-token-udf/
├── udf/
│   ├── count_tokens_rs/   # Native runtime UDF (Rust, tiktoken-rs). The one used in the post.
│   ├── count_tokens/      # Same UDF in Go (pure-Go tokenizer). Kept for the language comparison.
│   ├── count_tokens_py/   # Same UDF in Python (tiktoken). Kept for the language comparison.
│   └── judge_response/    # Network-enabled Python UDF: LLM-as-judge via Anthropic tool-use.
├── sql/
│   ├── 01_schema.sql      # llm_spans source table
│   ├── 02_token_mv.sql    # llm_span_tokens + the MV that calls count_tokens() at insert time
│   ├── 03_prices.sql      # model_prices via url() + refreshable MV + dictionary
│   ├── 04_evals.sql       # llm_evals + refreshable MV that samples and judges completions
│   └── 05_queries.sql     # cost attribution, caching savings, context bloat, ProfileEvents, ...
├── terraform/
│   └── main.tf            # clickhouse_udf + dev (follows latest) / prod (pinned) attachments
└── local/                 # XML function config + wrapper for running against OSS ClickHouse
```

## count_tokens (Native runtime, Rust)

`count_tokens(model String, text String) -> UInt32`

Build static binaries for both architectures and package them:

```bash
rustup target add x86_64-unknown-linux-musl aarch64-unknown-linux-musl
cd udf/count_tokens_rs && ./build.sh      # -> count_tokens.zip
```

Cloud settings: type `executable_pool`, runtime `Native`, format `RowBinary`, send chunk header on,
deterministic on, pool size 4. Arguments `model String`, `text String`; return type `UInt32`.

## judge_response (Python, network access)

`judge_response(prompt String, completion String) -> Tuple(UInt8, String, String)`

```bash
cd udf/judge_response
cp config.example.json config.json       # put your Anthropic API key in here
zip judge_response.zip main.py requirements.txt config.json
```

Cloud settings: type `executable_pool`, runtime `python3.11`, format `JSONEachRow`, network access on,
pool size 4, max command execution time 30s. Arguments `prompt String`, `completion String`;
return type `Tuple(UInt8, String, String)`.

## Running the SQL

```
:run sql/01_schema.sql
:run sql/02_token_mv.sql
:run sql/03_prices.sql
:run sql/04_evals.sql
```

Then insert into `llm_spans` and query `llm_span_tokens`, `llm_evals`, and `system.query_log`
as in `sql/05_queries.sql`.

## Testing locally without Cloud

Everything here also runs against open-source ClickHouse via an XML function config, which is how
the numbers in the post were produced. `local/udf_functions.xml` has the function definitions and
the steps; `local/count_tokens.sh` is the wrapper that gives the binary a working directory with
`models.json` in it.

## Prebuilt binaries

`udf/count_tokens_rs/count_tokens.zip` is committed so you can upload it without a Rust toolchain
(statically linked, linux/amd64 + linux/arm64). Rebuild with `build.sh` if you change the source.

## License

Apache 2.0, see `LICENSE`.
