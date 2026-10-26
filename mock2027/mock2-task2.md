# 2027 지방대회 대비 모의고사 2회 · 제2과제

## 응시 방법

1. 타이머를 4시간으로 맞추고 시작합니다. 인터넷은 AWS·Terraform 공식 문서만 참고합니다.
2. 과제를 마치면 `iac-bastion`에 `ec2-user`로 접속해 페이지 하단의 채점 스크립트를 내려받아 `<비번호>`와 함께 실행합니다. 모든 문항을 이 Bastion에서 채점합니다.
3. 채점 스크립트는 1번 문항을 위해 `terraform destroy`와 `terraform apply`를 실제로 실행합니다. 5분 안팎이 걸리니 끝날 때까지 기다립니다.
4. 출력 전체를 복사해 하단 제출 칸에 붙여넣고 제출합니다. 마지막 줄의 `TOTAL SCORE`가 점수입니다.
5. 채점 스크립트는 4번 문항을 위해 `/ops/web/message` 값을 바꾸고 association을 즉시 실행합니다.
6. 채점이 끝나면 `terraform destroy`를 포함해 리소스를 모두 삭제합니다.

| 항목 | 내용 |
| --- | --- |
| 과제명 | Small challenge |
| 경기시간 | 4시간 |
| 배점 | 50점 |
| 리전 | 문항별 지정 (서울, 도쿄) |
| 채점 위치 | `iac-bastion` (ec2-user) |

## 1. 요구사항

1. Infrastructure as Code (서울)
2. Streaming data lake (서울)
3. Serverless REST API (서울)
4. Fleet operation with SSM (도쿄)

## 2. 선수 유의사항

1. 문제의 괄호 `< >`는 변수입니다. `<비번호>`는 본인 비번호(숫자)로 바꿉니다.
2. 모든 문항은 `iac-bastion`에서 채점합니다. 이 Bastion에는 AWS CLI, curl, jq, Terraform이 설치되어 있어야 합니다.
3. 각 문항에서 요구하는 리전에 리소스를 생성합니다.
4. 문제에서 명시하지 않은 값은 기본값을 사용합니다.

## 3. Infrastructure as Code

Terraform으로 웹 서버 환경을 코드화합니다. 채점 전 채점자가 코드 경로에서 `terraform init` → `terraform destroy -auto-approve` → `terraform apply -auto-approve`를 실행한 뒤 결과를 확인합니다. 사람의 입력 없이 apply가 끝나야 합니다.

Bastion 구성

- EC2 name: `iac-bastion` / Default VPC / t3.micro / Amazon Linux 2023 / AdministratorAccess / Terraform, jq 설치
- 코드 경로: `/home/ec2-user/iac/` (이 경로 밖의 코드는 채점하지 않음)

Terraform 구성

- State는 S3 backend에 저장: Bucket `iac-tfstate-<비번호>`(미리 수동 생성, 버전 관리 활성화), Key `iac/terraform.tfstate`, S3 native lock(`use_lockfile = true`) 사용
- 모든 리소스에 `Project=KoreaSkills` 태그 (provider의 `default_tags` 사용)
- VPC `iac-vpc` 10.50.0.0/16 / Public subnet `iac-pub-a` 10.50.0.0/24 (ap-northeast-2a), `iac-pub-c` 10.50.1.0/24 (ap-northeast-2c) / IGW `iac-igw`
- Security group `iac-web-sg`: inbound TCP 80 허용, SSH 허용 금지
- EC2 `iac-web` / t3.micro / AMI는 SSM Parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`를 data source로 조회 / EBS 암호화 / IMDSv2 필수
- user_data로 nginx를 설치해 `/`에서 `Hello Terraform`을 반환
- Output `web_url` = `http://<iac-web 공인 IP>`

## 4. Streaming data lake

웹 클릭 로그를 Firehose로 S3에 쌓고, Glue로 카탈로그를 만든 뒤 Athena로 분석합니다.

- S3 bucket: `click-lake-<비번호>` / Athena 결과 버킷: `click-result-<비번호>`
- Firehose stream: `click-stream` / Source: Direct PUT / Destination: S3 / Buffer 60초 또는 1 MiB
- S3 prefix: `clicks/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/` / Error prefix: `errors/!{firehose:error-output-type}/`
- Glue crawler: `click-crawler` / Database: `click_db` / 생성되는 table 이름: `clicks` (year, month, day가 파티션 컬럼)
- Athena workgroup: `click-wg` / 쿼리당 스캔 제한 100 MB / 결과 위치 `s3://click-result-<비번호>/`
- Saved query `click-top-pages`: 페이지별 클릭 수 상위 3개, 컬럼은 `page`, `cnt` 두 개만, `cnt` 내림차순

테스트 데이터는 아래 레코드를 JSON으로 한 건씩 넣습니다(각 레코드 끝에 줄바꿈 포함). `/menu` 3회, `/order` 2회, `/event` 1회입니다. 채점 시점에 테이블에 이 6건만 있어야 합니다.

```csv
user,page,ts
u1,/menu,2027-04-01T10:00:00
u2,/menu,2027-04-01T10:00:05
u3,/order,2027-04-01T10:00:09
u1,/order,2027-04-01T10:01:00
u4,/menu,2027-04-01T10:01:30
u5,/event,2027-04-01T10:02:00
```

```bash
aws firehose put-record --delivery-stream-name click-stream --cli-binary-format raw-in-base64-out \
  --record '{"Data":"{\"user\":\"u1\",\"page\":\"/menu\",\"ts\":\"2027-04-01T10:00:00\"}\n"}'
```

## 5. Serverless REST API

메모 저장 API를 서버 없이 만듭니다. API 키가 없는 요청은 거부하고, 키별 사용량을 제한합니다.

- DynamoDB: `memo-table` / Partition key `memo_id` (S) / On-demand
- Lambda: `memo-handler` (Python 3.12) / 환경 변수 `TABLE_NAME` / 실행 역할은 `memo-table`의 PutItem·GetItem만 허용
- API Gateway: REST API `memo-api` / Stage `prod` / Lambda proxy integration
- Usage plan `memo-plan`: Rate 10 rps, Burst 20, Quota 1000회/일 / API key `memo-key` 연결

| API | Request | Response |
| --- | --- | --- |
| POST /memos | Header `x-api-key`, Body `{"text": "hello"}` | 201, `{"memo_id": "<uuid>"}` |
| GET /memos/{memo_id} | Header `x-api-key` | 200, `{"memo_id": "<uuid>", "text": "hello"}` |
| GET /memos/{memo_id} (없는 ID) | Header `x-api-key` | 404, `{"error": "not found"}` |
| 모든 요청 (키 없음) | - | 403 |

## 6. Fleet operation with SSM

이 문항은 ap-northeast-1(도쿄) 리전을 사용합니다. SSH 없이 Systems Manager만으로 여러 웹 서버의 설정을 일괄 관리합니다.

- EC2: `ops-web-1`, `ops-web-2` / Tag `Role=web` / t3.micro / Amazon Linux 2023 / nginx 설치 / Security group에 SSH(22) 없음
- IAM role: `ops-ssm-role` / `AmazonSSMManagedInstanceCore` + Parameter 읽기 권한
- Parameter Store: `/ops/web/message` / Type SecureString / Value `Hello Ops`
- SSM Document: `ops-update-index` / Type Command / Parameter를 읽어 `/usr/share/nginx/html/index.html`에 기록
- State Manager association: `ops-association` / 대상 Tag `Role=web` / 30분마다 `ops-update-index` 실행
- 채점자가 Parameter 값을 바꾼 뒤 association을 수동 실행하면, 두 서버의 `curl localhost`가 새 값을 출력해야 합니다.

## 배점

| 번호 | 주요항목 | 세부항목 (배점) | 합계 |
| --- | --- | --- | --- |
| 1 | Infrastructure as Code | apply 무인 성공 3, S3 backend 2, default_tags 1.5, VPC·서브넷 2, SG(SSH 없음) 1.5, EBS 암호화·IMDSv2 2, 웹 응답 2 | 14 |
| 2 | Streaming data lake | Firehose 설정 2.5, Error prefix 1, 파티션 경로 1.5, Glue table 2, Workgroup 2, Saved query 1, 쿼리 결과 3 | 13 |
| 3 | Serverless REST API | Lambda 1, Stage 1, Usage plan 2, API key 1, 생성 201 2, 조회 200 2, 없는 ID 404 1.5, 키 없음 403 1.5, 최소 권한 1 | 13 |
| 4 | Fleet operation with SSM | Managed instance 2, SecureString 1, Document 1, Association 2, SSH 미개방 1, 값 변경 반영 3 | 10 |
|  | **합계** |  | **50** |
