# 2027 지방 모의고사 6회 · 제2과제 채점기준표

비번호 __________　평가자 __________　평가일 __________　교사 지정 오류 파일 __________　확정 점수 ______ / 50

문제지 6절의 배점(10·8·12·14·6)을 세부 항목으로 나눈 기준표입니다. 각 항목의 증거를 확인하고 획득점을 적습니다. 12~14절의 2차 보강 시험은 별도 점수가 아니라 아래 항목의 판정 증거로 사용합니다.

| 영역 | 항목 | 배점 | 확인할 증거 | 획득점 |
| --- | --- | --- | --- | --- |
| 서버·관리 연결 | 두 서버 사양 | 4 | config-web-1·2, AL2023, t3.micro, 서로 다른 AZ, 태그 Project=ConfigLab·Role=web, nginx active·부팅 자동 시작 | ____ |
| 서버·관리 연결 | 관리 연결·SSH 차단 | 6 | 두 노드 PingStatus=Online(3), 연결된 모든 SG에 22·전체 포트 인바운드 없음(2), Role=web이 실습 2대뿐(1) | ____ |
| 저장소·권한 | 버킷 | 4 | 서울·공개 차단 4개·버전 관리·SSE-S3(2), 비 TLS Deny(1), config/site.json 한 키에 v1·v2·오류 버전(1) | ____ |
| 저장소·권한 | 역할 권한 | 4 | AmazonSSMManagedInstanceCore(1), 지정 객체 GetObjectVersion만·GetObject로 대체 안 함(2), 로그 권한 지정 그룹 범위(1). 다른 버킷 시험 Failed 확인 | ____ |
| Document | 버전 지정 읽기·매개변수 | 5 | Command·2.2(1), 두 매개변수 ENV_VAR·allowedPattern(1), --version-id 지정 읽기(1), 셸 주입·명령 치환 시험에서 명령 미실행(2) | ____ |
| Document | 검증·원자적 교체·기록 | 7 | 크기→JSON→message 순 검증(2), 교사 지정 오류 파일 Failed·두 파일 hash 보존(2), 같은 디렉터리 임시 파일 교체·644(1), deployment.json 4필드 실제 값(1), HTTP 본문 확인 후 성공·HTTP 실패 노드 Failed(1) | ____ |
| 배포·복구 | Association | 4 | 이름·문서·tag:Role=web·rate(30 minutes)(2), 버전 변경을 매개변수 수정·즉시 실행으로 수행한 버전 이력(2) | ____ |
| 배포·복구 | v1→v2 | 4 | 두 노드 각각 Success, Welcome v1→v2, deployment.json version_id 일치 | ____ |
| 배포·복구 | 실패 보존·복원·반복 | 6 | invalid·없는 버전 두 노드 Failed·보존(2), latest가 오류여도 v1 복원(2), 같은 v1 재실행 hash 동일·드리프트 즉시 실행 복구(1), 최종 association v1(1) | ____ |
| 관측 | 로그 | 3 | /config-lab/commands 14일(1), Run Command CloudWatch 출력 켜짐(1), 실패 로그에 버전·오류 요약만 있고 자격 증명·전체 데이터 없음(1) | ____ |
| 관측 | 경보 | 3 | 필터 ConfigLab/DeployFailures 값 1(1), 경보 Sum·60초·1회·1 이상·notBreaching(1), 실패 시험 후 실제 OK→ALARM 이력(1) | ____ |
| 합계 | | 50 | | ____ |

## 감점·불인정 기준

| 상황 | 처리 |
| --- | --- |
| v1/v2 문구를 코드에 고정 출력 | ‘버전 지정 읽기’ 0점, v1→v2 0점 |
| 실패 메시지를 출력했지만 index.html 또는 deployment.json hash가 변함 | ‘실패 보존’ 해당 2점 0점 |
| 상위 명령 상태만 제출, 노드별 결과 없음 | 해당 배포 항목 절반 |
| `{{VersionId}}`를 셸 본문에 직접 삽입 | 매개변수 처리 2점 0점(주입 시험 통과 여부와 무관) |
| 주입 시험에서 /tmp/configlab-pwned 생성 또는 id 출력 | 매개변수 처리 5점 중 주입 2점 0점, 보안 문제로 기록 |
| SSH 22를 일시적으로라도 열어 작업 | 관리 연결 6점 중 SSH 2점 0점 |
| 시험 후 nginx를 중지 상태로 둠 | 서버 사양 4점 중 1점 감점 |

## 점수 입력 순서

| 순서 | 영역 | 상한 | 영역 합계 |
| --- | --- | --- | --- |
| 1 | 서버·관리 연결 | 10 | ____ |
| 2 | 저장소·권한 | 8 | ____ |
| 3 | Document | 12 | ____ |
| 4 | 배포·복구 | 14 | ____ |
| 5 | 관측 | 6 | ____ |

## 교사용 노드 증거 수집

채점 스크립트는 읽기 전용이므로 두 노드의 파일 hash는 교사가 Run Command로 별도로 수집합니다. 아래 명령은 파일을 읽기만 합니다. 시험 단계마다(v2 적용 후, 오류 시험 후, v1 복원 후) 실행해 결과를 보관합니다.

```bash
export AWS_DEFAULT_REGION=ap-northeast-2
CID=$(aws ssm send-command --document-name AWS-RunShellScript \
  --targets Key=tag:Role,Values=web \
  --parameters 'commands=["sha256sum /usr/share/nginx/html/index.html /var/lib/config-lab/deployment.json","cat /var/lib/config-lab/deployment.json","curl -s http://localhost/","systemctl is-active nginx","ls -l /tmp/configlab-pwned 2>&1 || true"]' \
  --comment "mock6-t2 evidence" --query Command.CommandId --output text)
sleep 10
aws ssm list-command-invocations --command-id "$CID" --details \
  --query 'CommandInvocations[].{Node:InstanceId,Status:Status,Output:CommandPlugins[0].Output}' --output json
```

오류 시험 전후의 hash가 두 노드 모두 같아야 ‘실패 보존’을 인정합니다. 마지막 줄은 `No such file`이어야 합니다.

## 채점 스크립트 실행

서울 리전 CloudShell에서 실행합니다. 1234를 본인 비번호로 바꿉니다.

```bash
curl -fL 'https://rani0380.github.io/2026_nationalskills/downloads/mock2027/mock6-2_mark.sh' -o mock6-2_mark.sh
bash mock6-2_mark.sh 1234
```

스크립트는 EC2·SG·SSM 관리 노드·역할 정책·버킷·버전 목록·Document 매개변수·Association 설정·버전·실행 이력·Run Command 이력·로그·지표 필터·경보 이력을 조회만 합니다. [ERROR]가 나오면 리소스 이름과 조회 권한을 확인합니다. Document 스크립트 단서는 참고용이며 실제 동작은 노드 증거로 판정합니다.

교사가 영역별 점수를 확정하면 아래 형식으로 입력합니다. 숫자는 입력 예시입니다.

```bash
bash mock6-2_mark.sh 1234 9,7,10,12,5 | tee mock6-2-result.txt
```

확정 점수는 마지막 TOTAL SCORE 줄에 출력됩니다. 노드 증거 수집 결과, 교사 지정 오류 파일 이름, 경보 이력을 함께 첨부합니다.

## 채점 결과 제출

교사가 확정한 스크립트 출력을 아래 제출 양식에 붙여넣습니다. 비번호와 이름을 입력한 뒤 **Google Sheets로 제출**을 누릅니다.
