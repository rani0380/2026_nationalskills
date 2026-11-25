#!/usr/bin/env python3
"""Round 6 task 2 grading evidence. AWS operations in this script are read-only."""
import argparse
import json
import re
import subprocess
from decimal import Decimal

REGION = "ap-northeast-2"
RUBRICS = {
    "2": [("서버·관리 연결", 10), ("저장소·권한", 8), ("Document", 12), ("배포·복구", 14), ("관측", 6)],
}
LOG_GROUP = "/config-lab/commands"
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


def show(label, *args, query=None):
    value = aws(label, *args, query=query)
    evidence(label, value)
    return value


def statements(document):
    if isinstance(document, str):
        document = json.loads(document)
    items = (document or {}).get("Statement", [])
    return [items] if isinstance(items, dict) else items


def section(title):
    print(f"\n== {title} ==")


def servers():
    section("서버·관리 연결")
    instances = show("ConfigLab EC2", "ec2", "describe-instances",
                     "--filters", "Name=tag:Project,Values=ConfigLab",
                     "Name=instance-state-name,Values=pending,running,stopping,stopped",
                     query="Reservations[].Instances[].{Id:InstanceId,Name:Tags[?Key=='Name']|[0].Value,"
                           "Role:Tags[?Key=='Role']|[0].Value,Type:InstanceType,AZ:Placement.AvailabilityZone,"
                           "State:State.Name,Image:ImageId,PublicIp:PublicIpAddress,Subnet:SubnetId,"
                           "Profile:IamInstanceProfile.Arn,SG:SecurityGroups[].GroupId}") or []
    show("Role=web 전체 대상(실습 2대만이어야 함)", "ec2", "describe-instances",
         "--filters", "Name=tag:Role,Values=web",
         "Name=instance-state-name,Values=pending,running,stopping,stopped",
         query="Reservations[].Instances[].{Id:InstanceId,Name:Tags[?Key=='Name']|[0].Value,Project:Tags[?Key=='Project']|[0].Value}")
    if instances:
        evidence("서로 다른 AZ 수", len({i.get("AZ") for i in instances}))
        ids = ",".join(i["Id"] for i in instances)
        show("SSM 관리 노드", "ssm", "describe-instance-information",
             "--filters", f"Key=InstanceIds,Values={ids}",
             query="InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Agent:AgentVersion,Platform:PlatformName,Version:PlatformVersion}")
        groups = sorted({g for i in instances for g in (i.get("SG") or [])})
        rules = aws("보안 그룹", "ec2", "describe-security-groups", "--group-ids", *groups,
                    query="SecurityGroups[].{Id:GroupId,In:IpPermissions}") if groups else []
        rules = rules or []
        ssh = []
        for group in rules:
            for rule in group.get("In") or []:
                proto = rule.get("IpProtocol")
                low, high = rule.get("FromPort"), rule.get("ToPort")
                if proto == "-1" or (proto in ("tcp", "6") and low is not None and low <= 22 <= high):
                    ssh.append({"SG": group["Id"], "Protocol": proto, "From": low, "To": high,
                                "Ipv4": [r.get("CidrIp") for r in rule.get("IpRanges", [])],
                                "Groups": [r.get("GroupId") for r in rule.get("UserIdGroupPairs", [])]})
        evidence("SSH 22 허용 규칙(빈 목록이어야 함)", ssh)
        profiles = sorted({i["Profile"] for i in instances if i.get("Profile")})
        for arn in profiles:
            name = arn.rsplit("/", 1)[-1]
            roles = show("인스턴스 프로파일 역할", "iam", "get-instance-profile",
                         "--instance-profile-name", name, query="InstanceProfile.Roles[].RoleName") or []
            for role in roles:
                inspect_role(role)
    else:
        print("[확인 필요] Project=ConfigLab 인스턴스를 찾지 못했습니다.")
    print("[실기] nginx 활성·localhost 응답은 채점지의 Run Command 증거로 확인합니다.")


def inspect_role(role):
    show("역할 신뢰 주체", "iam", "get-role", "--role-name", role,
         query="Role.AssumeRolePolicyDocument.Statement[].Principal")
    show("관리형 정책", "iam", "list-attached-role-policies", "--role-name", role,
         query="AttachedPolicies[].PolicyArn")
    for policy in show("인라인 정책 이름", "iam", "list-role-policies", "--role-name", role,
                       query="PolicyNames") or []:
        document = aws("인라인 정책 " + policy, "iam", "get-role-policy", "--role-name", role,
                       "--policy-name", policy, query="PolicyDocument")
        if document is not None:
            evidence("인라인 정책 " + policy, [
                {k: s.get(k) for k in ("Effect", "Action", "Resource", "Condition") if k in s}
                for s in statements(document)])


def storage(account, student):
    section("저장소·권한")
    bucket = f"config-store-{account}-{student}"
    scope = ("--bucket", bucket, "--expected-bucket-owner", account)
    evidence("버킷", bucket)
    show("버킷 리전", "s3api", "get-bucket-location", *scope, query="LocationConstraint")
    show("버전 관리", "s3api", "get-bucket-versioning", *scope, query="Status")
    show("퍼블릭 액세스 차단", "s3api", "get-public-access-block", *scope,
         query="PublicAccessBlockConfiguration")
    show("기본 암호화", "s3api", "get-bucket-encryption", *scope,
         query="ServerSideEncryptionConfiguration.Rules[].ApplyServerSideEncryptionByDefault.SSEAlgorithm")
    policy = aws("버킷 정책", "s3api", "get-bucket-policy", *scope, query="Policy")
    if policy is not None:
        evidence("TLS 거부 문장", [
            {k: s.get(k) for k in ("Principal", "Action", "Resource")}
            for s in statements(policy)
            if s.get("Effect") == "Deny"
            and str(s.get("Condition", {}).get("Bool", {}).get("aws:SecureTransport")).lower() == "false"])
    show("config/site.json 버전 목록", "s3api", "list-object-versions", *scope,
         "--prefix", "config/site.json",
         query="Versions[?Key=='config/site.json'].{VersionId:VersionId,Latest:IsLatest,Bytes:Size,Modified:LastModified}")
    print("[실기] 역할의 GetObjectVersion 범위는 위 인라인 정책 Resource와 다른 버킷 시험 결과로 확인합니다.")


def document():
    section("Document")
    show("config-deploy 문서", "ssm", "describe-document", "--name", "config-deploy",
         query="Document.{Type:DocumentType,Schema:SchemaVersion,Status:Status,Format:DocumentFormat,Default:DefaultVersion,Latest:LatestVersion}")
    content = aws("문서 내용", "ssm", "get-document", "--name", "config-deploy",
                  "--document-format", "JSON", query="Content")
    if content is None:
        return
    try:
        body = json.loads(content)
    except ValueError:
        print("[확인 필요] 문서 내용 JSON 파싱 실패")
        return
    evidence("매개변수", {name: {k: v for k, v in spec.items() if k != "description"}
                          for name, spec in (body.get("parameters") or {}).items()})
    steps = body.get("mainSteps") or []
    evidence("단계", [{"action": s.get("action"), "name": s.get("name"),
                      "timeout": (s.get("inputs") or {}).get("timeoutSeconds")} for s in steps])
    script = "\n".join(line for s in steps for line in (s.get("inputs") or {}).get("runCommand") or [])
    evidence("스크립트 단서", {
        "SSM_VersionId 사용": "SSM_VersionId" in script,
        "SSM_BucketName 사용": "SSM_BucketName" in script,
        "{{VersionId}} 직접 삽입": "{{VersionId}}" in script or "{{ VersionId }}" in script,
        "--version-id 지정": "--version-id" in script or "VersionId=" in script,
        "CONFIG_DEPLOY_FAILED 출력": "CONFIG_DEPLOY_FAILED" in script,
        "원자적 교체(os.replace/mv)": "os.replace" in script or re.search(r"\bmv\b", script) is not None,
    })
    print("[실기] 검증 순서·실패 보존은 교사 지정 오류 파일 시험의 두 노드 hash로 확인합니다.")


def deployment():
    section("배포·복구")
    found = show("Association", "ssm", "list-associations", "--association-filter-list",
                 "key=AssociationName,value=config-deploy-assoc",
                 query="Associations[].{Id:AssociationId,Doc:Name,Targets:Targets,Schedule:ScheduleExpression}") or []
    if not found:
        print("[확인 필요] config-deploy-assoc를 찾지 못했습니다.")
    for item in found:
        assoc = item["Id"]
        show("Association 설정", "ssm", "describe-association", "--association-id", assoc,
             query="AssociationDescription.{Name:AssociationName,Doc:Name,DocVersion:DocumentVersion,Targets:Targets,"
                   "Schedule:ScheduleExpression,Parameters:Parameters,Status:Overview.Status,"
                   "MaxConcurrency:MaxConcurrency,MaxErrors:MaxErrors,Updated:LastUpdateAssociationDate}")
        show("Association 버전 이력(VersionId 변경)", "ssm", "list-association-versions",
             "--association-id", assoc, "--max-results", "10",
             query="AssociationVersions[].{Version:AssociationVersion,Created:CreatedDate,Parameters:Parameters}")
        show("Association 실행 이력 최대 10건", "ssm", "describe-association-executions",
             "--association-id", assoc, "--max-results", "10",
             query="AssociationExecutions[].{Id:ExecutionId,Status:Status,Detail:DetailedStatus,Created:CreatedTime,Counts:ResourceCountByStatus}")
    show("Run Command 이력 최대 15건", "ssm", "list-commands",
         "--filters", "key=DocumentName,value=config-deploy", "--max-items", "15",
         query="Commands[].{Id:CommandId,At:RequestedDateTime,Status:Status,VersionId:Parameters.VersionId,"
               "Bucket:Parameters.BucketName,Targets:TargetCount,Completed:CompletedCount,Errors:ErrorCount,"
               "CloudWatch:CloudWatchOutputConfig}")
    print("[실기] 노드별 v1→v2→실패 보존→v1, 드리프트 복구는 채점지의 hash·HTTP 증거로 확인합니다.")


def observe():
    section("관측")
    show("로그 보관", "logs", "describe-log-groups", "--log-group-name-prefix", LOG_GROUP,
         query=f"logGroups[?logGroupName=='{LOG_GROUP}'].{{Name:logGroupName,Days:retentionInDays}}")
    show("실패 지표 필터", "logs", "describe-metric-filters", "--log-group-name", LOG_GROUP,
         query="metricFilters[].{Name:filterName,Pattern:filterPattern,Metrics:metricTransformations}")
    show("실패 로그 최근 5건", "logs", "filter-log-events", "--log-group-name", LOG_GROUP,
         "--filter-pattern", '"CONFIG_DEPLOY_FAILED"', "--max-items", "5",
         query="events[].{Stream:logStreamName,Message:message}")
    show("경보 설정", "cloudwatch", "describe-alarms", "--alarm-names", "config-deploy-failed",
         query="MetricAlarms[].{State:StateValue,Namespace:Namespace,Metric:MetricName,Statistic:Statistic,"
               "Period:Period,Evaluations:EvaluationPeriods,Threshold:Threshold,Comparison:ComparisonOperator,"
               "Missing:TreatMissingData}")
    show("경보 상태 변경 이력", "cloudwatch", "describe-alarm-history", "--alarm-name",
         "config-deploy-failed", "--history-item-type", "StateUpdate", "--max-items", "15",
         query="AlarmHistoryItems[].{Time:Timestamp,Summary:HistorySummary}")


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
    parser = argparse.ArgumentParser(description="6회 모의고사 교사용 읽기 전용 채점 보조")
    parser.add_argument("task", choices=RUBRICS)
    parser.add_argument("student", help="비번호 1~6자리 숫자")
    parser.add_argument("teacher_scores", nargs="?", help="교사가 확정한 영역별 점수 5개, 쉼표 구분")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]{1,6}", args.student):
        parser.error("비번호는 숫자 1~6자리입니다. (버킷 이름 규칙)")
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
    print(f"2027 지방 모의고사 6회 제{args.task}과제 | 비번호: {args.student}")
    print(f"계정: {account} | 리전: {REGION}")
    print("조회 결과는 교사 실기 채점의 보조 증거입니다. 리소스를 변경하지 않습니다.")
    servers()
    storage(account, args.student)
    document()
    deployment()
    observe()
    if errors:
        print(f"\n[확인 필요] 조회 오류 {errors}건. 누락 증거는 교사가 별도로 확인합니다.")
    if scores is None:
        print("\n실기 점수 미입력. 영역 상한: " + ",".join(str(limit) for _, limit in rubric))
    else:
        print("\n교사 확정 점수")
        for (name, limit), score in zip(rubric, scores):
            print(f"- {name}: {score}/{limit}")
        print(f"TOTAL SCORE: {sum(scores):f}/50")
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
