# registry:2 to Harbor migration runbook

## Safety model

Harbor is installed on staging port `5002` while registry:2 remains online on
port `5001`. Image writers are frozen only for the final delta. The old
registry container and volume are not removed during cutover.

Do not copy `/var/lib/registry` directly into Harbor. Harbor needs project,
repository, artifact, scanner, and accessory metadata in addition to blobs.

## 1. Preconditions

```bash
cp config/harbor.env.example config/harbor.env
make verify
```

Confirm:

- `harbor.local` resolves to `127.0.0.1` on the host;
- Docker Desktop lists both `harbor.local:5001` and `harbor.local:5002` under
  `insecure-registries` for this local HTTP deployment;
- registry:2 responds on `http://localhost:5001/v2/`;
- Docker Desktop has enough CPU, memory, and disk;
- no existing service uses staging port `5002`;
- `crane` is installed.

## 2. Install and initialize Harbor

```bash
make harbor-install
make harbor-init
make status
```

Open `http://harbor.local:5002` and confirm that Trivy is healthy and the
projects exist. Administrator credentials are stored in `.harbor/secrets.env`.
Migration robot credentials are stored in `.harbor/migration-robot.json`.

Neither file may be committed or copied into application configuration.

## 3. Inventory registry:2

```bash
make inventory
jq . output/registry-v2-inventory.json
```

The inventory records repository, tag, media type, top-level digest, and
multi-architecture child descriptors.

Registry V2 catalog and tag APIs do not reveal unreachable untagged manifests.
If the source registry contains Cosign signatures, SBOMs, or provenance through
OCI referrers, inventory and copy those artifact graphs separately with an
OCI-referrer-aware tool such as `oras copy --recursive`.

## 4. Initial online copy

```bash
make migrate
jq . output/harbor-migration-report.json
```

For each tagged image the migration:

1. preserves the repository path, except root repositories become `library/*`;
2. copies the complete manifest or manifest list with `crane copy`;
3. resolves the target digest;
4. fails if source and target top-level digests differ.

Do not proceed while `failed` is non-zero.

## 5. Freeze and final delta

Pause all writers:

- scheduled mirror jobs;
- CI image pushes;
- local `docker push` operations;
- tag mutation or deletion.

Then repeat:

```bash
make inventory
make migrate
```

Review the regenerated report. The cutover command refuses an incomplete or
failed report.

## 6. Cut over

```bash
make cutover
```

This operation:

1. stops `local-image-registry` (registry:2), releasing port `5001`;
2. regenerates Harbor configuration for port `5001`;
3. recreates the Harbor Compose services;
4. waits for the Harbor health API;
5. keeps the registry:2 container and volume intact.

Re-authenticate clients because the registry authority changed from staging
port `5002` to final port `5001`:

```bash
docker login harbor.local:5001
```

## 7. Post-cutover acceptance

```bash
make status
make connect-kind
```

Verify at minimum:

- every expected project, repository, and tag is visible in Harbor;
- source and target digests in the report are identical;
- amd64 and arm64 images can be resolved;
- anonymous pull works for public projects;
- anonymous push fails;
- robot-authenticated push succeeds;
- an existing kind workload can be recreated without external registry access;
- Trivy scanning completes;
- SBOM generation completes for a newly pushed image.

## 8. Rollback

During the observation window:

```bash
make rollback
```

Rollback stops Harbor and restarts the preserved registry:2 container on
`localhost:5001`. Kubernetes manifests already changed to `harbor.local:5001`
must be reverted or temporarily remapped before workloads can use registry:2.

Any images pushed only to Harbor after cutover must be copied back or explicitly
accepted as post-cutover data loss before rollback.

## 9. Retirement

Retire registry:2 only after:

- the observation period has completed;
- Harbor image and database backups have been restored successfully in a test;
- all callers use Harbor references and credentials;
- no rollback has been required;
- the final source inventory and migration report are archived.

Deleting the old container or volume is intentionally a manual operation.
