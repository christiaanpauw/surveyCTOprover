# 🕵️ Auditor’s Verification Guide — SurveyCTO Record Integrity on Hedera

This guide explains how an independent auditor can verify that a SurveyCTO record has not been tampered with, using only the record files (JSON + attachments) and Hedera Consensus Service (HCS) data.

---

## 1. What you need

- The raw **SurveyCTO submission data** (JSON export or API pull).  
- Any associated **attachments** (images, audio, etc.) if relevant.  
- The **Hedera Topic ID** used by the project (e.g., `0.0.1234567`).  
- A **mirror node endpoint** (public or hosted). Hedera provides free access:  
  - Testnet: [https://testnet.mirrornode.hedera.com/api/v1](https://testnet.mirrornode.hedera.com/api/v1)  
  - Mainnet: [https://mainnet-public.mirrornode.hedera.com/api/v1](https://mainnet-public.mirrornode.hedera.com/api/v1)

---

## 2. Recompute the canonical record hash

The project uses deterministic hashing with these rules:

1. **Canonicalize JSON data**  
   - UTF-8 encoding  
   - Sort all object keys lexicographically  
   - Arrays keep their given order  
   - No extra whitespace  
   - Numbers serialized consistently (e.g., `1234.5`, not `1234.500`)  

2. **Hash the canonical JSON**  
   ```
   dataHash = SHA-256(canonical_json_bytes)
   ```

3. **Hash attachments**  
   - Compute `SHA-256` of each file’s raw bytes.  
   - Build a Merkle tree of all attachment hashes (sorted lex order).  
   - If no attachments, use 32 zero bytes.  
   ```
   attRoot = MerkleRoot(attachment_hashes)
   ```

4. **Final record hash**  
   ```
   recordHash = SHA-256(dataHash || attRoot)
   ```

The output is a 64-character lowercase hex string (SHA-256).

---

## 3. Query Hedera for the record hash

Use the mirror node API to search for messages containing the hash.

Example (testnet, curl):

```bash
HASH=deadbeef...   # 64-char recordHashHex
TOPIC_ID=0.0.1234567

curl "https://testnet.mirrornode.hedera.com/api/v1/topics/${TOPIC_ID}/messages?limit=100&order=desc" | jq .
```

Look through the returned messages for your `recordHashHex`.  

Alternatively, search all messages for the topic and grep:

```bash
curl -s "https://testnet.mirrornode.hedera.com/api/v1/topics/${TOPIC_ID}/messages?limit=100&order=desc" | jq -r '.messages[].message' | base64 -d | grep "$HASH"
```

---

## 4. What to check

1. **Presence**: The exact `recordHashHex` is present in the topic messages.  
2. **Metadata**: The message JSON should also include:  
   - `formId`  
   - `instanceId`  
   - `hashAlg: sha-256`  
   - `attachments: true/false`  
3. **Timestamp**: Each message has a `consensus_timestamp` assigned by Hedera.  
   - Verify this timestamp is on/after the claimed submission time.  
4. **Sequence number**: A monotonic index of messages within the topic.  

---

## 5. Example successful verification

- **Record hash recomputed locally:**  
  ```
  4a8b3d4e9f8b1c9a7e2d19c3c8f7b6a5e4d3c2b1a0987654321fedcba9876543
  ```

- **Mirror node message (truncated):**  

```json
{
  "consensus_timestamp": "2025-08-18T10:10:10.123456Z",
  "sequence_number": 42,
  "message": "eyJ2IjoxLCJmb3JtSWQiOiJob3VzZWhvbGRfc3VydmV5X3YzIiwiaW5zdGFuY2VJZCI6InV1aWQtMTIzNCIsImhhc2hBbGciOiJzaGEtMjU2IiwiYXR0YWNobWVudHMiOmZhbHNlLCJyZWNvcmRIYXNoSGV4IjoiNGE4YjNkNGU5ZjhiMWM5YTdlMmQxOWMzYzhmN2I2YTVlNGQzYzJiMWEwOTg3NjU0MzIxZmVkY2JhOTg3NjU0MyJ9"
}
```

- Decode the `message` (base64): it contains JSON with the same `recordHashHex`.  

---

## 6. Tools for auditors

- **Go verifier utility** (provided in the repo) can automate recomputation and lookup.  
- **Command-line**: use `jq`, `base64`, and `curl` as shown above.  
- **Mirror explorer UI**: [https://hashscan.io/](https://hashscan.io/) can be used to browse topic messages by ID.

---

## 7. Trust assumptions

- If the hash matches, the record has not been modified since the Hedera consensus timestamp.  
- Integrity is proven, but correctness and authenticity of data collection are outside scope.  

---

✅ With this process, auditors can independently confirm that SurveyCTO records remain untampered and timestamped on Hedera.
