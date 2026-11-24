"""학생용 시작 코드. TODO 1~2 완료 전에는 배포 성공으로 종료하지 않습니다."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request

def validate_config(raw):
    """TODO 1: bytes -> 앞뒤 공백을 제거한 message 문자열.
    1~65536 bytes, UTF-8 JSON 객체, message는 strip 후 1~80자 문자열.
    개행·제어문자는 거부합니다. 잘못된 입력은 ValueError입니다.
    """
    raise NotImplementedError("TODO 1: validate_config")

def atomic_write(path, body):
    """제공 helper: 대상 파일과 같은 디렉터리에서 임시 파일을 교체합니다."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".config-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o644)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)

def commit_config(message, bucket, version, root=Path("/")):
    """TODO 2: 검증된 message로 두 파일의 완성 내용을 생성한 뒤 atomic_write.
    root/usr/share/nginx/html/index.html: message + 줄바꿈 1개.
    root/var/lib/config-lab/deployment.json: bucket, key, version_id, message.
    key는 config/site.json. json.dumps(..., ensure_ascii=False) 사용.
    테스트에서는 root를 임시 디렉터리로 받습니다. root 밖에 쓰지 않습니다.
    다운로드·검증은 호출 전에 완료되며 이 함수는 이미 검증된 값만 받습니다.
    """
    raise NotImplementedError("TODO 2: commit_config")

def deploy(bucket, version):
    if not re.fullmatch(r"config-store-[0-9]{12}-[0-9]{1,6}", bucket):
        raise ValueError("INVALID_BUCKET")
    if not version or version == "null":
        raise ValueError("INVALID_VERSION")
    with tempfile.TemporaryDirectory(prefix="config-lab-") as work:
        source = Path(work) / "site.json"
        result = subprocess.run(
            ["aws", "s3api", "get-object", "--region", "ap-northeast-2",
             "--bucket", bucket, "--key", "config/site.json",
             "--version-id", version, str(source)],
            capture_output=True, text=True, timeout=45,
        )
        if result.returncode:
            # stderr 전체에 민감 정보가 섞일 수 있어 오류 종류만 보고합니다.
            raise RuntimeError("VERSION_DOWNLOAD_FAILED")
        if not 0 < source.stat().st_size <= 65536:
            raise ValueError("INVALID_SIZE")
        with source.open("rb") as stream:
            message = validate_config(stream.read(65537))
    # 이 줄에 도달하기 전까지 기존 두 파일은 변경하지 않습니다.
    commit_config(message, bucket, version)
    with urllib.request.urlopen("http://localhost/", timeout=5) as response:
        body = response.read(65537)
        if response.status != 200 or body != (message + "\n").encode("utf-8"):
            raise RuntimeError("HTTP_BODY_MISMATCH")
    print("CONFIG_DEPLOY_OK", version, flush=True)

def main():
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "--check-file":
            with open(sys.argv[2], "rb") as stream:
                validate_config(stream.read(65537))
            print("CONFIG_VALID")
        else:
            # ENV_VAR를 지원하지 않는 Agent에서 원시 치환으로 우회하지 않습니다.
            deploy(os.environ["SSM_BucketName"], os.environ["SSM_VersionId"])
        return 0
    except Exception as exc:
        print("CONFIG_DEPLOY_FAILED", type(exc).__name__, flush=True)
        return 1

if __name__ == "__main__":
    sys.exit(main())
