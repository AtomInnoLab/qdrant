# Qdrant Kubernetes 集群部署（prod 环境）

该目录包含在 Kubernetes 上部署 Qdrant 集群（prod 环境）的所有清单与脚本。

## 文件说明

- `secrets.yml`：API 密钥配置（注入到 `QDRANT__SERVICE__API_KEY`）
- `headless-service.yml`：Headless Service，供 `StatefulSet` 内部发现与 P2P 通信
- `service.yml`：ClusterIP Service，对外暴露 HTTP API（由 Ingress 入口）
- `stateful.yml`：StatefulSet 配置，3 副本集群，开放 6333/6334/6335 端口
- `ingress.yml`：Ingress（ALB），域名与 TLS 终止配置
- `deploy.sh`：一键部署脚本

## 部署前置

- 已在 Kubernetes 集群安装并启用 ALB Ingress Controller。
- 已在 DNS 中将 `qdrant.atominnolab.com` 指向 ALB。
- 已在集群中准备好 TLS Secret：`ssl.atominnotab.com`（请确认 Secret 名称与证书资源一致）。

提示：`ingress.yml` 中当前配置为：
- 域名：`qdrant.atominnolab.com`
- TLS Secret：`ssl.atominnotab.com`

如需变更，请同步修改 `ingress.yml` 中 `spec.rules[0].host`、`spec.tls[0].hosts` 与 `spec.tls[0].secretName`。

## 部署步骤

### 1) 准备 API 密钥 Secret

推荐使用 `stringData`，避免手动 base64 和换行符问题：

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: qdrant-apikey-secret-prod
  namespace: prod-ns
type: Opaque
stringData:
  apikey: your-api-key-here
```

应用：
```bash
kubectl apply -f secrets.yml
```

若坚持使用 `data`，请确保 base64 编码不带换行：
```bash
echo -n 'your-api-key-here' | base64
# 将输出替换到 secrets.yml 的 data.apikey 中
```

### 2) 修改配置（如需）

- `ingress.yml`：域名、TLS Secret
- `stateful.yml`：镜像、资源、存储类、节点选择器等
  - 副本数：`replicas: 3`
  - 端口：HTTP 6333、gRPC 6334、P2P 6335
  - 环境变量：
    - `QDRANT__SERVICE__API_KEY`（来自 Secret）
    - `QDRANT__CLUSTER__ENABLED=true`
    - `QDRANT__CLUSTER__HOST`（Pod IP）
  - 存储：`storageClassName: alicloud-disk-ssd`，请求 `20Gi`

### 3) 部署

一键脚本：
```bash
./deploy.sh
```

或手动：
```bash
kubectl create namespace prod-ns --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f secrets.yml
kubectl apply -f headless-service.yml
kubectl apply -f service.yml
kubectl apply -f stateful.yml
kubectl apply -f ingress.yml
```

### 4) 验证

```bash
kubectl get pods -n prod-ns -l app=qdrant-prod
kubectl get svc -n prod-ns
kubectl get ingress -n prod-ns
```

## 访问方式

### 外部访问（通过 Ingress）
- gRPC API: `https://qdrant.atominnolab.com:443`（仅支持 gRPC 协议）

### 集群内访问
- HTTP API: `http://qdrant-svc-prod.prod-ns.svc.cluster.local:6333`
- gRPC API: `http://qdrant-svc-prod.prod-ns.svc.cluster.local:6334`
- Web Dashboard: `http://qdrant-svc-prod.prod-ns.svc.cluster.local:6333/dashboard`

**注意**：
- Ingress 只代理 gRPC 服务（端口 6334），不提供 HTTP API 和 Web Dashboard 的外部访问
- HTTP API 和 Web Dashboard 只能在集群内部访问
- 首次访问 Web Dashboard 时，输入与服务端一致的 API Key（即 `Secret` 中的值）

## 调用示例

### 集群内访问（HTTP API）

```bash
# 使用 API Key（集群内访问）
curl -H 'api-key: your-api-key-here' http://qdrant-svc-prod.prod-ns.svc.cluster.local:6333/cluster
```

### 外部访问（gRPC）

```bash
# 列出所有可用的 gRPC 服务（外部访问）
grpcurl -H "api-key: sk-eXr5+cVKlbWhorfIn4ckRA" qdrant.atominnolab.com:443 list

# 输出示例：
# grpc.health.v1.Health
# qdrant.Collections
# qdrant.Points
# qdrant.Qdrant
# qdrant.Snapshots
```

### 集群内访问（gRPC）

```bash
# 集群内 gRPC 访问
grpcurl -H "api-key: sk-eXr5+cVKlbWhorfIn4ckRA" qdrant-svc-prod.prod-ns.svc.cluster.local:6334 list
```

- 使用 JWT（可选）：若使用 `Authorization: Bearer <token>`，则 `<token>` 必须是由服务端同一密钥（HS256）签发的 JWT
```bash
curl -H 'Authorization: Bearer <your-jwt-token>' https://qdrant.atominnolab.com/cluster
```

常见错误与提示：
- 返回 `Invalid API key or JWT`：说明请求头不正确，或密钥/Token 不匹配。
  - 使用 `api-key` 头而不是 `Authorization: Bearer sk-...`（后者会被当作 JWT 解析）。
  - 确保 `Secret` 未引入换行符（`stringData` 推荐；若用 base64，请用 `echo -n`）。

## 故障排除

1) Pod 启动失败
- 检查镜像拉取、`Secret` 是否存在、存储类是否可用。

2) 集群未形成
- 确认 P2P 端口 6335 与 Headless Service 工作正常，DNS 可解析 `qdrant-prod-0.qdrant-headless-prod.prod-ns.svc.cluster.local`。

3) 401/认证失败
- 校验 `Secret` 值与请求头完全一致；修正后执行：
```bash
kubectl rollout restart statefulset/qdrant-prod -n prod-ns
```

4) 集群内自测
```bash
# HTTP API 测试
kubectl -n prod-ns exec -it qdrant-prod-0 -- \
  curl -s -i -H 'api-key: your-api-key-here' http://qdrant-svc-prod.prod-ns.svc.cluster.local:6333/cluster

# gRPC API 测试（需要安装 grpcurl）
kubectl -n prod-ns exec -it qdrant-prod-0 -- \
  grpcurl -H "api-key: your-api-key-here" qdrant-svc-prod.prod-ns.svc.cluster.local:6334 list
```

## 扩容

修改 `stateful.yml` 的 `spec.replicas` 后应用：
```bash
kubectl apply -f stateful.yml
```

### 增加 Qdrant 集群节点（例如：3 -> 5）

方式一：编辑清单
1) 修改 `stateful.yml`：
```yaml
spec:
  replicas: 5
```
2) 应用并等待滚动完成：
```bash
kubectl apply -f stateful.yml
kubectl rollout status statefulset/qdrant-prod -n prod-ns --timeout=10m
```

方式二：直接伸缩命令
```bash
kubectl scale statefulset qdrant-prod -n prod-ns --replicas=5
kubectl rollout status statefulset/qdrant-prod -n prod-ns --timeout=10m
```

验证：
```bash
kubectl -n prod-ns get pods -l app=qdrant-prod -o wide
kubectl -n prod-ns logs qdrant-prod-3 --tail=100  # 新增 Pod 的日志
kubectl -n prod-ns logs qdrant-prod-4 --tail=100
```

注意：
- 新增副本会以相同启动参数加入集群，`qdrant-prod-0` 作为 bootstrap 节点即可完成拉起与共识。
- 请确保节点资源充足（CPU/内存/磁盘），必要时先执行"新增节点（ACK 节点池）"或"升级实例规格"。
- 集群扩容后，数据与分片的再平衡可能需要时间，期间查询/写入可正常进行但整体抖动取决于数据量与网络带宽。

## 阿里云 ACK 扩容与规格升级

以下步骤适用于当前使用的 `alicloud-disk-ssd` 存储类与 `StatefulSet` 部署方式。

### 升级实例规格（CPU/内存）

1) 编辑 `stateful.yml`，调整容器 `resources.requests/limits`：

```yaml
resources:
  requests:
    memory: "4Gi"   # 例如从 2Gi 升到 4Gi
    cpu: "2"       # 例如从 1 升到 2
  limits:
    memory: "8Gi"
    cpu: "4"
```

2) 应用并滚动重启（ACK 会逐 Pod 按序重建，保证最小不可用）：

```bash
kubectl apply -f stateful.yml
kubectl rollout restart statefulset/qdrant-prod -n prod-ns
kubectl rollout status statefulset/qdrant-prod -n prod-ns --timeout=10m
```

3) 验证：

```bash
kubectl -n prod-ns get pods -l app=qdrant-prod -o wide
kubectl -n prod-ns top pod -l app=qdrant-prod  # 如集群启用 metrics-server
```

提示：若底层节点资源不足，可能需要在 ACK 控制台扩容节点池或调整 `nodeSelector`/`tolerations` 以调度到有资源的节点。

### 扩容磁盘（PVC 在线扩容）

前提：`alicloud-disk-ssd` 存储类支持卷扩容（大多数 ACK 官方 CSI 已默认开启 `allowVolumeExpand`）。磁盘只支持"增大"，不支持缩小。

1) 查看现有 PVC（`volumeClaimTemplates.name: storage` 会生成 `storage-qdrant-prod-<id>`）：

```bash
kubectl -n prod-ns get pvc -l app=qdrant-prod
# 常见名称：storage-qdrant-prod-0、storage-qdrant-prod-1、storage-qdrant-prod-2
```

2) 逐个扩容（示例将 20Gi 扩到 50Gi）：

```bash
kubectl -n prod-ns patch pvc storage-qdrant-prod-0 --type merge -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
kubectl -n prod-ns patch pvc storage-qdrant-prod-1 --type merge -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
kubectl -n prod-ns patch pvc storage-qdrant-prod-2 --type merge -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
```

3) 观察扩容进度：

```bash
kubectl -n prod-ns get pvc storage-qdrant-prod-{0..2} -w
```

4) 文件系统扩容：大多数情况下，ACK + Alibaba Cloud CSI 支持在线文件系统扩容，状态就绪后 Pod 内会自动识别新容量；若未自动扩容，可对单个 Pod 执行重启以触发：

```bash
kubectl -n prod-ns delete pod qdrant-prod-0  # StatefulSet 会自动重建该 Pod
```

5) 校验容量：

```bash
kubectl -n prod-ns exec -it qdrant-prod-0 -- df -h /qdrant/storage
```

注意：
- 扩容顺序建议逐个副本执行，以降低业务影响。
- 不要减小 `requests.storage`，Kubernetes 与底层云盘不支持收缩。
- 如存储类未开启扩容，请在 ACK 中启用支持扩容的存储类或新建具备 `allowVolumeExpansion: true` 的存储类后再迁移。