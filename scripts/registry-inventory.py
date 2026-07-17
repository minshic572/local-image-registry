#!/usr/bin/env python3
"""Inventory tagged content in a Docker Registry HTTP API V2 endpoint."""

from __future__ import annotations

import argparse
import json
import ssl
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ACCEPT = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)


class RegistryClient:
    def __init__(self, base_url: str, insecure: bool) -> None:
        self.base_url = base_url.rstrip("/")
        self.context = ssl._create_unverified_context() if insecure else None

    def request(self, path_or_url: str, method: str = "GET"):
        url = path_or_url if path_or_url.startswith("http") else self.base_url + path_or_url
        request = urllib.request.Request(url, method=method, headers={"Accept": ACCEPT})
        return urllib.request.urlopen(request, context=self.context, timeout=30)

    def paged_values(self, path: str, field: str) -> list[str]:
        values: list[str] = []
        url = self.base_url + path
        while url:
            with self.request(url) as response:
                values.extend(json.load(response).get(field) or [])
                link = response.headers.get("Link", "")
            if link.startswith("<") and ">" in link:
                url = urllib.parse.urljoin(url, link[1 : link.index(">")])
            else:
                url = ""
        return values

    def manifest(self, repository: str, reference: str) -> dict:
        quoted_repo = urllib.parse.quote(repository, safe="/")
        quoted_ref = urllib.parse.quote(reference, safe=":@")
        path = f"/v2/{quoted_repo}/manifests/{quoted_ref}"
        with self.request(path) as response:
            raw = response.read()
            digest = response.headers.get("Docker-Content-Digest", "")
            media_type = response.headers.get("Content-Type", "").split(";", 1)[0]
        body = json.loads(raw)
        platforms = []
        for descriptor in body.get("manifests", []):
            platform = descriptor.get("platform") or {}
            platforms.append(
                {
                    "os": platform.get("os", ""),
                    "architecture": platform.get("architecture", ""),
                    "variant": platform.get("variant", ""),
                    "digest": descriptor.get("digest", ""),
                }
            )
        return {"digest": digest, "media_type": media_type, "platforms": platforms}


def build_inventory(client: RegistryClient) -> list[dict]:
    repositories = client.paged_values("/v2/_catalog?n=100", "repositories")
    inventory = []
    for repository in sorted(repositories):
        tags = client.paged_values(
            f"/v2/{urllib.parse.quote(repository, safe='/')}/tags/list?n=100", "tags"
        )
        tag_entries = []
        for tag in sorted(tags):
            tag_entries.append({"tag": tag, **client.manifest(repository, tag)})
        inventory.append({"repository": repository, "tags": tag_entries})
    return inventory


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", default="http://localhost:5001")
    parser.add_argument("--output", default="output/registry-v2-inventory.json")
    parser.add_argument("--insecure", action="store_true")
    args = parser.parse_args()

    client = RegistryClient(args.registry, args.insecure)
    inventory = build_inventory(client)

    result = {
        "source": args.registry,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "repository_count": len(inventory),
        "tag_count": sum(len(item["tags"]) for item in inventory),
        "repositories": inventory,
        "limitations": [
            "The Registry V2 catalog exposes repositories and tags, not unreachable untagged manifests.",
            "OCI referrers require a separate recursive artifact migration when present.",
        ],
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(f"[OK] Inventory: {result['repository_count']} repositories, {result['tag_count']} tags")
    print(f"[OK] Written to {output}")


if __name__ == "__main__":
    main()
