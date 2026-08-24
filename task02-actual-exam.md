# 제2과제 실제 출제본 공지 및 풀이

> **2026년 8월 24일 실제 시험 공지 반영**  
> 기존 Release Candidate와 예상문제는 실제 채점 기준이 아닙니다. 반드시 현장에 게시된 최종 문제지와 채점표를 우선합니다.

## 가장 중요한 변경

실제 인쇄 문제지 첫 페이지에는 1~5번이 표시되어 있지만, 공지에 따라 **기존 3번 모듈은 삭제**되었습니다. 따라서 현재 유효한 과제는 다음 4개입니다.

| 실제 작업 순서 | 인쇄 번호 | 과제 | 상태 |
|---:|---:|---|---|
| 1 | 1 | Workflow | 출제 |
| 2 | 2 | Real-Time Data Analytics | 출제 |
| - | 3 | EKS | **삭제 - 구축·채점하지 않음** |
| 3 | 4 | CDN Service Setup | 추가 출제 |
| 4 | 5 | Legacy System Operation | 추가 출제 |

## 8월 24일 공식 공지

- 오류 수정으로 과제 내용이 변경되었으므로 현재 배포된 문제지를 자세히 읽고 진행합니다.
- 기존 3번 모듈은 문제지와 채점지 오류로 삭제되었습니다.
- 변별력을 위한 추가 과제로 4번과 5번이 출제되었습니다.
- 4번 CDN Service Setup의 시간 출력은 **한국 시간(KST)** 기준이어야 합니다.
- 4번 채점 웹페이지는 `https://d2lvw397wb43zq.cloudfront.net`입니다.
- 채점 진행 시 CloudShell 사용에 문제가 없도록 구성해야 합니다.

채점 페이지:

```text
https://d2lvw397wb43zq.cloudfront.net
```

## 학생 즉시 행동 순서

1. 기존 RC의 MSK 또는 예상 Event Handling을 만들고 있었다면 즉시 중단합니다.
2. 인쇄된 3번 EKS는 공지에 따라 작업하지 않습니다.
3. Workflow와 Real-Time Data Analytics는 현장 최종 문제지의 변경값을 다시 확인합니다.
4. 새 4번 CDN Service Setup과 5번 Legacy System Operation에 시간을 배정합니다.
5. CDN 응답에 시간이 있다면 로컬 서버 timezone에 의존하지 말고 코드에서 KST `+09:00`을 명시합니다.
6. CloudShell에서 `aws sts get-caller-identity`와 모듈별 Region을 먼저 확인합니다.
7. Bastion, SSM, CloudShell 등 채점 접근 경로가 끊기지 않게 유지합니다.

## CDN KST 구현 기준

Python 예시:

```python
from datetime import datetime, timezone, timedelta

KST = timezone(timedelta(hours=9))
current_time = datetime.now(KST).isoformat(timespec="seconds")
# 예: 2026-08-24T10:30:00+09:00
```

Node.js 예시:

```javascript
const currentTime = new Intl.DateTimeFormat("sv-SE", {
  timeZone: "Asia/Seoul",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
}).format(new Date()).replace(" ", "T") + "+09:00";
```

검증 예시:

```bash
curl -fsSL https://d2lvw397wb43zq.cloudfront.net
```

실제 API 경로와 요청 방식은 현장 문제지의 표를 따릅니다. 사진에서 판독되지 않은 경로를 추측해 사용하지 않습니다.

## CloudShell 채점 접근 점검

```bash
aws sts get-caller-identity
aws configure get region
aws configure list
```

확인할 사항:

- 본인 AWS Account ID가 출력되는가
- 현재 작업 모듈의 Region과 일치하는가
- CloudShell에서 AWS CLI가 정상 실행되는가
- 채점 대상 리소스를 이름으로 조회할 수 있는가
- Session Manager 또는 Bastion 접근이 유지되는가

## 현재 자료 사용 구분

| 자료 | 사용 여부 |
|---|---|
| 이 페이지의 8월 24일 공지 | 사용 |
| 현장 최종 문제지·채점표 | 최우선 사용 |
| 기존 RC의 Workflow·Analytics 설명 | 변경값 대조 후 제한적으로 참고 |
| 기존 RC의 MSK 3번 채점표 | 사용 금지 |
| 비공식 Event Handling 예상문제 | 사용 금지 |
| 인쇄 문제지의 3번 EKS | 공지에 따라 사용 금지 |

## 세부 풀이 업데이트 상태

현재 확보된 전체 사진에서는 4번과 5번의 작은 글씨, 리소스명, API 경로, Runtime, 배점표를 만점 수준으로 판독할 수 없습니다. 각 페이지의 정면 근접 사진 또는 PDF가 확보되는 즉시 다음을 추가합니다.

- 1~5번 전체 리소스명·Region·CIDR 표
- CDN Origin, Behavior, Cache Policy, Lambda@Edge/API Gateway 설정
- Legacy System의 EC2·DB·API·배포 구성
- 실제 채점표 전 항목과 동일한 CloudShell 명령
- 항목별 기대 출력과 만점 체크표

> 세부값이 보이지 않는 상태에서 임의 이름을 만들어 제공하는 것보다, 확인된 공지만 먼저 정확히 반영하는 것이 안전합니다.
