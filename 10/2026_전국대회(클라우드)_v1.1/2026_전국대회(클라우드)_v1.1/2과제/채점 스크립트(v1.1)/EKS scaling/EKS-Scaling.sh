#!/bin/bash

echo ####################################
echo ####################################
echo ###
echo ###    Module 2 : EKS Scaling (KEDA)
echo ###    채점 항목 5개 / 총 7.5점
echo ####################################
echo ####################################

aws configure set default.region ap-northeast-2

CLUSTER_NAME=wsi-eks
NODEGROUP_NAME=wsi-system
NS=wsi-app
DEPLOY=wsi-worker-app
SA=wsi-worker-sa
SCALEDOBJECT=wsi-keda-scaler
QUEUE_NAME=wsi-task-queue
NODEPOOL=wsi-nodepool
NODECLASS=wsi-nodeclass

aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ap-northeast-2 >/dev/null 2>&1

#######################################################################
echo =====1=====   "[1] EKS Cluster & NodeGroup : status / type / scaling / taint (2.5)"
#######################################################################
aws eks describe-cluster --name ${CLUSTER_NAME} \
    --query "cluster.{Name:name,Status:status}"
aws eks describe-nodegroup --cluster-name ${CLUSTER_NAME} --nodegroup-name ${NODEGROUP_NAME} \
    --query "nodegroup.{Type:instanceTypes,Scaling:scalingConfig,Taints:taints}"
echo

#######################################################################
echo =====2=====   "[2] Deployment : image / IRSA / resources (0.5)"
#######################################################################
kubectl -n ${NS} get deploy ${DEPLOY} -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
kubectl -n ${NS} get sa ${SA} -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'; echo
kubectl -n ${NS} get deploy ${DEPLOY} -o jsonpath='{.spec.template.spec.containers[0].resources}'; echo
echo

#######################################################################
echo =====3=====   "[3] KEDA ScaledObject : target / SQS trigger / min-max (1.5)"
#######################################################################
kubectl -n ${NS} get scaledobject ${SCALEDOBJECT} -o jsonpath='{.spec.scaleTargetRef.name}'; echo
kubectl -n ${NS} get scaledobject ${SCALEDOBJECT} -o jsonpath='{.spec.triggers[0]}'; echo
kubectl -n ${NS} get scaledobject ${SCALEDOBJECT} -o jsonpath='{.spec.minReplicaCount}/{.spec.maxReplicaCount}'; echo
echo

#######################################################################
echo =====4=====   "[4] Karpenter NodePool(c5) / EC2NodeClass (1.5)"
#######################################################################
kubectl get nodepool ${NODEPOOL} -o jsonpath='{.spec.template.spec.requirements}'; echo
kubectl get ec2nodeclass ${NODECLASS} -o jsonpath='{.metadata.name}'; echo
echo

#######################################################################
echo =====5=====   "[5] Scale-out 결과 : pod replicas + Karpenter node ready (1.5)"
#######################################################################
QURL=$(aws sqs get-queue-url --queue-name ${QUEUE_NAME} --query QueueUrl --output text)
aws sqs purge-queue --queue-url ${QURL} 2>/dev/null
sleep 60   # purge cooldown

for i in $(seq 1 200); do
    aws sqs send-message --queue-url ${QURL} --message-body "task-${i}" >/dev/null
done

sleep 300

kubectl -n ${NS} get deploy ${DEPLOY} -o jsonpath='{.status.replicas}'; echo
kubectl get nodes -l karpenter.sh/nodepool=${NODEPOOL} \
    -o jsonpath='{range .items[?(@.status.conditions[-1].type=="Ready")]}{.metadata.name}{"\n"}{end}' \
    | grep -v '^$' | wc -l
kubectl get nodes -l karpenter.sh/nodepool=${NODEPOOL} -o wide 2>/dev/null
echo
