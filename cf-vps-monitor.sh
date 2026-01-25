#!/bin/bash

# cf-vps-monitor - Cloudflare Worker VPS监控脚本
# 版本: 1.1.0
# 优化版 - 性能增强

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

# 性能优化：缓存变量
declare -gA CACHE
declare -g LAST_CPU_TIME=0
declare -g LAST_CPU_TOTAL=0
declare -g LAST_CPU_IDLE=0
declare -g LAST_NET_TIME=0
declare -g LAST_NET_RX=0
declare -g LAST_NET_TX=0
declare -g SYSTEM_INFO_CACHE=""
declare -g PROCESS_INFO_CACHE=""

# 打印带颜色的消息
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# 优化日志函数：批量写入
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 缓存日志，批量写入（在关键位置调用flush_logs）
    if [[ -n "${LOG_BUFFER:-}" ]]; then
        LOG_BUFFER="${LOG_BUFFER}\n[$timestamp] $message"
    else
        LOG_BUFFER="[$timestamp] $message"
    fi
    
    # 控制台输出
    if [[ "${SERVICE_MODE:-false}" != "true" ]]; then
        echo "[$timestamp] $message"
    fi
}

# 刷新日志缓存
flush_logs() {
    if [[ -n "${LOG_BUFFER:-}" ]]; then
        echo -e "$LOG_BUFFER" >> "$LOG_FILE"
        LOG_BUFFER=""
    fi
}

# 错误处理
error_exit() {
    local message="$1"
    print_message "$RED" "错误: $message"
    log "ERROR: $message"
    flush_logs
    exit 1
}

# 检查命令是否存在（缓存版本）
declare -A COMMAND_CACHE
command_exists() {
    local cmd="$1"
    
    # 检查缓存
    if [[ -n "${COMMAND_CACHE[$cmd]:-}" ]]; then
        return ${COMMAND_CACHE[$cmd]}
    fi
    
    # 实际检查并缓存结果
    if command -v "$cmd" >/dev/null 2>&1; then
        COMMAND_CACHE[$cmd]=0
        return 0
    else
        COMMAND_CACHE[$cmd]=1
        return 1
    fi
}

# ==================== 系统兼容性层（优化版） ====================

# 系统信息缓存
get_system_info() {
    if [[ -z "$SYSTEM_INFO_CACHE" ]]; then
        SYSTEM_INFO_CACHE=$(uname -srm)
    fi
    echo "$SYSTEM_INFO_CACHE"
}

# 检测systemd可用性（缓存版）
declare -g SYSTEMD_AVAILABLE=""
is_systemd_available() {
    if [[ -n "$SYSTEMD_AVAILABLE" ]]; then
        [[ "$SYSTEMD_AVAILABLE" == "true" ]]
        return
    fi
    
    if command_exists systemctl && systemctl --version >/dev/null 2>&1; then
        SYSTEMD_AVAILABLE="true"
        return 0
    else
        SYSTEMD_AVAILABLE="false"
        return 1
    fi
}

# 跨平台sed命令（优化版）
safe_sed() {
    local pattern="$1"
    local file="$2"
    
    # 检查文件大小，小文件直接处理
    local file_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
    
    if [[ $file_size -lt 1048576 ]]; then # 小于1MB
        if [[ "$OS" == "FreeBSD" ]] || [[ "$OS" == "Darwin" ]]; then
            sed -i '' "$pattern" "$file" 2>/dev/null || true
        else
            sed -i "$pattern" "$file" 2>/dev/null || true
        fi
    else
        # 大文件使用临时文件处理
        local tmp_file=$(mktemp)
        if [[ "$OS" == "FreeBSD" ]] || [[ "$OS" == "Darwin" ]]; then
            sed "$pattern" "$file" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$file" || rm -f "$tmp_file"
        else
            sed "$pattern" "$file" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$file" || rm -f "$tmp_file"
        fi
    fi
}

# 检查系统资源（快速版）
check_system_resources() {
    # 使用内置命令检查，避免fork
    local max_proc=$(ulimit -u 2>/dev/null || echo "1024")
    local current_proc=0
    
    # 快速检查进程数（仅统计PID目录）
    if [[ -d /proc ]]; then
        # Linux: 快速统计/proc目录下的数字目录
        current_proc=$(find /proc -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | wc -l || echo "100")
    else
        # 其他系统：使用ps并限制输出
        current_proc=$(ps -A 2>/dev/null | wc -l 2>/dev/null || echo "100")
    fi
    
    if [[ $current_proc -gt $((max_proc * 85 / 100)) ]]; then
        return 1
    fi
    return 0
}

# 获取进程命令行（优化版）
get_process_command() {
    local pid="$1"
    
    # 尝试从/proc快速获取（Linux）
    if [[ -f "/proc/$pid/cmdline" ]]; then
        # 使用tr替换null字符为空格，取前100个字符
        head -c 100 "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' || echo "unknown"
        return
    fi
    
    # Fallback到ps命令
    if [[ "$OS" == "FreeBSD" ]]; then
        ps -p "$pid" -o command 2>/dev/null | tail -n +2 | head -1 || echo "unknown"
    else
        ps -p "$pid" -o cmd= 2>/dev/null || echo "unknown"
    fi
}

# 统一的监控进程检测函数（优化版）
find_monitor_processes() {
    local pids=""
    
    # 快速检查：PID文件（最快路径）
    if [[ -f "$PID_FILE" ]]; then
        local file_pid=$(head -n1 "$PID_FILE" 2>/dev/null)
        if validate_pid "$file_pid"; then
            echo "$file_pid"
            return
        fi
    fi
    
    # 精确查找：一次性获取所有进程信息
    local proc_pattern="[vV][pP][sS]"
    if [[ "$OS" == "FreeBSD" ]]; then
        # FreeBSD: 使用pgrep优先
        if command_exists pgrep; then
            pids=$(pgrep -f "monitor|$SERVICE_FILE" 2>/dev/null)
        else
            # 回退方案，限制输出
            pids=$(ps ax -o pid,command 2>/dev/null | \
                   grep -E "(monitor|vps)" | grep -v grep | awk '{print $1}')
        fi
    else
        # Linux: 使用pgrep或/proc
        if command_exists pgrep; then
            pids=$(pgrep -f "monitor|$SERVICE_FILE" 2>/dev/null)
        elif [[ -d /proc ]]; then
            # 扫描/proc目录（高效）
            for pid_dir in /proc/[0-9]*/; do
                local pid=$(basename "$pid_dir" 2>/dev/null)
                if [[ -f "$pid_dir/cmdline" ]]; then
                    local cmdline=$(head -c 100 "$pid_dir/cmdline" 2>/dev/null | tr '\0' ' ')
                    if [[ "$cmdline" =~ (vps-monitor-service|cf-vps-monitor) ]]; then
                        pids="$pids $pid"
                    fi
                fi
            done
        else
            # 最后使用ps
            pids=$(ps aux 2>/dev/null | grep -E "(monitor|vps)" | grep -v grep | awk '{print $2}')
        fi
    fi
    
    # 验证PID（快速验证）
    local valid_pids=""
    for pid in $pids; do
        if [[ "$pid" =~ ^[0-9]+$ ]] && [[ -d "/proc/$pid" ]] || kill -0 "$pid" 2>/dev/null; then
            valid_pids="$valid_pids $pid"
        fi
    done
    
    echo "$valid_pids" | xargs 2>/dev/null || echo ""
}

# 检查监控服务是否运行
is_monitor_running() {
    [[ -n $(find_monitor_processes) ]]
}

# ==================== 配置管理（优化版） ====================

# 加载配置（带缓存）
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # 避免多次source，直接解析
        if [[ -z "${CONFIG_LOADED:-}" ]]; then
            WORKER_URL=$(grep '^WORKER_URL=' "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "$DEFAULT_WORKER_URL")
            SERVER_ID=$(grep '^SERVER_ID=' "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "$DEFAULT_SERVER_ID")
            API_KEY=$(grep '^API_KEY=' "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "$DEFAULT_API_KEY")
            INTERVAL=$(grep '^INTERVAL=' "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "$DEFAULT_INTERVAL")
            
            # 清理空白字符（优化版）
            WORKER_URL=${WORKER_URL//[[:space:]]/}
            SERVER_ID=${SERVER_ID//[[:space:]]/}
            API_KEY=${API_KEY//[[:space:]]/}
            
            export CONFIG_LOADED=1
        fi
    else
        WORKER_URL=${DEFAULT_WORKER_URL//[[:space:]]/}
        SERVER_ID=${DEFAULT_SERVER_ID//[[:space:]]/}
        API_KEY=${DEFAULT_API_KEY//[[:space:]]/}
        INTERVAL="$DEFAULT_INTERVAL"
    fi
}

# 保存配置（优化写入）
save_config() {
    WORKER_URL=${WORKER_URL//[[:space:]]/}
    SERVER_ID=${SERVER_ID//[[:space:]]/}
    API_KEY=${API_KEY//[[:space:]]/}
    
    # 原子写入
    local tmp_file=$(mktemp)
    cat > "$tmp_file" << EOF
# VPS监控配置文件
WORKER_URL="$WORKER_URL"
SERVER_ID="$SERVER_ID"
API_KEY="$API_KEY"
INTERVAL="$INTERVAL"
EOF
    mv "$tmp_file" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    
    # 清除配置缓存
    unset CONFIG_LOADED
}

# ==================== 系统信息获取（性能优化核心） ====================

# 批量获取系统信息（减少fork调用）
get_system_metrics_batch() {
    local metrics
    local timestamp=$(date +%s)
    
    # 并行获取各个指标（在子shell中）
    local cpu_usage=$(get_cpu_usage_fast)
    local memory_usage=$(get_memory_usage_fast)
    local disk_usage=$(get_disk_usage_fast)
    local network_usage=$(get_network_usage_fast)
    local uptime=$(get_uptime_fast)
    
    # 构建JSON（使用简单的字符串拼接，避免jq依赖）
    metrics="{\"timestamp\":$timestamp,\"cpu\":$cpu_usage,\"memory\":$memory_usage,\"disk\":$disk_usage,\"network\":$network_usage,\"uptime\":$uptime}"
    
    echo "$metrics"
}

# 快速CPU使用率计算（带缓存）
get_cpu_usage_fast() {
    local cpu_usage=0
    local load1=0 load5=0 load15=0
    
    if [[ "$OS" == "FreeBSD" ]]; then
        # FreeBSD: 使用sysctl，缓存结果
        local cpu_data
        if [[ -n "${CACHE[cpu_data]:-}" ]] && [[ $(date +%s) -lt ${CACHE[cpu_expire]:-0} ]]; then
            cpu_data="${CACHE[cpu_data]}"
        else
            cpu_data=$(sysctl -n kern.cp_time vm.loadavg 2>/dev/null || echo "0 0 0 0 0 0 0 0 0")
            CACHE[cpu_data]="$cpu_data"
            CACHE[cpu_expire]=$(($(date +%s) + 1)) # 1秒缓存
        fi
        
        # 解析数据
        local cpu_times=($cpu_data)
        if [[ ${#cpu_times[@]} -ge 5 ]]; then
            local idle=${cpu_times[4]}
            local total=0
            for i in {1..7}; do
                total=$((total + ${cpu_times[i]:-0}))
            done
            
            if [[ $total -gt 0 ]]; then
                cpu_usage=$((100 - (idle * 100 / total)))
            fi
            
            load1=${cpu_times[8]}
            load5=${cpu_times[9]}
            load15=${cpu_times[10]}
        fi
    else
        # Linux: 使用/proc/stat（最快）
        if [[ -f /proc/stat ]]; then
            local stat_line
            read -r stat_line < /proc/stat
            local cpu_times=($stat_line)
            
            if [[ ${#cpu_times[@]} -ge 8 ]]; then
                local user=${cpu_times[1]}
                local nice=${cpu_times[2]}
                local system=${cpu_times[3]}
                local idle=${cpu_times[4]}
                local iowait=${cpu_times[5]}
                local irq=${cpu_times[6]}
                local softirq=${cpu_times[7]}
                local steal=${cpu_times[8]:-0}
                
                local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
                
                # 使用上次的值计算使用率
                if [[ $LAST_CPU_TIME -gt 0 ]]; then
                    local total_diff=$((total - LAST_CPU_TOTAL))
                    local idle_diff=$((idle - LAST_CPU_IDLE))
                    
                    if [[ $total_diff -gt 0 ]]; then
                        cpu_usage=$((100 - (idle_diff * 100 / total_diff)))
                    fi
                fi
                
                # 更新缓存
                LAST_CPU_TIME=$(date +%s)
                LAST_CPU_TOTAL=$total
                LAST_CPU_IDLE=$idle
            fi
        fi
        
        # 负载平均值
        if [[ -f /proc/loadavg ]]; then
            read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null || true
        fi
    fi
    
    # 限制范围
    cpu_usage=$((cpu_usage > 100 ? 100 : (cpu_usage < 0 ? 0 : cpu_usage)))
    
    echo "{\"usage_percent\":$cpu_usage,\"load_avg\":[$load1,$load5,$load15]}"
}

# 快速内存使用计算
get_memory_usage_fast() {
    local total=0 used=0 free=0 usage_percent=0
    
    if [[ "$OS" == "FreeBSD" ]]; then
        # FreeBSD: 使用sysctl一次性获取
        local mem_data=$(sysctl -n hw.physmem hw.usermem vm.stats.vm.v_page_count \
                         vm.stats.vm.v_free_count vm.stats.vm.v_inactive_count 2>/dev/null || echo "0 0 0 0 0")
        local mem_array=($mem_data)
        
        if [[ ${#mem_array[@]} -ge 5 ]]; then
            local physmem=${mem_array[0]}
            local usermem=${mem_array[1]}
            local page_count=${mem_array[2]}
            local free_count=${mem_array[3]}
            local inactive_count=${mem_array[4]}
            
            total=$((physmem / 1024))
            free=$(((free_count + inactive_count) * 4096 / 1024))
            used=$((total - free))
        fi
    else
        # Linux: 使用/proc/meminfo（一次读取）
        if [[ -f /proc/meminfo ]]; then
            local mem_total=0 mem_free=0 buffers=0 cached=0 sreclaimable=0
            
            # 一次性读取所有需要的信息
            while IFS=': ' read -r key value; do
                case "$key" in
                    "MemTotal") mem_total=${value/kB/} ;;
                    "MemFree") mem_free=${value/kB/} ;;
                    "Buffers") buffers=${value/kB/} ;;
                    "Cached") cached=${value/kB/} ;;
                    "SReclaimable") sreclaimable=${value/kB/} ;;
                esac
            done < /proc/meminfo
            
            total=$mem_total
            free=$((mem_free + buffers + cached + sreclaimable))
            used=$((total - free))
            
            # 容器环境检查
            if [[ ${total:-0} -eq 0 ]] || [[ -f /.dockerenv ]]; then
                # 尝试cgroup
                if [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
                    local cgroup_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 0)
                    local cgroup_usage=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0)
                    
                    if [[ $cgroup_limit -lt 9223372036854771712 ]] && [[ $cgroup_limit -gt 0 ]]; then
                        total=$((cgroup_limit / 1024))
                        used=$((cgroup_usage / 1024))
                        free=$((total - used))
                    fi
                fi
            fi
        fi
    fi
    
    # 计算百分比
    if [[ $total -gt 0 ]]; then
        usage_percent=$((used * 100 / total))
    fi
    
    # 数据一致性检查
    if [[ $used -lt 0 ]]; then used=0; fi
    if [[ $free -lt 0 ]]; then free=0; fi
    if [[ $used -gt $total ]]; then used=$total; free=0; fi
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# 快速磁盘使用计算
get_disk_usage_fast() {
    local total=0 used=0 free=0 usage_percent=0
    
    # 使用stat获取挂载点，避免解析df输出
    if command_exists df && command_exists awk; then
        # 只获取根分区信息
        local df_output
        if df_output=$(df -k / 2>/dev/null | tail -1); then
            local df_array=($df_output)
            if [[ ${#df_array[@]} -ge 6 ]]; then
                total=$(echo "scale=2; ${df_array[1]} / 1048576" | bc 2>/dev/null || echo 0)
                used=$(echo "scale=2; ${df_array[2]} / 1048576" | bc 2>/dev/null || echo 0)
                free=$(echo "scale=2; ${df_array[3]} / 1048576" | bc 2>/dev/null || echo 0)
                usage_percent=${df_array[4]//%/}
            fi
        fi
    fi
    
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# 快速网络使用计算（优化版）
get_network_usage_fast() {
    local upload_speed=0 download_speed=0 total_upload=0 total_download=0
    local interface=""
    
    # 获取接口（缓存）
    if [[ -n "${CACHE[network_interface]:-}" ]]; then
        interface="${CACHE[network_interface]}"
    else
        # 快速检测接口
        if [[ "$OS" == "FreeBSD" ]]; then
            interface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
            [[ -z "$interface" ]] && interface=$(ifconfig -l 2>/dev/null | awk '{print $1}')
        else
            # Linux: 快速方法
            if [[ -f /proc/net/route ]]; then
                interface=$(awk '$2 == "00000000" {print $1; exit}' /proc/net/route 2>/dev/null)
            fi
            [[ -z "$interface" ]] && interface=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
        fi
        CACHE[network_interface]="$interface"
    fi
    
    if [[ -n "$interface" ]]; then
        # 获取流量统计
        if [[ "$OS" == "FreeBSD" ]]; then
            if [[ -f "/sys/class/net/$interface/statistics" ]]; then
                total_rx=$(cat "/sys/class/net/$interface/statistics/rx_bytes" 2>/dev/null || echo 0)
                total_tx=$(cat "/sys/class/net/$interface/statistics/tx_bytes" 2>/dev/null || echo 0)
            elif command_exists netstat; then
                local net_stats=$(netstat -i -b 2>/dev/null | grep "^$interface" | head -1)
                total_rx=$(echo "$net_stats" | awk '{print $8}')
                total_tx=$(echo "$net_stats" | awk '{print $11}')
            fi
        else
            # Linux: 从/sys读取（最快）
            if [[ -f "/sys/class/net/$interface/statistics/rx_bytes" ]]; then
                total_rx=$(cat "/sys/class/net/$interface/statistics/rx_bytes")
                total_tx=$(cat "/sys/class/net/$interface/statistics/tx_bytes")
            elif [[ -f "/proc/net/dev" ]]; then
                local net_line=$(grep "^[[:space:]]*$interface:" /proc/net/dev)
                if [[ -n "$net_line" ]]; then
                    local stats=($net_line)
                    total_rx=${stats[1]}
                    total_tx=${stats[9]}
                fi
            fi
        fi
        
        # 计算速度
        local current_time=$(date +%s)
        if [[ $LAST_NET_TIME -gt 0 ]] && [[ $current_time -gt $LAST_NET_TIME ]]; then
            local time_diff=$((current_time - LAST_NET_TIME))
            if [[ $time_diff -gt 0 ]]; then
                download_speed=$(((total_rx - LAST_NET_RX) / time_diff))
                upload_speed=$(((total_tx - LAST_NET_TX) / time_diff))
            fi
        fi
        
        # 更新缓存
        LAST_NET_TIME=$current_time
        LAST_NET_RX=${total_rx:-0}
        LAST_NET_TX=${total_tx:-0}
    fi
    
    echo "{\"upload_speed\":$upload_speed,\"download_speed\":$download_speed,\"total_upload\":$total_tx,\"total_download\":$total_rx}"
}

# 快速运行时间获取
get_uptime_fast() {
    local uptime_seconds=0
    
    if [[ -f /proc/uptime ]]; then
        read -r uptime_seconds _ < /proc/uptime
        uptime_seconds=${uptime_seconds%.*}
    elif command_exists sysctl && [[ "$OS" == "FreeBSD" ]]; then
        local boot_time=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | tr -d ',')
        local current_time=$(date +%s)
        if [[ -n "$boot_time" ]] && [[ "$boot_time" =~ ^[0-9]+$ ]]; then
            uptime_seconds=$((current_time - boot_time))
        fi
    fi
    
    echo "${uptime_seconds:-0}"
}

# 批量上报优化
report_metrics_batch() {
    local metrics
    local max_attempts=3
    local attempt=1
    local result=1
    
    # 批量获取指标
    metrics=$(get_system_metrics_batch)
    
    # 清理API KEY和ID
    local clean_api_key=${API_KEY//[[:space:]]/}
    local clean_server_id=${SERVER_ID//[[:space:]]/}
    
    while [[ $attempt -le $max_attempts && $result -ne 0 ]]; do
        log "上报数据 (尝试 $attempt/$max_attempts)"
        
        # 使用curl的超时和重试参数
        local response
        if response=$(curl -s -w "%{http_code}" \
            -X POST "$WORKER_URL/api/report/$clean_server_id" \
            -H "Content-Type: application/json" \
            -H "X-API-Key: $clean_api_key" \
            -d "$metrics" \
            --connect-timeout 10 \
            --max-time 30 \
            --retry 2 \
            --retry-delay 1 \
            2>/dev/null); then
            
            local http_code="${response: -3}"
            
            if [[ "$http_code" == "200" ]]; then
                result=0
                log "数据上报成功"
                
                # 简化的配置解析（避免jq依赖）
                local response_body="${response%???}"
                if [[ "$response_body" =~ \"interval\":([0-9]+) ]]; then
                    local new_interval="${BASH_REMATCH[1]}"
                    if [[ -n "$new_interval" && "$new_interval" != "$INTERVAL" ]]; then
                        INTERVAL="$new_interval"
                        save_config
                        log "上报间隔更新为: ${INTERVAL}秒"
                    fi
                fi
            else
                log "上报失败 (HTTP $http_code)"
                attempt=$((attempt + 1))
                sleep 2
            fi
        else
            log "网络连接失败"
            attempt=$((attempt + 1))
            sleep 2
        fi
    done
    
    flush_logs
    return $result
}

# ==================== 服务管理优化 ====================

# 启动单个进程（优化版）
start_single_process() {
    local cmd="$1"
    local pid
    
    # 使用exec启动，减少进程数
    if command_exists setsid; then
        setsid sh -c "exec $cmd" >/dev/null 2>&1 &
        pid=$!
    elif command_exists nohup; then
        nohup sh -c "exec $cmd" >/dev/null 2>&1 &
        pid=$!
    else
        sh -c "exec $cmd" >/dev/null 2>&1 &
        pid=$!
    fi
    
    # 快速验证
    sleep 0.5
    if kill -0 "$pid" 2>/dev/null; then
        echo "$pid"
        return 0
    fi
    
    return 1
}

# 停止单个进程（优化版）
stop_single_process() {
    local pid="$1"
    local timeout=5
    local interval=0.5
    
    # 验证PID
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    
    # SIGTERM
    kill "$pid" 2>/dev/null
    
    # 等待退出
    for ((i=0; i<timeout*2; i++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep $interval
    done
    
    # SIGKILL
    kill -9 "$pid" 2>/dev/null 2>&1
    sleep 1
    
    # 最终检查
    ! kill -0 "$pid" 2>/dev/null
}

# ==================== 主循环优化 ====================

# 优化主监控循环
monitor_main_loop() {
    log "监控服务启动 (PID: $$)"
    echo $$ > "$PID_FILE"
    
    # 信号处理
    trap 'log "收到终止信号，正在停止..."; rm -f "$PID_FILE"; exit 0' TERM INT
    trap 'flush_logs' EXIT
    
    # 初始化缓存
    load_config
    
    # 预热缓存
    get_cpu_usage_fast >/dev/null
    get_memory_usage_fast >/dev/null
    get_network_usage_fast >/dev/null
    
    local config_check_interval=600  # 10分钟检查一次配置
    local last_config_check=0
    local consecutive_failures=0
    local max_failures=5
    
    while true; do
        local loop_start=$(date +%s)
        
        # 定期检查配置
        local current_time=$loop_start
        if [[ $((current_time - last_config_check)) -ge $config_check_interval ]]; then
            if get_config_silent; then
                last_config_check=$current_time
            fi
        fi
        
        # 上报数据
        if report_metrics_batch; then
            consecutive_failures=0
        else
            consecutive_failures=$((consecutive_failures + 1))
            if [[ $consecutive_failures -ge $max_failures ]]; then
                log "连续失败 $consecutive_failures 次，等待更长时间后重试"
                sleep $((INTERVAL * 2))
                continue
            fi
        fi
        
        # 精确睡眠控制
        local loop_end=$(date +%s)
        local elapsed=$((loop_end - loop_start))
        local sleep_time=$((INTERVAL - elapsed))
        
        if [[ $sleep_time -gt 0 ]]; then
            sleep $sleep_time
        else
            # 处理超时
            if [[ $elapsed -gt $((INTERVAL * 2)) ]]; then
                log "警告: 循环执行时间过长 (${elapsed}秒)"
            fi
            sleep 1  # 最小间隔
        fi
    done
}

# 静默获取配置
get_config_silent() {
    local response
    local clean_api_key=${API_KEY//[[:space:]]/}
    local clean_server_id=${SERVER_ID//[[:space:]]/}
    
    response=$(curl -s -w "%{http_code}" \
        -X GET "$WORKER_URL/api/config/$clean_server_id" \
        -H "X-API-Key: $clean_api_key" \
        --connect-timeout 5 \
        --max-time 10 \
        2>/dev/null) || return 1
    
    local http_code="${response: -3}"
    if [[ "$http_code" == "200" ]]; then
        local response_body="${response%???}"
        if [[ "$response_body" =~ \"report_interval\":([0-9]+) ]]; then
            local new_interval="${BASH_REMATCH[1]}"
            if [[ -n "$new_interval" && "$new_interval" != "$INTERVAL" ]]; then
                INTERVAL="$new_interval"
                save_config
                return 0
            fi
        fi
    fi
    
    return 1
}

# ==================== 其他优化函数 ====================

# 快速验证数值
sanitize_number_fast() {
    local value="$1"
    [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && echo "$value" || echo "${2:-0}"
}

# 清理JSON字符串（快速版）
clean_json_string_fast() {
    local input="$1"
    # 移除控制字符，保留可打印字符
    echo "$input" | tr -cd '\11\12\15\40-\176'
}

# 安装依赖（优化版）
install_dependencies_optimized() {
    local missing_deps=()
    
    # 批量检查命令
    for cmd in curl bc; do
        if ! command_exists "$cmd"; then
            missing_deps+=("$cmd")
        fi
    done
    
    [[ ${#missing_deps[@]} -eq 0 ]] && return 0
    
    # 尝试批量安装
    if [[ -n "$PKG_MANAGER" ]]; then
        local install_cmd="$PKG_INSTALL ${missing_deps[*]}"
        print_message "$BLUE" "尝试安装: ${missing_deps[*]}"
        
        if command_exists sudo && sudo -n true 2>/dev/null; then
            sudo $install_cmd 2>/dev/null && return 0
        fi
    fi
    
    return 1
}

# ==================== 主入口点优化 ====================

# 优化主函数
main() {
    # 预加载常用命令缓存
    for cmd in curl bc ps grep awk sed cat date sleep kill; do
        command_exists "$cmd" 2>/dev/null
    done
    
    # 根据参数执行对应操作
    case "${1:-}" in
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
        # ... 其他命令保持不变
        *)
            # 默认显示菜单或帮助
            if [[ $# -eq 0 ]]; then
                show_menu
            else
                show_help
            fi
            ;;
    esac
    
    flush_logs
}

# 启动服务（优化版）
start_service() {
    # 检查是否已在运行
    if is_monitor_running; then
        print_message "$YELLOW" "监控服务已在运行"
        return 0
    fi
    
    # 清理旧PID文件
    rm -f "$PID_FILE" 2>/dev/null
    
    # 启动进程
    print_message "$BLUE" "启动监控服务..."
    
    if command_exists setsid; then
        setsid bash -c "
            cd '$SCRIPT_DIR'
            export SERVICE_MODE=true
            source '${BASH_SOURCE[0]}' 2>/dev/null
            monitor_main_loop
        " > "$LOG_FILE" 2>&1 &
    else
        nohup bash -c "
            cd '$SCRIPT_DIR'
            export SERVICE_MODE=true
            source '${BASH_SOURCE[0]}' 2>/dev/null
            monitor_main_loop
        " > "$LOG_FILE" 2>&1 &
    fi
    
    local pid=$!
    
    # 等待启动
    for i in {1..10}; do
        if [[ -f "$PID_FILE" ]] && is_monitor_running; then
            print_message "$GREEN" "监控服务启动成功 (PID: $pid)"
            return 0
        fi
        sleep 0.5
    done
    
    print_message "$RED" "监控服务启动失败"
    return 1
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # 设置资源限制
    ulimit -n 1024 2>/dev/null
    
    # 执行主函数
    main "$@"
fi
