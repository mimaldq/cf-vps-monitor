#!/bin/bash

# cf-vps-monitor - Cloudflare Worker VPS监控脚本
# 版本: 1.3.0 (一键安装优化版)
# 支持一键安装: wget https://raw.githubusercontent.com/mimaldq/cf-vps-monitor/main/cf-vps-monitor.sh -O cf-vps-monitor.sh && chmod +x cf-vps-monitor.sh && ./cf-vps-monitor.sh -i -k API_KEY -s SERVER_ID -u WORKER_URL

set -euo pipefail

# ==================== 全局变量和配置 ====================
readonly SCRIPT_VERSION="1.3.0"
readonly SCRIPT_NAME="cf-vps-monitor"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# 文件路径
readonly SCRIPT_DIR="$HOME/.cf-vps-monitor"
readonly CONFIG_FILE="$SCRIPT_DIR/config/config"
readonly LOG_FILE="$SCRIPT_DIR/logs/monitor.log"
readonly PID_FILE="$SCRIPT_DIR/run/monitor.pid"
readonly SERVICE_FILE="$SCRIPT_DIR/bin/vps-monitor-service.sh"

# ==================== 工具函数 ====================

print_message() {
    local color="$1"
    local message="$2"
    printf "%b%s%b\n" "${color}" "${message}" "${NC}"
}

log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE"
    [[ "${SERVICE_MODE:-false}" != "true" ]] && echo "[$timestamp] $message"
}

error_exit() {
    local message="$1"
    print_message "$RED" "错误: $message" >&2
    log "ERROR: $message"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

sanitize_string() {
    echo "$1" | tr -d '\r\n\t' | sed 's/[^[:print:]]//g'
}

# ==================== 一键安装函数 ====================

# 解析命令行参数
parse_arguments() {
    local server_id=""
    local api_key=""
    local worker_url=""
    local install_mode=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
                # 如果不是我们的参数，可能是其他命令
                echo "$1"
                shift
                ;;
        esac
    done
    
    # 如果是一键安装模式，直接执行安装
    if [[ "$install_mode" == "true" ]]; then
        if [[ -z "$server_id" || -z "$api_key" || -z "$worker_url" ]]; then
            error_exit "一键安装需要所有参数: -s SERVER_ID -k API_KEY -u WORKER_URL"
        fi
        one_click_install "$server_id" "$api_key" "$worker_url"
        exit $?
    fi
    
    # 返回剩余的参数作为命令
    echo "$@"
}

# 一键安装函数
one_click_install() {
    local server_id="$1"
    local api_key="$2"
    local worker_url="$3"
    
    print_message "$CYAN" "========================================"
    print_message "$CYAN" "       VPS监控服务一键安装"
    print_message "$CYAN" "========================================"
    echo
    
    # 显示安装参数（隐藏部分API密钥）
    local masked_api_key="${api_key:0:8}****************${api_key: -8}"
    print_message "$BLUE" "安装配置:"
    echo "  Server ID: $server_id"
    echo "  API Key: $masked_api_key"
    echo "  Worker URL: $worker_url"
    echo
    
    # 检测系统
    detect_system
    
    # 创建目录
    create_directories
    
    # 保存配置
    save_config_direct "$server_id" "$api_key" "$worker_url"
    
    # 安装依赖
    install_dependencies
    
    # 创建服务脚本
    create_service_script
    
    # 启动服务
    if start_service; then
        print_message "$GREEN" "✓ VPS监控服务一键安装成功！"
        echo
        print_message "$CYAN" "服务信息:"
        echo "  安装目录: $SCRIPT_DIR"
        echo "  配置文件: $CONFIG_FILE"
        echo "  日志文件: $LOG_FILE"
        echo "  服务状态: 运行中"
        echo
        print_message "$YELLOW" "管理命令:"
        echo "  查看状态: $0 status"
        echo "  查看日志: $0 logs"
        echo "  停止服务: $0 stop"
        echo "  重启服务: $0 restart"
        echo
        print_message "$GREEN" "✓ 监控服务已启动并开始上报数据"
    else
        error_exit "服务启动失败"
    fi
}

# 直接保存配置
save_config_direct() {
    local server_id="$1"
    local api_key="$2"
    local worker_url="$3"
    
    print_message "$BLUE" "保存配置..."
    
    # 清理输入
    server_id=$(sanitize_string "$server_id")
    api_key=$(sanitize_string "$api_key")
    worker_url=$(sanitize_string "$worker_url")
    
    # 验证输入
    [[ -z "$server_id" ]] && error_exit "Server ID不能为空"
    [[ -z "$api_key" ]] && error_exit "API Key不能为空"
    [[ -z "$worker_url" ]] && error_exit "Worker URL不能为空"
    
    # 创建配置文件
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOF
# VPS监控配置文件
WORKER_URL="$worker_url"
SERVER_ID="$server_id"
API_KEY="$api_key"
INTERVAL="10"
EOF
    
    chmod 600 "$CONFIG_FILE"
    print_message "$GREEN" "✓ 配置保存成功"
}

# ==================== 系统检测函数 ====================

detect_system() {
    print_message "$BLUE" "检测系统环境..."
    
    local os_name=$(uname -s)
    local os_version=""
    
    case "$os_name" in
        Linux)
            if [[ -f /etc/os-release ]]; then
                . /etc/os-release
                os_version="$NAME $VERSION"
            else
                os_version="Linux (未知版本)"
            fi
            ;;
        Darwin)
            os_version="macOS $(sw_vers -productVersion)"
            ;;
        FreeBSD)
            os_version="FreeBSD $(uname -r)"
            ;;
        *)
            os_version="$os_name"
            ;;
    esac
    
    print_message "$GREEN" "✓ 系统: $os_version"
    print_message "$GREEN" "✓ 架构: $(uname -m)"
    
    # 设置全局变量
    export OS="$os_name"
}

# ==================== 依赖安装函数 ====================

install_dependencies() {
    print_message "$BLUE" "检查系统依赖..."
    
    local missing_deps=()
    
    # 检查必需依赖
    if ! command_exists curl; then
        missing_deps+=("curl")
    fi
    
    if ! command_exists bc; then
        missing_deps+=("bc")
    fi
    
    # 如果没有缺失依赖
    if [[ ${#missing_deps[@]} -eq 0 ]]; then
        print_message "$GREEN" "✓ 所有必需依赖已安装"
        return 0
    fi
    
    print_message "$YELLOW" "缺少依赖: ${missing_deps[*]}"
    
    # 尝试自动安装
    if [[ "$OS" == "Linux" ]]; then
        install_deps_linux "${missing_deps[@]}"
    elif [[ "$OS" == "Darwin" ]]; then
        install_deps_macos "${missing_deps[@]}"
    elif [[ "$OS" == "FreeBSD" ]]; then
        install_deps_freebsd "${missing_deps[@]}"
    else
        print_message "$YELLOW" "请手动安装依赖: ${missing_deps[*]}"
        return 1
    fi
    
    # 验证安装结果
    for dep in "${missing_deps[@]}"; do
        if ! command_exists "$dep"; then
            print_message "$RED" "✗ $dep 安装失败，请手动安装"
            return 1
        fi
    done
    
    print_message "$GREEN" "✓ 依赖安装完成"
    return 0
}

install_deps_linux() {
    local missing_deps=("$@")
    
    print_message "$BLUE" "尝试自动安装依赖..."
    
    if command_exists apt-get; then
        print_message "$CYAN" "使用 apt-get 安装..."
        sudo apt-get update && sudo apt-get install -y "${missing_deps[@]}" || return 1
    elif command_exists yum; then
        print_message "$CYAN" "使用 yum 安装..."
        sudo yum install -y "${missing_deps[@]}" || return 1
    elif command_exists dnf; then
        print_message "$CYAN" "使用 dnf 安装..."
        sudo dnf install -y "${missing_deps[@]}" || return 1
    elif command_exists pacman; then
        print_message "$CYAN" "使用 pacman 安装..."
        sudo pacman -Sy --noconfirm "${missing_deps[@]}" || return 1
    elif command_exists apk; then
        print_message "$CYAN" "使用 apk 安装..."
        sudo apk add "${missing_deps[@]}" || return 1
    else
        print_message "$RED" "未找到支持的包管理器"
        return 1
    fi
}

install_deps_macos() {
    local missing_deps=("$@")
    
    print_message "$BLUE" "尝试自动安装依赖..."
    
    if command_exists brew; then
        print_message "$CYAN" "使用 Homebrew 安装..."
        brew install "${missing_deps[@]}" || return 1
    else
        print_message "$RED" "请先安装 Homebrew: https://brew.sh"
        return 1
    fi
}

install_deps_freebsd() {
    local missing_deps=("$@")
    
    print_message "$BLUE" "尝试自动安装依赖..."
    
    if command_exists pkg; then
        print_message "$CYAN" "使用 pkg 安装..."
        sudo pkg install -y "${missing_deps[@]}" || return 1
    else
        print_message "$RED" "未找到 pkg 包管理器"
        return 1
    fi
}

# ==================== 目录创建函数 ====================

create_directories() {
    print_message "$BLUE" "创建目录结构..."
    
    local dirs=(
        "$SCRIPT_DIR/bin"
        "$SCRIPT_DIR/config"
        "$SCRIPT_DIR/logs"
        "$SCRIPT_DIR/run"
        "$SCRIPT_DIR/tmp"
    )
    
    for dir in "${dirs[@]}"; do
        if mkdir -p "$dir" 2>/dev/null; then
            print_message "$GREEN" "  ✓ $dir"
        else
            error_exit "无法创建目录: $dir"
        fi
    done
    
    # 设置临时目录
    export TMPDIR="$SCRIPT_DIR/tmp"
    
    print_message "$GREEN" "✓ 目录创建完成"
}

# ==================== 服务脚本创建函数 ====================

create_service_script() {
    print_message "$BLUE" "创建服务脚本..."
    
    cat > "$SERVICE_FILE" << 'EOF'
#!/bin/bash
# VPS监控服务脚本

set -euo pipefail

# 配置路径
SCRIPT_DIR="__SCRIPT_DIR__"
CONFIG_FILE="$SCRIPT_DIR/config/config"
LOG_FILE="$SCRIPT_DIR/logs/monitor.log"
PID_FILE="$SCRIPT_DIR/run/monitor.pid"

# 服务模式标志
export SERVICE_MODE=true

# 确保目录存在
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")"

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

# 获取系统指标
get_cpu_usage() {
    local usage=0
    if [[ -f /proc/stat ]]; then
        local cpu_line=$(head -n1 /proc/stat)
        local -a cpu_times=($cpu_line)
        local idle=${cpu_times[4]}
        local total=0
        for i in {1..8}; do
            total=$((total + ${cpu_times[$i]:-0}))
        done
        [[ $total -gt 0 ]] && usage=$((100 - (idle * 100 / total)))
    fi
    echo "$usage"
}

get_memory_usage() {
    local usage=0
    if [[ -f /proc/meminfo ]]; then
        local total=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}')
        local free=$(grep "^MemFree:" /proc/meminfo | awk '{print $2}')
        local buffers=$(grep "^Buffers:" /proc/meminfo | awk '{print $2}')
        local cached=$(grep "^Cached:" /proc/meminfo | awk '{print $2}')
        [[ -n "$total" ]] && usage=$((100 - ((free + buffers + cached) * 100 / total)))
    fi
    echo "$usage"
}

get_disk_usage() {
    df -h / | tail -1 | awk '{print $5}' | sed 's/%//'
}

# 构建监控数据
build_monitor_data() {
    local timestamp=$(date +%s)
    local cpu_usage=$(get_cpu_usage)
    local memory_usage=$(get_memory_usage)
    local disk_usage=$(get_disk_usage)
    
    cat << JSON
{
    "timestamp": $timestamp,
    "cpu_usage": $cpu_usage,
    "memory_usage": $memory_usage,
    "disk_usage": $disk_usage,
    "server_id": "$SERVER_ID"
}
JSON
}

# 上报数据
report_data() {
    local data=$(build_monitor_data)
    
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
    log "监控服务启动 (PID: $$)"
    echo $$ > "$PID_FILE"
    
    # 信号处理
    trap 'log "收到终止信号，正在停止..."; rm -f "$PID_FILE"; exit 0' TERM INT
    
    # 加载配置
    load_config
    
    while true; do
        if report_data; then
            log "上报成功，等待 ${INTERVAL} 秒..."
        else
            log "上报失败，等待 ${INTERVAL} 秒后重试..."
        fi
        
        sleep "$INTERVAL"
    done
}

# 启动主函数
main
EOF
    
    # 替换脚本目录
    sed -i "s|__SCRIPT_DIR__|$SCRIPT_DIR|g" "$SERVICE_FILE"
    
    chmod +x "$SERVICE_FILE"
    print_message "$GREEN" "✓ 服务脚本创建完成"
}

# ==================== 服务管理函数 ====================

# 启动服务
start_service() {
    print_message "$BLUE" "启动监控服务..."
    
    # 检查是否已在运行
    if is_monitor_running; then
        print_message "$YELLOW" "监控服务已在运行"
        return 0
    fi
    
    # 确保服务脚本存在
    if [[ ! -f "$SERVICE_FILE" ]]; then
        error_exit "服务脚本不存在: $SERVICE_FILE"
    fi
    
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
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        print_message "$GREEN" "✓ 监控服务已启动 (PID: $pid)"
        
        # 配置自启动
        setup_autostart
        
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

# 检查服务是否运行
is_monitor_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    
    # 检查进程
    if pgrep -f "$(basename "$SERVICE_FILE")" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# 配置自启动
setup_autostart() {
    print_message "$BLUE" "配置自启动..."
    
    # 尝试使用systemd
    if setup_systemd_service; then
        print_message "$GREEN" "✓ systemd服务已配置"
        return
    fi
    
    # 尝试使用crontab
    if setup_crontab_autostart; then
        print_message "$GREEN" "✓ crontab自启动已配置"
        return
    fi
    
    print_message "$YELLOW" "⚠ 自启动配置失败，服务需要手动启动"
}

# 配置systemd服务
setup_systemd_service() {
    if ! command_exists systemctl; then
        return 1
    fi
    
    local service_file=""
    if [[ $EUID -eq 0 ]]; then
        service_file="/etc/systemd/system/cf-vps-monitor.service"
    else
        service_file="$HOME/.config/systemd/user/cf-vps-monitor.service"
        mkdir -p "$(dirname "$service_file")"
    fi
    
    cat > "$service_file" << EOF
[Unit]
Description=CF VPS Monitor Service
After=network.target

[Service]
Type=simple
ExecStart=$SERVICE_FILE
Restart=always
RestartSec=10
WorkingDirectory=$SCRIPT_DIR

[Install]
WantedBy=default.target
EOF
    
    if [[ $EUID -eq 0 ]]; then
        systemctl daemon-reload
        systemctl enable cf-vps-monitor.service
        systemctl start cf-vps-monitor.service
    else
        systemctl --user daemon-reload
        systemctl --user enable cf-vps-monitor.service
        systemctl --user start cf-vps-monitor.service
    fi
    
    return 0
}

# 配置crontab自启动
setup_crontab_autostart() {
    if ! command_exists crontab; then
        return 1
    fi
    
    local crontab_entry="@reboot sleep 30 && $SERVICE_FILE"
    (crontab -l 2>/dev/null | grep -v "$SERVICE_FILE"; echo "$crontab_entry") | crontab -
    return 0
}

# 停止服务
stop_service() {
    print_message "$BLUE" "停止监控服务..."
    
    # 停止systemd服务
    if command_exists systemctl; then
        if [[ $EUID -eq 0 ]]; then
            systemctl stop cf-vps-monitor.service 2>/dev/null || true
            systemctl disable cf-vps-monitor.service 2>/dev/null || true
        else
            systemctl --user stop cf-vps-monitor.service 2>/dev/null || true
            systemctl --user disable cf-vps-monitor.service 2>/dev/null || true
        fi
    fi
    
    # 停止进程
    local pids=$(pgrep -f "$(basename "$SERVICE_FILE")" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        kill $pids 2>/dev/null || true
        sleep 1
        kill -9 $pids 2>/dev/null || true
    fi
    
    # 清理文件
    rm -f "$PID_FILE" 2>/dev/null || true
    
    print_message "$GREEN" "✓ 监控服务已停止"
}

# 检查服务状态
check_service_status() {
    print_message "$BLUE" "监控服务状态"
    echo
    
    if is_monitor_running; then
        local pid=""
        if [[ -f "$PID_FILE" ]]; then
            pid=$(cat "$PID_FILE" 2>/dev/null)
        else
            pid=$(pgrep -f "$(basename "$SERVICE_FILE")" | head -1)
        fi
        
        print_message "$GREEN" "✓ 监控服务正在运行"
        echo "  进程PID: $pid"
        echo "  运行时间: $(ps -p "$pid" -o etime= 2>/dev/null || echo "未知")"
    else
        print_message "$RED" "✗ 监控服务未运行"
    fi
    
    # 配置文件状态
    echo
    print_message "$BLUE" "配置文件:"
    if [[ -f "$CONFIG_FILE" ]]; then
        local worker_url server_id api_key interval
        worker_url=$(grep '^WORKER_URL=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
        server_id=$(grep '^SERVER_ID=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
        api_key=$(grep '^API_KEY=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
        interval=$(grep '^INTERVAL=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
        
        echo "  Worker URL: ${worker_url:0:50}..."
        echo "  Server ID: $server_id"
        echo "  API Key: ${api_key:0:8}..."
        echo "  上报间隔: ${interval}秒"
    else
        print_message "$YELLOW" "✗ 配置文件不存在"
    fi
    
    # 日志状态
    echo
    print_message "$BLUE" "日志文件:"
    if [[ -f "$LOG_FILE" ]]; then
        local log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
        local log_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
        echo "  位置: $LOG_FILE"
        echo "  大小: $log_size"
        echo "  行数: $log_lines"
        
        # 显示最后5行日志
        echo "  最后日志:"
        tail -n 5 "$LOG_FILE" 2>/dev/null | sed 's/^/    /'
    else
        print_message "$YELLOW" "✗ 日志文件不存在"
    fi
}

# 查看日志
view_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        print_message "$YELLOW" "日志文件不存在"
        return 1
    fi
    
    print_message "$BLUE" "监控服务日志 (Ctrl+C退出)"
    echo "========================================"
    tail -f "$LOG_FILE"
}

# 重启服务
restart_service() {
    stop_service
    sleep 2
    start_service
}

# 卸载服务
uninstall_service() {
    print_message "$YELLOW" "警告：这将完全卸载VPS监控服务"
    echo -n "确认卸载？(y/N): "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_message "$BLUE" "取消卸载"
        return 0
    fi
    
    print_message "$BLUE" "开始卸载监控服务..."
    
    # 停止服务
    stop_service
    
    # 清理crontab
    if command_exists crontab; then
        (crontab -l 2>/dev/null | grep -v "$SERVICE_FILE") | crontab -
    fi
    
    # 清理systemd服务
    if command_exists systemctl; then
        if [[ $EUID -eq 0 ]]; then
            rm -f /etc/systemd/system/cf-vps-monitor.service 2>/dev/null
            systemctl daemon-reload 2>/dev/null || true
        else
            rm -f "$HOME/.config/systemd/user/cf-vps-monitor.service" 2>/dev/null
            systemctl --user daemon-reload 2>/dev/null || true
        fi
    fi
    
    # 删除安装目录
    if [[ -d "$SCRIPT_DIR" ]]; then
        rm -rf "$SCRIPT_DIR"
        print_message "$GREEN" "✓ 监控服务已完全卸载"
    else
        print_message "$YELLOW" "安装目录不存在"
    fi
}

# ==================== 帮助信息 ====================

show_help() {
    cat << EOF
VPS监控脚本 v$SCRIPT_VERSION

一键安装:
  wget https://raw.githubusercontent.com/mimaldq/cf-vps-monitor/main/cf-vps-monitor.sh -O cf-vps-monitor.sh && chmod +x cf-vps-monitor.sh && ./cf-vps-monitor.sh -i -k API_KEY -s SERVER_ID -u WORKER_URL

命令:
  install        安装监控服务 (交互式)
  start          启动监控服务
  stop           停止监控服务
  restart        重启监控服务
  status         查看服务状态
  logs           查看运行日志
  uninstall      卸载监控服务
  help           显示帮助信息

参数:
  -i, --install      一键安装模式
  -s, --server-id    服务器ID
  -k, --api-key      API密钥
  -u, --worker-url   Worker地址
  -h, --help        显示帮助

示例:
  # 一键安装
  ./cf-vps-monitor.sh -i -k 9947e755... -s hr20js -u https://mycf-vps.workers.dev
  
  # 常规安装
  ./cf-vps-monitor.sh install
  
  # 查看状态
  ./cf-vps-monitor.sh status
  
  # 查看日志
  ./cf-vps-monitor.sh logs

注意:
  - 脚本会自动检测系统并安装依赖
  - 服务会在系统重启后自动启动
  - 数据上报间隔默认为10秒
EOF
}

# ==================== 主函数 ====================

main() {
    # 解析参数
    local remaining_args
    remaining_args=$(parse_arguments "$@")
    
    # 如果没有参数或有一键安装参数（一键安装已处理并退出）
    if [[ -z "$remaining_args" ]]; then
        show_interactive_menu
        return
    fi
    
    # 处理剩余的命令
    case "$remaining_args" in
        install)
            interactive_install
            ;;
        start)
            start_service
            ;;
        stop)
            stop_service
            ;;
        restart)
            restart_service
            ;;
        status)
            check_service_status
            ;;
        logs)
            view_logs
            ;;
        uninstall)
            uninstall_service
            ;;
        help)
            show_help
            ;;
        *)
            print_message "$RED" "未知命令: $remaining_args"
            show_help
            exit 1
            ;;
    esac
}

# 交互式安装
interactive_install() {
    print_message "$CYAN" "VPS监控服务安装向导"
    echo
    
    # 检测系统
    detect_system
    
    # 创建目录
    create_directories
    
    # 获取配置
    print_message "$BLUE" "请输入配置信息:"
    
    echo -n "Server ID: "
    read -r server_id
    
    echo -n "API Key: "
    read -r api_key
    
    echo -n "Worker URL: "
    read -r worker_url
    
    # 保存配置
    save_config_direct "$server_id" "$api_key" "$worker_url"
    
    # 安装依赖
    install_dependencies
    
    # 创建服务脚本
    create_service_script
    
    # 启动服务
    if start_service; then
        print_message "$GREEN" "✓ VPS监控服务安装成功！"
    else
        error_exit "服务启动失败"
    fi
}

# 交互式菜单
show_interactive_menu() {
    while true; do
        echo
        print_message "$CYAN" "VPS监控服务管理"
        echo
        echo "1) 安装监控服务"
        echo "2) 启动监控服务"
        echo "3) 停止监控服务"
        echo "4) 重启监控服务"
        echo "5) 查看服务状态"
        echo "6) 查看运行日志"
        echo "7) 卸载监控服务"
        echo "8) 退出"
        echo
        echo -n "请选择 (1-8): "
        read -r choice
        
        case "$choice" in
            1) interactive_install ;;
            2) start_service ;;
            3) stop_service ;;
            4) restart_service ;;
            5) check_service_status ;;
            6) view_logs ;;
            7) uninstall_service ;;
            8) exit 0 ;;
            *) print_message "$RED" "无效选择，请重试" ;;
        esac
        
        echo
        echo -n "按回车键继续..."
        read -r
    done
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
