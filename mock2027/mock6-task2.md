# 2027 지방대회 대비 모의고사 6회 · 제2과제

| 항목 | 조건 |
| --- | --- |
| 과제명 | Versioned configuration deployment and rollback |
| 난이도 / 시간 / 배점 | 상 / 4시간 / 50점 |
| 리전 | 서울 ap-northeast-2 |
| 채점 | 교사 실기 평가 50점 |
| 출제 구분 | 자체 제작 연습문제. 제1과제와 독립적으로 응시 |

보충 개정: 2026. 11. 24. · 기존 4시간·50점과 리소스 이름을 유지하고 배포·실패·롤백 시험을 구체화했습니다. 별도 보충 해설은 왼쪽 메뉴의 ‘6회 · 구현·검증 해설’에서 확인합니다.

## 1. 무엇을 만드나요?

웹 서버 두 대의 안내 문구를 SSH 없이 변경합니다. 설정 파일은 S3 버전으로 관리하고, Systems Manager가 지정한 버전을 두 서버에 적용합니다. 잘못된 설정이면 기존 웹 페이지를 그대로 유지해야 합니다. 문제가 생겼을 때는 이전 버전으로 되돌립니다.

흐름은 **S3 설정 버전 → SSM Command Document → 태그로 선택한 EC2 두 대 → nginx 웹 페이지**입니다. 실습 데이터는 단순한 안내 문구만 사용합니다.

## 2. 콘솔에서 서버와 저장소 준비

| 리소스 | 이름 | 필수 조건 |
| --- | --- | --- |
| EC2 | config-web-1, config-web-2 | AL2023, t3.micro, 두 AZ에 한 대씩 |
| EC2 공통 태그 | Project=ConfigLab, Role=web | 두 서버에 모두 지정 |
| IAM 역할 | config-web-role | EC2 신뢰, SSM Agent·설정 읽기·실행 로그에 필요한 권한 |
| S3 | config-store-<계정ID>-<비번호> | 서울, 공개 차단 4개, 버전 관리, SSE-S3 |
| SSM Document | config-deploy | Command, 스키마 2.2 |
| SSM Association | config-deploy-assoc | Role=web 태그 대상, rate(30 minutes) |

EC2는 공인 주소가 있는 Public 서브넷과 인터넷 경로를 사용하거나, 필요한 Endpoint를 갖춘 Private 서브넷을 사용할 수 있습니다. 두 인스턴스의 SSM Agent가 Online이어야 합니다. 모든 연결된 SG에서 SSH 22를 허용하지 않습니다. 채점은 Run Command로 localhost HTTP를 확인하므로 외부 HTTP 개방은 필수가 아닙니다.

**콘솔 순서**는 IAM → EC2 역할 생성 → EC2 두 대 시작 및 역할 연결 → Systems Manager 관리 노드에서 Online 확인 → S3 버킷 생성입니다. 서버에 nginx와 AWS CLI를 준비하고 nginx를 부팅 시 자동 시작합니다.

## 3. 설정 파일 준비

문제지 상단의 세 파일을 내려받습니다. S3의 같은 키 config/site.json에 순서대로 업로드하면서 각 VersionId를 기록합니다.

| 파일 | 역할 | 내용 |
| --- | --- | --- |
| site-v1.json | 최초 배포 | {"message":"Welcome v1"} |
| site-v2.json | 변경 배포 | {"message":"Welcome v2"} |
| site-invalid.json | 실패 시험 | {"message":""} |

message는 앞뒤 공백을 제거한 후 1~80자인 문자열이어야 합니다. JSON 객체가 아니거나 message가 없거나 타입·길이가 맞지 않으면 실패입니다. 다른 필드는 무시할 수 있습니다.

버킷 정책으로 비 TLS 요청을 거부합니다. 서버 역할의 설정 데이터 권한은 해당 config/site.json의 s3:GetObjectVersion으로 제한합니다. latest 객체를 읽는 GetObject로 대신하지 않습니다.

## 4. SSM Document 구현

Systems Manager의 **Documents → 문서 생성 → Command 또는 Session 문서**에서 Command 타입의 config-deploy를 만듭니다. 다음 매개변수를 정의합니다.

| 매개변수 | 타입 | 조건 |
| --- | --- | --- |
| BucketName | String | 지정한 실습 버킷 이름 |
| VersionId | String | 실제 S3 VersionId, 빈 문자열·null 거부 |

문서는 실행 시 다음 순서로 동작해야 합니다.

1. 매개변수는 셸에서 안전하게 사용합니다. 환경 변수 보간을 사용하거나, 명확한 유효성 검사와 인용을 적용해 문자열이 셸 명령으로 실행되지 않게 합니다.
2. S3 config/site.json을 VersionId로 지정해 임시 파일에 내려받습니다. 임시 파일 이름은 실행마다 충돌하지 않게 만듭니다.
3. JSON 구조와 message를 검증합니다. 다운로드나 검증에 실패하면 명령을 비정상 종료하고 현재 index.html과 배포 정보 파일을 바꾸지 않습니다.
4. 성공한 message와 줄바꿈 하나를 /usr/share/nginx/html/index.html로 반영합니다. 파일 교체는 임시 파일을 만든 뒤 같은 파일시스템 안에서 원자적으로 이동합니다. nginx가 읽을 수 있는 권한을 설정합니다.
5. /var/lib/config-lab/deployment.json에 bucket, key, version_id, message를 기록합니다. message와 version_id는 실제 배포에 사용한 값이어야 합니다.
6. 매번 같은 버전을 실행해도 같은 결과가 나와야 합니다. stdout에는 버전과 성공·실패 요약만 남깁니다. 사용자 데이터 전체나 AWS 자격 증명은 기록하지 않습니다.

페이지와 배포 정보의 교체가 모두 끝난 뒤 HTTP 응답을 확인하여 성공으로 종료합니다. 이 과제는 명령 두 개가 동시에 실행되는 장애나 운영체제 강제 종료 시점까지의 트랜잭션 복구를 요구하지 않습니다.

## 5. Association과 권한·관측

- **Systems Manager → State Manager → 연결 생성**에서 config-deploy-assoc를 만듭니다. 문서는 config-deploy, 대상 키는 tag:Role, 값은 web입니다. 같은 계정·리전의 다른 서버에 Role=web을 붙이지 않습니다.
- 매개변수 BucketName은 지정 버킷, VersionId는 현재 적용할 정상 버전으로 입력합니다. 스케줄은 rate(30 minutes)입니다. 버전을 바꿀 때는 association 매개변수를 수정하고 즉시 실행합니다.
- 인스턴스 역할에는 AmazonSSMManagedInstanceCore와 지정 객체 버전 읽기 권한을 부여합니다. 채점용 Run Command 출력은 CloudWatch Logs의 /config-lab/commands로 보내고 보관 14일로 설정합니다. 로그 스트림 생성·전송 권한을 해당 그룹으로 제한합니다.
- CloudWatch 지표 필터에서 CONFIG_DEPLOY_FAILED 문자열을 카운트하여 ConfigLab/DeployFailures 지표를 만듭니다. 경보 config-deploy-failed는 Sum, 60초, 1회, 1 이상, notBreaching입니다. 실패 시험 전에 필터와 경보를 준비합니다.
- SSM Document는 검증이나 읽기 실패 시 CONFIG_DEPLOY_FAILED를 출력하고 nonzero로 종료해야 합니다.

## 6. 시험 순서와 채점

1. association에 v1의 실제 VersionId를 지정해 두 대 모두 적용합니다. SSM Run Command에서 curl -s localhost와 배포 정보 파일을 읽어 Welcome v1 및 v1 버전을 확인합니다.
2. association을 v2로 수정하고 즉시 실행합니다. 두 서버가 Welcome v2와 v2 버전을 보여야 합니다.
3. 잘못된 JSON의 VersionId로 실행합니다. 두 대상은 실패 상태이며 기존 페이지와 배포 정보는 v2 그대로여야 합니다. 경보 ALARM과 실패 로그를 확인합니다.
4. association의 VersionId를 v1으로 돌리고 다시 실행합니다. S3의 최신 객체가 잘못된 JSON이어도 두 서버는 Welcome v1으로 복원되어야 합니다.
5. 같은 v1을 다시 적용해 문구가 중복되지 않는지 확인합니다. 평가 전 최종 association 매개변수도 v1으로 맞춥니다.

| 영역 | 확인할 항목 | 배점 |
| --- | --- | --- |
| 서버·관리 연결 | 두 AZ·사양·nginx 4, SSM Online 및 SSH 미허용 6 | 10 |
| 저장소·권한 | S3 버전·공개 차단·암호화·TLS 4, 지정 버전 읽기·SSM·로그 권한 4 | 8 |
| Document | 버전 지정 읽기·매개변수 처리 5, 검증 후 원자적 페이지 교체·정보 기록 7 | 12 |
| 배포·복구 | 태그 대상 association·스케줄 4, 두 서버 v1→v2 변경 4, 실패 보존 및 v1 복원·반복 실행 6 | 14 |
| 관측 | 로그 보관·메시지 3, 실제 경보 전이 3 | 6 |
| 합계 | 교사 실기 평가 | 50 |

두 노드의 실행 결과, 페이지·배포 파일, 각 VersionId, 실패 시 보존 증거와 경보 이력을 제출합니다. 평가 후 association을 먼저 삭제하고 실습용 Document·서버·역할·경보·로그·S3 객체 버전을 정리합니다.

## 참고 자료

SSM 문서 매개변수: https://docs.aws.amazon.com/systems-manager/latest/userguide/documents-syntax-data-elements-parameters.html

State Manager association: https://docs.aws.amazon.com/systems-manager/latest/userguide/state-manager.html

## 7. 보충: 서버 준비와 네트워크 조건

이 과제는 문구 배포를 평가합니다. nginx·AWS CLI v2·Python 3·SSM Agent는 문서 실행 전에 설치되어 있어야 합니다. SSM Document의 매 실행마다 패키지를 설치하지 않습니다.

| 구성 | 반드시 확인할 내용 |
| --- | --- |
| Public 방식 | 서로 다른 두 AZ, 공인 IPv4, IGW 기본 경로, outbound HTTPS. SSH 인바운드는 없음 |
| Private 방식 | ssm·ssmmessages Interface Endpoint, S3 접근 경로, 로그 Endpoint. 사용 Agent·환경이 요구하면 ec2messages도 준비 |
| 패키지 준비 | Private Endpoint만으로 일반 패키지 저장소에 모두 접근할 수 있다고 가정하지 않음. 사전 설치 AMI 또는 통제된 초기 설치 경로 사용 |
| 관리 연결 | Systems Manager 관리 노드에서 두 InstanceId와 PingStatus=Online 확인 |
| 웹 서버 | systemctl is-active nginx, curl --fail http://localhost/ 정상 |
| IAM | EC2 instance profile 연결, SSM 권한, 지정 객체 GetObjectVersion, 지정 로그 그룹 전송 |

실습 전용 두 서버에만 Role=web을 붙입니다. 다른 수업 서버와 공유 계정이면 별도 계정을 사용하거나 대상 충돌을 사전에 제거합니다. 이 문제의 최종 association 대상은 지정한 tag:Role=web을 유지합니다.

## 8. 보충: 버전 확보와 안전한 배포 절차

S3 콘솔에서 ‘버전 표시’를 켜거나 업로드 응답으로 각 VersionId를 얻습니다. 파일 이름을 v1/v2로 다르게 저장하는 것이 아니라 모두 같은 config/site.json 키에 올려야 합니다.

| 논리 이름 | 실제 VersionId | message |
| --- | --- | --- |
| v1 | 본인 업로드 응답의 값 | Welcome v1 |
| v2 | 본인 업로드 응답의 값 | Welcome v2 |
| invalid | 본인 업로드 응답의 값 | 빈 문자열 |

Document의 BucketName·VersionId String 매개변수에는 interpolationType=ENV_VAR를 사용합니다. 실행 스크립트는 SSM_BucketName·SSM_VersionId를 읽습니다. 이 기능을 지원하는 최신 SSM Agent를 준비하고, 환경 변수가 없으면 안전하게 실패시킵니다. 매개변수 값을 {{VersionId}} 형태로 셸 본문에 직접 넣는 fallback은 사용하지 않습니다.

1. 고유 임시 디렉터리를 만들고 종료 시 제거하도록 합니다. 실습 버킷 이름과 비어 있지 않은 VersionId를 검사합니다.
2. aws s3api get-object에 bucket, key=config/site.json, version-id를 모두 지정합니다.
3. 최대 64KiB의 JSON 객체인지 확인하고 message가 문자열이며 strip 후 1~80자인지 검사합니다. 개행·제어문자도 거부하여 웹 문구 한 줄을 유지합니다.
4. index.html과 deployment.json의 완성된 새 내용을 각각 임시 파일에 씁니다. JSON은 문자열 이어붙이기 대신 JSON serializer로 생성합니다.
5. 새 페이지는 /usr/share/nginx/html 안의 임시 파일에 만들고 chmod 644 후 os.replace 또는 같은 파일시스템 mv로 교체합니다. /tmp의 파일을 곧바로 이동하는 것만으로 원자적 교체를 보장한다고 가정하지 않습니다.
6. 정보 파일도 /var/lib/config-lab 안에서 임시 파일을 만든 뒤 교체합니다. 정보 파일의 bucket·key·version_id·message는 실제 읽은 버전과 같아야 합니다.
7. curl의 성공 여부와 실제 응답 본문을 확인합니다. 응답은 message 뒤에 줄바꿈 한 개가 붙은 UTF-8입니다.

다운로드·검증 단계가 끝나기 전에 기존 파일을 비우거나 덮어쓰지 않습니다. 특히 셸 리다이렉션으로 검증 전부터 index.html을 열지 않습니다. 읽기·검증 실패 시 두 파일의 내용이 모두 이전 상태여야 합니다. OS 중단·디스크 고장·동시 실행에 대한 두 파일 간 완전한 트랜잭션 복구는 이 문제의 평가 범위에 포함하지 않습니다.

## 9. 보충: Association과 CloudWatch 출력의 구분

State Manager Association은 주기 배포·목표 VersionId 유지에 사용하고, 채점용 Run Command는 CloudWatch 출력 옵션을 명시해 실행합니다. association을 만들었다는 사실만으로 모든 stdout이 지정 로그 그룹에 자동 수집된다고 가정하지 않습니다.

| 실행 경로 | 확인할 증거 |
| --- | --- |
| Association v1·v2·rollback | 연결 매개변수, 대상 두 노드, 실행 이력, 실제 두 파일·HTTP 응답 |
| Run Command 성공·실패 | 같은 config-deploy·같은 VersionId, CloudWatchOutputEnabled=true, 지정 로그 그룹 |
| 실패 경보 | 로그 필터 생성 후 invalid 버전 실행, 실제 CONFIG_DEPLOY_FAILED 이벤트와 ALARM 이력 |

로그 그룹 /config-lab/commands는 먼저 생성하고 retention 14일을 지정합니다. Run Command에서 CloudWatch 출력 사용을 체크하고 이 그룹을 선택합니다. CLI의 정확한 옵션은 --cloud-watch-output-config입니다. Association의 스케줄 시험과 로그 수집 시험은 같은 Document를 사용하되 각각의 설정·증거를 보관합니다.

| Metric filter 항목 | 설정 |
| --- | --- |
| 필터 패턴 | "CONFIG_DEPLOY_FAILED" 문자열 검색 |
| namespace | ConfigLab |
| metric name | DeployFailures |
| metric value | 1 |
| 경보 | config-deploy-failed |
| metric / statistic | ConfigLab의 DeployFailures / Sum |
| period / evaluation / threshold | 60초 / 1회 / 1 이상 |
| missing data | notBreaching |

Task Role이 아니라 EC2 instance role에 로그 권한을 줍니다. 그룹은 미리 생성하므로 CreateLogGroup 전체 권한을 줄 필요가 없습니다. 로그 스트림 생성·전송과 Agent가 사용하는 조회 권한을 지정 그룹 범위에 맞춰 준비합니다. 읽기·검증 실패 때는 Document가 CONFIG_DEPLOY_FAILED를 출력하고 nonzero로 끝나야 필터와 SSM 실패 상태를 함께 확인할 수 있습니다.

## 10. 보충: 실패·복구 시험의 정확한 판정

| 순서 | 입력·조작 | 두 노드의 기대 결과 |
| --- | --- | --- |
| 1 | Association에 v1 실제 VersionId 설정 후 즉시 실행 | Success, Welcome v1, 정보 파일 v1 |
| 2 | Association을 v2로 변경 후 즉시 실행 | Success, Welcome v2, 정보 파일 v2 |
| 3 | v2 상태의 두 파일 SHA-256 저장 | 비교 기준 확보 |
| 4 | invalid VersionId로 실행 | Failed, 두 파일의 hash·내용 모두 v2 그대로 |
| 5 | CloudWatch 출력 켠 Run Command로 invalid 실행 | Failed, 실패 로그와 경보 ALARM |
| 6 | 존재하지 않는 VersionId로 실행 | Failed, 두 파일 보존. 접근 오류도 성공으로 처리하지 않음 |
| 7 | Association을 v1으로 수정 후 즉시 실행 | latest가 invalid여도 Welcome v1로 복원 |
| 8 | 같은 v1 재실행 | Success, 두 파일 내용 동일. 문구 중복 없음 |

성공·실패는 상위 명령의 상태만 보지 말고 두 대상 노드별 응답 코드와 실행 결과를 확인합니다. 하나만 성공하면 두 노드 배포 성공으로 인정하지 않습니다. 두 노드에서 v1 적용이 끝난 후 최종 Association VersionId도 v1인지 확인합니다.

실패 판정 증거에는 시험 직전·직후 index.html과 deployment.json의 SHA-256, 실제 VersionId와 message를 포함합니다. idempotency 확인은 파일 수정 시각이 아니라 내용·hash를 비교합니다. 30분 주기 실행이 invalid 시험을 정상 버전으로 되돌려 증거를 가리지 않도록 시험 시작 시각과 Association의 현재 매개변수를 확인합니다.

## 11. 보충: 시간 배분과 제출물

| 권장 시간 | 작업 |
| --- | --- |
| 0~45분 | 두 서버·nginx·SSM Online·버킷 |
| 45~120분 | Document·검증·안전한 파일 교체 |
| 120~165분 | Association·v1/v2 변경 |
| 165~215분 | invalid·없는 버전·rollback·로그·경보 |
| 215~240분 | 재실행 확인·증거와 권한 정리 |

50점 배점은 기존 표를 유지합니다. 실패를 출력했더라도 현재 페이지나 배포 정보가 바뀌면 ‘실패 보존’ 점수를 인정하지 않습니다. v1/v2 문자열을 코드에 고정해 출력하는 방식도 실제 버전 읽기 점수를 인정하지 않습니다.

제출물은 Document JSON/YAML, 역할의 신뢰·권한 정책, 버전 목록, Association 설정·실행 이력, 노드별 HTTP·배포 정보·hash, CloudWatch 실패 로그·경보 전이입니다. 배포 정보에 VersionId가 빠지면 화면 문구만으로 복구 성공을 판정하지 않습니다.

## 보충 참고

Run Command의 CloudWatch 로그 설정: https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-rc-setting-up-cwlogs.html

CLI send-command: https://docs.aws.amazon.com/cli/latest/reference/ssm/send-command.html
