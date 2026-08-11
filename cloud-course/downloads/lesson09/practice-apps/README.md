# 명세 호환 연습용 Go 앱

공식 제공 바이너리가 아닙니다. 제시된 2026 System operation 명세를 바탕으로 컨테이너·ECR·EKS·RDS·S3 실습을 할 수 있도록 만든 교육용 대체 구현입니다.

- Go 1.22 / linux/amd64
- TCP 8080
- USER: POST/GET `/v1/user`, MySQL
- PRODUCT: POST/GET/PUT `/v1/product`, MySQL, S3 (`S3_BUCKET` 추가 필요)
- STRESS: POST `/v1/stress`
- 공통: GET `/healthcheck`, requestid·uuid 검증, stdout/stderr access log

공식 채점 환경에서는 주최 측이 제공한 원본 바이너리를 우선 사용하세요. 응답 본문은 공식 명세에 정의되지 않았으므로 이 구현의 JSON 형식이 원본과 동일하다고 보장하지 않습니다.

## 빌드

```bash
go mod download
chmod +x build-linux-amd64.sh
./build-linux-amd64.sh
```

## Docker

```bash
docker build --build-arg APP=user -t user:practice .
docker build --build-arg APP=product -t product:practice .
docker build --build-arg APP=stress -t stress:practice .
```

USER와 PRODUCT는 명세의 `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_DBNAME`이 필수입니다. PRODUCT 이미지 PUT 실습에는 `S3_BUCKET`과 Pod IAM S3 PutObject 권한이 추가로 필요합니다.