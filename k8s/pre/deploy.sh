#!/bin/bash

# Qdrant集群部署脚本（pre 环境）
set -e

echo "开始部署Qdrant集群（pre 环境）..."

# 创建命名空间（如果不存在）
echo "创建命名空间 pre..."
kubectl create namespace pre --dry-run=client -o yaml | kubectl apply -f -

# 部署secrets
echo "部署API密钥..."
kubectl apply -f secrets.yml

# 部署headless service
echo "部署headless service..."
kubectl apply -f headless-service.yml

# 部署StatefulSet
echo "部署StatefulSet..."
kubectl apply -f stateful.yml

# 部署Ingress
echo "部署Ingress..."
kubectl apply -f ingress.yml

echo "等待Pod启动..."
kubectl wait --for=condition=ready pod -l app=qdrant -n pre --timeout=300s

echo "检查Pod状态..."
kubectl get pods -n pre -l app=qdrant

echo "检查服务状态..."
kubectl get svc -n pre

echo "Qdrant集群部署完成！"
echo "外部 gRPC API: https://qdrant-pre.atominnolab.com:443"
echo "内部域名: http://qdrant.wispaperpre.inner"
echo "集群内访问: http://qdrant-headless.pre.svc.cluster.local:6333"
