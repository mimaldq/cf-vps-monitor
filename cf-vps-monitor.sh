#!/bin/bash

# cf-vps-monitor - Cloudflare Worker VPS监控脚本
# 版本: 2.0.2
# 修复FreeBSD内存和负载平均值问题

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
DEFAULT_WORKER_URL=""
DEFAULT_SERVER_ID=""
DEFAULT_API_KEY=""

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
    
    export OS ARCH KERNEL_VERSION VER DISTRO_ID DISTRO_NAME
}

# 检测包管理器
detect_package_manager() {
    PKG_MANAGER=""
    PKG_INSTALL=""
    PKG_UPDATE=""
    
    case "$OS" in
        FreeBSD|OpenBSD|NetBSD)
            if command_exists pkg; then
                PKG_MANAGER="pkg"
                PKG_INSTALL="pkg install -y"
                PKG_UPDATE="pkg update"
            fi
            ;;
        Darwin)
            if command_exists brew; then
                PKG_MANAGER="brew"
                PKG_INSTALL="brew install"
                PKG_UPDATE="brew update"
            fi
            ;;
        Linux|*)
            if command_exists apt-get; then
                PKG_MANAGER="apt-get"
                PKG_INSTALL="apt-get install -y"
                PKG_UPDATE="apt-get update"
            elif command_exists apt; then
                PKG_MANAGER="apt"
                PKG_INSTALL="apt install -y"
                PKG_UPDATE="apt update"
            elif command_exists yum; then
                PKG_MANAGER="yum"
                PKG_INSTALL="yum install -y"
                PKG_UPDATE="yum update -y"
            elif command_exists dnf; then
                PKG_MANAGER="dnf"
                PKG_INSTALL="dnf install -y"
                PKG_UPDATE="dnf update -y"
            elif command_exists pacman; then
                PKG_MANAGER="pacman"
                PKG_INSTALL="pacman -S --noconfirm"
                PKG_UPDATE="pacman -Sy"
            elif command_exists apk; then
                PKG_MANAGER="apk"
                PKG_INSTALL="apk add"
                PKG_UPDATE="apk update"
            fi
            ;;
    esac
    
    if [[ -n "$PKG_MANAGER" ]]; then
        print_message "$GREEN" "检测到包管理器: $PKG_MANAGER"
    fi
    
    export PKG_MANAGER PKG_INSTALL PKG_UPDATE
}

# 检查并安装依赖
install_dependencies() {
    print_message "$BLUE" "检查系统依赖..."
    
    local missing_deps=()
    
    # 检查必需的命令
    if ! command_exists curl; then
        missing_deps+=("curl")
    fi
    
    if [[ ${#missing_deps[@]} -eq 0 ]]; then
        print_message "$GREEN" "所有必需依赖已安装"
        return 0
    fi
    
    print_message "$YELLOW" "缺少必需依赖: ${missing_deps[*]}"
    
    # 尝试安装依赖
    if [[ -n "$PKG_MANAGER" ]]; then
        print_message "$BLUE" "尝试安装依赖..."
        
        if command_exists sudo && sudo -n true 2>/dev/null; then
            # 先更新包列表
            if [[ "$PKG_MANAGER" == "apt-get" ]] || [[ "$PKG_MANAGER" == "apt" ]]; then
                sudo $PKG_UPDATE 2>/dev/null || true
            fi
            
            for dep in "${missing_deps[@]}"; do
                print_message "$BLUE" "安装 $dep..."
                sudo $PKG_INSTALL "$dep" 2>/dev/null || true
            done
        else
            print_message "$YELLOW" "需要sudo权限安装依赖，请手动执行:"
            print_message "$CYAN" "  sudo $PKG_INSTALL ${missing_deps[*]}"
        fi
    else
        print_message "$YELLOW" "未检测到包管理器，请手动安装依赖"
        print_message "$CYAN" "常见安装命令:"
        print_message "$CYAN" "  Ubuntu/Debian: sudo apt-get install curl"
        print_message "$CYAN" "  CentOS/RHEL: sudo yum install curl"
        print_message "$CYAN" "  FreeBSD: sudo pkg install curl"
    fi
    
    # 再次检查
    for dep in "${missing_deps[@]}"; do
        if ! command_exists "$dep"; then
            print_message "$RED" "错误: $dep 安装失败，请手动安装后重试"
            return 1
        fi
    done
    
    print_message "$GREEN" "依赖安装完成"
    return 0
}

# ==================== 配置管理 ====================

# 创建集中式目录结构
create_directories() {
    print_message "$BLUE" "创建集中式目录结构..."
    
    mkdir -p "$SCRIPT_DIR"/{bin,config,logs,tmp,cache,run,system} || error_exit "无法创建目录结构"
    
    # 设置临时目录环境变量
    export TMPDIR="$SCRIPT_DIR/tmp"
    
    print_message "$GREEN" "✓ 集中式目录结构创建完成"
    print_message "$CYAN" "  主目录: $SCRIPT_DIR"
}

# 加载配置
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # 安全地source配置文件
        WORKER_URL=$(grep '^WORKER_URL=' "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "")
        SERVER_ID=$(grep '^SERVER_ID=' "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "")
        API_KEY=$(grep '^API_KEY=' "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "")
        INTERVAL=$(grep '^INTERVAL=' "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "$DEFAULT_INTERVAL")
        
        # 清理空白字符
        WORKER_URL=$(echo "$WORKER_URL" | tr -d ' \n\r')
        SERVER_ID=$(echo "$SERVER_ID" | tr -d ' \n\r')
        API_KEY=$(echo "$API_KEY" | tr -d ' \n\r')
    else
        WORKER_URL=$(echo "$DEFAULT_WORKER_URL" | tr -d ' \n\r')
        SERVER_ID=$(echo "$DEFAULT_SERVER_ID" | tr -d ' \n\r')
        API_KEY=$(echo "$DEFAULT_API_KEY" | tr -d ' \n\r')
        INTERVAL="$DEFAULT_INTERVAL"
    fi
}

# 保存配置
save_config() {
    # 确保保存前清理空白字符
    WORKER_URL=$(echo "$WORKER_URL" | tr -d ' \n\r')
    SERVER_ID=$(echo "$SERVER_ID" | tr -d ' \n\r')
    API_KEY=$(echo "$API_KEY" | tr -d ' \n\r')
    
    cat > "$CONFIG_FILE" << EOF
# VPS监控配置文件
WORKER_URL="$WORKER_URL"
SERVER_ID="$SERVER_ID"
API_KEY="$API_KEY"
INTERVAL="$INTERVAL"
EOF
    print_message "$GREEN" "配置已保存到 $CONFIG_FILE"
}

# ==================== FreeBSD优化的系统信息获取 ====================

# 移除内存值的单位（FreeBSD特定）
remove_memory_unit() {
    local value="$1"
    # 移除所有非数字字符，只保留数字
    echo "$value" | sed 's/[^0-9]//g'
}

# 获取CPU使用率（FreeBSD优化版）
get_cpu_usage_freebsd() {
    local cpu_usage=0
    local load1=0 load5=0 load15=0
    
    # FreeBSD: 使用sysctl获取负载平均值
    if command_exists sysctl; then
        local load_output=$(sysctl -n vm.loadavg 2>/dev/null)
        # 格式: { 1.05 1.20 1.15 } 或 1.05 1.20 1.15
        load_output=$(echo "$load_output" | tr -d '{}')
        local load_array=($load_output)
        
        if [[ ${#load_array[@]} -ge 3 ]]; then
            load1=${load_array[0]}
            load5=${load_array[1]}
            load15=${load_array[2]}
        fi
        
        # 使用top获取CPU使用率
        if command_exists top; then
            local top_output=$(top -b -d 1 2>/dev/null | head -10)
            if [[ "$top_output" =~ ([0-9.]+)%[[:space:]]*id ]]; then
                local idle_percent="${BASH_REMATCH[1]}"
                cpu_usage=$(echo "100 - $idle_percent" | bc 2>/dev/null || echo "0")
            fi
        fi
    fi
    
    # 确保数值在合理范围
    cpu_usage=$((cpu_usage > 100 ? 100 : (cpu_usage < 0 ? 0 : cpu_usage)))
    
    echo "{\"usage_percent\":$cpu_usage,\"load_avg\":[$load1,$load5,$load15]}"
}

# 获取内存使用情况（FreeBSD优化版）
get_memory_usage_freebsd() {
    local total=0 used=0 free=0 usage_percent=0
    
    if command_exists sysctl; then
        # FreeBSD: 使用sysctl获取内存信息
        local pagesize=$(sysctl -n hw.pagesize 2>/dev/null || echo "4096")
        local total_pages=$(sysctl -n vm.stats.vm.v_page_count 2>/dev/null || echo "0")
        local free_pages=$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null || echo "0")
        local inactive_pages=$(sysctl -n vm.stats.vm.v_inactive_count 2>/dev/null || echo "0")
        
        # 转换为KB
        total=$(( (total_pages * pagesize) / 1024 ))
        free=$(( ((free_pages + inactive_pages) * pagesize) / 1024 ))
        used=$((total - free))
    fi
    
    # 计算百分比
    if [[ $total -gt 0 ]]; then
        usage_percent=$((used * 100 / total))
    fi
    
    # 确保数值合理
    [[ $used -lt 0 ]] && used=0
    [[ $free -lt 0 ]] && free=0
    [[ $used -gt $total ]] && used=$total && free=0
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# 获取磁盘使用情况（通用版）
get_disk_usage() {
    local total=0 used=0 free=0 usage_percent=0
    
    if command_exists df; then
        local disk_info=$(df -k / 2>/dev/null | tail -1)
        if [[ -n "$disk_info" ]]; then
            total=$(echo "$disk_info" | awk '{printf "%.0f", $2 / 1024}' 2>/dev/null || echo "0")  # MB
            used=$(echo "$disk_info" | awk '{printf "%.0f", $3 / 1024}' 2>/dev/null || echo "0")   # MB
            free=$(echo "$disk_info" | awk '{printf "%.0f", $4 / 1024}' 2>/dev/null || echo "0")   # MB
            usage_percent=$(echo "$disk_info" | awk '{print $5}' | tr -d '%' 2>/dev/null || echo "0")
        fi
    fi
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# 获取系统运行时间
get_uptime() {
    local uptime_seconds=0
    
    if [[ -f /proc/uptime ]]; then
        uptime_seconds=$(cut -d. -f1 /proc/uptime)
    elif command_exists sysctl && [[ "$OS" == "FreeBSD" ]]; then
        # FreeBSD: 使用sysctl获取启动时间
        local boot_time=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | tr -d ',')
        local current_time=$(date +%s)
        if [[ -n "$boot_time" ]] && [[ "$boot_time" =~ ^[0-9]+$ ]]; then
            uptime_seconds=$((current_time - boot_time))
        fi
    fi
    
    echo "$uptime_seconds"
}

# ==================== 数据上报 ====================

# 简化的数据上报
report_metrics_simple() {
    local timestamp=$(date +%s)
    
    # 根据系统类型使用不同的获取方法
    local cpu_data memory_data
    
    if [[ "$OS" == "FreeBSD" ]]; then
        cpu_data=$(get_cpu_usage_freebsd)
        memory_data=$(get_memory_usage_freebsd)
    else
        # Linux系统使用简单方法
        cpu_data=$(get_cpu_usage_linux)
        memory_data=$(get_memory_usage_linux)
    fi
    
    local disk_data=$(get_disk_usage)
    local uptime=$(get_uptime)
    
    # 构建JSON数据
    local data="{\"timestamp\":$timestamp,\"cpu\":$cpu_data,\"memory\":$memory_data,\"disk\":$disk_data,\"uptime\":$uptime}"
    
    # 清理API KEY和ID
    local clean_api_key=$(echo "$API_KEY" | tr -d ' \n\r')
    local clean_server_id=$(echo "$SERVER_ID" | tr -d ' \n\r')
    
    log "正在上报数据到 $WORKER_URL/api/report/$clean_server_id"
    
    # 发送请求
    local response=$(curl -s -w "%{http_code}" -X POST "$WORKER_URL/api/report/$clean_server_id" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: $clean_api_key" \
        -d "$data" 2>/dev/null || echo "000")
    
    local http_code="${response: -3}"
    local response_body="${response%???}"
    
    if [[ "$http_code" == "200" ]]; then
        log "数据上报成功"
        return 0
    else
        log "数据上报失败 (HTTP $http_code)"
        log "响应内容: $response_body"
        return 1
    fi
}

# Linux系统的简单获取方法
get_cpu_usage_linux() {
    local cpu_usage=0
    local load1=0 load5=0 load15=0
    
    if [[ -f /proc/stat ]]; then
        local cpu_line=$(head -n1 /proc/stat 2>/dev/null)
        if [[ -n "$cpu_line" ]]; then
            local cpu_times=($cpu_line)
            if [[ ${#cpu_times[@]} -ge 5 ]]; then
                local user=${cpu_times[1]}
                local nice=${cpu_times[2]}
                local system=${cpu_times[3]}
                local idle=${cpu_times[4]}
                local total=$((user + nice + system + idle))
                
                if [[ $total -gt 0 ]]; then
                    cpu_usage=$((100 - (idle * 100 / total)))
                fi
            fi
        fi
    fi
    
    if [[ -f /proc/loadavg ]]; then
        local load_data=$(cat /proc/loadavg 2>/dev/null)
        load1=$(echo "$load_data" | awk '{print $1}' 2>/dev/null || echo "0")
        load5=$(echo "$load_data" | awk '{print $2}' 2>/dev/null || echo "0")
        load15=$(echo "$load_data" | awk '{print $3}' 2>/dev/null || echo "0")
    fi
    
    echo "{\"usage_percent\":$cpu_usage,\"load_avg\":[$load1,$load5,$load15]}"
}

# Linux系统的内存获取
get_memory_usage_linux() {
    local total=0 used=0 free=0 usage_percent=0
    
    if command_exists free; then
        local mem_info=$(free -k 2>/dev/null | grep "^Mem:")
        if [[ -n "$mem_info" ]]; then
            total=$(echo "$mem_info" | awk '{print $2}' 2>/dev/null || echo "0")
            used=$(echo "$mem_info" | awk '{print $3}' 2>/dev/null || echo "0")
            free=$(echo "$mem_info" | awk '{print $4}' 2>/dev/null || echo "0")
        fi
    fi
    
    if [[ $total -gt 0 ]]; then
        usage_percent=$((used * 100 / total))
    fi
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# ==================== 服务脚本创建 ====================

# 创建监控服务脚本
create_service_script() {
    cat > "$SERVICE_FILE" << 'EOF'
#!/bin/bash

# cf-vps-monitor服务脚本 - FreeBSD优化版
SCRIPT_DIR="$HOME/.cf-vps-monitor"
CONFIG_FILE="$SCRIPT_DIR/config/config"
LOG_FILE="$SCRIPT_DIR/logs/monitor.log"
PID_FILE="$SCRIPT_DIR/run/monitor.pid"

# 设置服务模式标志
export SERVICE_MODE=true

# 确保日志目录存在
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

# 加载配置
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') 配置文件不存在: $CONFIG_FILE" >> "$LOG_FILE"
    exit 1
fi

# 清理API KEY和ID
WORKER_URL=$(echo "$WORKER_URL" | tr -d ' \n\r')
SERVER_ID=$(echo "$SERVER_ID" | tr -d ' \n\r')
API_KEY=$(echo "$API_KEY" | tr -d ' \n\r')

# 获取CPU使用率（FreeBSD优化）
get_cpu_usage() {
    local cpu_usage=0
    local load1=0 load5=0 load15=0
    
    # FreeBSD: 使用sysctl获取负载平均值
    if command_exists sysctl; then
        local load_output=$(sysctl -n vm.loadavg 2>/dev/null)
        # 清理格式: { 1.05 1.20 1.15 } -> 1.05 1.20 1.15
        load_output=$(echo "$load_output" | tr -d '{}')
        local load_array=($load_output)
        
        if [[ ${#load_array[@]} -ge 3 ]]; then
            load1=${load_array[0]}
            load5=${load_array[1]}
            load15=${load_array[2]}
        fi
        
        # 使用top获取CPU使用率
        if command_exists top; then
            local top_output=$(top -b -d 1 2>/dev/null | head -10)
            if [[ "$top_output" =~ ([0-9.]+)%[[:space:]]*id ]]; then
                local idle_percent="${BASH_REMATCH[1]}"
                cpu_usage=$(echo "100 - $idle_percent" | bc 2>/dev/null || echo "0")
            fi
        fi
    else
        # Linux系统
        if [[ -f /proc/stat ]]; then
            local cpu_line=$(head -n1 /proc/stat 2>/dev/null)
            if [[ -n "$cpu_line" ]]; then
                local cpu_times=($cpu_line)
                if [[ ${#cpu_times[@]} -ge 5 ]]; then
                    local user=${cpu_times[1]}
                    local nice=${cpu_times[2]}
                    local system=${cpu_times[3]}
                    local idle=${cpu_times[4]}
                    local total=$((user + nice + system + idle))
                    
                    if [[ $total -gt 0 ]]; then
                        cpu_usage=$((100 - (idle * 100 / total)))
                    fi
                fi
            fi
        fi
        
        if [[ -f /proc/loadavg ]]; then
            local load_data=$(cat /proc/loadavg 2>/dev/null)
            load1=$(echo "$load_data" | awk '{print $1}' 2>/dev/null || echo "0")
            load5=$(echo "$load_data" | awk '{print $2}' 2>/dev/null || echo "0")
            load15=$(echo "$load_data" | awk '{print $3}' 2>/dev/null || echo "0")
        fi
    fi
    
    # 确保数值在合理范围
    cpu_usage=$((cpu_usage > 100 ? 100 : (cpu_usage < 0 ? 0 : cpu_usage)))
    
    echo "{\"usage_percent\":$cpu_usage,\"load_avg\":[$load1,$load5,$load15]}"
}

# 获取内存使用情况
get_memory_usage() {
    local total=0 used=0 free=0 usage_percent=0
    
    if [[ $(uname -s) == "FreeBSD" ]]; then
        # FreeBSD: 使用sysctl
        if command_exists sysctl; then
            local pagesize=$(sysctl -n hw.pagesize 2>/dev/null || echo "4096")
            local total_pages=$(sysctl -n vm.stats.vm.v_page_count 2>/dev/null || echo "0")
            local free_pages=$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null || echo "0")
            local inactive_pages=$(sysctl -n vm.stats.vm.v_inactive_count 2>/dev/null || echo "0")
            
            # 转换为KB
            total=$(( (total_pages * pagesize) / 1024 ))
            free=$(( ((free_pages + inactive_pages) * pagesize) / 1024 ))
            used=$((total - free))
        fi
    else
        # Linux: 使用free命令
        if command_exists free; then
            local mem_info=$(free -k 2>/dev/null | grep "^Mem:")
            if [[ -n "$mem_info" ]]; then
                total=$(echo "$mem_info" | awk '{print $2}' 2>/dev/null || echo "0")
                used=$(echo "$mem_info" | awk '{print $3}' 2>/dev/null || echo "0")
                free=$(echo "$mem_info" | awk '{print $4}' 2>/dev/null || echo "0")
            fi
        fi
    fi
    
    # 计算百分比
    if [[ $total -gt 0 ]]; then
        usage_percent=$((used * 100 / total))
    fi
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# 获取磁盘使用情况
get_disk_usage() {
    local total=0 used=0 free=0 usage_percent=0
    
    if command_exists df; then
        local disk_info=$(df -k / 2>/dev/null | tail -1)
        if [[ -n "$disk_info" ]]; then
            total=$(echo "$disk_info" | awk '{printf "%.0f", $2 / 1024}' 2>/dev/null || echo "0")
            used=$(echo "$disk_info" | awk '{printf "%.0f", $3 / 1024}' 2>/dev/null || echo "0")
            free=$(echo "$disk_info" | awk '{printf "%.0f", $4 / 1024}' 2>/dev/null || echo "0")
            usage_percent=$(echo "$disk_info" | awk '{print $5}' | tr -d '%' 2>/dev/null || echo "0")
        fi
    fi
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# 获取系统运行时间
get_uptime() {
    local uptime_seconds=0
    
    if [[ -f /proc/uptime ]]; then
        uptime_seconds=$(cut -d. -f1 /proc/uptime)
    elif command_exists sysctl && [[ $(uname -s) == "FreeBSD" ]]; then
        local boot_time=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | tr -d ',')
        local current_time=$(date +%s)
        if [[ -n "$boot_time" ]] && [[ "$boot_time" =~ ^[0-9]+$ ]]; then
            uptime_seconds=$((current_time - boot_time))
        fi
    fi
    
    echo "$uptime_seconds"
}

# 上报监控数据
report_metrics() {
    local timestamp=$(date +%s)
    
    # 获取各项数据
    local cpu_data=$(get_cpu_usage)
    local memory_data=$(get_memory_usage)
    local disk_data=$(get_disk_usage)
    local uptime=$(get_uptime)
    
    # 构建JSON数据
    local data="{\"timestamp\":$timestamp,\"cpu\":$cpu_data,\"memory\":$memory_data,\"disk\":$disk_data,\"uptime\":$uptime}"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') 正在上报数据到 $WORKER_URL/api/report/$SERVER_ID" >> "$LOG_FILE"
    
    # 发送请求
    local response=$(curl -s -w "%{http_code}" -X POST "$WORKER_URL/api/report/$SERVER_ID" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: $API_KEY" \
        -d "$data" 2>/dev/null || echo "000")
    
    local http_code="${response: -3}"
    
    if [[ "$http_code" == "200" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 数据上报成功" >> "$LOG_FILE"
        return 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 数据上报失败 (HTTP $http_code)" >> "$LOG_FILE"
        return 1
    fi
}

# 主循环
main() {
    echo "$(date '+%Y-%m-d %H:%M:%S') VPS监控服务启动 (PID: $$)" >> "$LOG_FILE"
    echo $$ > "$PID_FILE"
    
    # 信号处理
    trap 'echo "$(date +"%Y-%m-%d %H:%M:%S") 收到终止信号，正在停止..." >> "$LOG_FILE"; rm -f "$PID_FILE"; exit 0' TERM INT
    
    # 主循环
    while true; do
        if ! report_metrics; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 上报失败，将在下个周期重试" >> "$LOG_FILE"
        fi
        
        sleep "$INTERVAL"
    done
}

# 启动主函数
main
EOF
    
    chmod +x "$SERVICE_FILE"
    print_message "$GREEN" "监控服务脚本创建完成: $SERVICE_FILE"
}

# ==================== 服务管理 ====================

# 验证PID有效性
validate_pid() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" != "$$" ]] && kill -0 "$pid" 2>/dev/null
}

# 查找监控进程
find_monitor_processes() {
    local pids=""
    
    # 检查PID文件
    if [[ -f "$PID_FILE" ]]; then
        local file_pid=$(cat "$PID_FILE" 2>/dev/null)
        if validate_pid "$file_pid"; then
            pids="$file_pid"
        fi
    fi
    
    # 查找相关进程
    if [[ -z "$pids" ]] && [[ -f "${SERVICE_FILE:-}" ]]; then
        if [[ "$OS" == "FreeBSD" ]]; then
            pids=$(pgrep -f "vps-monitor-service" 2>/dev/null || ps aux | grep "$SERVICE_FILE" | grep -v grep | awk '{print $2}')
        else
            pids=$(pgrep -f "vps-monitor-service" 2>/dev/null || ps aux | grep "$SERVICE_FILE" | grep -v grep | awk '{print $2}')
        fi
    fi
    
    echo "$pids" | xargs 2>/dev/null || echo ""
}

# 检查监控服务是否运行
is_monitor_running() {
    [[ -n $(find_monitor_processes) ]]
}

# 启动服务
start_service() {
    print_message "$BLUE" "启动监控服务..."
    
    # 1. 检查是否已有进程在运行
    if is_monitor_running; then
        local pids=$(find_monitor_processes)
        local first_pid=$(echo "$pids" | awk '{print $1}')
        print_message "$YELLOW" "监控服务已在运行 (PID: $first_pid)"
        return 0
    fi
    
    # 2. 清理旧的PID文件
    rm -f "$PID_FILE" 2>/dev/null || true
    
    # 3. 检查服务脚本
    if [[ ! -f "$SERVICE_FILE" ]]; then
        print_message "$RED" "✗ 服务脚本不存在: $SERVICE_FILE"
        print_message "$CYAN" "请先运行安装命令"
        return 1
    fi
    
    chmod +x "$SERVICE_FILE" 2>/dev/null || true
    
    # 4. 启动服务
    print_message "$BLUE" "使用传统方式启动服务..."
    
    if command_exists nohup; then
        nohup "$SERVICE_FILE" >> "$LOG_FILE" 2>&1 &
    else
        "$SERVICE_FILE" >> "$LOG_FILE" 2>&1 &
    fi
    
    local pid=$!
    echo "$pid" > "$PID_FILE"
    
    # 5. 验证启动成功
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        print_message "$GREEN" "✓ 监控服务已启动 (PID: $pid)"
        print_message "$CYAN" "日志文件: $LOG_FILE"
        
        # 配置自启动
        configure_autostart
        return 0
    else
        print_message "$RED" "✗ 监控服务启动失败"
        if [[ -f "$LOG_FILE" ]]; then
            print_message "$YELLOW" "查看日志: tail -f $LOG_FILE"
        fi
        rm -f "$PID_FILE"
        return 1
    fi
}

# 停止服务
stop_service() {
    print_message "$BLUE" "停止监控服务..."
    
    local stopped=false
    
    # 1. 查找并停止所有相关进程
    local pids=$(find_monitor_processes)
    if [[ -n "$pids" ]]; then
        for pid in $pids; do
            if [[ "$pid" =~ ^[0-9]+$ ]]; then
                print_message "$BLUE" "停止进程 (PID: $pid)..."
                
                # 尝试温和停止
                kill "$pid" 2>/dev/null
                sleep 2
                
                # 如果还在运行，强制停止
                if kill -0 "$pid" 2>/dev/null; then
                    kill -9 "$pid" 2>/dev/null
                    sleep 1
                fi
                
                # 确认停止
                if ! kill -0 "$pid" 2>/dev/null; then
                    stopped=true
                    print_message "$GREEN" "  ✓ 进程已停止"
                else
                    print_message "$RED" "  ✗ 进程无法停止"
                fi
            fi
        done
    fi
    
    # 2. 清理PID文件
    rm -f "$PID_FILE" 2>/dev/null || true
    
    # 3. 结果报告
    if [[ "$stopped" == "true" ]]; then
        print_message "$GREEN" "✓ 监控服务已停止"
    else
        print_message "$YELLOW" "没有发现运行中的监控服务"
    fi
}

# ==================== 自启动配置 ====================

# 配置自启动
configure_autostart() {
    print_message "$BLUE" "配置自启动设置..."
    
    # 1. crontab自启动
    if command_exists crontab; then
        local current_crontab=$(crontab -l 2>/dev/null || echo "")
        if ! echo "$current_crontab" | grep -q "cf-vps-monitor"; then
            local crontab_entry="@reboot sleep 30 && $SERVICE_FILE"
            (echo "$current_crontab"; echo "$crontab_entry") | crontab - 2>/dev/null
            print_message "$GREEN" "  ✓ crontab自启动已配置"
        fi
    fi
    
    print_message "$GREEN" "✓ 自启动设置配置完成"
}

# 移除自启动
remove_autostart() {
    print_message "$BLUE" "移除自启动设置..."
    
    # 移除crontab条目
    if command_exists crontab; then
        local current_crontab=$(crontab -l 2>/dev/null || echo "")
        if echo "$current_crontab" | grep -q "cf-vps-monitor"; then
            echo "$current_crontab" | grep -v "cf-vps-monitor" | crontab - 2>/dev/null
            print_message "$GREEN" "  ✓ crontab自启动已移除"
        fi
    fi
    
    print_message "$GREEN" "✓ 自启动设置已移除"
}

# ==================== 测试连接 ====================

# 测试连接
test_connection() {
    print_message "$BLUE" "测试连接到监控服务器..."
    
    load_config
    
    if [[ -z "$WORKER_URL" || -z "$SERVER_ID" || -z "$API_KEY" ]]; then
        print_message "$RED" "配置不完整，请先配置监控参数"
        return 1
    fi
    
    print_message "$BLUE" "正在测试数据上报..."
    if report_metrics_simple; then
        print_message "$GREEN" "✓ 数据上报测试成功"
        return 0
    else
        print_message "$RED" "✗ 数据上报测试失败，请检查配置和网络"
        return 1
    fi
}

# ==================== 一键安装 ====================

# 一键安装函数
one_click_install() {
    local server_id="$1"
    local api_key="$2"
    local worker_url="$3"
    
    print_message "$BLUE" "开始一键安装VPS监控服务..."
    echo
    
    # 验证必需参数
    if [[ -z "$server_id" || -z "$api_key" || -z "$worker_url" ]]; then
        print_message "$RED" "错误: 缺少必需参数"
        echo "必需参数: -s <服务器ID> -k <API密钥> -u <Worker地址>"
        echo "使用 '$0 --help' 查看详细帮助"
        return 1
    fi
    
    # 设置默认间隔
    local interval="10"
    
    print_message "$CYAN" "安装参数:"
    echo "  服务器ID: $server_id"
    echo "  API密钥: ${api_key:0:8}..."
    echo "  Worker地址: $worker_url"
    echo "  上报间隔: ${interval}秒"
    echo
    
    # 检测系统
    detect_system
    detect_package_manager
    
    # 安装依赖
    install_dependencies
    
    # 创建目录结构
    create_directories
    
    # 设置配置参数
    WORKER_URL="$worker_url"
    SERVER_ID="$server_id"
    API_KEY="$api_key"
    INTERVAL="$interval"
    
    # 保存配置
    save_config
    print_message "$GREEN" "配置保存成功"
    
    # 测试连接
    print_message "$BLUE" "测试连接..."
    if test_connection; then
        print_message "$GREEN" "✓ 连接测试成功"
    else
        print_message "$YELLOW" "⚠ 连接测试失败，但将继续安装"
        print_message "$YELLOW" "请检查网络连接和配置参数"
    fi
    
    # 创建服务脚本
    create_service_script
    
    # 配置自启动
    configure_autostart
    
    # 启动服务
    echo
    if start_service; then
        print_message "$GREEN" "✓ VPS监控服务一键安装成功"
        echo
        print_message "$CYAN" "安装信息:"
        echo "  安装目录: $SCRIPT_DIR"
        echo "  配置文件: $CONFIG_FILE"
        echo "  日志文件: $LOG_FILE"
        echo "  服务脚本: $SERVICE_FILE"
        echo
        print_message "$GREEN" "✓ 已配置自启动，VPS重启后将自动运行"
        echo
        print_message "$YELLOW" "提示: 使用 '$0 status' 检查服务状态"
        print_message "$YELLOW" "提示: 使用 '$0 logs' 查看运行日志"
        return 0
    else
        print_message "$RED" "✗ 服务启动失败"
        return 1
    fi
}

# ==================== 服务状态检查 ====================

# 检查服务状态
check_service_status() {
    print_message "$BLUE" "检查监控服务状态..."
    echo
    
    # 1. 检查进程
    if is_monitor_running; then
        local pids=$(find_monitor_processes)
        print_message "$GREEN" "✓ 监控服务正在运行"
        print_message "$CYAN" "  进程ID: $pids"
    else
        print_message "$RED" "✗ 监控服务未运行"
    fi
    
    # 2. 显示配置信息
    echo
    print_message "$BLUE" "配置信息:"
    if [[ -f "$CONFIG_FILE" ]]; then
        load_config
        print_message "$CYAN" "  Worker URL: $WORKER_URL"
        print_message "$CYAN" "  Server ID: $SERVER_ID"
        print_message "$CYAN" "  API Key: ${API_KEY:0:8}..."
        print_message "$CYAN" "  上报间隔: ${INTERVAL}秒"
    else
        print_message "$YELLOW" "  ✗ 配置文件不存在"
    fi
    
    # 3. 显示日志文件信息
    echo
    print_message "$BLUE" "日志文件:"
    if [[ -f "$LOG_FILE" ]]; then
        local log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
        local log_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
        print_message "$CYAN" "  文件: $LOG_FILE"
        print_message "$CYAN" "  大小: $log_size"
        print_message "$CYAN" "  行数: $log_lines"
        print_message "$CYAN" "  最后5行日志:"
        echo "----------------------------------------"
        tail -n 5 "$LOG_FILE" 2>/dev/null || echo "无法读取日志文件"
        echo "----------------------------------------"
    else
        print_message "$YELLOW" "  ✗ 日志文件不存在"
    fi
}

# 查看日志
view_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        print_message "$YELLOW" "日志文件不存在: $LOG_FILE"
        return
    fi
    
    print_message "$BLUE" "显示最近50行日志:"
    echo "----------------------------------------"
    tail -n 50 "$LOG_FILE"
    echo "----------------------------------------"
    print_message "$CYAN" "日志文件位置: $LOG_FILE"
}

# ==================== 显示帮助信息 ====================

# 显示帮助信息
show_help() {
    echo "VPS监控脚本 v2.0.2"
    echo
    echo "用法: $0 [选项] [参数]"
    echo
    echo "基本选项:"
    echo "  install     安装监控服务"
    echo "  uninstall   彻底卸载监控服务"
    echo "  start       启动监控服务"
    echo "  stop        停止监控服务"
    echo "  restart     重启监控服务"
    echo "  status      查看服务状态"
    echo "  logs        查看运行日志"
    echo "  config      配置监控参数"
    echo "  test        测试连接"
    echo "  help        显示此帮助信息"
    echo
    echo "一键安装参数:"
    echo "  -i, --install           一键安装模式"
    echo "  -s, --server-id ID      服务器ID"
    echo "  -k, --api-key KEY       API密钥"
    echo "  -u, --worker-url URL    Worker地址"
    echo
    echo "示例:"
    echo "  $0 install              # 交互式安装"
    echo "  $0 status               # 查看服务状态"
    echo "  $0 logs                 # 查看日志"
    echo
    echo "一键安装示例:"
    echo "  $0 -i -s server123 -k abc123 -u https://worker.example.com"
    echo
    echo "注意: 上报间隔会自动从服务器获取，无需手动设置"
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
                # 如果是基本命令，返回处理
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

# 卸载监控服务
uninstall_monitor() {
    print_message "$YELLOW" "警告: 这将删除VPS监控服务及其数据"
    echo -n "确认卸载? (y/N): "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_message "$BLUE" "取消卸载"
        return 0
    fi
    
    print_message "$BLUE" "开始卸载VPS监控服务..."
    
    # 1. 停止服务
    stop_service
    
    # 2. 移除自启动
    remove_autostart
    
    # 3. 删除安装目录
    print_message "$BLUE" "删除安装目录: $SCRIPT_DIR"
    
    # 确保不在目标目录内执行删除
    cd / 2>/dev/null || cd "$HOME" 2>/dev/null || true
    
    # 尝试删除
    if rm -rf "$SCRIPT_DIR" 2>/dev/null; then
        print_message "$GREEN" "✓ VPS监控服务已彻底卸载"
    else
        print_message "$YELLOW" "⚠ 无法完全删除安装目录，可能需要手动删除"
        print_message "$CYAN" "手动删除: rm -rf '$SCRIPT_DIR'"
    fi
}

# 主函数
main() {
    # 首先尝试解析命令行参数
    if parse_arguments "$@"; then
        return
    fi
    
    # 处理命令行参数
    case "${1:-}" in
        install)
            # 交互式安装
            print_message "$BLUE" "开始交互式安装..."
            detect_system
            detect_package_manager
            install_dependencies
            create_directories
            create_service_script
            configure_autostart
            start_service
            ;;
        uninstall)
            uninstall_monitor
            ;;
        start)
            start_service
            ;;
        stop)
            stop_service
            ;;
        restart)
            stop_service
            sleep 1
            start_service
            ;;
        status)
            check_service_status
            ;;
        logs)
            view_logs
            ;;
        test)
            test_connection
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            # 如果没有参数，显示帮助
            show_help
            exit 1
            ;;
    esac
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
