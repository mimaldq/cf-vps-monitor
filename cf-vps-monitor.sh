#!/bin/bash

# cf-vps-monitor - Cloudflare Worker VPS监控脚本
# 版本: 2.1.0
# 支持一键安装，优化容器内存检测

set -euo pipefail

# 初始化系统类型变量
OS=$(uname -s)
export OS

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 全局变量 - 集中式文件管理
SCRIPT_DIR="$HOME/.cf-vps-monitor"
CONFIG_FILE="$SCRIPT_DIR/config/config"
LOG_FILE="$SCRIPT_DIR/logs/monitor.log"
PID_FILE="$SCRIPT_DIR/run/monitor.pid"
SERVICE_FILE="$SCRIPT_DIR/bin/vps-monitor-service.sh"

# 默认配置
DEFAULT_INTERVAL=10

# 打印带颜色的消息
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# 日志函数
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE"
    
    # 只在非服务模式下输出到控制台
    if [[ "${SERVICE_MODE:-false}" != "true" ]]; then
        echo "[$timestamp] $message"
    fi
}

# 错误处理
error_exit() {
    local message="$1"
    print_message "$RED" "错误: $message"
    log "ERROR: $message"
    exit 1
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ==================== 系统检测 ====================

# 检测系统信息
detect_system() {
    local system_info=$(uname -srm)
    IFS=' ' read -r OS KERNEL_VERSION ARCH <<< "$system_info"

    if [[ "$OS" == "FreeBSD" ]]; then
        VER=$(echo "$KERNEL_VERSION" | cut -d'-' -f1)
        DISTRO_ID="freebsd"
        DISTRO_NAME="FreeBSD"
        print_message "$GREEN" "检测到系统: FreeBSD $VER"
    elif [[ "$OS" == "Darwin" ]]; then
        VER=$(sw_vers -productVersion 2>/dev/null || echo "$KERNEL_VERSION")
        DISTRO_ID="macos"
        DISTRO_NAME="macOS"
        print_message "$GREEN" "检测到系统: macOS $VER"
    else
        # Linux系统
        if [[ -f /etc/os-release ]]; then
            local os_info=$(cat /etc/os-release 2>/dev/null)
            DISTRO_ID=$(echo "$os_info" | grep '^ID=' | cut -d= -f2 | tr -d '"' || echo "linux")
            VER=$(echo "$os_info" | grep '^VERSION_ID=' | cut -d= -f2 | tr -d '"' || echo "unknown")
            DISTRO_NAME=$(echo "$os_info" | grep '^NAME=' | cut -d= -f2 | tr -d '"' || echo "Linux")
        else
            DISTRO_ID="linux"
            VER="unknown"
            DISTRO_NAME="Linux"
        fi

        print_message "$GREEN" "检测到系统: $DISTRO_NAME $VER"
    fi

    # 检测容器环境
    if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup 2>/dev/null; then
        IS_CONTAINER="true"
        CONTAINER_TYPE="docker"
        print_message "$YELLOW" "检测到容器环境"
    else
        IS_CONTAINER="false"
        CONTAINER_TYPE="none"
    fi

    export OS ARCH KERNEL_VERSION VER DISTRO_ID DISTRO_NAME
    export IS_CONTAINER CONTAINER_TYPE
}

# ==================== 依赖检查 ====================

# 检查并安装依赖
install_dependencies() {
    print_message "$BLUE" "检查系统依赖..."
    
    local missing_deps=()
    
    # 检查必需的命令
    if ! command_exists curl; then
        missing_deps+=("curl")
    fi
    
    if ! command_exists bc; then
        missing_deps+=("bc")
    fi
    
    if [[ ${#missing_deps[@]} -eq 0 ]]; then
        print_message "$GREEN" "所有必需依赖已安装"
        return 0
    fi

    print_message "$YELLOW" "缺少必需依赖: ${missing_deps[*]}"
    
    # 尝试自动安装
    if [[ -f /etc/debian_version ]]; then
        print_message "$BLUE" "尝试安装依赖 (Debian/Ubuntu)..."
        apt-get update && apt-get install -y "${missing_deps[@]}" || return 1
    elif [[ -f /etc/redhat-release ]]; then
        print_message "$BLUE" "尝试安装依赖 (CentOS/RHEL)..."
        yum install -y "${missing_deps[@]}" || return 1
    elif [[ -f /etc/alpine-release ]]; then
        print_message "$BLUE" "尝试安装依赖 (Alpine)..."
        apk add "${missing_deps[@]}" || return 1
    else
        print_message "$YELLOW" "请手动安装依赖: ${missing_deps[*]}"
        return 1
    fi
    
    print_message "$GREEN" "依赖安装完成"
}

# ==================== 内存检测优化 ====================

# 获取容器内存限制（优化版）
get_container_memory() {
    local total=0 used=0 free=0
    
    # 优先使用 cgroup v2
    if [[ -f /sys/fs/cgroup/memory.max ]]; then
        local max_raw=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
        if [[ "$max_raw" != "max" && "$max_raw" =~ ^[0-9]+$ ]]; then
            total=$((max_raw / 1024))  # 转换为KB
            if [[ -f /sys/fs/cgroup/memory.current ]]; then
                used=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo "0")
                used=$((used / 1024))
                free=$((total - used))
            fi
        fi
    fi
    
    # 如果 cgroup v2 没有限制，尝试 cgroup v1
    if [[ $total -eq 0 ]] && [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
        local limit_raw=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        # 忽略极大的值 (未限制)
        if [[ "$limit_raw" =~ ^[0-9]+$ && "$limit_raw" -lt 9223372036854771712 ]]; then
            total=$((limit_raw / 1024))
            if [[ -f /sys/fs/cgroup/memory/memory.usage_in_bytes ]]; then
                used=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo "0")
                used=$((used / 1024))
                free=$((total - used))
            fi
        fi
    fi
    
    # 如果还是没有获取到限制，使用系统内存
    if [[ $total -eq 0 ]]; then
        return 1
    fi
    
    echo "$total $used $free"
}

# 获取系统内存（物理机）
get_system_memory() {
    local total=0 used=0 free=0
    
    # 优先使用 free 命令
    if command_exists free; then
        local mem_info=$(free -k 2>/dev/null | grep "^Mem:")
        if [[ -n "$mem_info" ]]; then
            total=$(echo "$mem_info" | awk '{print $2}')
            # 尝试获取 available 列
            local available=$(echo "$mem_info" | awk '{print $7}' 2>/dev/null || echo "")
            if [[ "$available" =~ ^[0-9]+$ ]]; then
                free=$available
                used=$((total - free))
            else
                local mem_free=$(echo "$mem_info" | awk '{print $4}' 2>/dev/null || echo "0")
                local buff_cache=$(echo "$mem_info" | awk '{print $6}' 2>/dev/null || echo "0")
                free=$((mem_free + buff_cache))
                used=$((total - free))
            fi
        fi
    fi
    
    # 备用方法：读取 /proc/meminfo
    if [[ $total -eq 0 ]] && [[ -f /proc/meminfo ]]; then
        total=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
        local mem_free=$(grep "^MemFree:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
        local buffers=$(grep "^Buffers:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
        local cached=$(grep "^Cached:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
        free=$((mem_free + buffers + cached))
        used=$((total - free))
    fi
    
    echo "$total $used $free"
}

# 获取内存使用情况（智能选择）
get_memory_usage() {
    local total used free usage_percent
    
    # 容器环境优先使用容器内存限制
    if [[ "$IS_CONTAINER" == "true" ]]; then
        local container_mem=$(get_container_memory)
        if [[ -n "$container_mem" ]]; then
            read -r total used free <<< "$container_mem"
        else
            # 容器无限制，使用系统内存
            local system_mem=$(get_system_memory)
            read -r total used free <<< "$system_mem"
        fi
    else
        # 物理机使用系统内存
        local system_mem=$(get_system_memory)
        read -r total used free <<< "$system_mem"
    fi
    
    # 数据验证和修正
    total=${total:-0}
    used=${used:-0}
    free=${free:-0}
    
    if [[ $total -eq 0 ]]; then
        usage_percent=0
    else
        # 确保 used 不超过 total
        if [[ $used -gt $total ]]; then
            used=$total
            free=0
        fi
        if [[ $free -lt 0 ]]; then
            free=0
            used=$total
        fi
        
        # 计算使用率
        usage_percent=$(echo "scale=1; $used * 100 / $total" | bc 2>/dev/null || echo "0")
        [[ ! "$usage_percent" =~ ^[0-9]+\.?[0-9]*$ ]] && usage_percent="0"
    fi
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# ==================== 其他监控指标 ====================

# 获取CPU使用率
get_cpu_usage() {
    local cpu_usage=0
    local load1=0 load5=0 load15=0
    
    if [[ -f /proc/stat ]]; then
        local cpu_line=$(head -n1 /proc/stat 2>/dev/null)
        if [[ -n "$cpu_line" ]]; then
            local cpu_times=($cpu_line)
            local idle=${cpu_times[4]}
            local iowait=${cpu_times[5]:-0}
            local total=0
            
            for i in {1..7}; do
                if [[ -n "${cpu_times[i]}" && "${cpu_times[i]}" =~ ^[0-9]+$ ]]; then
                    total=$((total + cpu_times[i]))
                fi
            done
            
            if [[ $total -gt 0 ]]; then
                cpu_usage=$(echo "scale=1; 100 - (($idle + $iowait) * 100 / $total)" | bc 2>/dev/null || echo "0")
            fi
        fi
    fi
    
    # 获取负载平均值
    if [[ -f /proc/loadavg ]]; then
        local load_data=$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}' || echo "0 0 0")
        read -r load1 load5 load15 <<< "$load_data"
    fi
    
    echo "{\"usage_percent\":$cpu_usage,\"load_avg\":[$load1,$load5,$load15]}"
}

# 获取磁盘使用情况
get_disk_usage() {
    local total=0 used=0 free=0 usage_percent=0
    
    if command_exists df; then
        local disk_info=$(df -k / 2>/dev/null | tail -1)
        if [[ -n "$disk_info" ]]; then
            total=$(echo "$disk_info" | awk '{printf "%.2f", $2 / 1024 / 1024}' 2>/dev/null || echo "0")
            used=$(echo "$disk_info" | awk '{printf "%.2f", $3 / 1024 / 1024}' 2>/dev/null || echo "0")
            free=$(echo "$disk_info" | awk '{printf "%.2f", $4 / 1024 / 1024}' 2>/dev/null || echo "0")
            usage_percent=$(echo "$disk_info" | awk '{print $5}' | tr -d '%' 2>/dev/null || echo "0")
        fi
    fi
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# 获取网络使用情况
get_network_usage() {
    local upload_speed=0 download_speed=0 total_upload=0 total_download=0
    
    # 获取默认网络接口
    local interface=""
    if command_exists ip; then
        interface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
    fi
    
    if [[ -n "$interface" ]] && [[ -f "/proc/net/dev" ]]; then
        local net_line=$(grep "^ *$interface:" /proc/net/dev 2>/dev/null)
        if [[ -n "$net_line" ]]; then
            local stats=($net_line)
            total_download=${stats[1]}  # 接收字节数
            total_upload=${stats[9]}    # 发送字节数
        fi
    fi
    
    echo "{\"upload_speed\":$upload_speed,\"download_speed\":$download_speed,\"total_upload\":$total_upload,\"total_download\":$total_download}"
}

# 获取系统运行时间
get_uptime() {
    local uptime_seconds=0
    if [[ -f /proc/uptime ]]; then
        uptime_seconds=$(cut -d. -f1 /proc/uptime)
    fi
    echo "$uptime_seconds"
}

# ==================== 配置文件管理 ====================

# 创建目录结构
create_directories() {
    print_message "$BLUE" "创建目录结构..."
    mkdir -p "$SCRIPT_DIR"/{bin,config,logs,tmp,run} || error_exit "无法创建目录结构"
    print_message "$GREEN" "✓ 目录结构创建完成"
}

# 加载配置
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi
}

# 保存配置
save_config() {
    cat > "$CONFIG_FILE" << EOF
# VPS监控配置文件
WORKER_URL="$WORKER_URL"
SERVER_ID="$SERVER_ID"
API_KEY="$API_KEY"
INTERVAL="$INTERVAL"
EOF
    print_message "$GREEN" "配置已保存"
}

# ==================== 服务管理 ====================

# 创建监控服务脚本
create_service_script() {
    cat > "$SERVICE_FILE" << 'EOF'
#!/bin/bash

# cf-vps-monitor服务脚本
SCRIPT_DIR="$HOME/.cf-vps-monitor"
CONFIG_FILE="$SCRIPT_DIR/config/config"
LOG_FILE="$SCRIPT_DIR/logs/monitor.log"

# 设置服务模式标志
export SERVICE_MODE=true

# 确保日志目录存在
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

# 加载配置
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "配置文件不存在: $CONFIG_FILE"
    exit 1
fi

# 日志函数
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE"
}

# 获取容器内存
get_container_memory() {
    local total=0 used=0 free=0
    
    if [[ -f /sys/fs/cgroup/memory.max ]]; then
        local max_raw=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
        if [[ "$max_raw" != "max" && "$max_raw" =~ ^[0-9]+$ ]]; then
            total=$((max_raw / 1024))
            if [[ -f /sys/fs/cgroup/memory.current ]]; then
                used=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo "0")
                used=$((used / 1024))
                free=$((total - used))
            fi
        fi
    fi
    
    if [[ $total -eq 0 ]] && [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
        local limit_raw=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        if [[ "$limit_raw" =~ ^[0-9]+$ && "$limit_raw" -lt 9223372036854771712 ]]; then
            total=$((limit_raw / 1024))
            if [[ -f /sys/fs/cgroup/memory/memory.usage_in_bytes ]]; then
                used=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo "0")
                used=$((used / 1024))
                free=$((total - used))
            fi
        fi
    fi
    
    [[ $total -eq 0 ]] && return 1
    echo "$total $used $free"
}

# 获取系统内存
get_system_memory() {
    local total=0 used=0 free=0
    
    if command_exists free; then
        local mem_info=$(free -k 2>/dev/null | grep "^Mem:")
        if [[ -n "$mem_info" ]]; then
            total=$(echo "$mem_info" | awk '{print $2}')
            local available=$(echo "$mem_info" | awk '{print $7}' 2>/dev/null || echo "")
            if [[ "$available" =~ ^[0-9]+$ ]]; then
                free=$available
                used=$((total - free))
            else
                local mem_free=$(echo "$mem_info" | awk '{print $4}' 2>/dev/null || echo "0")
                local buff_cache=$(echo "$mem_info" | awk '{print $6}' 2>/dev/null || echo "0")
                free=$((mem_free + buff_cache))
                used=$((total - free))
            fi
        fi
    fi
    
    if [[ $total -eq 0 ]] && [[ -f /proc/meminfo ]]; then
        total=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
        local mem_free=$(grep "^MemFree:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
        local buffers=$(grep "^Buffers:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
        local cached=$(grep "^Cached:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
        free=$((mem_free + buffers + cached))
        used=$((total - free))
    fi
    
    echo "$total $used $free"
}

# 获取内存使用情况
get_memory_usage() {
    local total used free usage_percent
    
    # 检测是否在容器中
    if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup 2>/dev/null; then
        local container_mem=$(get_container_memory)
        if [[ -n "$container_mem" ]]; then
            read -r total used free <<< "$container_mem"
        else
            local system_mem=$(get_system_memory)
            read -r total used free <<< "$system_mem"
        fi
    else
        local system_mem=$(get_system_memory)
        read -r total used free <<< "$system_mem"
    fi
    
    total=${total:-0}
    used=${used:-0}
    free=${free:-0}
    
    if [[ $total -eq 0 ]]; then
        usage_percent=0
    else
        [[ $used -gt $total ]] && used=$total
        [[ $free -lt 0 ]] && free=0
        usage_percent=$(echo "scale=1; $used * 100 / $total" | bc 2>/dev/null || echo "0")
    fi
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# 获取CPU使用率
get_cpu_usage() {
    local cpu_usage=0
    local load1=0 load5=0 load15=0
    
    if [[ -f /proc/stat ]]; then
        local cpu_line=$(head -n1 /proc/stat 2>/dev/null)
        if [[ -n "$cpu_line" ]]; then
            local cpu_times=($cpu_line)
            local idle=${cpu_times[4]}
            local total=0
            
            for i in {1..7}; do
                [[ -n "${cpu_times[i]}" ]] && total=$((total + cpu_times[i]))
            done
            
            [[ $total -gt 0 ]] && cpu_usage=$(echo "scale=1; 100 - ($idle * 100 / $total)" | bc 2>/dev/null || echo "0")
        fi
    fi
    
    if [[ -f /proc/loadavg ]]; then
        local load_data=$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}' || echo "0 0 0")
        read -r load1 load5 load15 <<< "$load_data"
    fi
    
    echo "{\"usage_percent\":$cpu_usage,\"load_avg\":[$load1,$load5,$load15]}"
}

# 上报监控数据
report_metrics() {
    local timestamp=$(date +%s)
    local cpu_raw=$(get_cpu_usage)
    local memory_raw=$(get_memory_usage)
    local disk_raw=$(get_disk_usage)
    local network_raw=$(get_network_usage)
    local uptime_raw=$(get_uptime)
    
    # 构建JSON数据
    local data="{\"timestamp\":$timestamp,\"cpu\":$cpu_raw,\"memory\":$memory_raw,\"disk\":$disk_raw,\"network\":$network_raw,\"uptime\":$uptime_raw}"
    
    log "正在上报数据..."
    
    local response=$(curl -s -w "%{http_code}" -X POST "$WORKER_URL/api/report/$SERVER_ID" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: $API_KEY" \
        -d "$data" 2>/dev/null || echo "000")
    
    local http_code="${response: -3}"
    
    if [[ "$http_code" == "200" ]]; then
        log "数据上报成功"
        return 0
    else
        log "数据上报失败 (HTTP $http_code)"
        return 1
    fi
}

# 主循环
main() {
    log "VPS监控服务启动 (PID: $$)"
    echo $$ > "$SCRIPT_DIR/run/monitor.pid"
    
    # 信号处理
    trap 'log "收到终止信号，正在停止..."; rm -f "$SCRIPT_DIR/run/monitor.pid"; exit 0' TERM INT
    
    while true; do
        report_metrics
        sleep "$INTERVAL"
    done
}

# 启动主函数
main
EOF

    chmod +x "$SERVICE_FILE"
    print_message "$GREEN" "监控服务脚本创建完成"
}

# 启动监控服务
start_service() {
    print_message "$BLUE" "启动监控服务..."
    
    if [[ ! -f "$SERVICE_FILE" ]]; then
        print_message "$RED" "服务脚本不存在，请先安装"
        return 1
    fi
    
    # 检查是否已有进程在运行
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            print_message "$YELLOW" "监控服务已在运行 (PID: $pid)"
            return 0
        fi
    fi
    
    # 启动服务
    nohup "$SERVICE_FILE" >> "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        print_message "$GREEN" "✓ 监控服务已启动 (PID: $pid)"
        print_message "$CYAN" "日志文件: $LOG_FILE"
        return 0
    else
        print_message "$RED" "✗ 监控服务启动失败"
        return 1
    fi
}

# 停止监控服务
stop_service() {
    print_message "$BLUE" "停止监控服务..."
    
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null && sleep 1
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
            fi
            print_message "$GREEN" "✓ 监控服务已停止"
        else
            print_message "$YELLOW" "监控服务未运行"
        fi
        rm -f "$PID_FILE"
    else
        print_message "$YELLOW" "监控服务未运行"
    fi
}

# ==================== 一键安装函数 ====================

# 一键安装监控服务
one_click_install() {
    local server_id="$1"
    local api_key="$2"
    local worker_url="$3"
    
    print_message "$CYAN" "=================================="
    print_message "$CYAN" "    VPS监控服务一键安装"
    print_message "$CYAN" "=================================="
    echo
    
    # 验证必需参数
    if [[ -z "$server_id" || -z "$api_key" || -z "$worker_url" ]]; then
        print_message "$RED" "错误: 缺少必需参数"
        echo "必需参数: -s <服务器ID> -k <API密钥> -u <Worker地址>"
        return 1
    fi
    
    # 显示安装参数
    print_message "$BLUE" "安装参数:"
    echo "  服务器ID: $server_id"
    echo "  API密钥: ${api_key:0:8}..."
    echo "  Worker地址: $worker_url"
    echo "  上报间隔: ${DEFAULT_INTERVAL}秒"
    echo
    
    # 检测系统
    detect_system
    
    # 安装依赖
    install_dependencies || {
        print_message "$YELLOW" "依赖安装失败，尝试继续安装..."
    }
    
    # 创建目录结构
    create_directories
    
    # 设置配置参数
    WORKER_URL="$worker_url"
    SERVER_ID="$server_id"
    API_KEY="$api_key"
    INTERVAL="$DEFAULT_INTERVAL"
    
    # 保存配置
    save_config
    
    # 创建服务脚本
    create_service_script
    
    # 测试连接
    print_message "$BLUE" "测试连接..."
    if test_connection; then
        print_message "$GREEN" "✓ 连接测试成功"
    else
        print_message "$YELLOW" "⚠ 连接测试失败，但将继续安装"
    fi
    
    # 启动服务
    echo
    if start_service; then
        print_message "$GREEN" "=================================="
        print_message "$GREEN" "    VPS监控服务安装成功！"
        print_message "$GREEN" "=================================="
        echo
        print_message "$CYAN" "安装信息:"
        echo "  安装目录: $SCRIPT_DIR"
        echo "  配置文件: $CONFIG_FILE"
        echo "  日志文件: $LOG_FILE"
        echo "  服务脚本: $SERVICE_FILE"
        echo
        print_message "$YELLOW" "管理命令:"
        echo "  查看状态: $0 status"
        echo "  查看日志: $0 logs"
        echo "  停止服务: $0 stop"
        echo
        return 0
    else
        print_message "$RED" "✗ 服务启动失败"
        return 1
    fi
}

# 测试连接
test_connection() {
    local timestamp=$(date +%s)
    local test_data='{"timestamp":'$timestamp',"test":"connection"}'
    
    local response=$(curl -s -w "%{http_code}" -X POST "$WORKER_URL/api/report/$SERVER_ID" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: $API_KEY" \
        -d "$test_data" 2>/dev/null || echo "000")
    
    local http_code="${response: -3}"
    
    if [[ "$http_code" == "200" ]]; then
        return 0
    else
        return 1
    fi
}

# ==================== 管理命令 ====================

# 查看服务状态
check_status() {
    print_message "$BLUE" "检查监控服务状态..."
    
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            print_message "$GREEN" "✓ 监控服务正在运行 (PID: $pid)"
            
            # 显示配置信息
            if [[ -f "$CONFIG_FILE" ]]; then
                load_config
                echo
                print_message "$CYAN" "配置信息:"
                echo "  Worker URL: $WORKER_URL"
                echo "  Server ID: $SERVER_ID"
                echo "  API Key: ${API_KEY:0:8}..."
                echo "  上报间隔: ${INTERVAL}秒"
            fi
        else
            print_message "$RED" "✗ 监控服务未运行"
        fi
    else
        print_message "$RED" "✗ 监控服务未运行"
    fi
    
    # 显示日志文件信息
    if [[ -f "$LOG_FILE" ]]; then
        echo
        print_message "$CYAN" "日志文件:"
        echo "  位置: $LOG_FILE"
        echo "  大小: $(du -h "$LOG_FILE" 2>/dev/null | cut -f1)"
        echo "  最近日志:"
        tail -5 "$LOG_FILE" 2>/dev/null | while read line; do
            echo "    $line"
        done
    fi
}

# 查看日志
view_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        print_message "$YELLOW" "日志文件不存在"
        return
    fi
    
    print_message "$BLUE" "显示最近50行日志:"
    echo "----------------------------------------"
    tail -n 50 "$LOG_FILE"
    echo "----------------------------------------"
    print_message "$CYAN" "日志文件位置: $LOG_FILE"
}

# 卸载服务
uninstall_service() {
    print_message "$YELLOW" "警告: 这将卸载VPS监控服务"
    echo -n "确认卸载? (y/N): "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_message "$BLUE" "取消卸载"
        return 0
    fi
    
    # 停止服务
    stop_service
    
    # 删除安装目录
    print_message "$BLUE" "删除安装目录: $SCRIPT_DIR"
    rm -rf "$SCRIPT_DIR" 2>/dev/null
    
    print_message "$GREEN" "✓ VPS监控服务已卸载"
}

# 显示帮助信息
show_help() {
    echo "VPS监控脚本 v2.1.0 - 一键安装版"
    echo
    echo "一键安装:"
    echo "  $0 -i -s <服务器ID> -k <API密钥> -u <Worker地址>"
    echo
    echo "管理命令:"
    echo "  $0 start     启动监控服务"
    echo "  $0 stop      停止监控服务"
    echo "  $0 status    查看服务状态"
    echo "  $0 logs      查看运行日志"
    echo "  $0 uninstall 卸载监控服务"
    echo
    echo "示例:"
    echo "  $0 -i -s server123 -k abc123def456 -u https://worker.example.com"
    echo "  $0 status"
    echo "  $0 logs"
}

# ==================== 主函数 ====================

# 解析命令行参数
parse_arguments() {
    local install_mode=false
    local server_id=""
    local api_key=""
    local worker_url=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--install)
                install_mode=true
                shift
                ;;
            -s|--server-id)
                server_id="$2"
                shift 2
                ;;
            -k|--api-key)
                api_key="$2"
                shift 2
                ;;
            -u|--worker-url)
                worker_url="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                # 如果是管理命令，返回处理
                return 1
                ;;
        esac
    done
    
    # 如果是一键安装模式
    if [[ "$install_mode" == "true" ]]; then
        one_click_install "$server_id" "$api_key" "$worker_url"
        exit $?
    fi
    
    return 1
}

# 处理管理命令
handle_command() {
    case "$1" in
        start)
            start_service
            ;;
        stop)
            stop_service
            ;;
        status)
            check_status
            ;;
        logs)
            view_logs
            ;;
        uninstall)
            uninstall_service
            ;;
        *)
            print_message "$RED" "未知命令: $1"
            show_help
            exit 1
            ;;
    esac
}

# 主函数
main() {
    # 首先尝试解析命令行参数（一键安装）
    if parse_arguments "$@"; then
        return
    fi
    
    # 如果没有参数或管理命令
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    else
        handle_command "$1"
    fi
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
