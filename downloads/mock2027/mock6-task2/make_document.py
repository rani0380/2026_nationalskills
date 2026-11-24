"""수정한 deploy.py를 SSM Command 문서 JSON에 포함합니다. AWS 호출 없음."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent
source = (root / "deploy.py").read_text(encoding="utf-8")
compile(source, "deploy.py", "exec")
marker = "CONFIGLAB_PY"
if marker in source.splitlines():
    raise ValueError("heredoc delimiter collision")
document = {
    "schemaVersion": "2.2",
    "description": "Mock6 versioned configuration deployment - student scaffold",
    "parameters": {
        "BucketName": {
            "type": "String", "interpolationType": "ENV_VAR",
            "allowedPattern": "^config-store-[0-9]{12}-[0-9]{1,6}$"
        },
        "VersionId": {
            "type": "String", "interpolationType": "ENV_VAR",
            "allowedPattern": "^[A-Za-z0-9._~+/=-]{1,1024}$"
        }
    },
    "mainSteps": [{
        "action": "aws:runShellScript", "name": "deploy",
        "inputs": {
            "timeoutSeconds": "120",
            "runCommand": ["python3 - <<'" + marker + "'\n" + source + "\n" + marker]
        }
    }]
}
target = root / "config-deploy.json"
target.write_text(json.dumps(document, ensure_ascii=False, indent=2), encoding="utf-8")
print("Generated", target.name, "- TODOs in deploy.py must still be completed.")
