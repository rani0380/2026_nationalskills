#!/bin/bash

echo =====3-1=====
C="wsc2026-logging-cluster"; N="wsc2026-logging"; OC="wsc2026-otel-collector-opentelemetry-collector"
aws eks update-kubeconfig --name $C --region ap-northeast-1 2>/dev/null
kubectl get deploy -n wsc2026-app --no-headers 2>/dev/null | awk '{print $1, $2}'
LB=$(kubectl get svc log-generator -n wsc2026-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
curl -s "http://$LB/health" 2>/dev/null; echo
echo

echo =====3-2=====
echo -n "FluentBit: "; kubectl get pods -n $N -l app.kubernetes.io/name=fluent-bit --no-headers 2>/dev/null | grep -c "Running"
echo -n "Nodes: "; kubectl get nodes --no-headers 2>/dev/null | wc -l
echo

echo =====3-3=====
echo -n "OTel Collector: "; kubectl get pods -n $N -l app.kubernetes.io/name=opentelemetry-collector --no-headers 2>/dev/null | grep -c "Running"
kubectl logs -n $N deploy/$OC --tail=50 2>/dev/null | grep -o 'log records": [0-9]*' | tail -1
echo

echo =====3-4=====
echo -n "Loki: "; kubectl get pods -n $N -l app.kubernetes.io/name=loki --no-headers 2>/dev/null | grep -c "Running"
echo -n "Labels: "; kubectl exec deploy/wsc2026-prometheus-server -n $N -c prometheus-server -- wget -qO- "http://wsc2026-loki.$N.svc.cluster.local:3100/loki/api/v1/labels" 2>/dev/null | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null
echo

echo =====3-5=====
curl -s "http://$LB/burst?count=20&level=INFO" >/dev/null
curl -s "http://$LB/burst?count=10&level=WARN" >/dev/null
curl -s "http://$LB/burst?count=5&level=ERROR" >/dev/null
sleep 15
echo -n "Prometheus: "; kubectl get pods -n $N -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c "Running"
kubectl exec deploy/wsc2026-prometheus-server -n $N -c prometheus-server -- \
wget -qO- "http://localhost:9090/api/v1/query?query=log_record_count_total" \
2>/dev/null | python3 -c "import sys,json;r=json.load(sys.stdin);print('Metrics: '+str(len(r['data']['result'])))" 2>/dev/null
echo

echo =====3-6=====
GF=$(kubectl get svc wsc2026-grafana -n $N -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
echo "Datasources:"
curl -s -u admin:Skill53@@ "http://$GF/api/datasources" 2>/dev/null | python3 -c "import sys,json;[print('  '+d['name']+' ('+d['type']+')') for d in json.load(sys.stdin)]" 2>/dev/null
echo "Dashboards:"
curl -s -u admin:Skill53@@ "http://$GF/api/search?query=wsc2026" 2>/dev/null | python3 -c "import sys,json;[print('  '+d['title']) for d in json.load(sys.stdin)]" 2>/dev/null
echo

echo =====3-7=====
echo "[수동] http://$GF (admin/Skill53@@)"
echo "Dashboard: wsc2026-app-logs"
echo "생성로그: Info Count=20 Warn Count=10 Error Count=5"
echo "채점기준표 가이드에 따라 채점합니다."
echo
