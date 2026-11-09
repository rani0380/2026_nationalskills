#!/usr/bin/env python3
"""Round 5 grading evidence. AWS operations in this script are read-only."""
import argparse
import json
import re
import subprocess
from decimal import Decimal

REGION = "ap-northeast-2"
RUBRICS = {
    "1": [("저장소", 10), ("API 설정", 10), ("접수·업로드", 14), ("완료·조회", 10), ("권한", 6)],
    "2": [("저장소", 10), ("기록 처리", 14), ("트리거", 10), ("장애 복구", 10), ("권한·관측", 6)],
}
errors = 0


def aws(label, *args, query=None):
    global errors
    cmd = ["aws", "--region", REGION, "--output", "json", "--no-cli-pager",
           "--cli-connect-timeout", "8", "--cli-read-timeout", "15", *args]
    if query:
        cmd.extend(["--query", query])
    try:
        response = subprocess.run(cmd, capture_output=True, text=True, timeout=45)
        if response.returncode:
            code = re.search(r"An error occurred \(([A-Za-z0-9_.-]+)\)", response.stderr)
            detail = code.group(1) if code else "CLI 실행 실패"
            print(f"[ERROR] {label}: {detail}")
            errors += 1
            return None
        return json.loads(response.stdout or "null")
    except (OSError, subprocess.TimeoutExpired, ValueError) as exc:
        print(f"[ERROR] {label}: {type(exc).__name__}")
        errors += 1
        return None


def evidence(label, value):
    if value is not None:
        print(f"[조회] {label}: {json.dumps(value, ensure_ascii=False, default=str)}")


def show(label, *args, query):
    value = aws(label, *args, query=query)
    evidence(label, value)
    return value


def role(label, arn):
    if not arn or ":role/" not in arn:
        print(f"[확인 필요] {label} 역할 ARN")
        return
    name = arn.rsplit("/", 1)[-1]
    show(label + " 인라인 정책 이름", "iam", "list-role-policies", "--role-name", name,
         query="PolicyNames")
    show(label + " 관리형 정책", "iam", "list-attached-role-policies", "--role-name", name,
         query="AttachedPolicies[].PolicyArn")


def alarm(name):
    show("경보 설정", "cloudwatch", "describe-alarms", "--alarm-names", name,
         query="MetricAlarms[].{State:StateValue,Namespace:Namespace,Metric:MetricName,Dimensions:Dimensions,Statistic:Statistic,Period:Period,Evaluations:EvaluationPeriods,Datapoints:DatapointsToAlarm,Threshold:Threshold,Comparison:ComparisonOperator,Missing:TreatMissingData,Actions:AlarmActions,ActionsEnabled:ActionsEnabled}")


def retention(group):
    show("로그 보관", "logs", "describe-log-groups", "--log-group-name-prefix", group,
         query=f"logGroups[?logGroupName=='{group}'].{{Name:logGroupName,Days:retentionInDays}}")


def inspect_bucket(bucket, account):
    scope = ("--bucket", bucket, "--expected-bucket-owner", account)
    evidence("버킷", bucket)
    show("버킷 리전", "s3api", "get-bucket-location", *scope, query="LocationConstraint")
    show("버전 관리", "s3api", "get-bucket-versioning", *scope, query="Status")
    show("퍼블릭 액세스 차단", "s3api", "get-public-access-block", *scope,
         query="PublicAccessBlockConfiguration")
    show("기본 암호화", "s3api", "get-bucket-encryption", *scope,
         query="ServerSideEncryptionConfiguration.Rules[].ApplyServerSideEncryptionByDefault.SSEAlgorithm")
    return scope


def inspect_function(name):
    config = show("Lambda 설정", "lambda", "get-function-configuration", "--function-name", name,
                  query="{Name:FunctionName,Runtime:Runtime,Timeout:Timeout,Role:Role,State:State,Logging:LoggingConfig}")
    if config:
        role("Lambda 실행", config["Role"])
    retention("/aws/lambda/" + name)


def task1(account, student):
    scope = inspect_bucket(f"evidence-{account}-{student}", account)
    show("객체 소유권", "s3api", "get-bucket-ownership-controls", *scope,
         query="OwnershipControls.Rules[].ObjectOwnership")
    policy = aws("S3 정책", "s3api", "get-bucket-policy", *scope, query="Policy")
    if policy is not None:
        statements = json.loads(policy).get("Statement", [])
        if isinstance(statements, dict):
            statements = [statements]
        evidence("TLS 거부 조건 후보", [
            {k: statement.get(k) for k in ("Principal", "Action", "Resource")}
            for statement in statements
            if statement.get("Effect") == "Deny"
            and str(statement.get("Condition", {}).get("Bool", {}).get("aws:SecureTransport")).lower() == "false"
        ])
    show("접수 테이블", "dynamodb", "describe-table", "--table-name", "evidence-uploads",
         query="Table.{Keys:KeySchema,Types:AttributeDefinitions,Billing:BillingModeSummary.BillingMode}")
    inspect_function("evidence-api")
    apis = show("API Gateway", "apigatewayv2", "get-apis",
                query="Items[?Name=='evidence-http'].{Id:ApiId,Type:ProtocolType,Endpoint:ApiEndpoint}")
    if apis is not None and not apis:
        print("[확인 필요] evidence-http를 찾지 못했습니다.")
    for api in apis or []:
        api_scope = ("--api-id", api["Id"])
        show("Stage exam", "apigatewayv2", "get-stage", *api_scope, "--stage-name", "exam",
             query="{Name:StageName,AutoDeploy:AutoDeploy,Default:DefaultRouteSettings,Overrides:RouteSettings}")
        show("API 경로", "apigatewayv2", "get-routes", *api_scope,
             query="Items[].{Route:RouteKey,Integration:Target,Authorization:AuthorizationType}")
        show("Lambda 통합", "apigatewayv2", "get-integrations", *api_scope,
             query="Items[].{Id:IntegrationId,Type:IntegrationType,URI:IntegrationUri,Payload:PayloadFormatVersion}")
    print("[실기] 접수, 서명 업로드, 제한 위반, 완료 및 버전 유지 시험은 채점지에서 확인합니다.")


def task2(account, student):
    archive = inspect_bucket(f"parts-audit-{account}-{student}", account)
    failure = inspect_bucket(f"parts-fail-{account}-{student}", account)
    show("재고 테이블·스트림", "dynamodb", "describe-table", "--table-name", "parts-inventory",
         query="Table.{Keys:KeySchema,Types:AttributeDefinitions,Billing:BillingModeSummary.BillingMode,Stream:StreamSpecification,StreamArn:LatestStreamArn}")
    inspect_function("parts-audit-writer")
    show("이벤트 소스 매핑", "lambda", "list-event-source-mappings", "--function-name", "parts-audit-writer",
         query="EventSourceMappings[].{State:State,Stream:EventSourceArn,Start:StartingPosition,Batch:BatchSize,Window:MaximumBatchingWindowInSeconds,Parallel:ParallelizationFactor,Responses:FunctionResponseTypes,Retries:MaximumRetryAttempts,Age:MaximumRecordAgeInSeconds,Destination:DestinationConfig.OnFailure.Destination}")
    for label, scope, prefix in [("감사 기록", archive, "records/"), ("실패 객체", failure, "aws/lambda/")]:
        show(label + " 객체 최대 10건", "s3api", "list-objects-v2", *scope, "--prefix", prefix,
             "--max-items", "10", query="Contents[].{Key:Key,Bytes:Size,Modified:LastModified}")
    show("실패 지표 필터", "logs", "describe-metric-filters", "--log-group-name",
         "/aws/lambda/parts-audit-writer", "--metric-name", "RecordFailures", "--metric-namespace", "PartsAudit",
         query="metricFilters[].{Pattern:filterPattern,Metrics:metricTransformations}")
    alarm("parts-audit-failures")
    show("경보 상태 변경 이력", "cloudwatch", "describe-alarm-history", "--alarm-name",
         "parts-audit-failures", "--history-item-type", "StateUpdate", "--max-items", "15",
         query="AlarmHistoryItems[].{Time:Timestamp,Summary:HistorySummary}")
    print("[실기] 변경 전후 값, 실패 입력, 재실행과 객체 버전 수는 채점지에서 확인합니다.")


def score_values(raw, rubric):
    values = raw.split(",")
    if len(values) != len(rubric):
        raise ValueError("교사 점수는 영역 순서대로 5개를 입력하세요.")
    scores = []
    for value, (name, limit) in zip(values, rubric):
        if not re.fullmatch(r"[0-9]{1,2}(?:\.[0-9]{1,2})?", value):
            raise ValueError(f"{name}: 0~{limit} 숫자를 입력하세요.")
        score = Decimal(value)
        if score > limit:
            raise ValueError(f"{name}: 상한 {limit}점 초과")
        scores.append(score)
    return scores


def main():
    parser = argparse.ArgumentParser(description="5회 모의고사 교사용 읽기 전용 채점 보조")
    parser.add_argument("task", choices=RUBRICS)
    parser.add_argument("student", help="비번호 1~12자리 숫자")
    parser.add_argument("teacher_scores", nargs="?", help="교사가 확정한 영역별 점수 5개, 쉼표 구분")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]{1,12}", args.student):
        parser.error("비번호는 숫자 1~12자리입니다.")
    rubric = RUBRICS[args.task]
    scores = None
    if args.teacher_scores is not None:
        try:
            scores = score_values(args.teacher_scores, rubric)
        except ValueError as exc:
            parser.error(str(exc))
    account = aws("호출 계정 확인", "sts", "get-caller-identity", query="Account")
    if not account or not re.fullmatch(r"[0-9]{12}", account):
        return 1
    print(f"2027 지방 모의고사 5회 제{args.task}과제 | 비번호: {args.student}")
    print(f"계정: {account} | 리전: {REGION}")
    print("조회 결과는 교사 실기 채점의 보조 증거입니다.")
    if args.task == "1":
        task1(account, args.student)
    else:
        task2(account, args.student)
    if errors:
        print(f"[확인 필요] 조회 오류 {errors}건. 누락 증거는 교사가 별도로 확인합니다.")
    if scores is None:
        print("실기 점수 미입력. 영역 상한: " + ",".join(str(limit) for _, limit in rubric))
    else:
        print("교사 확정 점수")
        for (name, limit), score in zip(rubric, scores):
            print(f"- {name}: {score}/{limit}")
        print(f"TOTAL SCORE: {sum(scores):f}/50")
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
