AWS 콘솔 상세해설서 실습파일

이 파일들은 해설서 순서대로 사용하는 예제이며 자동 배포 도구가 아닙니다.
AWS 계정에서 실행하지 않았습니다. 실제 리전 및 계정의 생성 가능 버전과 권한을 확인하세요.
REPLACE_로 시작하는 문자열은 본인 계정의 값으로 바꾸세요.
JSON에는 주석을 추가하지 마세요. Python 들여쓰기를 유지하세요.
AWS_REGION은 Lambda가 자동 제공하므로 Lambda 환경변수에 수동 추가하지 마세요.

module1: index.py는 제공 코드의 TODO 두 함수를 완성한 사본입니다.
         workflow.asl.json은 input/test.csv 등 1단계 ASCII 파일명 예제입니다.
         trigger.py는 별도 트리거 함수에 넣습니다.
module2: app.py 및 requirements.txt는 지급파일 사본입니다.
module3: app 바이너리는 원본 module3/app을 사용하세요. 소비자 코드는 학습용 구현입니다.
module4: OAI와 SSE-KMS 동시 요구는 모순입니다. OAC 예제는 기술적 대안입니다.
module5: root와 stub 바이너리, ingestion 코드는 원본을 사용하세요.
         root/stub는 ARM64입니다. 컨테이너 이미지는 ARM64로 빌드하세요.

iam: 역할에 추가하는 인라인 권한 예제입니다. 역할의 신뢰 정책 및 로그 정책은
     해설서에서 설명합니다. 역할별로 필요한 정책만 사용하세요.
     임시 토픽 생성 권한은 생성 및 검증 후 제거하세요.

원본 폴더의 파일은 수정하지 않았습니다.
