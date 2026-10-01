terraform {
  required_providers {
    clickhouse = {
      source  = "ClickHouse/clickhouse"
      version = ">= 3.24.0" # UDF resources landed in 3.24.0
    }
  }
}

variable "dev_service_id" { type = string }
variable "prod_service_id" { type = string }

# Pin production explicitly. Bump this when you've validated a build on dev.
variable "count_tokens_prod_version" { type = number }

# The function itself. A new ZIP hash publishes a new version and waits for the build.
# NB: `deterministic` and the memory limit are not in the provider schema yet; set those
# in the console or via the Cloud API after the first apply.
resource "clickhouse_udf" "count_tokens" {
  function_name = "count_tokens"
  runtime       = "native"
  type          = "executable_pool"
  format        = "RowBinary"
  return_type   = "UInt32"

  arguments = [
    { name = "model", type = "String" },
    { name = "text", type = "String" },
  ]

  pool_size                  = 4
  send_chunk_header          = true
  max_command_execution_time = 10

  source_archive_path = "${path.module}/../udf/count_tokens_rs/count_tokens.zip"
  source_archive_hash = filebase64sha256("${path.module}/../udf/count_tokens_rs/count_tokens.zip")
}

# Dev follows every successful build.
resource "clickhouse_udf_attachment" "dev" {
  function_name = clickhouse_udf.count_tokens.function_name
  service_id    = var.dev_service_id
  version       = clickhouse_udf.count_tokens.version
}

# Prod stays where you pinned it.
resource "clickhouse_udf_attachment" "prod" {
  function_name = clickhouse_udf.count_tokens.function_name
  service_id    = var.prod_service_id
  version       = var.count_tokens_prod_version
}
