#!/usr/bin/env python3
"""judge_response — a network-enabled ClickHouse Cloud executable UDF (Python).

Deploy as: type = executable_pool, runtime = python3.11, format = JSONEachRow,
network access = enabled, deterministic = false (it calls an LLM).

Arguments: (prompt String, completion String) -> Tuple(UInt8, String, String)
Returns (score 1-5, verdict in {pass, partial, fail}, one-sentence reason).

The verdict is constrained with Anthropic tool-use: the model must call a tool
whose input_schema has an enum on `verdict` and an integer range on `score`, so
the output is always parseable. No prose parsing.

JSONEachRow in, JSONEachRow out. One JSON object per line:
  stdin : {"prompt": "...", "completion": "..."}
  stdout: {"result": [4, "pass", "Answers the question and cites the policy."]}
"""
import hashlib
import json
import os
import sys
import time
from collections import OrderedDict

import requests

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# No secrets manager for UDFs yet, so the key ships in a config file inside the
# zip rather than in SQL. (Env var override is for local testing only.)
def _load_config() -> dict:
    try:
        with open(os.path.join(BASE_DIR, "config.json")) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}

CONFIG = _load_config()
API_KEY = os.environ.get("ANTHROPIC_API_KEY") or CONFIG.get("anthropic_api_key", "")
MODEL = os.environ.get("ANTHROPIC_MODEL") or CONFIG.get("model", "claude-haiku-4-5")
API_URL = os.environ.get("ANTHROPIC_API_URL") or "https://api.anthropic.com/v1/messages"

SESSION = requests.Session()  # keeps the HTTPS connection alive for the life of the pool process

VERDICTS = ["pass", "partial", "fail"]

JUDGE_TOOL = {
    "name": "report_verdict",
    "description": "Grade how well the completion answers the prompt.",
    "input_schema": {
        "type": "object",
        "properties": {
            "score": {"type": "integer", "minimum": 1, "maximum": 5,
                      "description": "5 = fully correct and helpful, 1 = wrong or harmful."},
            "verdict": {"type": "string", "enum": VERDICTS},
            "reason": {"type": "string", "maxLength": 200,
                       "description": "One sentence. Name the specific gap if any."},
        },
        "required": ["score", "verdict", "reason"],
    },
}

SYSTEM_PROMPT = (
    "You are grading an AI assistant's answer. You get the user's prompt and the "
    "assistant's completion. Judge correctness, completeness and whether it actually "
    "addresses what was asked. Call report_verdict exactly once. Be strict: a "
    "confident answer to the wrong question is a fail."
)

# Per-process LRU so re-judging the same (prompt, completion) is free.
_CACHE: "OrderedDict[str, tuple]" = OrderedDict()
_CACHE_MAX = 2048


def _cache_key(prompt: str, completion: str) -> str:
    h = hashlib.sha256()
    h.update(prompt.encode()); h.update(b"\x00"); h.update(completion.encode())
    return h.hexdigest()


def _call_anthropic(prompt: str, completion: str) -> tuple:
    body = {
        "model": MODEL,
        "max_tokens": 300,
        "system": SYSTEM_PROMPT,
        "tools": [JUDGE_TOOL],
        "tool_choice": {"type": "tool", "name": "report_verdict"},
        "messages": [{"role": "user", "content":
            f"<prompt>\n{prompt[:6000]}\n</prompt>\n<completion>\n{completion[:6000]}\n</completion>"}],
    }
    headers = {"x-api-key": API_KEY, "anthropic-version": "2023-06-01",
               "content-type": "application/json"}
    delay = 1.0
    for attempt in range(4):
        r = SESSION.post(API_URL, headers=headers, json=body, timeout=20)
        if r.status_code in (429, 529) and attempt < 3:  # rate limited / overloaded
            time.sleep(delay); delay *= 2
            continue
        r.raise_for_status()
        for block in r.json().get("content", []):
            if block.get("type") == "tool_use" and block.get("name") == "report_verdict":
                inp = block["input"]
                score = min(5, max(1, int(inp.get("score", 1))))
                verdict = inp.get("verdict") if inp.get("verdict") in VERDICTS else "fail"
                return (score, verdict, str(inp.get("reason", ""))[:200])
        return (0, "error", "model returned no tool call")
    return (0, "error", "rate limited")


def judge(prompt: str, completion: str) -> tuple:
    if not API_KEY:
        return (0, "error", "no API key configured")
    key = _cache_key(prompt, completion)
    if key in _CACHE:
        _CACHE.move_to_end(key)
        return _CACHE[key]
    try:
        result = _call_anthropic(prompt, completion)
    except Exception as e:  # fail soft: one bad call shouldn't kill the query
        result = (0, "error", f"{type(e).__name__}: {str(e)[:150]}")
    _CACHE[key] = result
    if len(_CACHE) > _CACHE_MAX:
        _CACHE.popitem(last=False)
    return result


def main() -> None:
    for line in sys.stdin:                       # JSONEachRow in ...
        if not line.strip():
            continue
        row = json.loads(line)
        score, verdict, reason = judge(row["prompt"], row["completion"])
        sys.stdout.write(json.dumps({"result": [score, verdict, reason]}) + "\n")   # ... JSONEachRow out
        sys.stdout.flush()


if __name__ == "__main__":
    main()
