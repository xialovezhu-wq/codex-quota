#!/usr/bin/env python3
import json
import os
import sys
import time


audit_path = os.environ["CODEX_QUOTA_FAKE_AUDIT"]


def receive():
    line = sys.stdin.buffer.readline()
    if not line:
        raise EOFError
    message = json.loads(line)
    with open(audit_path, "a", encoding="utf-8") as audit:
        audit.write(message["method"] + "\n")
    return message


def fragmented_send(message):
    payload = (json.dumps(message, separators=(",", ":")) + "\n").encode()
    midpoint = max(1, len(payload) // 2)
    sys.stdout.buffer.write(payload[:midpoint])
    sys.stdout.buffer.flush()
    time.sleep(0.03)
    sys.stdout.buffer.write(payload[midpoint:])
    sys.stdout.buffer.flush()


try:
    initialize = receive()
    fragmented_send({"id": initialize["id"], "result": {"userAgent": "fake-app-server 1.0"}})
    receive()
    first_read = receive()
    sys.stdout.write(json.dumps({"method": "account/rateLimits/updated", "params": {}}) + "\n")
    sys.stdout.flush()
    fragmented_send({
        "id": first_read["id"],
        "result": {
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "primary": {"usedPercent": 70, "windowDurationMins": 300, "resetsAt": 1900000000},
                    "secondary": {"usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1900600000},
                },
                "spark": {"limitId": "spark"},
            }
        },
    })
    second_read = receive()
    fragmented_send({
        "id": second_read["id"],
        "result": {
            "rateLimits": {
                "limitId": "codex",
                "primary": {"usedPercent": 69, "windowDurationMins": 300, "resetsAt": 1900000000},
            }
        },
    })
except EOFError:
    pass
