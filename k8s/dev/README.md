# Qdrant Kubernetes 集群部署（dev 环境）

该目录包含在 Kubernetes 上部署 Qdrant 集群（dev 环境）的所有清单与脚本。

## 文件说明

- `secrets.yml`：API 密钥配置（注入到 `QDRANT__SERVICE__API_KEY`）
- `headless-service.yml`：Headless Service，供 `StatefulSet` 内部发现与 P2P 通信
- `service.yml`：ClusterIP Service，对外暴露 HTTP API（由 Ingress 入口）
- `stateful.yml`：StatefulSet 配置，3 副本集群，开放 6333/6334/6335 端口
- `ingress.yml`：Ingress（ALB），域名与 TLS 终止配置
- `deploy.sh`：一键部署脚本

## 部署前置

- 已在 Kubernetes 集群安装并启用 ALB Ingress Controller。
- 已在 DNS 中将 `qdrant.dev.atominnolab.com` 指向 ALB。
- 已在集群中准备好 TLS Secret：`ssl-dev.atominnotab.com`（请确认 Secret 名称与证书资源一致）。

提示：`ingress.yml` 中当前配置为：
- 域名：`qdrant.dev.atominnolab.com`
- TLS Secret：`ssl-dev.atominnotab.com`

如需变更，请同步修改 `ingress.yml` 中 `spec.rules[0].host`、`spec.tls[0].hosts` 与 `spec.tls[0].secretName`。

## 部署步骤

### 1) 准备 API 密钥 Secret

推荐使用 `stringData`，避免手动 base64 和换行符问题：

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: qdrant-apikey-secret
  namespace: dev-ns
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
kubectl create namespace dev-ns --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f secrets.yml
kubectl apply -f headless-service.yml
kubectl apply -f service.yml
kubectl apply -f stateful.yml
kubectl apply -f ingress.yml
```

### 4) 验证

```bash
kubectl get pods -n dev-ns -l app=qdrant
kubectl get svc -n dev-ns
kubectl get ingress -n dev-ns
```

## 访问方式

- Web UI: https://qdrant.dev.atominnolab.com/dashboard
- HTTP API: https://qdrant.dev.atominnolab.com
- 集群内访问：`qdrant-svc.dev-ns.svc.cluster.local:6333`

首次访问 Web UI 时，输入与服务端一致的 API Key（即 `Secret` 中的值）。

## 调用示例

- 使用 API Key（HTTP 推荐方式）

```bash
curl -H 'api-key: your-api-key-here' https://qdrant.dev.atominnolab.com/cluster
```

- 使用 JWT（可选）：若使用 `Authorization: Bearer <token>`，则 `<token>` 必须是由服务端同一密钥（HS256）签发的 JWT
```bash
curl -H 'Authorization: Bearer <your-jwt-token>' https://qdrant.dev.atominnolab.com/cluster
```

常见错误与提示：
- 返回 `Invalid API key or JWT`：说明请求头不正确，或密钥/Token 不匹配。
  - 使用 `api-key` 头而不是 `Authorization: Bearer sk-...`（后者会被当作 JWT 解析）。
  - 确保 `Secret` 未引入换行符（`stringData` 推荐；若用 base64，请用 `echo -n`）。

## 故障排除

1) Pod 启动失败
- 检查镜像拉取、`Secret` 是否存在、存储类是否可用。

2) 集群未形成
- 确认 P2P 端口 6335 与 Headless Service 工作正常，DNS 可解析 `qdrant-0.qdrant-headless.dev-ns.svc.cluster.local`。

3) 401/认证失败
- 校验 `Secret` 值与请求头完全一致；修正后执行：
```bash
kubectl rollout restart statefulset/qdrant -n dev-ns
```

4) 集群内自测
```bash
kubectl -n dev-ns exec -it qdrant-0 -- \
  curl -s -i -H 'api-key: your-api-key-here' http://qdrant-svc.dev-ns.svc.cluster.local:6333/cluster
```

## 扩容

修改 `stateful.yml` 的 `spec.replicas` 后应用：
```bash
kubectl apply -f stateful.yml
```

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
kubectl rollout restart statefulset/qdrant -n dev-ns
kubectl rollout status statefulset/qdrant -n dev-ns --timeout=10m
```

3) 验证：

```bash
kubectl -n dev-ns get pods -l app=qdrant -o wide
kubectl -n dev-ns top pod -l app=qdrant  # 如集群启用 metrics-server
```

提示：若底层节点资源不足，可能需要在 ACK 控制台扩容节点池或调整 `nodeSelector`/`tolerations` 以调度到有资源的节点。

### 扩容磁盘（PVC 在线扩容）

前提：`alicloud-disk-ssd` 存储类支持卷扩容（大多数 ACK 官方 CSI 已默认开启 `allowVolumeExpand`）。磁盘只支持“增大”，不支持缩小。

1) 查看现有 PVC（`volumeClaimTemplates.name: storage` 会生成 `storage-qdrant-<id>`）：

```bash
kubectl -n dev-ns get pvc -l app=qdrant
# 常见名称：storage-qdrant-0、storage-qdrant-1、storage-qdrant-2
```

2) 逐个扩容（示例将 20Gi 扩到 50Gi）：

```bash
kubectl -n dev-ns patch pvc storage-qdrant-0 --type merge -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
kubectl -n dev-ns patch pvc storage-qdrant-1 --type merge -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
kubectl -n dev-ns patch pvc storage-qdrant-2 --type merge -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
```

3) 观察扩容进度：

```bash
kubectl -n dev-ns get pvc storage-qdrant-{0..2} -w
```

4) 文件系统扩容：大多数情况下，ACK + Alibaba Cloud CSI 支持在线文件系统扩容，状态就绪后 Pod 内会自动识别新容量；若未自动扩容，可对单个 Pod 执行重启以触发：

```bash
kubectl -n dev-ns delete pod qdrant-0  # StatefulSet 会自动重建该 Pod
```

5) 校验容量：

```bash
kubectl -n dev-ns exec -it qdrant-0 -- df -h /qdrant/storage
```

注意：
- 扩容顺序建议逐个副本执行，以降低业务影响。
- 不要减小 `requests.storage`，Kubernetes 与底层云盘不支持收缩。
- 如存储类未开启扩容，请在 ACK 中启用支持扩容的存储类或新建具备 `allowVolumeExpansion: true` 的存储类后再迁移。
