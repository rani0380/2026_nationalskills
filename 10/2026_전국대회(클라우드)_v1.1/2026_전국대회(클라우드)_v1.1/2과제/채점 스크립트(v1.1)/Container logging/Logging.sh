#=================================================
echo "2-1"
aws ec2 describe-vpcs --region  p-southeast-2 --filters "Name=tag:Name,Values=wsc2026-logging-vpc" --query "Vpcs[0].CidrBlock" --output text | grep "10.0.0.0/16"
#=================================================

#=================================================
echo "2-2"
aws ec2 describe-subnets --region ap-southeast-2 --filters "Name=tag:Name,Values=wsc2026-logging-public-subnet-a" --query "Subnets[0].CidrBlock" --output text | grep "10.0.1.0/24"
aws ec2 describe-subnets --region ap-southeast-2 --filters "Name=tag:Name,Values=wsc2026-logging-private-subnet-c" --query "Subnets[0].CidrBlock" --output text | grep "10.0.4.0/24"
aws ec2 describe-route-tables --region ap-southeast-2 --filters "Name=tag:Name,Values=wsc2026-public-routing-table" --query "RouteTables[0].Tags"
aws ec2 describe-nat-gateways | grep wsc2026-logging-internet-gateway
#=================================================

#=================================================
echo "2-3"
aws eks describe-cluster --region ap-southeast-2 --name wsc2026-logging-cluster --query "cluster.status" --output text | grep "ACTIVE"
#=================================================

#=================================================
echo "2-4"
kubectl get po -A | grep fluent-bit
kubectl get po -n logging | grep loki
kubectl get po -n logging | grep grafana
kubectl get po -n logging | grep nginx
#=================================================

#=================================================
echo "2-5"
aws elbv2 describe-load-balancers --names wsc2026-logging-alb --query "LoadBalancers[].DNSName" --output text
#=================================================

#=================================================
echo "2-6"
echo "브라우저에서 진행"
#=================================================