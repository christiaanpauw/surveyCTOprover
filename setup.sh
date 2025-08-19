#!/usr/bin/env bash
# Setup script for SurveyCTO -> Hedera Proof pipeline.
# Copies env.example to .env and optionally installs Go dependencies.

set -euo pipefail

ENV_FILE=".env"
EXAMPLE_FILE="env.example"

if [ -f "$ENV_FILE" ]; then
  echo "$ENV_FILE already exists. Skipping copy."
else
  if [ -f "$EXAMPLE_FILE" ]; then
    cp "$EXAMPLE_FILE" "$ENV_FILE"
    echo "Created $ENV_FILE from $EXAMPLE_FILE. Please edit it with your Hedera credentials."
  else
    echo "Example environment file $EXAMPLE_FILE not found."
  fi
fi

if [ -f "go.mod" ]; then
  echo "Running go mod tidy to ensure dependencies are installed..."
  go mod tidy
else
  echo "No go.mod file found, skipping Go dependency installation."
fi

echo "Environment setup complete."
