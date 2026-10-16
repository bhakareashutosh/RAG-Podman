#!/usr/bin/env bash
# Creates a session and asks the agent a question through the ADK API server.
set -euo pipefail
URL=${URL:-http://localhost:8080}
Q=${1:-"How many days of annual leave do I get, and how many can I carry forward?"}
SID="s-$(date +%s)"

curl -s -X POST "$URL/apps/rag_agent/users/u1/sessions/$SID" \
  -H "Content-Type: application/json" -d '{}' > /dev/null

curl -s -X POST "$URL/run" -H "Content-Type: application/json" -d @- <<JSON | python3 -c 'import json,sys
for ev in json.load(sys.stdin):
    for p in (ev.get("content") or {}).get("parts", []):
        if p.get("text"): print(p["text"])'
{"app_name": "rag_agent", "user_id": "u1", "session_id": "$SID",
 "new_message": {"role": "user", "parts": [{"text": "$Q"}]}}
JSON
