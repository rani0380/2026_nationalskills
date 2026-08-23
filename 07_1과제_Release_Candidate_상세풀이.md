# 07_1과제 Release Candidate 상세 풀이

대상: Unicorn Tickets Solution Architecture / 제1과제 / 4시간

첨부 과제지, 30점 채점기준, 저장소의 mark.sh를 대조해 실제 채점 순서로 정리한 풀이입니다. 이름·경로·출력 조건은 채점 명령을 우선합니다.

## 배점과 권장 순서

| 영역 | 배점 | 핵심 |
|---|---:|---|
| Networking | 3.0 | 3개 AZ, Route, Endpoint, Flow Log |
| KMS / S3 / DB / ECR | 4.5 | 암호화, Rotation, PITR, Scan |
| EKS / Lambda | 5.5 | Private EKS, Node 분리, Pod Identity |
| Service Endpoint | 7.0 | Internal ALB, VPC Origin, WAF |
| Security / Application | 3.5 | External ID, health, env, graceful |
| Observability / Runtime / Grafana | 6.5 | JSON 로그, Rate test, 5개 패널 |
| 합계 | 30.0 | |

구축 순서: Network → KMS → S3/DynamoDB/ECR → EKS → App/Pod Identity → Lambda → ALB → CloudFront → WAF → Logging/Monitoring → Runtime test.

## 1. 공통 변수

```bash
export AWS_REGION=ap-northeast-2
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export NUMBER=<선수등번호>
export BUCKET=unicorn-web-$ACCOUNT_ID
aws configure set region $AWS_REGION
```

채점은 Private Subnet의 CloudShell VPC Environment unicorn-mark에서 진행됩니다. 여기서 source kubectl-connect unicorn-eks-cluster가 성공해야 합니다.

## 2. Networking - 3점

### 2.1 전체 구성표

VPC는 `unicorn-vpc`, CIDR은 `10.97.0.0/16`입니다. NAT Gateway까지 포함한 최종 구성은 다음 표와 같아야 합니다.

| 구분 | Subnet | AZ | CIDR | Public IPv4 자동 할당 | Route Table | `0.0.0.0/0` 대상 | NAT Gateway / EIP |
|---|---|---|---|---|---|---|---|
| Public | unicorn-subnet-pub-a | ap-northeast-2a | 10.97.0.0/24 | 활성화 | unicorn-rt-pub | unicorn-igw | unicorn-nat-a / 새 Elastic IP |
| Public | unicorn-subnet-pub-b | ap-northeast-2b | 10.97.1.0/24 | 활성화 | unicorn-rt-pub | unicorn-igw | unicorn-nat-b / 새 Elastic IP |
| Public | unicorn-subnet-pub-c | ap-northeast-2c | 10.97.2.0/24 | 활성화 | unicorn-rt-pub | unicorn-igw | unicorn-nat-c / 새 Elastic IP |
| Private | unicorn-subnet-priv-a | ap-northeast-2a | 10.97.10.0/24 | 비활성화 | unicorn-rt-priv-a | unicorn-nat-a | 해당 없음 |
| Private | unicorn-subnet-priv-b | ap-northeast-2b | 10.97.11.0/24 | 비활성화 | unicorn-rt-priv-b | unicorn-nat-b | 해당 없음 |
| Private | unicorn-subnet-priv-c | ap-northeast-2c | 10.97.12.0/24 | 비활성화 | unicorn-rt-priv-c | unicorn-nat-c | 해당 없음 |

NAT Gateway는 반드시 같은 AZ의 Public Subnet에 생성합니다. 즉 `unicorn-nat-a`는 `unicorn-subnet-pub-a`, `unicorn-nat-b`는 `unicorn-subnet-pub-b`, `unicorn-nat-c`는 `unicorn-subnet-pub-c`에 배치합니다. 각 NAT Gateway에는 서로 다른 Elastic IP를 할당합니다.

### 2.2 Internet Gateway와 Route Table 검증표

| 리소스 | 연결 대상 | 필수 Route | Subnet Association 수 |
|---|---|---|---|
| unicorn-igw | unicorn-vpc | 해당 없음 | 해당 없음 |
| unicorn-rt-pub | Public Subnet a/b/c | `0.0.0.0/0 -> unicorn-igw` | 3 |
| unicorn-rt-priv-a | unicorn-subnet-priv-a | `0.0.0.0/0 -> unicorn-nat-a` | 1 |
| unicorn-rt-priv-b | unicorn-subnet-priv-b | `0.0.0.0/0 -> unicorn-nat-b` | 1 |
| unicorn-rt-priv-c | unicorn-subnet-priv-c | `0.0.0.0/0 -> unicorn-nat-c` | 1 |

Public Route Table 하나를 세 Public Subnet이 공유하고, Private Route Table은 AZ별로 하나씩 분리합니다. 이렇게 해야 한 AZ의 NAT 장애가 다른 AZ의 Private Subnet 경로에 직접 영향을 주지 않습니다.

### 2.3 VPC Endpoint 구성표

| Endpoint Service | 유형 | 연결 대상 | Private DNS | Security Group |
|---|---|---|---|---|
| com.amazonaws.ap-northeast-2.s3 | Gateway | unicorn-rt-priv-a/b/c | 해당 없음 | 해당 없음 |
| com.amazonaws.ap-northeast-2.ecr.api | Interface | Private Subnet a/b/c | 활성화 | Endpoint SG |
| com.amazonaws.ap-northeast-2.ecr.dkr | Interface | Private Subnet a/b/c | 활성화 | Endpoint SG |

Endpoint SG의 Inbound에는 `HTTPS / TCP 443 / 10.97.0.0/16`을 허용합니다. 더 엄격하게 구성하려면 EKS Node SG를 Source로 지정해도 되지만, 채점 전에 실제 Node에서 ECR API와 이미지 레이어에 접근되는지 확인해야 합니다. Interface Endpoint 두 개는 세 Private Subnet을 모두 선택하고 **Enable Private DNS name**을 활성화합니다.

S3는 Interface Endpoint가 아니라 Gateway Endpoint로 만들고 세 Private Route Table에 연결합니다. ECR 이미지 pull 과정은 ECR API/DKR뿐 아니라 이미지 레이어가 저장된 S3에도 접근하므로 S3 Endpoint를 빠뜨리면 Private Node의 이미지 pull이 실패할 수 있습니다.

### 2.4 VPC Flow Log 구성표

| 항목 | 권장 설정 |
|---|---|
| 대상 | unicorn-vpc |
| Filter | ALL |
| Destination | CloudWatch Logs |
| Log Group | 예: `/aws/vpc/unicorn-flow-log` |
| IAM Role | VPC Flow Logs가 CloudWatch Logs에 기록할 수 있는 전용 Role |
| 필수 상태 | Flow Log 1개 이상, Active |

### 2.5 최종 체크리스트

- VPC DNS resolution과 DNS hostnames가 모두 활성화되어 있는지 확인합니다.
- NAT Gateway 세 개가 `Available` 상태이고 각기 다른 Public Subnet과 Elastic IP를 사용하는지 확인합니다.
- Public Route Table Association은 3, 각 Private Route Table Association은 1인지 확인합니다.
- Private Subnet의 기본 경로가 같은 AZ의 NAT Gateway를 가리키는지 확인합니다.
- ECR Interface Endpoint 두 개의 Private DNS가 활성화되어 있는지 확인합니다.
- Endpoint SG가 Node에서 들어오는 TCP 443을 허용하는지 확인합니다.
- S3 Gateway Endpoint가 세 Private Route Table에 모두 연결되어 있는지 확인합니다.
- VPC Flow Log가 `Active` 상태인지 확인합니다.

## 3. KMS - 1점

| Alias | 사용처 |
|---|---|
| alias/unicorn-kms-app | Secrets Manager, DynamoDB |
| alias/unicorn-kms-data | S3, ECR |
| alias/unicorn-kms-platform | EKS, EBS, Logs |

세 키 모두 Rotation을 켜고 RotationPeriodInDays를 정확히 90으로 설정합니다. WAF 로그용 Platform Key는 us-east-1 다중 리전 요구도 확인합니다.

```bash
for a in app data platform; do
  aws kms get-key-rotation-status --key-id alias/unicorn-kms-$a     --query '[KeyRotationEnabled,RotationPeriodInDays]' --output text
done
```

세 줄 모두 True 90이어야 합니다.

## 4. S3 - 1점

버킷은 unicorn-web-$ACCOUNT_ID입니다.

- Block Public Access 4개 true
- Versioning Enabled
- Default encryption aws:kms, Data CMK
- 지급파일 index.html과 main.jpeg 업로드
- OAC만 허용
- Bucket Policy Principal은 cloudfront.amazonaws.com
- SourceArn은 현재 Distribution ARN

## 5. DynamoDB - 1.5점

| 항목 | 값 |
|---|---|
| Table | unicorn-concert-db |
| Billing | PAY_PER_REQUEST |
| PK | booking_id String |
| GSI | client-id-created-at-index |
| GSI PK / SK | client_id / created_at |
| Projection | ALL |
| Encryption | App CMK |
| PITR / 삭제 방지 | ENABLED / true |

### 5.1 DynamoDB Stream 추가과제 완성 풀이

이 항목은 `unicorn-concert-db`와 별개의 추가과제입니다.

```text
CLI PutItem -> source-db -> DynamoDB Stream
            -> ticket-processor Lambda -> destination-db
```

#### 5.1.1 정답 설정표

| 항목 | 값 |
|---|---|
| Source / Destination | source-db / destination-db |
| 두 테이블 PK | ticket_id String |
| Billing | PAY_PER_REQUEST |
| Stream | NEW_IMAGE |
| Lambda | ticket-processor, Container image |
| 계산식 | total_price = price * amount |
| 처리 | PutItem 후 60초 이내 결과 저장 |
| TTL | source-db 입력 시각 + 300초 |

`created_at`은 공지에 따라 String 또는 Epoch Number로 사용할 수 있습니다. TTL Attribute는 Unix Epoch **초 단위 Number**여야 하므로 `expires_at = 현재 Epoch + 300`을 추가하고 TTL Attribute로 지정합니다. DynamoDB의 실제 삭제는 비동기지만 만료 기준값은 정확히 300초 후여야 합니다.

#### 5.1.2 콘솔 풀이

1. DynamoDB에서 `source-db`, `destination-db`를 만들고 Partition key를 `ticket_id`(String), Capacity mode를 On-demand로 지정합니다.
2. `source-db` -> Exports and streams에서 Stream을 켜고 New image를 선택합니다.
3. Additional settings -> Time to Live에서 `expires_at`을 활성화합니다.
4. ECR에 `ticket-processor` Repository를 만들고 아래 이미지를 Push합니다.
5. Lambda를 Container image 방식, 이름 `ticket-processor`로 만들고 `DESTINATION_TABLE=destination-db`를 설정합니다.
6. Add trigger -> DynamoDB에서 `source-db` Stream, Starting position LATEST, Enabled를 선택합니다.
7. 실행 Role에는 Stream 읽기, `destination-db` PutItem, 로그 기록만 허용합니다.

#### 5.1.3 CLI로 테이블·Stream·TTL 생성

```bash
aws configure set region ap-northeast-2

for TABLE in source-db destination-db; do
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=ticket_id,AttributeType=S \
    --key-schema AttributeName=ticket_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST
  aws dynamodb wait table-exists --table-name "$TABLE"
done

aws dynamodb update-table --table-name source-db \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_IMAGE

aws dynamodb update-time-to-live --table-name source-db \
  --time-to-live-specification Enabled=true,AttributeName=expires_at

STREAM_ARN=$(aws dynamodb describe-table --table-name source-db \
  --query 'Table.LatestStreamArn' --output text)
```

#### 5.1.4 Lambda 컨테이너 코드

`lambda_function.py`:

```python
import os
import boto3
from boto3.dynamodb.types import TypeDeserializer

destination = boto3.resource("dynamodb").Table(
    os.environ.get("DESTINATION_TABLE", "destination-db")
)
deserialize = TypeDeserializer().deserialize

def lambda_handler(event, context):
    processed = 0
    for record in event.get("Records", []):
        if record.get("eventName") not in ("INSERT", "MODIFY"):
            continue
        image = record.get("dynamodb", {}).get("NewImage", {})
        item = {key: deserialize(value) for key, value in image.items()}
        item["total_price"] = item["price"] * item["amount"]
        item.pop("expires_at", None)
        destination.put_item(Item=item)
        processed += 1
    return {"processed": processed}
```

`Dockerfile`:

```dockerfile
FROM public.ecr.aws/lambda/python:3.12
COPY lambda_function.py ${LAMBDA_TASK_ROOT}/
CMD ["lambda_function.lambda_handler"]
```

#### 5.1.5 Build·Push·Lambda 연결

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2
aws ecr create-repository --repository-name ticket-processor \
  --image-scanning-configuration scanOnPush=true
aws ecr get-login-password --region "$REGION" | docker login \
  --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

docker build --platform linux/amd64 -t ticket-processor:latest .
docker tag ticket-processor:latest \
  "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/ticket-processor:latest"
docker push "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/ticket-processor:latest"
IMAGE_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/ticket-processor:latest"

aws lambda create-function --function-name ticket-processor \
  --package-type Image --code ImageUri="$IMAGE_URI" \
  --role "arn:aws:iam::$ACCOUNT_ID:role/ticket-processor-role" \
  --architectures x86_64 --timeout 30 --memory-size 256 \
  --environment 'Variables={DESTINATION_TABLE=destination-db}'
aws lambda wait function-active-v2 --function-name ticket-processor

aws lambda create-event-source-mapping --function-name ticket-processor \
  --event-source-arn "$STREAM_ARN" --starting-position LATEST \
  --batch-size 10 --maximum-retry-attempts 2 \
  --bisect-batch-on-function-error
```

Role Trust Principal은 `lambda.amazonaws.com`입니다. 정책에는 Logs, `destination-db`의 `dynamodb:PutItem`, 해당 Stream의 DescribeStream/GetRecords/GetShardIterator/ListStreams만 허용합니다.

#### 5.1.6 PutItem과 60초 검증

필수 필드는 최초 PutItem에 모두 포함하고 Lambda가 `created_at`을 추가하게 만들지 않습니다.

```bash
TICKET_ID=abcd1111
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EXPIRES_AT=$(($(date +%s) + 300))

aws dynamodb put-item --table-name source-db --item "{\
\"ticket_id\":{\"S\":\"$TICKET_ID\"},\
\"price\":{\"N\":\"1000\"},\
\"amount\":{\"N\":\"3\"},\
\"created_at\":{\"S\":\"$CREATED_AT\"},\
\"expires_at\":{\"N\":\"$EXPIRES_AT\"}}"

aws dynamodb get-item --table-name destination-db \
  --key '{"ticket_id":{"S":"abcd1111"}}' --consistent-read
```

기대 결과는 `price=1000`, `amount=3`, `total_price=3000`입니다. 60초 안에 없으면 다음을 확인합니다.

```bash
aws lambda list-event-source-mappings --function-name ticket-processor \
  --query 'EventSourceMappings[*].[State,LastProcessingResult]'
aws logs tail /aws/lambda/ticket-processor --since 10m
aws dynamodb describe-time-to-live --table-name source-db \
  --query TimeToLiveDescription
```

## 6. ECR - 1점

Repository 이름은 unicorn-concert-app입니다. 채점은 단순히 이미지가 보이는지만 확인하지 않고 Repository 설정, 두 tag, v1.0.0 스캔 이력, 취약점 개수를 함께 검사합니다.

### 6.1 정답 설정표

| 항목 | 값 |
|---|---|
| Repository | unicorn-concert-app |
| Scan on push | true |
| Encryption | KMS |
| KMS key | alias/unicorn-kms-data |
| Tag mutability | IMMUTABLE_WITH_EXCLUSION |
| Mutable exclusion | WILDCARD / latest |
| 필수 tag | v1.0.0, latest |
| v1.0.0 scan | 완료 이력 존재 |
| 허용 취약점 | CRITICAL/HIGH/MEDIUM/LOW/INFORMATIONAL 모두 0 |

IMMUTABLE_WITH_EXCLUSION은 기본적으로 모든 tag 덮어쓰기를 막되 exclusion에 일치하는 latest만 다시 push할 수 있게 합니다. v1.0.0은 최초 한 번만 정확히 push하세요.

### 6.2 콘솔에서 Repository 생성

1. AWS Console에서 Elastic Container Registry → Private registry → Repositories → Create repository로 이동합니다.
2. Repository name에 unicorn-concert-app을 입력합니다.
3. Image tag mutability는 Immutable을 선택합니다.
4. Exclusion filter를 추가하고 Filter type은 Wildcard, Filter는 latest로 지정합니다.
5. Scan on push를 활성화합니다.
6. Encryption configuration은 KMS를 선택합니다.
7. KMS key는 alias/unicorn-kms-data를 선택합니다.
8. 생성 후 Repository 상세의 Mutability가 IMMUTABLE_WITH_EXCLUSION인지 다시 확인합니다.

콘솔에 exclusion UI가 보이지 않거나 설정 결과가 다르면 아래 CLI 방식이 더 확실합니다.

### 6.3 CLI로 Repository 생성

아직 Repository가 없을 때:

```bash
aws ecr create-repository   --repository-name unicorn-concert-app   --region ap-northeast-2   --image-scanning-configuration scanOnPush=true   --encryption-configuration encryptionType=KMS,kmsKey=alias/unicorn-kms-data   --image-tag-mutability IMMUTABLE_WITH_EXCLUSION   --image-tag-mutability-exclusion-filters     filterType=WILDCARD,filter=latest
```

이미 Repository를 만들었다면 tag 정책을 다음처럼 교정합니다.

```bash
aws ecr put-image-tag-mutability   --repository-name unicorn-concert-app   --image-tag-mutability IMMUTABLE_WITH_EXCLUSION   --image-tag-mutability-exclusion-filters     filterType=WILDCARD,filter=latest
```

Scan on push가 false라면 다음 명령으로 켭니다.

```bash
aws ecr put-image-scanning-configuration   --repository-name unicorn-concert-app   --image-scanning-configuration scanOnPush=true
```

KMS 암호화 방식과 KMS key는 Repository 생성 후 변경할 수 없으므로 잘못 만들었다면 이미지가 없는 초기 단계에서 Repository를 다시 만드는 것이 안전합니다.

### 6.4 취약점 0건용 Dockerfile

지급된 book은 x86-64 정적 링크 Go 바이너리이므로 OS 패키지가 없는 scratch image로 실행할 수 있습니다. 이 방식은 스캔 대상 OS 패키지를 포함하지 않아 취약점 0건 조건을 맞추기 가장 쉽습니다.

book 파일과 같은 폴더에 Dockerfile을 만듭니다.

```dockerfile
FROM scratch
COPY book /book
EXPOSE 8080
ENTRYPOINT ["/book"]
```

주의:

- 지급된 book 바이너리는 수정하지 않습니다.
- Docker build context에 book이 있어야 합니다.
- scratch에는 shell, curl, chmod가 없습니다. Dockerfile에서 RUN chmod를 사용할 수 없습니다.
- Windows에서 파일을 옮겨 실행 권한 문제가 생기면 Linux/CloudShell에서 chmod +x book을 먼저 수행합니다.
- Kubernetes probe는 exec가 아니라 HTTP GET /health를 사용합니다.

### 6.5 로그인, Build, Tag, Push

지급파일 폴더에서 실행합니다.

```bash
cd '<지급파일의 book과 Dockerfile이 있는 폴더>'

export AWS_REGION=ap-northeast-2
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_URI=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/unicorn-concert-app

aws ecr get-login-password --region $AWS_REGION   | docker login --username AWS --password-stdin     $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

docker build --platform linux/amd64 -t unicorn-concert-app:v1.0.0 .

docker tag unicorn-concert-app:v1.0.0 $ECR_URI:v1.0.0
docker tag unicorn-concert-app:v1.0.0 $ECR_URI:latest

docker push $ECR_URI:v1.0.0
docker push $ECR_URI:latest
```

반드시 v1.0.0을 최초 push할 때 올바른 image를 사용합니다. v1.0.0을 다시 push하면 ImageTagAlreadyExistsException이 발생하는 것이 정상입니다. latest는 exclusion 대상이므로 다시 push할 수 있습니다.

두 tag를 같은 build 결과에 붙였는지 확인합니다.

```bash
aws ecr describe-images   --repository-name unicorn-concert-app   --image-ids imageTag=v1.0.0 imageTag=latest   --query 'imageDetails[].[imageDigest,imageTags]'   --output table
```

두 tag의 digest가 같으면 가장 단순하고 안전합니다.

### 6.6 Scan 실행과 완료 대기

Scan on push가 켜져 있으면 v1.0.0 push 직후 자동 스캔됩니다. 먼저 상태를 확인합니다.

```bash
aws ecr describe-image-scan-findings   --repository-name unicorn-concert-app   --image-id imageTag=v1.0.0   --query '[imageScanStatus.status,imageScanStatus.description]'   --output text
```

아직 스캔 이력이 없을 때만 수동 스캔을 시작합니다.

```bash
aws ecr start-image-scan   --repository-name unicorn-concert-app   --image-id imageTag=v1.0.0
```

같은 이미지는 보통 24시간에 한 번만 수동 스캔할 수 있으므로 scan on push가 이미 실행됐다면 start-image-scan을 반복하지 않습니다. 상태가 IN_PROGRESS이면 잠시 기다렸다가 describe-image-scan-findings를 다시 실행합니다.

### 6.7 취약점 0건 판정

전체 결과:

```bash
aws ecr describe-image-scan-findings   --repository-name unicorn-concert-app   --image-id imageTag=v1.0.0
```

채점에 필요한 핵심 출력만 확인:

```bash
aws ecr describe-image-scan-findings   --repository-name unicorn-concert-app   --image-id imageTag=v1.0.0   --query '[imageScanStatus.status,imageScanFindings.findingSeverityCounts]'   --output json
```

정상 예시:

```json
[
  "COMPLETE",
  {}
]
```

COMPLETE와 빈 객체가 함께 나와야 합니다. findingSeverityCounts가 비어 있어도 status가 없거나 scan 결과 자체가 없으면 스캔 미실행으로 오답입니다. LOW: 1처럼 LOW 하나만 있어도 이 과제에서는 오답입니다.

### 6.8 mark.sh와 같은 최종 검증

```bash
aws ecr describe-repositories   --repository-names unicorn-concert-app   --query 'repositories[0].{Scan:imageScanningConfiguration.scanOnPush,Mutability:imageTagMutability,Enc:encryptionConfiguration.encryptionType}'   --output json

aws ecr describe-images   --repository-name unicorn-concert-app   --query 'sort(imageDetails[].imageTags[])'   --output json | jq -r '@tsv'

aws ecr describe-image-scan-findings   --repository-name unicorn-concert-app   --image-id imageTag=v1.0.0   --query 'imageScanFindings.findingSeverityCounts'   --output json
```

기대 결과:

- Scan: true
- Mutability: IMMUTABLE_WITH_EXCLUSION
- Enc: KMS
- tag 목록에 latest와 v1.0.0 존재
- findingSeverityCounts는 빈 객체
- 스캔 이력은 별도 status 조회에서 COMPLETE

### 6.9 자주 발생하는 오류

| 증상 | 원인 | 해결 |
|---|---|---|
| ImageTagAlreadyExistsException | v1.0.0 재 push | 새 Repository라면 최초 push만 수행; latest만 갱신 |
| latest도 덮어쓰기 실패 | exclusion filter 누락/오타 | WILDCARD, latest로 put-image-tag-mutability 실행 |
| scan 결과가 없음 | scan on push 전에 이미지를 올림 | v1.0.0 수동 scan 1회 실행 |
| scan status IN_PROGRESS | 스캔 진행 중 | 완료까지 대기 후 다시 조회 |
| LOW 이상 finding 존재 | OS package가 든 base image 사용 | 정적 book을 scratch image로 다시 build |
| KMS가 AES256으로 출력 | 기본 암호화로 생성 | KMS Repository로 다시 생성 |
| no basic auth credentials | ECR 로그인 만료/리전 오류 | get-login-password를 서울 리전으로 재실행 |
| exec format error | 다른 CPU architecture로 build | --platform linux/amd64로 다시 build |
| Pod에서 /bin/sh 오류 | scratch에는 shell 없음 | exec probe 대신 HTTP /health 사용 |
## 7. EKS - 4.5점

채점은 Cluster 1.5점, NodeGroup 1.5점, Workload 1.5점입니다. Cluster  unicorn-mark 연결  Launch Template  NodeGroup  Pod Identity  App 순서로 진행합니다.

### 7.1 정답 설정표

| 구분 | 필수 값 |
|---|---|
| Cluster | unicorn-eks-cluster / 1.35 |
| Endpoint | Public false / Private true |
| Subnet | Private a, b, c |
| Logs | api, audit, authenticator, controllerManager, scheduler |
| API data / EBS / Logs KMS | alias/unicorn-kms-platform |
| App Node | unicorn=app, 2대 이상, 2개 이상 AZ |
| Addon Node | unicorn=addon, 1대 이상 |
| EC2 Name | unicorn-k8snode-app-node / unicorn-k8snode-addon-node |
| Namespace | unicorn |
| Deployment / Service | unicorn-book-app-deploy / unicorn-book-app-svc |
| ServiceAccount | unicorn-book-app-sa |

### 7.2 IAM Role 준비

Cluster Role에는 AmazonEKSClusterPolicy를 연결하고 Trust Principal을 eks.amazonaws.com으로 설정합니다. Node Role Trust Principal은 ec2.amazonaws.com이며 다음 정책이 필요합니다.

- AmazonEKSWorkerNodePolicy
- AmazonEC2ContainerRegistryPullOnly
- AmazonEKS_CNI_Policy 또는 CNI 전용 역할

DynamoDB App 권한은 Node Role에 넣지 않고 Pod Identity Role에만 넣습니다.

### 7.3 콘솔에서 Private Cluster 생성

1. EKS  Clusters  Create cluster로 이동합니다.
2. Name unicorn-eks-cluster, Kubernetes 1.35를 선택합니다.
3. unicorn-vpc와 Private Subnet a/b/c만 선택합니다.
4. Endpoint access는 Private only로 설정합니다.
5. Control Plane Logging 5종을 모두 활성화합니다.
6. Kubernetes API data encryption에 alias/unicorn-kms-platform을 지정합니다.
7. Authentication mode는 API 또는 API_AND_CONFIG_MAP을 선택합니다.
8. Cluster가 Active가 될 때까지 기다립니다.

VPC의 DNS support와 DNS hostnames가 켜져 있어야 Private Endpoint가 해석됩니다. unicorn-mark SG에서 Cluster SG의 TCP 443 접근도 허용합니다.

기존 Cluster 교정:

```bash
aws eks update-cluster-config --name unicorn-eks-cluster --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true
aws eks wait cluster-active --name unicorn-eks-cluster
aws eks update-cluster-config --name unicorn-eks-cluster --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
```

### 7.4 unicorn-mark에서 kubectl 연결

```bash
aws eks update-kubeconfig --region ap-northeast-2 --name unicorn-eks-cluster
kubectl cluster-info
kubectl get nodes
```

timeout은 네트워크/SG/DNS 문제, Unauthorized는 Access Entry/RBAC 문제입니다. CloudShell Role의 Access Entry를 확인합니다.

```bash
aws sts get-caller-identity --query Arn --output text
aws eks list-access-entries --cluster-name unicorn-eks-cluster
```

### 7.5 Platform CMK EBS Launch Template

App용과 Addon용 Launch Template을 각각 만듭니다. 핵심 Launch Template Data:

```json
{
  "InstanceType": "t3.medium",
  "BlockDeviceMappings": [{
    "DeviceName": "/dev/xvda",
    "Ebs": {
      "VolumeSize": 30,
      "VolumeType": "gp3",
      "Encrypted": true,
      "KmsKeyId": "alias/unicorn-kms-platform",
      "DeleteOnTermination": true
    }
  }],
  "TagSpecifications": [{
    "ResourceType": "instance",
    "Tags": [{"Key": "Name", "Value": "unicorn-k8snode-app-node"}]
  }],
  "MetadataOptions": {
    "HttpTokens": "required",
    "HttpPutResponseHopLimit": 1
  }
}
```

Addon Template은 Name을 unicorn-k8snode-addon-node로 바꿉니다. NodeGroup tag는 EC2 Instance에 자동 전파되지 않을 수 있으므로 채점 대상 Name은 반드시 Launch Template TagSpecifications에 넣습니다.

AMI는 EKS 1.35용 AL2023 최적화 AMI를 사용합니다. 콘솔 NodeGroup에서 AMI Type을 선택한다면 Template의 ImageId를 생략합니다. Platform CMK Key Policy에는 Auto Scaling/EC2가 encrypted EBS를 생성하는 데 필요한 CreateGrant, GenerateDataKey, Encrypt/Decrypt 권한을 최소 범위로 허용합니다.

### 7.6 Managed NodeGroup 두 개

| 항목 | App | Addon |
|---|---|---|
| Name | unicorn-app-ng | unicorn-addon-ng |
| Launch Template | App Template | Addon Template |
| Subnet | Private a,b,c | Private a,b,c |
| Instance | t3.medium | t3.medium |
| Desired/Min | 2/2 | 1/1 |
| Max | 3 이상 | 2 이상 |
| Label | unicorn=app | unicorn=addon |

App Node가 실제로 2개 이상 AZ에 분산됐는지 확인합니다. 한 AZ에 몰리면 Desired를 늘리거나 AZ별 NodeGroup으로 분산을 보장합니다.

```bash
kubectl get nodes -L unicorn,topology.kubernetes.io/zone
```

### 7.7 Addon을 Addon Node에 배치

aws-node, kube-proxy, Pod Identity Agent, Fluent Bit 같은 DaemonSet은 예외입니다. CoreDNS, Metrics Server, AWS Load Balancer Controller, Prometheus, Grafana에는 다음을 설정합니다.

```yaml
nodeSelector:
  unicorn: addon
```

Addon taint dedicated=addon:NoSchedule를 사용한다면 각 Addon에 toleration도 추가합니다. CoreDNS를 먼저 교정하지 않고 taint를 적용하면 DNS가 Pending이 될 수 있습니다.

```yaml
tolerations:
  - key: dedicated
    operator: Equal
    value: addon
    effect: NoSchedule
```

### 7.8 Pod Identity 구성

EKS Pod Identity Agent Add-on을 설치합니다.

```bash
aws eks create-addon --cluster-name unicorn-eks-cluster --addon-name eks-pod-identity-agent
kubectl create namespace unicorn
kubectl create serviceaccount unicorn-book-app-sa -n unicorn
```

Pod Identity Role Trust Policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "pods.eks.amazonaws.com"},
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
```

Permission Policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["dynamodb:PutItem", "dynamodb:GetItem"],
    "Resource": "arn:aws:dynamodb:ap-northeast-2:ACCOUNT_ID:table/unicorn-concert-db"
  }]
}
```

```bash
aws eks create-pod-identity-association --cluster-name unicorn-eks-cluster --namespace unicorn --service-account unicorn-book-app-sa --role-arn arn:aws:iam::ACCOUNT_ID:role/unicorn-book-app-role
aws eks list-pod-identity-associations --cluster-name unicorn-eks-cluster --namespace unicorn
```

ServiceAccount에는 IRSA annotation을 넣지 않습니다. Pod Identity Association은 Kubernetes 객체가 아니라 EKS에 저장됩니다.

### 7.9 Book App 전체 Manifest

ECR의 scratch image에는 /bin/sh가 없습니다. 따라서 preStop exec sleep 대신 Kubernetes lifecycle sleep handler를 사용합니다.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: unicorn-book-app-pdb
  namespace: unicorn
spec:
  minAvailable: 1
  selector:
    matchLabels: {app: unicorn-book}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unicorn-book-app-deploy
  namespace: unicorn
spec:
  replicas: 2
  strategy:
    rollingUpdate: {maxUnavailable: 0, maxSurge: 1}
  selector:
    matchLabels: {app: unicorn-book}
  template:
    metadata:
      labels: {app: unicorn-book}
    spec:
      serviceAccountName: unicorn-book-app-sa
      nodeSelector: {unicorn: app}
      terminationGracePeriodSeconds: 45
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: {app: unicorn-book}
      containers:
        - name: book
          image: ACCOUNT_ID.dkr.ecr.ap-northeast-2.amazonaws.com/unicorn-concert-app:v1.0.0
          ports:
            - {name: http, containerPort: 8080}
          env:
            - {name: AWS_REGION, value: ap-northeast-2}
            - {name: TABLE_NAME, value: unicorn-concert-db}
          readinessProbe:
            httpGet: {path: /health, port: http}
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet: {path: /health, port: http}
            initialDelaySeconds: 15
            periodSeconds: 10
          lifecycle:
            preStop:
              sleep:
                seconds: 15
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: 500m, memory: 256Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: unicorn-book-app-svc
  namespace: unicorn
spec:
  type: ClusterIP
  selector: {app: unicorn-book}
  ports:
    - {name: http, port: 80, targetPort: http}
```

ACCOUNT_ID를 바꾸고 적용합니다.

```bash
kubectl apply -f book-app.yaml
kubectl rollout status deploy/unicorn-book-app-deploy -n unicorn --timeout=180s
kubectl get deploy,svc,pod -n unicorn -o wide
```

### 7.10 내부 Health와 환경변수 테스트

```bash
kubectl run curl-test -n unicorn --rm -it --restart=Never --image=curlimages/curl -- curl -i http://unicorn-book-app-svc/health
POD=$(kubectl get pod -n unicorn -l app=unicorn-book -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n unicorn $POD -c book -- printenv AWS_REGION TABLE_NAME
```

기대값은 health 200, ap-northeast-2, unicorn-concert-db입니다.

### 7.11 mark.sh 기준 최종 검증

```bash
aws eks describe-cluster --name unicorn-eks-cluster --query 'cluster.[version,resourcesVpcConfig.endpointPublicAccess,resourcesVpcConfig.endpointPrivateAccess]' --output text
aws eks describe-cluster --name unicorn-eks-cluster --query 'cluster.logging.clusterLogging[?enabled==true].types[]' --output text
aws eks describe-cluster --name unicorn-eks-cluster --query 'cluster.encryptionConfig[].provider.keyArn' --output text

kubectl get nodes -l unicorn=app -L topology.kubernetes.io/zone
kubectl get nodes -l unicorn=addon
aws ec2 describe-instances --filters Name=tag:Name,Values=unicorn-k8snode-app-node Name=instance-state-name,Values=running --query 'Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone,PublicIpAddress]' --output table

kubectl get deploy unicorn-book-app-deploy -n unicorn -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas' --no-headers
kubectl get svc unicorn-book-app-svc -n unicorn -o custom-columns='NAME:.metadata.name,TYPE:.spec.type' --no-headers
kubectl get deploy unicorn-book-app-deploy -n unicorn -o jsonpath='liveness={.spec.template.spec.containers[0].livenessProbe.httpGet.path} readiness={.spec.template.spec.containers[0].readinessProbe.httpGet.path} graceful={.spec.template.spec.terminationGracePeriodSeconds} preStop={.spec.template.spec.containers[0].lifecycle.preStop}'
aws eks list-pod-identity-associations --cluster-name unicorn-eks-cluster --namespace unicorn --query 'associations[].serviceAccount' --output text
```

기대 핵심: 1.35 / false / true, 로그 5종, Encryption ARN, App Node 2대 이상, 2개 이상 AZ, Public IP 없음, Addon Node 1대, Ready/Available 2 이상, probe /health, graceful 45, preStop 존재, unicorn-book-app-sa 출력입니다.

### 7.12 KST와 장애 진단

Node timezone은 Launch Template user data 또는 사전 구성 AMI에서 timedatectl set-timezone Asia/Seoul을 적용합니다. 실행 중 수동 변경만 하면 Node 교체 시 사라집니다.

| 증상 | 원인 | 해결 |
|---|---|---|
| kubectl timeout | 외부 CloudShell 사용 | unicorn-mark VPC Environment 사용 |
| Unauthorized | Access Entry 누락 | CloudShell Role 등록 |
| Node NotReady | Endpoint/Route/Role | ECR/S3 Endpoint, NAT, Node Role 확인 |
| App Node 한 AZ | ASG 배치 편중 | Desired 증가 또는 AZ별 NodeGroup |
| EC2 Name 조회 0 | NodeGroup tag만 설정 | Launch Template Instance Name tag 추가 |
| EBS KMS 불일치 | 기본 Template | Platform CMK BlockDeviceMappings 사용 |
| CoreDNS Pending | taint toleration 누락 | CoreDNS nodeSelector/toleration 교정 |
| DynamoDB AccessDenied | Association/Policy 오류 | Agent, SA, Role ARN 확인 |
| preStop /bin/sh 실패 | scratch에 shell 없음 | lifecycle sleep 사용 |
| Ready 1 | replica/probe 실패 | replicas, events, logs, health 확인 |
## 8. Lambda - 1점

- Function: unicorn-get-booking-func
- GET /v1/book, booking_id 필수
- email, concert_name 선택 조건
- TABLE_NAME=unicorn-concert-db
- KMSKeyArn: Platform CMK
- Log Group: /unicorn/lambda/get-booking
- ALB 형식 JSON 응답
- DynamoDB 최소 권한

### 8.1 함수 생성과 보안 설정

Lambda 콘솔에서 Author from scratch를 선택합니다.

| 항목 | 값 |
|---|---|
| Function name | unicorn-get-booking-func |
| Runtime | Python 3.x |
| Architecture | x86_64 |
| Environment variable | TABLE_NAME=unicorn-concert-db |
| Environment encryption | alias/unicorn-kms-platform |
| Log group | /unicorn/lambda/get-booking |

실행 역할에는 CloudWatch Logs 기록 권한과 unicorn-concert-db의 dynamodb:GetItem만 허용합니다. 별도 조회 방식을 추가하지 않는다면 Scan이나 전체 테이블 wildcard 권한은 필요하지 않습니다.

### 8.2 lambda_function.py 전체 코드

```python
import json
import os

import boto3


TABLE_NAME = os.environ["TABLE_NAME"]
table = boto3.resource("dynamodb").Table(TABLE_NAME)

STATUS_TEXT = {
    200: "OK",
    400: "Bad Request",
    404: "Not Found",
    405: "Method Not Allowed",
    500: "Internal Server Error",
}


def alb_response(status_code, payload):
    return {
        "statusCode": status_code,
        "statusDescription": f"{status_code} {STATUS_TEXT[status_code]}",
        "isBase64Encoded": False,
        "headers": {
            "Content-Type": "application/json; charset=utf-8"
        },
        "body": json.dumps(payload, ensure_ascii=False),
    }


def lambda_handler(event, context):
    method = event.get("httpMethod", "GET")
    params = event.get("queryStringParameters") or {}

    if method != "GET":
        return alb_response(405, {"message": "Method Not Allowed"})

    booking_id = params.get("booking_id")
    if not booking_id:
        return alb_response(400, {"message": "booking_id is required"})

    try:
        result = table.get_item(
            Key={"booking_id": booking_id},
            ConsistentRead=True,
        )
    except Exception:
        print("DynamoDB GetItem failed", flush=True)
        return alb_response(500, {"message": "internal server error"})

    item = result.get("Item")
    if item is None:
        return alb_response(404, {"message": "booking not found"})

    # 선택 파라미터가 오면 저장된 값과 함께 일치해야 합니다.
    for field in ("email", "concert_name"):
        expected = params.get(field)
        if expected is not None and item.get(field) != expected:
            return alb_response(404, {"message": "booking not found"})

    return alb_response(200, item)
```

boto3는 Lambda Python 런타임에 포함되므로 별도 Layer나 dependency zip이 필요하지 않습니다. Handler는 lambda_function.lambda_handler로 둡니다.

### 8.3 IAM 최소 권한

ACCOUNT_ID는 실제 계정 ID로 바꿉니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadBooking",
      "Effect": "Allow",
      "Action": "dynamodb:GetItem",
      "Resource": "arn:aws:dynamodb:ap-northeast-2:ACCOUNT_ID:table/unicorn-concert-db"
    }
  ]
}
```

CloudWatch Logs는 AWSLambdaBasicExecutionRole을 사용하거나 /unicorn/lambda/get-booking에 한정한 logs:CreateLogStream, logs:PutLogEvents 권한을 직접 부여합니다. 환경변수 복호화를 위해 실행 역할에 Platform CMK의 kms:Decrypt도 필요합니다.

### 8.4 콘솔 테스트 이벤트

```json
{
  "httpMethod": "GET",
  "path": "/v1/book",
  "queryStringParameters": {
    "booking_id": "POST에서 받은 ID"
  }
}
```

정상 응답은 statusCode 200이고 body는 JSON 문자열이어야 합니다. booking_id가 없는 이벤트도 실행해 400을 확인합니다.

### 8.5 ALB Lambda Target Group 연결

#### 8.5.1 최종 연결 구조

| 요청 | ALB Listener 조건 | 전달 대상 |
|---|---|---|
| GET /v1/book?booking_id=... | Method GET + Path /v1/book | Lambda Target Group |
| POST /v1/book | Method POST + Path /v1/book | 기존 unicorn-tg |
| GET /health | Method GET + Path /health | 기존 unicorn-tg |
| 나머지 요청 | Default rule | Fixed response 403 |

같은 /v1/book 경로를 사용하므로 Path 조건만 만들면 안 됩니다. 반드시 **HTTP request method와 Path pattern을 함께** 조건으로 지정해야 GET은 Lambda, POST는 EKS App으로 분기됩니다.

#### 8.5.2 콘솔에서 Lambda Target Group 생성

1. EC2 -> Target Groups -> Create target group으로 이동합니다.
2. Choose a target type에서 **Lambda function**을 선택합니다.
3. Target group name은 예를 들어 unicorn-lambda-tg로 지정합니다.
4. Lambda function에서 unicorn-get-booking-func를 선택하고 Target으로 등록합니다.
5. 콘솔이 Lambda 호출 권한 추가를 요청하면 허용합니다.
6. Target Group의 Registered targets에 함수가 표시되는지 확인합니다.

Lambda Target Group은 Instance/IP Target Group과 달리 Protocol, Port, VPC를 지정하지 않습니다. 함수 Target 등록 전에 ALB가 함수를 호출할 수 있도록 Lambda Resource-based policy가 필요합니다.

#### 8.5.3 CLI로 생성하고 호출 권한 부여

```bash
REGION=ap-northeast-2
FUNC_NAME=unicorn-get-booking-func

FUNC_ARN=$(aws lambda get-function \
  --function-name "$FUNC_NAME" \
  --query 'Configuration.FunctionArn' --output text)

LAMBDA_TG_ARN=$(aws elbv2 create-target-group \
  --name unicorn-lambda-tg \
  --target-type lambda \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws lambda add-permission \
  --function-name "$FUNC_NAME" \
  --statement-id AllowInvokeFromUnicornALB \
  --action lambda:InvokeFunction \
  --principal elasticloadbalancing.amazonaws.com \
  --source-arn "$LAMBDA_TG_ARN"

aws elbv2 register-targets \
  --target-group-arn "$LAMBDA_TG_ARN" \
  --targets Id="$FUNC_ARN"
```

add-permission의 source-arn은 ALB ARN이 아니라 **Lambda Target Group ARN**입니다. 같은 Statement ID가 이미 있으면 ResourceConflictException이 발생하므로 기존 정책을 먼저 확인합니다.

```bash
aws lambda get-policy \
  --function-name unicorn-get-booking-func \
  --query Policy --output text
```

정책 안에 Principal elasticloadbalancing.amazonaws.com, Action lambda:InvokeFunction, SourceArn unicorn-lambda-tg의 ARN이 있어야 합니다.

#### 8.5.4 ALB Listener 규칙

EC2 -> Load Balancers -> unicorn-alb -> Listeners and rules -> HTTP:80 -> Manage rules에서 다음 순서로 만듭니다.

| Priority 예시 | 조건 | Action |
|---:|---|---|
| 10 | Method GET, Path /v1/book | Forward to unicorn-lambda-tg |
| 20 | Method POST, Path /v1/book | Forward to unicorn-tg |
| 30 | Method GET, Path /health | Forward to unicorn-tg |
| Default | 조건 없음 | Fixed response 403 |

우선순위 숫자는 기존 규칙과 겹치지 않으면 달라도 됩니다. 규칙 하나 안에서 Method와 Path 조건은 AND로 평가되어야 합니다.

```bash
aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" \
  --priority 10 \
  --conditions \
    'Field=http-request-method,HttpRequestMethodConfig={Values=[GET]}' \
    'Field=path-pattern,PathPatternConfig={Values=[/v1/book]}' \
  --actions Type=forward,TargetGroupArn="$LAMBDA_TG_ARN"
```

#### 8.5.5 CloudFront Query String 전달

CloudFront에서 Query String 전달이 꺼져 있으면 Lambda event의 queryStringParameters에 booking_id가 들어오지 않아 400이 발생합니다.

CloudFront -> Distribution -> Behaviors -> /v1/book* -> Edit에서 다음을 확인합니다.

| 항목 | 설정 |
|---|---|
| Origin | Internal ALB의 VPC Origin |
| Allowed HTTP methods | GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE |
| Cache policy | API 응답은 CachingDisabled 권장 |
| Origin request policy | 사용자 정의 Policy 연결 |
| Query strings | All 또는 Allow list |
| Allow list 사용 시 | booking_id, email, concert_name |

Origin request policy는 Query String을 Origin으로 전달하지만 반드시 Cache Key에 포함시키는 것은 아닙니다. GET 조회 결과를 캐싱한다면 사용자별 응답 혼합을 막기 위해 booking_id를 Cache Key에 포함하거나, 시험에서는 /v1/book*에 CachingDisabled를 적용하는 편이 안전합니다.

#### 8.5.6 연결 검증

```bash
CF_DOMAIN=배포도메인.cloudfront.net

curl -i "https://${CF_DOMAIN}/v1/book?booking_id=존재하는ID"
curl -i "https://${CF_DOMAIN}/v1/book"
curl -i -X POST "https://${CF_DOMAIN}/v1/book" \
  -H 'Content-Type: application/json' \
  -d '{"client_id":"test","concert_name":"unicorn"}'
curl -i "https://${CF_DOMAIN}/health"
```

첫 번째 요청은 Lambda 조회 결과, 두 번째 요청은 booking_id 누락에 따른 400, POST와 health는 EKS App 응답이어야 합니다. GET 요청이 EKS로 가거나 POST가 Lambda로 가면 Listener 규칙에 Method 조건이 빠졌는지 확인합니다. Query String을 보냈는데도 400이면 CloudFront Origin request policy와 Lambda 로그의 queryStringParameters를 확인합니다.

## 9. ALB와 CloudFront - 7점

### Internal ALB

- unicorn-alb / internal / application / active
- Listener HTTP 80
- App Target Group unicorn-tg
- POST /v1/book → EKS App
- GET /health → EKS App
- GET /v1/book → Lambda
- Default 403

Internal ALB 직접 curl은 000 또는 403이어야 합니다.

### CloudFront VPC Origin

Distribution Comment는 unicorn-svc-cf입니다.

| Origin ID | 연결 |
|---|---|
| s3-origin | S3 OAC |
| app-origin | unicorn-alb VPC Origin |

Default behavior는 S3, /v1/book*와 /health*는 app-origin으로 보냅니다. query string을 전달하고 정적 GET은 캐싱합니다. HTTP는 HTTPS로 redirect합니다.


### 9.1 콘솔·CLI 구축과 검증

1. IP 유형 `unicorn-tg`를 HTTP:8080, Health path `/health`로 만듭니다.
2. `unicorn-alb`는 Internal Application ALB로 만들고 Private Subnet 3개를 연결합니다.
3. HTTP:80 Listener에 GET `/v1/book` -> Lambda TG, POST `/v1/book`과 GET `/health` -> `unicorn-tg`, Default fixed 403 규칙을 둡니다.
4. CloudFront는 **Pay-as-you-go**, Comment `unicorn-svc-cf`로 만들고 S3 OAC Origin과 ALB VPC Origin을 등록합니다.
5. Default behavior는 S3, `/v1/book*`와 `/health*`는 ALB로 연결합니다. Viewer protocol은 Redirect HTTP to HTTPS, API는 CachingDisabled를 권장합니다.
6. S3 Bucket Policy의 Principal은 CloudFront Service, `AWS:SourceArn`은 현재 Distribution ARN으로 제한합니다.

```bash
aws elbv2 describe-load-balancers --names unicorn-alb \
  --query 'LoadBalancers[0].[Scheme,Type,State.Code,VpcId]'
aws elbv2 describe-target-health --target-group-arn "$APP_TG_ARN" \
  --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]'
aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='unicorn-svc-cf'].[Id,DomainName,Status]"
curl -i "https://${CF_DOMAIN}/"
curl -i "https://${CF_DOMAIN}/health"
curl -i "https://${CF_DOMAIN}/v1/book?booking_id=${BOOKING_ID}"
```

S3가 403이면 OAC와 Distribution ARN, API가 400이면 Query String 전달, 502이면 VPC Origin·ALB SG·Target Health를 확인합니다.

## 10. WAF - 1점 + Runtime 1.5점

### 10.1 정답 설정표

| 항목 | 값 |
|---|---|
| Web ACL | unicorn-waf |
| Scope / Region | CloudFront distributions / us-east-1 |
| Default action | Allow |
| Managed rules | AWSManagedRulesCommonRuleSet, AWSManagedRulesKnownBadInputsRuleSet |
| Rate rule | unicorn-rate-limit |
| Aggregate / Window / Limit | Source IP / 60초 / 50 |
| Rate action | Block |
| Custom response | 403 / Request blocked by Unicorn WAF |
| Log Group / Encryption | aws-waf-logs-unicorn / Platform CMK |

CloudFront용 Web ACL은 Global 리소스이므로 Console Region을 N. Virginia(us-east-1)로 바꾸고 Scope를 CloudFront distributions로 선택합니다. Web ACL 조회·수정 CLI에는 --scope CLOUDFRONT --region us-east-1을 사용합니다.

### 10.2 Web ACL과 Managed Rule 생성

1. WAF & Shield -> Web ACLs -> Create web ACL로 이동합니다.
2. Resource type은 CloudFront distributions, Name은 unicorn-waf로 지정합니다.
3. Default web ACL action은 Allow로 둡니다.
4. AWS managed rule groups에서 Core rule set(AWSManagedRulesCommonRuleSet)과 Known bad inputs(AWSManagedRulesKnownBadInputsRuleSet)을 추가합니다.
5. 두 Managed Rule의 Override action은 None으로 둡니다. Count로 바꾸면 XSS가 차단되지 않습니다.
6. Web ACL을 현재 CloudFront Distribution에 연결합니다.

권장 우선순위는 CommonRuleSet 10, KnownBadInputsRuleSet 20, Rate Rule 30입니다. 실제 숫자는 달라도 되지만 세 규칙이 모두 활성화되어야 합니다.

### 10.3 60초 50건 Rate Rule

Add rules -> Add my own rules and rule groups -> Rule builder에서 설정합니다.

| 필드 | 설정 |
|---|---|
| Name / Type | unicorn-rate-limit / Rate-based rule |
| Rate limit / Evaluation window | 50 / 1 minute (60 seconds) |
| Request aggregation | IP address |
| Scope-down statement | 없음 |
| Action | Block |
| Custom response code | 403 |
| Custom body name / type | unicorn-rate-block-body / TEXT_PLAIN |
| Body | Request blocked by Unicorn WAF |

전체 CloudFront 요청을 IP별로 제한해야 하므로 Scope-down은 비워 둡니다. AWS WAF Rate Rule은 정확히 51번째 요청을 즉시 차단하는 고정 카운터가 아니라 최근 요청률을 주기적으로 평가합니다. 반복 요청 직후 최대 수십 초 동안 200이 더 나올 수 있으므로 잠시 기다려 재검증합니다.

### 10.4 CloudWatch Logs와 Platform CMK

WAF Log Group은 Web ACL과 같은 us-east-1에 만들고 이름이 반드시 aws-waf-logs-로 시작해야 합니다.

```bash
WAF_REGION=us-east-1
LOG_GROUP=aws-waf-logs-unicorn

aws logs create-log-group \
  --region "$WAF_REGION" \
  --log-group-name "$LOG_GROUP" \
  --kms-key-id alias/unicorn-kms-platform

# 이미 만든 Log Group에 CMK를 연결할 때
aws logs associate-kms-key \
  --region "$WAF_REGION" \
  --log-group-name "$LOG_GROUP" \
  --kms-key-id alias/unicorn-kms-platform
```

Platform CMK의 us-east-1 Replica Key 정책은 logs.us-east-1.amazonaws.com의 Encrypt, Decrypt, ReEncrypt, GenerateDataKey, DescribeKey를 허용해야 합니다. Encryption Context는 해당 Log Group ARN으로 제한합니다. Key가 ap-northeast-2에만 있으면 us-east-1 Log Group에 연결할 수 없습니다.

WAF -> unicorn-waf -> Logging and metrics -> Enable logging에서 CloudWatch Logs와 aws-waf-logs-unicorn을 선택하고 Keep all logs로 둡니다.

```bash
WAF_ARN=$(aws wafv2 list-web-acls \
  --scope CLOUDFRONT --region us-east-1 \
  --query "WebACLs[?Name=='unicorn-waf'].ARN | [0]" --output text)

LOG_ARN=$(aws logs describe-log-groups \
  --region us-east-1 \
  --log-group-name-prefix aws-waf-logs-unicorn \
  --query "logGroups[?logGroupName=='aws-waf-logs-unicorn'].logGroupArn | [0]" \
  --output text)

aws wafv2 put-logging-configuration \
  --region us-east-1 \
  --logging-configuration \
  "ResourceArn=$WAF_ARN,LogDestinationConfigs=[$LOG_ARN]"
```

put-logging-configuration에는 --scope 옵션을 넣지 않습니다. ResourceArn이 CloudFront Scope의 Web ACL을 식별합니다.

### 10.5 설정 검증 명령

```bash
WAF_ID=$(aws wafv2 list-web-acls \
  --scope CLOUDFRONT --region us-east-1 \
  --query "WebACLs[?Name=='unicorn-waf'].Id | [0]" --output text)

aws wafv2 get-web-acl \
  --name unicorn-waf --id "$WAF_ID" \
  --scope CLOUDFRONT --region us-east-1 \
  --query '{Default:WebACL.DefaultAction,Rules:WebACL.Rules[*].{Name:Name,Priority:Priority,Action:Action,Override:OverrideAction,Statement:Statement}}'

aws wafv2 get-logging-configuration \
  --resource-arn "$WAF_ARN" --region us-east-1

aws logs describe-log-groups \
  --region us-east-1 \
  --log-group-name-prefix aws-waf-logs-unicorn \
  --query 'logGroups[*].[logGroupName,kmsKeyId]' --output table
```

Default Allow, Managed Rule 두 개, unicorn-rate-limit, Limit 50, EvaluationWindowSec 60, CustomResponse 403 및 Platform CMK ARN을 확인합니다.

### 10.6 Runtime 테스트

```bash
CF_DOMAIN=배포도메인.cloudfront.net

curl -i "https://${CF_DOMAIN}/health"

# XSS: HTTP 403 기대
curl -i "https://${CF_DOMAIN}/health?q=%3Cscript%3Ealert%281%29%3C%2Fscript%3E"

# 동일 IP에서 60초 구간의 Limit 초과
for i in $(seq 1 70); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    "https://${CF_DOMAIN}/health?rate_test=${i}"
done

sleep 10
curl -i "https://${CF_DOMAIN}/health"
```

정상 요청은 처음에 200, XSS 요청은 403이어야 합니다. Rate Rule이 활성화되면 마지막 /health 요청은 403과 정확한 본문 Request blocked by Unicorn WAF를 반환해야 합니다. XSS가 200이면 Managed Rule Override가 Count인지 확인하고, Rate 요청이 계속 200이면 Window 60, Limit 50 및 CloudFront Web ACL 연결을 확인합니다.

## 11. Audit Role - 2점

- Role: unicorn-audit-role
- External ID: unicorn-audit-2026$NUMBER
- Max session: 3600
- 동일 계정의 명시된 IAM Principal
- Inline Policy
- Action과 Resource wildcard 금지
- 허용: dynamodb:GetItem, dynamodb:Query, ec2:DescribeVpcs, eks:DescribeCluster

External ID 없이 AssumeRole은 AccessDenied, 올바른 값으로는 성공해야 합니다. Assume 후 DescribeVpcs는 성공하고 DescribeInstances는 UnauthorizedOperation이어야 합니다.


### 11.1 Trust·Inline Policy 작성

Trust Policy는 과제에서 지정한 동일 계정 IAM Principal ARN 하나와 정확한 External ID만 허용합니다. Principal `*`나 계정 전체 root를 쓰지 않습니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "AUDITOR_PRINCIPAL_ARN"},
    "Action": "sts:AssumeRole",
    "Condition": {"StringEquals": {
      "sts:ExternalId": "unicorn-audit-2026<선수등번호>"
    }}
  }]
}
```

Inline Policy에는 `unicorn-concert-db`의 GetItem·Query, `unicorn-eks-cluster`의 DescribeCluster, DescribeVpcs만 넣습니다. DynamoDB와 EKS는 정확한 ARN으로 제한합니다. EC2 Describe API는 Resource-level 권한을 지원하지 않아 `Resource: "*"`가 필요한 예외가 있으므로 채점표가 요구하는 조건 방식이 있으면 그것을 우선합니다. Maximum session duration은 3600초입니다.

```bash
aws iam get-role --role-name unicorn-audit-role \
  --query 'Role.[RoleName,MaxSessionDuration,AssumeRolePolicyDocument]'
aws sts assume-role \
  --role-arn "arn:aws:iam::$ACCOUNT_ID:role/unicorn-audit-role" \
  --role-session-name audit-test \
  --external-id "unicorn-audit-2026$NUMBER"
```

External ID가 없거나 틀리면 AccessDenied가 정상입니다. 임시 자격증명으로 DescribeVpcs·DescribeCluster는 성공하고 DescribeInstances는 거부되어야 합니다.

## 12. Observability - 2점

Fluent Bit DaemonSet이 Book App 로그를 10초 안에 /unicorn/eks/book-app으로 전송해야 합니다. /health 로그는 제외합니다.

정확한 JSON key:

```text
client_ip,method,path,status_code,timestamp
```

monitoring namespace에 Prometheus와 Grafana를 설치합니다. 관리형 Control Plane용 kube-controller-manager, kube-scheduler, kube-etcd ServiceMonitor 수는 0이어야 합니다.

Grafana:

- ALB/TG: unicorn-grafana-alb / unicorn-grafana-tg
- ID: skills$NUMBER
- Password: HelloKrSkills!$NUMBER@
- Dashboard: unicorn-grafana-dashboard

필수 패널:

1. EKS Node CPU Usage (%) - Time Series
2. EKS Node Memory Usage (%) - Time Series
3. unicorn Namespace Pod Status - Stat, graph 포함
4. Book App Ready Pods - Stat
5. Book App HTTP Request Duration - Time Series

No Data, 잘못된 Panel type, 다른 이름은 오답입니다.


### 12.1 Fluent Bit 실제 구성

Fluent Bit은 DaemonSet으로 모든 Node에서 실행하고 Book App 로그만 수집합니다. Flush는 10초 이하, `/health` 레코드는 grep filter로 제외하고 CloudWatch Log Group은 `/unicorn/eks/book-app`으로 지정합니다.

```ini
[SERVICE]
    Flush 5
[FILTER]
    Name grep
    Match kube.*
    Exclude log /health
[OUTPUT]
    Name cloudwatch_logs
    Match kube.*
    region ap-northeast-2
    log_group_name /unicorn/eks/book-app
    auto_create_group false
```

```bash
aws logs create-log-group --log-group-name /unicorn/eks/book-app
aws logs associate-kms-key --log-group-name /unicorn/eks/book-app \
  --kms-key-id "$PLATFORM_KMS_ARN"
kubectl -n kube-system get daemonset,pods -l k8s-app=fluent-bit -o wide
aws logs tail /unicorn/eks/book-app --since 5m
```

로그는 `timestamp, method, path, status_code, client_ip`의 JSON 필드를 가지며 `/health` 로그가 없어야 합니다.

### 12.2 Prometheus·Grafana 실제 구성

```bash
kubectl create namespace monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack --namespace monitoring \
  --set grafana.adminUser="skills$NUMBER" \
  --set grafana.adminPassword="HelloKrSkills!$NUMBER@" \
  --set grafana.nodeSelector.unicorn=addon \
  --set prometheus.prometheusSpec.nodeSelector.unicorn=addon
```

관리형 Control Plane의 미노출 메트릭은 Helm values에서 다음처럼 끕니다.

```yaml
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
```

Grafana Service 앞에 인터넷 연결형 `unicorn-grafana-alb` / `unicorn-grafana-tg`를 만들고, `unicorn-grafana-dashboard`에 과제지와 같은 이름·순서·Panel type으로 5개 패널을 배치합니다.

```bash
kubectl -n monitoring get pods -o wide
kubectl -n monitoring get servicemonitor | \
  grep -E 'controller-manager|scheduler|etcd' || true
aws elbv2 describe-load-balancers --names unicorn-grafana-alb \
  --query 'LoadBalancers[0].[Scheme,State.Code,DNSName]'
```

Monitoring Pod는 Addon Node에 배치되고 DaemonSet만 App Node에서도 실행될 수 있습니다. 모든 Grafana 패널은 No Data가 아니라 실제 메트릭을 표시해야 합니다.

## 13. 실제 채점 요청

```bash
CF=$(aws cloudfront list-distributions   --query "DistributionList.Items[?Comment=='unicorn-svc-cf'].DomainName | [0]"   --output text)

RESP=$(curl -s -X POST "https://$CF/v1/book"   -H 'Content-Type: application/json'   -d '{"client_id":"C-MARK","username":"Judge","email":"judge@skills.kr","concert_name":"UnicornMark2026"}')
echo "$RESP"
BID=$(echo "$RESP" | jq -r '.booking_id')

curl -s "https://$CF/v1/book?booking_id=$BID" | jq .
curl -s -o /dev/null -w "%{http_code}
" "https://$CF/health"
```

POST의 booking_id, DynamoDB item, GET 응답 booking_id가 같아야 합니다. created_at도 저장되어야 합니다.

## 14. 제출 직전 체크리스트

1. unicorn-mark에서 mark.sh 실행
2. Endpoint 3종과 Flow Log 확인
3. KMS 세 alias가 모두 True 90
4. ECR scan finding 완전 0
5. EKS endpoint false true, 로그 5종
6. App Pod 2개 Ready/Available, 2개 AZ
7. POST/GET/health CloudFront 테스트
8. ALB 직접 요청 000 또는 403
9. XSS 403
10. 최신 POST 로그가 30초 안에 도착
11. /health 로그 검색 0
12. Grafana 5개 패널 No Data 없음
13. 모든 테스트와 부하 중지

## 15. 빠른 장애 진단

| 증상 | 확인 |
|---|---|
| ImagePullBackOff | ECR api/dkr, S3 Endpoint, SG, Node Role |
| kubectl 실패 | unicorn-mark, private endpoint, access entry |
| CloudFront 502 | VPC Origin, ALB SG, target health |
| POST 200인데 DB 없음 | Pod Identity, TABLE_NAME, KMS 권한 |
| GET 502 | Lambda permission, ALB response, DynamoDB 권한 |
| S3 403 | OAC, SourceArn, Data KMS policy |
| 로그가 문자열 | Fluent Bit JSON parser 순서 |
| /health 로그 존재 | exclude filter key/path |
| Grafana No Data | datasource, scrape target, label |
| Rate test 200 | 60초 window, rule priority, 전파 대기 |