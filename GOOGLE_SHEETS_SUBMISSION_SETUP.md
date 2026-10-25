# Google Sheets 채점 결과 수신 설정

## 1. Google Sheet 생성

1. Google Sheets에서 새 스프레드시트를 만듭니다.
2. 파일 이름을 `2026 전국기능경기대회 채점결과`로 지정합니다.
3. 시트는 비어 있어도 됩니다. 첫 제출 때 `채점결과` 탭과 헤더가 자동 생성됩니다.

## 2. Apps Script 입력

1. 스프레드시트에서 `확장 프로그램 → Apps Script`를 엽니다.
2. 기본 `Code.gs` 내용을 모두 지웁니다.
3. 저장소의 `google-apps-script/Code.gs` 내용을 붙여넣고 저장합니다.

## 3. Web App 배포

1. Apps Script 우측 상단 `배포 → 새 배포`를 선택합니다.
2. 유형 선택에서 `웹 앱`을 선택합니다.
3. 설명에 `채점결과 수신`을 입력합니다.
4. 다음 사용자 인증 정보로 실행은 `나`를 선택합니다.
5. 액세스 권한은 `모든 사용자`를 선택합니다.
6. `배포`를 누르고 권한을 승인합니다.
7. 발급된 `https://script.google.com/macros/s/.../exec` URL을 복사합니다.

테스트용 `/dev` URL이 아니라 반드시 `/exec`로 끝나는 배포 URL을 사용합니다.

## 4. 사이트 연결

`assets/submission-config.js`의 endpoint에 복사한 URL을 입력합니다.

```javascript
window.SCORE_SUBMISSION_CONFIG = Object.freeze({
  endpoint: "https://script.google.com/macros/s/배포_ID/exec",
  taskKey: "task02first",
  taskName: "02_1과제_1등",
});
```

커밋하고 GitHub Pages가 배포되면 풀이 페이지 하단의 전송 버튼이 활성화됩니다.

## 5. 제출 테스트

1. 풀이 페이지 하단에서 비번호, 이름, 테스트 결과를 입력합니다.
2. `Google Sheets로 제출`을 누릅니다.
3. 스프레드시트의 `채점결과` 탭에 새 행이 생성되는지 확인합니다.

## 보안

- AWS Access Key, Secret Access Key, Session Token, 개인 비밀번호를 제출하지 않습니다.
- 사이트와 Apps Script 양쪽에서 일반적인 AWS 자격 증명 패턴을 검사합니다.
- 공개 Web App URL에는 비밀키를 넣지 않습니다.
- 시트 공유 권한은 교사 계정만 볼 수 있도록 유지합니다.

## 2027 지방 모의고사 제출 연결

모의고사 페이지(`guide.html?doc=mock1t1`, `mock1t2`)의 제출은 기존 endpoint를 그대로 쓰고, Apps Script가 `taskKey`가 `mock`으로 시작하는 제출만 아래 시트로 보냅니다.

- 스프레드시트: `1kZURRJDtN9FKv1jQdMTBE6U70AtjC0dyctEa_fp7vZM`
- 탭: `2027지방모의고사` (첫 제출 때 자동 생성)
- 컬럼: 수신시각, 학생 제출시각, 과제, 비번호, 이름, 학교/소속, 점수, 만점, AWS 계정, 채점 결과, 페이지 URL
- 점수는 채점 스크립트 마지막 줄 `TOTAL SCORE: x / 50`에서 자동 추출합니다.

적용 방법 (URL이 바뀌지 않는 방식)

1. 현재 endpoint를 배포한 Apps Script 프로젝트를 엽니다.
2. `Code.gs`를 저장소의 `google-apps-script/Code.gs`로 바꿔 붙여넣고 저장합니다.
3. `배포 → 배포 관리 → (연필) 편집 → 버전: 새 버전 → 배포`를 누릅니다.
4. `SpreadsheetApp.openById` 권한 승인 창이 뜨면 승인합니다. 배포 계정이 위 시트의 편집 권한을 가져야 합니다.

새 배포를 만들면 URL이 바뀌므로 `assets/submission-config.js`도 함께 바꿔야 합니다.

학생이 붙여넣은 출력은 수정이 가능하므로, 점수가 의심스러우면 `채점 결과` 칸의 항목별 O/X와 `AWS 계정` 값을 확인하세요.
