    APP_NAME ?= surveycto-hedera-proof
    IMAGE    ?= $(APP_NAME):local
    PORT     ?= 8080

    # Hedera configuration can be provided via environment variables or a .env file.
    # Example .env is provided as .env.example

    .PHONY: tidy build run docker-build docker-run docker-stop clean test up down verify

    tidy:
    	go mod tidy

    build:
    	CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/server .

    run: tidy
    	HEDERA_NETWORK=$${HEDERA_NETWORK:-testnet} \
	OPERATOR_ID=$${OPERATOR_ID} \
	OPERATOR_KEY=$${OPERATOR_KEY} \
	TOPIC_ID=$${TOPIC_ID} \
	go run .

    docker-build:
    	docker build -t $(IMAGE) .

    docker-run:
    	docker run --rm -p $(PORT):8080 \
	-e HEDERA_NETWORK=$${HEDERA_NETWORK:-testnet} \
	-e OPERATOR_ID=$${OPERATOR_ID} \
	-e OPERATOR_KEY=$${OPERATOR_KEY} \
	-e TOPIC_ID=$${TOPIC_ID} \
	$(IMAGE)

    docker-stop:
    	-docker stop $(APP_NAME)_ctr || true
    	-docker rm $(APP_NAME)_ctr || true

    test: docker-build docker-run
    	@echo "Waiting for container to be ready..."
    	@sleep 5
    	./test.sh
    	$(MAKE) docker-stop

    up: docker-build docker-stop
    	@echo "Starting container with .env (if present)"
    	docker run --rm -d --name $(APP_NAME)_ctr --env-file .env -p $(PORT):8080 $(IMAGE)
    	@echo "Container running at http://localhost:$(PORT)"

    down: docker-stop
    	@echo "Container stopped and removed."

    verify:
    	@echo "Building verifier..."
    	go build -o bin/verify verify.go
    	@echo "Run the verifier with your own arguments, e.g.:"
    	@echo "./bin/verify -data sample.json -topic-id 0.0.1234567 -network testnet"

    clean:
    	rm -rf bin
