# 🔍 Go CLI Verifier — Usage Guide

This document explains how to use the provided `verify.go` tool to independently recompute record hashes and verify their presence on the Hedera Consensus Service (HCS).

---

## 1. Setup

Ensure you have **Go 1.22+** installed.

Clone your project repository and place `verify.go` in the root (where your `go.mod` lives).

Confirm your `go.mod` includes the Hedera SDK dependency:

```go
require github.com/hashgraph/hedera-sdk-go/v2 v2.55.0
```

Then tidy dependencies:

```bash
go mod tidy
```

---

## 2. Build the verifier

```bash
go build -o bin/verify verify.go
```

This produces the binary `bin/verify`.

---

## 3. Usage

### 3.1 Compute record hash only (offline)

You can recompute the hash locally without contacting Hedera:

```bash
./bin/verify -data path/to/data.json   -att path/to/photo.jpg   -att path/to/audio.mp3
```

Output example:

```
recordHashHex: 4a8b3d4e9f8b1c9a7e2d19c3c8f7b6a5e4d3c2b1a0987654321fedcba9876543
dataPath: data.json
attachments: 2
```

### 3.2 Compute and verify on Hedera

To check that the computed hash was posted to a topic:

```bash
./bin/verify   -data path/to/data.json   -att path/to/photo.jpg   -topic-id 0.0.1234567   -network testnet   -start 2025-08-01T00:00:00Z   -timeout 60
```

- `-topic-id` = your Hedera Consensus Topic ID  
- `-network` = `testnet` or `mainnet`  
- `-start` = optional RFC3339 timestamp to begin searching from  
- `-timeout` = how long (in seconds) to wait for messages (default: 30s)  

Output example:

```
recordHashHex: 4a8b3d4e9f8b1c9a7e2d19c3c8f7b6a5e4d3c2b1a0987654321fedcba9876543
dataPath: data.json
attachments: 2
Searching topic 0.0.1234567 on testnet for recordHashHex...
✅ Match found in JSON message
sequenceNumber: 42
consensusTimestamp: 2025-08-18T10:10:10.123456Z
```

If your project posts bare hashes instead of JSON messages, the tool will also detect those.

---

## 4. Exit codes

- `0` → Success, hash found  
- `2` → Invalid usage (e.g., missing -data)  
- `3` → Hash not found within the given time window  
- Non-zero → Other error (file not found, invalid JSON, etc.)  

---

## 5. Practical tips

- For large topics, always supply a `-start` date to limit the search window.  
- Verification can be automated in CI pipelines or audit scripts.  
- Auditors only need the raw record files + Topic ID + this tool.  

---

✅ With `verify.go`, anyone can independently prove SurveyCTO records were anchored to Hedera and remain unaltered.
