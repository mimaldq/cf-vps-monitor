#!/bin/bash

# cf-vps-monitor - Cloudflare Worker VPS监控脚本
# 版本: 1.1.0
# 支持所有常见Linux系统，无需root权限

set -euo pipefail

# ==================== 常量定义 ====================
declare -r OS=$(uname -s)
declare -r SCRIPT_DIR="$HOME/.cf-vps-monitor"
declare -r CONFIG_FILE="$SCRIPT_DIR/config/config"
declare -r LOG_FILE="$SCRIPT_DIR/logs/monitor.log"
declare -r PID_FILE="$SCRIPT_DIR/run/monitor.pid"
declare -r SERVICE_FILE="$SCRIPT_DIR/bin/vps-monitor-service.sh"
declare -r INSTALL_MANIFEST="$SCRIPT_DIR/system/install.manifest"
declare -r CACHE_DIR="$SCRIPT_DIR/cache"
declare -r TMPDIR="$SCRIPT_DIR/tmp"

# 颜色定义
declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r PURPLE='\033[0;35m'
declare -r CYAN='\033[0;36m'
declare -r NC='\033[0m'

# 默认配置
declare -r DEFAULT_INTERVAL=10
declare -r DEFAULT_WORKER_URL=""
declare -r DEFAULT_SERVER_ID=""
declare -r DEFAULT_API_KEY=""

# 全局变量
declare WORKER_URL="$DEFAULT_WORKER_URL"
declare SERVER_ID="$DEFAULT_SERVER_ID"
declare API_KEY="$DEFAULT_API_KEY"
declare INTERVAL="$DEFAULT_INTERVAL"

# ==================== 工具函数 ====================

# 打印带颜色的消息
print_message() {
    echo -e "${1}${2}${NC}"
}

# 日志函数
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOG_FILE"
    
    [[ "${SERVICE_MODE:-false}" != "true" ]] && echo "[$timestamp] $1"
}

# 错误处理
error_exit() {
    print_message "$RED" "错误: $1"
    log "ERROR: $1"
    exit 1
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 安全的整数验证
sanitize_integer() {
    local value="${1//[^0-9]/}"
    [[ -n "$value" && "$value" =~ ^[0-9]+$ ]] && echo "$value" || echo "${2:-0}"
}

# 安全的数字验证
sanitize_number() {
    local value="${1//[^0-9.]/}"
    [[ "$value" =~ ^[0-9]*\.?[0-9]+$ ]] && echo "$value" || echo "${2:-0}"
}

# 清理JSON字符串
clean_json_string() {
    tr -d '\000-\037\177-\377' <<< "$1"
}

# ==================== 系统检测函数 ====================

# 检测是否为root用户
is_root_user() {
    [[ $EUID -eq 0 ]]
}

# 检测系统类型
detect_system() {
    local system_info=$(uname -srm)
    IFS=' ' read -r OS ARCH KERNEL_VERSION <<< "$system_info"
    
    case "$OS" in
        FreeBSD)
            VER=$(echo "$KERNEL_VERSION" | cut -d'-' -f1)
            DISTRO_ID="freebsd"
            DISTRO_NAME="FreeBSD"
            ;;
        Darwin)
            VER=$(sw_vers -productVersion 2>/dev/null || echo "$KERNEL_VERSION")
            DISTRO_ID="macos"
            DISTRO_NAME="macOS"
            ;;
        *)
            if [[ -f /etc/os-release ]]; then
                local os_info=$(cat /etc/os-release)
                DISTRO_ID=$(grep '^ID=' <<< "$os_info" | cut -d= -f2 | tr -d '"')
                VER=$(grep '^VERSION_ID=' <<< "$os_info" | cut -d= -f2 | tr -d '"')
                DISTRO_NAME=$(grep '^NAME=' <<< "$os_info" | cut -d= -f2 | tr -d '"')
            else
                DISTRO_ID="linux"
                VER="unknown"
                DISTRO_NAME="Linux"
            fi
            ;;
    esac
    
    print_message "$GREEN" "检测到系统: $DISTRO_NAME $VER"
}

# ==================== 目录管理函数 ====================

# 创建目录结构
create_directories() {
    print_message "$BLUE" "创建集中式目录结构..."
    
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
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir" 2>/dev/null || true
    done
    
    touch "$INSTALL_MANIFEST"
    print_message "$GREEN" "✓ 目录结构创建完成"
}

# ==================== 配置管理函数 ====================

# 加载配置
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        WORKER_URL="$DEFAULT_WORKER_URL"
        SERVER_ID="$DEFAULT_SERVER_ID"
        API_KEY="$DEFAULT_API_KEY"
        INTERVAL="$DEFAULT_INTERVAL"
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

# ==================== 系统监控函数 ====================

# 获取CPU使用率
get_cpu_usage() {
    local cpu_usage=0 load_avg="0,0,0"
    
    if [[ "$OS" == "FreeBSD" ]]; then
        # FreeBSD CPU使用率
        if command_exists sysctl; then
            local cpu_idle cpu_total
            cpu_idle=$(sysctl -n kern.cp_time 2>/dev/null | awk '{print $5}')
            cpu_total=$(sysctl -n kern.cp_time 2>/dev/null | awk '{sum=0; for(i=1;i<=NF;i++) sum+=$i; print sum}')
            
            cpu_idle=$(sanitize_integer "$cpu_idle")
            cpu_total=$(sanitize_integer "$cpu_total")
            
            if [[ $cpu_total -gt 0 ]]; then
                cpu_usage=$(echo "scale=1; 100 - ($cpu_idle * 100 / $cpu_total)" | bc 2>/dev/null || echo "0")
            fi
        fi
        
        # FreeBSD负载
        if command_exists sysctl; then
            load_avg=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2","$3","$4}')
        fi
    else
        # Linux CPU使用率
        if [[ -f /proc/stat ]]; then
            local cpu_line=$(head -n1 /proc/stat)
            local cpu_times=($cpu_line)
            
            if [[ ${#cpu_times[@]} -ge 8 ]]; then
                local idle=${cpu_times[4]}
                local iowait=${cpu_times[5]:-0}
                local total=0
                
                for i in {1..7}; do
                    [[ -n "${cpu_times[i]}" && "${cpu_times[i]}" =~ ^[0-9]+$ ]] && total=$((total + cpu_times[i]))
                done
                
                [[ $total -gt 0 ]] && cpu_usage=$(echo "scale=1; 100 - (($idle + $iowait) * 100 / $total)" | bc 2>/dev/null || echo "0")
            fi
        fi
        
        # Linux负载
        if [[ -f /proc/loadavg ]]; then
            load_avg=$(awk '{print $1","$2","$3}' /proc/loadavg 2>/dev/null || echo "0,0,0")
        fi
    fi
    
    cpu_usage=$(sanitize_number "$cpu_usage")
    echo "{\"usage_percent\":$cpu_usage,\"load_avg\":[$load_avg]}"
}

# 获取内存使用情况
get_memory_usage() {
    local total=0 used=0 free=0 usage_percent=0
    
    if [[ "$OS" == "FreeBSD" ]]; then
        # FreeBSD内存
        if command_exists sysctl; then
            local page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo "4096")
            local total_pages=$(sysctl -n vm.stats.vm.v_page_count 2>/dev/null || echo "0")
            local free_pages=$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null || echo "0")
            local inactive_pages=$(sysctl -n vm.stats.vm.v_inactive_count 2>/dev/null || echo "0")
            local cache_pages=$(sysctl -n vm.stats.vm.v_cache_count 2>/dev/null || echo "0")
            
            page_size=$(sanitize_integer "$page_size" "4096")
            total_pages=$(sanitize_integer "$total_pages")
            free_pages=$(sanitize_integer "$free_pages")
            inactive_pages=$(sanitize_integer "$inactive_pages")
            cache_pages=$(sanitize_integer "$cache_pages")
            
            if [[ $page_size -gt 0 && $total_pages -gt 0 ]]; then
                total=$(( (total_pages * page_size) / 1024 ))
                free=$(( ((free_pages + inactive_pages + cache_pages) * page_size) / 1024 ))
                used=$((total - free))
                [[ $used -lt 0 ]] && used=0
                [[ $free -lt 0 ]] && free=0
            fi
        fi
    else
        # Linux内存
        if command_exists free; then
            local mem_info=$(free -k 2>/dev/null | grep "^Mem:")
            if [[ -n "$mem_info" ]]; then
                total=$(awk '{print $2}' <<< "$mem_info")
                local available=$(awk '{print $7}' <<< "$mem_info" 2>/dev/null || echo "")
                
                if [[ "$available" =~ ^[0-9]+$ ]]; then
                    free=$available
                    used=$((total - free))
                else
                    local mem_free=$(awk '{print $4}' <<< "$mem_info" 2>/dev/null || echo "0")
                    local buff_cache=$(awk '{print $6}' <<< "$mem_info" 2>/dev/null || echo "0")
                    
                    if [[ "$mem_free" =~ ^[0-9]+$ ]] && [[ "$buff_cache" =~ ^[0-9]+$ ]]; then
                        free=$((mem_free + buff_cache))
                        used=$((total - free))
                    fi
                fi
            fi
        fi
    fi
    
    total=$(sanitize_integer "$total")
    used=$(sanitize_integer "$used")
    free=$(sanitize_integer "$free")
    
    [[ $total -gt 0 ]] && usage_percent=$(echo "scale=1; $used * 100 / $total" | bc 2>/dev/null || echo "0")
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# ==================== 服务管理函数 ====================

# 验证PID有效性
validate_pid() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" != "$$" ]] && kill -0 "$pid" 2>/dev/null
}

# 查找监控进程
find_monitor_processes() {
    local pids=""
    
    # 从PID文件获取
    [[ -f "$PID_FILE" ]] && {
        local file_pid=$(< "$PID_FILE")
        validate_pid "$file_pid" && pids="$file_pid"
    }
    
    # 从进程查找
    [[ -z "$pids" && -f "$SERVICE_FILE" ]] && {
        if [[ "$OS" == "FreeBSD" ]]; then
            pids=$(ps axww | grep -F "$SERVICE_FILE" | grep -v grep | awk '{print $1}')
        else
            pids=$(ps aux | grep -F "$SERVICE_FILE" | grep -v grep | awk '{print $2}')
        fi
    }
    
    # 验证所有PID
    local valid_pids=""
    for pid in $pids; do
        validate_pid "$pid" && {
            local cmd=$(ps -p "$pid" -o cmd= 2>/dev/null || echo "unknown")
            [[ "$cmd" =~ (vps-monitor-service|cf-vps-monitor) ]] && valid_pids="$valid_pids $pid"
        }
    done
    
    echo "${valid_pids## }"
}

# 检查服务是否运行
is_monitor_running() {
    [[ -n $(find_monitor_processes) ]]
}

# 启动服务
start_service() {
    print_message "$BLUE" "启动监控服务..."
    
    if is_monitor_running; then
        local pids=$(find_monitor_processes)
        local first_pid=$(awk '{print $1}' <<< "$pids")
        print_message "$YELLOW" "监控服务已在运行 (PID: $first_pid)"
        return 0
    fi
    
    rm -f "$PID_FILE" 2>/dev/null || true
    
    if [[ ! -f "$SERVICE_FILE" ]]; then
        print_message "$RED" "✗ 服务脚本不存在"
        return 1
    fi
    
    chmod +x "$SERVICE_FILE" 2>/dev/null || true
    
    if command_exists nohup; then
        nohup "$SERVICE_FILE" >> "$LOG_FILE" 2>&1 &
    else
        "$SERVICE_FILE" >> "$LOG_FILE" 2>&1 &
    fi
    
    local pid=$!
    echo "$pid" > "$PID_FILE"
    
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
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
    
    local pids=$(find_monitor_processes)
    if [[ -n "$pids" ]]; then
        local count=0
        for pid in $pids; do
            kill "$pid" 2>/dev/null && sleep 2 && {
                if ! kill -0 "$pid" 2>/dev/null; then
                    ((count++))
                else
                    kill -9 "$pid" 2>/dev/null && sleep 1 && ((count++))
                fi
            } || true
        done
        print_message "$GREEN" "✓ 已停止 $count 个监控进程"
    fi
    
    rm -f "$PID_FILE" 2>/dev/null || true
    print_message "$GREEN" "✓ 监控服务已停止"
}

# ==================== 主函数 ====================

# 配置监控参数
configure_monitor() {
    print_message "$BLUE" "配置监控参数"
    echo
    
    load_config
    
    echo -n "请输入Server ID"
    [[ -n "$SERVER_ID" ]] && echo -n " (当前: $SERVER_ID)"
    echo -n ": "
    read -r input
    [[ -n "$input" ]] && SERVER_ID="$input"
    
    echo -n "请输入API Key"
    [[ -n "$API_KEY" ]] && echo -n " (当前: ${API_KEY:0:8}...)"
    echo -n ": "
    read -r input
    [[ -n "$input" ]] && API_KEY="$input"
    
    echo -n "请输入Worker URL"
    [[ -n "$WORKER_URL" ]] && echo -n " (当前: $WORKER_URL)"
    echo -n ": "
    read -r input
    [[ -n "$input" ]] && WORKER_URL="$input"
    
    [[ -z "$INTERVAL" ]] && INTERVAL="10"
    
    save_config
    print_message "$GREEN" "配置保存成功"
}

# 安装监控服务
install_monitor() {
    print_message "$BLUE" "开始安装VPS监控服务..."
    
    detect_system
    create_directories
    
    if ! configure_monitor; then
        error_exit "配置失败，安装中止"
    fi
    
    create_service_script
    start_service
    
    print_message "$GREEN" "✓ VPS监控服务安装并启动成功"
}

# 显示帮助
show_help() {
    cat << EOF
VPS监控脚本 v1.1.0

用法: $0 [选项]

基本选项:
  install     安装监控服务
  uninstall   卸载监控服务
  start       启动监控服务
  stop        停止监控服务
  restart     重启监控服务
  status      查看服务状态
  config      配置监控参数
  help        显示此帮助信息

一键安装参数:
  -i, --install           一键安装模式
  -s, --server-id ID      服务器ID
  -k, --api-key KEY       API密钥
  -u, --worker-url URL    Worker地址

示例:
  $0 install              # 交互式安装
  $0 status               # 查看服务状态
  $0 logs                 # 查看日志

注意: 上报间隔会自动从服务器获取，无需手动设置
EOF
}

# 主函数
main() {
    [[ $# -eq 0 ]] && {
        show_help
        exit 0
    }
    
    case "$1" in
        install)
            install_monitor
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
            if is_monitor_running; then
                local pids=$(find_monitor_processes)
                print_message "$GREEN" "✓ 监控服务正在运行"
                [[ -n "$pids" ]] && print_message "$CYAN" "  进程PID: $pids"
            else
                print_message "$RED" "✗ 监控服务未运行"
            fi
            ;;
        config)
            configure_monitor
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_message "$RED" "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
