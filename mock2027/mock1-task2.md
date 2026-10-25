# 2027 지방대회 대비 모의고사 1회 · 제2과제

## 응시 방법

1. 타이머를 4시간으로 맞추고 시작합니다. 인터넷은 AWS 공식 문서만 참고합니다.
2. 과제를 마치면 서울 리전 CloudShell에서 페이지 하단의 채점 스크립트를 내려받아 `<비번호>`와 함께 실행합니다.
3. 출력 전체를 복사해 하단 제출 칸에 붙여넣고 제출합니다. 마지막 줄의 `TOTAL SCORE`가 점수입니다.
4. 채점 스크립트는 3번 문항을 확인하려고 `stop-dev-instances`를 실제로 실행해 dev 인스턴스를 중지합니다. 다시 채점하려면 dev 인스턴스를 먼저 시작해 두세요.
5. 채점이 끝나면 리소스를 모두 삭제합니다.

| 항목 | 내용 |
| --- | --- |
| 과제명 | Small challenge |
| 경기시간 | 4시간 |
| 배점 | 50점 |
| 리전 | 문항별 지정 (서울, 도쿄, CloudFront·WAF는 Global) |
| 채점 위치 | 서울 리전 CloudShell |

## 1. 요구사항

1. Static website with CDN (서울 + Global)
2. Serverless workflow (서울)
3. Event-driven automation (도쿄)
4. Conditional IAM policy (서울)

## 2. 선수 유의사항

1. 문제의 괄호 `< >`는 변수입니다. `<비번호>`는 본인 비번호(숫자)로 바꿉니다.
2. 채점은 CloudShell에서 진행합니다. 브라우저 접속과 권한에 문제가 없도록 합니다.
3. 각 문항에서 요구하는 리전에 리소스를 생성합니다.
4. Tag 정보가 맞지 않거나 권한 문제로 채점이 불가능하지 않도록 합니다.

## 3. Static website with CDN

SkillsCafe 메뉴 페이지를 S3에 올리고 CloudFront로 배포합니다. S3 버킷은 인터넷에서 직접 접근할 수 없고, CloudFront를 통해서만 읽을 수 있어야 합니다. 한 사용자가 요청을 과도하게 보내면 WAF로 차단합니다.

S3 구성 (서울)

- Bucket name: `cafe-web-<비번호>` / 퍼블릭 액세스 차단 4개 모두 활성화
- `index.html` 내용: `<h1>SkillsCafe Menu v1</h1>`
- `error.html` 내용: `<h1>Oops</h1>`

CloudFront 구성

- Tag: `Name=cafe-cdn` / Origin: 위 S3 버킷, Origin Access Control(OAC) 사용 (OAI 사용 금지)
- Default root object: `index.html` / HTTP 요청은 HTTPS로 Redirect
- 없는 경로(403/404) 요청 시 `/error.html`을 HTTP 404로 반환
- 전 세계 모든 엣지 로케이션 사용(Price class All)

WAF 구성

- Web ACL name: `cafe-web-acl` / Scope: CloudFront
- Rate-based rule `cafe-rate-limit`: 동일 IP에서 5분간 100회 초과 요청 시 Block
- AWS Managed rule `AWSManagedRulesCommonRuleSet` 적용

## 4. Serverless workflow

주문 처리 절차를 Step Functions로 자동화합니다. 수량(qty)이 10을 넘는 주문은 거절하고, 나머지는 Lambda로 제조한 뒤 결과를 DynamoDB에 기록합니다. DynamoDB 기록은 Lambda를 거치지 않고 Step Functions의 DynamoDB 서비스 통합(PutItem)으로 처리합니다.

- DynamoDB table: `cafe-order-status` / Partition key: `order_id` (S) / On-demand
- Lambda: `cafe-make-coffee` (Python 3.12) / 입력 주문을 그대로 받아 `{"order_id": ..., "status": "DONE"}`를 반환
- State machine: `cafe-order-flow` / Type: Standard
- 로그: Log level ALL, Log group `/aws/vendedlogs/states/cafe-order-flow`

| 입력 | 실행 결과(output) | DynamoDB status |
| --- | --- | --- |
| `{"order_id": "o-1", "menu": "latte", "qty": 2}` | `{"order_id": "o-1", "status": "DONE"}` | DONE |
| `{"order_id": "o-2", "menu": "mocha", "qty": 30}` | `{"order_id": "o-2", "status": "REJECTED"}` | REJECTED |

## 5. Event-driven automation

이 문항은 ap-northeast-1(도쿄) 리전을 사용합니다. 개발용 EC2를 매일 밤 자동으로 중지하고, 인스턴스가 중지되면 담당자에게 알림을 보냅니다.

- 테스트 EC2: `dev-web-1`, `dev-web-2` (Tag `Env=dev`), `prod-web-1` (Tag `Env=prod`) / t3.micro / Amazon Linux 2023
- Lambda: `stop-dev-instances` (Python 3.12) / `Env=dev` 태그가 있고 running 상태인 인스턴스만 중지, 중지한 인스턴스 ID 목록을 반환
- EventBridge Scheduler: `stop-dev-schedule` / 매일 22:00 (Asia/Seoul) / 대상 `stop-dev-instances`
- EventBridge rule: `ec2-stopped-rule` / EC2 상태가 `stopped`로 바뀔 때만 감지 / 대상 SNS topic `ec2-state-topic`
- Lambda 실행 역할은 `ec2:DescribeInstances`, `ec2:StopInstances`와 로그 권한만 가집니다. `ec2:StopInstances`는 `Env=dev` 태그가 있는 인스턴스에만 허용합니다.
- 채점 전 세 인스턴스는 모두 running 상태여야 합니다.

## 6. Conditional IAM policy

인턴 직원이 공유 버킷을 안전하게 쓰도록 IAM 조건을 건 정책을 만듭니다.

- Bucket: `cafe-share-<비번호>` / 버킷 정책으로 HTTPS가 아닌 요청(`aws:SecureTransport = false`)을 모두 Deny
- IAM role: `intern-role` / 선수 계정의 모든 user와 role이 assume 가능 / 붙은 정책은 `intern-policy` 하나뿐
- IAM policy `intern-policy`: `intern/` 접두사 아래 객체만 읽기(GetObject)·쓰기(PutObject) 가능
- IAM policy `intern-policy`: PutObject는 SSE-KMS 암호화 헤더(`x-amz-server-side-encryption: aws:kms`)가 있는 요청만 허용
- IAM policy `intern-policy`: `intern/` 아래에서만 ListBucket 가능, 객체 삭제는 불가

| 요청 (intern-role로 실행) | 기대 결과 |
| --- | --- |
| `aws s3 cp a.txt s3://cafe-share-<비번호>/intern/a.txt --sse aws:kms` | 성공 |
| `aws s3 cp a.txt s3://cafe-share-<비번호>/intern/b.txt` | AccessDenied |
| `aws s3 cp a.txt s3://cafe-share-<비번호>/admin/a.txt --sse aws:kms` | AccessDenied |
| `aws s3 rm s3://cafe-share-<비번호>/intern/a.txt` | AccessDenied |

## 배점

| 번호 | 주요항목 | 세부항목 (배점) | 합계 |
| --- | --- | --- | --- |
| 1 | Static website with CDN | 퍼블릭 차단 1.5, S3 직접 접근 403 1.5, OAC 2, Root object·HTTPS Redirect 1.5, 페이지 출력 2, 에러 페이지 1.5, Price class 1, WAF 연결 1.5, WAF 규칙 1.5 | 14 |
| 2 | Serverless workflow | Table 1.5, Lambda 1.5, Standard 1.5, 로그 ALL 1.5, DynamoDB 서비스 통합 2, 정상 주문 2, 거절 주문 2, DB 기록 1 | 13 |
| 3 | Event-driven automation | Scheduler 2, Rule 패턴 2, Rule 대상 SNS 1, Lambda 런타임 1, 태그 조건 IAM 2, 동작(dev만 중지) 4 | 12 |
| 4 | Conditional IAM policy | HTTPS 강제 2, Trust policy 1.5, 정책 1개 1.5, 동작 테스트 4건 × 1.5 | 11 |
|  | **합계** |  | **50** |
