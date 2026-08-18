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
