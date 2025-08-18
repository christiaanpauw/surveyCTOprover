# 🚀 Getting Started Guide — SurveyCTO → Hedera Proof-of-Integrity

This guide explains how to set up, run, and test the service that anchors SurveyCTO record hashes onto the Hedera Consensus Service (HCS).

---

## 1. Prerequisites

- **Go 1.22+** (if running locally without Docker)  
- **Docker + Docker Compose** (optional but recommended)  
- **Make** utility (to use the provided Makefile)  
- A **Hedera account** (create one at [portal.hedera.com](https://portal.hedera.com) for testnet)  
- A **Consensus Topic** created on Hedera, with its ID (e.g., `0.0.1234567`)  

---

## 2. Clone the project

```bash
git clone <your-repo-url>
cd surveycto-hedera-proof
```

---

## 3. Configure environment

Copy the example `.env` file and update it with your Hedera credentials:

```bash
cp .env.example .env
```

Edit `.env`:

```dotenv
HEDERA_NETWORK=testnet          # or "mainnet" later
OPERATOR_ID=0.0.xxxxxx          # your Hedera account ID
OPERATOR_KEY=302e0201...        # your private key
TOPIC_ID=0.0.yyyyyy             # your HCS topic ID
PORT=8080
```

---

## 4. Build & Run

### Option A: Run with Docker (recommended)

```bash
make up
```

- This builds the image and runs the container with environment variables from `.env`.
- The server is exposed at [http://localhost:8080](http://localhost:8080).  

Stop the container with:

```bash
make down
```

### Option B: Run locally with Go

```bash
make run
```

---

## 5. Test the setup

We provide a `test.sh` script that simulates a SurveyCTO submission.

```bash
make test
```

This will:
1. Build the image.  
2. Run the container in the background.  
3. Wait 5 seconds for it to start.  
4. Post a fake SurveyCTO submission.  
5. Validate the response fields (`ok`, `recordHashHex`, `sequenceNumber`, `consensusTimestamp`).  
6. Tear down the container.  

Expected output:

```json
Response:
{
  "ok": true,
  "topicId": "0.0.1234567",
  "transactionId": "...",
  "consensusTimestamp": "2025-08-18T10:10:10Z",
  "sequenceNumber": 42,
  "recordHashHex": "deadbeef..."
}
✅ Test passed: ok, hash, sequenceNumber, and consensusTimestamp look good.
```

---

## 6. Connect to SurveyCTO

- In SurveyCTO’s console, configure **Data publishing** (webhook) to point to your server:  

  ```
  https://<your-server>/webhook/surveycto
  ```

- Ensure SurveyCTO sends JSON submissions.  
- If attachments are included, configure SurveyCTO to send file URLs or base64 (the code supports base64; you can adapt for URL fetch).  

---

## 7. Verification of records

To prove a record is unaltered:

1. Take the raw SurveyCTO submission (JSON + attachments).  
2. Run the same **canonicalization + hashing procedure** (included in the Go code).  
3. Query the Hedera **topic messages** using either:  
   - The Go verification utility (`verify/` package), or  
   - Mirror node REST API (search for `recordHashHex`).  
4. Confirm that the hash appears with the expected timestamp and sequence number.  

---

## 8. Operational tips

- **Key safety:** never commit `.env` with real keys to Git.  
- **Logs:** pipe Docker logs to your monitoring system.  
- **Backfill:** you can hash old SurveyCTO exports and anchor them too.  
- **Production:** run on mainnet, behind TLS, and store your own database of `{recordId, recordHashHex, txId, timestamp, sequenceNumber}` for easy audit trails.  

---

## 9. Useful Makefile targets

- `make up` → run container with `.env`  
- `make down` → stop container  
- `make test` → spin up, test, tear down  
- `make run` → run locally (Go)  
- `make clean` → remove build artifacts  

---

✅ You’re now ready to prove SurveyCTO records are immutable via Hedera.  
