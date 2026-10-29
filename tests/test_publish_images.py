"""Exercise publishing without a Docker daemon, AWS credentials, or network."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
COMPONENTS = (
    "api", "webui", "llm-gateway", "logd", "license_manager",
    "guardrail", "guardrail-scanner", "custom-triton", "faig-models", "vllm-server",
)
REGISTRY = "123456789012.dkr.ecr.us-west-2.amazonaws.com/fortiaigate-lab"
STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
mode = os.environ.get('MOCK_MODE', '')
with open(os.environ['MOCK_EVENTS'], 'a') as out:
    out.write(json.dumps([tool, *args]) + '\n')
if tool == 'aws':
    if args[:2] == ['ecr', 'get-login-password']:
        print('test-token')
    elif args[:2] == ['ecr', 'describe-images']:
        if mode in ('existing', 'different'):
            print('{}')
        else:
            print('AccessDeniedException' if mode == 'denied' else 'ImageNotFoundException', file=sys.stderr)
            sys.exit(1)
    elif args[:2] == ['ecr', 'batch-get-image']:
        print(json.dumps({'config': {'digest': 'sha256:other' if mode == 'different' else 'sha256:abc'}}))
    else:
        sys.exit('Unexpected AWS call')
elif tool == 'docker':
    if args[0] == 'login':
        sys.stdin.read()
    elif args[0] == 'load':
        print('Loaded image: vendor/source:release')
        if mode == 'multiple':
            print('Loaded image: vendor/unrelated:release')
    elif args[:2] == ['image', 'inspect']:
        print('sha256:abc' if '{{.Id}}' in args else ('linux/arm64' if mode == 'arm' else 'linux/amd64'))
    elif args[0] not in ('info', 'tag', 'push'):
        sys.exit('Unexpected Docker call')
'''


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.images = self.work / "images with spaces"
        self.images.mkdir()
        self.events = self.work / "events.jsonl"
        for tool in ("docker", "aws"):
            path = self.bin / tool
            path.write_text(STUB)
            path.chmod(0o755)
        for component in COMPONENTS:
            (self.images / f"FAIG_{component}-V8.0.2-build0055-FORTINET.tar.gz").touch()

    def publish(self, mode=""):
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/publish-images.sh"), REGISTRY, "8.0.2", "0055", str(self.images)],
            env={**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}",
                 "AWS_DEFAULT_REGION": "us-west-2", "MOCK_EVENTS": str(self.events), "MOCK_MODE": mode},
            text=True, capture_output=True,
        )
        events = [json.loads(line) for line in self.events.read_text().splitlines()]
        return result, events

    def test_publishes_all_components_with_cli_gpu_pins(self):
        result, events = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        pushes = [event[2] for event in events if event[:2] == ["docker", "push"]]
        pins = {"custom-triton": "25.11-onnx-trt-agt-rpt-s1", "faig-models": "0.0.5-s1", "vllm-server": "0.28.0-rpt-s1"}
        self.assertCountEqual(pushes, [f"{REGISTRY}/{name}:{pins.get(name, 'V8.0.2-build0055')}" for name in COMPONENTS])

    def test_missing_archive_prevents_login_and_upload(self):
        next(self.images.glob("FAIG_vllm-server-*")).unlink()
        result, events = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing", result.stderr)
        self.assertFalse(any(event[0] == "aws" for event in events))

    def test_rejects_ambiguous_archive(self):
        result, events = self.publish("multiple")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one named image", result.stderr)
        self.assertFalse(any(event[:2] == ["docker", "push"] for event in events))

    def test_rejects_wrong_architecture(self):
        result, events = self.publish("arm")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("linux/amd64", result.stderr)
        self.assertFalse(any(event[:2] == ["docker", "push"] for event in events))

    def test_permission_error_is_not_treated_as_missing_tag(self):
        result, events = self.publish("denied")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AccessDeniedException", result.stderr)
        self.assertFalse(any(event[:2] == ["docker", "load"] for event in events))

    def test_resume_verifies_existing_images_without_pushing(self):
        result, events = self.publish("existing")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("Verified existing image:"), 10)
        self.assertFalse(any(event[:2] == ["docker", "push"] for event in events))

    def test_different_existing_image_is_never_overwritten(self):
        result, events = self.publish("different")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different image", result.stderr)
        self.assertFalse(any(event[:2] == ["docker", "push"] for event in events))


if __name__ == "__main__":
    unittest.main()
