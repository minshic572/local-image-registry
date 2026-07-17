#!/usr/bin/env python3

import importlib.util
import pathlib
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "scripts" / "registry-inventory.py"
SPEC = importlib.util.spec_from_file_location("registry_inventory", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class FakeRegistryClient:
    def paged_values(self, path, field):
        if path.startswith("/v2/_catalog"):
            return ["cilium/cilium", "busybox"]
        if "cilium/cilium" in path:
            return ["v1"]
        if "busybox" in path:
            return ["latest"]
        raise AssertionError(path)

    def manifest(self, repository, reference):
        if repository == "cilium/cilium":
            return {
                "digest": "sha256:index",
                "media_type": "application/vnd.oci.image.index.v1+json",
                "platforms": [
                    {"os": "linux", "architecture": "amd64", "variant": "", "digest": "sha256:amd64"},
                    {"os": "linux", "architecture": "arm64", "variant": "v8", "digest": "sha256:arm64"},
                ],
            }
        return {
            "digest": "sha256:busybox",
            "media_type": "application/vnd.oci.image.manifest.v1+json",
            "platforms": [],
        }


class InventoryTest(unittest.TestCase):
    def test_inventory_records_digests_platforms_and_root_repository(self):
        inventory = MODULE.build_inventory(FakeRegistryClient())
        self.assertEqual(len(inventory), 2)
        repositories = {item["repository"]: item for item in inventory}
        self.assertIn("busybox", repositories)
        cilium = repositories["cilium/cilium"]["tags"][0]
        self.assertEqual(cilium["digest"], "sha256:index")
        self.assertEqual([p["architecture"] for p in cilium["platforms"]], ["amd64", "arm64"])


if __name__ == "__main__":
    unittest.main()
