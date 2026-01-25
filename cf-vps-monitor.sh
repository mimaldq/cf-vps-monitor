#!/bin/bash

# cf-vps-monitor - Cloudflare Worker VPS监控脚本
# 版本: 2.2.0 (FreeBSD修复版)
# 完全兼容FreeBSD系统

set -euo pipefail

# ==================== 全局配置 ====================
readonly SCRIPT_VERSION="2.2.0"
readonly SCRIPT_NAME="cf-vps-monitor"

# 系统检测
OS=$(uname -s)
readonly OS

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

print_msg() {
    local color="$1"
    local msg="$2"
    printf "%b%s%b\n" "${color}" "${msg}" "${NC}"
}

log() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $msg" >> "$LOG_FILE"
    [[ "${SERVICE_MODE:-false}" != "true" ]] && echo "[$timestamp] $msg"
}

error_exit() {
    local msg="$1"
    print_msg "$RED" "错误: $msg" >&2
    log "错误: $msg"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ==================== 一键安装函数 ====================

# 一键安装主函数（直接从命令行参数执行）
one_click_install() {
    local server_id=""
    local api_key=""
    local worker_url=""
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
            *)
                shift
                ;;
        esac
    done
    
    # 验证参数
    if [[ -z "$server_id" || -z "$api_key" || -z "$worker_url" ]]; then
        error_exit "一键安装需要所有参数: -s SERVER_ID -k API_KEY -u WORKER_URL"
    fi
    
    print_msg "$CYAN" "========================================"
    print_msg "$CYAN" "      VPS监控服务一键安装"
    print_msg "$CYAN" "========================================"
    echo
    
    # 显示安装参数
    local masked_api_key="${api_key:0:8}****************${api_key: -8}"
    print_msg "$BLUE" "安装配置:"
    echo "  Server ID: $server_id"
    echo "  API Key: $masked_api_key"
    echo "  Worker URL: $worker_url"
    echo
    
    # 检测系统
    detect_system
    
    # 创建目录
    create_dirs
    
    # 保存配置
    save_config_direct "$server_id" "$api_key" "$worker_url"
    
    # 安装依赖
    install_deps
    
    # 创建服务脚本
    create_service_script
    
    # 启动服务
    if start_service; then
        print_msg "$GREEN" "✓ VPS监控服务一键安装成功！"
        echo
        print_msg "$CYAN" "服务信息:"
        echo "  安装目录: $SCRIPT_DIR"
        echo "  配置文件: $CONFIG_FILE"
        echo "  日志文件: $LOG_FILE"
        echo "  服务状态: 运行中"
        echo
        print_msg "$YELLOW" "管理命令:"
        echo "  查看状态: $0 status"
        echo "  查看日志: $0 logs"
        echo "  停止服务: $0 stop"
        echo "  重启服务: $0 restart"
        echo
        print_msg "$GREEN" "✓ 监控服务已启动并开始上报数据"
    else
        error_exit "服务启动失败"
    fi
}

# ==================== 系统检测函数 ====================

detect_system() {
    print_msg "$BLUE" "检测系统环境..."
    
    local os_name=$OS
    local os_version=""
    local arch=$(uname -m)
    
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
    
    print_msg "$GREEN" "✓ 系统: $os_version"
    print_msg "$GREEN" "✓ 架构: $arch"
}

# ==================== 目录创建函数 ====================

create_dirs() {
    print_msg "$BLUE" "创建目录结构..."
    
    local dirs=(
        "$SCRIPT_DIR/bin"
        "$SCRIPT_DIR/config"
        "$SCRIPT_DIR/logs"
        "$SCRIPT_DIR/run"
        "$SCRIPT_DIR/tmp"
    )
    
    for dir in "${dirs[@]}"; do
        if mkdir -p "$dir" 2>/dev/null; then
            print_msg "$GREEN" "  ✓ $dir"
        else
            error_exit "无法创建目录: $dir"
        fi
    done
    
    export TMPDIR="$SCRIPT_DIR/tmp"
    print_msg "$GREEN" "✓ 目录结构创建完成"
}

# ==================== 配置管理函数 ====================

save_config_direct() {
    local server_id="$1"
    local api_key="$2"
    local worker_url="$3"
    
    print_msg "$BLUE" "保存配置..."
    
    # 验证输入
    [[ -z "$server_id" ]] && error_exit "Server ID不能为空"
    [[ -z "$api_key" ]] && error_exit "API Key不能为空"
    [[ -z "$worker_url" ]] && error_exit "Worker URL不能为空"
    
    # 清理输入
    server_id=$(echo "$server_id" | tr -d '\r\n\t' | sed 's/[^[:alnum:]_-]//g')
    api_key=$(echo "$api_key" | tr -d '\r\n\t' | sed 's/[^[:alnum:]]//g')
    worker_url=$(echo "$worker_url" | tr -d '\r\n\t')
    
    # 创建配置文件
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOF
# VPS监控配置
WORKER_URL="$worker_url"
SERVER_ID="$server_id"
API_KEY="$api_key"
INTERVAL="10"
EOF
    
    chmod 600 "$CONFIG_FILE"
    print_msg "$GREEN" "✓ 配置保存成功"
}

# ==================== 依赖安装函数 ====================

install_deps() {
    print_msg "$BLUE" "检查系统依赖..."
    
    local missing_deps=()
    
    # 检查curl
    if ! command_exists curl; then
        missing_deps+=("curl")
    fi
    
    # 如果没有缺失依赖
    if [[ ${#missing_deps[@]} -eq 0 ]]; then
        print_msg "$GREEN" "✓ 所有必需依赖已安装"
        return 0
    fi
    
    print_msg "$YELLOW" "缺少依赖: ${missing_deps[*]}"
    
    # FreeBSD特殊处理
    if [[ "$OS" == "FreeBSD" ]]; then
        install_deps_freebsd "${missing_deps[@]}"
    elif [[ "$OS" == "Linux" ]]; then
        install_deps_linux "${missing_deps[@]}"
    elif [[ "$OS" == "Darwin" ]]; then
        install_deps_macos "${missing_deps[@]}"
    else
        print_msg "$YELLOW" "请手动安装依赖: ${missing_deps[*]}"
        return 1
    fi
    
    # 验证安装结果
    for dep in "${missing_deps[@]}"; do
        if ! command_exists "$dep"; then
            print_msg "$RED" "✗ $dep 安装失败，请手动安装"
            return 1
        fi
    done
    
    print_msg "$GREEN" "✓ 依赖安装完成"
    return 0
}

install_deps_freebsd() {
    local missing_deps=("$@")
    
    print_msg "$BLUE" "在FreeBSD上安装依赖..."
    
    if command_exists pkg; then
        print_msg "$CYAN" "使用pkg包管理器..."
        for dep in "${missing_deps[@]}"; do
            if ! sudo pkg install -y "$dep" 2>/dev/null; then
                print_msg "$YELLOW" "使用pkg安装$dep失败，尝试其他方法..."
                case "$dep" in
                    curl)
                        # 尝试从ports安装
                        if command_exists portsnap; then
                            print_msg "$CYAN" "从ports安装curl..."
                            sudo portsnap fetch extract 2>/dev/null || true
                            cd /usr/ports/ftp/curl && sudo make install clean 2>/dev/null || true
                        fi
                        ;;
                esac
            fi
        done
    else
        print_msg "$RED" "找不到pkg命令。请手动安装curl:"
        print_msg "$CYAN" "  sudo pkg install curl"
        return 1
    fi
}

install_deps_linux() {
    local missing_deps=("$@")
    
    print_msg "$BLUE" "在Linux上安装依赖..."
    
    if command_exists apt-get; then
        sudo apt-get update && sudo apt-get install -y "${missing_deps[@]}" || return 1
    elif command_exists yum; then
        sudo yum install -y "${missing_deps[@]}" || return 1
    elif command_exists dnf; then
        sudo dnf install -y "${missing_deps[@]}" || return 1
    elif command_exists pacman; then
        sudo pacman -Sy --noconfirm "${missing_deps[@]}" || return 1
    else
        print_msg "$RED" "未找到支持的包管理器"
        return 1
    fi
}

install_deps_macos() {
    local missing_deps=("$@")
    
    print_msg "$BLUE" "在macOS上安装依赖..."
    
    if command_exists brew; then
        brew install "${missing_deps[@]}" || return 1
    else
        print_msg "$RED" "请先安装Homebrew: https://brew.sh"
        return 1
    fi
}

# ==================== 服务脚本创建函数 ====================

create_service_script() {
    print_msg "$BLUE" "创建服务脚本..."
    
    cat > "$SERVICE_FILE" << 'EOF'
#!/bin/sh

# VPS监控服务脚本
# 兼容FreeBSD

set -e

# 配置文件路径
SCRIPT_DIR="__SCRIPT_DIR__"
CONFIG_FILE="$SCRIPT_DIR/config/config"
LOG_FILE="$SCRIPT_DIR/logs/monitor.log"
PID_FILE="$SCRIPT_DIR/run/monitor.pid"

# 服务模式标志
export SERVICE_MODE=true

# 确保目录存在
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")" 2>/dev/null

# 日志函数
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE"
}

# 加载配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
    else
        log "错误: 配置文件不存在"
        exit 1
    fi
}

# 获取CPU使用率 (FreeBSD兼容)
get_cpu_usage() {
    local usage=0
    if [ -f /proc/stat ]; then
        # Linux系统
        local cpu_line=$(head -n1 /proc/stat)
        local idle=$(echo "$cpu_line" | awk '{print $5}')
        local total=0
        for i in $(seq 2 9); do
            local val=$(echo "$cpu_line" | awk -v i="$i" '{print $i}')
            total=$((total + val))
        done
        if [ $total -gt 0 ]; then
            usage=$((100 - (idle * 100 / total)))
        fi
    elif command_exists sysctl; then
        # FreeBSD系统
        local cpu_times=$(sysctl -n kern.cp_time 2>/dev/null || echo "0 0 0 0 0")
        local idle=$(echo "$cpu_times" | awk '{print $5}')
        local total=0
        for i in 1 2 3 4 5; do
            local val=$(echo "$cpu_times" | awk -v i="$i" '{print $i}')
            total=$((total + val))
        done
        if [ $total -gt 0 ]; then
            usage=$((100 - (idle * 100 / total)))
        fi
    fi
    echo "$usage"
}

# 获取内存使用率 (FreeBSD兼容)
get_memory_usage() {
    local usage=0
    if [ -f /proc/meminfo ]; then
        # Linux系统
        local total=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}')
        local free=$(grep "^MemFree:" /proc/meminfo | awk '{print $2}')
        if [ -n "$total" ] && [ "$total" -gt 0 ]; then
            usage=$((100 - (free * 100 / total)))
        fi
    elif command_exists sysctl; then
        # FreeBSD系统
        local page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
        local total_pages=$(sysctl -n vm.stats.vm.v_page_count 2>/dev/null || echo 0)
        local free_pages=$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null || echo 0)
        local total=$((total_pages * page_size / 1024))
        local free=$((free_pages * page_size / 1024))
        if [ $total -gt 0 ]; then
            usage=$((100 - (free * 100 / total)))
        fi
    fi
    echo "$usage"
}

# 获取磁盘使用率
get_disk_usage() {
    local usage=0
    if command_exists df; then
        usage=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//' 2>/dev/null || echo 0)
    fi
    echo "$usage"
}

# 获取运行时间
get_uptime() {
    local uptime=0
    if [ -f /proc/uptime ]; then
        uptime=$(awk -F. '{print $1}' /proc/uptime 2>/dev/null || echo 0)
    elif command_exists sysctl; then
        local boot_time=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | tr -d ',')
        local current_time=$(date +%s)
        if [ -n "$boot_time" ]; then
            uptime=$((current_time - boot_time))
        fi
    fi
    echo "$uptime"
}

# 构建监控数据
build_monitor_data() {
    local timestamp=$(date +%s)
    local cpu_usage=$(get_cpu_usage)
    local memory_usage=$(get_memory_usage)
    local disk_usage=$(get_disk_usage)
    local uptime=$(get_uptime)
    
    cat << JSON
{
    "timestamp": $timestamp,
    "cpu_usage": $cpu_usage,
    "memory_usage": $memory_usage,
    "disk_usage": $disk_usage,
    "uptime": $uptime,
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
    
    local http_code=$(echo "$response" | tail -c 4)
    
    if [ "$http_code" = "200" ]; then
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
    
    # 替换脚本目录路径 - 使用sed的兼容方法
    local temp_file="$SERVICE_FILE.tmp"
    sed "s|__SCRIPT_DIR__|$SCRIPT_DIR|g" "$SERVICE_FILE" > "$temp_file"
    mv "$temp_file" "$SERVICE_FILE"
    
    chmod +x "$SERVICE_FILE"
    print_msg "$GREEN" "✓ 服务脚本创建完成"
}

# ==================== 服务管理函数 ====================

# 检查服务是否运行
is_service_running() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    
    # 检查进程
    if command_exists pgrep; then
        if pgrep -f "$(basename "$SERVICE_FILE")" >/dev/null 2>&1; then
            return 0
        fi
    else
        # FreeBSD可能没有pgrep，使用ps替代
        if ps aux | grep -v grep | grep "$(basename "$SERVICE_FILE")" >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    return 1
}

# 启动服务
start_service() {
    print_msg "$BLUE" "启动监控服务..."
    
    # 检查是否已在运行
    if is_service_running; then
        print_msg "$YELLOW" "监控服务已在运行"
        return 0
    fi
    
    # 确保服务脚本存在
    if [ ! -f "$SERVICE_FILE" ]; then
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
        print_msg "$GREEN" "✓ 监控服务已启动 (PID: $pid)"
        
        # 配置自启动
        setup_autostart
        
        return 0
    else
        print_msg "$RED" "✗ 监控服务启动失败"
        if [ -f "$LOG_FILE" ]; then
            print_msg "$YELLOW" "查看日志: tail -f $LOG_FILE"
        fi
        rm -f "$PID_FILE" 2>/dev/null
        return 1
    fi
}

# 配置自启动
setup_autostart() {
    print_msg "$BLUE" "配置自启动..."
    
    # FreeBSD使用rc.d
    if [[ "$OS" == "FreeBSD" ]]; then
        setup_rc_daemon
    elif command_exists systemctl; then
        setup_systemd_service
    elif command_exists crontab; then
        setup_crontab_autostart
    else
        print_msg "$YELLOW" "⚠ 自启动配置失败，服务需要手动启动"
    fi
}

# FreeBSD rc.d配置
setup_rc_daemon() {
    print_msg "$CYAN" "设置FreeBSD rc.d服务..."
    
    # 普通用户无法设置系统服务，使用crontab
    if [ $EUID -ne 0 ]; then
        print_msg "$YELLOW" "需要root权限设置rc.d服务，使用crontab替代"
        setup_crontab_autostart
        return
    fi
    
    local rc_file="/usr/local/etc/rc.d/cf-vps-monitor"
    
    cat > "$rc_file" << 'RCFILE'
#!/bin/sh

# PROVIDE: cf_vps_monitor
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="cf_vps_monitor"
rcvar="${name}_enable"
pidfile="/var/run/cf-vps-monitor.pid"
command="/usr/sbin/daemon"
command_args="-P ${pidfile} -r -f __SERVICE_SCRIPT__"

load_rc_config $name
run_rc_command "$1"
RCFILE
    
    # 替换服务脚本路径
    local temp_file="$rc_file.tmp"
    sed "s|__SERVICE_SCRIPT__|$SERVICE_FILE|g" "$rc_file" > "$temp_file"
    mv "$temp_file" "$rc_file"
    
    chmod +x "$rc_file"
    
    # 启用服务
    sysrc cf_vps_monitor_enable="YES" 2>/dev/null || true
    print_msg "$GREEN" "✓ FreeBSD rc.d服务已配置"
}

# 配置systemd服务
setup_systemd_service() {
    local service_file=""
    
    if [ $EUID -eq 0 ]; then
        service_file="/etc/systemd/system/cf-vps-monitor.service"
    else
        service_file="$HOME/.config/systemd/user/cf-vps-monitor.service"
        mkdir -p "$(dirname "$service_file")"
    fi
    
    cat > "$service_file" << EOF
[Unit]
Description=CF VPS监控服务
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
    
    if [ $EUID -eq 0 ]; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable cf-vps-monitor.service 2>/dev/null || true
    else
        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user enable cf-vps-monitor.service 2>/dev/null || true
    fi
    
    print_msg "$GREEN" "✓ systemd服务已配置"
}

# 配置crontab自启动
setup_crontab_autostart() {
    if ! command_exists crontab; then
        return 1
    fi
    
    local crontab_entry="@reboot sleep 30 && $SERVICE_FILE"
    (crontab -l 2>/dev/null | grep -v "$SERVICE_FILE"; echo "$crontab_entry") | crontab -
    
    print_msg "$GREEN" "✓ crontab自启动已配置"
}

# 停止服务
stop_service() {
    print_msg "$BLUE" "停止监控服务..."
    
    # 停止FreeBSD rc.d服务
    if [[ "$OS" == "FreeBSD" ]] && [ $EUID -eq 0 ]; then
        service cf_vps_monitor stop 2>/dev/null || true
        sysrc -x cf_vps_monitor_enable 2>/dev/null || true
        rm -f /usr/local/etc/rc.d/cf-vps-monitor 2>/dev/null || true
    fi
    
    # 停止systemd服务
    if command_exists systemctl; then
        if [ $EUID -eq 0 ]; then
            systemctl stop cf-vps-monitor.service 2>/dev/null || true
            systemctl disable cf-vps-monitor.service 2>/dev/null || true
        else
            systemctl --user stop cf-vps-monitor.service 2>/dev/null || true
            systemctl --user disable cf-vps-monitor.service 2>/dev/null || true
        fi
    fi
    
    # 停止进程
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
    
    # 清理crontab
    if command_exists crontab; then
        (crontab -l 2>/dev/null | grep -v "$SERVICE_FILE") | crontab - 2>/dev/null || true
    fi
    
    # 清理文件
    rm -f "$PID_FILE" 2>/dev/null || true
    
    print_msg "$GREEN" "✓ 监控服务已停止"
}

# 检查服务状态
check_service_status() {
    print_msg "$BLUE" "监控服务状态"
    echo
    
    if is_service_running; then
        local pid=""
        if [ -f "$PID_FILE" ]; then
            pid=$(cat "$PID_FILE" 2>/dev/null)
        elif command_exists pgrep; then
            pid=$(pgrep -f "$(basename "$SERVICE_FILE")" | head -1)
        fi
        
        print_msg "$GREEN" "✓ 监控服务正在运行"
        echo "  进程PID: $pid"
        
        # 显示运行时间
        if [ -n "$pid" ]; then
            if command_exists ps; then
                local etime=$(ps -p "$pid" -o etime= 2>/dev/null || echo "未知")
                echo "  运行时间: $etime"
            fi
        fi
    else
        print_msg "$RED" "✗ 监控服务未运行"
    fi
    
    # 配置文件状态
    echo
    print_msg "$BLUE" "配置文件:"
    if [ -f "$CONFIG_FILE" ]; then
        local worker_url=$(grep '^WORKER_URL=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
        local server_id=$(grep '^SERVER_ID=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
        local api_key=$(grep '^API_KEY=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
        local interval=$(grep '^INTERVAL=' "$CONFIG_FILE" | cut -d= -f2 | tr -d '"')
        
        echo "  Worker URL: ${worker_url:0:50}..."
        echo "  Server ID: $server_id"
        echo "  API Key: ${api_key:0:8}..."
        echo "  上报间隔: ${interval}秒"
    else
        print_msg "$YELLOW" "✗ 配置文件不存在"
    fi
    
    # 日志状态
    echo
    print_msg "$BLUE" "日志文件:"
    if [ -f "$LOG_FILE" ]; then
        local log_size=""
        if command_exists du; then
            log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
        fi
        local log_lines=0
        if command_exists wc; then
            log_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
        fi
        echo "  位置: $LOG_FILE"
        [ -n "$log_size" ] && echo "  大小: $log_size"
        echo "  行数: $log_lines"
        
        # 显示最后3行日志
        echo "  最后日志:"
        tail -n 3 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' || true
    else
        print_msg "$YELLOW" "✗ 日志文件不存在"
    fi
}

# 查看日志
view_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        print_msg "$YELLOW" "日志文件不存在"
        return 1
    fi
    
    print_msg "$BLUE" "监控服务日志 (按Ctrl+C退出)"
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
    print_msg "$YELLOW" "警告：这将完全卸载VPS监控服务"
    echo -n "确认卸载？(y/N): "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_msg "$BLUE" "取消卸载"
        return 0
    fi
    
    print_msg "$BLUE" "开始卸载..."
    
    # 停止服务
    stop_service
    
    # 删除安装目录
    if [ -d "$SCRIPT_DIR" ]; then
        rm -rf "$SCRIPT_DIR"
        print_msg "$GREEN" "✓ VPS监控服务已完全卸载"
    else
        print_msg "$YELLOW" "安装目录不存在"
    fi
}

# ==================== 帮助信息 ====================

show_help() {
    cat << EOF
VPS监控脚本 v$SCRIPT_VERSION

一键安装:
  wget https://raw.githubusercontent.com/mimaldq/cf-vps-monitor/main/cf-vps-monitor.sh -O cf-vps-monitor.sh && chmod +x cf-vps-monitor.sh && ./cf-vps-monitor.sh -i -k API_KEY -s SERVER_ID -u WORKER_URL

命令:
  start          启动监控服务
  stop           停止监控服务
  restart        重启监控服务
  status         查看服务状态
  logs           查看服务日志
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
  
  # 查看状态
  ./cf-vps-monitor.sh status
  
  # 查看日志
  ./cf-vps-monitor.sh logs

注意:
  - 脚本自动检测系统并安装依赖
  - 服务会在系统重启后自动启动
  - 默认上报间隔为10秒
EOF
}

# ==================== 主函数 ====================

main() {
    # 检查是否是一键安装模式
    for arg in "$@"; do
        if [[ "$arg" == "-i" ]] || [[ "$arg" == "--install" ]]; then
            # 直接调用一键安装函数
            one_click_install "$@"
            exit 0
        fi
    done
    
    # 如果不是一键安装，解析其他命令
    local command=""
    for arg in "$@"; do
        case "$arg" in
            start|stop|restart|status|logs|uninstall|help)
                command="$arg"
                break
                ;;
        esac
    done
    
    # 如果没有命令，显示帮助
    if [[ -z "$command" ]]; then
        show_help
        return
    fi
    
    # 处理命令
    case "$command" in
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
            print_msg "$RED" "未知命令: $command"
            show_help
            exit 1
            ;;
    esac
}

# 脚本入口
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
