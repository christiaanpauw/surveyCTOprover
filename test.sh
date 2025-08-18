#!/usr/bin/env bash
set -euo pipefail

URL="${URL:-http://localhost:8080/webhook/surveycto}"

# Post a minimal SurveyCTO-style payload and capture response JSON
RESP="$(curl -sS -X POST "$URL"       -H "Content-Type: application/json"       -d '{
    "formId": "household_survey_v3",
    "instanceId": "uuid-1234",
    "data": {
      "hh_id": "ZA-0001",
      "head_name": "Jane Doe",
      "members": [ {"age": 29}, {"age": 7} ],
      "income": 1234.5
    }
  }')"

echo "Response:"
echo "$RESP" | jq .

# Basic validations
OK=$(echo "$RESP" | jq -r '.ok // empty')
HASH=$(echo "$RESP" | jq -r '.recordHashHex // empty')
SEQ=$(echo "$RESP" | jq -r '.sequenceNumber // empty')
TS=$(echo "$RESP" | jq -r '.consensusTimestamp // empty')

if [[ "$OK" != "true" ]]; then
  echo "❌ Expected ok=true but got: $OK" >&2
  exit 1
fi

# Check SHA-256 hex format (64 hex chars)
if ! [[ "$HASH" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "❌ recordHashHex is missing or not a 64-char hex: $HASH" >&2
  exit 1
fi

# Sequence number should be a positive integer
if ! [[ "$SEQ" =~ ^[0-9]+$ ]] || [[ "$SEQ" -lt 1 ]]; then
  echo "❌ sequenceNumber invalid: $SEQ" >&2
  exit 1
fi

# Consensus timestamp should be non-empty
if [[ -z "$TS" || "$TS" == "null" ]]; then
  echo "❌ consensusTimestamp missing" >&2
  exit 1
fi

echo "✅ Test passed: ok, hash, sequenceNumber, and consensusTimestamp look good."
