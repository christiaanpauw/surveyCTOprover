
# SurveyCTO → Hedera Consensus: Proof-of-Integrity Pipeline (Go Edition)

This document shows how to build a minimal, production-minded pipeline that hashes each SurveyCTO submission deterministically and immutably timestamps that hash on a Hedera Consensus Service (HCS) topic. It includes a clear threat model, hashing spec, Go server code, and a verification utility.

---

## 1) What this proves (and doesn’t)

**Proves:** Integrity + timestamping. If you recompute the exact same hash from the same record, and that hash exists on your HCS topic with a consensus timestamp, you have strong evidence the record hasn’t changed since that time.

**Doesn’t prove:** Who captured the data, whether the data is “true,” or availability (someone can still delete a local copy).

**Trust assumptions:** You trust your own deterministic hashing rules and the finality properties of Hedera’s consensus.

---

## 2) High-level architecture

1. **Receive submissions from SurveyCTO** via webhook (data publishing) or API pull. Webhook push is simplest.
2. **Canonicalize + hash the record.** Use a stable JSON encoding and incorporate attachments (Merkle).
3. **Submit the hash to a Hedera Consensus topic.**
4. **Persist an audit trail** locally: `{recordId, recordHashHex, transactionId, consensusTimestamp, sequenceNumber}`.
5. **Verification tool** recomputes the hash and confirms it appears on the topic with the expected metadata/timestamp.

---

## 3) Deterministic hashing spec (canonicalization)

To ensure “same logical data → same hash,” adopt and document strict rules. The following conservative rules are used in the Go code below.

### 3.1 Canonical JSON rules

- **Encoding:** UTF-8.
- **Key ordering:** Sort **all** JSON object keys lexicographically at every level.
- **Arrays:** Preserve element order exactly as received.
- **Whitespace:** None beyond what JSON requires.
- **Numbers:** Use Go’s `encoding/json` default numeric formatting by marshaling from well-typed values. (When ingesting arbitrary JSON, it will often decode into `float64`. The canonicalizer in this doc normalizes numbers to a minimal JSON representation.)  
- **Newlines:** None inside JSON (standard JSON).

Implementation: recursively walk the payload, sort object keys, and build a JSON string deterministically.

### 3.2 Field selection

- Canonicalize and hash the **submission body** (the logical “data” payload) only. Exclude transport metadata (HTTP headers, gateway timestamps, etc.).
- If SurveyCTO adds wrapper metadata, extract the form payload cleanly (see the schema in the server code).

### 3.3 Attachments

- Compute `SHA-256` of each attachment’s raw bytes.
- Build a **Merkle root**:
  - Sort individual attachment hashes lexicographically (byte-wise).
  - If the level count is odd, duplicate the last hash to make a pair.
  - Parent = `SHA-256(left || right)`; continue until one root remains.
- If no attachments exist, use a **32‑byte zero** value as the attachment-root placeholder.

### 3.4 Final record hash

```
record_hash = SHA-256(
  canonical_json_bytes || attachments_merkle_root_bytes
)
```

Keep this exact structure even when no attachments are present (attachments root = zero bytes).

---

## 4) Hedera setup

1. Create a Hedera account (use **testnet** for development).
2. Create an HCS **topic** and note its ID (e.g., `0.0.1234567`).
3. Configure credentials via environment variables:
   - `HEDERA_NETWORK` = `testnet` or `mainnet`
   - `OPERATOR_ID` = your account ID (e.g., `0.0.12345`)
   - `OPERATOR_KEY` = your private key (e.g., `302e0201...`)
   - `TOPIC_ID` = your topic ID (e.g., `0.0.1234567`)

---

## 5) Go implementation (server)

A small HTTP server that receives SurveyCTO submissions, canonicalizes + hashes the record, posts to HCS, and returns an audit receipt.


### 5.1 `go.mod`

```go
module example.com/surveycto-hedera-proof

go 1.22

require (
    github.com/hashgraph/hedera-sdk-go/v2 v2.55.0 // or latest
)
```

### 5.2 Server (`main.go`)

```go
package main

import (
    "crypto/sha256"
    "encoding/base64"
    "encoding/json"
    "fmt"
    "log"
    "net/http"
    "os"
    "sort"
    "strings"
    "time"

    hedera "github.com/hashgraph/hedera-sdk-go/v2"
)

// ----- Config via environment variables -----

func mustEnv(key string) string {
    v := strings.TrimSpace(os.Getenv(key))
    if v == "" {
        log.Fatalf("missing required env var: %s", key)
    }
    return v
}

type Attachment struct {
    Filename      string `json:"filename"`
    ContentBase64 string `json:"contentBase64,omitempty"` // In production you may receive URLs instead
}

type Submission struct {
    FormID         string                 `json:"formId"`
    InstanceID     string                 `json:"instanceId"` // unique per submission
    SubmissionTime string                 `json:"submissionTime,omitempty"`
    Data           map[string]interface{} `json:"data"`
    Attachments    []Attachment           `json:"attachments,omitempty"`
}

// Canonical JSON: recursively sort map keys, render minimal JSON.
func canonicalJSONString(v interface{}) (string, error) {
    b, err := canonicalMarshal(v)
    if err != nil {
        return "", err
    }
    return string(b), nil
}

func canonicalMarshal(v interface{}) ([]byte, error) {
    switch x := v.(type) {
    case map[string]interface{}:
        // sort keys
        keys := make([]string, 0, len(x))
        for k := range x {
            keys = append(keys, k)
        }
        sort.Strings(keys)
        // build ordered map representation
        sb := &strings.Builder{}
        sb.WriteByte('{')
        for i, k := range keys {
            kb, _ := json.Marshal(k) // keys are strings; default encoding is fine
            sb.Write(kb)
            sb.WriteByte(':')
            vb, err := canonicalMarshal(x[k])
            if err != nil {
                return nil, err
            }
            sb.Write(vb)
            if i < len(keys)-1 {
                sb.WriteByte(',')
            }
        }
        sb.WriteByte('}')
        return []byte(sb.String()), nil

    case []interface{}:
        sb := &strings.Builder{}
        sb.WriteByte('[')
        for i := range x {
            vb, err := canonicalMarshal(x[i])
            if err != nil {
                return nil, err
            }
            sb.Write(vb)
            if i < len(x)-1 {
                sb.WriteByte(',')
            }
        }
        sb.WriteByte(']')
        return []byte(sb.String()), nil

    case string, float64, bool, nil:
        // Rely on encoding/json for stable scalar encoding
        return json.Marshal(x)

    default:
        // If you expect integers or other concrete types, ensure they are converted consistently.
        return json.Marshal(x)
    }
}

func sha256Bytes(b []byte) []byte {
    h := sha256.Sum256(b)
    return h[:]
}

func merkleRoot(hashes [][]byte) []byte {
    if len(hashes) == 0 {
        z := make([]byte, 32)
        return z
    }
    // sort lexicographically for determinism
    sort.Slice(hashes, func(i, j int) bool {
        return strings.Compare(string(hashes[i]), string(hashes[j])) < 0
    })

    level := hashes
    for len(level) > 1 {
        var next [][]byte
        for i := 0; i < len(level); i += 2 {
            left := level[i]
            right := left
            if i+1 < len(level) {
                right = level[i+1]
            }
            parent := sha256Bytes(append(left, right...))
            next = append(next, parent)
        }
        level = next
    }
    return level[0]
}

type HCSMessage struct {
    V              int    `json:"v"`
    FormID         string `json:"formId"`
    InstanceID     string `json:"instanceId"`
    HashAlg        string `json:"hashAlg"`
    Attachments    bool   `json:"attachments"`
    RecordHashHex  string `json:"recordHashHex"`
}

func main() {
    network := mustEnv("HEDERA_NETWORK") // "testnet" or "mainnet"
    operatorID := mustEnv("OPERATOR_ID")
    operatorKey := mustEnv("OPERATOR_KEY")
    topicIDStr := mustEnv("TOPIC_ID")
    port := os.Getenv("PORT")
    if port == "" {
        port = "8080"
    }

    // Hedera client
    client := hedera.ClientForName(network)
    accID, err := hedera.AccountIDFromString(operatorID)
    if err != nil {
        log.Fatalf("invalid OPERATOR_ID: %v", err)
    }
    privKey, err := hedera.PrivateKeyFromString(operatorKey)
    if err != nil {
        log.Fatalf("invalid OPERATOR_KEY: %v", err)
    }
    client.SetOperator(accID, privKey)

    topicID, err := hedera.TopicIDFromString(topicIDStr)
    if err != nil {
        log.Fatalf("invalid TOPIC_ID: %v", err)
    }

    // HTTP handler
    http.HandleFunc("/webhook/surveycto", func(w http.ResponseWriter, r *http.Request) {
        if r.Method != http.MethodPost {
            http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
            return
        }

        var sub Submission
        if err := json.NewDecoder(r.Body).Decode(&sub); err != nil {
            http.Error(w, "invalid JSON", http.StatusBadRequest)
            return
        }

        // Canonicalize submission Data
        canonical, err := canonicalJSONString(sub.Data)
        if err != nil {
            http.Error(w, "canonicalization failed", http.StatusBadRequest)
            return
        }
        dataHash := sha256Bytes([]byte(canonical))

        // Attachments merkle
        var attHashes [][]byte
        for _, a := range sub.Attachments {
            if a.ContentBase64 == "" {
                http.Error(w, "attachment missing contentBase64 in this flow", http.StatusBadRequest)
                return
            }
            raw, err := base64.StdEncoding.DecodeString(a.ContentBase64)
            if err != nil {
                http.Error(w, fmt.Sprintf("invalid base64 for %s", a.Filename), http.StatusBadRequest)
                return
            }
            attHashes = append(attHashes, sha256Bytes(raw))
        }
        attRoot := merkleRoot(attHashes)

        // Final record hash = H( dataHash || attRoot )
        recordHash := sha256Bytes(append(dataHash, attRoot...))
        recordHashHex := fmt.Sprintf("%x", recordHash)

        // Build compact message
        payload := HCSMessage{
            V:             1,
            FormID:        sub.FormID,
            InstanceID:    sub.InstanceID,
            HashAlg:       "sha-256",
            Attachments:   len(sub.Attachments) > 0,
            RecordHashHex: recordHashHex,
        }
        msgBytes, _ := json.Marshal(payload)

        // Submit to HCS
        tx, err := hedera.NewTopicMessageSubmitTransaction().
            SetTopicID(topicID).
            SetMessage(msgBytes).
            Execute(client)
        if err != nil {
            http.Error(w, "HCS submit failed: "+err.Error(), http.StatusBadGateway)
            return
        }

        receipt, err := tx.GetReceipt(client)
        if err != nil {
            http.Error(w, "HCS receipt failed: "+err.Error(), http.StatusBadGateway)
            return
        }

        // consensus timestamp + sequence number
        var consensus time.Time
        if receipt != nil && receipt.Timestamp != nil {
            consensus = *receipt.Timestamp
        }

        resp := map[string]interface{}{
            "ok":                 true,
            "topicId":            topicID.String(),
            "transactionId":      tx.TransactionID.String(),
            "consensusTimestamp": consensus,
            "sequenceNumber":     receipt.TopicSequenceNumber,
            "recordHashHex":      recordHashHex,
        }

        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(resp)
    })

    log.Printf("Listening on :%s", port)
    log.Fatal(http.ListenAndServe(":"+port, nil))
}
```

**Notes**

- In production, SurveyCTO often provides attachment URLs rather than base64; fetch bytes server‑side and hash streamingly.
- The message could be just the raw 32‑byte hash; we include JSON for easier discovery/indexing.
- Add persistence (SQL/NoSQL) where indicated to store the audit tuple.

---

## 6) Verification utility (Go)

Given a record (JSON `data` + attachments), recompute the canonical hash and confirm it appears on your topic. Below uses **TopicMessageQuery** to subscribe from a start time; you can also index locally during submission.

```go
package verify

import (
    "context"
    "encoding/json"
    "fmt"
    "time"

    hedera "github.com/hashgraph/hedera-sdk-go/v2"
)

type Proof struct {
    Found             bool
    ConsensusTime     time.Time
    SequenceNumber    uint64
    Message           map[string]interface{}
}

func FindHash(client *hedera.Client, topicID string, hex string, start *time.Time) (*Proof, error) {
    tid, err := hedera.TopicIDFromString(topicID)
    if err != nil {
        return nil, err
    }
    q := hedera.NewTopicMessageQuery().
        SetTopicID(tid)

    if start != nil {
        q.SetStartTime(*start)
    }

    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()

    var result *Proof
    _, err = q.Subscribe(ctx, client, func(msg hedera.TopicMessage) {
        var obj map[string]interface{}
        _ = json.Unmarshal(msg.Contents, &obj)
        if v, ok := obj["recordHashHex"].(string); ok && strings.EqualFold(v, hex) {
            result = &Proof{
                Found:          true,
                ConsensusTime:  msg.ConsensusTimestamp,
                SequenceNumber: msg.SequenceNumber,
                Message:        obj,
            }
            cancel() // stop after found
        }
    }, func(err error) {
        // handle subscription errors if needed
    })
    if err != nil {
        return nil, err
    }

    // Wait briefly for cancel to propagate (or add your own select/timeout)
    time.Sleep(250 * time.Millisecond)
    if result == nil {
        return &Proof{Found: false}, nil
    }
    return result, nil
}
```

For audits at scale, prefer storing `{recordHashHex → sequenceNumber}` at submission time and verifying a specific sequence via mirror REST APIs.

---

## 7) Operational guidance

- **Idempotency:** Use `instanceId` to dedupe and avoid reposting the same submission.
- **PII minimization:** Never publish raw data or PII on HCS. Publish only hashes and minimal metadata.
- **Key management:** Keep private keys in a KMS or restricted secret store. Rotate.
- **Backpressure & retries:** Queue incoming submissions and retry HCS on transient errors.
- **Clocks:** Record both local receive time and Hedera consensus time; the latter is authoritative for proofs.
- **Costs:** HCS messages are small and cheap; still, monitor usage and failures.

---

## 8) Backfill / batch mode

For historical exports (CSV/JSON + attachments), build a batch job that applies the **same canonicalization** and posts each record’s hash. You can embed an `exportedAt` timestamp in the message body for context (it does not affect the hash).

---

## 9) Auditor handover checklist

- Canonicalization spec (this section) + a small, public test corpus.
- `topicId` and a few known `sequenceNumber`s to verify.
- A deterministic verification tool (like the one above).
- Your DB export of `{recordId, recordHashHex, transactionId, consensusTimestamp, sequenceNumber}`.

---

## 10) Quick run

```bash
export HEDERA_NETWORK=testnet
export OPERATOR_ID=0.0.xxxxxx
export OPERATOR_KEY=302e020100300506032b657004220420...
export TOPIC_ID=0.0.yyyyyy
export PORT=8080

go mod tidy
go run .
```

Test with a minimal payload (no attachments):

```bash
curl -X POST http://localhost:8080/webhook/surveycto \
  -H "Content-Type: application/json" \
  -d '{
    "formId": "household_survey_v3",
    "instanceId": "uuid-1234",
    "data": {
      "hh_id": "ZA-0001",
      "head_name": "Jane Doe",
      "members": [ {"age": 29}, {"age": 7} ],
      "income": 1234.5
    }
  }'
```

You’ll receive `recordHashHex`, `transactionId`, `consensusTimestamp`, and `sequenceNumber` in response.

---

## 11) Variants & extensions

- **Client-side hashing** (inside the data-collection app) is possible, but server-side hashing is simpler and captures attachments uniformly.
- **Alternative message layout:** Submit the bare 32 bytes to HCS; store metadata only in your DB (saves a few bytes on-chain).
- **Multiple topics:** Per-form or per-project topics if you need isolation or different access controls.
- **Public discovery:** Publish a tiny index or API that maps `instanceId` → `recordHashHex` → `(topic, sequenceNumber)` for auditors.

---

**License:** MIT. Adapt freely.
