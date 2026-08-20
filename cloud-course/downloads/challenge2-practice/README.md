# 제2과제 최종 모의대회 배포자료

이 ZIP은 `Small Challenges Practice Set A` 페이지와 함께 사용합니다.

## 구성

- `module1/`: DynamoDB Client 애플리케이션
- `module2/`: VPC Lattice Client 및 Inventory Service 애플리케이션
- `module3/`: IAM Trust Policy 자동 복구 Lambda
- `module4/`: SQS Worker 및 Dockerfile
- `grade-all.sh`: 4개 모듈 자동 채점 스크립트

## 채점

AWS CloudShell에서 실행합니다.

```bash
chmod +x grade-all.sh
./grade-all.sh
```

완료 후 생성된 `challenge2-grade-result.json`을 웹페이지의 채점 결과 영역에 업로드합니다. 스크립트는 리소스를 생성하거나 삭제하지 않으며 조회와 API 호출만 수행합니다.

## 주의

- 실전 연습 전 AWS 비용이 발생할 수 있는 서비스를 확인합니다.
- 문제에 지정된 리전, 리소스 이름, Name 태그를 정확히 사용합니다.
- Access Key, Secret Key, Session Token은 결과 JSON에 넣지 않습니다.
