#!/usr/bin/env python3
"""Round 4 evidence collector. Only AWS read APIs are used."""
import argparse
import json
import re
import subprocess
from decimal import Decimal

REGION = "ap-northeast-2"
RUBRICS = {
    "1": [("네트워크", 10), ("접근 제어", 9), ("배포와 IAM", 9), ("API", 14), ("운영", 8)],
    "2": [("수집", 12), ("워크플로우", 12), ("데이터", 9), ("결과와 IAM", 10), ("운영", 7)],
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


def check(label, passed):
    print(f"[{'O' if passed else 'X'}] {label}")


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


def inspect_network():
    vpcs = show("VPC", "ec2", "describe-vpcs", "--filters", "Name=tag:Name,Values=inspect-vpc",
                query="Vpcs[].{Id:VpcId,CIDR:CidrBlock}")
    if vpcs is None:
        return
    if len(vpcs) != 1:
        print("[확인 필요] inspect-vpc를 정확히 하나 식별해야 네트워크를 조회합니다.")
        return
    vpc = vpcs[0]["Id"]
    filters = ("--filters", f"Name=vpc-id,Values={vpc}")
    subnets = show("서브넷", "ec2", "describe-subnets", *filters,
                   query="Subnets[].{Name:Tags[?Key=='Name'].Value|[0],Id:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,PublicIP:MapPublicIpOnLaunch}")
    show("라우팅 및 연결", "ec2", "describe-route-tables", *filters,
         query="RouteTables[].{Id:RouteTableId,Associated:Associations[].{Subnet:SubnetId,Main:Main},IPv4Default:Routes[?DestinationCidrBlock=='0.0.0.0/0'],IPv6Default:Routes[?DestinationIpv6CidrBlock=='::/0']}")
    show("VPC Endpoint", "ec2", "describe-vpc-endpoints", *filters,
         query="VpcEndpoints[].{Service:ServiceName,Type:VpcEndpointType,State:State,PrivateDNS:PrivateDnsEnabled,Subnets:SubnetIds,Routes:RouteTableIds,Groups:Groups[].GroupId}")
    show("SG 인바운드", "ec2", "describe-security-groups", *filters,
         query="SecurityGroups[].{Name:GroupName,Id:GroupId,Ingress:IpPermissions[].{Protocol:IpProtocol,From:FromPort,To:ToPort,IPv4:IpRanges[].CidrIp,IPv6:Ipv6Ranges[].CidrIpv6,SourceSG:UserIdGroupPairs[].GroupId,PrefixList:PrefixListIds[].PrefixListId}}")
    show("CloudFront 관리형 prefix list", "ec2", "describe-managed-prefix-lists",
         "--filters", "Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing",
         query="PrefixLists[].PrefixListId")
    if subnets is not None:
        expected = {
            ("inspect-pub-a", "10.40.0.0/24", REGION + "a"),
            ("inspect-pub-c", "10.40.1.0/24", REGION + "c"),
            ("inspect-app-a", "10.40.10.0/24", REGION + "a"),
            ("inspect-app-c", "10.40.11.0/24", REGION + "c"),
        }
        actual = {(x["Name"], x["CIDR"], x["AZ"]) for x in subnets}
        check("VPC CIDR 및 지정 서브넷 4개", vpcs[0]["CIDR"] == "10.40.0.0/16" and expected <= actual)


def inspect_origin(alb):
    listeners = show("ALB 리스너", "elbv2", "describe-listeners",
                     "--load-balancer-arn", alb["Arn"],
                     query="Listeners[].{Arn:ListenerArn,Protocol:Protocol,Port:Port,Default:DefaultActions[].{Type:Type,Status:FixedResponseConfig.StatusCode}}")
    header_values = set()
    if listeners is not None:
        for listener in listeners:
            if listener["Protocol"] != "HTTP" or listener["Port"] != 80:
                continue
            rules = aws("ALB 규칙", "elbv2", "describe-rules", "--listener-arn", listener["Arn"],
                        query="Rules[?IsDefault==\x60false\x60].{Priority:Priority,Conditions:Conditions,Actions:Actions[].{Type:Type,Target:TargetGroupArn,WeightedTargets:ForwardConfig.TargetGroups[].TargetGroupArn}}")
            for rule in rules or []:
                headers = [c["HttpHeaderConfig"] for c in rule["Conditions"]
                           if c.get("HttpHeaderConfig", {}).get("HttpHeaderName", "").lower() == "x-inspect-origin"]
                evidence("ALB 규칙 (헤더 값 비공개)", {
                    "priority": rule["Priority"], "condition_types": [c["Field"] for c in rule["Conditions"]],
                    "origin_header": bool(headers), "actions": rule["Actions"]})
                if any(a["Type"] == "forward" for a in rule["Actions"]):
                    header_values.update(value for h in headers for value in h.get("Values", []))
    distributions = aws("CloudFront 배포 목록", "cloudfront", "list-distributions",
                        query="DistributionList.Items[].{Id:Id,Domain:DomainName,OriginDomains:Origins.Items[].DomainName}")
    for dist in distributions or []:
        if alb["DNS"] not in (dist["OriginDomains"] or []):
            continue
        config = aws("CloudFront 배포 설정", "cloudfront", "get-distribution-config", "--id", dist["Id"],
                     query="DistributionConfig")
        if config is None:
            continue
        origins = [o for o in config["Origins"]["Items"] if o["DomainName"] == alb["DNS"]]
        ids = {o["Id"] for o in origins}
        matches = [h["HeaderValue"] for o in origins for h in o.get("CustomHeaders", {}).get("Items", [])
                   if h["HeaderName"].lower() == "x-inspect-origin"]
        behaviors = [config["DefaultCacheBehavior"], *config.get("CacheBehaviors", {}).get("Items", [])]
        evidence("CloudFront (헤더 값 비공개)", {
            "id": dist["Id"], "domain": dist["Domain"], "enabled": config["Enabled"],
            "origin_protocols": [o.get("CustomOriginConfig", {}).get("OriginProtocolPolicy") for o in origins],
            "origin_header_matches_alb": bool(set(matches) & header_values),
            "behaviors": [{"path": b.get("PathPattern", "default"), "viewer": b["ViewerProtocolPolicy"],
                           "methods": b["AllowedMethods"]["Items"], "cache_policy": b.get("CachePolicyId"),
                           "origin_request_policy": b.get("OriginRequestPolicyId")}
                          for b in behaviors if b["TargetOriginId"] in ids]})
        for policy in sorted({b["OriginRequestPolicyId"] for b in behaviors
                              if b["TargetOriginId"] in ids and b.get("OriginRequestPolicyId")}):
            show("Origin Request Policy", "cloudfront", "get-origin-request-policy", "--id", policy,
                 query="OriginRequestPolicy.OriginRequestPolicyConfig.HeadersConfig")
        for policy in sorted({b["CachePolicyId"] for b in behaviors
                              if b["TargetOriginId"] in ids and b.get("CachePolicyId")}):
            show("Cache Policy TTL", "cloudfront", "get-cache-policy", "--id", policy,
                 query="CachePolicy.CachePolicyConfig.{Min:MinTTL,Default:DefaultTTL,Max:MaxTTL}")
    if distributions is not None and not any(alb["DNS"] in (d["OriginDomains"] or []) for d in distributions):
        print("[확인 필요] 지정 ALB DNS를 Origin으로 사용하는 배포를 찾지 못했습니다.")


def task1():
    inspect_network()
    albs = show("ALB", "elbv2", "describe-load-balancers", "--names", "inspect-alb",
                query="LoadBalancers[].{Arn:LoadBalancerArn,DNS:DNSName,Scheme:Scheme,Zones:AvailabilityZones[].{AZ:ZoneName,Subnet:SubnetId},SG:SecurityGroups}")
    for alb in albs or []:
        inspect_origin(alb)
    groups = show("Target Group", "elbv2", "describe-target-groups", "--names", "inspect-api-tg",
                  query="TargetGroups[].{Arn:TargetGroupArn,Type:TargetType,Port:Port,Health:HealthCheckPath,Codes:Matcher.HttpCode}")
    for group in groups or []:
        targets = show("타깃 상태", "elbv2", "describe-target-health", "--target-group-arn", group["Arn"],
                       query="TargetHealthDescriptions[].{Id:Target.Id,AZ:Target.AvailabilityZone,State:TargetHealth.State}")
        if targets is not None:
            zones = {t["AZ"] for t in targets if t["State"] == "healthy" and t["AZ"] not in (None, "all")}
            evidence("조회된 healthy 타깃 AZ", sorted(zones))
    show("ECR 설정", "ecr", "describe-repositories", "--repository-names", "inspect-api",
         query="repositories[].{Name:repositoryName,Tags:imageTagMutability,ScanOnPush:imageScanningConfiguration.scanOnPush}")
    show("ECR v1", "ecr", "describe-images", "--repository-name", "inspect-api", "--image-ids", "imageTag=v1",
         query="imageDetails[].{Tags:imageTags,Digest:imageDigest}")
    services = show("ECS 서비스 및 배포", "ecs", "describe-services", "--cluster", "inspect-cluster",
                    "--services", "inspect-api",
                    query="services[].{Desired:desiredCount,Running:runningCount,Task:taskDefinition,Network:networkConfiguration.awsvpcConfiguration,CircuitBreaker:deploymentConfiguration.deploymentCircuitBreaker,Deployments:deployments[].{Task:taskDefinition,Status:status,Rollout:rolloutState},RecentEvents:events[:8].{Time:createdAt,Message:message}}")
    for service in services or []:
        task = show("Task Definition", "ecs", "describe-task-definition", "--task-definition", service["Task"],
                    query="taskDefinition.{Family:family,CPU:cpu,Memory:memory,Network:networkMode,Compat:requiresCompatibilities,Platform:runtimePlatform,TaskRole:taskRoleArn,ExecutionRole:executionRoleArn,Containers:containerDefinitions[].{Name:name,Image:image,Ports:portMappings[].containerPort,Driver:logConfiguration.logDriver,LogGroup:logConfiguration.options.\"awslogs-group\",EnvironmentNames:environment[].name}}")
        if task:
            role("Task", task["TaskRole"])
            role("Execution", task["ExecutionRole"])
    show("DynamoDB 테이블", "dynamodb", "describe-table", "--table-name", "inspect-records",
         query="Table.{Keys:KeySchema,Types:AttributeDefinitions,Billing:BillingModeSummary.BillingMode}")
    show("DynamoDB PITR", "dynamodb", "describe-continuous-backups", "--table-name", "inspect-records",
         query="ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus")
    retention("/inspect/api")
    alarm("inspect-unhealthy")
    print("[실기] API 응답·동시 요청·실패 revision의 자동 롤백은 채점지 순서로 확인합니다.")


def task2(account, student):
    incoming = f"reconcile-in-{account}-{student}"
    outgoing = f"reconcile-out-{account}-{student}"
    for bucket in [incoming, outgoing]:
        evidence("버킷", bucket)
        scope = ("--bucket", bucket, "--expected-bucket-owner", account)
        show("버전 관리", "s3api", "get-bucket-versioning", *scope, query="Status")
        show("퍼블릭 액세스 차단", "s3api", "get-public-access-block", *scope,
             query="PublicAccessBlockConfiguration")
        policy = aws("버킷 정책", "s3api", "get-bucket-policy", *scope, query="Policy")
        if policy is not None:
            try:
                statements = json.loads(policy).get("Statement", [])
                if isinstance(statements, dict):
                    statements = [statements]
                evidence("TLS 거부 문장 후보", [s for s in statements if s.get("Effect") == "Deny"
                          and str(s.get("Condition", {}).get("Bool", {}).get("aws:SecureTransport")).lower() == "false"])
            except (TypeError, ValueError):
                print("[확인 필요] 버킷 정책 형식")
    notification = aws("S3 알림", "s3api", "get-bucket-notification-configuration",
                       "--bucket", incoming, "--expected-bucket-owner", account)
    if notification is not None:
        check("입력 S3의 EventBridge 알림 활성", "EventBridgeConfiguration" in notification)
    rule_info = show("EventBridge 규칙", "events", "describe-rule", "--name", "reconcile-upload",
                     query="{State:State,Pattern:EventPattern,EventBus:EventBusName}")
    if rule_info:
        targets = show("EventBridge 대상", "events", "list-targets-by-rule", "--rule", "reconcile-upload",
                       query="Targets[].{Arn:Arn,Role:RoleArn}")
        for target in targets or []:
            role("EventBridge", target["Role"])
    machines = show("Step Functions", "stepfunctions", "list-state-machines",
                    query="stateMachines[?name=='reconcile-flow'].{Arn:stateMachineArn,Type:type}")
    for machine in machines or []:
        arn = machine["Arn"]
        flow = show("워크플로우 로그 및 역할", "stepfunctions", "describe-state-machine",
                    "--state-machine-arn", arn, query="{Status:status,Logging:loggingConfiguration,Role:roleArn}")
        if flow:
            role("Step Functions", flow["Role"])
        definition = aws("상태 정의", "stepfunctions", "describe-state-machine", "--state-machine-arn", arn,
                         query="definition")
        if definition:
            states = json.loads(definition).get("States", {})
            for name, state in states.items():
                if state["Type"] == "Map":
                    processor = state.get("ItemProcessor", state.get("Iterator", {}))
                    evidence("Map 및 Retry", {"state": name, "concurrency": state.get("MaxConcurrency"),
                             "mode": processor.get("ProcessorConfig", {}).get("Mode", "INLINE"),
                             "task_retries": {k: v.get("Retry", []) for k, v in processor.get("States", {}).items()
                                              if v["Type"] == "Task"}})
        executions = show("최근 실행 5건", "stepfunctions", "list-executions", "--state-machine-arn", arn,
                          "--max-items", "5", query="executions[].{Arn:executionArn,Status:status,Started:startDate}")
        for execution in executions or []:
            show("실패·재시도 이력 " + execution["Arn"].rsplit(":", 1)[-1],
                 "stepfunctions", "get-execution-history", "--execution-arn", execution["Arn"],
                 "--no-include-execution-data", "--reverse-order", "--max-items", "150",
                 query="events[?type=='TaskFailed'||type=='LambdaFunctionFailed'||type=='ExecutionFailed'].{Time:timestamp,Type:type,TaskError:taskFailedEventDetails.error,LambdaError:lambdaFunctionFailedEventDetails.error,ExecutionError:executionFailedEventDetails.error}")
    for function in ("reconcile-load", "reconcile-apply", "reconcile-report"):
        config = show("Lambda " + function, "lambda", "get-function-configuration", "--function-name", function,
                      query="{Runtime:Runtime,Role:Role,State:State}")
        if config:
            role(function, config["Role"])
    show("정산 테이블", "dynamodb", "describe-table", "--table-name", "reconcile-ledger",
         query="Table.{Keys:KeySchema,Types:AttributeDefinitions,Billing:BillingModeSummary.BillingMode}")
    show("보고서 객체 최대 10건", "s3api", "list-objects-v2", "--bucket", outgoing,
         "--expected-bucket-owner", account, "--prefix", "reports/", "--max-items", "10",
         query="Contents[].{Key:Key,Size:Size,Modified:LastModified}")
    retention("/aws/vendedlogs/states/reconcile-flow")
    alarm("reconcile-execution-failed")
    show("최근 ALARM 전이", "cloudwatch", "describe-alarm-history", "--alarm-name",
         "reconcile-execution-failed", "--history-item-type", "StateUpdate", "--max-items", "20",
         query="AlarmHistoryItems[].{Time:Timestamp,Summary:HistorySummary}")
    print("[실기] 버전 재처리·중복과 충돌·보고서 내용·정책 범위는 채점지 순서로 확인합니다.")


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
    parser = argparse.ArgumentParser(description="4회 모의고사 교사용 읽기 전용 채점 보조")
    parser.add_argument("task", choices=RUBRICS)
    parser.add_argument("student", help="비번호 1~6자리 숫자")
    parser.add_argument("teacher_scores", nargs="?", help="교사가 확정한 영역별 점수 5개, 쉼표 구분")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]{1,6}", args.student):
        parser.error("비번호는 숫자 1~6자리입니다.")
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
    print(f"2027 지방 모의고사 4회 제{args.task}과제 | 비번호: {args.student}")
    print(f"계정: {account} | 리전: {REGION}")
    print("조회 결과는 교사 실기 채점의 보조 증거입니다.")
    if args.task == "1":
        task1()
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
