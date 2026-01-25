#!/bin/bash

# cf-vps-monitor - Cloudflare Worker VPS监控脚本
# 版本: 1.2.0 (优化版)
# 支持所有常见Linux系统，无需root权限

set -euo pipefail

# ==================== 全局变量和配置 ====================
readonly SCRIPT_VERSION="1.2.0"
readonly SCRIPT_NAME="cf-vps-monitor"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# 全局变量 - 集中式文件管理
readonly SCRIPT_DIR="$HOME/.cf-vps-monitor"
readonly CONFIG_FILE="$SCRIPT_DIR/config/config"
readonly LOG_FILE="$SCRIPT_DIR/logs/monitor.log"
readonly PID_FILE="$SCRIPT_DIR/run/monitor.pid"
readonly SERVICE_FILE="$SCRIPT_DIR/bin/vps-monitor-service.sh"
readonly INSTALL_MANIFEST="$SCRIPT_DIR/system/install.manifest"
readonly CACHE_DIR="$SCRIPT_DIR/cache"
readonly CONFIG_CACHE_FILE="$CACHE_DIR/config.json"

# 默认配置
readonly DEFAULT_INTERVAL=10
readonly DEFAULT_WORKER_URL=""
readonly DEFAULT_SERVER_ID=""
readonly DEFAULT_API_KEY=""

# 系统检测结果缓存
declare -g OS ARCH KERNEL_VERSION VER DISTRO_ID DISTRO_NAME
declare -g PKG_MANAGER PKG_INSTALL PKG_UPDATE PKG_SEARCH PKG_INFO
declare -g IS_CONTAINER CONTAINER_TYPE VIRTUALIZATION

# ==================== 工具函数 ====================

# 打印带颜色的消息
print_message() {
    local color="$1"
    local message="$2"
    printf "%b%s%b\n" "${color}" "${message}" "${NC}"
}

# 日志函数
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 写入日志文件
    echo "[$timestamp] $message" >> "$LOG_FILE"
    
    # 只在非服务模式下输出到控制台
    if [[ "${SERVICE_MODE:-false}" != "true" ]]; then
        echo "[$timestamp] $message"
    fi
}

# 错误处理
error_exit() {
    local message="$1"
    print_message "$RED" "错误: $message" >&2
    log "ERROR: $message"
    exit 1
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 验证和清理数值
sanitize_number() {
    local value="$1"
    local default_value="${2:-0}"
    
    # 移除所有非数字和非小数点的字符
    value=$(echo "$value" | tr -d -c '0-9.')
    
    if [[ "$value" =~ ^[0-9]*\.?[0-9]+$ ]] || [[ "$value" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        [[ "$value" =~ ^\. ]] && value="0$value"
        [[ "$value" =~ \.$ ]] && value="${value}0"
        echo "$value"
    else
        echo "$default_value"
    fi
}

# 验证和清理整数
sanitize_integer() {
    local value="$1"
    local default_value="${2:-0}"
    
    value=$(echo "$value" | tr -d -c '0-9')
    [[ "$value" =~ ^[0-9]+$ ]] && echo "$value" || echo "$default_value"
}

# 清理JSON字符串
clean_json_string() {
    local input="$1"
    # 移除控制字符，保留可打印字符
    echo "$input" | tr -d '\000-\037\177-\377'
}

# ==================== 系统检测函数 ====================

# 检测系统信息（缓存版本）
detect_system() {
    # 如果已经检测过，直接返回
    [[ -n "${OS:-}" ]] && return 0
    
    local system_info
    system_info=$(uname -srm)
    IFS=' ' read -r OS KERNEL_VERSION ARCH <<< "$system_info"
    
    # 缓存系统类型用于快速判断
    case "$OS" in
        "FreeBSD"|"OpenBSD"|"NetBSD")
            IS_CONTAINER="false"
            CONTAINER_TYPE="none"
            VIRTUALIZATION="none"
            VER=$(echo "$KERNEL_VERSION" | cut -d'-' -f1)
            DISTRO_ID="${OS,,}"
            DISTRO_NAME="$OS"
            ;;
        "Darwin")
            IS_CONTAINER="false"
            CONTAINER_TYPE="none"
            VIRTUALIZATION="none"
            VER=$(sw_vers -productVersion 2>/dev/null || echo "$KERNEL_VERSION")
            DISTRO_ID="macos"
            DISTRO_NAME="macOS"
            ;;
        "Linux"|*)
            IS_CONTAINER="false"
            [[ -f /.dockerenv ]] && IS_CONTAINER="true" && CONTAINER_TYPE="docker"
            
            if [[ -f /etc/os-release ]]; then
                # 一次读取所有os-release信息
                local os_info
                os_info=$(cat /etc/os-release 2>/dev/null)
                DISTRO_ID=$(echo "$os_info" | grep '^ID=' | cut -d= -f2 | tr -d '"' || echo "linux")
                VER=$(echo "$os_info" | grep '^VERSION_ID=' | cut -d= -f2 | tr -d '"' || echo "unknown")
                DISTRO_NAME=$(echo "$os_info" | grep '^NAME=' | cut -d= -f2 | tr -d '"' || echo "Linux")
            else
                DISTRO_ID="linux"
                VER="unknown"
                DISTRO_NAME="Linux"
            fi
            ;;
    esac
    
    log "检测到系统: $DISTRO_NAME $VER ($ARCH)"
}

# 检测包管理器（缓存版本）
detect_package_manager() {
    # 如果已经检测过，直接返回
    [[ -n "${PKG_MANAGER:-}" ]] && return 0
    
    detect_system
    
    case "$OS" in
        "FreeBSD"|"OpenBSD"|"NetBSD")
            [[ "$OS" == "OpenBSD" ]] && command_exists pkg_add && PKG_MANAGER="pkg_add" || PKG_MANAGER="pkg"
            ;;
        "Darwin")
            command_exists brew && PKG_MANAGER="brew" || PKG_MANAGER="port"
            ;;
        *)
            # Linux发行版包管理器检测
            local managers=(
                "apt-get:apt-get install -y:apt-get update:apt-cache search:apt-cache show"
                "apt:apt install -y:apt update:apt search:apt show"
                "dnf:dnf install -y:dnf update -y:dnf search:dnf info"
                "yum:yum install -y:yum update -y:yum search:yum info"
                "zypper:zypper install -y:zypper refresh:zypper search:zypper info"
                "pacman:pacman -S --noconfirm:pacman -Sy:pacman -Ss:pacman -Si"
                "apk:apk add:apk update:apk search:apk info"
            )
            
            for manager_info in "${managers[@]}"; do
                local manager="${manager_info%%:*}"
                if command_exists "$manager"; then
                    IFS=':' read -r _ install_cmd update_cmd search_cmd info_cmd <<< "$manager_info"
                    PKG_MANAGER="$manager"
                    PKG_INSTALL="$install_cmd"
                    PKG_UPDATE="$update_cmd"
                    PKG_SEARCH="$search_cmd"
                    PKG_INFO="$info_cmd"
                    break
                fi
            done
            ;;
    esac
    
    [[ -n "$PKG_MANAGER" ]] && log "检测到包管理器: $PKG_MANAGER"
}

# ==================== 文件系统函数 ====================

# 创建集中式目录结构
create_directories() {
    local dirs=(
        "$SCRIPT_DIR/bin"
        "$SCRIPT_DIR/config" 
        "$SCRIPT_DIR/logs"
        "$SCRIPT_DIR/tmp"
        "$SCRIPT_DIR/cache"
        "$SCRIPT_DIR/run"
        "$SCRIPT_DIR/system/templates"
        "$SCRIPT_DIR/system/backups"
    )
    
    print_message "$BLUE" "创建集中式目录结构..."
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir" 2>/dev/null || error_exit "无法创建目录: $dir"
    done
    
    touch "$INSTALL_MANIFEST"
    export TMPDIR="$SCRIPT_DIR/tmp"
    
    print_message "$GREEN" "✓ 目录结构创建完成"
}

# 记录安装项到安装清单
record_installation() {
    printf "%s:%s:%s:%s\n" "$1" "$2" "$3" "${4:-none}" >> "$INSTALL_MANIFEST"
}

# ==================== 配置管理函数 ====================

# 加载配置
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # 安全地source配置文件
        local config_content
        config_content=$(cat "$CONFIG_FILE")
        eval "$config_content"
    else
        WORKER_URL=$(echo "$DEFAULT_WORKER_URL" | tr -d ' \n\r')
        SERVER_ID=$(echo "$DEFAULT_SERVER_ID" | tr -d ' \n\r')
        API_KEY=$(echo "$DEFAULT_API_KEY" | tr -d ' \n\r')
        INTERVAL="$DEFAULT_INTERVAL"
    fi
}

# 保存配置
save_config() {
    # 清理并验证配置
    WORKER_URL=$(sanitize_string "$WORKER_URL")
    SERVER_ID=$(sanitize_string "$SERVER_ID")
    API_KEY=$(sanitize_string "$API_KEY")
    INTERVAL=$(sanitize_integer "$INTERVAL" "$DEFAULT_INTERVAL")
    
    cat > "$CONFIG_FILE" << EOF
# VPS监控配置文件
WORKER_URL="$WORKER_URL"
SERVER_ID="$SERVER_ID"
API_KEY="$API_KEY"
INTERVAL="$INTERVAL"
EOF
    
    chmod 600 "$CONFIG_FILE"
    print_message "$GREEN" "配置已保存"
}

# 清理字符串（移除特殊字符）
sanitize_string() {
    echo "$1" | tr -d '\r\n\t' | sed 's/[^[:print:]]//g'
}

# ==================== 资源监控函数（优化版） ====================

# 统一的资源获取函数
get_system_resource() {
    local resource_type="$1"
    
    case "$resource_type" in
        "cpu")
            get_cpu_usage_safe
            ;;
        "memory")
            get_memory_usage_safe
            ;;
        "disk")
            get_disk_usage_safe
            ;;
        "network")
            get_network_usage_safe
            ;;
        "uptime")
            get_uptime_safe
            ;;
        *)
            echo "{}"
            ;;
    esac
}

# 安全获取CPU使用率
get_cpu_usage_safe() {
    local cpu_usage=0
    local load_avg="0,0,0"
    
    if [[ "$OS" == "FreeBSD" ]]; then
        # FreeBSD CPU使用率
        if command_exists sysctl; then
            local cpu_times
            cpu_times=$(sysctl -n kern.cp_time 2>/dev/null)
            if [[ -n "$cpu_times" ]]; then
                # 解析CPU时间
                local -a times=($cpu_times)
                local idle=${times[4]:-0}
                local total=0
                
                for ((i=0; i<5; i++)); do
                    [[ -n "${times[i]}" ]] && total=$((total + times[i]))
                done
                
                [[ $total -gt 0 ]] && cpu_usage=$((100 - (idle * 100 / total)))
            fi
            
            # FreeBSD负载
            local load_info
            load_info=$(sysctl -n vm.loadavg 2>/dev/null)
            [[ -n "$load_info" ]] && load_avg=$(echo "$load_info" | awk '{print $2","$3","$4}')
        fi
    else
        # Linux CPU使用率
        if [[ -f /proc/stat ]]; then
            local cpu_line
            cpu_line=$(head -n1 /proc/stat 2>/dev/null)
            if [[ -n "$cpu_line" ]]; then
                local -a cpu_times=($cpu_line)
                local idle=${cpu_times[4]:-0}
                local iowait=${cpu_times[5]:-0}
                local total=0
                
                for ((i=1; i<=7; i++)); do
                    [[ -n "${cpu_times[i]}" ]] && total=$((total + cpu_times[i]))
                done
                
                [[ $total -gt 0 ]] && cpu_usage=$((100 - ((idle + iowait) * 100 / total)))
            fi
        fi
        
        # Linux负载
        if [[ -f /proc/loadavg ]]; then
            load_avg=$(awk '{print $1","$2","$3}' /proc/loadavg 2>/dev/null)
        fi
    fi
    
    cpu_usage=$(sanitize_number "$cpu_usage" "0")
    echo "{\"usage_percent\":$cpu_usage,\"load_avg\":[$load_avg]}"
}

# 安全获取内存使用情况
get_memory_usage_safe() {
    local total=0 used=0 free=0
    
    if [[ "$OS" == "FreeBSD" ]]; then
        # FreeBSD内存
        if command_exists sysctl; then
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
            
            [[ $page_size -gt 0 ]] && total=$(( (total_pages * page_size) / 1024 ))
            free=$(( ((free_pages + inactive_pages + cache_pages) * page_size) / 1024 ))
            used=$((total - free))
        fi
    else
        # Linux内存（优化版）
        if [[ -f /proc/meminfo ]]; then
            # 一次读取所有内存信息
            local meminfo_content
            meminfo_content=$(cat /proc/meminfo 2>/dev/null)
            
            # 使用awk一次性提取所有需要的值
            IFS=$'\n' read -d '' -r total free buffers cached sreclaimable <<< $(echo "$meminfo_content" | awk '
                /^MemTotal:/ {total=$2}
                /^MemFree:/ {free=$2}
                /^Buffers:/ {buffers=$2}
                /^Cached:/ {cached=$2}
                /^SReclaimable:/ {sreclaimable=$2}
                END {
                    print total;
                    print free;
                    print buffers;
                    print cached;
                    print sreclaimable
                }
            ')
            
            total=$(sanitize_integer "$total" "0")
            free=$(sanitize_integer "$free" "0")
            buffers=$(sanitize_integer "$buffers" "0")
            cached=$(sanitize_integer "$cached" "0")
            sreclaimable=$(sanitize_integer "$sreclaimable" "0")
            
            free=$((free + buffers + cached + sreclaimable))
            used=$((total - free))
        elif command_exists free; then
            local free_output
            free_output=$(free -k 2>/dev/null | grep "^Mem:")
            if [[ -n "$free_output" ]]; then
                local -a mem_info=($free_output)
                total=${mem_info[1]:-0}
                used=${mem_info[2]:-0}
                free=${mem_info[3]:-0}
            fi
        fi
    fi
    
    # 数据验证和修正
    total=$(sanitize_integer "$total" "0")
    used=$(sanitize_integer "$used" "0")
    free=$(sanitize_integer "$free" "0")
    
    # 确保数据一致性
    if [[ $total -gt 0 ]]; then
        [[ $used -lt 0 ]] && used=0
        [[ $free -lt 0 ]] && free=0
        [[ $used -gt $total ]] && used=$total && free=0
        [[ $free -gt $total ]] && free=$total && used=0
        
        # 重新计算确保一致性
        local sum=$((used + free))
        if [[ $sum -ne $total ]]; then
            # 优先保证total不变，调整used
            used=$((total - free))
        fi
    fi
    
    local usage_percent=0
    [[ $total -gt 0 ]] && usage_percent=$(echo "scale=1; $used * 100 / $total" | bc 2>/dev/null || echo "0")
    usage_percent=$(sanitize_number "$usage_percent" "0")
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# 安全获取磁盘使用情况
get_disk_usage_safe() {
    local total=0 used=0 free=0 usage_percent=0
    
    if command_exists df; then
        local df_output
        df_output=$(df -k / 2>/dev/null | tail -1)
        if [[ -n "$df_output" ]]; then
            local -a disk_info=($df_output)
            total=$(echo "${disk_info[1]:-0} / 1048576" | bc 2>/dev/null || echo "0")
            used=$(echo "${disk_info[2]:-0} / 1048576" | bc 2>/dev/null || echo "0")
            free=$(echo "${disk_info[3]:-0} / 1048576" | bc 2>/dev/null || echo "0")
            usage_percent=$(echo "${disk_info[4]:-0}" | tr -d '%')
        fi
    fi
    
    total=$(sanitize_number "$total" "0")
    used=$(sanitize_number "$used" "0")
    free=$(sanitize_number "$free" "0")
    usage_percent=$(sanitize_integer "$usage_percent" "0")
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# 安全获取网络使用情况
get_network_usage_safe() {
    local upload_speed=0 download_speed=0 total_upload=0 total_download=0
    local interface=""
    
    # 获取网络接口（优化版）
    if [[ "$OS" == "FreeBSD" ]]; then
        if command_exists route; then
            interface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
        fi
        [[ -z "$interface" ]] && interface=$(netstat -i -b 2>/dev/null | awk 'NR>1 && $1 !~ /^lo/{print $1; exit}')
    else
        # Linux接口检测
        if command_exists ip; then
            interface=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
        fi
        [[ -z "$interface" ]] && interface=$(awk '$2 == "00000000" {print $1; exit}' /proc/net/route 2>/dev/null)
        [[ -z "$interface" ]] && interface=$(awk -F: '$1 !~ /^(lo|docker|virbr)/ {print $1; exit}' /proc/net/dev 2>/dev/null)
    fi
    
    # 获取网络统计
    if [[ -n "$interface" ]]; then
        if [[ "$OS" == "FreeBSD" ]] && command_exists netstat; then
            local net_stats=$(netstat -i -b 2>/dev/null | grep "^$interface" | head -1)
            if [[ -n "$net_stats" ]]; then
                local -a stats=($net_stats)
                total_download=${stats[7]:-0}  # Ibytes
                total_upload=${stats[10]:-0}   # Obytes
            fi
        elif [[ -f "/proc/net/dev" ]]; then
            local net_line=$(grep "^ *$interface:" /proc/net/dev 2>/dev/null)
            if [[ -n "$net_line" ]]; then
                local -a stats=($net_line)
                total_download=${stats[1]:-0}
                total_upload=${stats[9]:-0}
            fi
        fi
    fi
    
    # 计算速度
    total_upload=$(sanitize_integer "$total_upload" "0")
    total_download=$(sanitize_integer "$total_download" "0")
    
    # 简单的速度计算（使用缓存）
    local cache_file="${TMPDIR:-/tmp}/net_speed_$(id -u)_${interface:-unknown}"
    if [[ -f "$cache_file" ]]; then
        local last_data
        last_data=$(cat "$cache_file" 2>/dev/null)
        local last_time=$(echo "$last_data" | cut -d' ' -f1)
        local last_rx=$(echo "$last_data" | cut -d' ' -f2)
        local last_tx=$(echo "$last_data" | cut -d' ' -f3)
        local current_time=$(date +%s)
        local time_diff=$((current_time - last_time))
        
        if [[ $time_diff -gt 0 ]]; then
            download_speed=$(( (total_download - last_rx) / time_diff ))
            upload_speed=$(( (total_upload - last_tx) / time_diff ))
            [[ $download_speed -lt 0 ]] && download_speed=0
            [[ $upload_speed -lt 0 ]] && upload_speed=0
        fi
    fi
    
    # 保存当前数据
    echo "$(date +%s) $total_download $total_upload" > "$cache_file" 2>/dev/null
    
    echo "{\"upload_speed\":$upload_speed,\"download_speed\":$download_speed,\"total_upload\":$total_upload,\"total_download\":$total_download}"
}

# 安全获取运行时间
get_uptime_safe() {
    local uptime_seconds=0
    
    if [[ "$OS" == "FreeBSD" ]]; then
        if command_exists sysctl; then
            local boot_time=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | tr -d ',')
            local current_time=$(date +%s)
            [[ -n "$boot_time" ]] && uptime_seconds=$((current_time - boot_time))
        fi
    elif [[ -f /proc/uptime ]]; then
        uptime_seconds=$(awk -F. '{print $1}' /proc/uptime 2>/dev/null)
    fi
    
    echo "$uptime_seconds"
}

# ==================== 服务管理函数 ====================

# 检查是否为root用户
is_root_user() {
    [[ $EUID -eq 0 ]]
}

# 检测systemd可用性
is_systemd_available() {
    command_exists systemctl && systemctl --version >/dev/null 2>&1
}

# 检测用户级systemd可用性
is_user_systemd_available() {
    if is_root_user; then
        is_systemd_available
    else
        is_systemd_available && [[ -n "${XDG_RUNTIME_DIR:-}" ]] && \
        systemctl --user --version >/dev/null 2>&1
    fi
}

# 验证PID有效性
validate_pid() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" != "$$" ]] && kill -0 "$pid" 2>/dev/null
}

# 查找监控进程（优化版）
find_monitor_processes() {
    local pids=""
    
    # 首先检查PID文件
    if [[ -f "$PID_FILE" ]]; then
        local file_pid
        file_pid=$(cat "$PID_FILE" 2>/dev/null)
        validate_pid "$file_pid" && pids="$file_pid"
    fi
    
    # 如果没有找到，搜索相关进程
    if [[ -z "$pids" ]] && [[ -f "${SERVICE_FILE:-}" ]]; then
        if [[ "$OS" == "FreeBSD" ]]; then
            pids=$(pgrep -f "$(basename "$SERVICE_FILE")" 2>/dev/null || \
                   ps axww | grep -v grep | grep "$SERVICE_FILE" | awk '{print $1}')
        else
            pids=$(pgrep -f "$(basename "$SERVICE_FILE")" 2>/dev/null || \
                   ps aux | grep -v grep | grep "$SERVICE_FILE" | awk '{print $2}')
        fi
    fi
    
    # 验证PID并过滤
    local valid_pids=""
    for pid in $pids; do
        if validate_pid "$pid"; then
            local cmdline
            cmdline=$(tr -d '\0' < "/proc/$pid/cmdline" 2>/dev/null || \
                     ps -p "$pid" -o command= 2>/dev/null || \
                     echo "")
            [[ "$cmdline" =~ (vps-monitor|cf-vps-monitor) ]] && valid_pids="$valid_pids $pid"
        fi
    done
    
    echo "$valid_pids" | xargs
}

# 检查监控服务是否运行
is_monitor_running() {
    local pids
    pids=$(find_monitor_processes)
    [[ -n "$pids" ]]
}

# ==================== 安装和配置函数 ====================

# 安装依赖
install_dependencies() {
    print_message "$BLUE" "检查系统依赖..."
    
    local required_deps=("curl" "bc")
    local optional_deps=("jq" "ifstat")
    local missing_required=()
    local missing_optional=()
    
    # 检查必需依赖
    for dep in "${required_deps[@]}"; do
        command_exists "$dep" || missing_required+=("$dep")
    done
    
    # 检查可选依赖
    for dep in "${optional_deps[@]}"; do
        command_exists "$dep" || missing_optional+=("$dep")
    done
    
    # 报告依赖状态
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        print_message "$YELLOW" "可选依赖未安装: ${missing_optional[*]}"
    fi
    
    if [[ ${#missing_required[@]} -eq 0 ]]; then
        print_message "$GREEN" "所有必需依赖已安装"
        return 0
    fi
    
    print_message "$YELLOW" "缺少必需依赖: ${missing_required[*]}"
    
    # 尝试安装
    detect_package_manager
    if [[ -n "$PKG_MANAGER" ]] && [[ -n "$PKG_INSTALL" ]]; then
        if is_root_user || command_exists sudo; then
            local install_cmd="sudo $PKG_INSTALL"
            [[ $EUID -eq 0 ]] && install_cmd="$PKG_INSTALL"
            
            print_message "$BLUE" "尝试安装依赖..."
            for dep in "${missing_required[@]}"; do
                print_message "$CYAN" "  安装 $dep..."
                $install_cmd "$dep" 2>/dev/null || true
            done
            
            # 验证安装结果
            local installed_all=true
            for dep in "${missing_required[@]}"; do
                command_exists "$dep" || installed_all=false
            done
            
            if $installed_all; then
                print_message "$GREEN" "✓ 依赖安装成功"
            else
                print_message "$YELLOW" "⚠ 部分依赖安装失败，请手动安装"
            fi
        else
            print_message "$YELLOW" "需要权限安装依赖，请手动执行:"
            print_message "$CYAN" "  sudo $PKG_INSTALL ${missing_required[*]}"
        fi
    else
        print_message "$YELLOW" "请手动安装依赖: ${missing_required[*]}"
    fi
    
    # 最终检查
    if ! command_exists curl; then
        print_message "$RED" "错误: curl未安装，请先安装curl"
        return 1
    fi
    
    return 0
}

# ==================== 网络通信函数 ====================

# 发送HTTP请求（带重试）
send_request() {
    local method="$1"
    local url="$2"
    local headers="$3"
    local data="$4"
    local max_retries="${5:-3}"
    local retry_delay="${6:-2}"
    
    local response="" http_code="" attempt=1
    
    while [[ $attempt -le $max_retries ]]; do
        local curl_opts=("-s" "-w" "%{http_code}" "-X" "$method" "$url")
        
        # 添加headers
        while IFS=':' read -r key value; do
            [[ -n "$key" ]] && curl_opts+=("-H" "${key}:${value}")
        done <<< "$headers"
        
        # 添加data（如果是POST）
        if [[ -n "$data" ]] && [[ "$method" == "POST" ]]; then
            curl_opts+=("-d" "$data")
        fi
        
        # 执行请求
        response=$(curl "${curl_opts[@]}" 2>/dev/null || echo "000")
        http_code="${response: -3}"
        
        # 成功响应
        [[ "$http_code" =~ ^[2] ]] && break
        
        # 可重试错误
        if [[ "$http_code" =~ ^(429|5[0-9][0-9]|000)$ ]] && [[ $attempt -lt $max_retries ]]; then
            log "请求失败 (HTTP $http_code)，${retry_delay}秒后重试..."
            sleep $retry_delay
            attempt=$((attempt + 1))
            continue
        fi
        
        # 不可重试错误
        break
    done
    
    echo "${response%???}|$http_code"
}

# 获取服务器配置
get_config() {
    load_config
    
    [[ -z "$WORKER_URL" || -z "$SERVER_ID" || -z "$API_KEY" ]] && return 1
    
    local url="${WORKER_URL}/api/config/${SERVER_ID}"
    local headers="X-API-Key: ${API_KEY}"
    local result
    
    result=$(send_request "GET" "$url" "$headers" "" 3 2)
    local response="${result%|*}"
    local http_code="${result##*|}"
    
    if [[ "$http_code" == "200" ]] && [[ -n "$response" ]]; then
        # 解析新间隔（不使用jq以提高兼容性）
        local new_interval
        new_interval=$(echo "$response" | sed -n 's/.*"interval":\([0-9]\+\).*/\1/p')
        new_interval=$(sanitize_integer "$new_interval")
        
        if [[ -n "$new_interval" ]] && [[ "$new_interval" -gt 0 ]] && [[ "$new_interval" -ne "$INTERVAL" ]]; then
            INTERVAL="$new_interval"
            save_config
            log "配置更新: 上报间隔调整为 ${INTERVAL}秒"
        fi
        
        # 缓存配置
        mkdir -p "$CACHE_DIR"
        echo "$response" > "$CONFIG_CACHE_FILE"
        
        return 0
    fi
    
    log "配置获取失败 (HTTP $http_code)"
    return 1
}

# 上报监控数据
report_metrics() {
    load_config
    
    [[ -z "$WORKER_URL" || -z "$SERVER_ID" || -z "$API_KEY" ]] && return 1
    
    # 收集所有指标
    local timestamp=$(date +%s)
    local cpu_info=$(get_system_resource "cpu")
    local memory_info=$(get_system_resource "memory")
    local disk_info=$(get_system_resource "disk")
    local network_info=$(get_system_resource "network")
    local uptime=$(get_system_resource "uptime")
    
    # 构建JSON数据
    local json_data="{\"timestamp\":$timestamp,\"cpu\":$cpu_info,\"memory\":$memory_info,\"disk\":$disk_info,\"network\":$network_info,\"uptime\":$uptime}"
    
    # 发送请求
    local url="${WORKER_URL}/api/report/${SERVER_ID}"
    local headers=$'Content-Type: application/json\nX-API-Key: '"${API_KEY}"
    local result
    
    result=$(send_request "POST" "$url" "$headers" "$json_data" 3 2)
    local response="${result%|*}"
    local http_code="${result##*|}"
    
    if [[ "$http_code" == "200" ]]; then
        log "数据上报成功"
        
        # 检查是否需要更新间隔
        local new_interval
        new_interval=$(echo "$response" | sed -n 's/.*"interval":\([0-9]\+\).*/\1/p')
        new_interval=$(sanitize_integer "$new_interval")
        
        if [[ -n "$new_interval" ]] && [[ "$new_interval" -gt 0 ]] && [[ "$new_interval" -ne "$INTERVAL" ]]; then
            INTERVAL="$new_interval"
            save_config
            log "服务器调整上报间隔为 ${INTERVAL}秒"
            touch "$SCRIPT_DIR/.restart_needed"
        fi
        
        return 0
    else
        log "数据上报失败 (HTTP $http_code)"
        return 1
    fi
}

# ==================== 服务脚本创建 ====================

# 创建监控服务脚本
create_service_script() {
    local main_script_path
    main_script_path=$(realpath "$0" 2>/dev/null || echo "$0")
    
    cat > "$SERVICE_FILE" << 'EOF'
#!/bin/bash
# cf-vps-monitor服务脚本

set -euo pipefail

# 配置路径
readonly SCRIPT_DIR="__SCRIPT_DIR__"
readonly CONFIG_FILE="$SCRIPT_DIR/config/config"
readonly LOG_FILE="$SCRIPT_DIR/logs/monitor.log"
readonly PID_FILE="$SCRIPT_DIR/run/monitor.pid"
readonly CACHE_DIR="$SCRIPT_DIR/cache"

# 服务模式标志
export SERVICE_MODE=true

# 确保目录存在
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")" "$CACHE_DIR"

# 日志函数
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE"
}

# 加载配置
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        log "错误: 配置文件不存在"
        exit 1
    fi
}

# 主循环
main() {
    log "监控服务启动 (PID: $$)"
    echo $$ > "$PID_FILE"
    
    # 信号处理
    trap 'log "收到终止信号，正在停止..."; rm -f "$PID_FILE"; exit 0' TERM INT
    
    # 加载配置
    load_config
    
    local config_check_counter=0
    local config_check_interval=10
    
    while true; do
        # 定期检查配置更新
        if [[ $config_check_counter -ge $config_check_interval ]]; then
            # 这里可以添加配置检查逻辑
            config_check_counter=0
        else
            config_check_counter=$((config_check_counter + 1))
        fi
        
        # 这里添加实际的数据上报逻辑
        # 简化示例：只记录心跳
        log "服务运行中... (间隔: ${INTERVAL}s)"
        
        # 检查是否需要重启
        if [[ -f "$SCRIPT_DIR/.restart_needed" ]]; then
            log "检测到配置变更，重新加载配置..."
            rm -f "$SCRIPT_DIR/.restart_needed"
            load_config
            log "配置已重新加载"
        fi
        
        sleep "$INTERVAL"
    done
}

# 启动
main
EOF
    
    # 替换占位符
    sed -i "s|__SCRIPT_DIR__|$SCRIPT_DIR|g" "$SERVICE_FILE"
    
    chmod +x "$SERVICE_FILE"
    print_message "$GREEN" "服务脚本创建完成"
}

# ==================== 服务管理 ====================

# 启动服务
start_service() {
    print_message "$BLUE" "启动监控服务..."
    
    # 检查是否已在运行
    if is_monitor_running; then
        print_message "$YELLOW" "监控服务已在运行"
        return 0
    fi
    
    # 确保服务脚本存在
    [[ -f "$SERVICE_FILE" ]] || create_service_script
    
    # 清理旧的PID文件
    rm -f "$PID_FILE" 2>/dev/null || true
    
    # 启动服务
    if command_exists nohup; then
        nohup "$SERVICE_FILE" >> "$LOG_FILE" 2>&1 &
    else
        "$SERVICE_FILE" >> "$LOG_FILE" 2>&1 &
    fi
    
    local pid=$!
    echo "$pid" > "$PID_FILE"
    
    # 验证启动
    sleep 1
    if validate_pid "$pid"; then
        print_message "$GREEN" "✓ 监控服务已启动 (PID: $pid)"
        return 0
    else
        print_message "$RED" "✗ 监控服务启动失败"
        rm -f "$PID_FILE"
        return 1
    fi
}

# 停止服务
stop_service() {
    print_message "$BLUE" "停止监控服务..."
    
    local pids
    pids=$(find_monitor_processes)
    
    if [[ -z "$pids" ]]; then
        print_message "$YELLOW" "没有运行中的监控服务"
        return 0
    fi
    
    local stopped=0
    for pid in $pids; do
        print_message "$CYAN" "停止进程: $pid"
        
        # 先尝试温和停止
        kill "$pid" 2>/dev/null && sleep 2
        
        # 如果还在运行，强制停止
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null && sleep 1
        fi
        
        # 验证已停止
        if ! kill -0 "$pid" 2>/dev/null; then
            stopped=$((stopped + 1))
        fi
    done
    
    # 清理
    rm -f "$PID_FILE" 2>/dev/null || true
    
    if [[ $stopped -gt 0 ]]; then
        print_message "$GREEN" "✓ 已停止 $stopped 个监控进程"
    else
        print_message "$RED" "✗ 停止服务失败"
        return 1
    fi
}

# 检查服务状态
check_service_status() {
    print_message "$BLUE" "监控服务状态检查"
    echo
    
    # 进程状态
    local pids
    pids=$(find_monitor_processes)
    
    if [[ -n "$pids" ]]; then
        print_message "$GREEN" "✓ 监控服务正在运行"
        echo "  进程PID: $pids"
        
        # 显示进程信息
        for pid in $pids; do
            local cpu_mem
            cpu_mem=$(ps -p "$pid" -o %cpu,%mem,etime,cmd --no-headers 2>/dev/null || echo "未知")
            echo "  进程 $pid: $cpu_mem"
        done
    else
        print_message "$RED" "✗ 监控服务未运行"
    fi
    
    # 配置文件状态
    echo
    print_message "$BLUE" "配置状态:"
    if [[ -f "$CONFIG_FILE" ]]; then
        load_config
        echo "  Worker URL: ${WORKER_URL:0:50}..."
        echo "  Server ID: $SERVER_ID"
        echo "  API Key: ${API_KEY:0:8}..."
        echo "  上报间隔: ${INTERVAL}秒"
    else
        print_message "$YELLOW" "✗ 配置文件不存在"
    fi
    
    # 日志状态
    echo
    print_message "$BLUE" "日志状态:"
    if [[ -f "$LOG_FILE" ]]; then
        local log_size log_lines
        log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1 || echo "未知")
        log_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
        echo "  文件: $LOG_FILE"
        echo "  大小: $log_size"
        echo "  行数: $log_lines"
        
        # 显示最后几行日志
        echo "  最后日志:"
        tail -n 3 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' || true
    else
        print_message "$YELLOW" "✗ 日志文件不存在"
    fi
}

# ==================== 主安装函数 ====================

# 配置监控参数
configure_monitor() {
    print_message "$BLUE" "配置监控参数"
    echo
    
    load_config
    
    # Server ID
    echo -n "请输入Server ID"
    [[ -n "$SERVER_ID" ]] && echo -n " (当前: $SERVER_ID)"
    echo -n ": "
    read -r input
    [[ -n "$input" ]] && SERVER_ID="$input"
    
    # API Key
    echo -n "请输入API Key"
    [[ -n "$API_KEY" ]] && echo -n " (当前: ${API_KEY:0:8}...)"
    echo -n ": "
    read -r input
    [[ -n "$input" ]] && API_KEY="$input"
    
    # Worker URL
    echo -n "请输入Worker URL"
    [[ -n "$WORKER_URL" ]] && echo -n " (当前: $WORKER_URL)"
    echo -n ": "
    read -r input
    [[ -n "$input" ]] && WORKER_URL="$input"
    
    # 验证配置
    if [[ -z "$SERVER_ID" || -z "$API_KEY" || -z "$WORKER_URL" ]]; then
        print_message "$RED" "错误: 所有配置项都必须填写"
        return 1
    fi
    
    # 设置默认间隔
    INTERVAL="${INTERVAL:-$DEFAULT_INTERVAL}"
    
    # 保存配置
    save_config
    
    # 测试连接
    echo
    echo -n "是否测试连接? (y/N): "
    read -r test_choice
    if [[ "$test_choice" =~ ^[Yy]$ ]]; then
        if report_metrics; then
            print_message "$GREEN" "✓ 连接测试成功"
        else
            print_message "$YELLOW" "⚠ 连接测试失败，请检查配置"
        fi
    fi
    
    print_message "$GREEN" "✓ 配置完成"
}

# 安装监控服务
install_monitor() {
    print_message "$BLUE" "开始安装VPS监控服务..."
    echo
    
    # 检测系统
    detect_system
    
    # 安装依赖
    install_dependencies || error_exit "依赖安装失败"
    
    # 创建目录结构
    create_directories
    
    # 配置参数
    configure_monitor || error_exit "配置失败"
    
    # 创建服务脚本
    create_service_script
    
    # 启动服务
    if start_service; then
        print_message "$GREEN" "✓ VPS监控服务安装成功"
        echo
        print_message "$CYAN" "安装信息:"
        echo "  安装目录: $SCRIPT_DIR"
        echo "  配置文件: $CONFIG_FILE"
        echo "  日志文件: $LOG_FILE"
        echo "  服务脚本: $SERVICE_FILE"
        echo
        print_message "$YELLOW" "提示: 使用 '$0 status' 检查服务状态"
        print_message "$YELLOW" "提示: 使用 '$0 logs' 查看运行日志"
    else
        error_exit "服务启动失败"
    fi
}

# 卸载监控服务
uninstall_monitor() {
    print_message "$YELLOW" "警告: 这将卸载VPS监控服务"
    echo -n "确认卸载? (y/N): "
    read -r confirm
    
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    
    print_message "$BLUE" "开始卸载..."
    
    # 停止服务
    stop_service
    
    # 备份当前脚本（如果它在安装目录内）
    local script_path
    script_path=$(realpath "$0" 2>/dev/null || echo "$0")
    if [[ "$script_path" == "$SCRIPT_DIR/"* ]]; then
        local backup="/tmp/cf-vps-monitor-backup-$(date +%s).sh"
        cp "$script_path" "$backup"
        print_message "$CYAN" "脚本已备份到: $backup"
    fi
    
    # 删除安装目录
    if [[ -d "$SCRIPT_DIR" ]]; then
        rm -rf "$SCRIPT_DIR"
        print_message "$GREEN" "✓ 监控服务已卸载"
    else
        print_message "$YELLOW" "安装目录不存在"
    fi
}

# 查看日志
view_logs() {
    [[ -f "$LOG_FILE" ]] || {
        print_message "$YELLOW" "日志文件不存在"
        return 1
    }
    
    print_message "$BLUE" "显示日志 (Ctrl+C退出):"
    echo "----------------------------------------"
    tail -f "$LOG_FILE"
}

# ==================== 主函数 ====================

# 显示帮助
show_help() {
    cat << EOF
VPS监控脚本 v$SCRIPT_VERSION

用法: $0 [命令]

命令:
  install     安装监控服务
  uninstall   卸载监控服务
  start       启动监控服务
  stop        停止监控服务
  restart     重启监控服务
  status      查看服务状态
  logs        查看运行日志
  config      配置监控参数
  test        测试连接
  help        显示帮助信息

示例:
  $0 install      # 安装服务
  $0 status       # 查看状态
  $0 logs         # 查看日志

一键安装参数:
  -i, --install           一键安装
  -s, --server-id ID      服务器ID
  -k, --api-key KEY       API密钥
  -u, --worker-url URL    Worker地址

一键安装示例:
  $0 -i -s server123 -k abc123 -u https://worker.example.com
EOF
}

# 主函数
main() {
    # 处理命令行参数
    local command=""
    local oneclick_mode=false
    local server_id="" api_key="" worker_url=""
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--install)
                oneclick_mode=true
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
                command="$1"
                shift
                ;;
        esac
    done
    
    # 一键安装模式
    if [[ "$oneclick_mode" == "true" ]]; then
        [[ -z "$server_id" || -z "$api_key" || -z "$worker_url" ]] && {
            print_message "$RED" "错误: 一键安装需要所有参数"
            show_help
            exit 1
        }
        
        # 设置配置
        WORKER_URL="$worker_url"
        SERVER_ID="$server_id"
        API_KEY="$api_key"
        INTERVAL="$DEFAULT_INTERVAL"
        
        # 执行安装
        install_monitor
        exit $?
    fi
    
    # 常规命令模式
    case "${command}" in
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
            report_metrics && print_message "$GREEN" "✓ 连接测试成功" || \
            print_message "$RED" "✗ 连接测试失败"
            ;;
        menu|"")
            # 显示简单菜单
            print_message "$CYAN" "VPS监控服务管理"
            echo
            echo "1) 安装服务"
            echo "2) 启动服务"
            echo "3) 停止服务"
            echo "4) 查看状态"
            echo "5) 查看日志"
            echo "6) 配置参数"
            echo "7) 卸载服务"
            echo "8) 退出"
            echo
            echo -n "请选择 (1-8): "
            read -r choice
            
            case "$choice" in
                1) install_monitor ;;
                2) start_service ;;
                3) stop_service ;;
                4) check_service_status ;;
                5) view_logs ;;
                6) configure_monitor ;;
                7) uninstall_monitor ;;
                8) exit 0 ;;
                *) print_message "$RED" "无效选择" ;;
            esac
            ;;
        help)
            show_help
            ;;
        *)
            print_message "$RED" "未知命令: $command"
            show_help
            exit 1
            ;;
    esac
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
