# 2027 지방대회 대비 모의고사 6회 · 제2과제

| 항목 | 조건 |
| --- | --- |
| 과제명 | Versioned configuration deployment and rollback |
| 난이도 / 시간 / 배점 | 상 / 4시간 / 50점 |
| 리전 | 서울 ap-northeast-2 |
| 채점 | 교사 실기 평가 50점 |
| 출제 구분 | 자체 제작 연습문제. 제1과제와 독립적으로 응시 |

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
- 인스턴스 역할에는 AmazonSSMManagedInstanceCore와 지정 객체 버전 읽기 권한을 부여합니다. Command 출력은 CloudWatch Logs의 /config-lab/commands로 보내고 보관 14일로 설정합니다. 로그 스트림 생성·전송 권한을 해당 그룹으로 제한합니다.
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
