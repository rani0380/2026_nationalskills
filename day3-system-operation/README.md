# AWS System Operation — 제3과제 공개 학습 풀이

2026년도 전국기능경기대회 클라우드컴퓨팅 직종 제3과제 `System operation`의 공개 교육용 해설 사이트입니다.

## 범위

- VPC, EKS(EC2 `c5.large`), ECR
- RDS MySQL 8.0 Multi-AZ `db.t3.micro`
- S3 이미지 저장과 동일 endpoint 제공
- `user`, `product`, `stress` 컨테이너 배포
- ALB 단일 HTTPS endpoint와 경로 라우팅
- WAF 403 / 미제공 API 404 처리
- CloudWatch 모니터링, 검증, 비용 점검

> 제공 바이너리와 `load_user.dump`는 저장소에 포함하지 않습니다. 실제 채점은 공식 과제지와 채점기준표가 우선합니다.

## 로컬 열기

`index.html`을 브라우저로 열면 됩니다. 별도 빌드 과정이나 외부 라이브러리가 없습니다.

## 공개 문서

GitHub Pages로 배포되는 정적 사이트입니다.
