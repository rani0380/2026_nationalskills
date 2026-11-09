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

## 3. 접수와 업로드

1. POST /uploads에 {"device":"pump-1"}을 받습니다. device는 앞뒤 공백을 제거한 뒤 1~40자 문자열이어야 합니다. 올바르지 않으면 400과 {"error":"invalid input"}을 반환합니다.
2. 서버에서 UUID를 생성해 upload_id로 사용합니다. 해당 레코드에 device, status=PENDING, object_key=images/<upload_id>.jpg를 저장합니다. 기존 UUID 레코드를 덮어쓰지 않도록 조건부 쓰기를 사용합니다.
3. 120초 동안 사용할 수 있는 S3 **사전 서명 POST**의 url과 fields를 생성합니다. 업로드 정책은 해당 객체 키, Content-Type=image/jpeg, 파일 크기 1~1,048,576바이트로 제한합니다. S3 클라이언트는 서울 리전과 SigV4를 사용합니다. 반환 형식은 {"upload_id":"<UUID>","status":"PENDING","upload":{"url":"<S3 URL>","fields":{}}}이고 HTTP 상태는 201입니다. fields에는 실제 S3 서명 폼 값이 들어갑니다.
4. CloudShell에서 반환된 폼 필드를 모두 그대로 전송하고 사진 파일을 마지막 multipart 필드 file에 첨부합니다. 브라우저 CORS 구성은 필요하지 않습니다. 폼 값이나 서명 주소 전체를 제출물에 복사하지 않습니다.

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

## 5. 권한과 로그

- Lambda 실행 역할은 지정 테이블에 대한 PutItem·GetItem·UpdateItem, 해당 버킷의 images/*에 대한 s3:PutObject·s3:GetObject를 허용합니다. 파일 미존재를 구분하는 데 필요한 s3:ListBucket은 해당 실습 버킷으로 제한합니다. 로그 권한은 별도로 부여합니다. 정적 액세스 키를 코드나 환경 변수에 넣지 않습니다.
- API Gateway Stage exam의 기본 제한을 초당 5 요청, 버스트 10으로 설정합니다. 호출은 이 실습의 비공개 데이터가 없는 테스트 환경에서 진행하며 별도 로그인 구현은 요구하지 않습니다.
- Lambda 로그에 요청 ID와 처리 상태를 남깁니다. 서명 필드, 임시 자격 증명, 파일 내용은 로그에 쓰지 않습니다.

## 6. 시험 순서와 배점

1. 유효한 접수 요청으로 201과 PENDING을 확인합니다. 사진 업로드 전에 완료 요청을 보내 409인지 확인합니다.
2. 발급받은 폼으로 작은 JPEG를 올립니다. 별도 접수 번호로 제한을 넘는 파일과 폼 키를 바꾼 요청이 각각 S3에서 거부되는지 확인합니다.
3. 완료 요청을 보내 READY와 version_id를 확인합니다. 준비해 둔 두 번째 사진을 같은 폼이 유효한 시간 안에 동일 키에 올려 새 버전을 만든 뒤, 완료 재호출과 조회에서 최초 확정 버전이 유지되는지 확인합니다.
4. 존재하지 않는 번호, 빈 장비 이름, S3 객체의 익명 직접 읽기 실패를 확인합니다. 화면에는 상태 코드와 결과만 기록하고 서명 폼 값은 가립니다.

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
