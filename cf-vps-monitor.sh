#!/bin/bash

# cf-vps-monitor - Cloudflare Worker VPS监控脚本
# 版本: 2.0.0
# 完整修复版 - 包含所有必需函数

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
INSTALL_MANIFEST="$SCRIPT_DIR/system/install.manifest"

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

# ==================== 系统兼容性层 ====================

# 跨平台sed命令
safe_sed() {
    local pattern="$1"
    local file="$2"
    if [[ "$OS" == "FreeBSD" ]] || [[ "$OS" == "Darwin" ]]; then
        sed -i '' "$pattern" "$file" 2>/dev/null || true
    else
        sed -i "$pattern" "$file" 2>/dev/null || true
    fi
}

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
    else
        print_message "$YELLOW" "警告: 未检测到支持的包管理器"
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
    
    if ! command_exists bc; then
        missing_deps+=("bc")
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
        print_message "$CYAN" "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
        print_message "$CYAN" "  CentOS/RHEL: sudo yum install ${missing_deps[*]}"
        print_message "$CYAN" "  Fedora: sudo dnf install ${missing_deps[*]}"
        print_message "$CYAN" "  Alpine: sudo apk add ${missing_deps[*]}"
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

# ==================== 系统信息获取 ====================

# 验证和清理整数
sanitize_integer() {
    local value="$1"
    local default_value="${2:-0}"
    
    value=$(echo "$value" | sed 's/[^0-9]//g')
    [[ "$value" =~ ^[0-9]+$ ]] && echo "$value" || echo "$default_value"
}

# 验证和清理数值
sanitize_number() {
    local value="$1"
    local default_value="${2:-0}"
    
    value=$(echo "$value" | sed 's/[^0-9.]//g')
    
    if [[ "$value" =~ ^[0-9]*\.?[0-9]+$ ]] || [[ "$value" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        [[ "$value" =~ ^\. ]] && value="0$value"
        [[ "$value" =~ \.$ ]] && value="${value}0"
        echo "$value"
    else
        echo "$default_value"
    fi
}

# 清理JSON字符串
clean_json_string() {
    local input="$1"
    # 移除可能的控制字符和非打印字符
    echo "$input" | tr -d '\000-\037' | tr -d '\177-\377'
}

# 获取CPU使用率
get_cpu_usage() {
    local cpu_usage
    local cpu_load
    
    if [[ "$OS" == "FreeBSD" ]]; then
        # FreeBSD系统
        if command_exists sysctl; then
            local cpu_idle=$(sysctl -n kern.cp_time 2>/dev/null | awk '{print $5}' 2>/dev/null || echo "0")
            local cpu_total=$(sysctl -n kern.cp_time 2>/dev/null | awk '{sum=0; for(i=1;i<=NF;i++) sum+=$i; print sum}' 2>/dev/null || echo "0")
            
            cpu_idle=$(sanitize_integer "$cpu_idle" "0")
            cpu_total=$(sanitize_integer "$cpu_total" "0")
            
            if [[ $cpu_total -gt 0 && $cpu_idle -le $cpu_total ]]; then
                cpu_usage=$(echo "scale=1; 100 - ($cpu_idle * 100 / $cpu_total)" | bc 2>/dev/null || echo "0")
                cpu_usage=$(sanitize_number "$cpu_usage" "0")
            else
                cpu_usage="0"
            fi
            
            # FreeBSD负载平均值
            local load1="0" load5="0" load15="0"
            if command_exists sysctl; then
                load1=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' 2>/dev/null || echo "0")
                load5=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $3}' 2>/dev/null || echo "0")
                load15=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $4}' 2>/dev/null || echo "0")
                
                load1=$(sanitize_number "$load1" "0")
                load5=$(sanitize_number "$load5" "0")
                load15=$(sanitize_number "$load15" "0")
            fi
            
            cpu_load="$load1,$load5,$load15"
        else
            cpu_usage="0"
            cpu_load="0,0,0"
        fi
    else
        # Linux系统
        cpu_usage="0"
        
        # 方法1: 使用/proc/stat
        if [[ -f /proc/stat ]]; then
            local cpu_line=$(head -n1 /proc/stat 2>/dev/null)
            if [[ -n "$cpu_line" ]]; then
                local cpu_times=($cpu_line)
                if [[ ${#cpu_times[@]} -ge 8 ]]; then
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
        fi
        
        cpu_usage=$(sanitize_number "$cpu_usage" "0")
        
        # 获取负载平均值
        local load1="0" load5="0" load15="0"
        if [[ -f /proc/loadavg ]]; then
            local load_data=$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}' || echo "0 0 0")
            read -r load1 load5 load15 <<< "$load_data"
        fi
        
        load1=$(sanitize_number "$load1" "0")
        load5=$(sanitize_number "$load5" "0")
        load15=$(sanitize_number "$load15" "0")
        
        cpu_load="$load1,$load5,$load15"
    fi
    
    echo "{\"usage_percent\":$cpu_usage,\"load_avg\":[$cpu_load]}"
}

# 获取内存使用情况
get_memory_usage() {
    local total used free usage_percent
    
    if [[ "$OS" == "FreeBSD" ]]; then
        if command_exists sysctl; then
            # FreeBSD内存信息
            local page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo "4096")
            local total_pages=$(sysctl -n vm.stats.vm.v_page_count 2>/dev/null || echo "0")
            local free_pages=$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null || echo "0")
            local inactive_pages=$(sysctl -n vm.stats.vm.v_inactive_count 2>/dev/null || echo "0")
            local cache_pages=$(sysctl -n vm.stats.vm.v_cache_count 2>/dev/null || echo "0")
            
            page_size=$(sanitize_integer "$page_size" "4096")
            total_pages=$(sanitize_integer "$total_pages" "0")
            free_pages=$(sanitize_integer "$free_pages" "0")
            inactive_pages=$(sanitize_integer "$inactive_pages" "0")
            cache_pages=$(sanitize_integer "$cache_pages" "0")
            
            if [[ $page_size -gt 0 && $total_pages -gt 0 ]]; then
                total=$(( (total_pages * page_size) / 1024 ))
                free=$(( ((free_pages + inactive_pages + cache_pages) * page_size) / 1024 ))
                used=$((total - free))
                
                if [[ $used -lt 0 ]]; then used=0; fi
                if [[ $free -lt 0 ]]; then free=0; fi
            else
                total=0
                used=0
                free=0
            fi
        else
            total=0
            used=0
            free=0
        fi
    else
        # Linux系统
        total=0
        used=0
        free=0
        
        # 方法1: 使用free命令
        if command_exists free; then
            local mem_info=$(free -k 2>/dev/null | grep "^Mem:")
            if [[ -n "$mem_info" ]]; then
                total=$(echo "$mem_info" | awk '{print $2}')
                
                # 尝试获取available列
                local available=$(echo "$mem_info" | awk '{print $7}' 2>/dev/null || echo "")
                if [[ "$available" =~ ^[0-9]+$ ]]; then
                    free=$available
                    used=$((total - free))
                else
                    local mem_free=$(echo "$mem_info" | awk '{print $4}' 2>/dev/null || echo "0")
                    local buff_cache=$(echo "$mem_info" | awk '{print $6}' 2>/dev/null || echo "0")
                    
                    if [[ "$mem_free" =~ ^[0-9]+$ ]] && [[ "$buff_cache" =~ ^[0-9]+$ ]]; then
                        free=$((mem_free + buff_cache))
                        used=$((total - free))
                    else
                        local raw_used=$(echo "$mem_info" | awk '{print $3}' 2>/dev/null || echo "0")
                        if [[ "$raw_used" =~ ^[0-9]+$ ]]; then
                            used=$raw_used
                            free=$((total - used))
                        fi
                    fi
                fi
            fi
        fi
        
        # 方法2: 直接读取/proc/meminfo
        if [[ "$total" == "0" ]] && [[ -f /proc/meminfo ]]; then
            total=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
            local mem_free=$(grep "^MemFree:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
            local buffers=$(grep "^Buffers:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
            local cached=$(grep "^Cached:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
            local sreclaimable=$(grep "^SReclaimable:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
            
            free=$((mem_free + buffers + cached + sreclaimable))
            used=$((total - free))
        fi
        
        # 容器环境特殊处理
        local cgroup_limit="0"
        local cgroup_usage="0"
        local cgroup_found=false
        
        # 尝试检测 Cgroup V2
        if [[ -f /sys/fs/cgroup/memory.max ]]; then
            local max_raw=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
            if [[ "$max_raw" != "max" && "$max_raw" =~ ^[0-9]+$ ]]; then
                cgroup_limit="$max_raw"
                if [[ -f /sys/fs/cgroup/memory.current ]]; then
                    cgroup_usage=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo "0")
                    cgroup_found=true
                fi
            fi
        fi
        
        # 尝试检测 Cgroup V1
        if [[ "$cgroup_found" == "false" && -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
            local limit_raw=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo "0")
            if [[ "$limit_raw" =~ ^[0-9]+$ && "$limit_raw" -lt 9223372036854771712 ]]; then
                cgroup_limit="$limit_raw"
                cgroup_usage=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo "0")
                cgroup_found=true
            fi
        fi
        
        # 如果找到了有效的cgroup限制
        if [[ "$cgroup_found" == "true" ]]; then
            local cgroup_total_kb=$((cgroup_limit / 1024))
            
            if [[ "$total" == "0" || "$cgroup_total_kb" -lt "$total" ]]; then
                total=$cgroup_total_kb
                used=$((cgroup_usage / 1024))
                free=$((total - used))
            fi
        fi
        
        # 确保所有值都是有效数字
        total=$(sanitize_integer "$total" "0")
        used=$(sanitize_integer "$used" "0")
        free=$(sanitize_integer "$free" "0")
        
        # 数据一致性验证和修正
        if [[ $total -gt 0 ]]; then
            total=$(sanitize_integer "$total" "0")
            used=$(sanitize_integer "$used" "0")
            free=$(sanitize_integer "$free" "0")
            
            local sum=$((used + free))
            local diff=$((sum - total))
            
            local tolerance=$((total / 100))
            if [[ $tolerance -lt 1024 ]]; then
                tolerance=1024
            fi
            
            if [[ ${diff#-} -gt $tolerance ]]; then
                if [[ $free -gt $total ]]; then
                    free=$total
                    used=0
                elif [[ $used -gt $total ]]; then
                    used=$total
                    free=0
                else
                    used=$((total - free))
                fi
                
                if [[ $used -lt 0 ]]; then
                    used=0
                    free=$total
                fi
                if [[ $free -lt 0 ]]; then
                    free=0
                    used=$total
                fi
            fi
        else
            total=0
            used=0
            free=0
        fi
    fi
    
    # 计算使用百分比
    if [[ $total -gt 0 ]]; then
        usage_percent=$(echo "scale=1; $used * 100 / $total" | bc 2>/dev/null || echo "0")
        if ! [[ "$usage_percent" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            usage_percent="0"
        fi
    else
        usage_percent="0"
    fi
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# 获取磁盘使用情况
get_disk_usage() {
    local total used free usage_percent
    
    # 多种方法获取磁盘信息
    if command_exists df; then
        local disk_info=$(df -k / 2>/dev/null | tail -1)
        if [[ -n "$disk_info" ]]; then
            total=$(echo "$disk_info" | awk '{printf "%.2f", $2 / 1024 / 1024}' 2>/dev/null || echo "0")
            used=$(echo "$disk_info" | awk '{printf "%.2f", $3 / 1024 / 1024}' 2>/dev/null || echo "0")
            free=$(echo "$disk_info" | awk '{printf "%.2f", $4 / 1024 / 1024}' 2>/dev/null || echo "0")
            usage_percent=$(echo "$disk_info" | awk '{print $5}' | tr -d '%' 2>/dev/null || echo "0")
            
            total=$(sanitize_number "$total" "0")
            used=$(sanitize_number "$used" "0")
            free=$(sanitize_number "$free" "0")
            usage_percent=$(sanitize_integer "$usage_percent" "0")
        else
            total="0"
            used="0"
            free="0"
            usage_percent="0"
        fi
    else
        total="0"
        used="0"
        free="0"
        usage_percent="0"
    fi
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# 获取网络使用情况
get_network_usage() {
    local upload_speed=0
    local download_speed=0
    local total_upload=0
    local total_download=0
    local interface=""
    
    if [[ "$OS" == "FreeBSD" ]]; then
        # FreeBSD系统
        if command_exists route; then
            interface=$(route -n get default 2>/dev/null | grep 'interface:' | awk '{print $2}')
        fi
        
        if [[ -z "$interface" ]] && command_exists netstat; then
            interface=$(netstat -i -b | awk 'NR>1 && $1 !~ /^lo/ && ($8 > 0 || $11 > 0) {print $1; exit}')
            if [[ -z "$interface" ]]; then
                interface=$(netstat -i -b | awk 'NR>1 && $1 !~ /^lo/ {print $1; exit}')
            fi
        fi
        
        if [[ -z "$interface" ]] && command_exists ifconfig; then
            interface=$(ifconfig -l | tr ' ' '\n' | grep -v '^lo' | head -1)
        fi
        
        if [[ -n "$interface" ]] && command_exists netstat; then
            local net_stats=$(netstat -i -b 2>/dev/null | grep "^$interface" | grep "<Link#" | head -1 2>/dev/null || echo "")
            if [[ -n "$net_stats" ]]; then
                local raw_download=$(echo "$net_stats" | awk '{print $8}' 2>/dev/null || echo "0")
                local raw_upload=$(echo "$net_stats" | awk '{print $11}' 2>/dev/null || echo "0")
                
                total_download=$(sanitize_integer "$raw_download" "0")
                total_upload=$(sanitize_integer "$raw_upload" "0")
            fi
            
            # 计算速度
            local speed_file="${TMPDIR:-/tmp}/vps_monitor_net_${interface}_$(whoami)"
            mkdir -p "$(dirname "$speed_file")" 2>/dev/null
            local current_time=$(date +%s)
            
            if [[ -f "$speed_file" ]]; then
                local last_data=$(cat "$speed_file")
                local last_time=$(echo "$last_data" | cut -d' ' -f1)
                local last_rx=$(echo "$last_data" | cut -d' ' -f2)
                local last_tx=$(echo "$last_data" | cut -d' ' -f3)
                
                local time_diff=$((current_time - last_time))
                if [[ $time_diff -gt 0 ]]; then
                    download_speed=$(( (total_download - last_rx) / time_diff ))
                    upload_speed=$(( (total_upload - last_tx) / time_diff ))
                    
                    [[ $download_speed -lt 0 ]] && download_speed=0
                    [[ $upload_speed -lt 0 ]] && upload_speed=0
                fi
            fi
            
            echo "$current_time $total_download $total_upload" > "$speed_file"
        fi
    else
        # Linux系统
        # 获取默认网络接口
        if command_exists ip; then
            interface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
        fi
        
        if [[ -z "$interface" ]] && command_exists route; then
            interface=$(route -n 2>/dev/null | awk '/^0.0.0.0/ {print $8}' | head -1)
        fi
        
        if [[ -z "$interface" && -f "/proc/net/route" ]]; then
            interface=$(awk '/^[^I]/ && $2 == "00000000" {print $1; exit}' /proc/net/route 2>/dev/null)
        fi
        
        if [[ -z "$interface" && -f "/proc/net/dev" ]]; then
            interface=$(awk '/^ *[^:]*:/ {
                gsub(/:/, "", $1)
                if ($1 != "lo" && $1 !~ /^(docker|br-|veth|tun|tap|virbr|vmnet)/) {
                    print $1
                    exit
                }
            }' /proc/net/dev)
        fi
        
        if [[ -n "$interface" && -f "/proc/net/dev" ]]; then
            local net_line=$(grep "^ *$interface:" /proc/net/dev 2>/dev/null)
            if [[ -n "$net_line" ]]; then
                local stats=($net_line)
                total_download=${stats[1]}
                total_upload=${stats[9]}
                
                if ! [[ "$total_download" =~ ^[0-9]+$ ]]; then
                    total_download=0
                fi
                if ! [[ "$total_upload" =~ ^[0-9]+$ ]]; then
                    total_upload=0
                fi
            fi
            
            # 计算速度
            local speed_file="${TMPDIR:-/tmp}/vps_monitor_net_${interface}_$(whoami)"
            mkdir -p "$(dirname "$speed_file")" 2>/dev/null
            local current_time=$(date +%s)
            
            if [[ -f "$speed_file" ]]; then
                local last_data=$(cat "$speed_file")
                local last_time=$(echo "$last_data" | cut -d' ' -f1)
                local last_rx=$(echo "$last_data" | cut -d' ' -f2)
                local last_tx=$(echo "$last_data" | cut -d' ' -f3)
                
                local time_diff=$((current_time - last_time))
                if [[ $time_diff -gt 0 ]]; then
                    download_speed=$(( (total_download - last_rx) / time_diff ))
                    upload_speed=$(( (total_upload - last_tx) / time_diff ))
                fi
            fi
            
            echo "$current_time $total_download $total_upload" > "$speed_file"
        fi
    fi
    
    # 确保所有值都是数字
    [[ "$upload_speed" =~ ^[0-9]+$ ]] || upload_speed=0
    [[ "$download_speed" =~ ^[0-9]+$ ]] || download_speed=0
    [[ "$total_upload" =~ ^[0-9]+$ ]] || total_upload=0
    [[ "$total_download" =~ ^[0-9]+$ ]] || total_download=0
    
    echo "{\"upload_speed\":$upload_speed,\"download_speed\":$download_speed,\"total_upload\":$total_upload,\"total_download\":$total_download}"
}

# 获取系统运行时间
get_uptime() {
    local uptime_seconds=0
    
    if [[ "$OS" == "FreeBSD" ]]; then
        if command_exists sysctl; then
            local boot_time_raw=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | tr -d ',' 2>/dev/null || echo "0")
            local boot_time=$(sanitize_integer "$boot_time_raw" "0")
            local current_time=$(date +%s)
            
            if [[ $boot_time -gt 0 && $current_time -gt $boot_time ]]; then
                uptime_seconds=$((current_time - boot_time))
            fi
        fi
    else
        if [[ -f /proc/uptime ]]; then
            uptime_seconds=$(cut -d. -f1 /proc/uptime)
        fi
    fi
    
    echo "$uptime_seconds"
}

# ==================== 数据上报 ====================

# 获取服务器配置
get_config() {
    local max_attempts=3
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        log "正在获取服务器配置... (第 $attempt/$max_attempts 次)"
        
        local response=$(curl -s -w "%{http_code}" -X GET "$WORKER_URL/api/config/$SERVER_ID" \
            -H "X-API-Key: $API_KEY" 2>/dev/null || echo "000")
        
        local http_code="${response: -3}"
        local response_body="${response%???}"
        
        if [[ "$http_code" == "200" ]]; then
            log "配置获取成功"
            
            # 简化的间隔解析
            local new_interval=$(echo "$response_body" | sed -n 's/.*"interval":\([0-9]\+\).*/\1/p')
            
            if [[ -n "$new_interval" && "$new_interval" =~ ^[0-9]+$ && "$new_interval" -gt 0 ]]; then
                if [[ "$new_interval" != "$INTERVAL" ]]; then
                    log "服务器返回新的上报间隔: ${new_interval}秒 (当前: ${INTERVAL}秒)"
                    INTERVAL="$new_interval"
                    save_config
                    log "上报间隔已更新为: ${INTERVAL}秒"
                fi
            fi
            
            return 0
        else
            log "配置获取失败 (HTTP $http_code)"
            
            case "$http_code" in
                "401") log "认证失败 - 请检查API密钥" ;;
                "404") log "服务器不存在 - 请检查服务器ID" ;;
                "000") log "网络连接失败" ;;
            esac
            
            if [[ $attempt -lt $max_attempts ]]; then
                log "等待2秒后重试..."
                sleep 2
            fi
        fi
        
        attempt=$((attempt + 1))
    done
    
    log "配置获取最终失败"
    return 1
}

# 上报监控数据
report_metrics() {
    local timestamp=$(date +%s)
    local cpu_raw=$(get_cpu_usage)
    local memory_raw=$(get_memory_usage)
    local disk_raw=$(get_disk_usage)
    local network_raw=$(get_network_usage)
    local uptime_raw=$(get_uptime)
    
    # 验证运行时间
    local uptime=$(sanitize_integer "$uptime_raw" "0")
    
    # 清理JSON数据
    cpu_raw=$(clean_json_string "$cpu_raw")
    memory_raw=$(clean_json_string "$memory_raw")
    disk_raw=$(clean_json_string "$disk_raw")
    network_raw=$(clean_json_string "$network_raw")
    
    # 简单验证JSON格式
    [[ ! "$cpu_raw" =~ ^\{.*\}$ ]] && cpu_raw='{"usage_percent":0,"load_avg":[0,0,0]}'
    [[ ! "$memory_raw" =~ ^\{.*\}$ ]] && memory_raw='{"total":0,"used":0,"free":0,"usage_percent":0}'
    [[ ! "$disk_raw" =~ ^\{.*\}$ ]] && disk_raw='{"total":0,"used":0,"free":0,"usage_percent":0}'
    [[ ! "$network_raw" =~ ^\{.*\}$ ]] && network_raw='{"upload_speed":0,"download_speed":0,"total_upload":0,"total_download":0}'
    
    # 构建JSON数据
    local data="{\"timestamp\":$timestamp,\"cpu\":$cpu_raw,\"memory\":$memory_raw,\"disk\":$disk_raw,\"network\":$network_raw,\"uptime\":$uptime}"
    
    # 确保API KEY和ID没有多余的空格或换行
    local clean_api_key=$(echo "$API_KEY" | tr -d ' \n\r')
    local clean_server_id=$(echo "$SERVER_ID" | tr -d ' \n\r')
    
    log "正在上报数据到 $WORKER_URL/api/report/$clean_server_id"
    
    local response=$(curl -s -w "%{http_code}" -X POST "$WORKER_URL/api/report/$clean_server_id" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: $clean_api_key" \
        -d "$data" 2>/dev/null || echo "000")
    
    local http_code="${response: -3}"
    local response_body="${response%???}"
    
    if [[ "$http_code" == "200" ]]; then
        log "数据上报成功"
        
        # 尝试从响应中解析新的间隔设置
        if command_exists jq; then
            local new_interval=$(echo "$response_body" | jq -r '.interval // empty' 2>/dev/null)
            if [[ -n "$new_interval" && "$new_interval" =~ ^[0-9]+$ && "$new_interval" -gt 0 ]]; then
                if [[ "$new_interval" != "$INTERVAL" ]]; then
                    log "服务器返回新的上报间隔: ${new_interval}秒 (当前: ${INTERVAL}秒)"
                    INTERVAL="$new_interval"
                    save_config
                    log "上报间隔已更新为: ${INTERVAL}秒"
                    touch "$SCRIPT_DIR/restart_needed"
                fi
            fi
        else
            local new_interval=$(echo "$response_body" | sed -n 's/.*"interval":\([0-9]\+\).*/\1/p')
            if [[ -n "$new_interval" && "$new_interval" =~ ^[0-9]+$ && "$new_interval" -gt 0 ]]; then
                if [[ "$new_interval" != "$INTERVAL" ]]; then
                    log "服务器返回新的上报间隔: ${new_interval}秒 (当前: ${INTERVAL}秒)"
                    INTERVAL="$new_interval"
                    save_config
                    log "上报间隔已更新为: ${INTERVAL}秒"
                    touch "$SCRIPT_DIR/restart_needed"
                fi
            fi
        fi
        
        return 0
    else
        # 错误分类处理
        case "$http_code" in
            "400"|"413")
                log "数据上报失败 (HTTP $http_code): 数据格式或大小问题"
                return 1
                ;;
            "401"|"403")
                log "数据上报失败 (HTTP $http_code): 认证失败"
                return 1
                ;;
            "404")
                log "数据上报失败 (HTTP $http_code): 服务器不存在"
                return 1
                ;;
            "429"|"500"|"502"|"503"|"504"|"000")
                log "数据上报失败 (HTTP $http_code): 可重试的错误"
                return 2
                ;;
            *)
                log "数据上报失败 (HTTP $http_code): 未知错误"
                return 1
                ;;
        esac
    fi
}

# ==================== 服务脚本创建 ====================

# 创建监控服务脚本
create_service_script() {
    # 获取当前脚本的绝对路径
    local main_script_path=$(realpath "$0" 2>/dev/null || echo "$0")
    
    cat > "$SERVICE_FILE" << EOF
#!/bin/bash

# cf-vps-monitor服务脚本 - 集中式文件管理
SCRIPT_DIR="$SCRIPT_DIR"
CONFIG_FILE="\$SCRIPT_DIR/config/config"
LOG_FILE="\$SCRIPT_DIR/logs/monitor.log"
PID_FILE="\$SCRIPT_DIR/run/monitor.pid"
MAIN_SCRIPT="$main_script_path"

# 设置服务模式标志
export SERVICE_MODE=true

# 确保日志目录存在
mkdir -p "\$(dirname "\$LOG_FILE")" 2>/dev/null

# 加载配置
if [[ -f "\$CONFIG_FILE" ]]; then
    source "\$CONFIG_FILE"
else
    echo "配置文件不存在: \$CONFIG_FILE" >> "\$LOG_FILE"
    exit 1
fi

# 加载主脚本中的函数
load_functions() {
    # 定义必要的函数
    sanitize_integer() {
        local value="\$1"
        local default_value="\${2:-0}"
        value=\$(echo "\$value" | sed 's/[^0-9]//g')
        [[ "\$value" =~ ^[0-9]+\$ ]] && echo "\$value" || echo "\$default_value"
    }
    
    clean_json_string() {
        local input="\$1"
        echo "\$input" | tr -d '\\000-\\037' | tr -d '\\177-\\377'
    }
    
    # CPU使用率函数
    get_cpu_usage() {
        local cpu_usage=0
        local load1=0 load5=0 load15=0
        
        if [[ -f /proc/stat ]]; then
            local cpu_line=\$(head -n1 /proc/stat 2>/dev/null)
            if [[ -n "\$cpu_line" ]]; then
                local cpu_times=(\$cpu_line)
                if [[ \${#cpu_times[@]} -ge 8 ]]; then
                    local idle=\${cpu_times[4]}
                    local total=0
                    for i in {1..7}; do
                        if [[ -n "\${cpu_times[i]}" && "\${cpu_times[i]}" =~ ^[0-9]+\$ ]]; then
                            total=\$((total + cpu_times[i]))
                        fi
                    done
                    if [[ \$total -gt 0 ]]; then
                        cpu_usage=\$(echo "scale=1; 100 - (\$idle * 100 / \$total)" | bc 2>/dev/null || echo "0")
                    fi
                fi
            fi
        fi
        
        if [[ -f /proc/loadavg ]]; then
            local load_data=\$(cat /proc/loadavg 2>/dev/null | awk '{print \$1" "\$2" "\$3}' || echo "0 0 0")
            read -r load1 load5 load15 <<< "\$load_data"
        fi
        
        echo "{\\"usage_percent\\":\$cpu_usage,\\"load_avg\\":[\$load1,\$load5,\$load15]}"
    }
    
    # 内存使用函数
    get_memory_usage() {
        local total=0 used=0 free=0 usage_percent=0
        
        if command_exists free; then
            local mem_info=\$(free -k 2>/dev/null | grep "^Mem:")
            if [[ -n "\$mem_info" ]]; then
                total=\$(echo "\$mem_info" | awk '{print \$2}')
                local available=\$(echo "\$mem_info" | awk '{print \$7}' 2>/dev/null || echo "")
                if [[ "\$available" =~ ^[0-9]+\$ ]]; then
                    free=\$available
                    used=\$((total - free))
                else
                    local raw_used=\$(echo "\$mem_info" | awk '{print \$3}' 2>/dev/null || echo "0")
                    if [[ "\$raw_used" =~ ^[0-9]+\$ ]]; then
                        used=\$raw_used
                        free=\$((total - used))
                    fi
                fi
            fi
        fi
        
        if [[ \$total -gt 0 ]]; then
            usage_percent=\$(echo "scale=1; \$used * 100 / \$total" | bc 2>/dev/null || echo "0")
        fi
        
        echo "{\\"total\\":\$total,\\"used\\":\$used,\\"free\\":\$free,\\"usage_percent\\":\$usage_percent}"
    }
    
    # 磁盘使用函数
    get_disk_usage() {
        local total=0 used=0 free=0 usage_percent=0
        
        if command_exists df; then
            local disk_info=\$(df -k / 2>/dev/null | tail -1)
            if [[ -n "\$disk_info" ]]; then
                total=\$(echo "\$disk_info" | awk '{printf "%.2f", \$2 / 1024 / 1024}' 2>/dev/null || echo "0")
                used=\$(echo "\$disk_info" | awk '{printf "%.2f", \$3 / 1024 / 1024}' 2>/dev/null || echo "0")
                free=\$(echo "\$disk_info" | awk '{printf "%.2f", \$4 / 1024 / 1024}' 2>/dev/null || echo "0")
                usage_percent=\$(echo "\$disk_info" | awk '{print \$5}' | tr -d '%' 2>/dev/null || echo "0")
            fi
        fi
        
        echo "{\\"total\\":\$total,\\"used\\":\$used,\\"free\\":\$free,\\"usage_percent\\":\$usage_percent}"
    }
    
    # 网络使用函数
    get_network_usage() {
        local upload_speed=0 download_speed=0 total_upload=0 total_download=0
        
        # 简单实现，返回基础数据
        echo "{\\"upload_speed\\":\$upload_speed,\\"download_speed\\":\$download_speed,\\"total_upload\\":\$total_upload,\\"total_download\\":\$total_download}"
    }
    
    # 运行时间函数
    get_uptime() {
        local uptime_seconds=0
        if [[ -f /proc/uptime ]]; then
            uptime_seconds=\$(cut -d. -f1 /proc/uptime)
        fi
        echo "\$uptime_seconds"
    }
}

# 上报监控数据
report_metrics_service() {
    local timestamp=\$(date +%s)
    
    # 加载函数
    load_functions
    
    local cpu_raw=\$(get_cpu_usage)
    local memory_raw=\$(get_memory_usage)
    local disk_raw=\$(get_disk_usage)
    local network_raw=\$(get_network_usage)
    local uptime=\$(get_uptime)
    
    # 清理数据
    cpu_raw=\$(clean_json_string "\$cpu_raw")
    memory_raw=\$(clean_json_string "\$memory_raw")
    disk_raw=\$(clean_json_string "\$disk_raw")
    network_raw=\$(clean_json_string "\$network_raw")
    
    # 构建JSON数据
    local data="{\\"timestamp\\":\$timestamp,\\"cpu\\":\$cpu_raw,\\"memory\\":\$memory_raw,\\"disk\\":\$disk_raw,\\"network\\":\$network_raw,\\"uptime\\":\$uptime}"
    
    # 清理API KEY和ID
    local clean_api_key=\$(echo "\$API_KEY" | tr -d ' \\n\\r')
    local clean_server_id=\$(echo "\$SERVER_ID" | tr -d ' \\n\\r')
    
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 正在上报数据..." >> "\$LOG_FILE"
    
    local response=\$(curl -s -w "%{http_code}" -X POST "\$WORKER_URL/api/report/\$clean_server_id" \\
        -H "Content-Type: application/json" \\
        -H "X-API-Key: \$clean_api_key" \\
        -d "\$data" 2>/dev/null || echo "000")
    
    local http_code="\${response: -3}"
    
    if [[ "\$http_code" == "200" ]]; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 数据上报成功" >> "\$LOG_FILE"
        return 0
    else
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 数据上报失败 (HTTP \$http_code)" >> "\$LOG_FILE"
        return 1
    fi
}

# 主循环
main_service() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] VPS监控服务启动 (PID: \$\$)" >> "\$LOG_FILE"
    echo \$\$ > "\$PID_FILE"
    
    # 信号处理
    trap 'echo "[\$(date +"%Y-%m-%d %H:%M:%S")] 收到终止信号，正在停止..." >> "\$LOG_FILE"; rm -f "\$PID_FILE"; exit 0' TERM INT
    
    while true; do
        if ! report_metrics_service; then
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 上报失败，将在下个周期重试" >> "\$LOG_FILE"
        fi
        
        # 检查是否需要重启以应用新的间隔设置
        if [[ -f "\$SCRIPT_DIR/restart_needed" ]]; then
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 检测到间隔设置变更，正在重新加载配置..." >> "\$LOG_FILE"
            rm -f "\$SCRIPT_DIR/restart_needed"
            # 重新加载配置
            if [[ -f "\$CONFIG_FILE" ]]; then
                source "\$CONFIG_FILE"
                echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 已重新加载配置，新的上报间隔: \${INTERVAL}秒" >> "\$LOG_FILE"
            fi
        fi
        
        sleep "\$INTERVAL"
    done
}

# 启动主函数
main_service
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

# 获取进程命令行
get_process_command() {
    local pid="$1"
    
    if [[ "$OS" == "FreeBSD" ]]; then
        ps -p "$pid" -o command 2>/dev/null | tail -n +2 | head -1 || echo "unknown"
    else
        ps -p "$pid" -o cmd= 2>/dev/null || echo "unknown"
    fi
}

# 查找监控进程
find_monitor_processes() {
    local pids=""
    
    # 层次1: PID文件检测
    if [[ -f "$PID_FILE" ]]; then
        local file_pid=$(cat "$PID_FILE" 2>/dev/null)
        if validate_pid "$file_pid"; then
            pids="$file_pid"
        fi
    fi
    
    # 层次2: 精确脚本路径匹配
    if [[ -z "$pids" ]] && [[ -f "${SERVICE_FILE:-}" ]]; then
        if [[ "$OS" == "FreeBSD" ]]; then
            pids=$(ps axww | grep "$SERVICE_FILE" | grep -v grep | awk '{print $1}')
        else
            pids=$(ps aux | grep "$SERVICE_FILE" | grep -v grep | awk '{print $2}')
        fi
    fi
    
    # 层次3: 验证所有PID并确认命令行
    local valid_pids=""
    for pid in $pids; do
        if validate_pid "$pid"; then
            local cmd=$(get_process_command "$pid")
            if [[ "$cmd" =~ (vps-monitor-service|cf-vps-monitor) ]]; then
                valid_pids="$valid_pids $pid"
            fi
        fi
    done
    
    echo "$valid_pids" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

# 检查监控服务是否运行
is_monitor_running() {
    local pids=$(find_monitor_processes)
    [[ -n "$pids" ]]
}

# 停止单个进程
stop_single_process() {
    local pid="$1"
    
    # 首先验证PID
    if ! validate_pid "$pid"; then
        print_message "$YELLOW" "  ⚠ PID $pid 无效或进程不存在"
        return 1
    fi
    
    # 获取正确的进程信息
    local cmd=$(get_process_command "$pid")
    print_message "$BLUE" "停止进程: $cmd (PID: $pid)"
    
    # 1. 温和停止（SIGTERM）
    if kill "$pid" 2>/dev/null; then
        sleep 2
        
        # 2. 检查是否还在运行
        if ! kill -0 "$pid" 2>/dev/null; then
            print_message "$GREEN" "  ✓ 进程已正常停止"
            return 0
        fi
        
        # 3. 强制停止（SIGKILL）
        if kill -9 "$pid" 2>/dev/null; then
            sleep 1
            
            # 4. 最终确认
            if ! kill -0 "$pid" 2>/dev/null; then
                print_message "$GREEN" "  ✓ 进程已强制停止"
                return 0
            else
                print_message "$RED" "  ✗ 进程无法停止"
                return 1
            fi
        fi
    fi
    
    print_message "$YELLOW" "  ⚠ 无法发送信号"
    return 1
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
        local stopped_count=0
        local total_count=0
        
        for pid in $pids; do
            total_count=$((total_count + 1))
            if stop_single_process "$pid"; then
                stopped_count=$((stopped_count + 1))
                stopped=true
            fi
        done
        
        if [[ $stopped_count -gt 0 ]]; then
            print_message "$GREEN" "✓ 已停止 $stopped_count/$total_count 个监控进程"
        fi
    fi
    
    # 2. 清理PID文件
    rm -f "$PID_FILE" 2>/dev/null || true
    
    # 3. 移除自启动
    remove_autostart
    
    # 4. 结果报告
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
    
    # 2. systemd服务（用户级）
    if command_exists systemctl; then
        local service_path="$HOME/.config/systemd/user/cf-vps-monitor.service"
        mkdir -p "$(dirname "$service_path")" 2>/dev/null
        
        if [[ ! -f "$service_path" ]]; then
            cat > "$service_path" << EOF
[Unit]
Description=CF VPS Monitor Service
After=network.target

[Service]
Type=simple
ExecStart=$SERVICE_FILE
Restart=always
RestartSec=10
User=$USER
WorkingDirectory=$HOME

[Install]
WantedBy=default.target
EOF
            
            systemctl --user daemon-reload 2>/dev/null || true
            systemctl --user enable cf-vps-monitor.service 2>/dev/null || true
            print_message "$GREEN" "  ✓ systemd服务已配置"
        fi
    fi
    
    print_message "$GREEN" "✓ 自启动设置配置完成"
}

# 移除自启动
remove_autostart() {
    print_message "$BLUE" "移除自启动设置..."
    
    # 1. 移除crontab条目
    if command_exists crontab; then
        local current_crontab=$(crontab -l 2>/dev/null || echo "")
        if echo "$current_crontab" | grep -q "cf-vps-monitor"; then
            echo "$current_crontab" | grep -v "cf-vps-monitor" | crontab - 2>/dev/null
            print_message "$GREEN" "  ✓ crontab自启动已移除"
        fi
    fi
    
    # 2. 移除systemd服务
    local service_path="$HOME/.config/systemd/user/cf-vps-monitor.service"
    if [[ -f "$service_path" ]] && command_exists systemctl; then
        systemctl --user stop cf-vps-monitor.service 2>/dev/null || true
        systemctl --user disable cf-vps-monitor.service 2>/dev/null || true
        rm -f "$service_path"
        systemctl --user daemon-reload 2>/dev/null || true
        print_message "$GREEN" "  ✓ systemd服务已移除"
    fi
    
    print_message "$GREEN" "✓ 自启动设置已移除"
}

# ==================== 配置监控参数 ====================

# 配置监控参数
configure_monitor() {
    print_message "$BLUE" "配置监控参数"
    echo
    
    load_config
    
    # Server ID
    echo -n "请输入Server ID"
    if [[ -n "$SERVER_ID" ]]; then
        echo -n " (当前: $SERVER_ID)"
    fi
    echo -n ": "
    read -r input_server_id
    if [[ -n "$input_server_id" ]]; then
        SERVER_ID="$input_server_id"
    fi
    
    # API Key
    echo -n "请输入API Key"
    if [[ -n "$API_KEY" ]]; then
        echo -n " (当前: ${API_KEY:0:8}...)"
    fi
    echo -n ": "
    read -r input_api_key
    if [[ -n "$input_api_key" ]]; then
        API_KEY="$input_api_key"
    fi
    
    # Worker URL
    echo -n "请输入Worker URL"
    if [[ -n "$WORKER_URL" ]]; then
        echo -n " (当前: $WORKER_URL)"
    fi
    echo -n ": "
    read -r input_url
    if [[ -n "$input_url" ]]; then
        WORKER_URL="$input_url"
    fi
    
    # 设置默认上报间隔
    if [[ -z "$INTERVAL" ]]; then
        INTERVAL="10"
    fi
    print_message "$CYAN" "上报间隔设置为: ${INTERVAL}秒"
    
    # 验证配置
    if [[ -z "$WORKER_URL" || -z "$SERVER_ID" || -z "$API_KEY" ]]; then
        print_message "$RED" "配置不完整，请确保所有必需参数都已填写"
        return 1
    fi
    
    # 保存配置
    save_config
    print_message "$GREEN" "配置保存成功"
    
    # 询问是否测试连接
    echo
    echo -n "是否测试连接? (y/N): "
    read -r test_choice
    if [[ "$test_choice" =~ ^[Yy]$ ]]; then
        test_connection
    fi
}

# 测试连接
test_connection() {
    print_message "$BLUE" "测试连接到监控服务器..."
    
    load_config
    
    if [[ -z "$WORKER_URL" || -z "$SERVER_ID" || -z "$API_KEY" ]]; then
        print_message "$RED" "配置不完整，请先配置监控参数"
        return 1
    fi
    
    print_message "$BLUE" "正在测试配置获取..."
    if get_config; then
        print_message "$GREEN" "✓ 配置获取测试成功"
    else
        print_message "$YELLOW" "⚠ 配置获取测试失败，但不影响基本功能"
    fi
    
    print_message "$BLUE" "正在测试数据上报..."
    if report_metrics; then
        print_message "$GREEN" "✓ 数据上报测试成功"
    else
        print_message "$RED" "✗ 数据上报测试失败，请检查配置和网络"
        return 1
    fi
    
    print_message "$GREEN" "✓ 连接测试完成"
}

# ==================== 服务状态检查 ====================

# 检查服务状态
check_service_status() {
    print_message "$BLUE" "检查监控服务状态..."
    echo
    
    # 1. 检查进程
    if is_monitor_running; then
        local pids=$(find_monitor_processes)
        local pid_count=$(echo "$pids" | wc -w)
        
        print_message "$GREEN" "✓ 监控服务正在运行"
        
        if [[ $pid_count -eq 1 ]]; then
            local pid=$(echo "$pids" | awk '{print $1}')
            local cmd=$(get_process_command "$pid")
            print_message "$CYAN" "  进程信息: PID $pid"
            print_message "$CYAN" "  命令行: $cmd"
        else
            print_message "$YELLOW" "  发现多个进程实例 ($pid_count 个):"
            for pid in $pids; do
                local cmd=$(get_process_command "$pid")
                print_message "$CYAN" "    PID $pid: $cmd"
            done
        fi
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
        print_message "$CYAN" "  最后10行日志:"
        echo "----------------------------------------"
        tail -n 10 "$LOG_FILE" 2>/dev/null || echo "无法读取日志文件"
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

# ==================== 安装监控服务 ====================

# 安装监控服务
install_monitor() {
    print_message "$BLUE" "开始安装VPS监控服务..."
    echo
    
    # 检测系统
    detect_system
    detect_package_manager
    
    # 安装依赖
    install_dependencies
    
    # 创建目录结构
    create_directories
    
    # 配置监控参数
    if ! configure_monitor; then
        error_exit "配置失败，安装中止"
    fi
    
    # 创建服务脚本
    create_service_script
    
    # 配置自启动
    configure_autostart
    
    # 启动服务
    echo
    if start_service; then
        print_message "$GREEN" "✓ VPS监控服务安装并启动成功"
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
    else
        error_exit "服务启动失败"
    fi
}

# 彻底卸载监控服务
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
    
    # 2. 删除安装目录
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
    if report_metrics; then
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

# ==================== 显示帮助信息 ====================

# 显示帮助信息
show_help() {
    echo "VPS监控脚本 v2.0"
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

# 显示交互菜单
show_menu() {
    while true; do
        clear
        print_message "$CYAN" "=================================="
        print_message "$CYAN" "       VPS监控服务管理菜单"
        print_message "$CYAN" "=================================="
        echo
        echo "1. 安装监控服务"
        echo "2. 启动监控服务"
        echo "3. 停止监控服务"
        echo "4. 重启监控服务"
        echo "5. 查看服务状态"
        echo "6. 查看运行日志"
        echo "7. 配置监控参数"
        echo "8. 测试连接"
        echo "9. 彻底卸载服务"
        echo "0. 退出"
        echo
        echo -n "请选择操作 (0-9): "
        read -r choice
        
        case $choice in
            1) install_monitor ;;
            2) start_service ;;
            3) stop_service ;;
            4) 
                stop_service
                sleep 1
                start_service
                ;;
            5) check_service_status ;;
            6) view_logs ;;
            7) configure_monitor ;;
            8) test_connection ;;
            9) uninstall_monitor ;;
            0) 
                print_message "$GREEN" "感谢使用VPS监控服务！"
                exit 0
                ;;
            *)
                print_message "$RED" "无效选择，请重新输入"
                sleep 1
                ;;
        esac
        
        echo
        print_message "$BLUE" "按任意键继续..."
        read -r
    done
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

# 主函数
main() {
    # 首先尝试解析命令行参数
    if parse_arguments "$@"; then
        return
    fi
    
    # 如果没有参数，显示菜单
    if [[ $# -eq 0 ]]; then
        show_menu
        return
    fi
    
    # 处理命令行参数
    case "$1" in
        install)
            install_monitor
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
        config)
            configure_monitor
            ;;
        test)
            test_connection
            ;;
        menu)
            show_menu
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_message "$RED" "未知选项: $1"
            echo
            show_help
            exit 1
            ;;
    esac
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
