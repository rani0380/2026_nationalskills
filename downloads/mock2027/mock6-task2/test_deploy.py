"""오프라인 확인 문제. TODO 완료 전 일부 ERROR가 정상입니다."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import deploy

class ConfigTests(unittest.TestCase):
    def test_valid_message(self):
        self.assertEqual(deploy.validate_config(b'{"message":" Welcome v1 "}'), "Welcome v1")

    def test_invalid_values(self):
        for value in [{}, [], {"message":""}, {"message":5}, {"message":"a\nb"}, {"message":"x"*81}]:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    deploy.validate_config(json.dumps(value).encode())

    def test_invalid_json(self):
        with self.assertRaises(ValueError):
            deploy.validate_config(b"{broken")
        with self.assertRaises(ValueError):
            deploy.validate_config(b"x"*65537)

    def test_two_files(self):
        with tempfile.TemporaryDirectory() as work:
            root=Path(work)
            deploy.commit_config("Welcome v1","config-store-123456789012-001","version-1",root)
            page=root/"usr/share/nginx/html/index.html"
            meta=root/"var/lib/config-lab/deployment.json"
            self.assertEqual(page.read_bytes(), b"Welcome v1\n")
            expected={"bucket":"config-store-123456789012-001","key":"config/site.json",
                      "version_id":"version-1","message":"Welcome v1"}
            self.assertEqual(json.loads(meta.read_text()),expected)
            before=(page.read_bytes(),meta.read_bytes())
            deploy.commit_config("Welcome v1",expected["bucket"],"version-1",root)
            self.assertEqual((page.read_bytes(),meta.read_bytes()),before)

    def test_validation_failure_never_calls_commit(self):
        with patch.object(deploy,"validate_config",side_effect=ValueError), \
             patch.object(deploy,"commit_config") as commit:
            # 로컬 검사는 실제 웹 파일을 변경하지 않습니다.
            with tempfile.TemporaryDirectory() as work:
                source=Path(work)/"bad.json";source.write_text('{"message":""}')
                with patch("sys.argv",["deploy.py","--check-file",str(source)]):
                    self.assertEqual(deploy.main(),1)
            commit.assert_not_called()

    def test_download_failure_never_calls_commit(self):
        import subprocess
        with patch.object(deploy.subprocess,"run",
                          return_value=subprocess.CompletedProcess([],1,"","")), \
             patch.object(deploy,"commit_config") as commit:
            with self.assertRaises(RuntimeError):
                deploy.deploy("config-store-123456789012-001","missing-version")
            commit.assert_not_called()

if __name__ == "__main__":
    unittest.main()
