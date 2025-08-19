#!/usr/bin/env bash
# attested-run.sh
# Run a Docker container by immutable digest, verify signature with cosign,
# produce a signed run-attestation JSON, and post the attestation hash to Hedera.
#
# Usage:
#   ./attested-run.sh [DOCKER_FLAGS ...] -- IMAGE@sha256:<digest> [CMD ARGS ...]
#
# Examples:
#   ./attested-run.sh -e FOO=bar -v /data:/data -- ghcr.io/acme/app@sha256:ABCD... --serve --port 8080
#
# Requirements: docker, jq, cosign, and bin/post_hcs (built via `make post-hcs-build`).
#
set -euo pipefail

# Load variables from .env without overriding existing environment
if [[ -f .env ]]; then
  while IFS='=' read -r key value; do
    [[ "$key" == '' || "$key" == \#* ]] && continue
    if [[ -z "${!key:-}" ]]; then
      export "$key=$value"
    fi
  done < .env
fi

# --- helpers ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 127; }; }

# sha256 of a file, outputs hex
file_sha256() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r "$f" | awk '{print $1}'
  else
    echo "No sha256 tool found (need sha256sum | shasum | openssl)" >&2
    exit 127
  fi
}

# --- check deps ---
need docker
need jq
need cosign

# post_hcs helper (built by `make post-hcs-build`)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POST_HCS="${SCRIPT_DIR}/bin/post_hcs"
if [[ ! -x "$POST_HCS" ]]; then
  echo "Missing ${POST_HCS}. Build it with: make post-hcs-build" >&2
  exit 1
fi

# --- parse args or fall back to environment/.env variables ---
DOCKER_FLAGS=()
CMD_ARGS=()

if [[ $# -lt 2 ]]; then
  if [[ -n "${ATT_IMAGE:-}" ]]; then
    if [[ -n "${ATT_FLAGS:-}" ]]; then
      read -r -a DOCKER_FLAGS <<< "${ATT_FLAGS}"
    fi
    IMG="${ATT_IMAGE}"
    if [[ -n "${ATT_CMD:-}" ]]; then
      read -r -a CMD_ARGS <<< "${ATT_CMD}"
    fi
  else
    echo "usage: $0 [DOCKER_FLAGS ...] -- IMAGE@sha256:<digest> [CMD ARGS ...]" >&2
    echo "Or set ATT_FLAGS, ATT_IMAGE and ATT_CMD in the environment or .env" >&2
    exit 2
  fi
else
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then
      shift
      break
    fi
    DOCKER_FLAGS+=("$1")
    shift
  done

  if [[ $# -lt 1 ]]; then
    echo "Missing IMAGE@sha256:<digest> after --" >&2
    exit 2
  fi

  IMG="$1"; shift
  CMD_ARGS=("$@")
fi

if [[ "$IMG" != *@sha256:* ]]; then
  echo "Image must be referenced by immutable digest (image@sha256:...)" >&2
  exit 2
fi

# --- verify image signature ---
echo "Verifying image signature with cosign: $IMG"
COSIGN_OUT=$(cosign verify "$IMG" 2>&1 || true)
if ! echo "$COSIGN_OUT" | grep -q "Verified OK"; then
  echo "$COSIGN_OUT"
  echo "cosign verify did not report 'Verified OK' — aborting." >&2
  exit 1
fi
echo "$COSIGN_OUT" > cosign.verify.txt

# --- run the container by digest ---
echo "Running container: docker run --pull=never ${DOCKER_FLAGS[*]} $IMG ${CMD_ARGS[*]}"
CID=$(docker run --pull=never -d "${DOCKER_FLAGS[@]}" "$IMG" "${CMD_ARGS[@]}")
echo "Started container: $CID"

# --- snapshot runtime state ---
INSPECT_JSON=$(docker inspect "$CID")
HOST_UNAME=$(uname -a)
DOCKER_VER=$(docker version --format '{{json .}}')
DOCKER_INFO=$(docker info --format '{{json .}}')
NOW=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
IMG_CONFIG_DIGEST=$(echo "$INSPECT_JSON" | jq -r '.[0].Image')

ATT_JSON=$(jq -n \
  --arg now "$NOW" \
  --arg img_ref "$IMG" \
  --arg img_cfg "$IMG_CONFIG_DIGEST" \
  --arg cid "$CID" \
  --arg uname "$HOST_UNAME" \
  --arg cosign "$(cat cosign.verify.txt)" \
  --arg docker_ver "$DOCKER_VER" \
  --arg docker_info "$DOCKER_INFO" \
  --arg inspect "$INSPECT_JSON" '
  {
    v: 1,
    type: "docker-run-attestation",
    time_utc: $now,
    image_ref: $img_ref,
    image_config_digest: $img_cfg,
    container_id: $cid,
    host_uname: $uname,
    cosign_verify_output: $cosign,
    docker_version: ($docker_ver | fromjson),
    docker_info: ($docker_info | fromjson),
    container_inspect: ($inspect | fromjson)
  }')

echo "$ATT_JSON" > run-attestation.json

# --- sign the attestation blob ---
echo "Signing run-attestation.json with cosign (keyless if configured)..."
cosign sign-blob --yes \
  --output-signature run-attestation.sig \
  --output-certificate run-attestation.pem \
  run-attestation.json >/dev/null

# --- compute attestation hash and post to Hedera ---
ATT_HASH_HEX=$(file_sha256 run-attestation.json)
echo "Attestation SHA-256: $ATT_HASH_HEX"

MSG_FILE="attestation-hash-message.json"
jq -n --arg now "$NOW" --arg hash "$ATT_HASH_HEX" --arg img "$IMG" --arg cid "$CID" '{
  v: 1,
  type: "docker-run-attestation-hash",
  time_utc: $now,
  attestationHashHex: $hash,
  imageRef: $img,
  containerId: $cid
}' > "$MSG_FILE"

echo "Posting attestation hash to Hedera topic via ${POST_HCS} ..."
"${POST_HCS}" -file "$MSG_FILE"

echo "Done."
echo "Artifacts:"
echo "  - run-attestation.json"
echo "  - run-attestation.sig"
echo "  - run-attestation.pem"
echo "  - attestation-hash-message.json (posted)"
