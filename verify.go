
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	hedera "github.com/hiero-ledger/hiero-sdk-go/v2"
)

// canonicalMarshal recursively sorts map keys and renders minimal JSON.
// It accepts typical decoded JSON types: map[string]interface{}, []interface{}, string, float64, bool, nil.
// If you have schema knowledge (ints vs floats), convert prior to calling for stricter numeric control.
func canonicalMarshal(v interface{}) ([]byte, error) {
	switch x := v.(type) {
	case map[string]interface{}:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		var b strings.Builder
		b.WriteByte('{')
		for i, k := range keys {
			kb, _ := json.Marshal(k)
			b.Write(kb)
			b.WriteByte(':')
			vb, err := canonicalMarshal(x[k])
			if err != nil {
				return nil, err
			}
			b.Write(vb)
			if i < len(keys)-1 {
				b.WriteByte(',')
			}
		}
		b.WriteByte('}')
		return []byte(b.String()), nil

	case []interface{}:
		var b strings.Builder
		b.WriteByte('[')
		for i := range x {
			vb, err := canonicalMarshal(x[i])
			if err != nil {
				return nil, err
			}
			b.Write(vb)
			if i < len(x)-1 {
				b.WriteByte(',')
			}
		}
		b.WriteByte(']')
		return []byte(b.String()), nil

	case string, float64, bool, nil:
		return json.Marshal(x)

	default:
		// Fallback to default JSON encoding for other concrete types
		return json.Marshal(x)
	}
}

func sha256Bytes(b []byte) []byte {
	h := sha256.Sum256(b)
	return h[:]
}

func merkleRoot(hashes [][]byte) []byte {
	if len(hashes) == 0 {
		return make([]byte, 32)
	}
	// copy and sort for determinism
	cp := make([][]byte, len(hashes))
	copy(cp, hashes)
	sort.Slice(cp, func(i, j int) bool {
		return strings.Compare(string(cp[i]), string(cp[j])) < 0
	})
	level := cp
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

func loadJSONFile(path string) (map[string]interface{}, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	dec := json.NewDecoder(f)
	dec.UseNumber() // preserve numbers; still render canonically later
	var m map[string]interface{}
	if err := dec.Decode(&m); err != nil {
		return nil, err
	}
	return m, nil
}

func readFileBytes(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(f)
}

func main() {
	var (
		dataPath   string
		attPaths   multiFlag
		network    string
		topicIDStr string
		startRFC3339 string
		timeoutSec int
		// Optional: operator credentials are NOT required for read-only queries; omit unless needed
	)

	flag.StringVar(&dataPath, "data", "", "Path to JSON file containing the logical submission data (required)")
	flag.Var(&attPaths, "att", "Attachment file path (repeatable). Example: -att photo.jpg -att audio.wav")
	flag.StringVar(&network, "network", "testnet", "Hedera network: testnet or mainnet")
	flag.StringVar(&topicIDStr, "topic-id", "", "Hedera Topic ID to search (e.g., 0.0.1234567). If empty, only prints the computed hash.")
	flag.StringVar(&startRFC3339, "start", "", "Optional start time (RFC3339) for topic search, e.g., 2025-08-18T00:00:00Z")
	flag.IntVar(&timeoutSec, "timeout", 30, "Seconds to wait for query subscription before giving up")
	flag.Parse()

	if dataPath == "" {
		fmt.Fprintln(os.Stderr, "Error: -data is required")
		flag.Usage()
		os.Exit(2)
	}

	// Load and canonicalize data JSON
	data, err := loadJSONFile(dataPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to read data JSON: %v\n", err)
		os.Exit(1)
	}
	canon, err := canonicalMarshal(data)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Canonicalization failed: %v\n", err)
		os.Exit(1)
	}
	dataHash := sha256Bytes(canon)

	// Hash attachments
	var attHashes [][]byte
	for _, p := range attPaths {
		b, err := readFileBytes(p)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to read attachment %s: %v\n", p, err)
			os.Exit(1)
		}
		attHashes = append(attHashes, sha256Bytes(b))
	}
	attRoot := merkleRoot(attHashes)

	// Final record hash
	recordHash := sha256Bytes(append(dataHash, attRoot...))
	recordHashHex := fmt.Sprintf("%x", recordHash)

	fmt.Printf("recordHashHex: %s\n", recordHashHex)
	fmt.Printf("dataPath: %s\n", filepath.Base(dataPath))
	if len(attPaths) > 0 {
		fmt.Printf("attachments: %d\n", len(attPaths))
	} else {
		fmt.Printf("attachments: 0 (using 32 zero bytes for Merkle root)\n")
	}

	// If no topic specified, stop here
	if topicIDStr == "" {
		return
	}

	// Prepare Hedera client for read-only query
	client := hedera.ClientForName(network)
	// No operator needed for mirror/topic query

	topicID, err := hedera.TopicIDFromString(topicIDStr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Invalid topic ID: %v\n", err)
		os.Exit(1)
	}

	q := hedera.NewTopicMessageQuery().
		SetTopicID(topicID)

	if startRFC3339 != "" {
		ts, err := time.Parse(time.RFC3339, startRFC3339)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Invalid -start time (RFC3339): %v\n", err)
			os.Exit(1)
		}
		q.SetStartTime(ts)
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSec)*time.Second)
	defer cancel()

	fmt.Printf("Searching topic %s on %s for recordHashHex...\n", topicIDStr, network)

	found := false
	_, err = q.Subscribe(ctx, client, func(msg hedera.TopicMessage) {
		// Messages could be raw bytes (hash only) or JSON with recordHashHex field.
		// Try to parse JSON; if that fails, compare direct hex of bytes.
		var obj map[string]interface{}
		if err := json.Unmarshal(msg.Contents, &obj); err == nil {
			if v, ok := obj["recordHashHex"].(string); ok && strings.EqualFold(v, recordHashHex) {
				fmt.Println("✅ Match found in JSON message")
				fmt.Printf("sequenceNumber: %d\n", msg.SequenceNumber)
				fmt.Printf("consensusTimestamp: %s\n", msg.ConsensusTimestamp.Format(time.RFC3339Nano))
				found = true
				cancel()
				return
			}
		}
		// Fallback: compare hex of raw bytes against our hash hex (for bare-hash postings)
		if strings.EqualFold(fmt.Sprintf("%x", msg.Contents), recordHashHex) {
			fmt.Println("✅ Match found (raw bytes)")
			fmt.Printf("sequenceNumber: %d\n", msg.SequenceNumber)
			fmt.Printf("consensusTimestamp: %s\n", msg.ConsensusTimestamp.Format(time.RFC3339Nano))
			found = true
			cancel()
			return
		}
	}, func(err error) {
		// subscription error
		if err != nil && ctx.Err() == nil {
			fmt.Fprintf(os.Stderr, "Subscription error: %v\n", err)
		}
	})
	if err != nil && ctx.Err() == nil {
		fmt.Fprintf(os.Stderr, "Subscribe failed: %v\n", err)
		os.Exit(1)
	}

	<-ctx.Done()
	if !found {
		fmt.Println("❌ No matching message found within the time window.")
		os.Exit(3)
	}
}

// multiFlag collects repeatable -att flags
type multiFlag []string

func (m *multiFlag) String() string {
	return strings.Join(*m, ",")
}
func (m *multiFlag) Set(v string) error {
	*m = append(*m, v)
	return nil
}
