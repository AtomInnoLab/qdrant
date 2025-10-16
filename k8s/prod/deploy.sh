#!/bin/bash

# Qdrant集群部署脚本
set -e

echo "开始部署Qdrant集群..."

# 创建命名空间（如果不存在）
echo "创建命名空间 prod-ns..."
kubectl create namespace prod-ns --dry-run=client -o yaml | kubectl apply -f -

# 部署secrets
echo "部署API密钥..."
kubectl apply -f secrets.yml

# 部署headless service
echo "部署headless service..."
kubectl apply -f headless-service.yml

# 部署普通service
echo "部署service..."
kubectl apply -f service.yml

# 部署StatefulSet
echo "部署StatefulSet..."
kubectl apply -f stateful.yml

# 部署Ingress
echo "部署Ingress..."
kubectl apply -f ingress.yml

echo "等待Pod启动..."
kubectl wait --for=condition=ready pod -l app=qdrant-prod -n prod-ns --timeout=300s

echo "检查Pod状态..."
kubectl get pods -n prod-ns -l app=qdrant-prod

echo "检查服务状态..."
kubectl get svc -n prod-ns

echo "Qdrant集群部署完成！"
echo "Web UI地址: http://qdrant.atominnolab.com/dashboard"
echo "gRPC API地址: https://qdrant.atominnolab.com:443"
