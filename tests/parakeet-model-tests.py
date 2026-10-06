#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
import plistlib
import shutil
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("model_tool", ROOT / "scripts/parakeet-model.py")
model_tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(model_tool)


class ParakeetModelTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.destination = self.root / "model"
        self.payload = b"pinned model contents"
        self.manifest = {
            "repository": "fixture/parakeet",
            "revision": "a" * 40,
            "directory": "parakeet-tdt-0.6b-v2-coreml",
            "files": [{"path": "Encoder.mlmodelc/weights/weight.bin", "size": len(self.payload),
                       "sha256": hashlib.sha256(self.payload).hexdigest()}],
        }

    def tearDown(self):
        self.temporary.cleanup()

    def download(self, staging, manifest, item):
        path = Path(staging) / item["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.payload)

    def test_verified_cache_requires_no_network(self):
        self.download(self.destination, self.manifest, self.manifest["files"][0])
        with patch.object(model_tool.urllib.request, "urlopen", side_effect=AssertionError("network called")):
            model_tool.install(self.destination, self.manifest)

    def test_valid_download_replaces_corrupt_cache_only_after_verification(self):
        self.download(self.destination, self.manifest, self.manifest["files"][0])
        path = self.destination / self.manifest["files"][0]["path"]
        path.write_bytes(b"x" * len(self.payload))
        model_tool.install(self.destination, self.manifest, downloader=self.download)
        model_tool.verify(self.destination, self.manifest)
        backups = list(self.root.glob("model.invalid.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / self.manifest["files"][0]["path"]).read_bytes(), b"x" * len(self.payload))

    def test_corrupt_download_keeps_old_cache_and_removes_staging(self):
        self.download(self.destination, self.manifest, self.manifest["files"][0])
        path = self.destination / self.manifest["files"][0]["path"]
        path.write_bytes(b"old cache")
        def corrupt(staging, manifest, item):
            self.download(staging, manifest, item)
            (Path(staging) / item["path"]).write_bytes(b"x" * len(self.payload))
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            model_tool.install(self.destination, self.manifest, downloader=corrupt)
        self.assertEqual(path.read_bytes(), b"old cache")
        self.assertEqual(list(self.root.glob(".parakeet-download-*")), [])

    def test_path_traversal_mutable_revisions_and_duplicate_files_are_rejected(self):
        manifest_path = self.root / "manifest.json"
        for change in [
            {"revision": "main"},
            {"directory": "../model"},
            {"files": [dict(self.manifest["files"][0], path="../outside")]},
            {"files": self.manifest["files"] * 2},
        ]:
            manifest_path.write_text(json.dumps(dict(self.manifest, **change)))
            with self.assertRaises(ValueError):
                model_tool.load_manifest(manifest_path)

    def test_symlink_cannot_verify_a_file_outside_the_model_directory(self):
        item = self.manifest["files"][0]
        external = self.root / "external.bin"
        external.write_bytes(self.payload)
        path = self.destination / item["path"]
        path.parent.mkdir(parents=True)
        path.symlink_to(external)
        with self.assertRaisesRegex(ValueError, "unsafe"):
            model_tool.verify(self.destination, self.manifest)

    def test_download_uses_immutable_revision_and_checks_exact_bytes(self):
        item = self.manifest["files"][0]
        with patch.object(model_tool.urllib.request, "urlopen") as request:
            response = request.return_value.__enter__.return_value
            response.read.side_effect = [self.payload, b""]
            model_tool.download_file(self.destination, self.manifest, item)
            url = request.call_args.args[0].full_url
            self.assertIn("/resolve/" + self.manifest["revision"] + "/", url)
            model_tool.verify(self.destination, self.manifest)

    def test_canonical_shell_metadata_matches_reviewed_resource_manifest(self):
        manifest = model_tool.load_manifest(model_tool.CANONICAL_MANIFEST)
        metadata = (ROOT / "dependencies.env").read_text()
        for key, value in [("MODEL_REPOSITORY", manifest["repository"]), ("MODEL_REVISION", manifest["revision"]),
                           ("MODEL_DIRECTORY_NAME", manifest["directory"]), ("BACKEND_VERSION", manifest["fluidAudioVersion"])]:
            self.assertIn(f"{key}='{value}'", metadata)


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def assert_failure(self, script, environment, message):
        result = subprocess.run([str(ROOT / script)], env=dict(os.environ, **environment), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)

    def test_production_paths_reject_model_dependency_and_version_overrides(self):
        fake = str(self.root / "external.json")
        self.assert_failure("setup.sh", {"TALKTEXT_MODEL_MANIFEST": fake}, "does not accept a model manifest override")
        self.assert_failure("setup.sh", {"TALKTEXT_DEPENDENCY_MANIFEST": fake}, "does not accept a dependency manifest override")
        self.assert_failure("release.sh", {"TALKTEXT_MODEL_MANIFEST": fake}, "does not accept a model manifest override")
        self.assert_failure("bundle.sh", {"TALKTEXT_SIGNING_MODE": "developer-id", "TALKTEXT_MODEL_MANIFEST": fake},
                            "does not accept a model manifest override")
        for script in ["bundle.sh", "release.sh", "scripts/verify-bundle.sh"]:
            self.assert_failure(script, {"TALKTEXT_VERSION_FILE": fake}, "does not accept a VERSION file override")

    def test_developer_id_rejects_external_shell_manifest_before_sourcing(self):
        marker = self.root / "executed"
        manifest = self.root / "external.env"
        manifest.write_text(f"touch '{marker}'\n")
        self.assert_failure("bundle.sh", {"TALKTEXT_SIGNING_MODE": "developer-id", "TALKTEXT_DEPENDENCY_MANIFEST": str(manifest)},
                            "does not accept a dependency manifest override")
        self.assertFalse(marker.exists())

    def test_metadata_export_and_package_follow_the_canonical_plist(self):
        package = self.root / "TalkText"
        scripts = self.root / "scripts"
        package.mkdir()
        scripts.mkdir()
        info = plistlib.loads((ROOT / "TalkText/Info.plist").read_bytes())
        info.update(CFBundleName="EchoFixture", CFBundleExecutable="EchoFixtureExecutable", LSMinimumSystemVersion="15.0")
        (package / "Info.plist").write_bytes(plistlib.dumps(info))
        shutil.copy(ROOT / "TalkText/Package.swift", package)
        shutil.copy(ROOT / "scripts/export-canonical-metadata.sh", scripts)
        (package / "Sources/TalkText/Resources").mkdir(parents=True)
        (package / "Tests/TalkTextTests").mkdir(parents=True)
        (package / "Sources/TalkText/main.swift").write_text("print(42)\n")
        output = self.root / "metadata.env"
        result = subprocess.run([str(scripts / "export-canonical-metadata.sh"), str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = output.read_text()
        self.assertIn("TALKTEXT_BUNDLE_NAME=EchoFixture", metadata)
        self.assertIn("TALKTEXT_EXECUTABLE_NAME=EchoFixtureExecutable", metadata)
        self.assertIn("TALKTEXT_MINIMUM_SYSTEM_VERSION=15.0", metadata)
        result = subprocess.run(["swift", "package", "--package-path", str(package), "dump-package"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        resolved = json.loads(result.stdout)
        self.assertEqual(resolved["name"], "EchoFixture")
        self.assertEqual(resolved["products"][0]["name"], "EchoFixtureExecutable")
        self.assertEqual(resolved["platforms"][0]["version"], "15.0")

    def test_immutable_release_source_includes_model_manifest_and_package_lock(self):
        files = ["release.sh", "scripts/read-version.sh", "VERSION", "dependencies.env", "TalkText/Info.plist",
                 "TalkText/TalkText.entitlements", "TalkText/Package.resolved", "TalkText/Sources/TalkText/Resources/parakeet-model.json"]
        for name in files:
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / name, destination)
        def git(*args):
            return subprocess.check_output(["git", "-C", str(self.root), *args], text=True).strip()
        git("init", "--quiet")
        git("add", ".")
        git("-c", "user.name=TalkText Fixture", "-c", "user.email=fixture@localhost", "commit", "--quiet", "-m", "fixture")
        version = (self.root / "VERSION").read_text().strip()
        git("tag", "v" + version)
        commit = git("rev-parse", "HEAD")
        environment = dict(os.environ, TALKTEXT_RELEASE_COMMIT=commit, TALKTEXT_RELEASE_TAG="v" + version)
        result = subprocess.run([str(self.root / "release.sh"), "verify-source"], env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = self.root / "TalkText/Sources/TalkText/Resources/parakeet-model.json"
        manifest.write_text(manifest.read_text() + "\n")
        result = subprocess.run([str(self.root / "release.sh"), "verify-source"], env=environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("canonical release file", result.stderr)


if __name__ == "__main__":
    unittest.main()
