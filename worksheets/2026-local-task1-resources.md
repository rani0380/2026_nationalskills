# 작업표 1 | 기준과 네트워크 리소스

2026 지방대회 제1과제 WorldPay | 콘솔 작업용 리소스 총정리
이름 __________  비번호 __________  작업일 __________
공식 이름·CIDR·포트는 그대로 사용합니다. ‘예시’ 이름과 수량은 이 학습자료에서 정한 구성입니다. 기존 운영 리소스를 변경하지 않고 실습 전용으로 생성합니다. 모든 표의 리전은 별도 표기가 없으면 서울(ap-northeast-2)입니다.

## 생성 순서
VPC·서브넷 → IGW·NAT·라우팅·피어링 → SG·NACL·Endpoint·Flow Logs → IAM·KMS → DB·Secret → 앱 실행 환경 → ALB·ASG → 로그·대시보드 → 검증.
SG는 먼저 모두 만든 뒤 서로 참조하는 규칙을 입력합니다. 앱 DB 초기화는 ASG 앱 EC2의 Session Manager에서 수행하는 구성을 기준으로 합니다.

| 콘솔 / 리소스 | 이름·수량 | 입력값 / 연결 대상 |
| --- | --- | --- |
| VPC / 앱 VPC | worldpay-app-vpc / 1개 | IPv4 10.0.0.0/16, DNS 확인·호스트 이름 활성 |
| VPC / DB VPC | world-db-vpc / 1개 | IPv4 10.100.0.0/16, DNS 확인·호스트 이름 활성 |
| VPC / IGW | worldpay-igw / 예시 1개 | 앱 VPC에 연결. DB VPC에는 연결하지 않음 |
| EC2 / Elastic IP | NAT용 / 예시 2개 | Public NAT마다 1개. 자동 생성 ID 기록 |
| VPC / NAT Gateway | worldpay-nat-a, -c / 예시 각 1개 | Public a/c에 각각 생성, Public 유형, EIP 연결 |
| VPC / Peering | worldpay-vpc-peering / 1개 | 요청자 앱 VPC, 수락자 DB VPC, Active, DNS 양방향 |
NAT를 AZ별 2개 사용하는 것은 이 작업표의 가용성 예시입니다. 공식 지문은 개수를 고정하지 않습니다. NAT는 SG를 연결하는 리소스가 아닙니다.

## 완료 기록
앱 VPC ID __________ / DB VPC ID __________ / IGW ID __________
NAT a/c ID ____________________ / Peering ID ________________

# 작업표 2 | 서브넷·라우팅 연결 전체

## VPC → 서브넷 생성: 아래 이름과 AZ·CIDR 입력
| 서브넷 이름 | VPC / AZ | CIDR / 연결할 라우팅 테이블 |
| --- | --- | --- |
| worldpay-pub-subnet-a | 앱 / ap-northeast-2a | 10.0.0.0/24 / worldpay-pub-rt |
| worldpay-pub-subnet-c | 앱 / ap-northeast-2c | 10.0.1.0/24 / worldpay-pub-rt |
| worldpay-app-subnet-a | 앱 / ap-northeast-2a | 10.0.10.0/24 / worldpay-app-rt-a |
| worldpay-app-subnet-c | 앱 / ap-northeast-2c | 10.0.11.0/24 / worldpay-app-rt-c |
| worldpay-db-subnet-a | DB / ap-northeast-2a | 10.100.0.0/24 / worldpay-db-rt |
| worldpay-db-subnet-c | DB / ap-northeast-2c | 10.100.1.0/24 / worldpay-db-rt |

## VPC → 라우팅 테이블 → 경로 편집: 기본 local 경로는 유지
| 라우팅 테이블 | 목적지 CIDR | 대상 / 저장 후 확인 |
| --- | --- | --- |
| worldpay-pub-rt | 0.0.0.0/0 | 앱 IGW / Public a·c 명시적 연결 |
| worldpay-app-rt-a | 0.0.0.0/0 | NAT a / App a 명시적 연결 |
| worldpay-app-rt-a | 10.100.0.0/16 | worldpay-vpc-peering |
| worldpay-app-rt-c | 0.0.0.0/0 | NAT c / App c 명시적 연결 |
| worldpay-app-rt-c | 10.100.0.0/16 | worldpay-vpc-peering |
| worldpay-db-rt | 10.0.0.0/16 | worldpay-vpc-peering / DB a·c 명시적 연결 |
앱은 인터넷에 NAT로, DB에는 Peering으로 접근합니다. DB는 앱 CIDR의 Peering 경로만 추가하고 인터넷 기본 경로를 만들지 않습니다. Public 테이블의 DB 경로는 이 구성에서 필요하지 않습니다.

## 두 탭을 모두 확인
[ ] 경로(Routes) 저장  [ ] 서브넷 연결(Subnet associations) 저장
[ ] Peering DNS 양방향  [ ] DB 인터넷 기본 경로 없음

# 작업표 3 | 보안 그룹 생성·인바운드

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

# 작업표 4 | 보안 그룹 아웃바운드

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

# 작업표 5 | NACL·Endpoint·Flow Logs

## DB NACL: worldpay-db-nacl / DB VPC / DB a·c 연결
| 방향 / 규칙 번호 | 유형·포트 | 소스 또는 목적지 / 작업 |
| --- | --- | --- |
| 인바운드 100 | 사용자 지정 TCP / 3307 | 소스 10.0.10.0/24 / ALLOW |
| 인바운드 110 | 사용자 지정 TCP / 3307 | 소스 10.0.11.0/24 / ALLOW |
| 아웃바운드 100 | 사용자 지정 TCP / 1024-65535 | 목적지 10.0.10.0/24 / ALLOW |
| 아웃바운드 110 | 사용자 지정 TCP / 1024-65535 | 목적지 10.0.11.0/24 / ALLOW |
| 양방향 나머지 * | 모든 트래픽 | 기본 DENY 유지 / 0.0.0.0/0 허용 금지 |
규칙 번호는 예시입니다. 더 낮은 번호에 거부 규칙이 있으면 먼저 적용됩니다. App·Public NACL은 별도로 제한하지 않는 학습용 구성입니다. 제한한다면 해당 요청·응답도 설계해야 합니다.

| 리소스 / 콘솔 | 이름·유형 | 설정·연결 |
| --- | --- | --- |
| VPC Endpoint | worldpay-secrets-vpce / 예시 | Interface / 앱 VPC / App a·c / Endpoint SG |
| Endpoint 서비스 | com.amazonaws.ap-northeast-2.secretsmanager | Private DNS 활성 / Available |
| Endpoint 정책 | Secret 읽기 허용 범위 | App 역할의 필요한 Secret 접근 허용. IAM·KMS도 별도 허용 |
| VPC Flow Logs | 두 VPC 각각 활성 | 예시 ALL 트래픽 / CloudWatch Logs 목적지 |
| Flow Logs 로그 그룹 | /worldpay/vpc-flow / 예시 | 앱 로그와 구분 / 보존 30일은 학습용 예시 |
| Flow Logs IAM 역할 | worldpay-flow-role / 예시 | 신뢰 vpc-flow-logs.amazonaws.com, 해당 로그 그룹 기록 권한 |
Flow Logs 역할에는 로그 그룹·스트림 생성·기록과 필요한 조회 권한을 목적지에 맞게 설정합니다. 두 VPC의 Flow Logs 상태가 Active인지 확인합니다.

# 작업표 6 | KMS·RDS·Secret·스키마

| 리소스 / 입력칸 | 공식 값 또는 예시 | 설정·확인 |
| --- | --- | --- |
| KMS 고객 관리형 키 | alias/worldpay-key / 예시 | 대칭 암호화 키, Secret에 사용. 앱 역할 복호화 허용 |
| RDS 서브넷 그룹 | worldpay-db-subnets / 예시 | DB VPC / DB a·c 두 서브넷 |
| DB 클러스터 식별자 | worldpay-rds | Aurora MySQL 8.0 호환 |
| DB 인스턴스 클래스 | db.t3.medium | 선택 불가 조합이면 차이를 교사에게 기록·확인 |
| DB 연결 | 포트 3307 / Public No | DB 서브넷 그룹 / DB SG 연결 |
| DB 저장소 암호화 | KMS 활성 | 예시 위 고객 관리형 키. Secret과 같은 키 사용 가능 |
| DB 관리자 계정 | 학생 지정 | 초기 스키마·앱 계정 생성에만 사용 / 비밀번호 기록 금지 |
| DB 데이터베이스 | worldpay | 앱 계정에서 사용할 DB |
| DB 테이블 | worldpay.users | uid INT AUTO_INCREMENT PK, name VARCHAR(255), age INT |
| DB 앱 계정 | app / 예시 | admin 금지 / SELECT·INSERT 등 필요한 권한만 |
| Secrets Manager 이름 | worldpay-secret | 고객 관리형 KMS 키 선택 |
| Secret username | app / 예시 | 실제 생성한 DB 계정과 동일 |
| Secret password | 해당 앱 계정 비밀번호 | 공개 자료·캡처·시트에 포함하지 않기 |
| Secret host | 실제 Writer endpoint | 포트 포함 URL이 아닌 DB 호스트 이름 |
원문의 Secret JSON은 예시이며 실제 앱 설정과 다를 수 있습니다. 추가 포트·DB 이름 필드가 필요하면 앱 설정 방식에 맞춰 확인합니다. DB에서 자동 순환·특정 보조 인스턴스 개수 등 지문에 없는 값을 공식 필수라고 단정하지 않습니다.

## 실행·검증 위치
앱 EC2의 Session Manager → MySQL 클라이언트 → Writer endpoint:3307. DB·users·app 계정을 생성하고 앱 계정으로 재접속하여 INSERT·SELECT를 확인합니다. 바이너리 파일은 이 인프라 작업표의 준비물에 포함하지 않습니다.
Writer endpoint _____________________ / 키 ID ______________

# 작업표 7 | EC2·IAM·시작 템플릿

| 콘솔 / 리소스 | 이름·값 | 연결·권한·확인 |
| --- | --- | --- |
| IAM Bastion 역할 | worldpay-bastion-role / 예시 | 신뢰 EC2. 공식 지문대로 채점용 관리자 수준 권한, SSM 사용 시 접속 권한 |
| IAM 앱 역할 | worldpay-app-role / 예시 | 신뢰 EC2. 관리자 역할과 분리 |
| 앱 Secret 권한 | GetSecretValue | 실제 worldpay-secret ARN에 제한 |
| 앱 KMS 권한 | kms:Decrypt | 해당 CMK ARN. 키 정책에서도 앱 역할 허용 |
| 앱 로그 권한 | CreateLogStream, PutLogEvents 등 | worldpay-log-group 범위. 그룹 사전 생성 여부에 맞춰 필요한 조회 권한 포함 |
| 앱 SSM 권한 | AmazonSSMManagedInstanceCore 예시 | SSM Agent 실행, 443 통신 경로도 필요 |
| EC2 Bastion | worldpay-bastion | AL2023 / t3.micro / Public a / Bastion SG / Bastion 프로파일 |
| SSH 접속 선택 시 | 키 페어·공인 IPv4 | SSH 22의 내 IP/32. SSM만이면 SSH 규칙 불필요 |
| 시작 템플릿 | worldpay-app-lt / 예시 | AL2023 x86_64 / t3.micro / App SG / 앱 프로파일 |
| 템플릿 네트워크 | 앱에 공인 IP 미부여 | ASG에서 App a·c 지정. Public 서브넷 고정하지 않기 |
| 앱 실행 환경 | 8080 리슨 | 서비스 자동 시작·Secret 연동·로그 수집은 앱 연동 확장 실습에서 확인 |
| AMI·사용자 데이터 | 학습 환경에 맞게 준비 | 비밀번호·고정 액세스 키 입력 금지. 새 인스턴스에도 동일 설정 재현 |
템플릿 변경은 새 버전으로 저장하고 ASG 사용 버전까지 확인합니다. 기존 인스턴스는 새 템플릿 내용이 자동 반영된 것으로 판단하지 않습니다.

## 접속 경로 선택
이 표는 앱 SSM이 NAT를 통해 AWS 서비스에 접근하는 예시입니다. Secrets Manager Endpoint 하나가 SSM·CloudWatch 연결까지 대신하지 않습니다. Bastion의 실습용 관리자 권한은 평가 종료 후 회수합니다.
역할·프로파일 ID 기록 ______________________________________

# 작업표 8 | ALB·대상 그룹·ASG

| 리소스 / 입력칸 | 값 | 연결·확인 |
| --- | --- | --- |
| 대상 그룹 이름 | worldpay-app-tg / 예시 | Instance 대상 / 앱 VPC / HTTP 8080 |
| 상태 검사 | HTTP /health | traffic-port 8080 / 정상 응답 확인 |
| ALB 이름 | worldpay-alb | Application / Internet-facing / 앱 VPC |
| ALB 서브넷 | Public a·c | 서로 다른 AZ / ALB SG 연결 |
| ALB 리스너 | HTTP 80 | 기본 작업 Fixed response 403 |
| 규칙 우선순위 10 / 예시 | /v1/users AND GET 또는 POST | App 대상 그룹으로 전달 |
| 규칙 우선순위 20 / 예시 | /health AND GET | App 대상 그룹으로 전달 |
| 규칙 기본 / 마지막 | 그 외 모든 요청 | ALB 고정 응답 403 / 앱에 전달 금지 |
| ASG 이름 | worldpay-asg | 앱 VPC / App a·c / 시작 템플릿 버전 지정 |
| ASG 용량 | 최소 2 / 원하는 2 / 최대 4 | 최소 2는 공식 조건. 원하는·최대 값은 학습용 예시 |
| ASG Name 태그 | worldpay-app | 새 인스턴스에 전파 체크 |
| ASG 로드 밸런싱 | App 대상 그룹 | 새 인스턴스 자동 등록 |
| ASG 조정 정책 | 대상 추적 / 평균 CPU 70% | 최대 용량이 최소보다 커야 확장 가능 |
| ASG 상태 검사 | ELB 상태 검사 사용 예시 | 초기 설치에 맞는 유예시간. 공식 고정 시간 없음 |
ALB는 Public에, 앱은 App 서브넷에 배치합니다. ALB 리스너 포트 80과 앱·상태 검사 포트 8080을 혼동하지 않습니다. 허용 API를 /v1/* 또는 /*로 넓게 전달하지 않습니다.

## 확인 결과
ALB DNS _____________________ / 대상 Healthy 개수 __________
ASG 실제 인스턴스 개수 ______ / 두 AZ 사용 [ ]

# 작업표 9 | 로그·대시보드·운영 확인

| 콘솔 / 리소스 | 값 | 작업·정상 상태 |
| --- | --- | --- |
| CloudWatch 앱 로그 그룹 | worldpay-log-group | 보존 30일 |
| 앱 로그 파일 | /var/log/worldpay/app.log / 예시 | 실제 출력 경로에 맞춰 Agent 설정 |
| Agent 로그 스트림 | {instance_id} / 예시 | 인스턴스별 구분 / 해당 로그 그룹으로 전송 |
| 로그 전송 지연 | 최대 5분 | 실제 앱 요청 시각과 도착 로그 시각 비교 |
| CloudWatch Dashboard | worldpay-dashboard | 서울 리전 / 아래 두 지표 표시 |
| ALB 위젯 | HTTP_Fixed_Response_Count | AWS/ApplicationELB / 해당 ALB 차원 / Sum 예시 |
| CPU 위젯 | CPUUtilization | AWS/EC2 / AutoScalingGroupName=worldpay-asg / Average |
| EC2 모니터링 | 지표 가용 여부 확인 | ASG 차원의 평균 CPU인지 확인. 단일 인스턴스 CPU와 구분 |
| 채점 접속 | worldpay-bastion | SSH 또는 SSM 성공 / 자신의 계정 / 서울 리전 |
| 채점 도구 | awscli, curl, 공식 mark.sh | 실행 출력과 기대값을 비교. Secret 출력 공개 금지 |

## 요청별 최종 확인표
| 테스트 | 기대 결과 | 확인 기록 |
| --- | --- | --- |
| ALB /health | 앱이 실행된 환경에서 상태 OK | □ / 시각 __________ |
| POST /v1/users | 생성된 uid 반환 | □ / uid __________ |
| GET /v1/users?uid=실제값 | 저장한 name·age 조회 | □ / 결과 __________ |
| GET /v1/users123 | ALB 고정 응답 HTTP 403 | □ / 코드 __________ |
| 로그와 ALB 지표 | 새 로그·고정 응답 지표 확인 | □ / 시각 __________ |
API·앱 로그 테스트는 앱이 실행된 확장 실습 환경에서 진행합니다. 콘솔 구성만 학습하는 경우 리소스 설정과 예상 결과를 확인하고, 동작 테스트 완료로 표시하지 않습니다.

# 작업표 10 | 누락 방지와 리소스 ID 기록

## 콘솔에서 마지막으로 한 줄씩 대조
| 점검 항목 | 정상 기준 | 완료 |
| --- | --- | --- |
| 리전·명칭·태그 | 서울 / 공식 Name 태그 정확 | □ |
| 네트워크 연결 | 6개 서브넷 / 4개 라우팅 테이블 연결 | □ |
| 공개·비공개 구분 | ALB·NAT·Bastion Public / 앱·DB Private | □ |
| Peering | Active / DNS 양방향 / 양쪽 경로 | □ |
| DB 방화벽 | SG 3307 앱 CIDR / NACL 요청·응답 | □ |
| SG 참조 | ALB→App 8080 / App→Endpoint 443 | □ |
| SG 실제 적용 | 올바른 VPC·연결 / 다른 SG의 전체 허용 없음 | □ |
| IAM·KMS | 앱 최소 권한 / Secret CMK / 키 정책 허용 | □ |
| DB·Secret | DB 3307·비공개·암호화 / admin 미사용 | □ |
| ASG·ALB | 최소 2 / CPU 70 / 기본 403 | □ |
| 관측 | 두 VPC Flow Logs / 앱 로그·30일 / 두 위젯 | □ |

## 연결 오류를 줄이는 ID 기록 (비밀번호 제외)
ALB SG ID ______________ / App SG ID ______________________
DB SG ID _______________ / Endpoint SG ID __________________
Bastion SG ID __________ / DB Subnet Group _________________
시작 템플릿 ID·버전 _____________ / 대상 그룹 ARN ___________
KMS 키 ARN _____________________ / Secret ARN _____________

## 공식 기준과 학습용 예시를 구분
SG·IGW·NAT·IAM 역할·KMS 별칭·DB 서브넷 그룹·템플릿·대상 그룹 이름은 이 표의 예시입니다. 공식 요구값은 실제 시행과제·채점기준을 우선합니다. 이 작업표는 학생 계정에 실제 리소스를 생성하거나 실기 검증을 완료했다는 증명서가 아닙니다.
참고: AWS VPC Security group rules 및 ALB Security groups 공식 문서의 상태 유지·SG 참조·리스너/대상 포트 설명에 맞춰 정리했습니다. 자세한 원리는 본 학습자료의 보안 그룹 1~6쪽에서 확인합니다.
