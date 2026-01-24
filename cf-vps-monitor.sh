#!/bin/bash

# cf-vps-monitor - Cloudflare Worker VPS监控脚本
# 版本: 2.1.0 - 修复参数解析问题
# 支持FreeBSD、Linux、macOS

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

    export OS ARCH KERNEL_VERSION VER DISTRO_ID DISTRO_NAME
}

# 安装依赖
install_dependencies() {
    print_message "$BLUE" "检查系统依赖..."
    
    local missing_deps=()
    
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
    
    # FreeBSD系统
    if [[ "$OS" == "FreeBSD" ]]; then
        if command_exists pkg; then
            print_message "$BLUE" "使用pkg安装依赖..."
            sudo pkg install -y curl bc 2>/dev/null || {
                print_message "$YELLOW" "需要root权限安装依赖，请手动执行:"
                print_message "$CYAN" "  sudo pkg install -y curl bc"
            }
        else
            print_message "$YELLOW" "请手动安装依赖:"
            print_message "$CYAN" "  pkg install curl bc"
        fi
    else
        # Linux系统
        if command_exists apt-get; then
            print_message "$BLUE" "使用apt-get安装依赖..."
            sudo apt-get update && sudo apt-get install -y curl bc 2>/dev/null || {
                print_message "$YELLOW" "需要root权限安装依赖，请手动执行:"
                print_message "$CYAN" "  sudo apt-get update && sudo apt-get install -y curl bc"
            }
        elif command_exists yum; then
            print_message "$BLUE" "使用yum安装依赖..."
            sudo yum install -y curl bc 2>/dev/null || {
                print_message "$YELLOW" "需要root权限安装依赖，请手动执行:"
                print_message "$CYAN" "  sudo yum install -y curl bc"
            }
        elif command_exists dnf; then
            print_message "$BLUE" "使用dnf安装依赖..."
            sudo dnf install -y curl bc 2>/dev/null || {
                print_message "$YELLOW" "需要root权限安装依赖，请手动执行:"
                print_message "$CYAN" "  sudo dnf install -y curl bc"
            }
        else
            print_message "$YELLOW" "未检测到包管理器，请手动安装依赖"
            print_message "$CYAN" "常见安装命令:"
            print_message "$CYAN" "  Ubuntu/Debian: sudo apt-get install curl bc"
            print_message "$CYAN" "  CentOS/RHEL: sudo yum install curl bc"
            print_message "$CYAN" "  Fedora: sudo dnf install curl bc"
            print_message "$CYAN" "  Alpine: sudo apk add curl bc"
        fi
    fi
    
    # 重新检查
    if ! command_exists curl && ! command_exists wget; then
        print_message "$RED" "错误: curl和wget都不可用"
        return 1
    fi
    
    print_message "$GREEN" "依赖检查完成"
}

# 创建目录结构
create_directories() {
    print_message "$BLUE" "创建集中式目录结构..."
    mkdir -p "$SCRIPT_DIR"/{bin,config,logs,tmp,cache,run,system/{templates,backups}} || error_exit "无法创建目录结构"
    touch "$INSTALL_MANIFEST"
    export TMPDIR="$SCRIPT_DIR/tmp"
    print_message "$GREEN" "✓ 集中式目录结构创建完成"
}

# 加载配置
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        WORKER_URL=$(echo "$DEFAULT_WORKER_URL" | tr -d ' \n\r')
        SERVER_ID=$(echo "$DEFAULT_SERVER_ID" | tr -d ' \n\r')
        API_KEY=$(echo "$DEFAULT_API_KEY" | tr -d ' \n\r')
        INTERVAL="$DEFAULT_INTERVAL"
    fi
}

# 保存配置
save_config() {
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

# 创建服务脚本
create_service_script() {
    # 获取当前脚本的绝对路径
    local main_script_path=$(realpath "$0" 2>/dev/null || echo "$0")
    
    cat > "$SERVICE_FILE" << 'EOF'
#!/bin/bash

# cf-vps-monitor服务脚本 - 集中式文件管理
SCRIPT_DIR="$HOME/.cf-vps-monitor"
CONFIG_FILE="$SCRIPT_DIR/config/config"
LOG_FILE="$SCRIPT_DIR/logs/monitor.log"
PID_FILE="$SCRIPT_DIR/run/monitor.pid"

# 设置服务模式标志
export SERVICE_MODE=true

# 确保日志目录存在
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

# 日志函数
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE"
}

# 加载配置
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    log "错误: 配置文件不存在: $CONFIG_FILE"
    exit 1
fi

# 获取CPU使用率
get_cpu_usage() {
    local cpu_usage=0
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
    echo "$cpu_usage"
}

# 获取内存使用率
get_memory_usage() {
    local mem_usage=0
    if [[ -f /proc/meminfo ]]; then
        local mem_total=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
        local mem_free=$(grep "^MemFree:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
        local buffers=$(grep "^Buffers:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
        local cached=$(grep "^Cached:" /proc/meminfo | awk '{print $2}' 2>/dev/null || echo "0")
        
        if [[ $mem_total -gt 0 ]]; then
            local mem_used=$((mem_total - mem_free - buffers - cached))
            mem_usage=$(echo "scale=1; $mem_used * 100 / $mem_total" | bc 2>/dev/null || echo "0")
        fi
    fi
    echo "$mem_usage"
}

# 获取磁盘使用率
get_disk_usage() {
    local disk_usage=0
    if command -v df >/dev/null 2>&1; then
        disk_usage=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d '% ' || echo "0")
    fi
    echo "$disk_usage"
}

# 上报数据
report_metrics() {
    local cpu_usage=$(get_cpu_usage)
    local mem_usage=$(get_memory_usage)
    local disk_usage=$(get_disk_usage)
    local uptime=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")
    local timestamp=$(date +%s)
    
    local json_data="{\"timestamp\":$timestamp,\"server_id\":\"$SERVER_ID\",\"cpu_usage\":$cpu_usage,\"mem_usage\":$mem_usage,\"disk_usage\":$disk_usage,\"uptime\":$uptime}"
    
    local clean_api_key=$(echo "$API_KEY" | tr -d ' \n\r')
    local clean_server_id=$(echo "$SERVER_ID" | tr -d ' \n\r')
    
    local response=$(curl -s -w "%{http_code}" -X POST "$WORKER_URL/api/report/$clean_server_id" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: $clean_api_key" \
        -d "$json_data" 2>/dev/null || echo "000")
    
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
    echo $$ > "$PID_FILE"
    
    trap 'log "收到终止信号，正在停止..."; rm -f "$PID_FILE"; exit 0' TERM INT
    
    while true; do
        if report_metrics; then
            sleep "$INTERVAL"
        else
            sleep 30
        fi
    done
}

# 启动主函数
main
EOF

    chmod +x "$SERVICE_FILE"
    print_message "$GREEN" "监控服务脚本创建完成: $SERVICE_FILE"
}

# 启动监控服务
start_service() {
    print_message "$BLUE" "启动监控服务..."
    
    # 检查是否已在运行
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" && $pid -gt 0 ]] && kill -0 "$pid" 2>/dev/null; then
            print_message "$YELLOW" "监控服务已在运行 (PID: $pid)"
            return 0
        fi
    fi
    
    # 清理旧的PID文件
    rm -f "$PID_FILE" 2>/dev/null
    
    # 启动服务
    if [[ ! -f "$SERVICE_FILE" ]]; then
        print_message "$RED" "服务脚本不存在: $SERVICE_FILE"
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
        print_message "$CYAN" "日志文件: $LOG_FILE"
        return 0
    else
        print_message "$RED" "✗ 监控服务启动失败"
        rm -f "$PID_FILE"
        return 1
    fi
}

# 停止监控服务
stop_service() {
    print_message "$BLUE" "停止监控服务..."
    
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" && $pid -gt 0 ]]; then
            print_message "$BLUE" "停止进程 (PID: $pid)"
            
            # 温和停止
            kill "$pid" 2>/dev/null
            sleep 2
            
            # 强制停止
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
                sleep 1
            fi
            
            # 最终确认
            if ! kill -0 "$pid" 2>/dev/null; then
                print_message "$GREEN" "✓ 监控服务已停止"
            else
                print_message "$RED" "✗ 无法停止监控服务"
            fi
        fi
        rm -f "$PID_FILE"
    else
        print_message "$YELLOW" "没有运行中的监控服务"
    fi
}

# 检查服务状态
check_service_status() {
    print_message "$BLUE" "检查监控服务状态..."
    
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" && $pid -gt 0 ]] && kill -0 "$pid" 2>/dev/null; then
            print_message "$GREEN" "✓ 监控服务正在运行 (PID: $pid)"
            return 0
        else
            print_message "$RED" "✗ 监控服务未运行 (PID文件存在但进程不存在)"
            rm -f "$PID_FILE"
            return 1
        fi
    else
        print_message "$RED" "✗ 监控服务未运行"
        return 1
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

# 测试连接
test_connection() {
    print_message "$BLUE" "测试连接到监控服务器..."
    load_config

    if [[ -z "$WORKER_URL" || -z "$SERVER_ID" || -z "$API_KEY" ]]; then
        print_message "$RED" "配置不完整，请先配置监控参数"
        return 1
    fi

    # 测试API连接
    local clean_api_key=$(echo "$API_KEY" | tr -d ' \n\r')
    local clean_server_id=$(echo "$SERVER_ID" | tr -d ' \n\r')
    
    print_message "$BLUE" "测试连接到: $WORKER_URL"
    local response=$(curl -s -w "%{http_code}" -X GET "$WORKER_URL/api/health" \
        -H "X-API-Key: $clean_api_key" 2>/dev/null || echo "000")
    
    local http_code="${response: -3}"
    
    if [[ "$http_code" == "200" ]]; then
        print_message "$GREEN" "✓ 连接测试成功"
        return 0
    else
        print_message "$RED" "✗ 连接测试失败 (HTTP $http_code)"
        return 1
    fi
}

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

    # 设置默认上报间隔为10秒
    if [[ -z "$INTERVAL" ]]; then
        INTERVAL="10"
    fi

    # 验证配置
    if [[ -z "$WORKER_URL" || -z "$SERVER_ID" || -z "$API_KEY" ]]; then
        print_message "$RED" "配置不完整，请确保所有必需参数都已填写"
        return 1
    fi

    # 保存配置
    save_config
    print_message "$GREEN" "配置保存成功"
    
    return 0
}

# 安装监控服务
install_monitor() {
    print_message "$BLUE" "开始安装VPS监控服务..."
    echo

    # 检测系统
    detect_system

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

    # 启动服务
    if start_service; then
        print_message "$GREEN" "✓ VPS监控服务安装并启动成功"
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
    print_message "$YELLOW" "警告: 这将删除VPS监控服务及其数据"
    echo -n "确认卸载? (y/N): "
    read -r confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_message "$BLUE" "取消卸载"
        return 0
    fi

    print_message "$BLUE" "开始卸载VPS监控服务..."

    # 停止服务
    stop_service

    # 删除目录
    if [[ -d "$SCRIPT_DIR" ]]; then
        rm -rf "$SCRIPT_DIR"
        print_message "$GREEN" "✓ VPS监控服务已卸载"
    else
        print_message "$YELLOW" "安装目录不存在"
    fi
}

# 一键安装函数（修复版）
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
            -k|--api-key|--key)
                api_key="$2"
                shift 2
                ;;
            -u|--worker-url|--url)
                worker_url="$2"
                shift 2
                ;;
            -i|--install)
                # 忽略这个参数，它只是表示一键安装模式
                shift
                ;;
            *)
                print_message "$RED" "未知参数: $1"
                return 1
                ;;
        esac
    done

    print_message "$BLUE" "开始一键安装VPS监控服务..."
    echo

    # 验证必需参数
    if [[ -z "$server_id" || -z "$api_key" || -z "$worker_url" ]]; then
        print_message "$RED" "错误: 缺少必需参数"
        echo "必需参数:"
        echo "  -s <服务器ID> 或 --server-id <服务器ID>"
        echo "  -k <API密钥> 或 --key <API密钥>"
        echo "  -u <Worker地址> 或 --url <Worker地址>"
        return 1
    fi

    print_message "$CYAN" "安装参数:"
    echo "  服务器ID: $server_id"
    echo "  API密钥: ${api_key:0:8}..."
    echo "  Worker地址: $worker_url"
    echo "  上报间隔: 10秒 (运行后会自动从服务器获取最新配置)"
    echo

    # 检测系统
    detect_system

    # 安装依赖
    install_dependencies || {
        print_message "$YELLOW" "依赖安装失败，尝试继续..."
    }

    # 创建目录结构
    create_directories

    # 设置配置参数
    WORKER_URL="$worker_url"
    SERVER_ID="$server_id"
    API_KEY="$api_key"
    INTERVAL="10"

    # 保存配置
    save_config
    print_message "$GREEN" "配置保存成功"

    # 测试连接
    print_message "$BLUE" "测试连接..."
    local clean_api_key=$(echo "$api_key" | tr -d ' \n\r')
    local clean_server_id=$(echo "$server_id" | tr -d ' \n\r')
    
    local response=$(curl -s -w "%{http_code}" -X GET "$worker_url/api/health" \
        -H "X-API-Key: $clean_api_key" 2>/dev/null || echo "000")
    
    local http_code="${response: -3}"
    
    if [[ "$http_code" == "200" ]]; then
        print_message "$GREEN" "✓ 连接测试成功"
    else
        print_message "$YELLOW" "⚠ 连接测试失败 (HTTP $http_code)，但将继续安装"
    fi

    # 创建服务脚本
    create_service_script

    # 启动服务
    if start_service; then
        print_message "$GREEN" "✓ VPS监控服务一键安装成功"
        echo
        print_message "$CYAN" "安装信息:"
        echo "  安装目录: $SCRIPT_DIR"
        echo "  配置文件: $CONFIG_FILE"
        echo "  日志文件: $LOG_FILE"
        echo "  服务脚本: $SERVICE_FILE"
        echo
        print_message "$YELLOW" "提示: 使用 '$0 status' 检查服务状态"
        print_message "$YELLOW" "提示: 使用 '$0 logs' 查看运行日志"
        return 0
    else
        print_message "$RED" "✗ 服务启动失败"
        return 1
    fi
}

# 显示帮助信息
show_help() {
    echo "VPS监控脚本 v2.1.0"
    echo
    echo "用法: $0 [命令] [选项]"
    echo
    echo "基本命令:"
    echo "  install     安装监控服务"
    echo "  uninstall   卸载监控服务"
    echo "  start       启动监控服务"
    echo "  stop        停止监控服务"
    echo "  restart     重启监控服务"
    echo "  status      查看服务状态"
    echo "  logs        查看运行日志"
    echo "  config      配置监控参数"
    echo "  test        测试连接"
    echo "  help        显示此帮助信息"
    echo
    echo "一键安装 (推荐):"
    echo "  $0 -i -s 服务器ID -k API密钥 -u Worker地址"
    echo "  或"
    echo "  $0 --install --server-id 服务器ID --key API密钥 --url Worker地址"
    echo
    echo "示例:"
    echo "  $0 -i -s hr20js -k 9947e75553434750f9aad401f09b65b41ca76e5204faefa79abb451cb3795baf -u https://mycf-vps.brxrqimy.workers.dev"
    echo "  $0 install              # 交互式安装"
    echo "  $0 status               # 查看服务状态"
    echo "  $0 logs                 # 查看日志"
    echo
    echo "支持的参数:"
    echo "  -i, --install          一键安装模式"
    echo "  -s, --server-id ID     服务器ID"
    echo "  -k, --key KEY          API密钥"
    echo "  -u, --url URL          Worker地址"
}

# 解析命令行参数
parse_arguments() {
    # 如果没有参数，显示帮助
    if [[ $# -eq 0 ]]; then
        show_help
        return 0
    fi

    # 检查是否是一键安装参数
    for arg in "$@"; do
        if [[ "$arg" == "-i" || "$arg" == "--install" ]]; then
            one_click_install "$@"
            return $?
        fi
    done

    # 处理基本命令
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
        help|--help|-h)
            show_help
            ;;
        *)
            print_message "$RED" "未知命令: $1"
            echo
            show_help
            exit 1
            ;;
    esac
}

# 主函数
main() {
    # 首先解析命令行参数
    parse_arguments "$@"
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
