# Attested Run Configuration

The attested run workflow relies on three environment variables:

- `ATT_FLAGS` – optional Docker flags passed to `docker run` (for example, `-e FOO=bar -v /data:/data`).
- `ATT_IMAGE` – reference to the container image **including its digest**, e.g. `registry/org/app@sha256:abcd...`.
- `ATT_CMD` – command and arguments executed inside the container. Use a space‑separated string such as `--serve --port 8080`.

## Setting values

1. **Via environment variables**
   ```bash
   export ATT_FLAGS="-e FOO=bar"
   export ATT_IMAGE="registry/org/app@sha256:abcd..."
   export ATT_CMD="--serve"
   ```
   These take priority over values in `.env`.

2. **Via `.env` file**

   Create a `.env` file (not committed to git) using the structure in `env.example`:
   ```ini
   ATT_FLAGS=-e FOO=bar
   ATT_IMAGE=registry/org/app@sha256:abcd...
   ATT_CMD=--serve
   ```
   `attested-run.sh` and related tools will read missing values from this file.

### Obtaining the image digest

After building and pushing your image, run:
```bash
docker pull registry/org/app:tag
docker inspect --format='{{.RepoDigests}}' registry/org/app:tag
```
Copy the `sha256:` digest and use it in `ATT_IMAGE`.

### Running the attested container

With the variables set, run:
```bash
make -f Makefile_hcs_docker attest-run
```
The script will verify the image, run it, and post the attestation hash to Hedera.
