#!/usr/bin/env python3
"""count_tokens_py — the same UDF as count_tokens, in Python.

Exists only for the side-by-side comparison in the blog post. Same contract:
executable_pool, format RowBinary, send_chunk_header = true,
arguments (model String, text String) -> UInt32.
"""
import json
import os
import struct
import sys

import tiktoken

_ENCODERS = {}
_RULES = []

try:
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "models.json")) as f:
        _RULES = sorted(json.load(f), key=lambda r: -len(r["prefix"]))
except FileNotFoundError:
    pass


def encoder_for(model: str):
    enc_name = next((r["encoding"] for r in _RULES if model.startswith(r["prefix"])), None)
    if enc_name is None:
        try:
            return tiktoken.encoding_for_model(model)
        except KeyError:
            enc_name = "o200k_base"
    enc = _ENCODERS.get(enc_name)
    if enc is None:
        enc = _ENCODERS[enc_name] = tiktoken.get_encoding(enc_name)
    return enc


def read_uvarint(stream) -> int:
    shift, result = 0, 0
    while True:
        b = stream.read(1)
        if not b:
            raise EOFError
        byte = b[0]
        result |= (byte & 0x7F) << shift
        if byte < 0x80:
            return result
        shift += 7


def read_string(stream) -> str:
    n = read_uvarint(stream)
    return stream.read(n).decode("utf-8", errors="replace")


def main() -> None:
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
    pack = struct.Struct("<I").pack
    while True:
        header = stdin.readline()
        if not header:
            return
        rows = int(header)
        out = []
        for _ in range(rows):
            model = read_string(stdin)
            text = read_string(stdin)
            out.append(pack(len(encoder_for(model).encode_ordinary(text))))
        stdout.write(b"".join(out))
        stdout.flush()


if __name__ == "__main__":
    main()
