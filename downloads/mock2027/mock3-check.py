#!/usr/bin/env python3
"""Read-only AWS configuration checks. No credentials or response bodies printed."""
import json
import os
import re
import subprocess
import sys

REGION = "ap-northeast-2"
os.environ["AWS_PAGER"] = ""
os.environ["AWS_CLI_AUTO_PROMPT"] = "off"

def aws(service, command, **kwargs):
    args = ["aws", service, command, "--region", REGION, "--output", "json", "--no-cli-pager"]
    for key, value in kwargs.items():
        args.append("--" + key.replace("_", "-"))
        if isinstance(value, bool):
            args.pop()
            args.append("--" + ("" if value else "no-") + key.replace("_", "-"))
        elif isinstance(value, (dict, list)):
            args.append(json.dumps(value))
        else:
            args.append(str(value))
    result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if result.returncode:
        code = re.search(r"\(([^)]+)\)", result.stderr)
        code = code.group(1) if code else "CLI_ERROR"
        if code in {"ResourceNotFoundException", "NoSuchEntity", "NoSuchBucket",
                    "QueueDoesNotExist", "AWS.SimpleQueueService.NonExistentQueue",
                    "NoSuchBucketPolicy", "NoSuchPublicAccessBlockConfiguration",
                    "RepositoryNotFoundException", "ImageNotFoundException", "ClusterNotFoundException",
                    "LoadBalancerNotFound", "TargetGroupNotFound", "DashboardNotFoundError"}:
            return {}
        raise RuntimeError(code)
    return json.loads(result.stdout or "{}")

def first(items):
    return next(iter(items), {})

def statements(policy):
    p = json.loads(policy) if isinstance(policy, str) else policy
    s = p.get("Statement", [])
    return s if isinstance(s, list) else [s]

score = 0
errors = 0
count = 0
def check(label, fn):
    global score, errors, count
    count += 1
    try:
        ok = bool(fn())
        score += 2 if ok else 0
        print(("PASS" if ok else "FAIL") + " | " + label + " | " + ("2/2" if ok else "0/2"))
    except Exception as exc:
        errors += 1
        # Do not print AWS response bodies, account details or secret values.
        print("ERROR | " + label + " | " + type(exc).__name__ + " (API/permission/config inspection failed)")

def task1():
    def network():
        v = first(aws("ec2", "describe-vpcs", filters=[{"Name":"tag:Name","Values":["docs-vpc"]}]).get("Vpcs", []))
        return v
    check("VPC CIDR", lambda: network().get("CidrBlock") == "10.30.0.0/16")
    def subnets():
        v = network()
        return aws("ec2", "describe-subnets", filters=[{"Name":"vpc-id","Values":[v["VpcId"]]}]).get("Subnets", []) if v else []
    expected = {("10.30.0.0/24","ap-northeast-2a"), ("10.30.1.0/24","ap-northeast-2c"),
                ("10.30.10.0/24","ap-northeast-2a"), ("10.30.11.0/24","ap-northeast-2c")}
    check("Four subnet CIDRs/AZs", lambda: expected <= {(s["CidrBlock"],s["AvailabilityZone"]) for s in subnets()})
    def nats():
        v=network()
        if not v: return False
        ns=aws("ec2","describe-nat-gateways",filter=[{"Name":"vpc-id","Values":[v["VpcId"]]}]).get("NatGateways",[])
        public={s["SubnetId"] for s in subnets() if s["CidrBlock"] in {"10.30.0.0/24","10.30.1.0/24"}}
        return len(public)==2 and public <= {n["SubnetId"] for n in ns if n["State"]=="available" and n.get("ConnectivityType")=="public"}
    check("Public NAT in each AZ", nats)
    def endpoint():
        v=network()
        if not v: return False
        private={s["SubnetId"] for s in subnets() if s["CidrBlock"] in {"10.30.10.0/24","10.30.11.0/24"}}
        rts=aws("ec2","describe-route-tables",filters=[{"Name":"vpc-id","Values":[v["VpcId"]]}]).get("RouteTables",[])
        ids={r["RouteTableId"] for r in rts if any(a.get("SubnetId") in private for a in r.get("Associations",[]))}
        eps=aws("ec2","describe-vpc-endpoints",filters=[{"Name":"vpc-id","Values":[v["VpcId"]]}]).get("VpcEndpoints",[])
        return len(ids)==2 and any(e.get("State")=="available" and e.get("VpcEndpointType")=="Gateway" and e.get("ServiceName")=="com.amazonaws.ap-northeast-2.dynamodb" and ids <= set(e.get("RouteTableIds",[])) for e in eps)
    check("DynamoDB endpoint associations", endpoint)
    def table():
        return aws("dynamodb","describe-table",table_name="docs-table").get("Table",{})
    check("DynamoDB PK and on-demand", lambda: table().get("KeySchema")==[{"AttributeName":"doc_id","KeyType":"HASH"}] and {"AttributeName":"doc_id","AttributeType":"S"} in table().get("AttributeDefinitions",[]) and table().get("BillingModeSummary",{}).get("BillingMode")=="PAY_PER_REQUEST")
    check("PITR",lambda: aws("dynamodb","describe-continuous-backups",table_name="docs-table").get("ContinuousBackupsDescription",{}).get("PointInTimeRecoveryDescription",{}).get("PointInTimeRecoveryStatus")=="ENABLED")
    def ecr():
        r=first(aws("ecr","describe-repositories",repository_names=["docs-api"]).get("repositories",[]))
        images=aws("ecr","list-images",repository_name="docs-api").get("imageIds",[]) if r else []
        return r.get("imageTagMutability")=="IMMUTABLE" and r.get("imageScanningConfiguration",{}).get("scanOnPush") is True and any(i.get("imageTag")=="v1" for i in images)
    check("ECR immutable/scan/v1",ecr)
    def service():
        return first(aws("ecs","describe-services",cluster="docs-cluster",services=["docs-api"]).get("services",[]))
    def service_ok():
        s=service(); n=s.get("networkConfiguration",{}).get("awsvpcConfiguration",{})
        p={x["SubnetId"] for x in subnets() if x["CidrBlock"] in {"10.30.10.0/24","10.30.11.0/24"}}
        return s.get("status")=="ACTIVE" and s.get("launchType")=="FARGATE" and s.get("desiredCount")==2 and s.get("runningCount",0)>=2 and len(p)==2 and set(n.get("subnets",[]))==p and n.get("assignPublicIp")=="DISABLED"
    check("Service and private placement",service_ok)
    def td():
        s=service()
        return aws("ecs","describe-task-definition",task_definition=s["taskDefinition"]).get("taskDefinition",{}) if s else {}
    check("Task Fargate sizing/platform",lambda: "FARGATE" in td().get("requiresCompatibilities",[]) and td().get("networkMode")=="awsvpc" and td().get("cpu")=="256" and td().get("memory")=="512" and td().get("runtimePlatform",{}).get("cpuArchitecture","X86_64")=="X86_64" and td().get("runtimePlatform",{}).get("operatingSystemFamily","LINUX")=="LINUX" and service().get("deploymentConfiguration",{}).get("deploymentCircuitBreaker")=={"enable":True,"rollback":True})
    def container():
        return first(c for c in td().get("containerDefinitions",[]) if c.get("name")=="api")
    check("Container port/env",lambda: any(p.get("containerPort")==8080 for p in container().get("portMappings",[])) and {"TABLE_NAME":"docs-table","AWS_REGION":REGION}.items() <= {e["name"]:e["value"] for e in container().get("environment",[])}.items() and container().get("image","").endswith("/docs-api:v1"))
    def alb():
        return first(aws("elbv2","describe-load-balancers",names=["docs-alb"]).get("LoadBalancers",[]))
    def tg():
        return first(aws("elbv2","describe-target-groups",names=["docs-api-tg"]).get("TargetGroups",[]))
    def listener():
        a=alb(); t=tg()
        ls=aws("elbv2","describe-listeners",load_balancer_arn=a["LoadBalancerArn"]).get("Listeners",[]) if a else []
        return a.get("Scheme")=="internet-facing" and a.get("Type")=="application" and t and any(l.get("Port")==80 and l.get("Protocol")=="HTTP" and any(x.get("Type")=="forward" and (x.get("TargetGroupArn")==t["TargetGroupArn"] or any(g.get("TargetGroupArn")==t["TargetGroupArn"] for g in x.get("ForwardConfig",{}).get("TargetGroups",[]))) for x in l.get("DefaultActions",[])) for l in ls) and any(x.get("targetGroupArn")==t["TargetGroupArn"] and x.get("containerName")=="api" and x.get("containerPort")==8080 for x in service().get("loadBalancers",[]))
    check("ALB listener/service target group",listener)
    def healthy():
        t=tg()
        h=aws("elbv2","describe-target-health",target_group_arn=t["TargetGroupArn"]).get("TargetHealthDescriptions",[]) if t else []
        return t.get("TargetType")=="ip" and t.get("Port")==8080 and t.get("HealthCheckPath")=="/health" and t.get("Matcher",{}).get("HttpCode")=="200" and sum(x.get("TargetHealth",{}).get("State")=="healthy" for x in h)>=2
    check("Target health",healthy)
    def logs():
        c=container().get("logConfiguration",{})
        gs=aws("logs","describe-log-groups",log_group_name_prefix="/skillsdocs/api").get("logGroups",[])
        return c.get("logDriver")=="awslogs" and c.get("options",{}).get("awslogs-group")=="/skillsdocs/api" and c.get("options",{}).get("awslogs-stream-prefix")=="ecs" and any(g["logGroupName"]=="/skillsdocs/api" and g.get("retentionInDays")==7 for g in gs)
    check("awslogs and retention",logs)
    def scaling():
        rid="service/docs-cluster/docs-api"
        ts=aws("application-autoscaling","describe-scalable-targets",service_namespace="ecs",resource_ids=[rid]).get("ScalableTargets",[])
        ps=aws("application-autoscaling","describe-scaling-policies",service_namespace="ecs",resource_id=rid,scalable_dimension="ecs:service:DesiredCount").get("ScalingPolicies",[])
        return any(t.get("MinCapacity")==2 and t.get("MaxCapacity")==4 for t in ts) and any(p.get("PolicyType")=="TargetTrackingScaling" and (c:=p.get("TargetTrackingScalingPolicyConfiguration",{})).get("TargetValue")==60 and c.get("PredefinedMetricSpecification",{}).get("PredefinedMetricType")=="ECSServiceAverageCPUUtilization" and c.get("ScaleInCooldown")==60 and c.get("ScaleOutCooldown")==60 for p in ps)
    check("CPU target tracking",scaling)
    def alarm():
        a=first(aws("cloudwatch","describe-alarms",alarm_names=["docs-api-5xx"]).get("MetricAlarms",[]))
        lb=alb(); t=tg()
        dims={x["Name"]:x["Value"] for x in a.get("Dimensions",[])}
        return lb and t and a.get("Namespace")=="AWS/ApplicationELB" and a.get("MetricName")=="HTTPCode_Target_5XX_Count" and a.get("Statistic")=="Sum" and a.get("Period")==60 and a.get("EvaluationPeriods")==1 and a.get("DatapointsToAlarm",1)==1 and a.get("Threshold")==5 and a.get("ComparisonOperator")=="GreaterThanOrEqualToThreshold" and a.get("TreatMissingData")=="notBreaching" and dims=={"LoadBalancer":lb["LoadBalancerArn"].split(":loadbalancer/")[1],"TargetGroup":t["TargetGroupArn"].split(":")[-1]}
    check("5xx alarm",alarm)

def task2(number, account):
    bucket="docs-inbox-"+account+"-"+number
    def queue(name):
        u=aws("sqs","get-queue-url",queue_name=name).get("QueueUrl")
        return aws("sqs","get-queue-attributes",queue_url=u,attribute_names=["All"]).get("Attributes",{}) if u else {}
    def bucket_ok():
        b=aws("s3api","get-public-access-block",bucket=bucket).get("PublicAccessBlockConfiguration",{})
        return all(b.get(k) is True for k in ["BlockPublicAcls","IgnorePublicAcls","BlockPublicPolicy","RestrictPublicBuckets"]) and aws("s3api","get-bucket-versioning",bucket=bucket).get("Status")=="Enabled"
    check("S3 private/versioned",bucket_ok)
    def notifications():
        q=queue("docs-events")
        ns=aws("s3api","get-bucket-notification-configuration",bucket=bucket).get("QueueConfigurations",[])
        return q and any(n.get("QueueArn")==q.get("QueueArn") and "s3:ObjectCreated:*" in n.get("Events",[]) and {x["Name"].lower():x["Value"] for x in n.get("Filter",{}).get("Key",{}).get("FilterRules",[])}=={"prefix":"incoming/","suffix":".json"} for n in ns)
    check("S3 queue notification/filter",notifications)
    check("Source queue visibility/SSE",lambda: (q:=queue("docs-events")) and q.get("VisibilityTimeout")=="180" and q.get("SqsManagedSseEnabled")=="true" and q.get("FifoQueue","false")=="false")
    def redrive():
        q=queue("docs-events"); d=queue("docs-events-dlq")
        p=json.loads(q.get("RedrivePolicy","{}"))
        return d and d.get("MessageRetentionPeriod")=="1209600" and d.get("SqsManagedSseEnabled")=="true" and d.get("FifoQueue","false")=="false" and p.get("deadLetterTargetArn")==d.get("QueueArn") and str(p.get("maxReceiveCount"))=="3"
    check("DLQ/redrive",redrive)
    check("Lambda runtime/env",lambda: (l:=aws("lambda","get-function-configuration",function_name="docs-indexer")) and l.get("Runtime")=="python3.12" and l.get("Timeout")==30 and l.get("MemorySize")==128 and l.get("Environment",{}).get("Variables",{}).get("TABLE_NAME")=="docs-index")
    def mapping():
        q=queue("docs-events")
        return q and any(m.get("EventSourceArn")==q["QueueArn"] and m.get("State")=="Enabled" and m.get("BatchSize")==5 and m.get("MaximumBatchingWindowInSeconds",0)==0 and "ReportBatchItemFailures" in m.get("FunctionResponseTypes",[]) for m in aws("lambda","list-event-source-mappings",function_name="docs-indexer").get("EventSourceMappings",[]))
    check("SQS mapping/partial failures",mapping)
    def source():
        t=aws("dynamodb","describe-table",table_name="docs-index").get("Table",{})
        p=aws("dynamodb","describe-continuous-backups",table_name="docs-index").get("ContinuousBackupsDescription",{})
        return t.get("KeySchema")==[{"AttributeName":"object_key","KeyType":"HASH"}] and {"AttributeName":"object_key","AttributeType":"S"} in t.get("AttributeDefinitions",[]) and t.get("BillingModeSummary",{}).get("BillingMode")=="PAY_PER_REQUEST" and p.get("PointInTimeRecoveryDescription",{}).get("PointInTimeRecoveryStatus")=="ENABLED"
    check("Source table/PK/on-demand/PITR",source)
    check("Available checkpoint backup",lambda: any(b.get("BackupName")=="docs-index-checkpoint" and b.get("BackupStatus")=="AVAILABLE" for b in aws("dynamodb","list-backups",table_name="docs-index").get("BackupSummaries",[])))
    def restored():
        t=aws("dynamodb","describe-table",table_name="docs-index-restore").get("Table",{})
        return t.get("TableStatus")=="ACTIVE" and t.get("KeySchema")==[{"AttributeName":"object_key","KeyType":"HASH"}] and {"AttributeName":"object_key","AttributeType":"S"} in t.get("AttributeDefinitions",[])
    check("Restore table active/PK",restored)
    check("Uploader role exists",lambda: aws("iam","get-role",role_name="docs-uploader").get("Role",{}).get("RoleName")=="docs-uploader")
    def tls():
        p=aws("s3api","get-bucket-policy",bucket=bucket).get("Policy","{}")
        resources={"arn:aws:s3:::"+bucket,"arn:aws:s3:::"+bucket+"/*"}
        for s in statements(p):
            rs=s.get("Resource",[]); rs=[rs] if isinstance(rs,str) else rs
            ac=s.get("Action",[]); ac=[ac] if isinstance(ac,str) else ac
            cond=s.get("Condition",{}).get("Bool",{}).get("aws:SecureTransport")
            if s.get("Effect")=="Deny" and s.get("Principal") in ("*",{"AWS":"*"}) and "s3:*" in ac and resources <= set(rs) and cond in ("false",False):
                return True
        return False
    check("TLS deny policy structure",tls)
    check("Lambda log retention",lambda: any(g.get("logGroupName")=="/aws/lambda/docs-indexer" and g.get("retentionInDays")==14 for g in aws("logs","describe-log-groups",log_group_name_prefix="/aws/lambda/docs-indexer").get("logGroups",[])))
    def alarm():
        return first(aws("cloudwatch","describe-alarms",alarm_names=["docs-dlq-visible"]).get("MetricAlarms",[]))
    check("DLQ alarm metric/settings",lambda: (a:=alarm()) and a.get("Namespace")=="AWS/SQS" and a.get("MetricName")=="ApproximateNumberOfMessagesVisible" and a.get("Statistic")=="Maximum" and a.get("Period")==60 and a.get("EvaluationPeriods")==1 and a.get("DatapointsToAlarm",1)==1 and a.get("Threshold")==1 and a.get("ComparisonOperator")=="GreaterThanOrEqualToThreshold" and a.get("TreatMissingData")=="notBreaching" and a.get("Dimensions")==[{"Name":"QueueName","Value":"docs-events-dlq"}])
    check("SNS alarm action",lambda: "arn:aws:sns:"+REGION+":"+account+":docs-ops-alerts" in alarm().get("AlarmActions",[]) and any(t.get("TopicArn")=="arn:aws:sns:"+REGION+":"+account+":docs-ops-alerts" for t in aws("sns","list-topics").get("Topics",[])))
    def dashboard():
        d=aws("cloudwatch","get-dashboard",dashboard_name="docs-ops")
        widgets=json.loads(d.get("DashboardBody","{}")).get("widgets",[])
        needed=[["AWS/Lambda","Errors","FunctionName","docs-indexer"],["AWS/SQS","ApproximateNumberOfMessagesVisible","QueueName","docs-events-dlq"]]
        found=[False,False]
        for w in widgets:
            p=w.get("properties",{})
            if w.get("type")!="metric" or p.get("region")!=REGION: continue
            for m in p.get("metrics",[]):
                for i,n in enumerate(needed):
                    if m[:4]==n and (m[-1].get("stat",p.get("stat","Average")) if isinstance(m[-1],dict) else p.get("stat","Average"))==("Sum" if i==0 else "Maximum"):
                        found[i]=True
        return all(found)
    check("Dashboard metrics/dimensions/stat",dashboard)

def main():
    global errors
    if len(sys.argv) not in (3,4) or sys.argv[1] not in ("1","2") or not re.fullmatch(r"[0-9]{1,6}",sys.argv[2]):
        print("Usage: python3 mock3-check.py <1|2> <studentNo> [teacher-rubric-scores]")
        return 2
    task, number=sys.argv[1:3]
    maxima=[4,4,6,4,2] if task=="1" else [8,4,6,2]
    manual=None
    if len(sys.argv)==4:
        parts=sys.argv[3].split(",")
        if len(parts)!=len(maxima) or any(not x.isdigit() or int(x)>m for x,m in zip(parts,maxima)):
            print("Invalid teacher scores. Per-category maxima: "+",".join(map(str,maxima)))
            return 2
        manual=sum(map(int,parts))
    try:
        account=aws("sts","get-caller-identity")["Account"]
    except Exception:
        print("ERROR: AWS identity/CLI unavailable; no score produced.")
        return 2
    print("MOCK3 TASK "+task+" | student "+number+" | region "+REGION)
    print("계정: "+account)
    print("READ-ONLY configuration checks; teacher evidence required for practical marks.")
    if task=="1": task1()
    else: task2(number,account)
    print("AUTO SCORE: "+str(score)+"/30")
    if count!=15:
        print("ERROR: internal rubric count mismatch")
        return 2
    if errors:
        print("INCOMPLETE: "+str(errors)+" checks errored; resolve before submission.")
        return 2
    if manual is None:
        print("PRACTICAL: pending teacher assessment; TOTAL SCORE not finalized.")
    else:
        print("TEACHER RUBRIC: "+sys.argv[3]+" | evidence must be reviewed by teacher")
        print("MANUAL SCORE: "+str(manual)+"/20")
        print("TOTAL SCORE: "+str(score+manual)+"/50")
    return 0

if __name__=="__main__":
    sys.exit(main())
