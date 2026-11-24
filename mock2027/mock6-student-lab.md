# 모의고사 6회 · 학생용 단계별 실습

처음 학습할 때는 아래 순서로 진행합니다. 제1·2과제는 독립된 과제이며, 한 과제씩 완료하세요. 연습은 두 과제 합계 12~16시간을 권장하고, 모의시험은 기존대로 과제당 4시간·50점입니다. 권장 시간은 학습 계획이며 실제 소요시간은 숙련도에 따라 달라집니다.

## 1. 문제를 풀기 전에

| 스스로 할 수 있어야 하는 것 | 확인 |
| --- | --- |
| S3 객체를 올리고 실제 VersionId 확인 | 직접 업로드하고 버전 표시 |
| IAM 역할과 액세스 키 구분 | EC2/ECS 역할로 접근한다고 설명 |
| Python 함수·예외·JSON·CSV | 함수의 반환값·실패 예외 구분 |
| VPC 서브넷·라우팅·SG | 공인 IP 없이 AWS 서비스 접근 경로 설명 |
| CloudShell과 실제 서버 구분 | 웹 파일은 CloudShell이 아닌 EC2에 있다고 설명 |

아직 어려운 항목은 교사와 먼저 연습합니다. 새 모의시험을 시작할 때는 이전 회차의 동일 이름 리소스와 혼동하지 않도록 전용 계정을 사용합니다.

## 2. 학생에게 제공되는 파일

각 문제 상단의 ‘실습 제공 파일’에서 해당 과제 파일을 같은 디렉터리에 내려받습니다. 브라우저에서 이름이 worker(1).py처럼 바뀌면 원래 이름으로 정리합니다.

| 과제 | 파일 | 용도 |
| --- | --- | --- |
| 제1과제 | worker.py | 메시지 수신·파일 읽기·DB 후 삭제 흐름. TODO 3개 |
| 제1과제 | Dockerfile, requirements.txt | 컨테이너 빌드 틀 |
| 제1과제 | test_worker.py | 입력 검증·처리 순서 오프라인 확인 |
| 제1과제 | input.csv, invalid.csv, job.json | 정상·실패 데이터와 메시지 |
| 제2과제 | deploy.py | 설정 검증·배포 틀. TODO 2개 |
| 제2과제 | make_document.py | 수정한 Python을 SSM Command JSON으로 변환 |
| 제2과제 | test_deploy.py | 검증·파일 생성·실패 경로 오프라인 확인 |
| 제2과제 | site-v1.json, site-v2.json, site-invalid.json | 정상 버전 두 개와 오류 버전 |

시작 코드는 완성된 정답이 아닙니다. TODO가 남아 있으면 NotImplementedError 또는 CONFIG_DEPLOY_FAILED로 끝납니다. 오류를 지우려고 예외를 무시하거나 고정 성공값을 반환하면 안 됩니다. 테스트 파일은 수정하지 않습니다.

## 3. 제1과제 1단계: AWS 없이 데이터 검증

worker.py에서 TODO 1 validate_job과 TODO 2 summarize를 구현합니다.

```bash
cd 본인의-제1과제-폴더
python3 -m unittest -v test_worker.ValidationTests
```

| 함수 | 입력 | 반환 |
| --- | --- | --- |
| validate_job | SQS body JSON 문자열 | job_id·source_key·source_version dict |
| summarize | CSV bytes | total·pass·fail 정수 dict |

정상 CSV는 total=4/pass=3/fail=1입니다. 빈 데이터·UNKNOWN·초과 열·101행·크기 초과는 ValueError여야 합니다. 테스트가 ERROR/FAIL이면 다음 단계로 넘어가기 전에 원인을 기록합니다.

확인 질문: source_version을 무시하고 최신 객체를 읽으면 어떤 시험에서 틀릴까요? CSV 100행 제한에서 헤더를 포함할까요? 데이터 행만 100개입니다.

## 4. 제1과제 2단계: 저장소·큐·네트워크

문제의 S3·DynamoDB·SQS·DLQ와 VPC Endpoint를 만듭니다. 앱 구현과 무관하게 아래 증거를 먼저 남깁니다.

| 확인 | 통과 기준 |
| --- | --- |
| VPC DNS | DNS resolution·hostnames 활성 |
| 작업자 서브넷 | 서로 다른 A/C AZ, 인터넷 기본 경로 없음 |
| Interface Endpoint | ecr.api·ecr.dkr·logs·sqs, 두 AZ, Private DNS |
| Gateway Endpoint | S3·DynamoDB가 두 Private RT에 연결 |
| SG | Endpoint 443은 worker SG만, worker inbound 없음 |
| SQS | 원본 visibility 180초, long poll 20초, maxReceiveCount 3 |
| 버킷 | 버전 관리·공개 차단·SSE-S3·TLS 정책 |

브라우저의 CloudShell에서 접속된다는 사실은 Private Task에서도 접속된다는 증거가 아닙니다.

## 5. 제1과제 3단계: TODO 3 구현

get_or_create_report는 다음 순서대로 구현합니다.

1. 보고서 key를 reports/job_id.json으로 고정합니다.
2. read_report로 조회합니다. 기존 보고서가 있으면 match_report 후 반환합니다.
3. 없으면 read_source → summarize를 호출하고 원본 세 필드와 집계를 합칩니다.
4. IfNoneMatch="*"로 최초 생성합니다. 성공하면 보고서를 반환합니다.
5. 412이면 기존 보고서를 읽고 match_report 후 반환합니다.
6. 409는 제한 횟수만 재시도하고 끝내 해결되지 않으면 실패합니다.
7. 다른 오류는 그대로 실패시킵니다. 생성한 보고서를 삭제하지 않습니다.

제공된 process_message는 보고서 확인 → DynamoDB PutItem → DeleteMessage 순서입니다. 이 순서를 바꾸지 않습니다.

```bash
python3 -m unittest -v test_worker
```

오프라인 확인이 통과해도 실제 S3 조건부 쓰기 경쟁과 IAM·Endpoint 연결은 별도 실기 시험으로 확인해야 합니다. 테스트에 포함되지 않은 요구사항도 문제지대로 구현합니다.

## 6. 제1과제 4단계: 이미지·ECS 배포

수정한 worker.py와 Dockerfile·requirements.txt가 같은 폴더에 있어야 합니다. 빌드 전 TODO를 검토하고 설치된 boto3가 PutObject IfNoneMatch를 지원하는지 확인합니다.

```bash
# 인터넷이 있는 Docker 빌드 환경에서 실행합니다.
# REPOSITORY_URI는 콘솔의 본인 report-worker ECR URI로 교체합니다.
REPOSITORY_URI="본인계정.dkr.ecr.ap-northeast-2.amazonaws.com/report-worker"
REGISTRY=$(printf '%s' "$REPOSITORY_URI" | cut -d/ -f1)
aws ecr get-login-password --region ap-northeast-2 | \
  docker login --username AWS --password-stdin "$REGISTRY"
docker build --platform linux/amd64 -t report-worker:v1 .
docker tag report-worker:v1 "$REPOSITORY_URI:v1"
docker push "$REPOSITORY_URI:v1"
```

빌드가 끝나면 설치된 의존성 버전을 기록합니다. ECR v1은 immutable이므로 연습 중 재빌드는 v2 등의 새 태그로 시험합니다. 최종 평가용 깨끗한 저장소에서 제출 이미지를 v1으로 push하고 해당 Task Definition revision을 사용합니다. 다른 학생의 이미지를 삭제하지 않습니다.

ECS에서 QUEUE_URL·BUCKET_NAME·TABLE_NAME·AWS_REGION을 입력하고 Execution Role/Task Role을 구분합니다. 최초 로그 WORKER_READY를 확인합니다. TODO가 남아 있으면 메시지 처리에서 JOB_FAILED가 나오는 것이 맞습니다. WORKER_READY만으로 작업 성공이라고 판단하지 않습니다.

## 7. 제1과제 5단계: 한 시험씩 실행

| 순서 | 입력 | 반드시 볼 증거 |
| --- | --- | --- |
| A | 정상 exam-001 | 보고서 4/3/1, DB DONE |
| B | 같은 메시지 두 개 | 정확한 보고서 key의 객체 버전 1개 |
| C | 같은 key의 latest 변경, 예전 버전 지정 | 예전 정상 내용으로 집계 |
| D | invalid.csv | 실패 로그·DLQ. DONE 없음 |
| E | 성공 job_id에 다른 원본 버전 | JOB_CONFLICT 또는 오류 유형, 기존 데이터 유지 |
| F | 교사가 DB 일시 실패 유도 후 복구 | 보고서 재사용·DB 복구·그 후 삭제 |
| G | Task 하나 중지 | 다른 Task 유지·새 Task 생성·RUNNING 2 |
| H | DLQ 실제 적재 | 실제 경보 ALARM |

오류 메시지를 먼저 많이 보내면 정상 시험과 섞입니다. 각 job_id·전송 시각·기대 결과를 기록하며 하나씩 진행하세요.

## 8. 제2과제 1단계: 로컬에서 설정 검증

deploy.py TODO 1 validate_config를 구현합니다.

```bash
cd 본인의-제2과제-폴더
python3 -m unittest -v test_deploy.ConfigTests.test_valid_message \
  test_deploy.ConfigTests.test_invalid_values \
  test_deploy.ConfigTests.test_invalid_json
python3 deploy.py --check-file site-v1.json
python3 deploy.py --check-file site-invalid.json
```

첫 파일은 CONFIG_VALID/exit 0, 오류 파일은 CONFIG_DEPLOY_FAILED/exit 1이어야 합니다. --check-file은 실제 웹 파일을 변경하지 않습니다.

TODO 2 commit_config를 구현합니다. 제공 atomic_write helper를 사용하고 두 파일 bytes를 먼저 완성합니다. metadata에는 bucket·key·version_id·message 네 값을 넣습니다. root 인자는 테스트용 임시 디렉터리이므로 경로 앞의 /를 잘못 붙여 root를 무시하지 않도록 합니다.

```bash
python3 -m unittest -v test_deploy
```

## 9. 제2과제 2단계: Document 생성과 서버 준비

```bash
python3 make_document.py
python3 -m json.tool config-deploy.json >/dev/null
```

config-deploy.json을 Systems Manager Command 문서 config-deploy로 등록합니다. 이 도구는 deploy.py 전체를 문서 안에 포함하므로 EC2에 별도 코드 파일을 업로드할 필요가 없습니다. 코드를 고친 뒤에는 생성 도구를 다시 실행하고 SSM 문서 새 버전을 등록·기본 버전을 갱신합니다. Association이 사용하는 문서 버전도 확인합니다.

서버에는 Python 3·nginx·AWS CLI·최신 SSM Agent가 미리 있어야 합니다. 두 노드 Online과 nginx 정상 응답부터 확인합니다. 생성된 JSON이 문법상 정상이어도 TODO 구현과 권한이 갖춰지지 않으면 배포는 실패합니다.

## 10. 제2과제 3단계: v1·v2·오류·복원

1. 세 설정 파일을 같은 config/site.json 키에 올리고 VersionId 세 개를 기록합니다.
2. Association에 v1을 넣어 두 노드 모두 Welcome v1인지 확인합니다.
3. v2로 바꾸고 두 노드의 페이지·metadata를 확인합니다.
4. Run Command로 두 파일 hash를 기록합니다.
5. invalid 버전을 적용하고 두 노드의 Failed·두 파일 hash 보존을 확인합니다.
6. CloudWatch 출력 옵션을 켠 같은 Document의 Run Command로 실패 로그·경보를 확인합니다.
7. Association을 v1으로 되돌려 두 노드 모두 복원합니다.
8. v1을 다시 적용해 내용·hash가 변하지 않는지 확인합니다.

확인할 명령은 EC2에서 SSM Run Command로 실행합니다. CloudShell 로컬의 /usr/share/nginx 경로를 조회하지 않습니다.

```bash
curl --fail --silent http://localhost/
cat /var/lib/config-lab/deployment.json
sha256sum /usr/share/nginx/html/index.html /var/lib/config-lab/deployment.json
```

## 11. 학생 결과 기록 양식

| 시험 ID | 실행 시각 | 입력 key·VersionId·job_id | 기대 결과 | 실제 결과 | 증거 파일 | 재시도 원인 |
| --- | --- | --- | --- | --- | --- | --- |
| 1-A | 본인 입력 | 본인 입력 | 4/3/1·DONE | 본인 기록 | 본인 기록 | 해당 시 기록 |
| 1-B | 본인 입력 | exam-001 중복 | 보고서 버전 1개 | 본인 기록 | 본인 기록 | 해당 시 기록 |
| 2-v2 | 본인 입력 | v2 실제 ID | 두 노드 v2 | 본인 기록 | 본인 기록 | 해당 시 기록 |
| 2-invalid | 본인 입력 | invalid 실제 ID | Failed·hash 유지 | 본인 기록 | 본인 기록 | 해당 시 기록 |
| 2-rollback | 본인 입력 | v1 실제 ID | 두 노드 v1 | 본인 기록 | 본인 기록 | 해당 시 기록 |

원본 문제지의 나머지 시험도 행을 추가합니다. 테스트 출력은 연습 확인 자료이며 자동 채점 만점으로 바꾸지 않습니다. 기존 각 과제의 50점 실기 배점과 부분점수는 유지합니다.

## 12. 막혔을 때 질문하는 방법

“안 돼요” 대신 과제·단계 번호, 성공한 마지막 단계, 비밀정보를 제거한 오류 종류, 실제 확인한 리소스 이름과 기대/실제 결과를 함께 제시하세요. 토큰·비밀번호·Access Key는 보내지 않습니다.

연습 후에는 문제의 정리 순서대로 리소스를 제거합니다. 두 과제에 필요한 Endpoint·EC2 등은 사용 시간에 따라 과금되므로 종료 여부를 교사와 확인합니다.
