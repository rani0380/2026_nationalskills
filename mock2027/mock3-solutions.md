# 2027 지방대회 대비 모의고사 3회 · 교사용 풀이

문제와 분리된 교사용 해설입니다. 자동 채점은 설정 30점, 교사 실기 확인은 20점입니다. 스크립트는 읽기 전용 AWS 조회만 수행하며 실제 복구·메시지 처리·권한 범위는 교사가 확인합니다.

## 제1과제: 구축 순서

1. VPC에서 DNS 해석·DNS 호스트 이름을 켜고 네 서브넷을 생성합니다. 두 Public 서브넷을 IGW 라우팅 테이블에 연결합니다.
2. Public 각 AZ에 EIP/NAT를 생성합니다. Private RT 두 개를 분리해 같은 AZ NAT로 기본 경로를 지정합니다. DynamoDB Gateway endpoint를 두 RT에 연결합니다.
3. ALB SG는 80을 인터넷에, API SG는 8080을 ALB SG에만 엽니다.
4. DynamoDB를 생성하고 PITR을 활성화합니다.
5. ECS Task 신뢰 주체는 ecs-tasks.amazonaws.com입니다. Execution Role에 ECR pull·CloudWatch Logs 전송 권한을 주고, Task Role에 지정 테이블의 GetItem/PutItem만 허용합니다.
6. 아래 Dockerfile로 이미지를 만들고 ECR docs-api:v1에 push합니다. 이후 재빌드는 불변 태그를 덮어쓰지 말고 새 태그를 쓰고 최종 제출 시 문제의 v1을 사용하는 revision을 지정합니다.
7. 로그 그룹을 미리 생성하고 retention 7일을 설정합니다. Task Definition과 IP target group, ALB listener를 만듭니다.
8. 두 Private 서브넷에서 Fargate 서비스 Desired 2로 배포합니다. Public IP는 끕니다. ALB health가 정상화되면 Auto Scaling·circuit breaker·경보를 설정합니다.

Dockerfile 예시:

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 8080
CMD ["gunicorn","--bind","0.0.0.0:8080","--workers","2","--access-logfile","-","--capture-output","app:app"]
```

Task Role 정책 예시(<계정ID> 치환):

```json
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["dynamodb:PutItem","dynamodb:GetItem"],"Resource":"arn:aws:dynamodb:ap-northeast-2:<계정ID>:table/docs-table"}]}
```

## 제1과제: 동작 확인

ALB DNS를 사용해 다음 순서로 확인합니다.

```bash
BASE="http://ALB_DNS로교체"
curl -i "$BASE/health"
curl -i -H 'Content-Type: application/json' -d '{"title":"practice"}' "$BASE/documents"
# 응답 doc_id를 아래에 넣습니다.
curl -i "$BASE/documents/반환된UUID"
curl -i "$BASE/documents/missing"
curl -i -H 'Content-Type: application/json' -d '{}' "$BASE/documents"
for i in $(seq 1 10); do curl --fail --silent --show-error "$BASE/health"; done
```

서비스의 Task 1개 중지 후 ECS가 새 Task를 생성하고 TG healthy가 2로 복구되는 것을 관찰합니다. Deployment circuit breaker 설정만으로 이 실기 점수를 주지 않습니다.

- CannotPullContainerError: Private 기본 경로·NAT 상태·Execution Role·이미지 태그·아키텍처를 확인합니다.
- TG unhealthy: SG의 참조 방향, 8080 매핑, /health 응답과 앱 bind 주소를 확인합니다.
- DynamoDB AccessDenied: Task Role과 Execution Role을 바꿔 연결하지 않았는지 확인합니다.
- 5xx metric의 dimensions는 ALB ARN 전체가 아닌 app/이름/ID, TG는 targetgroup/이름/ID입니다. 두 dimension을 모두 넣습니다.

## 제2과제: 구축 순서

1. 원본 테이블·S3·DLQ·원본 큐를 만듭니다. S3 알림은 큐 정책 적용 후 설정해야 대상 검증 오류를 피할 수 있습니다.
2. DLQ ARN과 maxReceiveCount=3으로 redrive 정책을 지정합니다.
3. S3 알림은 incoming/과 .json을 동시에 지정합니다. S3 테스트 알림을 앱이 무시하도록 합니다.
4. Lambda 역할과 아래 코드를 적용하고 mapping에 ReportBatchItemFailures를 켭니다.
5. 정상 파일을 올려 색인 완료 후 백업을 만들고 AVAILABLE까지 기다립니다. 백업으로 복원하고 ACTIVE까지 기다립니다.
6. uploader 역할과 TLS 강제 버킷 정책을 구성합니다. 관리자 자격증명으로 권한 실기 테스트를 대신하지 않습니다.
7. SNS·경보·Dashboard를 구성하고 실패 파일을 올려 재시도와 ALARM을 확인합니다.

Lambda index.py 예시, handler=index.handler:

```python
import json
import os
from urllib.parse import unquote_plus
import boto3

s3 = boto3.client("s3")
table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])

def handler(event, context):
    failures = []
    for message in event.get("Records", []):
        key = "(unknown)"
        try:
            payload = json.loads(message["body"])
            if payload.get("Event") == "s3:TestEvent":
                continue
            records = payload.get("Records")
            if not isinstance(records, list) or not records:
                raise ValueError("missing S3 Records")
            for record in records:
                bucket = record["s3"]["bucket"]["name"]
                key = unquote_plus(record["s3"]["object"]["key"])
                response = s3.get_object(Bucket=bucket, Key=key)
                with response["Body"] as stream:
                    body = json.loads(stream.read())
                title = body.get("title") if isinstance(body, dict) else None
                owner = body.get("owner") if isinstance(body, dict) else None
                if not all(isinstance(v, str) and v.strip() for v in (title, owner)):
                    raise ValueError("invalid document")
                table.put_item(Item={
                    "object_key": key, "title": title.strip(),
                    "owner": owner.strip(), "status": "INDEXED"
                })
                print("INDEXED", key, flush=True)
        except Exception as exc:
            print("FAILED", key, type(exc).__name__, flush=True)
            failures.append({"itemIdentifier": message["messageId"]})
    return {"batchItemFailures": failures}
```

SQS 메시지 하나에 여러 S3 레코드가 있으면 그 메시지 단위로 재시도됩니다. 동일 PK 덮어쓰기로 중복 행을 방지합니다.

## 제2과제: 정책 예시

SQS queue policy 예시:

```json
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"s3.amazonaws.com"},"Action":"sqs:SendMessage","Resource":"arn:aws:sqs:ap-northeast-2:<계정ID>:docs-events","Condition":{"ArnEquals":{"aws:SourceArn":"arn:aws:s3:::docs-inbox-<계정ID>-<비번호>"},"StringEquals":{"aws:SourceAccount":"<계정ID>"}}}]}
```

uploader 권한 예시:

```json
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::docs-inbox-<계정ID>-<비번호>/incoming/*"},{"Effect":"Allow","Action":"s3:GetBucketLocation","Resource":"arn:aws:s3:::docs-inbox-<계정ID>-<비번호>"},{"Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::docs-inbox-<계정ID>-<비번호>","Condition":{"StringLike":{"s3:prefix":"incoming/*"}}}]}
```

TLS 강제 버킷 정책 예시:

```json
{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::docs-inbox-<계정ID>-<비번호>","arn:aws:s3:::docs-inbox-<계정ID>-<비번호>/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}
```

Lambda에는 원본 큐의 ReceiveMessage/DeleteMessage/GetQueueAttributes와 지정 S3 GetObject, 테이블 PutItem, 로그 권한을 분리해 부여합니다. SSE-SQS를 사용하므로 SQS용 KMS 복호화 권한은 필요하지 않습니다.

## 제2과제: 실기 확인

- incoming/good.json 업로드 후 docs-index에서 ConsistentRead로 조회합니다.
- 같은 파일을 다시 업로드해 처리한 뒤 같은 key의 항목만 있는지 확인합니다.
- outside/ignored.json은 색인되지 않아야 합니다. 로그·알림 설정도 함께 확인합니다.
- Lambda 콘솔의 테스트 입력에 정상·실패 SQS 레코드를 함께 넣고 실패 messageId만 반환되는지 확인합니다. 실제 SQS mapping에서도 정상 메시지가 재시도되지 않는지 관찰합니다.
- bad.json을 올리고 최대 15분 내 DLQ에 도착하는지 확인합니다. 경보를 확인하기 전에 DLQ 메시지를 삭제하지 않습니다.
- 백업 생성 시각, 정상 색인 시각과 복원한 실제 항목을 대조합니다.
- AssumeRole 임시 세션은 별도 셸에서 사용하고 종료합니다. 세션 토큰이나 STS 출력은 제출하지 않습니다.
- 복원 테이블과 원본 테이블을 모두 유지한 상태로 평가한 후 정리합니다.

## 채점 결과 사용

자동 점검 실패는 설정 불일치, ERROR는 API·권한·네트워크 오류입니다. 오류가 하나라도 있으면 스크립트는 총점을 확정하지 않으며 제출 전 해결해야 합니다. 교사 점수를 생략하면 자동 점검만 실행되고 TOTAL SCORE는 출력하지 않습니다.

교사 점수 입력 형식은 각 문제의 실기 영역 점수를 쉼표로 연결합니다. 제1과제 상한은 4,4,6,4,2이고 제2과제 상한은 8,4,6,2입니다. 입력하지 않은 실기 점수는 자동으로 만점 처리되지 않습니다.

## 참고 문서

- ECS Task Role과 Execution Role: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/security-iam-roles.html
- S3 이벤트 대상과 같은 리전 제약: https://docs.aws.amazon.com/AmazonS3/latest/userguide/notification-how-to-event-types-and-destinations.html
- SQS event source와 visibility timeout: https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-configure.html
- SQS 부분 배치 실패 처리: https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-errorhandling.html

이 해설은 하나의 구현 예입니다. 요구사항과 실제 동작이 같은 다른 구현도 인정합니다. AWS 계정에 실제 배포해 검증한 결과물은 아니므로 수업 전 교사 계정에서 사전 실습을 권장합니다.
