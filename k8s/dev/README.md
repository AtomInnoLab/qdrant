# Qdrant Kubernetes 集群部署

这个目录包含了在Kubernetes上部署Qdrant集群的所有配置文件。

## 文件说明

- `secrets.yml` - API密钥配置
- `headless-service.yml` - Headless Service，用于StatefulSet
- `service.yml` - 普通Service，用于外部访问
- `stateful.yml` - StatefulSet配置，包含3个Qdrant实例
- `ingress.yml` - Ingress配置，用于外部访问
- `deploy.sh` - 自动部署脚本

## 部署步骤

### 1. 准备API密钥

首先需要创建API密钥Secret：

```bash
kubectl create secret generic qdrant-apikey-secret \
  --from-literal=apikey=your-api-key-here \
  -n dev-ns
```

### 2. 修改配置

根据需要修改以下配置：

- `ingress.yml` - 修改域名 `qdrant.dev.example.com` 为你的实际域名
- `stateful.yml` - 修改镜像地址、资源限制等

### 3. 部署集群

使用部署脚本自动部署：

```bash
./deploy.sh
```

或者手动部署：

```bash
# 创建命名空间
kubectl create namespace dev-ns

# 部署所有资源
kubectl apply -f secrets.yml
kubectl apply -f headless-service.yml
kubectl apply -f service.yml
kubectl apply -f stateful.yml
kubectl apply -f ingress.yml
```

### 4. 验证部署

```bash
# 检查Pod状态
kubectl get pods -n dev-ns -l app=qdrant

# 检查服务状态
kubectl get svc -n dev-ns

# 检查Ingress状态
kubectl get ingress -n dev-ns
```

## 集群配置说明

### 集群架构

- **3个Qdrant实例**：qdrant-0, qdrant-1, qdrant-2
- **第一个实例（qdrant-0）**：作为集群的初始leader
- **其他实例**：通过bootstrap连接到qdrant-0

### 端口配置

- **6333** - HTTP API端口
- **6334** - gRPC端口
- **6335** - P2P集群通信端口

### 存储配置

- 使用阿里云SSD云盘（alicloud-disk-ssd）
- 每个实例20GB存储空间
- 持久化存储

## 故障排除

### 常见问题

1. **"First peer should specify its uri"错误**
   - 解决方案：确保第一个peer（qdrant-0）正确设置了URI
   - 检查StatefulSet中的command配置

2. **"qdrant: not found"错误**
   - 解决方案：确保使用正确的可执行文件路径
   - Qdrant可执行文件位于`/qdrant/qdrant`，需要在启动前切换到该目录

3. **Pod无法启动**
   - 检查镜像拉取权限
   - 检查API密钥Secret是否正确创建
   - 检查存储类是否存在

4. **集群无法形成共识**
   - 检查P2P端口（6335）是否正确暴露
   - 检查网络策略是否允许Pod间通信
   - 检查DNS解析是否正常

### 日志查看

```bash
# 查看特定Pod日志
kubectl logs -n dev-ns qdrant-0

# 查看所有Pod日志
kubectl logs -n dev-ns -l app=qdrant
```

## 访问方式

部署完成后，可以通过以下方式访问：

- **Web UI**: http://qdrant.dev.example.com/dashboard
- **API**: http://qdrant.dev.example.com
- **集群内访问**: qdrant-svc.dev-ns.svc.cluster.local:6333

## 扩展集群

要扩展集群到更多实例，修改StatefulSet中的`replicas`字段，并更新相应的配置。
