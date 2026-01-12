# 迁移命令清单

**重要提示**：根据 Qdrant 官方文档，全存储快照仅适用于单节点部署，分布式集群不支持通过API恢复全存储快照。但可以通过以下方案实现一次性迁移。

## 变量
```bash
NAMESPACE="dev-ns"
SOURCE_URL="http://qdrant-headless.dev-ns.svc.cluster.local:6333"
TARGET_URL="http://qdrant-v1-16-3-headless.dev-ns.svc.cluster.local:6333"
API_KEY="sk-eXr5+cVKlbWhorfIn4ckRA"
BATCH_SIZE=500
TARGET_POD=$(kubectl get pods -n $NAMESPACE -l app=qdrant-v1-16-3 -o jsonpath='{.items[0].metadata.name}')
```

## 1. 进入目标 Pod
```bash
kubectl exec -it -n $NAMESPACE $TARGET_POD -c qdrant -- /bin/bash
```

## 2. 在 Pod 内设置变量
```bash
export API_KEY="sk-eXr5+cVKlbWhorfIn4ckRA"
export SOURCE_URL="http://qdrant-headless.dev-ns.svc.cluster.local:6333"
export TARGET_URL="http://qdrant-v1-16-3-headless.dev-ns.svc.cluster.local:6333"
export BATCH_SIZE=500
```

## 3. 创建存储快照（在旧集群执行）
```bash
# 创建整个存储的快照（包含所有集合）
snapshot_resp=$(curl -s -X POST -H "api-key: $API_KEY" -H "Content-Type: application/json" \
  "$SOURCE_URL/snapshots?wait=true")

snapshot_name=$(echo "$snapshot_resp" | jq -r '.result.name')
echo "存储快照已创建: $snapshot_name"
```

## 4 查看已有快照
curl -s -H "api-key: $API_KEY"   "$SOURCE_URL/snapshots" | jq '.result'

## 4. 找到有快照的节点并从该节点下载（在本地执行）
```bash
# 在本地执行，找到有快照的Pod
SOURCE_NAMESPACE="dev-ns"
SNAPSHOT_NAME="full-snapshot-2026-01-06-10-36-33.snapshot"  # 步骤3获取的名称

# 找到包含快照的Pod
SOURCE_POD=""
for pod in $(kubectl get pods -n $SOURCE_NAMESPACE -l app=qdrant -o jsonpath='{.items[*].metadata.name}'); do
  if kubectl exec -n $SOURCE_NAMESPACE $pod -c qdrant -- test -f "/qdrant/snapshots/$SNAPSHOT_NAME" 2>/dev/null; then
    SOURCE_POD=$pod
    echo "找到快照在Pod: $SOURCE_POD"
    break
  fi
done

if [ -z "$SOURCE_POD" ]; then
  echo "错误: 未找到包含快照的Pod"
  exit 1
fi

# 直接复制到目标Pod
kubectl cp $SOURCE_NAMESPACE/$SOURCE_POD:/qdrant/snapshots/$SNAPSHOT_NAME \
  $NAMESPACE/$TARGET_POD:/qdrant/snapshots/$SNAPSHOT_NAME -c qdrant

echo "快照已复制到目标Pod"
```

## 5. 恢复全存储快照（在目标Pod中执行）
```bash
SNAPSHOT_NAME="full-snapshot-2026-01-06-10-36-33.snapshot"

# 全存储快照是一个tar包，包含所有集合快照和配置
# 解压并恢复所有集合快照
cd /tmp
mkdir -p snapshot_recovery
tar -xf /qdrant/snapshots/$SNAPSHOT_NAME -C snapshot_recovery/

# 查看配置，了解包含哪些集合
cat snapshot_recovery/config.json | jq .

# 从配置中提取集合列表和对应的快照文件
collections=$(cat snapshot_recovery/config.json | jq -r '.collections_mapping | keys[]')

for collection in $collections; do
  snapshot_file=$(cat snapshot_recovery/config.json | jq -r ".collections_mapping.\"$collection\"")
  snapshot_path="/tmp/snapshot_recovery/$snapshot_file"
  
  echo "恢复集合: $collection (使用快照: $snapshot_file)"
  # 使用 file:// 协议恢复集合快照
  curl -s -X POST -H "api-key: $API_KEY" -H "Content-Type: application/json" \
    -d "{\"location\": \"file://$snapshot_path\"}" \
    "$TARGET_URL/collections/$collection/snapshots/recover?wait=true" | jq .
done

# 恢复别名（如果有）
aliases=$(cat snapshot_recovery/config.json | jq -r '.collections_aliases | to_entries[] | "\(.key)=\(.value)"')
if [ -n "$aliases" ]; then
  for alias_pair in $aliases; do
    alias=$(echo $alias_pair | cut -d'=' -f1)
    collection=$(echo $alias_pair | cut -d'=' -f2)
    echo "创建别名: $alias -> $collection"
    curl -s -X PUT -H "api-key: $API_KEY" -H "Content-Type: application/json" \
      -d "{\"create_alias\": {\"collection_name\": \"$collection\", \"alias_name\": \"$alias\"}}" \
      "$TARGET_URL/aliases" | jq .
  done
else
  echo "没有别名需要恢复"
fi

echo "全存储快照恢复完成"
```

## 7. 验证数据（可选）
```bash
# 检查所有集合
curl -s -H "api-key: $API_KEY" \
  "$TARGET_URL/collections" | jq '.result.collections[].name'

# 检查特定集合信息（替换 COLLECTION_NAME）
COLLECTION_NAME="集合名称"
curl -s -H "api-key: $API_KEY" \
  "$TARGET_URL/collections/$COLLECTION_NAME" | jq '.result'
```

