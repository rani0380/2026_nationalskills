# 2026 지방대회 제1과제 | 풀이 해설서

WorldPay 사용자 관리 시스템 / Solution architecture
실제 시행과제·공식 50점 채점기준 기준 / 2026-11-26

## 이 해설서의 목적
어제 학습한 제1과제의 정답 구성을 구축 순서대로 설명합니다. 콘솔에서 무엇을 만들고 어디에 연결해야 하는지, 그 설정이 왜 필요한지, 실패하면 어디부터 확인해야 하는지를 함께 정리했습니다. 실습 계정의 어제 실행 로그를 재현한 보고서가 아니라, 제공된 실제 시행자료에 맞춘 풀이입니다.

## 함께 사용할 자료
학생용 학습자료는 개념 설명과 연습 문제, 전체 리소스 작업표는 콘솔 입력값을 확인하는 데 사용합니다. 이 해설서는 그 설정들을 하나의 시스템으로 연결하는 순서와 검증을 설명합니다. 바이너리 파일은 이 해설서의 준비물에 포함하지 않습니다. 실제 앱이 실행되는 환경에서만 API·앱 로그의 실동작을 확인합니다.

## 차례
1. 전체 구조와 작업 순서 / 2. VPC·인터넷 경로·Peering
3. 보안 그룹·NACL / 4. Endpoint·Flow Logs·Bastion
5. IAM·KMS / 6. Aurora·스키마·Secret
7. ALB·시작 템플릿·ASG / 8. 로그·대시보드
9. 최종 검증 / 10. 오류 해결·공식 채점기준

## 고정값과 예시 구별
리소스 이름·CIDR·포트·공식 배점은 실제 시행자료를 따릅니다. SG 이름, IAM 역할 이름, KMS 별칭, 시작 템플릿·대상 그룹 이름, NAT 개수와 ASG 최대 용량은 이 해설서의 예시입니다. 공식 DB VPC 이름은 world-db-vpc이며 worldpay-db-vpc로 바꾸지 않습니다.

# 1. 전체 구조와 풀이 순서

![WorldPay 정답 구성의 요청 흐름](worksheets/images/worldpay-architecture.png)

## 정답 구성의 핵심
사용자는 HTTP 80으로 ALB에 접근합니다. ALB는 허용 API만 앱 EC2의 8080으로 전달합니다. 앱은 별도 VPC에 있는 Aurora의 3307로 접속합니다. DB 접속정보는 CMK로 암호화한 worldpay-secret에서 읽습니다. 앱의 Secret 조회는 Interface Endpoint의 PrivateLink 경로를 사용합니다.

## 이 순서로 풀면 되돌리는 작업이 줄어듭니다
VPC·서브넷·라우팅 → SG·NACL·Peering·Endpoint → 역할·KMS → DB → 스키마·앱 계정 → Secret → 앱 환경 → ALB → ASG → 로그·대시보드 → 최종 검증.
DB 생성은 시간이 걸리므로 네트워크와 키가 준비되면 먼저 시작합니다. 앱 실행에 필요한 DB와 Secret을 나중에 준비하면 인스턴스가 먼저 실행되어 시작 실패가 반복될 수 있습니다. ASG를 최소 2대로 유지하면서 앱 설정을 검증하고, 이후 새 템플릿 버전으로 재현성을 확인합니다.

# 2. VPC와 서브넷을 정확히 만드는 이유

## 콘솔 경로와 생성값
VPC → 내 VPC → VPC 생성 → VPC만. 앱·DB VPC를 각각 만들고 DNS 확인과 DNS 호스트 이름을 활성화합니다. 서브넷 생성 시에는 Name뿐 아니라 선택한 VPC와 가용 영역을 대조합니다.

| 구분 / 이름 | VPC·AZ | CIDR / 라우팅 테이블 |
| --- | --- | --- |
| worldpay-pub-subnet-a | 앱·2a | 10.0.0.0/24 / worldpay-pub-rt |
| worldpay-pub-subnet-c | 앱·2c | 10.0.1.0/24 / worldpay-pub-rt |
| worldpay-app-subnet-a | 앱·2a | 10.0.10.0/24 / worldpay-app-rt-a |
| worldpay-app-subnet-c | 앱·2c | 10.0.11.0/24 / worldpay-app-rt-c |
| worldpay-db-subnet-a | DB·2a | 10.100.0.0/24 / worldpay-db-rt |
| worldpay-db-subnet-c | DB·2c | 10.100.1.0/24 / worldpay-db-rt |
앱 VPC는 10.0.0.0/16, DB VPC는 10.100.0.0/16입니다. 2a·2c는 각각 ap-northeast-2a·ap-northeast-2c입니다.

## 해설
Public은 인터넷 입구·NAT·Bastion, App은 비공개 처리 계층, DB는 별도 저장 계층입니다. 이름에 private를 붙이는 것만으로 비공개가 되지 않습니다. 라우팅·공인 IP·SG를 함께 확인해야 합니다. 여러 AZ를 사용하는 이유는 한 AZ에만 모든 처리가 몰리는 구성을 피하기 위해서입니다.

## 정상 확인
서브넷 상세에서 VPC ID·AZ·CIDR을 읽고 표와 비교합니다. 라우팅 테이블의 서브넷 연결 탭에서 각 서브넷이 명시적으로 연결되었는지 확인합니다. 경로만 추가하고 연결을 생략하는 실수가 자주 발생합니다.

# 3. IGW·NAT·Peering의 역할 구분

![목적지별 네트워크 경로](worksheets/images/worldpay-routes.png)

## 인터넷 경로
IGW를 앱 VPC에 연결합니다. Public 테이블의 0.0.0.0/0은 IGW로, App a/c의 0.0.0.0/0은 NAT로 연결합니다. 이 해설의 가용성 예시는 AZ별 NAT 2개이며 공식 고정 개수는 아닙니다. NAT는 Public 서브넷에 배치하고 Elastic IP를 연결합니다.

## VPC 간 경로
worldpay-vpc-peering 생성 → 요청 수락 → Active 확인 → 양방향 원격 DNS 확인 활성화. App 테이블 두 개에는 10.100.0.0/16 → Peering, DB 테이블에는 10.0.0.0/16 → Peering을 추가합니다. DB에는 인터넷 기본 경로를 만들지 않습니다.

## 해설과 검증
DB 목적지는 더 구체적인 DB CIDR 경로가 선택되므로 NAT를 거치지 않습니다. Peering만 생성하고 라우팅을 생략하면 연결되지 않습니다. DB에 요청이 도착하더라도 DB의 앱 방향 응답 경로가 없으면 통신이 완성되지 않습니다. Public→DB 직접 접속은 이 풀이에서 사용하지 않고, DB 초기화는 App EC2의 Session Manager에서 진행합니다.

# 4. 보안 그룹 | 인바운드 정답표

## EC2 → 보안 그룹: 이름은 학습용 예시
| 그룹 이름 | VPC | 실제 연결 대상 |
| --- | --- | --- |
| worldpay-alb-sg | 앱 | worldpay-alb |
| worldpay-app-sg | 앱 | ASG 시작 템플릿·앱 EC2 |
| worldpay-db-sg | DB | worldpay-rds의 DB 인스턴스 |
| worldpay-endpoint-sg | 앱 | Secrets Manager Interface Endpoint |
| worldpay-bastion-sg | 앱 | worldpay-bastion |

## 인바운드 규칙 편집 → 규칙 추가 → 규칙 저장
| 선택할 SG | 유형 / 프로토콜 | 포트 | 소스(Source)에 입력 |
| --- | --- | --- | --- |
| ALB SG | HTTP / TCP | 80 | 0.0.0.0/0 |
| App SG | 사용자 지정 TCP | 8080 | ALB SG의 실제 sg-... ID 선택 |
| DB SG | 사용자 지정 TCP | 3307 | 10.0.10.0/24 |
| DB SG | 사용자 지정 TCP | 3307 | 10.0.11.0/24 |
| Endpoint SG | HTTPS / TCP | 443 | App SG의 실제 sg-... ID 선택 |
| Bastion SG | SSH / TCP | 22 | 내 공인 IP/32. SSH 사용 시만 추가 |
Session Manager만 사용하면 Bastion·앱에 22 인바운드는 필요하지 않습니다. 이 표에는 Bastion→앱 SSH 연결을 넣지 않았습니다. 앱의 8080을 인터넷 전체에 열지 않습니다. DB 포트는 기본 MySQL 3306이 아닌 3307입니다.

## 소스로 SG를 선택하는 방법
소스 종류 사용자 지정(Custom) → 값 입력칸에서 보안 그룹 이름 또는 실제 sg-... ID 검색 → 목록의 항목 클릭. 그룹 ID와 VPC가 맞는지 확인합니다. 이름을 CIDR처럼 직접 입력해서 끝내지 않습니다.
규칙을 만들었어도 리소스에 그 SG가 연결되어 있지 않으면 적용되지 않습니다.

# 5. 보안 그룹 | 아웃바운드 정답표

## 아웃바운드 규칙 편집: 기본 전체 허용을 아래 규칙으로 교체
표의 대상은 Destination입니다. App의 DB 목적지는 DB CIDR이며, ALB의 앱 목적지는 App SG입니다. 아래 이름 약칭은 앞 페이지의 SG와 같습니다.
| 선택할 SG | 유형 / 프로토콜 | 포트 | 대상(Destination)에 입력 |
| --- | --- | --- | --- |
| ALB SG | 사용자 지정 TCP | 8080 | App SG의 실제 sg-... ID |
| App SG | 사용자 지정 TCP | 3307 | 10.100.0.0/24 |
| App SG | 사용자 지정 TCP | 3307 | 10.100.1.0/24 |
| App SG | HTTPS / TCP | 443 | 0.0.0.0/0 |
| App SG | HTTP / TCP | 80 | 0.0.0.0/0 |
| DB SG | 신규 규칙 없음 | - | 기본 전체 허용 제거 |
| Endpoint SG | 신규 규칙 없음 | - | 기본 전체 허용 제거 |
| Bastion SG | HTTPS / TCP | 443 | 0.0.0.0/0 |
| Bastion SG | HTTP / TCP | 80 | 0.0.0.0/0 |

## 이 표를 적용하는 조건
80/443 외부 허용은 공식 지문에서 허용한 실습용 구성입니다. App의 443 전체 대상에는 Endpoint의 사설 IP도 포함됩니다. 실제 통신은 Private DNS·NAT·Endpoint 경로에 따라 이동합니다.
DB·Endpoint는 이 구성에서 새 연결을 시작하지 않습니다. 허용된 인바운드 연결에 대한 응답은 SG가 자동 허용하므로 응답용 아웃바운드 포트를 추가하지 않습니다. 별도의 신규 통신이 생기면 그 목적을 확인해 추가 설계합니다.
SG에는 응답용 임시 포트 1024-65535를 넣지 않습니다. DB NACL에는 별도로 필요합니다. 여러 SG가 연결되면 허용 규칙이 합쳐지므로 다른 SG에 남은 전체 허용도 확인합니다.

## 학생 점검
[ ] 기본 전체 트래픽 삭제  [ ] ALB 아웃바운드 8080
[ ] App→DB 3307 두 CIDR  [ ] SG 연결·VPC 확인

# 6. DB NACL은 요청과 응답을 각각 허용

![DB NACL 요청과 응답 포트](worksheets/images/worldpay-nacl.png)

## 콘솔 설정
VPC → 네트워크 ACL 생성 → worldpay-db-nacl / DB VPC. DB a/c에 연결합니다. 인바운드 TCP 3307을 앱 a·c CIDR에서 각각 허용하고, 아웃바운드 TCP 1024-65535를 같은 앱 CIDR로 각각 허용합니다. 기본 * 거부는 유지하고 인터넷 전체 허용을 넣지 않습니다.

## 왜 아웃바운드는 3307이 아닌가요?
앱이 임시 포트 45000에서 DB의 3307로 연결했다면 응답은 DB 3307에서 앱 45000으로 돌아갑니다. NACL 아웃바운드가 판단하는 목적지 포트는 45000입니다. 반면 SG는 연결 상태를 기억하므로 허용된 DB 요청의 응답을 위해 임시 포트 규칙을 따로 만들지 않습니다.

## 실패 원인 좁히기
App a는 성공하고 c만 실패하면 App c의 라우팅·DB SG·NACL에 c CIDR이 빠졌는지 확인합니다. 두 AZ 모두 시간 초과라면 Peering 경로와 NACL 응답 규칙을 먼저 봅니다. 낮은 번호의 DENY가 먼저 적용되고 있지 않은지도 확인합니다.

# 7. PrivateLink·Flow Logs·Bastion

## Secret은 내부 HTTPS 경로로 조회
VPC → 엔드포인트 생성에서 com.amazonaws.ap-northeast-2.secretsmanager / Interface를 선택합니다. 앱 VPC, App a/c, Private DNS 활성, Endpoint SG를 지정합니다. Endpoint SG 인바운드 443의 소스는 App SG입니다.
App EC2에서 Secrets Manager 이름을 조회했을 때 Endpoint ENI의 사설 IP로 해석되는지 확인합니다. 단순 조회 성공만으로 내부 경로 사용을 증명할 수 없습니다. NAT를 통해서도 API 호출이 성공할 수 있기 때문입니다.

## Flow Logs는 앱 로그와 다릅니다
두 VPC 각각 Flow Logs를 활성화합니다. CloudWatch Logs 목적지와 전달 역할을 준비하고 상태를 확인합니다. 예시 목적지 /worldpay/vpc-flow는 네트워크 허용·거부 기록용입니다. 앱 이벤트를 수집하는 worldpay-log-group과 혼동하지 않습니다.

## 채점용 Bastion
worldpay-bastion / AL2023 / t3.micro / Public a로 생성합니다. SSH를 사용하면 키·공인 주소·내 IP/32의 22 인바운드를 준비합니다. SSM만 사용하면 22 인바운드는 필요하지 않지만 에이전트·역할·443 서비스 경로가 필요합니다. 공식 지문은 채점용 관리자 수준 권한을 요구합니다. 앱 역할에 같은 권한을 복사하지 않습니다.
```sh
aws configure set region ap-northeast-2
aws sts get-caller-identity
aws --version
curl --version
```
계정·리전·도구를 확인한 뒤 채점합니다. 임시 관리자 권한은 평가 종료 후 회수합니다.

# 8. 앱 IAM 역할과 KMS의 연결

## 역할은 실제 앱 EC2에 연결되어야 합니다
IAM → 역할 생성 → AWS 서비스 EC2 신뢰 → 앱 역할 생성. 시작 템플릿의 IAM 인스턴스 프로파일로 지정합니다. 역할에 정책을 붙여도 인스턴스에 연결하지 않으면 앱은 그 권한을 받지 못합니다.
아래는 Secret 읽기 권한 예시입니다. SECRET_ARN과 KEY_ARN을 콘솔에서 복사한 실제 ARN으로 바꿉니다. Secret ARN 접미사도 포함합니다.
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "SECRET_ARN"
    },
    {
      "Effect": "Allow",
      "Action": "kms:Decrypt",
      "Resource": "KEY_ARN"
    }
  ]
}
```
## 해설
CMK로 암호화한 Secret은 GetSecretValue뿐 아니라 kms:Decrypt도 필요합니다. KMS 키 정책에서 앱 역할의 사용도 허용되어야 합니다. Endpoint 정책 역시 필요한 Secret 조회를 막지 않아야 합니다. 로그 전송과 SSM 권한은 이 예시에 포함되지 않으므로 사용할 기능에 맞춰 별도로 연결합니다.

# 9. Aurora를 생성하고 접속 경로 확인

## 콘솔 설정값
RDS → 데이터베이스 생성 → 표준 생성 → Aurora MySQL 호환. 클러스터 worldpay-rds, 요구 엔진 aurora-mysql8.0, 클래스 db.t3.medium, 포트 3307을 지정합니다. DB VPC, DB a/c 서브넷 그룹, DB SG, Public No, KMS 저장소 암호화를 확인합니다.
클래스·엔진 조합이 현재 계정·리전에서 선택되지 않으면 임의 변경을 공식 정답으로 단정하지 말고 차이를 교사에게 확인합니다. Writer endpoint는 쓰기 요청의 연결 대상으로 사용합니다. DB 관리자는 초기화용이고 앱은 별도 계정을 씁니다.

## DB 연결을 네 단계로 나눕니다
| 단계 | 확인 방법 | 실패 시 우선 확인 |
| --- | --- | --- |
| DNS | getent hosts로 endpoint 조회 | 이름 오타·VPC DNS·Peering DNS |
| 연결 | mysql로 3307 접속 시도 | App outbound·DB inbound·경로·NACL |
| 인증 | 사용자·비밀번호로 로그인 | 계정·비밀번호·사용자 호스트 조건 |
| 스키마 | worldpay.users 조회 | DB·테이블·권한 |
```sh
getent hosts <writer-endpoint>
mysql -h <writer-endpoint> -P 3307 -u <관리자계정> -p
```
App EC2의 Session Manager에서 MySQL 호환 클라이언트를 사용합니다. 비밀번호는 명령 인자에 적지 않고 프롬프트에 입력합니다. 클라이언트 패키지는 실습 이미지에서 제공되는 호환 패키지를 사용합니다.

# 10. 데이터베이스·앱 사용자 생성 SQL

## 관리자 세션에서 초기화
아래는 학습용 app 계정 예시입니다. 비밀번호 자리는 본인만 아는 강한 값으로 바꿉니다. 실제 값은 배포 자료나 학습지에 기록하지 않습니다.
```sql
CREATE DATABASE IF NOT EXISTS worldpay;
CREATE TABLE IF NOT EXISTS worldpay.users (
  uid INT AUTO_INCREMENT,
  name VARCHAR(255),
  age INT,
  PRIMARY KEY (uid)
);
CREATE USER 'app'@'%' IDENTIFIED BY '<개인-비밀번호>';
GRANT SELECT, INSERT ON worldpay.users TO 'app'@'%';
SHOW GRANTS FOR 'app'@'%';
```
기존 app 사용자가 있다면 CREATE USER가 실패할 수 있습니다. 기존 계정과 권한을 확인하고 필요한 경우 수정합니다. '%'는 MySQL 사용자 호스트 패턴이며, DB가 인터넷에 공개된다는 의미는 아닙니다. 네트워크와 DB SG는 앱 서브넷으로 제한합니다.

## app 사용자로 재접속해 검증
```sql
INSERT INTO worldpay.users (name, age)
VALUES ('solution-check', 26);
SELECT uid, name, age FROM worldpay.users
WHERE name = 'solution-check';
```
uid는 자동 증가하므로 고정값 1을 기대하지 않습니다. SELECT·INSERT는 예시 앱 동작에 필요한 권한이며 앱이 추가 작업을 한다면 그 요구를 확인한 범위에서 권한을 조정합니다. 관리자 계정으로만 성공한 결과를 앱 계정 성공으로 판단하지 않습니다.

# 11. Secret을 만들고 앱 연결 조건 점검

## 콘솔 입력
Secrets Manager → 새 보안 암호 저장 → 기타 보안 암호 유형. worldpay-secret을 만들고 고객 관리형 KMS 키를 선택합니다. username은 app처럼 admin이 아닌 실제 DB 계정, password는 그 계정의 비밀번호, host는 Writer endpoint입니다.
원문은 JSON 예시가 실제 내용과 다를 수 있다고 명시합니다. DB 이름 worldpay와 포트 3307을 전달하는 필드·환경변수는 실제 앱 설정 방식에 맞춥니다. 확인되지 않은 port/dbname 필드를 임의 정답으로 고정하지 않습니다.

## 값 노출 없이 읽기 권한 확인
App EC2에서 아래 명령은 Secret 전체를 화면에 출력하지 않고 성공 메시지만 표시합니다. 두 번째 명령이 성공해야 GetSecretValue·KMS 복호화 경로를 확인한 것입니다.
```sh
aws secretsmanager describe-secret --secret-id worldpay-secret
aws secretsmanager get-secret-value --secret-id worldpay-secret \
  --query 'ARN' --output text >/dev/null && echo SECRET_READ_OK
```
describe-secret은 메타데이터 확인이며 값 읽기 성공을 대신하지 않습니다. 위 명령의 실패는 숨기지 않고 오류 내용을 확인합니다. 터미널 디버깅으로 응답 전체를 출력하거나 파일에 남기지 않습니다.

## 앱 실행 환경 확인
AL2023 x86 환경에서 앱이 8080을 리슨하고, Secret을 읽어 worldpay.users에 연결하며 재부팅 후에도 시작되도록 구성합니다. 앱 실행 명령·로그 경로는 실제 실습 환경 설정을 사용합니다. 이 해설은 바이너리 다운로드·대체 프로그램을 요구하지 않습니다.

# 12. ALB 규칙의 정답과 해석

![ALB의 허용 API와 기본 403](worksheets/images/worldpay-alb-rules.png)

## 생성 순서
대상 그룹: Instance / 앱 VPC / HTTP 8080 / 상태 검사 /health. ALB: worldpay-alb / Internet-facing / Public a·c / ALB SG / HTTP 80. 리스너 기본 동작을 고정 응답 403으로 지정합니다.
추가 규칙 10은 경로 /v1/users와 메서드 GET 또는 POST, 규칙 20은 /health와 GET을 대상 그룹으로 전달합니다. 우선순위 숫자는 예시입니다. 다른 조건 종류는 AND, 같은 조건의 여러 값은 OR로 해석합니다.

## 왜 기본 전달이 아닌가요?
없는 API는 앱에 전달되면 안 됩니다. 앱이 반환한 404와 ALB 고정 응답 403은 결과가 다릅니다. /* 또는 /v1/*로 넓게 전달하지 않습니다. /v1/users?uid=3의 쿼리 문자열은 경로 /v1/users와 별개이므로 경로 조건을 바꿀 필요가 없습니다. 루트 /는 허용 API가 아니므로 403이 정상입니다.

# 13. 시작 템플릿·ASG로 자동 재현

## 시작 템플릿
예시 worldpay-app-lt에 AL2023 x86_64 / t3.micro / App SG / 앱 IAM 프로파일을 지정합니다. 앱 공인 IP는 부여하지 않고, 서브넷은 ASG에서 App a·c를 선택합니다. 서비스 자동 시작·로그 수집 설정이 새 인스턴스에도 적용되도록 준비합니다.
사용자 데이터나 이미지에 DB 비밀번호를 고정하지 않습니다. 앱은 실행 시 Secret을 읽습니다. 한 대에서 수동으로 고친 설정은 템플릿이나 이미지에도 반영해야 새 인스턴스에서 재현됩니다.

## ASG 설정
| 입력칸 | 설정값 | 이유 |
| --- | --- | --- |
| 이름 | worldpay-asg | 공식 명칭 |
| 서브넷 | App a·c | 두 AZ에 배치 |
| 최소 / 원하는 / 최대 | 2 / 2 / 4 예시 | 최소 2 공식 조건 / 최대 여유 필요 |
| Name 태그 | worldpay-app, 전파 체크 | 새 EC2의 공식 Name 태그 |
| 대상 그룹 | 앞의 App 대상 그룹 | 새 인스턴스 자동 등록 |
| 대상 추적 정책 | ASG 평균 CPU 70% | CPU 사용 증가 시 확장 |
| 시작 템플릿 버전 | 검증한 명시적 버전 | 이전 버전 오사용 방지 |

## 검증을 구별하기
원하는 용량을 3으로 바꿔 새 인스턴스가 자동 실행·Healthy로 전환되는지 확인한 뒤 2로 복귀할 수 있습니다. 이 검증은 CPU 부하에 따른 자동 확장 검증을 대신하지 않습니다. 최소=최대=2로 설정하면 확장할 수 없습니다.

# 14. 앱 로그 수집 설정 예시

## 로그 그룹과 에이전트 준비
CloudWatch에서 worldpay-log-group을 만들고 보존을 30일로 설정합니다. 아래 /var/log/worldpay/app.log는 예시이므로 실제 앱 로그 파일로 바꿉니다. Agent가 읽을 권한과 앱 역할의 로그 전송 권한을 확인합니다.
```sh
sudo yum install -y amazon-cloudwatch-agent
```
아래 JSON을 예시 /tmp/worldpay-cw.json으로 저장합니다.
```json
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [{
          "file_path": "/var/log/worldpay/app.log",
          "log_group_name": "worldpay-log-group",
          "log_stream_name": "{instance_id}"
        }]
      }
    }
  }
}
```
```sh
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s -c file:/tmp/worldpay-cw.json
```
실제 API 요청 후 5분 이내에 해당 인스턴스 스트림에 앱 로그가 나타나는지 확인합니다. 파일이 없거나 Agent 설정을 적용하지 않았다면 설치만 성공해도 로그는 전송되지 않습니다. ASG의 새 인스턴스에도 설정이 필요합니다.

# 15. 대시보드는 정확한 차원을 선택

## 대시보드 생성
CloudWatch → 대시보드 → worldpay-dashboard 생성. 아래 두 위젯을 추가합니다. 지표가 비어 있으면 리전·시간 범위·모니터링 설정·실제 요청 유무를 확인합니다.
| 위젯 | 선택할 지표·차원 | 통계 예시·검증 |
| --- | --- | --- |
| ALB 고정 응답 | AWS/ApplicationELB / HTTP_Fixed_Response_Count / 실제 ALB | Sum / 없는 API 403 요청 후 증가 확인 |
| ASG 평균 CPU | AWS/EC2 / CPUUtilization / AutoScalingGroupName=worldpay-asg | Average / 그룹 평균인지 확인 |

## 지표를 읽는 방법
ALB 지표는 고정 응답을 몇 번 반환했는지 보여줍니다. HTTPCode_Target_4XX_Count처럼 앱에서 발생한 오류 지표를 대신 선택하면 요구 지표가 아닙니다. CPU는 특정 InstanceId 하나만 선택하지 말고 ASG 차원을 선택합니다. 그룹 지표를 사용할 수 있도록 인스턴스 모니터링·지표 가용 여부를 확인합니다.

## 로그와 지표 연결
없는 API 요청은 ALB에서 끝나므로 그 요청이 앱 로그에 나타나지 않아도 이상하지 않습니다. 앱 로그 수집은 정상 API 요청으로 별도 검증합니다. Flow Logs는 통신 기록, 앱 로그는 프로그램 이벤트, 대시보드는 수치 지표입니다. 세 가지가 각각 생성되었는지 확인합니다.

## 기록할 증거
요청 시각, 로그 이벤트 시각, 보존 기간 화면, ALB 지표 이름·차원, CPU 지표 이름·차원을 기록합니다. 비밀번호·Secret 전체 값은 증거 화면에 포함하지 않습니다.

# 16. 최종 API 검증과 기대 결과

앱이 실행 중인 환경에서 Bastion 또는 접속 가능한 터미널로 확인합니다. ALB_ENDPOINT에는 http://를 제외한 본인 ALB DNS를 입력합니다. POST는 실습 DB에 데이터를 생성합니다.
```sh
ALB_ENDPOINT='<본인-ALB-DNS>'
curl -i "http://$ALB_ENDPOINT/health"
curl -sS "http://$ALB_ENDPOINT/v1/users" \
  -H 'Content-Type: application/json' \
  -d '{"name":"solution-check","age":26}'
```
POST 응답 {"uid":3}은 예시입니다. 실제 받은 uid로 다음의 3을 바꿉니다.
```sh
curl -i "http://$ALB_ENDPOINT/v1/users?uid=3"
curl -sS -o /dev/null -w '%{http_code}\n' \
  "http://$ALB_ENDPOINT/v1/users123"
```
| 확인 항목 | 정상 기대값 | 실패 시 먼저 볼 곳 |
| --- | --- | --- |
| /health | 상태 OK JSON | 앱 실행·대상 상태·8080 SG |
| POST /v1/users | 새 uid | DB 연결·계정 권한·스키마 |
| GET /v1/users?uid=실제값 | 저장한 name·age | 실제 uid·DB 데이터 |
| 없는 API | HTTP 403 | ALB 기본 동작·허용 규칙 범위 |
| 새 ASG 인스턴스 | 자동 시작·Healthy | 템플릿 버전·역할·서비스 설정 |
앱 미연동 상태에서는 네트워크·권한 등 설정 검증과 API 동작 검증을 구분해 기록합니다. 이 해설서 제작 과정에서 학생 AWS 계정의 실동작 검증을 수행한 것은 아닙니다.

# 17. 오류 해결 | 증상에서 원인으로 좁히기

| 증상 | 먼저 확인 | 다음 확인 |
| --- | --- | --- |
| ALB 접근 자체 실패 | DNS·Internet-facing·ALB SG 80 | Public IGW 경로·서브넷 |
| 대상 Unhealthy | 앱 8080·로컬 /health | ALB outbound·App inbound·상태 검사 |
| DB 연결 시간 초과 | Peering 양쪽 경로·SG 3307 | NACL 요청·응답·DNS |
| DB Access denied | app 계정·비밀번호·호스트 조건 | Secret 값 일치·권한 |
| 테이블 없음 | worldpay.users 생성 | 실제 접속 DB·계정 |
| Secret AccessDenied | GetSecretValue·kms:Decrypt | 키 정책·Endpoint 정책 |
| Secret 연결 시간 초과 | Endpoint SG 443·Private DNS | App outbound·Endpoint 상태 |
| 앱 로그 없음 | 실제 파일·Agent 실행·설정 적용 | 역할·로그 그룹·전송 경로 |
| 새 인스턴스만 실패 | 템플릿 버전·자동 시작 | IAM 프로파일·설치 경로 |
| 없는 API가 404 | ALB가 넓은 경로를 전달했는지 | 기본 403·메서드 조건 |
| 정상 API가 403 | 허용 경로·메서드·우선순위 | 올바른 리스너 선택 여부 |
| 503 / 504 | 사용 가능한 대상 / 응답 지연 | 대상 그룹 연결 / 앱→DB 통신 |

## 수정은 한 단계씩 합니다
로컬 앱 → 대상 그룹 → ALB 정상 API → DB 생성·조회 → 비정상 API → 로그·지표 순서로 점검합니다. 원인을 모른 채 전체 공개 규칙을 추가하면 문제가 가려집니다. 시간 초과와 AccessDenied는 원인 후보를 좁히는 단서이며 단독으로 원인을 확정하지 않습니다.

# 18. 공식 채점기준과 마무리

| 영역 | 배점 | 주요 확인 |
| --- | --- | --- |
| VPC | 15.5 | VPC·CIDR·서브넷·라우팅·Peering·DNS·NACL·Flow Logs·Endpoint |
| ASG | 6.5 | 생성·용량·Name·타입·CPU 정책 |
| RDS | 7 | 생성·클래스·KMS·3307·비공개 |
| Secrets Manager | 4.5 | 생성·CMK·admin 미사용 |
| ALB | 4 | 생성·두 AZ·기본 규칙 |
| Application | 4.5 | 사용자 생성·조회·비정상 요청 |
| CloudWatch Logs | 4 | 그룹·30일·로그 전송 |
| CloudWatch | 4 | 대시보드·ALB 지표·평균 CPU |
| 합계 | 50 | 교사 최종 확인 |

## 채점 스크립트 해석
제공된 mark.sh는 확인 명령과 기대값을 사람이 비교하는 형태입니다. 실행 자체를 자동 합산 완료로 판단하지 않습니다. 일부 명령은 Secret 값을 출력하므로 전체 출력을 그대로 공개 제출하지 않습니다. 교사가 확인한 결과와 비밀정보 없는 증거만 기록합니다.

## 다시 설명할 수 있어야 할 내용
왜 ALB와 앱의 포트가 다른가? 왜 DB 응답에는 SG 임시 포트 규칙이 없지만 NACL에는 있는가? 왜 Secret 조회에 IAM과 KMS가 필요한가? 왜 한 대의 수동 수정만으로 ASG 구축을 완료할 수 없는가? 이 네 질문을 설명하면 풀이의 핵심을 이해한 것입니다.
평가 종료가 확정되면 생성한 유료 실습 리소스와 임시 권한을 정리합니다. 공유·기존 리소스와 구별하고 삭제 전 대상을 확인합니다.

# 참고 자료와 예시 적용 범위

## 원본 기준
사용자가 제공한 2026 지방대회 실제 시행과제 HWP·제1과제 채점기준 HWP·당일 제1과제 mark.sh를 기준으로 작성했습니다. 이전 요약자료의 skills-* 이름·일반 MySQL 3306·100점 예시는 이 풀이에 적용하지 않습니다.

## AWS 공식 문서
SG 규칙·참조: https://docs.aws.amazon.com/vpc/latest/userguide/security-group-rules.html
SG 상태 유지: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html
ALB SG: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-update-security-groups.html
Aurora 사용자 권한: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Security.html
Secret·KMS: https://docs.aws.amazon.com/secretsmanager/latest/userguide/security-encryption.html
CloudWatch Agent 설치: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/manual-installation.html
Agent 설정 적용: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/create-cloudwatch-agent-configuration-file.html

## 예시 코드 사용
JSON의 SECRET_ARN·KEY_ARN, 명령의 endpoint·uid·개인 비밀번호는 실습 계정의 값으로 바꿉니다. SG·IAM·템플릿 예시 이름은 기존 작업표와 일관되게 사용합니다. 실제 앱의 실행 명령이나 Secret 추가 필드는 확인된 환경에 맞게 적용합니다.
그림은 직접 제작한 수업용 개념도이며 실제 AWS 콘솔 화면 캡처가 아닙니다. 콘솔 메뉴 언어와 화면 배치는 업데이트에 따라 달라질 수 있으므로 서비스 이름과 입력 항목을 함께 확인합니다.
