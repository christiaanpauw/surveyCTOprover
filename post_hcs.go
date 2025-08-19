\
    // post_hcs.go
    // Minimal helper to submit a message (file) to Hedera Consensus Service.
    // Reads env: HEDERA_NETWORK, OPERATOR_ID, OPERATOR_KEY, TOPIC_ID
    package main

    import (
    	"encoding/json"
    	"flag"
    	"fmt"
    	"io/ioutil"
    	"log"
    	"os"

    	hedera "github.com/hashgraph/hedera-sdk-go/v2"
    )

    func mustEnv(key string) string {
    	v := os.Getenv(key)
    	if v == "" {
    		log.Fatalf("missing required env var %s", key)
    	}
    	return v
    }

    func main() {
    	file := flag.String("file", "", "Path to a file whose contents will be the HCS message (JSON recommended)")
    	flag.Parse()

    	if *file == "" {
    		log.Fatal("usage: post_hcs -file <path>")
    	}

    	msg, err := ioutil.ReadFile(*file)
    	if err != nil {
    		log.Fatalf("failed to read file: %v", err)
    	}

    	network := mustEnv("HEDERA_NETWORK") // "testnet" or "mainnet"
    	operatorID := mustEnv("OPERATOR_ID")
    	operatorKey := mustEnv("OPERATOR_KEY")
    	topicIDStr := mustEnv("TOPIC_ID")

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

    	tx, err := hedera.NewTopicMessageSubmitTransaction().
    		SetTopicID(topicID).
    		SetMessage(msg).
    		Execute(client)
    	if err != nil {
    		log.Fatalf("HCS submit failed: %v", err)
    	}

    	receipt, err := tx.GetReceipt(client)
    	if err != nil {
    		log.Fatalf("HCS receipt failed: %v", err)
    	}

    	out := map[string]interface{}{
    		"ok":              true,
    		"topicId":         topicID.String(),
    		"transactionId":   tx.TransactionID.String(),
    		"sequenceNumber":  receipt.TopicSequenceNumber,
    		"consensusTime":   receipt.Timestamp,
    	}
    	enc := json.NewEncoder(os.Stdout)
    	enc.SetIndent("", "  ")
    	_ = enc.Encode(out)
    	fmt.Fprintln(os.Stderr, "message submitted to HCS")
    }
