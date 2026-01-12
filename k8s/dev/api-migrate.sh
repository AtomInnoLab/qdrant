#!/bin/bash

# Qdrant API 数据迁移脚本（不停机）
# 从 qdrant (v1.14.1) 迁移到 qdrant-v1-16-3 (v1.16.3)

set -e

NAMESPACE="dev-ns"
SOURCE_SERVICE="qdrant-headless"
TARGET_SERVICE="qdrant-v1-16-3-headless"
API_KEY="sk-eXr5+cVKlbWhorfIn4ckRA"

# 性能配置（可通过环境变量覆盖）
BATCH_SIZE=${BATCH_SIZE:-500}  # 批次大小，默认500（可设置为100-1000）
LOG_INTERVAL=${LOG_INTERVAL:-1000}  # 日志输出间隔（每N个点输出一次）
PARALLEL_JOBS=${PARALLEL_JOBS:-0}  # 并行迁移的集合数量，默认0（串行），设置为1-5启用并行

# 初始 URL（集群内地址）
SOURCE_URL_INTERNAL="http://${SOURCE_SERVICE}.${NAMESPACE}.svc.cluster.local:6333"
TARGET_URL_INTERNAL="http://${TARGET_SERVICE}.${NAMESPACE}.svc.cluster.local:6333"

# 实际使用的 URL（会在检测后设置）
SOURCE_URL=""
TARGET_URL=""

# Port-forward 相关变量
SOURCE_PORT=6333
TARGET_PORT=6334
declare -a PORT_FORWARD_PIDS=()

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 清理函数：停止所有 port-forward 进程
cleanup() {
    if [ ${#PORT_FORWARD_PIDS[@]} -gt 0 ]; then
        log_info "清理 port-forward 进程..."
        for pid in "${PORT_FORWARD_PIDS[@]}"; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
            fi
        done
        # 清理可能的残留进程
        pkill -f "kubectl.*port-forward.*${SOURCE_SERVICE}" 2>/dev/null || true
        pkill -f "kubectl.*port-forward.*${TARGET_SERVICE}" 2>/dev/null || true
        log_info "清理完成"
    fi
}

# 注册清理函数
trap cleanup EXIT INT TERM

# 检查 Pod 中的工具
check_pod_tools() {
    local pod_name=$1
    local missing_tools=()
    
    # 检查 curl
    if ! kubectl exec -n "$NAMESPACE" "$pod_name" -c qdrant -- \
        sh -c 'command -v curl > /dev/null 2>&1' 2>/dev/null; then
        missing_tools+=("curl")
    fi
    
    # 检查 jq
    if ! kubectl exec -n "$NAMESPACE" "$pod_name" -c qdrant -- \
        sh -c 'command -v jq > /dev/null 2>&1' 2>/dev/null; then
        missing_tools+=("jq")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo "${missing_tools[@]}"
        return 1
    fi
    return 0
}

# 在 Pod 中安装工具
install_pod_tools() {
    local pod_name=$1
    shift
    local tools=("$@")
    
    log_info "在 Pod $pod_name 中安装工具: ${tools[*]}"
    
    # 检测操作系统类型
    local os_type=$(kubectl exec -n "$NAMESPACE" "$pod_name" -c qdrant -- \
        sh -c 'cat /etc/os-release 2>/dev/null | grep "^ID=" | cut -d= -f2 | tr -d "\""' 2>/dev/null || echo "debian")
    
    log_info "检测到操作系统: $os_type"
    
    # 更新包管理器并安装工具
    if [ "$os_type" = "alpine" ]; then
        log_info "使用 Alpine 包管理器安装..."
        kubectl exec -n "$NAMESPACE" "$pod_name" -c qdrant -- \
            sh -c 'apk update > /dev/null 2>&1' 2>/dev/null || {
            log_error "无法更新包管理器"
            return 1
        }
        
        # 构建安装命令
        local install_cmd="apk add --no-cache"
        for tool in "${tools[@]}"; do
            install_cmd="$install_cmd $tool"
        done
        
        kubectl exec -n "$NAMESPACE" "$pod_name" -c qdrant -- \
            sh -c "$install_cmd > /dev/null 2>&1" 2>/dev/null || {
            log_error "安装工具失败: ${tools[*]}"
            return 1
        }
    else
        # Debian/Ubuntu 系统
        log_info "使用 apt-get 安装..."
        kubectl exec -n "$NAMESPACE" "$pod_name" -c qdrant -- \
            sh -c 'apt-get update > /dev/null 2>&1' 2>/dev/null || {
            log_error "无法更新包管理器"
            return 1
        }
        
        # 构建安装命令
        local install_cmd="apt-get install -y"
        for tool in "${tools[@]}"; do
            install_cmd="$install_cmd $tool"
        done
        
        kubectl exec -n "$NAMESPACE" "$pod_name" -c qdrant -- \
            sh -c "DEBIAN_FRONTEND=noninteractive $install_cmd > /dev/null 2>&1" 2>/dev/null || {
            log_error "安装工具失败: ${tools[*]}"
            return 1
        }
    fi
    
    log_info "工具安装完成"
    return 0
}

# 检测是否在集群内
check_cluster_access() {
    log_info "检测集群访问方式..."
    
    # 尝试访问集群内服务地址（快速检测，超时1秒）
    if curl -s -f --max-time 1 --connect-timeout 1 -H "api-key: $API_KEY" \
        "$SOURCE_URL_INTERNAL/collections" > /dev/null 2>&1; then
        log_info "检测到集群内访问，使用内部服务地址"
        SOURCE_URL="$SOURCE_URL_INTERNAL"
        TARGET_URL="$TARGET_URL_INTERNAL"
        return 0
    fi
    
    # 如果无法访问集群内服务，尝试在目标 Pod 内执行
    log_info "检测到集群外访问，将在目标集群 Pod 内执行迁移（使用内网地址）"
    return 2
}

# 在目标 Pod 内执行迁移脚本
execute_in_target_pod() {
    log_info "准备在目标集群 Pod 内执行迁移..."
    log_info "将在目标 Pod 内使用内网地址访问源集群和目标集群"
    
    # 检查 kubectl 是否可用
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl 未安装或不在 PATH 中"
        exit 1
    fi
    
    # 获取目标集群的第一个 Pod
    log_info "查找目标集群 Pod..."
    local target_pod=$(kubectl get pods -n "$NAMESPACE" -l app=qdrant-v1-16-3 \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$target_pod" ]; then
        log_error "无法找到目标集群 Pod (app=qdrant-v1-16-3)"
        log_error "请检查 Pod 是否存在: kubectl get pods -n $NAMESPACE -l app=qdrant-v1-16-3"
        exit 1
    fi
    
    log_info "找到目标 Pod: $target_pod"
    
    # 检查 Pod 状态
    local pod_status=$(kubectl get pod "$target_pod" -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null)
    
    if [ "$pod_status" != "Running" ]; then
        log_error "Pod $target_pod 状态不是 Running (当前: $pod_status)"
        exit 1
    fi
    
    # 注意：工具检查将在 Pod 内脚本中自动进行
    # 这里只检查 Pod 状态，不检查工具（因为 Pod 内脚本会自动安装）
    log_info "Pod 状态检查通过，工具将在 Pod 内自动检查并安装"
    
    # 将脚本内容传递给 Pod 执行
    log_info "在 Pod 内执行迁移脚本（使用内网地址）..."
    
    # 创建一个可以在 Pod 内执行的脚本（使用变量替换）
    local pod_script=$(cat <<POD_SCRIPT_EOF
#!/bin/sh
set -e

# 在 Pod 内执行的迁移逻辑
NAMESPACE="${NAMESPACE}"
SOURCE_SERVICE="${SOURCE_SERVICE}"
TARGET_SERVICE="${TARGET_SERVICE}"
API_KEY="${API_KEY}"
BATCH_SIZE="${BATCH_SIZE:-500}"
LOG_INTERVAL="${LOG_INTERVAL:-1000}"

# 确保 PATH 包含常用工具路径
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"

# 使用内网地址
SOURCE_URL="http://\${SOURCE_SERVICE}.\${NAMESPACE}.svc.cluster.local:6333"
TARGET_URL="http://\${TARGET_SERVICE}.\${NAMESPACE}.svc.cluster.local:6333"

log_info() {
    echo "[INFO] \$1"
}

log_warn() {
    echo "[WARN] \$1"
}

log_error() {
    echo "[ERROR] \$1" >&2
}

# 检查并安装工具
check_and_install_tools() {
    local missing_tools=""
    
    # 检查 curl
    if ! command -v curl > /dev/null 2>&1; then
        missing_tools="curl"
    fi
    
    # 检查 jq
    if ! command -v jq > /dev/null 2>&1; then
        if [ -n "\$missing_tools" ]; then
            missing_tools="\$missing_tools jq"
        else
            missing_tools="jq"
        fi
    fi
    
    # 检查 Python（python3 或 python）
    if ! command -v python3 > /dev/null 2>&1 && ! command -v python > /dev/null 2>&1; then
        if [ -n "\$missing_tools" ]; then
            missing_tools="\$missing_tools python3"
        else
            missing_tools="python3"
        fi
    fi
    
    if [ -n "\$missing_tools" ]; then
        log_warn "缺少工具: \$missing_tools"
        log_info "尝试安装..."
        
        # 检测操作系统
        if [ -f /etc/alpine-release ]; then
            # Alpine Linux
            apk update > /dev/null 2>&1
            # 对于 Alpine，python3 包名是 python3
            local install_packages="\$missing_tools"
            # 如果包含 python3，确保使用正确的包名
            if echo "\$install_packages" | grep -q python3; then
                install_packages=\$(echo "\$install_packages" | sed 's/python3/python3/')
            fi
            apk add --no-cache \$install_packages > /dev/null 2>&1 || {
                log_error "安装工具失败: \$missing_tools"
                return 1
            }
        else
            # Debian/Ubuntu
            apt-get update > /dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y \$missing_tools > /dev/null 2>&1 || {
                log_error "安装工具失败: \$missing_tools"
                return 1
            }
        fi
        
        log_info "工具安装完成"
    fi
    
    # 验证工具
    if ! command -v curl > /dev/null 2>&1 || ! command -v jq > /dev/null 2>&1; then
        log_error "工具验证失败"
        return 1
    fi
    
    # 验证 Python
    if ! command -v python3 > /dev/null 2>&1 && ! command -v python > /dev/null 2>&1; then
        log_error "Python 验证失败"
        return 1
    fi
    
    return 0
}

# 检查连接
check_connection() {
    log_info "检查源集群连接..."
    if ! curl -s -f -H "api-key: \$API_KEY" "\$SOURCE_URL/collections" > /dev/null; then
        log_error "无法连接到源集群: \$SOURCE_URL"
        return 1
    fi
    log_info "源集群连接正常"
    
    log_info "检查目标集群连接..."
    if ! curl -s -f -H "api-key: \$API_KEY" "\$TARGET_URL/collections" > /dev/null; then
        log_error "无法连接到目标集群: \$TARGET_URL"
        return 1
    fi
    log_info "目标集群连接正常"
}

# 获取所有集合
get_collections() {
    log_info "获取源集群的所有集合..." >&2
    local collections_json=\$(curl -s -H "api-key: \$API_KEY" "\$SOURCE_URL/collections" 2>/dev/null)
    
    if [ -z "\$collections_json" ]; then
        log_warn "无法获取集合列表" >&2
        return 1
    fi
    
    # 提取集合名称
    echo "\$collections_json" | jq -r '.result.collections[]?.name // empty' 2>/dev/null | \
        grep -v '^\$' | \
        grep -v '^\[.*\]' | \
        grep -v '^获取' | \
        grep -E '^[a-zA-Z0-9_\-]+' | \
        grep -v -i 'benchmark' | \
        grep -v -i 'test' || echo ""
}

# 获取集合配置
get_collection_config() {
    local collection=\$1
    curl -s -H "api-key: \$API_KEY" "\$SOURCE_URL/collections/\$collection" | \
        jq '.result.config' 2>/dev/null
}

# 创建集合
create_collection() {
    local collection=\$1
    local config=\$2
    
    log_info "创建集合: \$collection"
    
    local create_payload=\$(echo "\$config" | jq '{
        vectors: .params.vectors,
        sparse_vectors: .params.sparse_vectors,
        hnsw_config: .hnsw_config,
        optimizers_config: .optimizer,
        wal_config: .wal,
        quantization_config: .quantization_config
    }' | jq 'del(.[] | nulls)')
    
    local result=\$(curl -s -w "\\n%{http_code}" -X PUT \
        -H "api-key: \$API_KEY" \
        -H "Content-Type: application/json" \
        -d "\$create_payload" \
        "\$TARGET_URL/collections/\$collection")
    
    local http_code=\$(echo "\$result" | tail -n1)
    local body=\$(echo "\$result" | sed '\$d')
    
    if [ "\$http_code" = "200" ] || [ "\$http_code" = "201" ]; then
        log_info "集合创建成功"
        return 0
    elif [ "\$http_code" = "409" ]; then
        log_warn "集合已存在，跳过创建"
        return 0
    else
        log_error "创建集合失败 (HTTP \$http_code)"
        log_error "响应内容: \$body"
        return 1
    fi
}

# 清空目标集合
clear_target_collection() {
    local collection=\$1
    log_info "清空目标集合 \$collection 的所有点..."
    
    local collection_info=\$(curl -s -H "api-key: \$API_KEY" "\$TARGET_URL/collections/\$collection" 2>/dev/null)
    if echo "\$collection_info" | jq -e '.error' > /dev/null 2>&1; then
        log_warn "目标集合不存在，跳过清空"
        return 0
    fi
    
    local points_count=\$(echo "\$collection_info" | jq -r '.result.points_count // 0' 2>/dev/null)
    if [ "\$points_count" = "0" ] || [ -z "\$points_count" ]; then
        log_info "目标集合为空，无需清空"
        return 0
    fi
    
    log_info "目标集合当前有 \$points_count 个点，开始清空..."
    local delete_result=\$(curl -s -w "\\n%{http_code}" -X POST \
        -H "api-key: \$API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"filter": {"must": []}}' \
        "\$TARGET_URL/collections/\$collection/points/delete?wait=true")
    
    local http_code=\$(echo "\$delete_result" | tail -n1)
    local body=\$(echo "\$delete_result" | sed '\$d')
    
    if [ "\$http_code" = "200" ] || [ "\$http_code" = "201" ]; then
        sleep 1
        local verify_info=\$(curl -s -H "api-key: \$API_KEY" "\$TARGET_URL/collections/\$collection" 2>/dev/null)
        local remaining_points=\$(echo "\$verify_info" | jq -r '.result.points_count // 0' 2>/dev/null)
        if [ "\$remaining_points" = "0" ]; then
            log_info "目标集合已清空"
            return 0
        else
            log_warn "清空后仍有 \$remaining_points 个点，可能需要重试"
            return 1
        fi
    else
        log_error "清空目标集合失败 (HTTP \$http_code)"
        log_error "响应内容: \$body"
        return 1
    fi
}

# 迁移点数据
migrate_points() {
    local collection=\$1
    log_info "开始迁移点数据..."
    
    local total_points=0
    local migrated_points=0
    local offset=""
    local batch_count=0
    
    while true; do
        # 使用 jq 构建 JSON payload
        local scroll_payload
        if [ -n "\$offset" ] && [ "\$offset" != "null" ]; then
            if [ "\$offset" -gt 0 ] 2>/dev/null; then
                scroll_payload=\$(echo "{}" | jq -c --argjson limit "\$BATCH_SIZE" --argjson offset "\$offset" '{limit: \$limit, offset: \$offset, with_payload: true, with_vectors: true}')
            else
                scroll_payload=\$(echo "{}" | jq -c --argjson limit "\$BATCH_SIZE" --arg offset "\$offset" '{limit: \$limit, offset: \$offset, with_payload: true, with_vectors: true}')
            fi
        else
            scroll_payload=\$(echo "{}" | jq -c --argjson limit "\$BATCH_SIZE" '{limit: \$limit, with_payload: true, with_vectors: true}')
        fi
        
        local scroll_result=\$(curl -s -X POST \
            -H "api-key: \$API_KEY" \
            -H "Content-Type: application/json" \
            -d "\$scroll_payload" \
            "\$SOURCE_URL/collections/\$collection/points/scroll")
        
        # 检查响应是否为空
        if [ -z "\$scroll_result" ]; then
            log_error "Scroll 响应为空"
            return 1
        fi
        
        # 基本检查：响应应该以 { 开头（JSON 对象）
        if ! echo "\$scroll_result" | head -c 1 | grep -q '{'; then
            log_error "Scroll 响应格式错误，不是有效的 JSON 对象"
            log_error "响应内容（前500字符）: \$(echo "\$scroll_result" | head -c 500)"
            return 1
        fi
        
        # 检查是否有错误字段（先检查字符串，避免 jq 处理大响应失败）
        if echo "\$scroll_result" | grep -q '"error"'; then
            local error_msg=\$(echo "\$scroll_result" | jq -r '.error.message // .error' 2>/dev/null || echo "未知错误")
            log_error "Scroll 请求失败: \$error_msg"
            return 1
        fi
        
        # 检查是否有 result 字段（先检查字符串，避免 jq 处理大响应失败）
        if ! echo "\$scroll_result" | grep -q '"result"'; then
            log_error "Scroll 响应格式错误，没有 result 字段"
            log_error "响应内容（前500字符）: \$(echo "\$scroll_result" | head -c 500)"
            log_error "请求 URL: \$SOURCE_URL/collections/\$collection/points/scroll"
            log_error "请求 Payload: \$scroll_payload"
            return 1
        fi
        
        # 使用临时文件处理大响应，避免管道和内存问题
        local scroll_result_file=\$(mktemp)
        echo "\$scroll_result" > "\$scroll_result_file"
        
        # 使用 Python 解析 JSON（Python 的 json 模块可以处理包含未转义控制字符的 JSON）
        # 先检查 Python 是否可用，如果不可用则尝试安装
        local python_cmd=\$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
        
        if [ -z "\$python_cmd" ]; then
            log_warn "Python 不可用，尝试安装..."
            # 检测操作系统并安装 Python
            if [ -f /etc/alpine-release ]; then
                # Alpine Linux
                apk update > /dev/null 2>&1
                apk add --no-cache python3 > /dev/null 2>&1 || {
                    log_error "安装 Python3 失败"
                    rm -f "\$scroll_result_file"
                    return 1
                }
            else
                # Debian/Ubuntu
                apt-get update > /dev/null 2>&1
                DEBIAN_FRONTEND=noninteractive apt-get install -y python3 > /dev/null 2>&1 || {
                    log_error "安装 Python3 失败"
                    rm -f "\$scroll_result_file"
                    return 1
                }
            fi
            python_cmd=\$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
            if [ -z "\$python_cmd" ]; then
                log_error "Python 安装后仍不可用"
                rm -f "\$scroll_result_file"
                return 1
            fi
            log_info "Python 安装成功"
        fi
        
        # 使用 Python 解析 JSON 并提取信息
        # 创建 Python 脚本临时文件
        local python_script=\$(mktemp)
        cat > "\$python_script" << 'PYTHON_SCRIPT'
import json
import sys
import re

def clean_control_chars(text):
    """清理字符串中的未转义控制字符（U+0000 到 U+001F）"""
    # 最简单有效的方法：直接移除所有控制字符
    # 注意：这会移除未转义的控制字符，但保留已转义的（如 \\n）
    # 因为已转义的字符在文本中是两个字符 '\\' 和 'n'，不会被正则匹配
    return re.sub(r'[\x00-\x1f]', '', text)

try:
    input_file = sys.argv[1]
    
    # 读取文件内容
    with open(input_file, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()
    
    # 尝试直接解析 JSON
    try:
        data = json.loads(content)
    except json.JSONDecodeError as e1:
        # 如果失败，清理控制字符后重试
        cleaned_content = clean_control_chars(content)
        try:
            data = json.loads(cleaned_content)
        except json.JSONDecodeError as e2:
            # 如果还是失败，使用更激进的方法：移除所有控制字符和扩展控制字符
            aggressive_cleaned = re.sub(r'[\x00-\x1f\x7f-\x9f]', '', content)
            try:
                data = json.loads(aggressive_cleaned)
            except json.JSONDecodeError as e3:
                print(f"ERROR:JSON解析失败: {e3}", file=sys.stderr)
                print(f"ERROR:位置: line {e3.lineno}, column {e3.colno}", file=sys.stderr)
                sys.exit(1)
    
    # 检查错误
    if 'error' in data:
        error_msg = data.get('error', {})
        if isinstance(error_msg, dict):
            error_msg = error_msg.get('message', str(error_msg))
        print(f"ERROR:{error_msg}", file=sys.stderr)
        sys.exit(1)
    
    # 提取 points_count 和 next_offset
    result = data.get('result', {})
    points = result.get('points', [])
    points_count = len(points)
    next_offset = result.get('next_page_offset')
    
    # 输出格式: points_count|next_offset|upload_payload_json
    upload_payload = {'points': points}
    upload_payload_json = json.dumps(upload_payload, ensure_ascii=False)
    print(f"{points_count}|{next_offset}|{upload_payload_json}")
    
except Exception as e:
    print(f"ERROR:处理失败: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_SCRIPT
        
        # 执行 Python 脚本
        local json_info=\$(\$python_cmd "\$python_script" "\$scroll_result_file" 2>&1)
        local python_exit_code=\$?
        
        # 清理 Python 脚本文件
        rm -f "\$python_script"
        
        # 检查 Python 执行是否成功
        if [ \$python_exit_code -ne 0 ]; then
            log_error "Python JSON 解析失败"
            log_error "响应大小: \$(wc -c < "\$scroll_result_file") 字节"
            log_error "响应前200字符: \$(head -c 200 "\$scroll_result_file")"
            log_error "Python 错误: \$json_info"
            rm -f "\$scroll_result_file"
            return 1
        fi
        
        # 检查是否有错误（错误会输出到 stderr，但会被捕获到 json_info）
        if echo "\$json_info" | grep -q "^ERROR:"; then
            local error_msg=\$(echo "\$json_info" | grep "^ERROR:" | sed 's/^ERROR://')
            log_error "Scroll 请求失败: \$error_msg"
            rm -f "\$scroll_result_file"
            return 1
        fi
        
        # 提取 points_count、next_offset 和 upload_payload（格式: points_count|next_offset|upload_payload_json）
        local points_count=\$(echo "\$json_info" | cut -d'|' -f1)
        local next_offset=\$(echo "\$json_info" | cut -d'|' -f2)
        local upload_payload=\$(echo "\$json_info" | cut -d'|' -f3-)
        
        # 验证提取的数据
        if [ -z "\$points_count" ] || [ -z "\$upload_payload" ]; then
            log_error "无法从 JSON 响应中提取数据"
            log_error "提取的信息: \$json_info"
            rm -f "\$scroll_result_file"
            return 1
        fi
        
        # 检查 points 数组是否为空
        if [ -z "\$points_count" ] || [ "\$points_count" = "0" ] || [ "\$points_count" = "null" ]; then
            # 如果没有数据，检查是否是因为 offset 问题
            if [ -n "\$offset" ] && [ "\$offset" != "null" ]; then
                log_info "已到达数据末尾（offset: \$offset）"
            else
                log_warn "源集合为空或无法获取数据"
            fi
            rm -f "\$scroll_result_file"
            break
        fi
        
        # 设置 batch_count
        batch_count=\$points_count
        
        # 将上传 payload 写入临时文件
        local upload_payload_file=\$(mktemp)
        echo "\$upload_payload" > "\$upload_payload_file"
        
        # 清理 scroll_result 临时文件
        rm -f "\$scroll_result_file"
        
        # 使用临时文件上传（避免 Argument list too long 错误）
        local upload_result=\$(curl -s -w "\\n%{http_code}" -X PUT \
            -H "api-key: \$API_KEY" \
            -H "Content-Type: application/json" \
            --data-binary "@\$upload_payload_file" \
            "\$TARGET_URL/collections/\$collection/points?wait=true")
        
        # 清理上传 payload 临时文件
        rm -f "\$upload_payload_file"
        
        local upload_code=\$(echo "\$upload_result" | tail -n1)
        local upload_body=\$(echo "\$upload_result" | sed '\$d')
        
        if [ "\$upload_code" != "200" ] && [ "\$upload_code" != "201" ]; then
            log_error "上传批次失败 (HTTP \$upload_code)"
            log_error "响应内容: \$upload_body"
            return 1
        fi
        
        migrated_points=\$((migrated_points + batch_count))
        
        if [ \$((migrated_points % LOG_INTERVAL)) -eq 0 ]; then
            log_info "已迁移 \$migrated_points 个点..."
        fi
        
        if [ -z "\$next_offset" ] || [ "\$next_offset" = "null" ]; then
            break
        fi
        
        offset="\$next_offset"
    done
    
    log_info "点数据迁移完成，共迁移 \$migrated_points 个点"
}

# 验证迁移
verify_migration() {
    local collection=\$1
    log_info "验证迁移结果..."
    
    local retry=0
    local max_retries=3
    
    while [ \$retry -lt \$max_retries ]; do
        sleep 2
        
        local source_info=\$(curl -s -H "api-key: \$API_KEY" "\$SOURCE_URL/collections/\$collection" 2>/dev/null)
        local target_info=\$(curl -s -H "api-key: \$API_KEY" "\$TARGET_URL/collections/\$collection" 2>/dev/null)
        
        local source_count=\$(echo "\$source_info" | jq -r '.result.points_count // 0' 2>/dev/null)
        local target_count=\$(echo "\$target_info" | jq -r '.result.points_count // 0' 2>/dev/null)
        
        source_count=\${source_count:-0}
        target_count=\${target_count:-0}
        
        if [ "\$target_count" = "\$source_count" ] && [ "\$source_count" -gt 0 ]; then
            log_info "✓ 验证通过: 源集群 \$source_count 个点，目标集群 \$target_count 个点"
            return 0
        elif [ \$retry -lt \$((max_retries - 1)) ]; then
            log_warn "点数不匹配 (尝试 \$((retry + 1))/\$max_retries): 源集群 \$source_count 个点，目标集群 \$target_count 个点，等待重试..."
        else
            log_error "⚠ 点数不匹配: 源集群 \$source_count 个点，目标集群 \$target_count 个点"
            return 1
        fi
        
        retry=\$((retry + 1))
    done
    
    return 1
}

# 迁移单个集合
migrate_collection() {
    local collection=\$1
    
    log_info ""
    log_info "========================================="
    log_info "开始迁移集合: \$collection"
    log_info "========================================="
    
    # 1. 获取集合配置
    log_info "步骤 1/4: 获取集合配置..."
    local config=\$(get_collection_config "\$collection")
    if [ -z "\$config" ] || [ "\$config" = "null" ]; then
        log_error "无法获取集合配置"
        return 1
    fi
    
    # 2. 创建集合
    log_info "步骤 2/4: 创建目标集合..."
    if ! create_collection "\$collection" "\$config"; then
        log_error "创建集合失败"
        return 1
    fi
    
    # 3. 清空目标集合
    log_info "步骤 3/4: 清空目标集合..."
    if ! clear_target_collection "\$collection"; then
        log_warn "清空目标集合失败，继续迁移（可能会产生重复数据）"
    fi
    
    # 4. 迁移点数据
    log_info "步骤 4/4: 迁移点数据..."
    if ! migrate_points "\$collection"; then
        log_error "迁移点数据失败"
        return 1
    fi
    
    log_info "集合 \$collection 迁移完成"
}

# 主函数
main() {
    log_info "========================================="
    log_info "Qdrant API 数据迁移（Pod 内执行）"
    log_info "========================================="
    log_info "源集群: \$SOURCE_URL"
    log_info "目标集群: \$TARGET_URL"
    log_info ""
    
    # 检查并安装工具
    if ! check_and_install_tools; then
        log_error "工具检查失败，无法继续"
        exit 1
    fi
    
    if ! check_connection; then
        exit 1
    fi
    
    local collections=\$(get_collections)
    if [ -z "\$collections" ]; then
        log_warn "没有找到需要迁移的集合"
        exit 0
    fi
    
    local test_collections=\$(echo "\$collections" | grep -i -E '(benchmark|test)' | wc -l)
    if [ "\$test_collections" -gt 0 ]; then
        log_info "已跳过 \$test_collections 个测试集合（包含 benchmark 或 test）"
    fi
    
    local success_count=0
    local fail_count=0
    local total_collections=0
    
    for collection in \$collections; do
        if [ -z "\$collection" ] || [ "\${collection#\[}" != "\$collection" ] || ! echo "\$collection" | grep -qE '^[a-zA-Z0-9_\-]+'; then
            continue
        fi
        total_collections=\$((total_collections + 1))
        
        if migrate_collection "\$collection"; then
            if verify_migration "\$collection"; then
                success_count=\$((success_count + 1))
            else
                fail_count=\$((fail_count + 1))
            fi
        else
            fail_count=\$((fail_count + 1))
        fi
    done
    
    log_info ""
    log_info "========================================="
    log_info "迁移完成"
    log_info "========================================="
    log_info "成功: \$success_count 个集合"
    log_info "失败: \$fail_count 个集合"
    log_info "总计: \$total_collections 个集合"
}

# 执行主函数
main "\$@"
POD_SCRIPT_EOF
)
    
    # 通过 kubectl exec 在 Pod 内执行脚本
    kubectl exec -n "$NAMESPACE" "$target_pod" -c qdrant -- \
        sh -c "$pod_script"
    
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        log_info "迁移完成"
    else
        log_error "迁移失败 (退出码: $exit_code)"
    fi
    
    return $exit_code
}

# 启动 port-forward（保留作为备选方案）
setup_port_forward() {
    log_info "设置 kubectl port-forward..."
    
    # 检查 kubectl 是否可用
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl 未安装或不在 PATH 中"
        exit 1
    fi
    
    # 检查服务是否存在
    if ! kubectl get svc "$SOURCE_SERVICE" -n "$NAMESPACE" &> /dev/null; then
        log_error "源服务 $SOURCE_SERVICE 不存在"
        exit 1
    fi
    
    if ! kubectl get svc "$TARGET_SERVICE" -n "$NAMESPACE" &> /dev/null; then
        log_error "目标服务 $TARGET_SERVICE 不存在"
        exit 1
    fi
    
    # 检查端口是否已被占用，如果是 kubectl port-forward 则清理
    if lsof -Pi :${SOURCE_PORT} -sTCP:LISTEN -t >/dev/null 2>&1; then
        local port_pid=$(lsof -Pi :${SOURCE_PORT} -sTCP:LISTEN -t 2>/dev/null | head -1)
        if [ -n "$port_pid" ]; then
            # 检查是否是 kubectl port-forward 进程
            if ps -p "$port_pid" -o command= 2>/dev/null | grep -q "kubectl.*port-forward.*${SOURCE_SERVICE}"; then
                log_info "检测到已存在的 port-forward 进程 (PID: $port_pid)，清理中..."
                kill "$port_pid" 2>/dev/null || true
                sleep 1
            else
                log_warn "端口 ${SOURCE_PORT} 已被其他进程占用，尝试使用其他端口..."
                SOURCE_PORT=6335
            fi
        fi
    fi
    
    if lsof -Pi :${TARGET_PORT} -sTCP:LISTEN -t >/dev/null 2>&1; then
        local port_pid=$(lsof -Pi :${TARGET_PORT} -sTCP:LISTEN -t 2>/dev/null | head -1)
        if [ -n "$port_pid" ]; then
            # 检查是否是 kubectl port-forward 进程
            if ps -p "$port_pid" -o command= 2>/dev/null | grep -q "kubectl.*port-forward.*${TARGET_SERVICE}"; then
                log_info "检测到已存在的 port-forward 进程 (PID: $port_pid)，清理中..."
                kill "$port_pid" 2>/dev/null || true
                sleep 1
            else
                log_warn "端口 ${TARGET_PORT} 已被其他进程占用，尝试使用其他端口..."
                TARGET_PORT=6336
            fi
        fi
    fi
    
    # 启动源集群 port-forward
    log_info "启动源集群 port-forward (localhost:${SOURCE_PORT})..."
    kubectl port-forward -n "$NAMESPACE" "svc/$SOURCE_SERVICE" \
        "${SOURCE_PORT}:6333" > /tmp/qdrant-source-portforward.log 2>&1 &
    local source_pid=$!
    PORT_FORWARD_PIDS+=("$source_pid")
    
    # 等待 port-forward 就绪
    local retry=0
    while [ $retry -lt 10 ]; do
        sleep 1
        if kill -0 "$source_pid" 2>/dev/null && \
           curl -s -f --max-time 1 "http://localhost:${SOURCE_PORT}/" > /dev/null 2>&1; then
            break
        fi
        retry=$((retry + 1))
    done
    
    if ! kill -0 "$source_pid" 2>/dev/null; then
        log_error "源集群 port-forward 启动失败"
        cat /tmp/qdrant-source-portforward.log 2>/dev/null || true
        exit 1
    fi
    
    # 启动目标集群 port-forward
    log_info "启动目标集群 port-forward (localhost:${TARGET_PORT})..."
    kubectl port-forward -n "$NAMESPACE" "svc/$TARGET_SERVICE" \
        "${TARGET_PORT}:6333" > /tmp/qdrant-target-portforward.log 2>&1 &
    local target_pid=$!
    PORT_FORWARD_PIDS+=("$target_pid")
    
    # 等待 port-forward 就绪
    retry=0
    while [ $retry -lt 10 ]; do
        sleep 1
        if kill -0 "$target_pid" 2>/dev/null && \
           curl -s -f --max-time 1 "http://localhost:${TARGET_PORT}/" > /dev/null 2>&1; then
            break
        fi
        retry=$((retry + 1))
    done
    
    if ! kill -0 "$target_pid" 2>/dev/null; then
        log_error "目标集群 port-forward 启动失败"
        cat /tmp/qdrant-target-portforward.log 2>/dev/null || true
        exit 1
    fi
    
    # 设置 URL
    SOURCE_URL="http://localhost:${SOURCE_PORT}"
    TARGET_URL="http://localhost:${TARGET_PORT}"
    
    log_info "Port-forward 设置完成"
    log_info "源集群: $SOURCE_URL"
    log_info "目标集群: $TARGET_URL"
}

# 检查集群连接
check_connection() {
    log_info "检查源集群连接..."
    if ! curl -s -f -H "api-key: $API_KEY" "$SOURCE_URL/collections" > /dev/null; then
        log_error "无法连接到源集群: $SOURCE_URL"
        exit 1
    fi
    log_info "源集群连接正常"
    
    log_info "检查目标集群连接..."
    if ! curl -s -f -H "api-key: $API_KEY" "$TARGET_URL/collections" > /dev/null; then
        log_error "无法连接到目标集群: $TARGET_URL"
        exit 1
    fi
    log_info "目标集群连接正常"
}

# 获取所有集合
get_collections() {
    log_info "获取源集群的所有集合..." >&2
    local collections_json=$(curl -s -H "api-key: $API_KEY" "$SOURCE_URL/collections" 2>/dev/null)
    
    if [ -z "$collections_json" ]; then
        log_warn "无法获取集合列表" >&2
        return 1
    fi
    
    # 提取集合名称，使用临时文件避免管道问题
    local temp_file=$(mktemp)
    echo "$collections_json" | jq -r '.result.collections[]?.name // empty' 2>/dev/null > "$temp_file"
    
    # 过滤掉空行、无效行和测试集合（包含 benchmark 或 test）
    local collections_list=$(grep -v '^$' "$temp_file" | \
        grep -v '^\[.*\]' | \
        grep -v '^获取' | \
        grep -E '^[a-zA-Z0-9_\-]+' | \
        grep -v -i 'benchmark' | \
        grep -v -i 'test' || echo "")
    rm -f "$temp_file"
    
    if [ -z "$collections_list" ]; then
        log_warn "源集群中没有集合" >&2
        return 1
    fi
    
    # 输出集合列表（只输出到 stdout）
    echo "$collections_list"
}

# 获取集合配置
get_collection_config() {
    local collection=$1
    curl -s -H "api-key: $API_KEY" "$SOURCE_URL/collections/$collection" | \
        jq -r '.result.config'
}

# 创建集合
create_collection() {
    local collection=$1
    local config=$2
    
    log_info "创建集合: $collection"
    
    # 提取配置信息（包括 sparse vectors）
    local create_payload=$(echo "$config" | jq '{
        vectors: .params.vectors,
        sparse_vectors: .params.sparse_vectors,
        hnsw_config: .hnsw_config,
        optimizers_config: .optimizer,
        wal_config: .wal,
        quantization_config: .quantization_config
    }' | jq 'del(.[] | nulls)')  # 删除空值
    
    local result=$(curl -s -w "\n%{http_code}" -X PUT \
        -H "api-key: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$create_payload" \
        "$TARGET_URL/collections/$collection")
    
    local http_code=$(echo "$result" | tail -n1)
    local body=$(echo "$result" | sed '$d')
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        log_info "集合创建成功"
        return 0
    elif [ "$http_code" = "409" ]; then
        # HTTP 409 表示集合已存在
        log_warn "集合已存在，检查配置是否需要更新..."
        
        # 检查目标集合是否有 sparse vectors 配置
        local target_info=$(curl -s -H "api-key: $API_KEY" \
            "$TARGET_URL/collections/$collection" 2>/dev/null)
        local target_sparse=$(echo "$target_info" | jq -r '.result.config.params.sparse_vectors // empty' 2>/dev/null)
        local source_sparse=$(echo "$config" | jq -r '.params.sparse_vectors // empty' 2>/dev/null)
        
        # 如果源集合有 sparse vectors 但目标集合没有，需要删除并重新创建
        if [ -n "$source_sparse" ] && [ "$source_sparse" != "null" ] && ([ -z "$target_sparse" ] || [ "$target_sparse" = "null" ]); then
            log_warn "目标集合缺少 sparse vectors 配置"
            log_warn "Qdrant 不支持在已存在的集合上添加 sparse vectors，需要删除并重新创建"
            
            # 检查目标集合是否有数据
            local target_points=$(echo "$target_info" | jq -r '.result.points_count // 0' 2>/dev/null)
            if [ "$target_points" -gt 0 ]; then
                log_error "目标集合已有 $target_points 个点，无法自动删除"
                log_error "请手动删除目标集合并重新运行脚本，或迁移数据后再删除"
                return 1
            fi
            
            # 删除目标集合
            log_info "删除目标集合以重新创建（包含 sparse vectors 配置）..."
            local delete_result=$(curl -s -w "\n%{http_code}" -X DELETE \
                -H "api-key: $API_KEY" \
                "$TARGET_URL/collections/$collection")
            local delete_code=$(echo "$delete_result" | tail -n1)
            
            if [ "$delete_code" = "200" ]; then
                log_info "目标集合已删除，重新创建..."
                # 重新创建集合
                local retry_result=$(curl -s -w "\n%{http_code}" -X PUT \
                    -H "api-key: $API_KEY" \
                    -H "Content-Type: application/json" \
                    -d "$create_payload" \
                    "$TARGET_URL/collections/$collection")
                local retry_code=$(echo "$retry_result" | tail -n1)
                
                if [ "$retry_code" = "200" ] || [ "$retry_code" = "201" ]; then
                    log_info "集合重新创建成功（包含 sparse vectors 配置）"
                    return 0
                else
                    log_error "重新创建集合失败 (HTTP $retry_code)"
                    return 1
                fi
            else
                log_error "删除目标集合失败 (HTTP $delete_code)"
                return 1
            fi
        fi
        
        log_warn "集合已存在，跳过创建"
        return 0
    elif echo "$body" | jq -e '.status.error // .error.message' > /dev/null 2>&1; then
        local error_msg=$(echo "$body" | jq -r '.status.error // .error.message' 2>/dev/null)
        if echo "$error_msg" | grep -qi "already exists\|already exist"; then
            log_warn "集合已存在，跳过创建"
            return 0
        else
            log_error "创建集合失败: $error_msg"
            return 1
        fi
    else
        log_error "创建集合失败 (HTTP $http_code)"
        echo "$body" | jq '.' 2>/dev/null || echo "$body"
        return 1
    fi
}

# 清空目标集合的所有点
clear_target_collection() {
    local collection=$1
    
    log_info "清空目标集合 $collection 的所有点..."
    
    # 检查目标集合是否存在
    local collection_info=$(curl -s -H "api-key: $API_KEY" \
        "$TARGET_URL/collections/$collection" 2>/dev/null)
    
    if echo "$collection_info" | jq -e '.error' > /dev/null 2>&1; then
        log_warn "目标集合不存在，跳过清空"
        return 0
    fi
    
    local points_count=$(echo "$collection_info" | jq -r '.result.points_count // 0' 2>/dev/null)
    
    if [ "$points_count" = "0" ] || [ -z "$points_count" ]; then
        log_info "目标集合为空，无需清空"
        return 0
    fi
    
    log_info "目标集合当前有 $points_count 个点，开始清空..."
    
    # 使用匹配所有点的 filter 删除所有点
    # 注意：空的 filter {} 在某些版本可能不工作，使用 must: [] 更可靠
    local delete_result=$(curl -s -w "\n%{http_code}" -X POST \
        -H "api-key: $API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"filter": {"must": []}}' \
        "$TARGET_URL/collections/$collection/points/delete?wait=true")
    
    local http_code=$(echo "$delete_result" | tail -n1)
    local body=$(echo "$delete_result" | sed '$d')
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        # 验证是否清空成功
        sleep 1
        local verify_info=$(curl -s -H "api-key: $API_KEY" \
            "$TARGET_URL/collections/$collection" 2>/dev/null)
        local remaining_points=$(echo "$verify_info" | jq -r '.result.points_count // 0' 2>/dev/null)
        
        if [ "$remaining_points" = "0" ]; then
            log_info "目标集合已清空"
            return 0
        else
            log_warn "清空后仍有 $remaining_points 个点，可能需要重试"
            return 1
        fi
    else
        log_error "清空目标集合失败 (HTTP $http_code)"
        echo "$body" | jq '.' 2>/dev/null || echo "$body"
        return 1
    fi
}

# 迁移点数据
migrate_points() {
    local collection=$1
    # 使用全局批次大小配置
    local batch_size=${2:-$BATCH_SIZE}
    local total_points=0
    local migrated_points=0
    local offset=""
    
    log_info "开始迁移点数据..."
    
    # 获取集合信息以获取总点数
    local collection_info=$(curl -s -H "api-key: $API_KEY" \
        "$SOURCE_URL/collections/$collection")
    local points_count=$(echo "$collection_info" | jq -r '.result.points_count // 0')
    
    if [ "$points_count" = "0" ] || [ -z "$points_count" ]; then
        log_warn "集合 $collection 没有点数据，跳过"
        return 0
    fi
    
    log_info "集合 $collection 共有 $points_count 个点"
    
    # 分批迁移
    while true; do
        # 构建 scroll 请求
        local scroll_payload="{\"limit\": $batch_size"
        if [ -n "$offset" ] && [ "$offset" != "null" ]; then
            # offset 可能是数字或字符串，需要根据实际类型处理
            # 如果是数字，直接使用；如果是字符串，需要加引号
            if [[ "$offset" =~ ^[0-9]+$ ]]; then
                scroll_payload="$scroll_payload, \"offset\": $offset"
            else
                scroll_payload="$scroll_payload, \"offset\": \"$offset\""
            fi
        fi
        scroll_payload="$scroll_payload, \"with_payload\": true, \"with_vectors\": true}"
        
        # 获取一批点
        local scroll_result=$(curl -s -X POST \
            -H "api-key: $API_KEY" \
            -H "Content-Type: application/json" \
            -d "$scroll_payload" \
            "$SOURCE_URL/collections/$collection/points/scroll")
        
        # 使用临时文件存储响应
        local scroll_result_file=$(mktemp)
        echo "$scroll_result" > "$scroll_result_file"
        
        # 使用 Python 解析 JSON（Python 的 json 模块可以处理包含未转义控制字符的 JSON）
        local python_cmd=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
        
        if [ -z "$python_cmd" ]; then
            log_error "Python 不可用，无法解析 JSON"
            log_error "请安装 Python3: apt-get install python3 或 apk add python3"
            rm -f "$scroll_result_file"
            return 1
        fi
        
        # 创建 Python 脚本临时文件
        local python_script=$(mktemp)
        cat > "$python_script" << 'PYTHON_SCRIPT'
import json
import sys
import re

def clean_control_chars(text):
    """清理字符串中的未转义控制字符（U+0000 到 U+001F）"""
    # 最简单有效的方法：直接移除所有控制字符
    # 注意：这会移除未转义的控制字符，但保留已转义的（如 \\n）
    # 因为已转义的字符在文本中是两个字符 '\\' 和 'n'，不会被正则匹配
    return re.sub(r'[\x00-\x1f]', '', text)

try:
    input_file = sys.argv[1]
    
    # 读取文件内容
    with open(input_file, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()
    
    # 尝试直接解析 JSON
    try:
        data = json.loads(content)
    except json.JSONDecodeError as e1:
        # 如果失败，清理控制字符后重试
        cleaned_content = clean_control_chars(content)
        try:
            data = json.loads(cleaned_content)
        except json.JSONDecodeError as e2:
            # 如果还是失败，使用更激进的方法：移除所有控制字符和扩展控制字符
            aggressive_cleaned = re.sub(r'[\x00-\x1f\x7f-\x9f]', '', content)
            try:
                data = json.loads(aggressive_cleaned)
            except json.JSONDecodeError as e3:
                print(f"ERROR:JSON解析失败: {e3}", file=sys.stderr)
                print(f"ERROR:位置: line {e3.lineno}, column {e3.colno}", file=sys.stderr)
                sys.exit(1)
    
    # 检查错误
    if 'error' in data:
        error_msg = data.get('error', {})
        if isinstance(error_msg, dict):
            error_msg = error_msg.get('message', str(error_msg))
        print(f"ERROR:{error_msg}", file=sys.stderr)
        sys.exit(1)
    
    # 提取 points_count 和 next_offset
    result = data.get('result', {})
    points = result.get('points', [])
    points_count = len(points)
    next_offset = result.get('next_page_offset')
    
    # 检查是否有 sparse vector
    has_sparse = False
    if points and len(points) > 0:
        first_point = points[0]
        if 'vector' in first_point and isinstance(first_point['vector'], dict):
            if 'sparse' in first_point['vector']:
                has_sparse = True
    
    # 构建上传 payload
    upload_payload = {'points': points}
    upload_payload_json = json.dumps(upload_payload, ensure_ascii=False)
    
    # 输出格式: points_count|next_offset|has_sparse|upload_payload_json
    print(f"{points_count}|{next_offset}|{has_sparse}|{upload_payload_json}")
    
except Exception as e:
    print(f"ERROR:处理失败: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_SCRIPT
        
        # 执行 Python 脚本
        local json_info=$($python_cmd "$python_script" "$scroll_result_file" 2>&1)
        local python_exit_code=$?
        
        # 清理 Python 脚本文件
        rm -f "$python_script"
        
        # 检查 Python 执行是否成功
        if [ $python_exit_code -ne 0 ]; then
            log_error "Python JSON 解析失败"
            log_error "响应大小: $(wc -c < "$scroll_result_file") 字节"
            log_error "响应前200字符: $(head -c 200 "$scroll_result_file")"
            log_error "Python 错误: $json_info"
            rm -f "$scroll_result_file"
            return 1
        fi
        
        # 检查是否有错误
        if echo "$json_info" | grep -q "^ERROR:"; then
            local error_msg=$(echo "$json_info" | grep "^ERROR:" | sed 's/^ERROR://')
            log_error "Scroll 请求失败: $error_msg"
            rm -f "$scroll_result_file"
            return 1
        fi
        
        # 提取 points_count、next_offset、has_sparse 和 upload_payload（格式: points_count|next_offset|has_sparse|upload_payload_json）
        local points_count=$(echo "$json_info" | cut -d'|' -f1)
        local next_offset=$(echo "$json_info" | cut -d'|' -f2)
        local has_sparse=$(echo "$json_info" | cut -d'|' -f3)
        local upload_payload=$(echo "$json_info" | cut -d'|' -f4-)
        
        # 验证提取的数据
        if [ -z "$points_count" ] || [ -z "$upload_payload" ]; then
            log_error "无法从 JSON 响应中提取数据"
            log_error "提取的信息: $json_info"
            rm -f "$scroll_result_file"
            return 1
        fi
        
        # 检查是否还有数据
        if [ "$points_count" = "0" ] || [ -z "$points_count" ] || [ "$points_count" = "null" ]; then
            log_info "所有点数据已迁移完成"
            rm -f "$scroll_result_file"
            break
        fi
        
        migrated_points=$((migrated_points + points_count))
        
        # 构建上传 payload（使用临时文件避免参数过长）
        local temp_file=$(mktemp)
        echo "$upload_payload" > "$temp_file"
        
        # 如果点数据中有 sparse vector，检查目标集合是否支持
        if [ "$has_sparse" = "True" ]; then
            local target_config=$(curl -s -H "api-key: $API_KEY" \
                "$TARGET_URL/collections/$collection" 2>/dev/null)
            local target_has_sparse=$(echo "$target_config" | jq -r '.result.config.params.sparse_vectors // empty' 2>/dev/null)
            
            if [ -z "$target_has_sparse" ] || [ "$target_has_sparse" = "null" ]; then
                log_error "点数据包含 sparse vector，但目标集合不支持 sparse vectors"
                log_error "请删除目标集合并重新创建，或手动更新集合配置"
                rm -f "$temp_file" "$scroll_result_file"
                return 1
            fi
        fi
        
        # 清理 scroll_result 临时文件
        rm -f "$scroll_result_file"
        
        # 上传到目标集群（wait 参数在 URL 中）
        local upload_result=$(curl -s -w "\n%{http_code}" -X PUT \
            -H "api-key: $API_KEY" \
            -H "Content-Type: application/json" \
            --data-binary "@$temp_file" \
            "$TARGET_URL/collections/$collection/points?wait=true")
        
        # 清理临时文件
        rm -f "$temp_file"
        
        local upload_http_code=$(echo "$upload_result" | tail -n1)
        local upload_body=$(echo "$upload_result" | sed '$d')
        
        if [ "$upload_http_code" = "200" ] || [ "$upload_http_code" = "201" ]; then
            # 检查响应中是否有错误信息（即使 HTTP 状态码是 200）
            if echo "$upload_body" | jq -e '.status.error // .error' > /dev/null 2>&1; then
                local error_msg=$(echo "$upload_body" | jq -r '.status.error // .error.message // .error' 2>/dev/null)
                log_error "上传点数据失败: $error_msg"
                echo "$upload_body" | jq '.' 2>/dev/null || echo "$upload_body"
                return 1
            fi
            # 减少日志输出频率：根据配置的间隔输出
            if [ $((migrated_points % LOG_INTERVAL)) -eq 0 ] || [ "$migrated_points" -eq "$points_count" ]; then
                log_info "已迁移 $migrated_points/$points_count 个点"
            fi
        else
            log_error "上传点数据失败 (HTTP $upload_http_code)"
            log_error "响应内容: $upload_body"
            # 保存失败的 payload 用于调试
            echo "$upload_payload" > "/tmp/failed_upload_${collection}_${migrated_points}.json" 2>/dev/null || true
            echo "$upload_body" | jq '.' 2>/dev/null || echo "$upload_body"
            rm -f "$temp_file"
            return 1
        fi
        
        # 清理上传临时文件
        rm -f "$temp_file"
        
        # 更新 offset（已在 Python 脚本中提取）
        offset="$next_offset"
        
        # 如果没有 next_page_offset，说明没有更多数据了
        if [ -z "$offset" ] || [ "$offset" = "null" ]; then
            log_info "所有点数据已迁移完成"
            break
        fi
        
        # 继续下一批（移除延迟以提高性能）
    done
    
    log_info "点数据迁移完成: $migrated_points 个点"
}

# 迁移单个集合
migrate_collection() {
    local collection=$1
    
    log_info ""
    log_info "========================================="
    log_info "迁移集合: $collection"
    log_info "========================================="
    
    # 1. 获取集合配置
    log_info "步骤 1/3: 获取集合配置..."
    local config=$(get_collection_config "$collection")
    if [ -z "$config" ] || [ "$config" = "null" ]; then
        log_error "无法获取集合配置"
        return 1
    fi
    
    # 2. 创建集合
    log_info "步骤 2/4: 创建目标集合..."
    if ! create_collection "$collection" "$config"; then
        log_error "创建集合失败，跳过"
        return 1
    fi
    
    # 3. 清空目标集合（如果已有数据）
    log_info "步骤 3/4: 清空目标集合..."
    if ! clear_target_collection "$collection"; then
        log_warn "清空目标集合失败，继续迁移（可能会产生重复数据）"
    fi
    
    # 4. 迁移点数据
    log_info "步骤 4/4: 迁移点数据..."
    migrate_points "$collection"
    
    log_info "集合 $collection 迁移完成"
}

# 验证迁移结果
verify_migration() {
    local collection=$1
    
    log_info "验证集合 $collection 的迁移结果..."
    
    # 等待数据同步（Qdrant 可能需要一点时间）
    sleep 1
    
    # 获取源集合信息
    local source_info=$(curl -s -H "api-key: $API_KEY" \
        "$SOURCE_URL/collections/$collection")
    local source_count=$(echo "$source_info" | jq -r '.result.points_count // 0')
    
    # 获取目标集合信息（重试几次，因为数据可能还在同步）
    local target_count=0
    local retry=0
    while [ $retry -lt 3 ]; do
        local target_info=$(curl -s -H "api-key: $API_KEY" \
            "$TARGET_URL/collections/$collection")
        target_count=$(echo "$target_info" | jq -r '.result.points_count // 0' 2>/dev/null || echo "0")
        
        # 确保是数字
        target_count=${target_count:-0}
        source_count=${source_count:-0}
        
        if [ "$target_count" = "$source_count" ] && [ "$source_count" -gt 0 ]; then
            break
        fi
        
        if [ $retry -lt 2 ]; then
            sleep 1
        fi
        retry=$((retry + 1))
    done
    
    # 确保都是数字
    source_count=${source_count:-0}
    target_count=${target_count:-0}
    
    if [ "$source_count" = "$target_count" ]; then
        log_info "✓ 验证通过: 源集群 $source_count 个点，目标集群 $target_count 个点"
        return 0
    else
        log_warn "⚠ 点数不匹配: 源集群 $source_count 个点，目标集群 $target_count 个点"
        # 输出目标集群的详细信息用于调试
        local target_info=$(curl -s -H "api-key: $API_KEY" \
            "$TARGET_URL/collections/$collection")
        log_warn "目标集群集合信息: $(echo "$target_info" | jq '.result | {points_count, status}' 2>/dev/null || echo 'unknown')"
        return 1
    fi
}

# 主函数
main() {
    log_info "========================================="
    log_info "Qdrant API 数据迁移工具"
    log_info "========================================="
    log_info ""
    
    # 检测集群访问方式并设置 URL
    # 注意：check_cluster_access 返回 2 表示需要在 Pod 内执行，这是正常的，不应该触发 set -e
    set +e  # 临时禁用 set -e，以便捕获返回值 2
    check_cluster_access
    local access_result=$?
    set -e  # 重新启用 set -e
    
    if [ "$access_result" = "2" ]; then
        # 集群外访问，在目标 Pod 内执行（使用内网地址）
        # 脚本在本地执行，但迁移操作在目标 Pod 内完成，使用内网地址访问源集群和目标集群
        log_info ""
        log_info "执行方式: 本地脚本 -> kubectl exec -> 目标 Pod 内执行迁移"
        log_info "网络访问: Pod 内使用内网地址 (svc.cluster.local)"
        log_info ""
        execute_in_target_pod
        exit $?
    elif [ "$access_result" != "0" ]; then
        # 集群外访问，使用 port-forward（备选方案）
        setup_port_forward
    fi
    
    log_info "源集群: $SOURCE_URL"
    log_info "目标集群: $TARGET_URL"
    log_info ""
    
    # 检查连接
    check_connection
    
    # 获取集合列表
    local collections=$(get_collections)
    if [ -z "$collections" ]; then
        log_warn "没有需要迁移的集合"
        exit 0
    fi
    
    # 统计测试集合数量（用于日志）
    local all_collections_json=$(curl -s -H "api-key: $API_KEY" "$SOURCE_URL/collections" 2>/dev/null)
    local test_collections=$(echo "$all_collections_json" | jq -r '.result.collections[]?.name // empty' 2>/dev/null | \
        grep -v '^$' | grep -E '^[a-zA-Z0-9_\-]+' | \
        grep -i -E '(benchmark|test)' 2>/dev/null | wc -l | tr -d ' ')
    
    if [ -n "$test_collections" ] && [ "$test_collections" -gt 0 ]; then
        log_info "跳过 $test_collections 个测试集合（包含 benchmark/test）"
    fi
    
    log_info "找到以下集合需要迁移:"
    echo "$collections" | while IFS= read -r coll; do
        # 过滤掉空行和日志信息
        if [ -n "$coll" ] && [[ ! "$coll" =~ ^\[.*\] ]]; then
            echo "  - $coll"
        fi
    done
    log_info ""
    
    # 迁移每个集合（支持并行）
    local success_count=0
    local fail_count=0
    local pids=()
    local collection_array=()
    
    # 收集所有需要迁移的集合
    while IFS= read -r collection || [ -n "$collection" ]; do
        # 过滤掉空行和日志信息
        if [ -z "$collection" ] || [[ "$collection" =~ ^\[.*\] ]] || [[ ! "$collection" =~ ^[a-zA-Z0-9_\-]+ ]]; then
            continue
        fi
        collection_array+=("$collection")
    done < <(printf '%s\n' "$collections")
    
    local total_collections=${#collection_array[@]}
    
    # 如果 PARALLEL_JOBS <= 0，使用串行模式（更快，因为避免了锁和日志管理开销）
    if [ "$PARALLEL_JOBS" -le 0 ]; then
        log_info "使用串行模式迁移 $total_collections 个集合"
        
        # 串行迁移（更简单，通常更快）
        for collection in "${collection_array[@]}"; do
            if migrate_collection "$collection"; then
                verify_migration "$collection"
                success_count=$((success_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
        done
    else
        log_info "开始并行迁移 $total_collections 个集合（并发数: $PARALLEL_JOBS）"
        
        # 并行迁移函数（简化日志，减少锁的使用）
        migrate_collection_parallel() {
            local collection=$1
            local log_file="/tmp/migrate_${collection}.log"
            
            # 执行迁移并记录日志（静默模式，减少输出）
            {
                migrate_collection "$collection" && verify_migration "$collection"
            } > "$log_file" 2>&1
            
            local exit_code=$?
            
            # 只在完成后输出关键信息，减少锁的使用
            (
                flock -n 9 2>/dev/null || true
                echo "[集合: $collection] - $(tail -n 5 "$log_file" | grep -E '(迁移完成|验证通过|点数不匹配)' || echo '完成')"
            ) 9>/tmp/migrate_log.lock 2>/dev/null || {
                # 如果锁失败，直接输出（可能混乱但至少能工作）
                echo "[集合: $collection] - 完成"
            }
            
            rm -f "$log_file"
            return $exit_code
        }
        
        # 并行执行迁移
        local current_index=0
        while [ $current_index -lt $total_collections ]; do
            # 等待有可用的并行槽位
            while [ ${#pids[@]} -ge $PARALLEL_JOBS ]; do
                local new_pids=()
                for pid in "${pids[@]}"; do
                    if kill -0 "$pid" 2>/dev/null; then
                        # 进程仍在运行
                        new_pids+=("$pid")
                    else
                        # 进程已完成，等待并获取退出码
                        wait "$pid" 2>/dev/null
                        local exit_code=$?
                        if [ $exit_code -eq 0 ]; then
                            success_count=$((success_count + 1))
                        else
                            fail_count=$((fail_count + 1))
                        fi
                    fi
                done
                pids=("${new_pids[@]}")
                sleep 0.1
            done
            
            # 启动新的迁移任务
            local collection="${collection_array[$current_index]}"
            log_info "[$((current_index + 1))/$total_collections] 启动迁移: $collection"
            migrate_collection_parallel "$collection" &
            pids+=($!)
            current_index=$((current_index + 1))
        done
        
        # 等待所有剩余任务完成
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                wait "$pid" 2>/dev/null
                local exit_code=$?
                if [ $exit_code -eq 0 ]; then
                    success_count=$((success_count + 1))
                else
                    fail_count=$((fail_count + 1))
                fi
            else
                # 进程已完成，获取退出码
                wait "$pid" 2>/dev/null
                local exit_code=$?
                if [ $exit_code -eq 0 ]; then
                    success_count=$((success_count + 1))
                else
                    fail_count=$((fail_count + 1))
                fi
            fi
        done
    fi
    
    log_info ""
    log_info "========================================="
    log_info "迁移完成"
    log_info "========================================="
    log_info "成功: $success_count 个集合"
    log_info "失败: $fail_count 个集合"
    log_info "总计: $total_collections 个集合"
    log_info ""
    log_info "请手动验证目标集群的数据完整性"
    log_info "验证命令:"
    log_info "  curl -H \"api-key: $API_KEY\" $TARGET_URL/collections"
    
    # 清理临时文件
    rm -f /tmp/migrate_log.lock /tmp/migrate_*.log /tmp/migrate_status_*.txt 2>/dev/null || true
}

# 运行主函数
main "$@"

