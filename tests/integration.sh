#!/usr/bin/env bash
set -euo pipefail

plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/mise-oci-test.XXXXXX")
container="mise-oci-test-${RANDOM}-${RANDOM}"
cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -f "$work/test.key" "$work/wrong.key" "$work/tls.key" "$work/certs/tls.key"
}
trap cleanup EXIT
printf 'Integration evidence: %s\n' "$work"
mkdir -p "$work/certs" "$work/publish" "$work/consumer" "$work/anonymous"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$work/tls.key" -out "$work/certs/tls.crt" \
    -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,DNS:localhost.,IP:127.0.0.1' > "$work/openssl.log" 2>&1
cp "$work/tls.key" "$work/certs/tls.key"
docker run --detach --name "$container" -p 127.0.0.1::5000 \
    -v "$work/certs:/certs:ro" \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/tls.crt \
    -e REGISTRY_HTTP_TLS_KEY=/certs/tls.key registry:3 > "$work/registry-id"
port=$(docker port "$container" 5000/tcp | sed 's/.*://')
repository="localhost.:$port/mise-oci-test"
export SSL_CERT_FILE="$work/certs/tls.crt"
for attempt in $(seq 1 30); do
    if curl --silent --fail --cacert "$SSL_CERT_FILE" "https://localhost:$port/v2/" >/dev/null; then break; fi
    if [ "$attempt" = 30 ]; then exit 1; fi
    sleep 1
done

export COSIGN_PASSWORD=''
cosign generate-key-pair --output-key-prefix "$work/test" > "$work/key.log" 2>&1
cosign generate-key-pair --output-key-prefix "$work/wrong" >> "$work/key.log" 2>&1
for platform in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do
    suffix=${platform//\//-}
    mkdir -p "$work/publish/$suffix"
    printf '#!/bin/sh\nprintf "oci fixture %s\\n"\n' "$platform" > "$work/publish/$suffix/ocifixture"
    chmod 755 "$work/publish/$suffix/ocifixture"
    tar -czf "$work/publish/$suffix/ocifixture.tar.gz" -C "$work/publish/$suffix" ocifixture
    (cd "$work/publish/$suffix" && oras push --plain-http=false \
        --artifact-type application/vnd.mise.tool.v1 --artifact-platform "$platform" \
        "$repository:build-$suffix" ocifixture.tar.gz:application/gzip)
done
oras manifest index create --plain-http=false "$repository:v1.2.3" \
    build-linux-amd64 build-linux-arm64 build-darwin-amd64 build-darwin-arm64
index_digest=$(oras resolve --plain-http=false "$repository:v1.2.3")
cosign sign --yes --key "$work/test.key" --bundle "$work/bundle.json" "$repository@$index_digest"

export MISE_DATA_DIR="$work/mise data"
export MISE_CONFIG_DIR="$work/mise config"
export MISE_CACHE_DIR="$work/mise cache"
export DOCKER_CONFIG="$work/anonymous"
cd "$work/consumer"
cat > mise.toml <<CONFIG
[tools]
oras = "1.3.4"
cosign = "3.1.3"
"oci:ocifixture" = { version = "1.2.3", repository = "$repository", tag_prefix = "v", public_key = "$work/test.pub", digest = "$index_digest" }
CONFIG
mise trust
mise plugins link oci "$plugin_dir"
mise install
mise ls-remote oci:ocifixture | grep -Fx 1.2.3
case $(uname -s) in Linux) os=linux ;; Darwin) os=darwin ;; *) exit 1 ;; esac
case $(uname -m) in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) exit 1 ;; esac
actual=$(mise exec oci:ocifixture@1.2.3 -- ocifixture)
[ "$actual" = "oci fixture $os/$arch" ]
printf '%s\n' "$actual"

cat >> mise.toml <<CONFIG
"oci:wrong-key" = { version = "1.2.3", binary = "ocifixture", repository = "$repository", tag_prefix = "v", public_key = "$work/wrong.pub" }
"oci:wrong-pin" = { version = "1.2.3", binary = "ocifixture", repository = "$repository", tag_prefix = "v", public_key = "$work/test.pub", digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000" }
CONFIG
if mise install oci:wrong-key@1.2.3 > "$work/wrong-key.log" 2>&1; then
    echo 'Wrong key unexpectedly accepted' >&2; exit 1
fi
if mise install oci:wrong-pin@1.2.3 > "$work/wrong-pin.log" 2>&1; then
    echo 'Wrong digest unexpectedly accepted' >&2; exit 1
fi
grep -F 'configured index digest does not match' "$work/wrong-pin.log"
# Check the negative failed in cryptographic verification, rather than tool setup.
grep -E 'no matching|signature|transparency log' "$work/wrong-key.log"
printf 'PASS: signed multiarch installation, wrong-key rejection, wrong-pin rejection\n'
