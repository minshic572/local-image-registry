# Local Image Registry

A local Docker registry management and kind/Kubernetes cluster integration toolkit. This project uses the official `registry:2` image as its foundation, combined with `crane` for image synchronization, to provide a stable alternative to `kind load docker-image`, `ctr images import`, and Docker local caching.

## Why Local Registry Instead of `kind load docker-image` / `ctr images import`?

| Method | Problem |
|--------|---------|
| `kind load docker-image` | Images are loaded into the kind node's containerd, but this doesn't work reliably with some CNI plugins and Helm installations that expect to pull from a registry. |
| `ctr images import` | Requires exec into the node and doesn't integrate with Kubernetes' image pull mechanisms. |
| Docker local cache | Only works for Docker-in-Docker scenarios, not for Kubernetes pods. |

**Local registry benefits:**
- Kubernetes pods pull images the same way they would in production
- No node exec required after initial setup
- Works consistently across pod restarts and new deployments
- Simulates production environment where images come from a registry
- Digest-based content addressing ensures image integrity

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Host Machine                          │
│                                                              │
│  ┌──────────────────┐      ┌─────────────────────────────┐ │
│  │  Docker Desktop   │      │  kind Cluster               │ │
│  │                   │      │                             │ │
│  │  ┌──────────────┐ │      │  ┌───────────────────────┐  │ │
│  │  │ registry:2  │ │◄─────┼──│ containerd           │  │ │
│  │  │              │ │      │  │                       │  │ │
│  │  │ :5000 (int)  │ │      │  │ /etc/containerd/     │  │ │
│  │  │ :5001 (host) │ │      │  │   certs.d/            │  │ │
│  │  └──────────────┘ │      │  │   local-image-       │  │ │
│  │         │        │      │  │   registry:5000/     │  │ │
│  │         │        │      │  │   hosts.toml          │  │ │
│  │  ┌──────────────┐ │      │  └───────────────────────┘  │ │
│  │  │ crane copy   │ │      │                             │ │
│  │  │ (sync tool)  │ │      │  ┌───────────────────────┐  │ │
│  │  └──────────────┘ │      │  │ Kubernetes Pods      │  │ │
│  └──────────────────┘      │  │ image: local-image-   │  │ │
│                            │  │ registry:5000/image:tag│  │ │
│                            │  └───────────────────────┘  │ │
│                            └─────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Components

1. **registry:2** - Official Docker distribution registry server
2. **crane** - Google's container registry tool for efficient image copying
3. **kind nodes** - Configured with `hosts.toml` to resolve `local-image-registry:5000`
4. **ConfigMap** - `kube-public/local-registry-hosting` for cluster-wide registry info

## Prerequisites

- macOS or Linux
- Docker Desktop (or Docker Engine)
- kind (`brew install kind`)
- kubectl
- crane (`brew install crane`)

## Quick Start

### 1. Start the Registry

```bash
# Start the local registry
make start

# Verify it's running
make status
```

### 2. Sync Cilium/Hubble Images

```bash
# Mirror all Cilium images to local registry
make mirror-cilium

# Or generate lock file without syncing
make lock
```

### 3. Create kind Cluster (if not exists)

```bash
# Create a new kind cluster
kind create cluster --name cyber-resilience

# Note: For kind < 0.20, you may need to enable config_path in containerd:
# kind create cluster --name cyber-resilience --config - <<EOF
# kind: Cluster
# nodes:
# - role: control-plane
#   extraMounts:
#   - hostPath: /etc/docker/daemon.json
#     containerPath: /etc/docker/daemon.json
# EOF
```

### 4. Connect Registry to kind Cluster

```bash
# Connect registry to kind cluster
make connect-kind
```

### 5. Verify Everything Works

```bash
# Check registry status
make status

# List synced images
curl -s http://localhost:5001/v2/_catalog

# Verify nodes can reach registry by copying a test image:
# First, tag and push busybox to local registry:
docker pull busybox:latest
docker tag busybox:latest localhost:5001/busybox:latest
docker push localhost:5001/busybox:latest

# Then verify on a kind node:
docker exec cyber-resilience-control-plane crictl pull localhost:5001/busybox:latest
```

## Complete Verification Path

Here's a full end-to-end verification:

```bash
# Step 1: Start local registry
make start

# Step 2: Verify registry is accessible
curl -s http://localhost:5001/v2/ | jq
# Expected: {"version":"2"}

# Step 3: Sync Cilium images (this may take several minutes)
make mirror-cilium

# Step 4: Verify images were synced
curl -s http://localhost:5001/v2/_catalog | jq
# Expected: {"repositories":["cilium/cilium","cilium/cilium-envoy",...]}

# Step 5: Check specific image
curl -s http://localhost:5001/v2/cilium/cilium/tags/list | jq

# Step 6: Create kind cluster (if not exists)
kind create cluster --name cyber-resilience

# Step 7: Connect registry to cluster
make connect-kind

# Step 8: Push a test image to local registry
docker pull busybox:latest
docker tag busybox:latest localhost:5001/busybox:latest
docker push localhost:5001/busybox:latest

# Step 9: Verify node can pull from local registry
docker exec cyber-resilience-control-plane crictl pull localhost:5001/busybox:latest

# Step 10: Verify pod can use local registry image
kubectl run test --image=localhost:5001/busybox:latest -- sleep 10
kubectl logs test
kubectl delete pod test

# Step 11: Cleanup
kind delete cluster --name cyber-resilience
make stop
```

## Usage Guide

### Registry Management

```bash
# Start registry (creates if not exists, starts if stopped)
make start

# Stop registry (keeps data)
make stop

# Stop and delete everything (loses all images)
make stop-purge

# Check status
make status
```

### Image Synchronization

```bash
# Sync images from YAML config
./scripts/mirror-images.sh --config config/images.cilium.yaml

# Sync specific platform only
./scripts/mirror-images.sh --config config/images.cilium.yaml --platform linux/amd64

# Dry run (see what would be synced, no registry required)
./scripts/mirror-images.sh --config config/images.cilium.yaml --dry-run

# Force re-sync even if images exist
./scripts/mirror-images.sh --config config/images.cilium.yaml --force

# Override target registry
./scripts/mirror-images.sh --config config/images.cilium.yaml --registry 192.168.1.100:5001

# Override mode
./scripts/mirror-images.sh --config config/images.cilium.yaml --mode single-platform
```

### Push Local Images

```bash
# Push a local Docker image to registry
./scripts/push-local-image.sh \
    --source myapp:v1 \
    --target localhost:5001/myorg/myapp:v1
```

### Kind Integration

```bash
# Connect registry to kind cluster (uses defaults)
make connect-kind

# Or with custom parameters
./scripts/registry-connect-kind.sh --cluster my-cluster --registry my-registry
```

## How Cyber-Resilience Uses This

### 1. Third-Party Images → Local Registry

Instead of referencing external registries in your Kubernetes manifests:

```yaml
# Before (external registry)
image: quay.io/cilium/cilium:v1.19.5

# After (local registry)
image: local-image-registry:5000/cilium/cilium:v1.19.5
```

### 2. Project Images → Local Registry

Build and push your project images to local registry:

```bash
# Build your image
docker build -t platform-api:dev .

# Push to local registry
./scripts/push-local-image.sh \
    --source platform-api:dev \
    --target localhost:5001/cyber-resilience/platform-api:dev
```

### 3. Kubernetes Manifests

All Helm values and YAML manifests reference local registry:

```yaml
# values.yaml for Cilium
cilium:
  image: local-image-registry:5000/cilium/cilium
  tag: v1.19.5

hubble:
  relay:
    image: local-image-registry:5000/cilium/hubble-relay
    tag: v1.19.5
```

## Manifest-List vs Single-Platform Mode

### manifest-list (Default)

```
┌─────────────────────────┐
│   manifest-list         │
│   (multi-arch)          │
├─────────────────────────┤
│  ┌───────────────────┐  │
│  │ linux/amd64       │  │
│  │ sha256:abc123...  │  │
│  └───────────────────┘  │
│  ┌───────────────────┐  │
│  │ linux/arm64       │  │
│  │ sha256:def456...  │  │
│  └───────────────────┘  │
└─────────────────────────┘
```

- **Recommended** for long-term private registry use
- Preserves upstream digest semantics
- Kubernetes automatically pulls correct platform for each node
- Larger storage footprint but best compatibility

### single-platform

```
┌─────────────────────────┐
│   single image          │
│   (one platform)        │
├─────────────────────────┤
│  ┌───────────────────┐  │
│  │ linux/amd64       │  │
│  │ sha256:abc123...  │  │
│  └───────────────────┘  │
└─────────────────────────┘
```

- Saves storage space
- You must ensure platform compatibility at deploy time
- Use `--platform linux/amd64` to sync specific platform

## Known Limitations

### localhost Differences

| Context | localhost:5001 means |
|---------|---------------------|
| Host machine | Your local registry |
| Inside kind node | localhost inside node (not your registry!) |

**Always use `local-image-registry:5000` inside kind nodes**, not `localhost:5001`.

### kind Version Compatibility

For kind versions < 0.20, containerd may require additional configuration. When creating a new cluster, you may need to enable the `config_path` feature:

```bash
cat > kind-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraArgs:
    # Enable registry config path for containerd
    config-source: kubelet
EOF

kind create cluster --name cyber-resilience --config kind-config.yaml
```

After connecting the registry, you may need to restart containerd on each node for the changes to take effect:

```bash
docker exec cyber-resilience-control-plane systemctl restart containerd
```

### Network Configuration

- Registry container must be on the `kind` Docker network
- Kind nodes must have `hosts.toml` configured for containerd
- Some older kind versions may require containerd restart

### Production Alternatives

For production environments, consider these mature solutions:

- **Harbor** - Full-featured registry with UI, replication, vulnerability scanning
- **JFrog Artifactory** - Universal artifact repository
- **Sonatype Nexus** - Artifact repository manager
- **CNCF Distribution (zot)** - CNCF project, OCI-compatible registry server

## Project Structure

```
local-image-registry/
├── README.md
├── Makefile
├── config/
│   ├── images.cilium.yaml          # Cilium/Hubble images
│   └── images.cyber-resilience.yaml.example
├── scripts/
│   ├── registry-start.sh          # Start registry
│   ├── registry-stop.sh           # Stop registry
│   ├── registry-status.sh          # Check status
│   ├── registry-connect-kind.sh   # Connect to kind
│   ├── mirror-images.sh            # Sync images
│   ├── push-local-image.sh        # Push local images
│   └── generate-lock.sh            # Generate lock file
└── output/
    ├── .gitkeep
    ├── images-lock.json            # Synced images record
    └── local-images-lock.json      # Local images record
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DEFAULT_REGISTRY_PORT` | `5001` | Registry host port |
| `DEFAULT_KIND_CLUSTER` | `cyber-resilience` | Default kind cluster name |
| `CONTAINER_NAME` | `local-image-registry` | Registry container name |

## Troubleshooting

### Registry not responding

```bash
# Check if container is running
docker ps | grep local-image-registry

# Check logs
docker logs local-image-registry

# Restart if needed
make stop && make start
```

### Kind nodes can't pull images

```bash
# Verify registry is on kind network
docker network inspect kind | grep local-image-registry

# Check hosts.toml on node
docker exec cyber-resilience-control-plane cat /etc/containerd/certs.d/local-image-registry:5000/hosts.toml

# Restart containerd on node
docker exec cyber-resilience-control-plane systemctl restart containerd

# Re-run connect script
make connect-kind
```

### Images not found after sync

```bash
# Check registry catalog
curl http://localhost:5001/v2/_catalog

# Check specific image
curl http://localhost:5001/v2/cilium/cilium/tags/list
```

### YAML config not parsing correctly

```bash
# Test YAML parsing with dry-run (no registry required)
./scripts/generate-lock.sh --config config/images.cilium.yaml

# Check output/images-lock.json
cat output/images-lock.json | jq
```

## License

MIT
