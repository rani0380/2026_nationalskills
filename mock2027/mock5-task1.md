# 2027 지방대회 대비 모의고사 5회 · 제1과제

| 항목 | 조건 |
| --- | --- |
| 과제명 | Secure evidence upload API |
| 난이도 / 시간 / 배점 | 상 / 4시간 / 50점 |
| 리전 | 서울 ap-northeast-2 |
| 채점 | 교사 실기 평가 50점 |
| 과제 범위 | 자체 제작 연습문제. 제2과제와 독립적으로 응시 |

## 1. 무엇을 만드나요?

장비를 점검한 학생이 사진을 제출하는 API를 만듭니다. 사용자는 먼저 접수 번호와 임시 업로드 주소를 받습니다. 사진 파일은 Lambda를 거치지 않고 S3에 직접 전송합니다. 사용자가 완료 요청을 보내면 API가 S3에 파일이 있는지 확인하고 제출을 확정합니다.

구성 흐름은 **사용자 → API Gateway → Lambda → DynamoDB**입니다. 사진 자체는 **사용자 → 비공개 S3**로 이동합니다.

한 번 제출하는 동안 같은 접수 번호를 사용합니다. 접수 직후 DynamoDB에는 PENDING 기록만 있습니다. S3 업로드가 성공해도 아직 PENDING이고, 완료 API가 객체를 확인한 뒤에 READY가 됩니다. READY에 기록된 버전은 그때 제출한 사진을 가리킵니다.

## 2. 콘솔에서 준비할 리소스

| 서비스 | 이름 | 필수 설정 |
| --- | --- | --- |
| S3 | evidence-<계정ID>-<비번호> | 서울, 퍼블릭 액세스 차단 4개, 버전 관리 활성, SSE-S3, Bucket owner enforced |
| DynamoDB | evidence-uploads | PK upload_id(String), On-demand |
| Lambda | evidence-api | Python 3.12, 환경 변수 BUCKET_NAME과 TABLE_NAME |
| API Gateway | evidence-http | HTTP API, Lambda 프록시 통합 2.0, Stage exam, 자동 배포 활성 |
| CloudWatch Logs | /aws/lambda/evidence-api | 보관 7일 |

S3 버킷 정책으로 TLS를 사용하지 않는 버킷과 객체 요청을 거부합니다. <계정ID>는 본인 AWS 계정의 12자리 ID, <비번호>는 본인 번호입니다. 실습용 사진만 사용합니다. 버킷이나 이미지 객체에 공개 읽기 권한을 부여하지 않습니다.

**콘솔 경로**는 S3 → 버킷 → 만들기, DynamoDB → 테이블 → 생성, IAM → 역할 → 역할 생성, Lambda → 함수 → 함수 생성, API Gateway → API 생성 → HTTP API 순입니다. 앱 코드는 직접 작성하여 Lambda의 **코드** 탭에 입력합니다. Stage exam을 선택해 배포된 세 경로에 연결합니다.

### 콘솔에서 입력하는 순서

1. **S3 → 범용 버킷 → 버킷 만들기**에서 서울 리전을 선택합니다. 버킷 이름은 위 표의 계정 ID와 비번호를 넣어 완성합니다. **객체 소유권**, **퍼블릭 액세스 차단**, **버킷 버전 관리**, **기본 암호화**를 설정합니다. TLS 거부 정책은 생성한 버킷의 **권한 → 버킷 정책**에서 작성합니다. 버킷 ARN과 객체 ARN을 모두 포함합니다.
2. **DynamoDB → 테이블 → 테이블 생성**에서 테이블 이름과 문자열 파티션 키를 넣습니다. 정렬 키는 필요하지 않습니다. **테이블 설정 사용자 지정**에서 용량 모드 On-demand를 확인합니다.
3. **IAM → 역할 → 역할 생성**에서 Lambda를 신뢰하는 실행 역할을 준비합니다. **Lambda → 함수 → 함수 생성**에서 Python 3.12와 이 역할을 선택합니다. **구성 → 환경 변수**의 BUCKET_NAME에는 실제 버킷 이름을, TABLE_NAME에는 evidence-uploads를 입력합니다. **코드** 탭에서 작성한 코드를 배포합니다.
4. **API Gateway → HTTP API → 통합**에 evidence-api를 연결하고, **경로**에서 아래 세 경로를 각각 같은 통합에 연결합니다. **스테이지**에서 exam의 자동 배포를 활성화합니다. 화면의 호출 URL 끝에 /exam이 포함되는지 확인합니다.
5. **CloudWatch → 로그 그룹**에서 /aws/lambda/evidence-api의 보존 기간을 7일로 설정합니다. 그룹이 아직 없다면 직접 만들거나 첫 함수 호출로 생성된 뒤 변경합니다.

| 메서드 | 경로 | Lambda가 사용할 값 |
| --- | --- | --- |
| POST | /uploads | JSON 본문의 device |
| POST | /uploads/{upload_id}/complete | 경로의 upload_id |
| GET | /uploads/{upload_id} | 경로의 upload_id |

HTTP API의 Lambda 프록시 2.0에서는 routeKey로 경로를 구분하고, 경로 변수는 pathParameters에서 읽습니다. 본문의 JSON 문자열을 파싱한 뒤 객체와 device 값의 타입을 확인합니다. 응답에는 statusCode, JSON Content-Type, JSON 문자열 body를 지정합니다.

## 3. 접수와 업로드

1. POST /uploads에 {"device":"pump-1"}을 받습니다. device는 앞뒤 공백을 제거한 뒤 1~40자 문자열이어야 합니다. 올바르지 않으면 400과 {"error":"invalid input"}을 반환합니다.
2. 서버에서 UUID를 생성해 upload_id로 사용합니다. 해당 레코드에 device, status=PENDING, object_key=images/<upload_id>.jpg를 저장합니다. 기존 UUID 레코드를 덮어쓰지 않도록 조건부 쓰기를 사용합니다.
3. 120초 동안 사용할 수 있는 S3 **사전 서명 POST**의 url과 fields를 생성합니다. 업로드 정책은 해당 객체 키, Content-Type=image/jpeg, 파일 크기 1~1,048,576바이트로 제한합니다. S3 클라이언트는 서울 리전과 SigV4를 사용합니다. 반환 형식은 {"upload_id":"<UUID>","status":"PENDING","upload":{"url":"<S3 URL>","fields":{}}}이고 HTTP 상태는 201입니다. fields에는 실제 S3 서명 폼 값이 들어갑니다.
4. CloudShell에서 반환된 폼 필드를 모두 그대로 전송하고 사진 파일을 마지막 multipart 필드 file에 첨부합니다. 브라우저 CORS 구성은 필요하지 않습니다. 폼 값이나 서명 주소 전체를 제출물에 복사하지 않습니다.

### 접수 결과의 예시

아래 값은 응답 구조를 보여 주는 예시입니다. 실제 호출의 upload_id, url, fields는 Lambda가 발급한 값을 사용합니다.

```json
{
  "upload_id": "11111111-2222-4333-8444-555555555555",
  "status": "PENDING",
  "upload": {
    "url": "https://evidence-example.s3.ap-northeast-2.amazonaws.com/",
    "fields": {
      "key": "images/11111111-2222-4333-8444-555555555555.jpg",
      "Content-Type": "image/jpeg",
      "policy": "<예시에서 가림>",
      "x-amz-signature": "<예시에서 가림>"
    }
  }
}
```

Boto3의 generate_presigned_post를 쓰면 Bucket과 Key에 지정한 값을 기준으로 키 조건이 생성됩니다. Content-Type은 폼 값과 정책 조건 양쪽에 지정하고, content-length-range는 정책 조건에 추가합니다. SDK가 반환하는 폼 필드에는 세션 토큰 등 위 예시보다 더 많은 항목이 있을 수 있습니다. 호출자는 실제 응답의 모든 폼 필드를 사용합니다.

## 4. 완료 처리와 조회

| 요청 | 조건 | 기대 응답 |
| --- | --- | --- |
| POST /uploads/{upload_id}/complete | 레코드 없음 | 404, {"error":"not found"} |
| POST /uploads/{upload_id}/complete | PENDING이고 해당 키에 업로드한 파일 없음 | 409, {"error":"upload not ready"} |
| POST /uploads/{upload_id}/complete | S3 객체 크기·Content-Type 조건 충족 | 200, status=READY 및 확인한 version_id |
| POST /uploads/{upload_id}/complete | 같은 접수 번호가 이미 READY | 200, 저장된 READY 결과 그대로 반환 |
| GET /uploads/{upload_id} | 레코드 있음 | 200, upload_id·device·status, READY이면 version_id 포함 |
| GET /uploads/{upload_id} | 레코드 없음 | 404, {"error":"not found"} |

- 경로의 upload_id를 검사하고, S3 키는 **DB에 저장된 object_key**를 사용합니다. 요청 본문에서 버킷, 키, 상태, 버전을 받아 확정하지 않습니다.
- 완료 요청은 저장된 키를 HeadObject로 조회합니다. Content-Type과 크기가 위 조건에 맞고 S3 VersionId가 확인된 경우에만 READY로 변경합니다. 객체가 존재하지만 조건이 맞지 않으면 409와 {"error":"invalid object"}를 반환합니다. 권한 오류나 내부 오류가 발생하면 성공으로 응답하지 않습니다.
- status=PENDING인 경우에만 조건부 UpdateItem으로 status=READY와 version_id를 함께 저장합니다. 동시 완료 요청으로 조건이 실패하면 일관된 읽기로 다시 조회하여 이미 확정된 버전을 반환합니다. 이후 같은 키에 새 버전이 생겨도 확정 레코드의 버전은 바뀌지 않아야 합니다.

### 완료 요청에서 확인하는 순서

1. DB에 해당 접수 번호가 없으면 404를 반환합니다. READY라면 저장된 version_id로 응답합니다. 이때 S3의 최신 버전을 다시 확인해 DB를 수정할 필요가 없습니다.
2. PENDING이라면 저장된 키의 메타데이터를 읽습니다. HeadObject에서 객체 미존재 404가 나오면 API는 409와 upload not ready를 반환합니다. S3 403은 권한 설정을 확인합니다.
3. ContentLength, ContentType, VersionId를 확인합니다. 버전 관리가 활성화되어 실제 버전 ID가 있어야 합니다. 정상이라면 DB 상태와 version_id를 한 번에 저장합니다.

예를 들어 첫 사진의 버전이 vA라면 완료 뒤 GET 응답은 아래와 같습니다. version_id에는 S3가 발급한 실제 값이 들어갑니다. 같은 키에 두 번째 사진 vB를 올린 뒤에도 GET과 완료 재호출의 version_id는 vA입니다.

```json
{
  "upload_id": "11111111-2222-4333-8444-555555555555",
  "device": "pump-1",
  "status": "READY",
  "version_id": "vA"
}
```

## 5. 권한과 로그

- Lambda 실행 역할은 지정 테이블에 대한 PutItem·GetItem·UpdateItem, 해당 버킷의 images/*에 대한 s3:PutObject·s3:GetObject를 허용합니다. 파일 미존재를 구분하는 데 필요한 s3:ListBucket은 해당 실습 버킷으로 제한합니다. 로그 권한은 별도로 부여합니다. 정적 액세스 키를 코드나 환경 변수에 넣지 않습니다.
- API Gateway Stage exam의 기본 제한을 초당 5 요청, 버스트 10으로 설정합니다. 호출은 이 실습의 비공개 데이터가 없는 테스트 환경에서 진행하며 별도 로그인 구현은 요구하지 않습니다.
- Lambda 로그에 요청 ID와 처리 상태를 남깁니다. 서명 필드, 임시 자격 증명, 파일 내용은 로그에 쓰지 않습니다.

| 실행 역할 권한 | 대상 리소스 |
| --- | --- |
| dynamodb:PutItem, dynamodb:GetItem, dynamodb:UpdateItem | arn:aws:dynamodb:ap-northeast-2:<계정ID>:table/evidence-uploads |
| s3:PutObject, s3:GetObject | arn:aws:s3:::evidence-<계정ID>-<비번호>/images/* |
| s3:ListBucket | arn:aws:s3:::evidence-<계정ID>-<비번호> |
| CloudWatch Logs 쓰기 | evidence-api 함수 로그 그룹과 스트림 |

API Gateway에서 exam 스테이지의 기본 경로 제한을 설정합니다. 콘솔에서 이 설정이 보이지 않으면 CloudShell에서 API_ID를 실제 ID로 바꿔 다음 명령을 실행합니다.

```bash
API_ID='본인 API ID'
aws apigatewayv2 update-stage --region ap-northeast-2 \
  --api-id "$API_ID" --stage-name exam \
  --default-route-settings '{"ThrottlingRateLimit":5,"ThrottlingBurstLimit":10}'
```

## 6. 시험 순서와 배점

1. 유효한 접수 요청으로 201과 PENDING을 확인합니다. 사진 업로드 전에 완료 요청을 보내 409인지 확인합니다.
2. 발급받은 폼으로 작은 JPEG를 올립니다. 별도 접수 번호로 제한을 넘는 파일과 폼 키를 바꾼 요청이 각각 S3에서 거부되는지 확인합니다.
3. 완료 요청을 보내 READY와 version_id를 확인합니다. 준비해 둔 두 번째 사진을 같은 폼이 유효한 시간 안에 동일 키에 올려 새 버전을 만든 뒤, 완료 재호출과 조회에서 최초 확정 버전이 유지되는지 확인합니다.
4. 존재하지 않는 번호, 빈 장비 이름, S3 객체의 익명 직접 읽기 실패를 확인합니다. 화면에는 상태 코드와 결과만 기록하고 서명 폼 값은 가립니다.

### CloudShell 호출 예시

실습용 사진 두 장을 sample-1.jpg와 sample-2.jpg라는 이름으로 같은 작업 폴더에 둡니다. 각각 1MiB 이하여야 합니다. curl과 jq를 사용합니다. 먼저 시험용 API 주소를 지정해 접수합니다.

```bash
BASE='https://본인APIID.execute-api.ap-northeast-2.amazonaws.com/exam'
umask 077
curl -sS --fail -o receipt.json -w '접수 HTTP %{http_code}\n' \
  -H 'Content-Type: application/json' \
  -d '{"device":"pump-1"}' "$BASE/uploads"
UPLOAD_ID=$(jq -er '.upload_id' receipt.json)
curl -sS -i -X POST "$BASE/uploads/$UPLOAD_ID/complete"
```

접수는 201, 업로드 전 완료는 409가 나와야 합니다. receipt.json에는 사전 서명 폼 값이 들어 있으므로 제출물에 포함하지 않습니다. 발급 후 120초 안에 아래 업로드를 진행합니다. 시간이 지났다면 접수부터 다시 실행하여 새 번호와 폼을 받습니다.

```bash
upload_photo() {
  local photo=$1 url field
  local -a form=()
  url=$(jq -er '.upload.url' receipt.json) || return 1
  jq -e '.upload.fields | type == "object" and length > 0' \
    receipt.json >/dev/null || return 1
  while IFS= read -r field; do
    form+=(--form-string "$field")
  done < <(jq -r '.upload.fields | to_entries[] | "\(.key)=\(.value)"' receipt.json)
  curl -sS --fail -o /dev/null -w '업로드 HTTP %{http_code}\n' \
    "${form[@]}" --form "file=@$photo;type=image/jpeg" "$url"
}

upload_photo sample-1.jpg &&
  curl -sS -i -X POST "$BASE/uploads/$UPLOAD_ID/complete"
curl -sS -i "$BASE/uploads/$UPLOAD_ID"

# 첫 사진이 READY로 확정된 것을 확인하고, 같은 폼이 유효할 때 실행
upload_photo sample-2.jpg &&
  curl -sS -i -X POST "$BASE/uploads/$UPLOAD_ID/complete"
curl -sS -i "$BASE/uploads/$UPLOAD_ID"
```

두 GET의 version_id를 비교합니다. **S3 → 버킷 → 객체 → 버전 표시**에서 같은 키에 버전이 두 개 있는지, **DynamoDB → 테이블 → 항목 탐색**에서 확정 레코드가 처음 버전을 유지하는지 확인합니다.

제한 위반 시험은 별도의 새 접수로 진행합니다. 하나는 정상 폼에 1MiB를 넘는 실습 파일을 넣고, 다른 하나는 복사한 폼의 key 필드만 다른 경로로 바꿉니다. 두 경우 모두 S3가 요청을 거부해야 합니다. 채점 시에는 반환된 상태 코드와 객체 생성 여부만 보여 줍니다.

| 영역 | 확인할 항목 | 배점 |
| --- | --- | --- |
| 저장소 | S3 비공개·버전·암호화·TLS 6, DynamoDB 키·용량 4 | 10 |
| API 설정 | HTTP API·경로·Stage·통합 6, 호출 제한·로그 4 | 10 |
| 접수·업로드 | UUID와 PENDING 저장 4, 서명 제약 5, 정상·제한 초과·키 변경 시험 5 | 14 |
| 완료·조회 | 미업로드·입력 오류·없는 번호 4, READY 조건부 확정 및 버전 유지 6 | 10 |
| 권한 | 실행 역할 최소 권한 4, 정적 키와 서명 로그 미사용 2 | 6 |
| 합계 | 교사 실기 평가 | 50 |

실습 후 API를 비활성화하거나 삭제하고, 실습용 Lambda·테이블·권한과 S3 객체 버전·삭제 마커를 정리합니다.

## 참고 자료

S3 사전 서명 POST: https://docs.aws.amazon.com/boto3/latest/reference/services/s3/client/generate_presigned_post.html

HTTP API Lambda 통합 2.0: https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-lambda.html

S3 객체 메타데이터 확인: https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadObject.html
