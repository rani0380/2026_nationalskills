# 2027 지방대회 대비 모의고사 2회 · 제2과제

## 과제 개요

서로 독립된 네 가지 클라우드 운영 과제를 수행합니다. 서울 리전에서는 Terraform 기반 인프라 재구축, 클릭 로그 분석 파이프라인, 메모 REST API를 구현하고, 도쿄 리전에서는 Systems Manager로 웹 서버 두 대의 설정을 일괄 갱신합니다.

| 항목 | 내용 |
| --- | --- |
| 과제명 | Small challenge |
| 경기시간 | 4시간 |
| 총점 | 50점 |
| 1번 문항 | Infrastructure as Code · 서울 · 14점 |
| 2번 문항 | Streaming data lake · 서울 · 13점 |
| 3번 문항 | Serverless REST API · 서울 · 13점 |
| 4번 문항 | Fleet operation with SSM · 도쿄 · 10점 |
| 채점 실행 위치 | 서울 리전의 iac-bastion, ec2-user 계정 |
| 참고 자료 | AWS 및 Terraform 공식 문서 |

이 문서는 문제의 구성 조건과 완료 기준을 설명합니다. 네 문항의 구현 순서는 자유이며, 1번 문항을 제외한 문항은 AWS 콘솔 또는 CLI 등으로 구성할 수 있습니다.

## 1. 공통 조건 및 선수 유의사항

### 1.1. 이름과 리전

- `<비번호>`는 본인에게 부여된 숫자로 치환합니다. 예를 들어 비번호가 17이면 상태 버킷 이름은 `iac-tfstate-17`입니다.
- 서울 리전 코드는 `ap-northeast-2`, 도쿄 리전 코드는 `ap-northeast-1`입니다.
- 문항 1~3은 서울, 문항 4는 도쿄에 생성합니다. IAM은 전역 서비스이므로 역할에 리전 선택은 없습니다.
- 리소스 이름, EC2의 Name 태그, 파라미터 경로, 테이블명, 출력 변수명은 문제에서 지정한 철자를 정확하게 사용합니다.
- 같은 계정·리전에서 채점 대상과 이름이 같은 리소스를 중복 생성하지 않습니다. 도쿄에서 `Role=web` 태그를 가진 SSM 관리 노드는 이 문항의 두 대만 남겨 둡니다.
- S3 버킷 이름은 전역에서 고유해야 합니다. 지정 이름을 다른 계정이 사용 중이라 생성할 수 없으면 감독자에게 알립니다. 임의로 접미사를 붙이면 기존 채점 스크립트가 찾지 못합니다.
- 명시하지 않은 설정은 기본값을 사용할 수 있으나, 필요한 네트워크 경로·IAM 권한·서비스 간 연결은 선수가 완성해야 합니다.

### 1.2. 채점 환경

- `iac-bastion`에는 AWS CLI v2, Terraform, curl, jq가 설치되어 있어야 합니다.
- 채점은 `ec2-user`로 실행합니다. Terraform 파일은 `/home/ec2-user/iac/`에 두고, 해당 사용자가 읽고 실행할 수 있어야 합니다.
- Bastion의 인스턴스 프로파일에는 이 실습에서 지정한 `AdministratorAccess`를 연결합니다. AWS 리소스 조회·생성·삭제, IAM 조회, API 키 조회, SSM 명령 실행이 가능해야 합니다.
- 정적 Access Key를 코드나 user_data에 넣지 않고 인스턴스 역할을 사용합니다.
- Bastion은 Terraform provider 다운로드, 패키지 설치, 서울·도쿄 AWS API 호출, 생성한 웹/API 주소 접근이 가능해야 합니다.
- 입력 변수가 있으면 기본값 또는 코드 경로의 자동 로드 tfvars 파일로 값을 공급합니다. 채점자가 별도 `-var`, `-var-file`, `-backend-config` 옵션을 주지 않아도 실행되어야 합니다.

### 1.3. 채점 중 실제로 변경되는 항목

- 1번 문항은 Terraform의 `init → destroy → apply`를 실제로 실행합니다. 현재 존재하는 웹 서버의 설정만 맞추는 것으로는 충분하지 않으며, 삭제 후 코드만으로 동일한 기능을 재현해야 합니다.
- Bastion, S3 상태 버킷, 문항 2~4의 리소스는 1번 문항의 Terraform state에 포함하지 않습니다. 채점 중 삭제되면 채점이 중단되거나 다른 문항 점수를 잃을 수 있습니다.
- 3번 문항은 실제 POST 요청으로 메모를 생성한 뒤 같은 ID로 조회합니다.
- 4번 문항은 SecureString 값을 임시 문자열로 바꾸고 association을 즉시 실행합니다. 두 서버가 새 값을 반환하는지 확인한 뒤 Parameter Store의 원래 값을 복원합니다.
- 현재 스크립트는 파라미터 복원 직후 association을 다시 실행하지 않습니다. 서버 파일까지 원래 값으로 되돌리려면 채점 후 association을 다시 실행하고 두 대의 응답을 확인합니다.
- Terraform 재구축, 서비스 준비 및 SSM 검증 대기 때문에 채점에 수 분 이상 걸릴 수 있습니다. 끝나기 전에 터미널을 닫거나 중단하지 않습니다.

## 2. Infrastructure as Code · 14점

### 2.1. 수행 목표

Terraform으로 독립된 VPC와 공개 웹 서버를 구성합니다. 기존 환경을 삭제한 뒤 다시 적용해도 nginx가 자동 설치되고 지정 문구를 반환해야 합니다.

구성 흐름: 인터넷 → Internet Gateway → 공개 서브넷 → iac-web의 TCP 80 → nginx.

### 2.2. 사전 준비 리소스

| 항목 | 요구사항 |
| --- | --- |
| Bastion 이름 | EC2 Name 태그 `iac-bastion` |
| Bastion 네트워크 | 서울 리전 Default VPC, AWS API와 인터넷 접근 가능 |
| Bastion 사양 | t3.micro, Amazon Linux 2023 |
| Bastion 역할 | AdministratorAccess가 연결된 EC2 인스턴스 역할 |
| 코드 경로 | `/home/ec2-user/iac/` |
| 상태 버킷 | `iac-tfstate-<비번호>`, 서울 리전, 사전 수동 생성 |
| 상태 버킷 버전 관리 | Enabled |

Bastion과 상태 버킷은 재구축 대상 외부에 둡니다. 상태 버킷을 같은 Terraform 구성에서 생성·삭제하거나, 재구축 대상 VPC에 Bastion을 배치하지 않습니다.

### 2.3. Terraform 실행 및 상태 관리

- S3 backend의 bucket은 `iac-tfstate-<비번호>`, key는 `iac/terraform.tfstate`, region은 `ap-northeast-2`로 설정합니다.
- S3 native locking을 사용하도록 `use_lockfile = true`를 설정합니다. 이 옵션을 지원하는 Terraform 버전을 설치합니다.
- EC2 역할은 state 객체 읽기·쓰기와 잠금 객체 생성·삭제가 가능해야 합니다.
- AWS provider의 `default_tags`에 `Project = "KoreaSkills"`를 설정합니다. 태그를 지원하는 재구축 대상 리소스에 이 값이 적용되어야 합니다.
- 아래 명령이 코드 경로에서 사용자 입력 없이 모두 성공해야 합니다. 콘솔에서 수동으로 보완한 설정도 재구축 후 유지되어야 하므로 코드에 반영합니다.

```bash
cd /home/ec2-user/iac
terraform init -input=false -no-color
terraform destroy -auto-approve -input=false -no-color
terraform apply -auto-approve -input=false -no-color
terraform output -raw web_url
```

### 2.4. 네트워크 구성

| 리소스 | 이름 | 설정 |
| --- | --- | --- |
| VPC | iac-vpc | CIDR 10.50.0.0/16 |
| 공개 서브넷 A | iac-pub-a | 10.50.0.0/24, ap-northeast-2a |
| 공개 서브넷 C | iac-pub-c | 10.50.1.0/24, ap-northeast-2c |
| Internet Gateway | iac-igw | iac-vpc에 연결 |
| 라우팅 | 이름 자유 | 두 공개 서브넷에서 0.0.0.0/0 → iac-igw |
| 보안 그룹 | iac-web-sg | iac-vpc에 생성, 인바운드는 TCP 80만 허용 |

- VPC·서브넷·IGW의 이름은 Name 태그로 지정합니다. 보안 그룹은 그룹 이름을 `iac-web-sg`로 생성합니다.
- 웹 서버는 두 공개 서브넷 중 한 곳에 한 대만 배치하고 공인 IPv4를 부여합니다.
- HTTP 접근을 위해 TCP 80의 소스는 `0.0.0.0/0`으로 설정합니다.
- SSH 22, HTTPS 443, 모든 트래픽 등 다른 인바운드 규칙을 추가하지 않습니다. 아웃바운드는 패키지 설치와 응답에 필요한 통신을 허용합니다.

### 2.5. 웹 서버 및 출력

- EC2 Name 태그는 `iac-web`, 인스턴스 유형은 `t3.micro`입니다.
- AMI ID를 하드코딩하지 않고 SSM Parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`를 Terraform data source로 조회합니다.
- 연결되는 EBS 볼륨을 암호화합니다. 메타데이터 옵션은 IMDSv2 필수, 즉 `HttpTokens=required`로 설정합니다.
- user_data에서 nginx 설치, 서비스 시작 및 부팅 시 자동 시작을 처리합니다.
- 루트 경로 `/`의 응답 본문은 `Hello Terraform`이어야 합니다. 마지막 줄바꿈은 허용합니다.
- Terraform output 이름은 `web_url`, 값은 `http://<iac-web의 현재 공인 IPv4>`입니다. 재구축으로 IP가 바뀌면 output도 새 IP를 가리켜야 합니다.
- `terraform apply` 완료와 user_data 완료 시점은 다를 수 있습니다. nginx 준비 후 Bastion에서 출력 URL로 접속되는지 확인합니다.

완료 기준: 코드만으로 재구축되고, 원격 상태·버전 관리·태그·네트워크·보안 설정이 유지되며, `web_url`에 HTTP 요청하면 지정 문구가 출력됩니다.

## 3. Streaming data lake · 13점

### 3.1. 수행 목표

웹 클릭 이벤트 6건을 Amazon Data Firehose에 전송합니다. S3에 적재된 JSON 로그를 Glue Data Catalog에 등록하고 Athena의 저장 쿼리로 페이지별 클릭 수를 집계합니다.

구성 흐름: Direct PUT → click-stream → S3 clicks/ 날짜 경로 → click-crawler → click_db.clicks → click-wg.

### 3.2. S3 및 Firehose

| 항목 | 요구사항 |
| --- | --- |
| 로그 버킷 | `click-lake-<비번호>`, 서울 리전 |
| Athena 결과 버킷 | `click-result-<비번호>`, 서울 리전 |
| Firehose 이름 | `click-stream` |
| 소스 | Direct PUT |
| 대상 | 로그 버킷의 S3 목적지 |
| Buffer interval | 60초 |
| Buffer size | 1 MiB |
| S3 prefix | `clicks/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/` |
| Error prefix | `errors/!{firehose:error-output-type}/` |

- 버퍼 설정은 시간 60초와 크기 1 MiB를 모두 지정합니다. 두 조건 중 먼저 충족되는 조건에 따라 전송되므로, 6건처럼 작은 데이터도 적재 완료까지 기다려야 합니다.
- 로그는 UTF-8의 줄바꿈 구분 JSON으로 저장합니다. 레코드 사이에는 실제 LF 줄바꿈이 있어야 합니다. 이 과제에서는 형식 변환 없이 JSON을 그대로 적재합니다.
- Firehose 실행 역할에는 목적지 버킷 적재에 필요한 권한을 부여합니다.
- 날짜 경로는 JSON의 `ts` 필드가 아니라 Firehose의 도착 시각을 기준으로 생성합니다. 기본 UTC 시간대를 사용하며, `2027/04/01`로 고정하지 않습니다.
- Error prefix는 설정값을 평가합니다. 오류 객체를 만들기 위해 테스트 데이터를 일부러 실패시킬 필요는 없습니다.

### 3.3. 테스트 데이터

아래 6건을 각각 JSON 레코드로 한 번씩 전송합니다. 필드명은 `user`, `page`, `ts`입니다. 아래 시간은 분석용 문자열이며 실제 실습 날짜와 같을 필요는 없습니다.

```json
{"user":"u1","page":"/menu","ts":"2027-04-01T10:00:00"}
{"user":"u2","page":"/menu","ts":"2027-04-01T10:00:05"}
{"user":"u3","page":"/order","ts":"2027-04-01T10:00:09"}
{"user":"u1","page":"/order","ts":"2027-04-01T10:01:00"}
{"user":"u4","page":"/menu","ts":"2027-04-01T10:01:30"}
{"user":"u5","page":"/event","ts":"2027-04-01T10:02:00"}
```

이 블록은 단일 JSON 배열이 아니라 6개의 JSON 객체를 한 줄씩 표현한 것입니다. 각 레코드의 끝에는 줄바꿈을 포함해야 합니다.

한 건 전송 예시:

```bash
aws firehose put-record \
  --region ap-northeast-2 \
  --delivery-stream-name click-stream \
  --cli-binary-format raw-in-base64-out \
  --record '{"Data":"{\"user\":\"u1\",\"page\":\"/menu\",\"ts\":\"2027-04-01T10:00:00\"}\n"}'
```

- 예시 명령은 첫 번째 레코드를 실제 전송합니다. 예시를 실행한 뒤 전체 6건을 다시 보내면 첫 번째 레코드가 중복됩니다.
- 채점 시 `clicks` 테이블에는 정확히 이 6건만 조회되어야 합니다. 이전 테스트 데이터나 재전송된 데이터가 섞이지 않게 확인합니다.
- API 전송 성공만으로 S3 적재 완료를 판단하지 않습니다. S3 객체 생성과 그 안의 줄바꿈·레코드 수를 확인한 뒤 crawler를 실행합니다.

### 3.4. Glue 카탈로그

- Glue crawler 이름은 `click-crawler`, 대상은 `s3://click-lake-<비번호>/clicks/`입니다. 오류 경로와 Athena 결과 버킷은 크롤링 대상에 넣지 않습니다.
- 데이터베이스 이름은 `click_db`, 최종 테이블 이름은 `clicks`입니다.
- 컬럼 `user`, `page`, `ts`를 읽을 수 있어야 하고, 파티션 키는 `year`, `month`, `day` 순서여야 합니다.
- crawler 역할에는 대상 S3 경로 읽기와 Glue 카탈로그 갱신에 필요한 권한을 부여합니다.
- crawler를 실행해 완료 상태를 확인합니다. 생성된 테이블 이름·Location·JSON 스키마·파티션이 요구사항과 다른 경우 최종 카탈로그 구성을 바로잡습니다.
- 데이터가 다른 날짜 경로에 새로 적재되었다면 해당 파티션도 등록되어야 합니다.

### 3.5. Athena 분석

| 항목 | 요구사항 |
| --- | --- |
| Workgroup | `click-wg` |
| 쿼리당 스캔 제한 | 104857600 bytes, 즉 100 MiB |
| 쿼리 결과 위치 | `s3://click-result-<비번호>/` |
| Saved query 이름 | `click-top-pages` |
| Saved query 소속 | Workgroup click-wg, Database click_db |

저장 쿼리는 `clicks` 테이블 전체에서 page별 레코드 수를 집계하고, 결과 컬럼명을 `page`, `cnt`로 지정합니다. cnt 내림차순으로 상위 3개만 반환해야 합니다. 결과를 상수로 반환하거나 중복을 숨기기 위해 별도 필터를 넣지 않습니다.

| page | cnt |
| --- | --- |
| /menu | 3 |
| /order | 2 |
| /event | 1 |

완료 기준: 채점자가 click-wg에서 저장 쿼리를 실행하면, 컬럼 순서를 포함해 위 결과가 그대로 출력됩니다.

## 4. Serverless REST API · 13점

### 4.1. 수행 목표

DynamoDB에 메모를 저장하고 조회하는 REST API를 구현합니다. API Gateway의 API key 필수 설정과 Usage plan을 연결하여, 유효한 키를 포함한 요청만 지정 메서드를 호출할 수 있게 합니다.

구성 흐름: HTTP 클라이언트 → memo-api의 prod Stage → memo-handler → memo-table.

### 4.2. DynamoDB와 Lambda

| 항목 | 요구사항 |
| --- | --- |
| DynamoDB 테이블 | `memo-table` |
| Partition key | `memo_id`, String |
| 용량 모드 | On-demand |
| Lambda 함수 | `memo-handler` |
| 런타임 | Python 3.12 |
| 환경 변수 | `TABLE_NAME=memo-table` |

- POST 처리 시 UUID 형식의 새 memo_id를 생성하고, 요청의 text와 함께 DynamoDB에 저장합니다.
- GET 처리 시 경로 변수 memo_id로 저장된 항목을 조회합니다. 하드코딩된 응답 대신 실제 테이블 데이터를 반환합니다.
- 존재하지 않는 ID는 예외가 발생하는 500 응답 대신 지정된 404 응답으로 처리합니다.
- Lambda proxy 응답의 statusCode와 JSON 문자열 body를 올바르게 구성하고, 응답 Content-Type은 application/json으로 지정합니다.
- 정상 입력과 없는 ID의 처리까지가 이 문항의 필수 응답 범위입니다. 추가 입력 검증을 구현해도 아래 필수 응답을 바꾸면 안 됩니다.

### 4.3. IAM 권한

- Lambda 실행 역할은 Lambda 서비스가 AssumeRole할 수 있어야 합니다.
- DynamoDB 데이터 접근 권한은 서울 리전, 본인 계정의 `memo-table` ARN에 대한 `dynamodb:PutItem`, `dynamodb:GetItem` 두 작업으로 제한합니다.
- DynamoDB에 대한 `Resource: "*"`, `dynamodb:*`, Scan·DeleteItem 등 불필요한 작업과 DynamoDB 광범위 관리형 정책을 추가하지 않습니다.
- CloudWatch Logs 기록 권한은 별도로 허용할 수 있습니다. “PutItem·GetItem만”이라는 조건은 DynamoDB 접근 범위를 의미합니다.
- API Gateway가 memo-handler를 호출할 수 있도록 Lambda 리소스 기반 호출 권한도 설정합니다.

### 4.4. API Gateway와 Usage plan

- API 유형은 HTTP API가 아닌 REST API이며, 이름은 `memo-api`입니다.
- 리소스 `/memos`에 POST, `/memos/{memo_id}`에 GET 메서드를 생성합니다.
- 두 메서드 모두 memo-handler에 대한 Lambda proxy integration을 사용합니다.
- 두 메서드 모두 API key required를 활성화하고 키 소스는 HEADER로 설정합니다.
- 변경 사항을 `prod` Stage로 배포합니다. 메서드 설정 변경 후 재배포가 필요한지 확인합니다.
- 이름이 `memo-key`인 활성 API key를 생성합니다. 요청의 x-api-key에는 키의 이름이나 ID가 아닌 실제 키 값을 넣습니다.
- `memo-plan` Usage plan에 해당 REST API의 prod Stage와 memo-key를 모두 연결합니다.

| Usage plan 항목 | 값 |
| --- | --- |
| Rate limit | 10 requests/second |
| Burst limit | 20 |
| Quota limit | 1000 |
| Quota period | DAY |

Usage plan의 rate·quota는 서비스의 최선 노력 방식으로 적용됩니다. 정확히 1001번째 요청에서 차단되는 것을 이 과제의 완료 조건으로 삼지 않습니다. API key는 이 과제의 호출 조건이며 사용자 신원 인증을 구현하는 요구사항은 아닙니다.

### 4.5. 필수 요청·응답

기본 URL은 `https://<REST-API-ID>.execute-api.ap-northeast-2.amazonaws.com/prod`입니다.

| 요청 | 조건 | HTTP 상태 | JSON 응답 |
| --- | --- | --- | --- |
| POST /memos | 유효한 x-api-key, Content-Type: application/json, 본문 {"text":"hello"} | 201 | {"memo_id":"<생성된 UUID>"} |
| GET /memos/{memo_id} | 유효한 x-api-key, 직전에 생성한 ID | 200 | {"memo_id":"<같은 UUID>","text":"hello"} |
| GET /memos/{memo_id} | 유효한 x-api-key, 저장되지 않은 ID | 404 | {"error":"not found"} |
| POST /memos 또는 GET /memos/{memo_id} | x-api-key 없음 | 403 | API Gateway 기본 오류 본문 허용 |

- JSON 속성 순서와 공백은 자유입니다. 상태 코드는 본문의 숫자가 아니라 실제 HTTP 상태여야 합니다.
- “키 없음 403”의 범위는 이 과제에서 구성한 두 메서드입니다. 존재하지 않는 다른 경로까지 별도로 구현할 필요는 없습니다.
- 채점 스크립트는 POST 응답의 첫 줄에서 memo_id를 읽으므로 JSON 응답은 한 줄로 직렬화합니다.
- 채점 전 새 메모 생성 → 같은 ID 조회 → 없는 ID 조회 → 키 없는 요청 순서로 확인합니다.

완료 기준: 새 요청마다 UUID를 생성해 저장하고, 유효한 키로 동일 메모를 조회할 수 있으며, 없는 메모와 키 없는 요청에 각각 지정 상태를 반환합니다.

## 5. Fleet operation with SSM · 10점

### 5.1. 수행 목표

도쿄 리전 웹 서버 두 대에 직접 SSH 접속하지 않고, Parameter Store의 값을 State Manager association으로 배포합니다. 파라미터 변경 후 Document나 인스턴스를 수정하지 않아도 재실행만으로 두 서버의 웹 문구가 갱신되어야 합니다.

구성 흐름: /ops/web/message → ops-update-index → ops-association → Role=web 서버 두 대의 nginx index.html.

### 5.2. 웹 서버와 관리 연결

| 항목 | 요구사항 |
| --- | --- |
| 리전 | ap-northeast-1 |
| EC2 Name 태그 | `ops-web-1`, `ops-web-2` |
| 공통 대상 태그 | 두 인스턴스 모두 `Role=web` |
| 인스턴스 유형 | t3.micro |
| 운영체제 | Amazon Linux 2023 |
| 실행 역할 | `ops-ssm-role` |
| 웹 서비스 | nginx, 실행 중이며 재부팅 후 자동 시작 |
| SSH | 연결된 모든 보안 그룹에서 TCP 22 접근 금지 |

- 인스턴스 프로파일을 통해 ops-ssm-role을 두 서버에 연결하고, 역할에 AmazonSSMManagedInstanceCore를 부여합니다.
- SSM Agent를 실행하고 Systems Manager에서 두 대 모두 Online으로 표시되는지 확인합니다.
- SSM·Parameter Store 및 패키지 설치 대상에 접근 가능한 네트워크를 구성합니다. 필요한 인터넷 경로나 VPC endpoint 등은 구현 방식에 맞게 선택합니다.
- 다른 포트 범위나 모든 트래픽 규칙으로 SSH 22를 간접 허용하지 않습니다.
- 채점은 SSM Run Command에서 `curl -s localhost`로 확인하므로 공인 웹 접근이나 인바운드 80 개방은 필수 조건이 아닙니다.

### 5.3. Parameter Store와 읽기 권한

- 파라미터 이름은 `/ops/web/message`, Type은 `SecureString`, 초기 값은 `Hello Ops`입니다.
- ops-ssm-role에는 이 도쿄 리전 파라미터를 읽는 `ssm:GetParameter` 권한을 부여합니다.
- Document는 복호화 옵션으로 값을 읽습니다. 고객 관리형 KMS 키를 선택했다면 역할과 키 정책에 필요한 복호화 권한도 설정합니다.
- 초기 문구를 user_data나 Document에 고정해서 기록하는 것으로 요구사항을 대신하지 않습니다.

### 5.4. SSM Document

- 이름은 `ops-update-index`, Type은 `Command`입니다.
- 서버에서 실행될 때마다 도쿄 리전의 /ops/web/message 최신 값을 조회하고 복호화합니다.
- 조회 결과의 Value 문자열만 `/usr/share/nginx/html/index.html`에 기록합니다. JSON 전체나 파라미터 이름을 쓰지 않습니다.
- 공백이 포함된 값도 그대로 저장하도록 셸 인용을 처리합니다.
- 반복 실행 시 문자열을 누적 append하지 않고 기존 파일을 새 값으로 덮어씁니다.
- nginx가 파일을 제공할 수 있도록 경로·권한을 맞춥니다. 같은 Document를 여러 번 실행해도 정상 상태가 유지되어야 합니다.

### 5.5. State Manager association

| 항목 | 요구사항 |
| --- | --- |
| Association 이름 | `ops-association` |
| 실행 Document | `ops-update-index` |
| Target key | `tag:Role` |
| Target value | `web` |
| Schedule expression | `rate(30 minutes)` |

인스턴스 ID 두 개를 직접 고정하는 대신 태그를 대상으로 지정합니다. 정기 실행뿐 아니라 “지금 한 번 실행” 요청도 두 서버에 적용되어야 합니다.

### 5.6. 동작 확인

1. 초기 association 실행 후 두 서버의 `curl -s localhost`가 Hello Ops를 반환하는지 확인합니다.
2. 파라미터 값을 공백이 포함된 다른 문자열로 변경합니다.
3. ops-association을 수동으로 한 번 실행하고 대상 두 대의 실행 완료를 기다립니다.
4. SSM Run Command로 두 서버의 응답을 확인합니다. 두 대 모두 변경한 문자열을 반환해야 합니다.
5. 제출 전 파라미터 값을 Hello Ops로 복원하고 association을 다시 실행해 서버 파일도 초기 상태로 맞춥니다.

완료 기준: 두 대 모두 Online이고, 파라미터 변경 후 association 재실행만으로 두 서버의 HTTP 응답이 같은 새 값으로 바뀝니다.

## 6. 최종 확인 및 제출

### 6.1. 채점 전 확인

| 문항 | 확인할 내용 |
| --- | --- |
| 1 | 코드 경로, 무인 재구축, backend 설정, 버전 관리, web_url 및 HTTP 응답 |
| 2 | Firehose 적재 완료, JSON 6건만 존재, Glue 파티션 등록, 저장 쿼리 결과 |
| 3 | prod 배포, API key 필수 설정, Usage plan 연결, 필수 상태 코드, IAM 범위 |
| 4 | 도쿄 SSM 두 대 Online, SecureString 읽기, 태그 대상 association, 두 대 갱신 |

서비스 생성 직후에는 EC2 초기화·Firehose 적재·Glue crawler·API 설정 전파·SSM 등록이 완료되지 않았을 수 있습니다. 각 서비스의 완료 상태와 실제 동작을 확인한 뒤 채점을 시작합니다.

### 6.2. 채점 스크립트 실행

서울 리전 iac-bastion에 ec2-user로 접속하고 아래 명령을 실행합니다. 마지막 인수의 `<비번호>`는 실제 숫자로 바꿉니다.

```bash
curl -fL "https://rani0380.github.io/2026_nationalskills/downloads/mock2027/mock2-2_mark.sh" -o ~/mock2-2_mark.sh
bash ~/mock2-2_mark.sh <비번호>
```

- 모든 문항은 이 Bastion에서 함께 채점합니다. 도쿄 서버에서 채점 스크립트를 따로 실행하지 않습니다.
- 출력의 O/X, 항목 번호, 확인값을 살펴보고 실패한 설정을 보완합니다.
- Terraform 실패 시 Bastion의 `/tmp/mock2_tf.log`에서 원인을 확인할 수 있습니다.
- 현재 스크립트의 마지막 점수 표기는 `TOTAL SCORE: <획득점수> / 50`이며, 그 아래 구분선이 출력됩니다.
- 출력 전체를 페이지 하단 제출 칸에 붙여넣고 비번호·이름을 입력하여 제출합니다. 결과 파일도 저장해 둡니다.
- 비밀번호, AWS Access Key, Secret Access Key, Session Token은 제출하지 않습니다.

### 6.3. 종료 및 정리

채점 결과 저장·제출과 감독자의 확인이 끝난 뒤 리소스를 정리합니다. 채점 전에 삭제하지 않습니다.

1. 1번 문항의 코드 경로에서 terraform destroy를 실행합니다.
2. 문항 2~4에서 만든 Firehose, Glue crawler·catalog, API Gateway, Lambda, DynamoDB, SSM association·Document·Parameter, 도쿄 EC2 등 실습 리소스를 정리합니다.
3. S3 객체와 버전 관리 버킷의 이전 버전·삭제 마커를 포함해 정리한 뒤 버킷을 삭제합니다. backend 버킷은 Terraform 리소스 삭제가 끝난 뒤 정리합니다.
4. 사용하지 않는 실습 IAM 역할·정책·인스턴스 프로파일을 정리하고, Bastion은 마지막에 삭제합니다. 다른 과제나 공용 리소스는 정리 대상에서 제외합니다.

## 7. 배점

기존 배점은 유지합니다. 아래 항목은 현재 자동 채점 항목의 요약이며, 자동 검사에 직접 포함되지 않는 세부 조건도 문제의 구현 요구사항입니다.

| 번호 | 주요항목 | 세부항목 (배점) | 합계 |
| --- | --- | --- | --- |
| 1 | Infrastructure as Code | apply 무인 성공 3, S3 backend 2, default_tags 1.5, VPC·서브넷 2, SG(SSH 없음) 1.5, EBS 암호화·IMDSv2 2, 웹 응답 2 | 14 |
| 2 | Streaming data lake | Firehose 설정 2.5, Error prefix 1, 파티션 경로 1.5, Glue table 2, Workgroup 2, Saved query 1, 쿼리 결과 3 | 13 |
| 3 | Serverless REST API | Lambda 1, Stage 1, Usage plan 2, API key 1, 생성 201 2, 조회 200 2, 없는 ID 404 1.5, 키 없음 403 1.5, 최소 권한 1 | 13 |
| 4 | Fleet operation with SSM | Managed instance 2, SecureString 1, Document 1, Association 2, SSH 미개방 1, 값 변경 반영 3 | 10 |
| | 합계 | | 50 |

## 8. 공식 문서 참고

- Terraform S3 backend: https://developer.hashicorp.com/terraform/language/backend/s3
- Firehose S3 prefix 및 timestamp: https://docs.aws.amazon.com/firehose/latest/dev/s3-prefixes.html
- API Gateway Usage plan과 API key: https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-api-usage-plans.html
- Systems Manager association: https://docs.aws.amazon.com/systems-manager/latest/userguide/state-manager-associations.html
