#!/usr/bin/env python3
"""Expose Dart JSON test failures in GitHub check annotations."""
import json
import sys

tests = {}
with open(sys.argv[1], encoding="utf-8") as report:
    for line in report:
        event = json.loads(line)
        if event["type"] == "testStart":
            test = event["test"]
            tests[test["id"]] = test["name"]
        elif event["type"] == "error":
            name = tests.get(event.get("testID"), "Test runner")
            message = f"{name}\n{event['error']}\n{event.get('stackTrace', '')}"[:3000]
            escaped = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error title=Dart test failure::{escaped}")
