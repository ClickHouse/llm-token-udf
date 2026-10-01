#!/bin/sh
# Local-testing wrapper: run the binary with the script directory as the working
# directory so models.json is found, mirroring the Cloud Native runtime where data
# files sit next to the binary in the working directory.
cd "$(dirname "$0")" && exec ./count_tokens_main
