#!/usr/bin/env python3
"""No-network validation of the BSOD image build context and pinning contract."""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
IMAGE = ROOT / "image" / "container" / "bsod-detector"


class ContainerContractTests(unittest.TestCase):
    def test_dockerfile_copy_sources_exist_in_repository_context(self):
        dockerfile = (IMAGE / "Dockerfile").read_text(encoding="utf-8")
        logical = dockerfile.replace("\\\n", " ")
        sources = []
        for line in logical.splitlines():
            if line.startswith("COPY "):
                parts = line.split()
                self.assertGreaterEqual(len(parts), 3, line)
                sources.extend(parts[1:-1])
        self.assertGreater(len(sources), 8)
        for source in sources:
            self.assertTrue((ROOT / source).exists(), source)

    def test_base_python_and_clients_are_immutable_inputs(self):
        dockerfile = (IMAGE / "Dockerfile").read_text(encoding="utf-8")
        requirements = (IMAGE / "requirements.txt").read_text(encoding="utf-8")
        makefile = (IMAGE / "Makefile").read_text(encoding="utf-8")
        self.assertIn("ARG BASE_IMAGE\nFROM ${BASE_IMAGE}", dockerfile)
        self.assertIn("--require-hashes", dockerfile)
        self.assertRegex(requirements, r"python-evtx==[0-9.]+")
        self.assertGreaterEqual(len(re.findall(r"--hash=sha256:[0-9a-f]{64}", requirements)), 2)
        self.assertIn("BASE_IMAGE must be digest-pinned", makefile)
        self.assertIn("OCP_CLIENT_SHA256", makefile)
        self.assertIn("VIRTCTL_SHA256", makefile)

    def test_one_image_name_and_repository_root_context(self):
        makefile = (IMAGE / "Makefile").read_text(encoding="utf-8")
        wrapper = (ROOT / "apps" / "bsod-detector" / "host-tools" / "run.sh").read_text(encoding="utf-8")
        self.assertIn("IMAGE_NAME ?= bsod-detector", makefile)
        self.assertIn("quay.io/redhatqe/bsod-detector:latest", wrapper)
        self.assertRegex(makefile, r"(?m)^\s*['\"]?\.\./\.\./\.\.['\"]?;? \\?$|['\"]\.\./\.\./\.\.['\"]")


if __name__ == "__main__":
    unittest.main()
