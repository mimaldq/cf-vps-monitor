#!/bin/bash

# cf-vps-monitor - Cloudflare Worker VPS监控脚本
# 版本: 2.0.0
# 优化版 - 更简洁、高效、安全

set -euo pipefail

# ==================== 全局配置 ====================
readonly VERSION="2.0.0"
readonly SCRIPT_NAME="cf-vps-monitor"

# 颜色定义（使用printf更安全）
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# 目录结构
readonly BASE_DIR="$HOME/.cf-vps-monitor"
readonly DIR_STRUCTURE=(
    "bin"
    "config"
    "logs"
    "cache"
    "run"
    "tmp"
    "system/backups"
    "system/templates"
)

# 文件路径
readonly CONFIG_FILE="$BASE_DIR/config/monitor.conf"
readonly LOG_FILE="$BASE_DIR/logs/monitor.log"
readonly PID_FILE="$BASE_DIR/run/monitor.pid"
readonly SERVICE_FILE="$BASE_DIR/bin/monitor-service.sh"
readonly INSTALL_LOG="$BASE_DIR/system/install.log"
readonly SCRIPT_PID="$$"

# 默认配置
readonly DEFAULT_INTERVAL=10
readonly MAX_LOG_SIZE=10485760  # 10MB
readonly MAX_LOG_FILES=5

# ==================== 核心工具函数 ====================

# 安全的颜色输出
print_message() {
    local color="$1"
    local message="$2"
    printf "%b%s%b\n" "$color" "$message" "$NC"
}

# 带时间戳的日志记录
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 检查日志轮转
    check_log_rotation
    
    # 写入日志文件
    printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE"
    
    # 控制台输出（非服务模式）
    [[ "${SERVICE_MODE:-false}" != "true" ]] && \
        printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message"
}

# 错误处理
error_exit() {
    local message="$1"
    print_message "$RED" "错误: $message"
    log "ERROR" "$message"
    exit 1
}

# 清理字符串
trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# 验证数字
is_number() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

# 验证整数
is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# 验证URL格式
validate_url() {
    local url="$1"
    [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(/[a-zA-Z0-9./_-]*)?$ ]]
}

# 检查命令是否存在
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# ==================== 系统检测 ====================

# 检测操作系统
detect_os() {
    local os_info
    os_info=$(uname -s 2>/dev/null || echo "Unknown")
    
    case "$os_info" in
        Linux*)     OS="linux" ;;
        Darwin*)    OS="macos" ;;
        FreeBSD*)   OS="freebsd" ;;
        OpenBSD*)   OS="openbsd" ;;
        NetBSD*)    OS="netbsd" ;;
        *)          OS="unknown" ;;
    esac
    
    export OS
    log "INFO" "检测到操作系统: $OS"
}

# 检测包管理器
detect_pkg_manager() {
    local managers=(
        "apt apt-get install -y"
        "dnf dnf install -y"
        "yum yum install -y"
        "pacman pacman -S --noconfirm"
        "apk apk add"
        "brew brew install"
        "pkg pkg install -y"
        "zypper zypper install -y"
    )
    
    for manager in "${managers[@]}"; do
        local name cmd
        name=$(echo "$manager" | awk '{print $1}')
        cmd=$(echo "$manager" | awk '{print $2}')
        
        if has_command "$name"; then
            PKG_MANAGER="$name"
            PKG_INSTALL="$cmd"
            log "INFO" "检测到包管理器: $PKG_MANAGER"
            export PKG_MANAGER PKG_INSTALL
            return 0
        fi
    done
    
    log "WARN" "未检测到包管理器"
    return 1
}

# ==================== 文件系统管理 ====================

# 创建目录结构
create_dirs() {
    log "INFO" "创建目录结构..."
    
    for dir in "${DIR_STRUCTURE[@]}"; do
        local full_path="$BASE_DIR/$dir"
        [[ -d "$full_path" ]] || mkdir -p "$full_path"
    done
    
    # 设置安全的目录权限
    chmod 700 "$BASE_DIR"
    chmod 755 "$BASE_DIR/bin"
    chmod 700 "$BASE_DIR/config"
    chmod 755 "$BASE_DIR/logs"
}

# 日志轮转
check_log_rotation() {
    [[ -f "$LOG_FILE" ]] || return 0
    
    local log_size
    log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)
    
    if [[ $log_size -gt $MAX_LOG_SIZE ]]; then
        log "INFO" "日志文件过大 ($log_size bytes)，执行轮转"
        
        # 删除最旧的日志
        [[ -f "$LOG_FILE.$MAX_LOG_FILES" ]] && rm -f "$LOG_FILE.$MAX_LOG_FILES"
        
        # 轮转现有日志
        for ((i=MAX_LOG_FILES-1; i>=0; i--)); do
            [[ -f "$LOG_FILE.$i" ]] && mv "$LOG_FILE.$i" "$LOG_FILE.$((i+1))"
        done
        
        mv "$LOG_FILE" "$LOG_FILE.0"
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi
}

# 安全的文件写入
safe_write() {
    local file="$1"
    local content="$2"
    local tmp_file
    
    tmp_file="$(mktemp "$BASE_DIR/tmp/.tmp.XXXXXX")"
    printf '%s' "$content" > "$tmp_file"
    
    # 验证文件内容
    if [[ -s "$tmp_file" ]]; then
        mv "$tmp_file" "$file"
        chmod 600 "$file" 2>/dev/null || chmod 644 "$file"
    else
        rm -f "$tmp_file"
        return 1
    fi
}

# ==================== 配置管理 ====================

# 加载配置
load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    
    # 使用安全的source方法
    local config_content
    config_content=$(< "$CONFIG_FILE")
    
    # 解析配置
    while IFS='=' read -r key value; do
        key=$(trim "$key")
        value=$(trim "$value" | sed "s/^['\"]//;s/['\"]$//")
        
        case "$key" in
            WORKER_URL) WORKER_URL="$value" ;;
            SERVER_ID) SERVER_ID="$value" ;;
            API_KEY) API_KEY="$value" ;;
            INTERVAL) INTERVAL="$value" ;;
        esac
    done <<< "$config_content"
    
    # 设置默认值
    INTERVAL=${INTERVAL:-$DEFAULT_INTERVAL}
    
    # 验证配置
    validate_config
}

# 验证配置
validate_config() {
    local errors=()
    
    [[ -n "$WORKER_URL" ]] || errors+=("WORKER_URL 未设置")
    [[ -n "$SERVER_ID" ]] || errors+=("SERVER_ID 未设置")
    [[ -n "$API_KEY" ]] || errors+=("API_KEY 未设置")
    
    if [[ -n "$WORKER_URL" ]] && ! validate_url "$WORKER_URL"; then
        errors+=("WORKER_URL 格式无效: $WORKER_URL")
    fi
    
    if [[ -n "$INTERVAL" ]] && ! is_integer "$INTERVAL"; then
        errors+=("INTERVAL 必须是整数: $INTERVAL")
    fi
    
    [[ ${#errors[@]} -eq 0 ]] || {
        log "ERROR" "配置验证失败: ${errors[*]}"
        return 1
    }
}

# 保存配置
save_config() {
    local config_content
    config_content=$(cat << EOF
# cf-vps-monitor 配置文件
# 生成时间: $(date)

WORKER_URL="$WORKER_URL"
SERVER_ID="$SERVER_ID"
API_KEY="$API_KEY"
INTERVAL="$INTERVAL"
EOF
)
    
    if safe_write "$CONFIG_FILE" "$config_content"; then
        log "INFO" "配置已保存到 $CONFIG_FILE"
        return 0
    else
        log "ERROR" "保存配置失败"
        return 1
    fi
}

# ==================== 依赖管理 ====================

# 安装依赖
install_deps() {
    local required=("curl" "bc")
    local optional=("jq" "ifstat")
    local missing=()
    
    log "INFO" "检查系统依赖..."
    
    # 检查必需依赖
    for cmd in "${required[@]}"; do
        has_command "$cmd" || missing+=("$cmd")
    done
    
    # 检查可选依赖
    for cmd in "${optional[@]}"; do
        has_command "$cmd" || log "WARN" "可选依赖未安装: $cmd"
    done
    
    # 如果没有缺失的依赖
    [[ ${#missing[@]} -eq 0 ]] && {
        log "INFO" "所有必需依赖已安装"
        return 0
    }
    
    log "WARN" "缺少依赖: ${missing[*]}"
    
    # 尝试自动安装
    if [[ -n "$PKG_MANAGER" ]]; then
        log "INFO" "尝试使用 $PKG_MANAGER 安装依赖..."
        
        # 构建安装命令
        local install_cmd="$PKG_INSTALL ${missing[*]}"
        
        # 如果有sudo权限
        if [[ $EUID -eq 0 ]]; then
            eval "$install_cmd" >/dev/null 2>&1
        elif has_command sudo; then
            sudo $install_cmd >/dev/null 2>&1
        else
            log "ERROR" "需要root权限安装依赖"
            return 1
        fi
        
        # 验证安装结果
        local failed=()
        for cmd in "${missing[@]}"; do
            has_command "$cmd" || failed+=("$cmd")
        done
        
        [[ ${#failed[@]} -eq 0 ]] || {
            log "ERROR" "安装失败: ${failed[*]}"
            return 1
        }
        
        log "INFO" "依赖安装完成"
        return 0
    fi
    
    log "ERROR" "无法自动安装依赖，请手动安装: ${missing[*]}"
    return 1
}

# ==================== 进程管理 ====================

# 查找监控进程
find_monitor_pids() {
    local pids=()
    
    # 通过PID文件
    [[ -f "$PID_FILE" ]] && {
        local pid
        pid=$(< "$PID_FILE")
        [[ -n "$pid" && $pid -gt 0 ]] && {
            if kill -0 "$pid" 2>/dev/null; then
                pids+=("$pid")
            else
                rm -f "$PID_FILE"
            fi
        }
    }
    
    # 通过进程名
    if [[ ${#pids[@]} -eq 0 ]]; then
        local cmd_pattern="($SERVICE_FILE|cf-vps-monitor)"
        
        if [[ "$OS" == "linux" ]]; then
            pids=($(pgrep -f "$cmd_pattern" 2>/dev/null || echo ""))
        elif [[ "$OS" == "freebsd" ]]; then
            pids=($(ps aux | grep -E "$cmd_pattern" | grep -v grep | awk '{print $2}' 2>/dev/null || echo ""))
        fi
    fi
    
    # 排除当前脚本
    local filtered_pids=()
    for pid in "${pids[@]}"; do
        [[ $pid -ne $SCRIPT_PID ]] && filtered_pids+=("$pid")
    done
    
    echo "${filtered_pids[@]}"
}

# 检查服务状态
is_running() {
    local pids=($(find_monitor_pids))
    [[ ${#pids[@]} -gt 0 ]]
}

# 停止服务
stop_service() {
    log "INFO" "停止监控服务..."
    
    # 获取所有进程
    local pids=($(find_monitor_pids))
    
    if [[ ${#pids[@]} -eq 0 ]]; then
        print_message "$YELLOW" "监控服务未运行"
        return 0
    fi
    
    # 停止每个进程
    local stopped=0
    for pid in "${pids[@]}"; do
        log "INFO" "停止进程 $pid"
        
        # 发送SIGTERM
        if kill -TERM "$pid" 2>/dev/null; then
            sleep 1
            if kill -0 "$pid" 2>/dev/null; then
                # 强制终止
                kill -KILL "$pid" 2>/dev/null && {
                    log "INFO" "进程 $pid 已强制终止"
                    ((stopped++))
                }
            else
                log "INFO" "进程 $pid 已终止"
                ((stopped++))
            fi
        fi
    done
    
    # 清理PID文件
    rm -f "$PID_FILE" 2>/dev/null
    
    [[ $stopped -gt 0 ]] && {
        print_message "$GREEN" "✓ 监控服务已停止"
        return 0
    }
    
    print_message "$RED" "停止服务失败"
    return 1
}

# 启动服务
start_service() {
    log "INFO" "启动监控服务..."
    
    # 检查是否已在运行
    if is_running; then
        print_message "$YELLOW" "监控服务已在运行"
        return 0
    fi
    
    # 检查服务脚本
    [[ -x "$SERVICE_FILE" ]] || {
        print_message "$RED" "服务脚本不存在或不可执行: $SERVICE_FILE"
        return 1
    }
    
    # 清理旧的PID文件
    rm -f "$PID_FILE" 2>/dev/null
    
    # 启动服务
    if nohup "$SERVICE_FILE" >> "$LOG_FILE" 2>&1 & then
        local pid=$!
        echo "$pid" > "$PID_FILE"
        sleep 1
        
        if kill -0 "$pid" 2>/dev/null; then
            print_message "$GREEN" "✓ 监控服务已启动 (PID: $pid)"
            setup_autostart
            return 0
        fi
    fi
    
    print_message "$RED" "启动服务失败"
    return 1
}

# ==================== 服务脚本生成 ====================

# 生成服务脚本
create_service_script() {
    log "INFO" "生成服务脚本..."
    
    local script_content
    script_content=$(cat << 'EOF'
#!/bin/bash

# cf-vps-monitor 服务脚本
set -euo pipefail

# 导入配置
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$BASE_DIR/config/monitor.conf"
LOG_FILE="$BASE_DIR/logs/monitor.log"
PID_FILE="$BASE_DIR/run/monitor.pid"

# 服务模式标志
export SERVICE_MODE=true

# 加载配置
load_config() {
    [[ -f "$CONFIG_FILE" ]] || exit 1
    
    while IFS='=' read -r key value; do
        key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(echo "$value" | sed "s/^['\"]//;s/['\"]$//")
        
        case "$key" in
            WORKER_URL) WORKER_URL="$value" ;;
            SERVER_ID) SERVER_ID="$value" ;;
            API_KEY) API_KEY="$value" ;;
            INTERVAL) INTERVAL="$value" ;;
        esac
    done < "$CONFIG_FILE"
    
    INTERVAL=${INTERVAL:-10}
}

# 日志函数
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE"
}

# 获取CPU使用率
get_cpu_usage() {
    local cpu_usage=0
    
    if [[ -f /proc/stat ]]; then
        local cpu_line
        cpu_line=$(head -n1 /proc/stat)
        local cpu_times=($cpu_line)
        
        if [[ ${#cpu_times[@]} -ge 5 ]]; then
            local idle=${cpu_times[4]}
            local total=0
            
            for i in {1..4}; do
                [[ -n "${cpu_times[i]}" ]] && total=$((total + cpu_times[i]))
            done
            
            [[ $total -gt 0 ]] && {
                cpu_usage=$(echo "scale=1; 100 - ($idle * 100 / $total)" | bc 2>/dev/null || echo "0")
            }
        fi
    fi
    
    echo "${cpu_usage:-0}"
}

# 获取内存使用率
get_memory_usage() {
    local mem_usage=0
    
    if [[ -f /proc/meminfo ]]; then
        local mem_total mem_available
        mem_total=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}')
        mem_available=$(grep "^MemAvailable:" /proc/meminfo | awk '{print $2}')
        
        if [[ -n "$mem_total" && -n "$mem_available" && $mem_total -gt 0 ]]; then
            mem_usage=$(echo "scale=1; ($mem_total - $mem_available) * 100 / $mem_total" | bc 2>/dev/null || echo "0")
        fi
    fi
    
    echo "${mem_usage:-0}"
}

# 获取磁盘使用率
get_disk_usage() {
    local disk_usage=0
    
    if command -v df >/dev/null 2>&1; then
        disk_usage=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d '%' | tr -d ' ')
    fi
    
    echo "${disk_usage:-0}"
}

# 上报数据
report_data() {
    local cpu_usage disk_usage mem_usage uptime
    cpu_usage=$(get_cpu_usage)
    mem_usage=$(get_memory_usage)
    disk_usage=$(get_disk_usage)
    uptime=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")
    
    local json_data
    json_data=$(cat << EOD
{
    "server_id": "$SERVER_ID",
    "timestamp": $(date +%s),
    "metrics": {
        "cpu": $cpu_usage,
        "memory": $mem_usage,
        "disk": $disk_usage
    },
    "uptime": $uptime
}
EOD
)
    
    local response http_code
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "$WORKER_URL/api/report" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: $API_KEY" \
        -d "$json_data" 2>/dev/null || echo "000")
    
    http_code=$(echo "$response" | tail -1)
    local response_body="${response%$'\n'*}"
    
    if [[ "$http_code" == "200" ]]; then
        log "INFO" "数据上报成功"
        # 尝试获取新的上报间隔
        local new_interval
        new_interval=$(echo "$response_body" | grep -o '"interval":[0-9]*' | cut -d: -f2)
        [[ -n "$new_interval" && "$new_interval" =~ ^[0-9]+$ && "$new_interval" -ne "$INTERVAL" ]] && {
            INTERVAL="$new_interval"
            echo "INTERVAL=$INTERVAL" >> "$CONFIG_FILE"
            log "INFO" "更新上报间隔为: ${INTERVAL}秒"
        }
        return 0
    else
        log "ERROR" "数据上报失败 (HTTP $http_code)"
        return 1
    fi
}

# 主循环
main() {
    trap 'log "INFO" "服务停止"; rm -f "$PID_FILE"; exit 0' TERM INT
    
    load_config || {
        log "ERROR" "加载配置失败"
        exit 1
    }
    
    echo $$ > "$PID_FILE"
    log "INFO" "监控服务启动 (PID: $$)"
    
    local config_counter=0
    local config_check_interval=5  # 每5个周期检查一次配置
    
    while true; do
        # 定期重新加载配置
        if [[ $config_counter -ge $config_check_interval ]]; then
            load_config
            config_counter=0
        fi
        ((config_counter++))
        
        # 上报数据
        if report_data; then
            sleep "$INTERVAL"
        else
            sleep 30  # 失败后等待更长时间
        fi
    done
}

# 启动主函数
main "$@"
EOF
)
    
    if safe_write "$SERVICE_FILE" "$script_content"; then
        chmod +x "$SERVICE_FILE"
        log "INFO" "服务脚本已生成: $SERVICE_FILE"
        return 0
    else
        log "ERROR" "生成服务脚本失败"
        return 1
    fi
}

# ==================== 自启动管理 ====================

# 设置自启动
setup_autostart() {
    log "INFO" "配置自启动..."
    
    # 1. systemd (首选)
    if setup_systemd_service; then
        log "INFO" "systemd自启动已配置"
        return 0
    fi
    
    # 2. crontab (备选)
    if setup_crontab; then
        log "INFO" "crontab自启动已配置"
        return 0
    fi
    
    # 3. rc.local (FreeBSD/Linux传统)
    if setup_rclocal; then
        log "INFO" "rc.local自启动已配置"
        return 0
    fi
    
    log "WARN" "无法配置自启动"
    return 1
}

# 配置systemd服务
setup_systemd_service() {
    [[ $EUID -eq 0 ]] && local service_dir="/etc/systemd/system" \
                     || local service_dir="$HOME/.config/systemd/user"
    
    [[ -d "$service_dir" ]] || mkdir -p "$service_dir"
    
    local service_file="$service_dir/cf-vps-monitor.service"
    
    local service_content
    service_content=$(cat << EOF
[Unit]
Description=CF VPS Monitor
After=network.target

[Service]
Type=simple
ExecStart=$SERVICE_FILE
Restart=always
RestartSec=10
User=$USER
WorkingDirectory=$BASE_DIR

[Install]
WantedBy=default.target
EOF
)
    
    if safe_write "$service_file" "$service_content"; then
        if [[ $EUID -eq 0 ]]; then
            systemctl daemon-reload 2>/dev/null
            systemctl enable cf-vps-monitor.service 2>/dev/null
        else
            systemctl --user daemon-reload 2>/dev/null
            systemctl --user enable cf-vps-monitor.service 2>/dev/null
        fi
        return 0
    fi
    return 1
}

# 配置crontab
setup_crontab() {
    has_command crontab || return 1
    
    local crontab_entry="@reboot sleep 30 && $SERVICE_FILE 2>&1 | logger -t cf-vps-monitor"
    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || echo "")
    
    # 检查是否已存在
    echo "$current_crontab" | grep -q "$SERVICE_FILE" && return 0
    
    # 添加新条目
    (echo "$current_crontab"; echo "$crontab_entry") | crontab - 2>/dev/null
    [[ $? -eq 0 ]]
}

# 配置rc.local
setup_rclocal() {
    local rc_file
    case "$OS" in
        linux)   rc_file="/etc/rc.local" ;;
        freebsd) rc_file="/etc/rc.local" ;;
        *)       return 1 ;;
    esac
    
    [[ -f "$rc_file" ]] || return 1
    
    # 检查是否已存在
    grep -q "$SERVICE_FILE" "$rc_file" && return 0
    
    # 添加启动命令
    local entry="su - $USER -c '$SERVICE_FILE &'"
    echo "$entry" >> "$rc_file"
    chmod +x "$rc_file" 2>/dev/null
    return 0
}

# ==================== 配置向导 ====================

# 交互式配置
interactive_config() {
    print_message "$CYAN" "=== VPS监控配置向导 ==="
    echo
    
    # 加载现有配置
    load_config 2>/dev/null
    
    # Worker URL
    while true; do
        echo -n "请输入Worker URL"
        [[ -n "$WORKER_URL" ]] && echo -n " [当前: $WORKER_URL]"
        echo -n ": "
        read -r input_url
        
        [[ -n "$input_url" ]] && WORKER_URL="$input_url"
        
        if validate_url "$WORKER_URL"; then
            break
        else
            print_message "$RED" "URL格式无效，请重新输入"
        fi
    done
    
    # Server ID
    while true; do
        echo -n "请输入Server ID"
        [[ -n "$SERVER_ID" ]] && echo -n " [当前: $SERVER_ID]"
        echo -n ": "
        read -r input_id
        
        [[ -n "$input_id" ]] && SERVER_ID="$input_id"
        
        [[ -n "$SERVER_ID" ]] && break
        print_message "$RED" "Server ID不能为空"
    done
    
    # API Key
    while true; do
        echo -n "请输入API Key"
        [[ -n "$API_KEY" ]] && echo -n " [当前: ${API_KEY:0:8}...]"
        echo -n ": "
        read -r input_key
        
        [[ -n "$input_key" ]] && API_KEY="$input_key"
        
        [[ ${#API_KEY} -ge 8 ]] && break
        print_message "$RED" "API Key至少需要8个字符"
    done
    
    # 保存配置
    if save_config; then
        print_message "$GREEN" "✓ 配置保存成功"
        return 0
    else
        print_message "$RED" "配置保存失败"
        return 1
    fi
}

# ==================== 测试功能 ====================

# 测试连接
test_connection() {
    load_config || {
        print_message "$RED" "配置未找到或无效"
        return 1
    }
    
    print_message "$BLUE" "测试连接到监控服务器..."
    
    # 测试网络连接
    if ping -c 1 -W 2 "$(echo "$WORKER_URL" | sed 's|https*://||;s|/.*||')" >/dev/null 2>&1; then
        print_message "$GREEN" "✓ 网络连接正常"
    else
        print_message "$YELLOW" "⚠ 网络连接异常"
    fi
    
    # 测试API连接
    local response http_code
    response=$(curl -s -w "\n%{http_code}" \
        -X GET "$WORKER_URL/api/health" \
        -H "X-API-Key: $API_KEY" 2>/dev/null || echo "000")
    
    http_code=$(echo "$response" | tail -1)
    
    case "$http_code" in
        200)
            print_message "$GREEN" "✓ API连接正常"
            return 0
            ;;
        401|403)
            print_message "$RED" "✗ 认证失败 (HTTP $http_code)"
            return 1
            ;;
        404)
            print_message "$RED" "✗ 接口不存在 (HTTP $http_code)"
            return 1
            ;;
        000)
            print_message "$RED" "✗ 网络错误"
            return 1
            ;;
        *)
            print_message "$YELLOW" "⚠ 服务器响应异常 (HTTP $http_code)"
            return 1
            ;;
    esac
}

# ==================== 状态显示 ====================

# 显示服务状态
show_status() {
    print_message "$CYAN" "=== VPS监控服务状态 ==="
    echo
    
    # 检查服务运行状态
    if is_running; then
        local pids=($(find_monitor_pids))
        print_message "$GREEN" "✓ 监控服务正在运行"
        echo "  进程数: ${#pids[@]}"
        echo "  主PID: ${pids[0]:-无}"
    else
        print_message "$RED" "✗ 监控服务未运行"
    fi
    
    # 显示配置信息
    echo
    print_message "$CYAN" "配置信息:"
    if load_config 2>/dev/null; then
        echo "  Worker URL: $WORKER_URL"
        echo "  Server ID: $SERVER_ID"
        echo "  API Key: ${API_KEY:0:8}..."
        echo "  上报间隔: ${INTERVAL}秒"
    else
        echo "  配置未找到"
    fi
    
    # 显示文件状态
    echo
    print_message "$CYAN" "文件状态:"
    local files=(
        "$CONFIG_FILE"
        "$SERVICE_FILE"
        "$LOG_FILE"
        "$PID_FILE"
    )
    
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            local size
            size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
            echo "  ✓ $(basename "$file"): $(numfmt --to=iec $size 2>/dev/null || echo "${size}B")"
        else
            echo "  ✗ $(basename "$file"): 不存在"
        fi
    done
}

# 查看日志
show_logs() {
    [[ -f "$LOG_FILE" ]] || {
        print_message "$YELLOW" "日志文件不存在"
        return 1
    }
    
    print_message "$CYAN" "=== 最近日志 ==="
    tail -50 "$LOG_FILE"
    echo
    print_message "$CYAN" "完整日志: $LOG_FILE"
}

# ==================== 安装/卸载 ====================

# 安装监控服务
install_service() {
    print_message "$CYAN" "开始安装VPS监控服务..."
    echo
    
    # 检测系统
    detect_os
    detect_pkg_manager
    
    # 创建目录
    create_dirs
    
    # 安装依赖
    install_deps || {
        print_message "$YELLOW" "依赖安装失败，继续安装..."
    }
    
    # 配置
    interactive_config || {
        error_exit "配置失败"
    }
    
    # 生成服务脚本
    create_service_script || {
        error_exit "生成服务脚本失败"
    }
    
    # 启动服务
    start_service || {
        error_exit "启动服务失败"
    }
    
    print_message "$GREEN" "✓ VPS监控服务安装完成"
    echo
    print_message "$CYAN" "安装信息:"
    echo "  配置目录: $BASE_DIR"
    echo "  服务脚本: $SERVICE_FILE"
    echo "  日志文件: $LOG_FILE"
    echo "  查看状态: $0 status"
    echo "  查看日志: $0 logs"
}

# 卸载监控服务
uninstall_service() {
    print_message "$YELLOW" "警告: 这将卸载VPS监控服务"
    echo -n "确认卸载? (y/N): "
    read -r confirm
    
    [[ "$confirm" =~ ^[Yy]$ ]] || {
        print_message "$BLUE" "取消卸载"
        return 0
    }
    
    # 停止服务
    stop_service
    
    # 清理文件
    print_message "$BLUE" "清理文件..."
    
    local files_to_remove=(
        "$BASE_DIR"
        "/etc/systemd/system/cf-vps-monitor.service"
        "$HOME/.config/systemd/user/cf-vps-monitor.service"
    )
    
    for file in "${files_to_remove[@]}"; do
        [[ -e "$file" ]] && {
            rm -rf "$file"
            print_message "$GREEN" "  已删除: $file"
        }
    done
    
    # 清理crontab
    if has_command crontab; then
        local current_crontab
        current_crontab=$(crontab -l 2>/dev/null || echo "")
        if echo "$current_crontab" | grep -q "$SERVICE_FILE"; then
            echo "$current_crontab" | grep -v "$SERVICE_FILE" | crontab -
            print_message "$GREEN" "  已清理crontab条目"
        fi
    fi
    
    print_message "$GREEN" "✓ VPS监控服务已卸载"
}

# ==================== 主函数 ====================

# 显示帮助
show_help() {
    cat << EOF
VPS监控脚本 v$VERSION

用法: $0 <命令> [选项]

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
  help        显示此帮助

选项:
  --url URL       设置Worker URL
  --id ID         设置Server ID
  --key KEY       设置API Key
  --interval N    设置上报间隔(秒)

示例:
  $0 install                    # 交互式安装
  $0 config                     # 重新配置
  $0 status                     # 查看状态
  $0 test                       # 测试连接

快速安装:
  $0 install --url https://worker.example.com \\
             --id server123 \\
             --key your_api_key_here
EOF
}

# 处理命令行参数
parse_args() {
    local action=""
    local quick_install=0
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|uninstall|start|stop|restart|status|logs|config|test|help)
                action="$1"
                shift
                ;;
            --url)
                WORKER_URL="$2"
                quick_install=1
                shift 2
                ;;
            --id)
                SERVER_ID="$2"
                quick_install=1
                shift 2
                ;;
            --key)
                API_KEY="$2"
                quick_install=1
                shift 2
                ;;
            --interval)
                INTERVAL="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                print_message "$RED" "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 快速安装
    if [[ $quick_install -eq 1 ]] && [[ -n "$WORKER_URL" ]] && [[ -n "$SERVER_ID" ]] && [[ -n "$API_KEY" ]]; then
        create_dirs
        save_config
        create_service_script
        start_service
        exit $?
    fi
    
    [[ -z "$action" ]] && {
        print_message "$RED" "请指定操作命令"
        show_help
        exit 1
    }
    
    # 执行对应操作
    case "$action" in
        install)    install_service ;;
        uninstall)  uninstall_service ;;
        start)      start_service ;;
        stop)       stop_service ;;
        restart)    stop_service; sleep 1; start_service ;;
        status)     show_status ;;
        logs)       show_logs ;;
        config)     interactive_config ;;
        test)       test_connection ;;
        help)       show_help ;;
    esac
}

# 脚本入口
main() {
    # 初始化
    detect_os
    create_dirs
    
    # 记录启动日志
    log "INFO" "脚本启动: $0 $*"
    
    # 解析参数
    parse_args "$@"
}

# 运行主函数
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
