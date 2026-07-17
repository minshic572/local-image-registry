# Harbor-backed Local Image Registry

This repository manages a local Harbor deployment and its integration with
Docker Desktop and kind. It replaces the previous standalone `registry:2`
container with Harbor while preserving image repository paths and, after
cutover, host port `5001`.

Harbor provides project-based image management, vulnerability scanning, SBOM
generation, OCI artifact storage, and support for Cosign/Notation signatures.

## Architecture

Harbor runs as an independent Docker Compose project on Docker Desktop. It is
not deployed into kind, so recreating a cluster does not delete the registry.

```text
Host / CI ───────────────┐
                        ├── harbor.local:5001 ── Harbor Compose stack
kind containerd ─────────┘                         ├── registry storage
                                                   ├── PostgreSQL / Redis
                                                   └── Trivy
```

The official Harbor installer creates multiple containers. The Compose project
is the deployment and lifecycle boundary.

## Requirements

- Docker Desktop with Docker Compose v2
- At least 4 CPUs, 8 GiB memory, and 40 GiB free disk recommended
- `curl`, `python3`, `openssl`, and `tar`
- `crane` for image migration and mirroring
- `kind` and `kubectl` for cluster integration

Harbor officially documents Linux Docker hosts. Running its Linux containers
on Docker Desktop is suitable for this local development use case, but Apple
Silicon may run some Harbor images through amd64 emulation. The installer emits
a warning when it detects an arm64 Docker server.

## Configuration

Create the local configuration:

```bash
cp config/harbor.env.example config/harbor.env
```

The default public address is `harbor.local`. Add it to the host resolver:

```text
127.0.0.1 harbor.local
```

On macOS this normally means adding the line to `/etc/hosts` with
administrator privileges. The name must resolve before Docker login, migration,
or opening the Harbor Portal.

The default local deployment uses HTTP. In Docker Desktop **Settings → Docker
Engine**, add both migration-stage and final authorities, then restart Docker
Desktop:

```json
{
  "insecure-registries": [
    "harbor.local:5001",
    "harbor.local:5002"
  ]
}
```

This is only appropriate for an isolated local development environment. A
shared or network-accessible Harbor must use HTTPS and a trusted certificate.

Configuration and generated secrets are intentionally excluded from Git:

```text
config/harbor.env
.harbor/secrets.env
.harbor/migration-robot.json
.harbor/data/
```

## Fresh Harbor installation

The old registry can continue serving `localhost:5001` while Harbor is prepared
on staging port `5002`:

```bash
make harbor-install
make harbor-init
make status
```

`harbor-install` performs the following operations:

1. Downloads the pinned official Harbor online installer.
2. Verifies the archive against the SHA-256 digest in GitHub release metadata
   when that metadata is available.
3. Generates local administrator and database passwords with mode `0600`.
4. Renders `harbor.yml` from the official release template.
5. Installs Harbor with Trivy on `harbor.local:5002`.

`harbor-init` creates the default `library`, `cilium`, `cyber-resilience`,
`falcosecurity`, and `helm` projects, enables scan-on-push and SBOM generation,
and creates a scoped migration robot. Projects are public for anonymous pulls;
all pushes require authentication. The migration robot receives pull, push, and
OCI artifact permissions for those projects.

## Migrate registry:2

See [MIGRATION.md](MIGRATION.md) for the complete runbook.

The normal flow is:

```bash
# Inventory the still-running registry:2 at localhost:5001.
make inventory

# Copy to Harbor on port 5002 and verify every top-level digest.
make migrate

# Freeze image writers, repeat inventory and migration for the final delta.
make inventory
make migrate

# Stop registry:2 and reconfigure Harbor to use port 5001.
make cutover
```

The cutover keeps the old container and its Docker volume. During the
observation window:

```bash
make rollback
```

stops Harbor and starts the preserved registry:2 on port `5001` again.

## Daily operations

```bash
make start
make stop
make status
make logs
```

Destructive Harbor purge is deliberately not automated. Harbor data includes
registry blobs, PostgreSQL metadata, Redis state, scanner data, signatures, and
SBOM attachments; deletion must follow a verified backup.

## Mirror images

```bash
make mirror-cilium

./scripts/mirror-images.sh \
  --config config/images.cilium.yaml \
  --platform linux/amd64
```

The mirror script automatically targets Harbor's current staging or final port.
It uses Docker's credential store, so authenticate first:

```bash
make login
```

Other local projects can prepare Docker and Helm authentication without reading
Harbor credentials directly:

```bash
make -C ~/projects/local-image-registry login
```

The login command reads the migration robot credentials created by
`make harbor-init`, selects the active Harbor port automatically, and logs in to
both Docker and Helm. It is safe to run repeatedly.

Repository paths retain the Harbor project as their first segment:

```text
harbor.local:5001/cilium/cilium:v1.19.5
harbor.local:5001/cyber-resilience/platform-api:dev
harbor.local:5001/library/nginx:1.25-alpine
```

A root-level registry:2 repository such as `busybox` is migrated to
`library/busybox`, because Harbor requires every repository to belong to a
project.

## kind integration

After cutover:

```bash
make connect-kind
```

The command:

- maps `harbor.local` to Docker Desktop's host gateway in each kind node;
- writes containerd `hosts.toml` for `harbor.local:5001`;
- updates `kube-public/local-registry-hosting`.

Workloads then use the same reference in every context:

```yaml
image: harbor.local:5001/cilium/cilium:v1.19.5
```

Public projects do not need an image pull secret. Private projects require a
Kubernetes `imagePullSecret` created from a read-only Harbor robot account.

## Supply-chain security rollout

Migration deliberately leaves signature and vulnerability pull enforcement
disabled so legacy images remain usable. Enable controls in this order:

1. Establish reliable scan-on-push and scheduled scans.
2. Review CVE severity policy and allowlists.
3. Generate or attach SBOMs.
4. Sign immutable image digests using Cosign or Notation.
5. Generate SLSA/in-toto provenance in CI and store it as an OCI attestation.
6. Enforce signature and provenance policy in Kubernetes admission control.

Harbor stores and manages signatures and attestations; it does not establish
trusted provenance by itself.

## Validation

```bash
make verify
```

The checks cover Bash/Python syntax, Harbor configuration rendering, Registry
V2 inventory, multi-architecture descriptors, and existing image-config parsing.
