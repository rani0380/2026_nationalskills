# 9차시 USER·PRODUCT·STRESS 배포 키트

이 파일은 실습용 Kubernetes 배포 템플릿입니다. 과제에서 제공하는 실제 USER·PRODUCT·STRESS 바이너리를 Docker 이미지로 만든 뒤 ECR에 Push하고, 아래 placeholder를 실제 값으로 바꾸어 사용합니다.

## 파일

- `app-deployments.yaml`: Namespace, ConfigMap, 세 Deployment와 ClusterIP Service
- `deploy.sh`: Secret을 안전하게 생성하고 manifest를 적용하는 스크립트
- `smoke-test.sh`: 세 Service의 healthcheck와 핵심 API 검증 스크립트

## 먼저 바꿀 값

`app-deployments.yaml`에서 다음 값을 검색하여 교체합니다.

- `REPLACE_RDS_ENDPOINT`
- `REPLACE_S3_BUCKET`
- `REPLACE_ACCOUNT_ID`
- `REPLACE_USER_DIGEST`
- `REPLACE_PRODUCT_DIGEST`
- `REPLACE_STRESS_DIGEST`

## 실행

```bash
chmod +x deploy.sh smoke-test.sh
./deploy.sh
./smoke-test.sh
```

DB 비밀번호는 YAML에 넣지 않으며 `deploy.sh` 실행 중 숨김 입력합니다. 실제 비밀번호나 생성된 Secret을 Git에 커밋하지 마세요.