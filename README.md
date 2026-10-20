# mise-oci

A Lua backend plugin for [mise](https://mise.jdx.dev/) that installs native CLI
binaries from signed, multi-platform OCI artifacts. ORAS handles registry access;
Cosign verifies signatures and transparency-log evidence before installation.
No container runtime is used.

## Requirements

- mise **2026.10.4 or later** (Lua backend plugins).
- Linux or macOS, AMD64 or ARM64.
- ORAS **1.3.4** and Cosign **3.1.3**; declare them alongside the plugin tool.
- System `tar`, `chmod`, `cp`, `mkdir`, and `sha256sum` (Linux) or `shasum` (macOS).

Windows, libc selection, CPU-specific variants, OS-version constraints, and
arbitrary archive layouts are not supported. Publish portable/static Linux
binaries; Linux platform selection alone does not distinguish glibc and musl.

## Install

```sh
mise plugins install oci https://github.com/sphr2k/mise-oci.git
```

Add a tool to `mise.toml`:

```toml
[tools]
oras = "1.3.4"
cosign = "3.1.3"
"oci:mytool" = { version = "1.2.3", repository = "ghcr.io/myorg/mytool", tag_prefix = "v", issuer = "https://agent.buildkite.com", subject = "https://buildkite.com/myorg/my-pipeline" }
```

```sh
mise install
mise exec -- mytool --version
mise ls-remote oci:mytool
```

ORAS and Cosign are declared plugin dependencies, so mise puts them on the hook
PATH and installs them before the OCI tool. For `ls-remote` before the first
installation, install these helpers first: `mise install oras cosign`.

Public registries require no login. Private registries use the tools' normal
Docker credential configuration (`DOCKER_CONFIG`); do not put credentials in tool
options. Plugin installation itself still uses GitHub, but CLI version discovery
and download use only the OCI registry.

### Public-key verification

Replace `issuer` and `subject` with a local public-key path:

```toml
"oci:mytool" = { version = "1.2.3", repository = "ghcr.io/myorg/mytool", public_key = "/absolute/path/publisher.pub" }
```

Configure exactly one trust mode: a public key, or **both** an exact issuer and
an exact subject. No regex matching and no skip-verification option are exposed.
Public-key signatures must also have valid transparency-log evidence. Cosign's
normal trusted Sigstore roots are used; this plugin does not configure private
Fulcio/Rekor deployments. Public keys must be provisioned independently of the
artifact being verified. Never fetch a key from the same untrusted artifact.

### Immutable pins

Use `digest = "sha256:<64 hex characters>"` to pin the **index**, consistently
across all supported platforms. The plugin rejects a tag resolving to another
digest, even if that replacement also has a valid signature.

Lua backend downloads currently do **not** produce download URL/checksum entries
in `mise.lock`. A version tag plus signature authorizes the configured publisher,
but does not freeze a mutable tag. Use an explicit `digest` for reproducibility;
`mise.lock` alone is insufficient for this backend. Already installed versions are
not reverified on each execution, as with other mise tools.

## Artifact contract

```text
mytool:v1.2.3 -> signed OCI image index
  linux/amd64  -> OCI image manifest -> mytool_1.2.3_linux_amd64.tar.gz
  linux/arm64  -> OCI image manifest -> mytool_1.2.3_linux_arm64.tar.gz
  darwin/arm64 -> OCI image manifest -> mytool_1.2.3_darwin_arm64.tar.gz
```

- Index: `application/vnd.oci.image.index.v1+json`, schema version 2.
- Exactly one matching platform descriptor. ARM64 variant `v8` is accepted;
  ambiguous matches and other variants are rejected.
- Each child is an OCI image manifest with
  `artifactType: application/vnd.mise.tool.v1`.
- Exactly one `application/gzip` layer, with a plain `.tar.gz` filename in
  `org.opencontainers.image.title`.
- The archive contains **one regular file at its root**: the executable, named
  after the tool (or the `binary` option). An optional `./` prefix is accepted.
  Directories, links, extra files and nested paths are rejected.
- Archives are limited to 128 MiB; executables to 256 MiB. Index/manifest JSON is
  limited to 1 MiB. Every digest must use SHA-256.
- Version tags are SemVer without build metadata, optionally prefixed with
  `tag_prefix` (e.g. `v`). Signature/referrer tags are ignored. Versions are
  ordered with SemVer prerelease precedence.

The plugin resolves the version tag once, verifies that **index digest**, hashes
its raw bytes, selects the platform, checks the child's size/digest against the
index and the archive's size/digest against the child. It fetches only by digest
after resolution. Each command is bounded by a timeout. Tar streams the single
validated regular file to a fixed staging path; it never extracts paths chosen
by the archive into the filesystem. The executable is published by rename only
after all checks succeed. Installation does not execute publisher code.

### Publishing with ORAS

```sh
# Archives must contain just the matching root-level executable.
tar -czf mytool_1.2.3_linux_amd64.tar.gz mytool
oras push --artifact-type application/vnd.mise.tool.v1 \
  --artifact-platform linux/amd64 ghcr.io/myorg/mytool:build-linux-amd64 \
  mytool_1.2.3_linux_amd64.tar.gz:application/gzip
# Repeat for other platforms, using unique build tags.
oras manifest index create ghcr.io/myorg/mytool:v1.2.3 \
  build-linux-amd64 build-linux-arm64 build-darwin-arm64
DIGEST=$(oras resolve ghcr.io/myorg/mytool:v1.2.3)
cosign sign --yes "ghcr.io/myorg/mytool@$DIGEST"
```

Only the index needs a signature: its digests bind the selected manifest and
archive. A signature on a child alone does not authorize the index. Publish all
children before the index and sign before announcing the version. Keep build
tags immutable/unique, or construct the index from child digests. ORAS's index
creation command is currently marked experimental.

For a local test key, run `cosign generate-key-pair`, then
`cosign sign --yes --key cosign.key "$REFERENCE@$DIGEST"`. Default signing
includes a Rekor entry; do not disable transparency-log upload.

## Options

| Option | Meaning |
| --- | --- |
| `repository` | Required `registry/path`, without tag or digest. |
| `tag_prefix` | Optional literal prefix, default empty. |
| `binary` | Root archive filename and installed executable; defaults to the tool's final path component. |
| `digest` | Optional immutable SHA-256 index pin; recommended. |
| `public_key` | Public-key verification; mutually exclusive with issuer/subject. |
| `issuer` | Exact HTTPS OIDC issuer for keyless verification. |
| `subject` | Exact certificate identity for keyless verification. |

## Development

```sh
mise install
mise run format
mise run ci
mise run integration
```

On Debian/Ubuntu, install `libreadline-dev` before building the development Lua
interpreter through mise. This is not needed by plugin consumers.

Lua targets **5.1**, matching mise's embedded runtime. StyLua formatting and
LuaLS diagnostics run in CI. Unit tests cover trust configuration, SemVer,
platform selection, malformed descriptors, archive safety and fail-closed
orchestration. The integration test uses real ORAS, Cosign, Rekor and a local TLS
registry, installs through mise, and checks wrong-key/pin failures. It requires
Docker and OpenSSL; it does not alter the global mise installation.

The test fixture publisher uses throwaway local keys; production signing should
use the expected CI keyless identity. Signature verification authenticates an
artifact; this plugin does not validate SLSA provenance predicates.

`types/mise-plugin.lua` comes from jdx/mise-backend-plugin-template; its upstream
license is retained in `types/LICENSE`.
