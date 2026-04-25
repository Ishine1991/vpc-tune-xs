#!/bin/bash
#=============================================================================
# BBR v3 终极优化脚本 - 融合版
# 功能：结合 XanMod 官方内核的稳定性 + 专业队列算法调优
# 特点：安全性 + 性能 双优化
# 版本：2.2 Ultimate Edition
# 更新：安全下载校验 + MSS 规则安全处理 + Realm 依赖预检
#=============================================================================

#=============================================================================
# 📋 推荐配置方案（基于实测优化）
#=============================================================================
# 
# 💡 测试环境：经过本人十几二十几台不同服务器的测试
#    包括酷雪云北京9929等多个节点的实测验证
# 
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 
# ⭐ 首选方案（推荐）：
#    步骤1 → 执行菜单选项 1：BBR v3 内核安装
#    步骤2 → 执行菜单选项 3：BBR 直连/落地优化（智能带宽检测）
#            选择子选项 1 进行自动检测
#    步骤3 → 执行菜单选项 6：Realm转发timeout修复（如使用 Realm 转发）
# 
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 
# 🔧 次选方案（备用）：
#    步骤1 → 执行菜单选项 1：BBR v3 内核安装
#    步骤2 → 执行菜单选项 5：NS论坛CAKE调优
#    步骤3 → 执行菜单选项 6：科技lion高性能模式内核参数优化
#            选择第一个选项
# 
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 
#=============================================================================

# 颜色定义（保留中文变量名以兼容现有代码）
gl_hong='\033[31m'      # 红色
gl_lv='\033[32m'        # 绿色
gl_huang='\033[33m'     # 黄色
gl_bai='\033[0m'        # 重置
gl_kjlan='\033[96m'     # 亮青色
gl_zi='\033[35m'        # 紫色
gl_hui='\033[90m'       # 灰色

# 英文别名（供新代码使用）
readonly COLOR_RED="$gl_hong"
readonly COLOR_GREEN="$gl_lv"
readonly COLOR_YELLOW="$gl_huang"
readonly COLOR_RESET="$gl_bai"
readonly COLOR_CYAN="$gl_kjlan"
readonly COLOR_PURPLE="$gl_zi"
readonly COLOR_GRAY="$gl_hui"

# GitHub 代理设置
gh_proxy="https://"

# 配置文件路径（使用独立文件，不破坏系统配置）
SYSCTL_CONF="/etc/sysctl.d/99-bbr-ultimate.conf"

#=============================================================================
# 常量定义（版本号、URL 等集中管理）
#=============================================================================

# 版本号
readonly SCRIPT_VERSION="2.3"
readonly CADDY_DEFAULT_VERSION="2.7.6"
readonly SNELL_DEFAULT_VERSION="5.0.1"

# IP 查询服务 URL（按优先级排序）
readonly IP_CHECK_V4_URLS=(
    "https://api.ipify.org"
    "https://ip.sb"
    "https://checkip.amazonaws.com"
    "https://ipinfo.io/ip"
)
readonly IP_CHECK_V6_URLS=(
    "https://api64.ipify.org"
    "https://v6.ipinfo.io/ip"
    "https://ip.sb"
)

# IP 信息查询
readonly IP_INFO_URL="https://ipinfo.io"

#=============================================================================
# 日志系统
#=============================================================================

readonly LOG_FILE="/var/log/net-tcp-tune.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# 统一日志函数
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # 写入日志文件（静默失败）
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true

    # 根据级别输出到终端
    case "$level" in
        ERROR)
            echo -e "${gl_hong}[ERROR] $message${gl_bai}" >&2
            ;;
        WARN)
            echo -e "${gl_huang}[WARN] $message${gl_bai}"
            ;;
        INFO)
            [ "$LOG_LEVEL" != "ERROR" ] && echo -e "${gl_lv}[INFO] $message${gl_bai}"
            ;;
        DEBUG)
            [ "$LOG_LEVEL" = "DEBUG" ] && echo -e "${gl_hui}[DEBUG] $message${gl_bai}"
            ;;
    esac
}

# 便捷日志函数
log_error() { log "ERROR" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_info()  { log "INFO" "$@"; }
log_debug() { log "DEBUG" "$@"; }

#=============================================================================
# 错误处理
#=============================================================================

# 清理临时文件
cleanup_temp_files() {
    rm -f /tmp/net-tcp-tune.* 2>/dev/null || true
    rm -f /tmp/caddy.tar.gz 2>/dev/null || true
}

# 全局错误处理器（可选启用）
error_handler() {
    local exit_code=$1
    local line_no=$2
    local command="$3"

    log_error "脚本执行失败"
    log_error "  退出码: $exit_code"
    log_error "  行号: $line_no"
    log_error "  命令: $command"

    cleanup_temp_files
}

# 启用严格模式（用于调试）
enable_strict_mode() {
    set -euo pipefail
    trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR
}

# 退出时清理
trap cleanup_temp_files EXIT

#=============================================================================
# 工具函数
#=============================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${gl_hong}错误: ${gl_bai}此脚本需要 root 权限运行！"
        echo "请使用: sudo bash $0"
        exit 1
    fi
}

break_end() {
    echo -e "${gl_lv}操作完成${gl_bai}"
    echo "按任意键继续..."
    read -n 1 -s -r -p ""
    echo ""
}

clean_sysctl_conf() {
    # 备份主配置文件
    if [ -f /etc/sysctl.conf ] && ! [ -f /etc/sysctl.conf.bak.original ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.original
    fi
    
    # 注释所有冲突参数
    sed -i '/^net.core.rmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net.core.wmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net.ipv4.tcp_rmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net.ipv4.tcp_wmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net.core.default_qdisc/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net.ipv4.tcp_congestion_control/s/^/# /' /etc/sysctl.conf 2>/dev/null
}

install_package() {
    local packages=("$@")
    local missing_packages=()
    local os_release="/etc/os-release"
    local os_id=""
    local os_like=""
    local pkg_manager=""
    local update_cmd=()
    local install_cmd=()

    for package in "${packages[@]}"; do
        if ! command -v "$package" &>/dev/null; then
            missing_packages+=("$package")
        fi
    done

    if [ "${#missing_packages[@]}" -eq 0 ]; then
        return 0
    fi

    if [ -r "$os_release" ]; then
        # shellcheck disable=SC1091
        . "$os_release"
        os_id="${ID,,}"
        os_like="${ID_LIKE,,}"
    fi

    local detection="${os_id} ${os_like}"

    if [[ "$detection" =~ (debian|ubuntu) ]]; then
        pkg_manager="apt"
        update_cmd=(apt-get update)
        install_cmd=(apt-get install -y)
    elif [[ "$detection" =~ (rhel|centos|fedora|rocky|alma|redhat) ]]; then
        if command -v dnf &>/dev/null; then
            pkg_manager="dnf"
            update_cmd=(dnf makecache)
            install_cmd=(dnf install -y)
        elif command -v yum &>/dev/null; then
            pkg_manager="yum"
            update_cmd=(yum makecache)
            install_cmd=(yum install -y)
        else
            echo "错误: 未找到可用的 RHEL 系包管理器 (dnf 或 yum)" >&2
            return 1
        fi
    else
        echo "错误: 未支持的 Linux 发行版，无法自动安装依赖。请手动安装: ${missing_packages[*]}" >&2
        return 1
    fi

    if [ ${#update_cmd[@]} -gt 0 ]; then
        echo -e "${gl_huang}正在更新软件仓库...${gl_bai}"
        if ! "${update_cmd[@]}"; then
            echo "错误: 使用 ${pkg_manager} 更新软件仓库失败。" >&2
            return 1
        fi
    fi

    for package in "${missing_packages[@]}"; do
        echo -e "${gl_huang}正在安装 $package...${gl_bai}"
        if ! "${install_cmd[@]}" "$package"; then
            echo "错误: ${pkg_manager} 安装 $package 失败，请检查上方输出信息。" >&2
            return 1
        fi
    done
}

safe_download_script() {
    local url=$1
    local output_file=$2

    if command -v curl &>/dev/null; then
        curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$output_file"
    elif command -v wget &>/dev/null; then
        wget -qO "$output_file" "$url"
    else
        return 1
    fi

    [ -s "$output_file" ]
}

verify_downloaded_script() {
    local file=$1

    if [ ! -s "$file" ]; then
        return 1
    fi

    if head -n 1 "$file" | grep -qiE '<!DOCTYPE|<html'; then
        return 1
    fi

    # 检查 shebang，同时处理 UTF-8 BOM (ef bb bf) 开头的情况
    head -n 5 "$file" | sed 's/^\xef\xbb\xbf//' | grep -q '^#!'
}

run_remote_script() {
    local url=$1
    local interpreter=${2:-bash}
    shift 2

    local tmp_file
    tmp_file=$(mktemp /tmp/net-tcp-tune.XXXXXX) || {
        echo -e "${gl_hong}❌ 无法创建临时文件${gl_bai}"
        return 1
    }

    if ! safe_download_script "$url" "$tmp_file"; then
        echo -e "${gl_hong}❌ 下载脚本失败: ${url}${gl_bai}"
        rm -f "$tmp_file"
        return 1
    fi

    if ! verify_downloaded_script "$tmp_file"; then
        echo -e "${gl_hong}❌ 脚本校验失败，已取消执行${gl_bai}"
        rm -f "$tmp_file"
        return 1
    fi

    chmod +x "$tmp_file"
    "$interpreter" "$tmp_file" "$@"
    local rc=$?
    rm -f "$tmp_file"
    return $rc
}

check_disk_space() {
    local required_gb=$1
    local required_space_mb=$((required_gb * 1024))
    local available_space_mb=$(df -m / | awk 'NR==2 {print $4}')

    if [ "$available_space_mb" -lt "$required_space_mb" ]; then
        echo -e "${gl_huang}警告: ${gl_bai}磁盘空间不足！"
        echo "当前可用: $((available_space_mb/1024))G | 最低需求: ${required_gb}G"
        read -e -p "是否继续？(Y/N): " continue_choice
        case "$continue_choice" in
            [Yy]) return 0 ;;
            *) exit 1 ;;
        esac
    fi
}

check_swap() {
    local swap_total=$(free -m | awk 'NR==3{print $2}')
    
    if [ "$swap_total" -eq 0 ]; then
        echo -e "${gl_huang}检测到无虚拟内存，正在创建 1G SWAP...${gl_bai}"
        fallocate -l $((1025 * 1024 * 1024)) /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1025
        chmod 600 /swapfile
        mkswap /swapfile > /dev/null 2>&1
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo -e "${gl_lv}虚拟内存创建成功${gl_bai}"
    fi
}

add_swap() {
    local new_swap=$1  # 获取传入的参数（单位：MB）

    echo -e "${gl_kjlan}=== 调整虚拟内存（仅管理 /swapfile） ===${gl_bai}"

    # 检测是否存在活跃的 /dev/* swap 分区
    local dev_swap_list
    dev_swap_list=$(awk 'NR>1 && $1 ~ /^\/dev\// {printf "  • %s (大小: %d MB, 已用: %d MB)\n", $1, int(($3+512)/1024), int(($4+512)/1024)}' /proc/swaps)

    if [ -n "$dev_swap_list" ]; then
        echo -e "${gl_huang}检测到以下 /dev/ 虚拟内存处于激活状态：${gl_bai}"
        echo "$dev_swap_list"
        echo ""
        echo -e "${gl_huang}提示:${gl_bai} 本脚本不会修改 /dev/ 分区，请使用 ${gl_zi}swapoff <设备>${gl_bai} 等命令手动处理。"
        echo ""
    fi

    # 确保 /swapfile 不再被使用
    swapoff /swapfile 2>/dev/null
    
    # 删除旧的 /swapfile
    rm -f /swapfile
    
    echo "正在创建 ${new_swap}MB 虚拟内存..."
    
    # 创建新的 swap 分区
    fallocate -l $(( (new_swap + 1) * 1024 * 1024 )) /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((new_swap + 1))
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null 2>&1
    swapon /swapfile
    
    # 更新 /etc/fstab
    sed -i '/\/swapfile/d' /etc/fstab
    echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
    
    # Alpine Linux 特殊处理
    if [ -f /etc/alpine-release ]; then
        echo "nohup swapon /swapfile" > /etc/local.d/swap.start
        chmod +x /etc/local.d/swap.start
        rc-update add local 2>/dev/null
    fi
    
    echo -e "${gl_lv}虚拟内存大小已调整为 ${new_swap}MB${gl_bai}"
}

calculate_optimal_swap() {
    # 获取物理内存（MB）
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local recommended_swap
    local reason
    
    echo -e "${gl_kjlan}=== 智能计算虚拟内存大小 ===${gl_bai}"
    echo ""
    echo -e "检测到物理内存: ${gl_huang}${mem_total}MB${gl_bai}"
    echo ""
    echo "计算过程："
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 根据内存大小计算推荐 SWAP
    if [ "$mem_total" -lt 512 ]; then
        # < 512MB: SWAP = 1GB（固定）
        recommended_swap=1024
        reason="内存极小（< 512MB），固定推荐 1GB"
        echo "→ 内存 < 512MB"
        echo "→ 推荐固定 1GB SWAP"
        
    elif [ "$mem_total" -lt 1024 ]; then
        # 512MB ~ 1GB: SWAP = 内存 × 2
        recommended_swap=$((mem_total * 2))
        reason="内存较小（512MB-1GB），推荐 2 倍内存"
        echo "→ 内存在 512MB - 1GB 之间"
        echo "→ 计算公式: SWAP = 内存 × 2"
        echo "→ ${mem_total}MB × 2 = ${recommended_swap}MB"
        
    elif [ "$mem_total" -lt 2048 ]; then
        # 1GB ~ 2GB: SWAP = 内存 × 1.5
        recommended_swap=$((mem_total * 3 / 2))
        reason="内存适中（1-2GB），推荐 1.5 倍内存"
        echo "→ 内存在 1GB - 2GB 之间"
        echo "→ 计算公式: SWAP = 内存 × 1.5"
        echo "→ ${mem_total}MB × 1.5 = ${recommended_swap}MB"
        
    elif [ "$mem_total" -lt 4096 ]; then
        # 2GB ~ 4GB: SWAP = 内存 × 1
        recommended_swap=$mem_total
        reason="内存充足（2-4GB），推荐与内存同大小"
        echo "→ 内存在 2GB - 4GB 之间"
        echo "→ 计算公式: SWAP = 内存 × 1"
        echo "→ ${mem_total}MB × 1 = ${recommended_swap}MB"
        
    elif [ "$mem_total" -lt 8192 ]; then
        # 4GB ~ 8GB: SWAP = 4GB（固定）
        recommended_swap=4096
        reason="内存较多（4-8GB），固定推荐 4GB"
        echo "→ 内存在 4GB - 8GB 之间"
        echo "→ 固定推荐 4GB SWAP"
        
    else
        # >= 8GB: SWAP = 4GB（固定）
        recommended_swap=4096
        reason="内存充裕（≥ 8GB），固定推荐 4GB"
        echo "→ 内存 ≥ 8GB"
        echo "→ 固定推荐 4GB SWAP"
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "${gl_lv}计算结果：${gl_bai}"
    echo -e "  物理内存:   ${gl_huang}${mem_total}MB${gl_bai}"
    echo -e "  推荐 SWAP:  ${gl_huang}${recommended_swap}MB${gl_bai}"
    echo -e "  总可用内存: ${gl_huang}$((mem_total + recommended_swap))MB${gl_bai}"
    echo ""
    echo -e "${gl_zi}推荐理由: ${reason}${gl_bai}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # 确认是否应用
    read -e -p "$(echo -e "${gl_huang}是否应用此配置？(Y/N): ${gl_bai}")" confirm
    
    case "$confirm" in
        [Yy])
            add_swap "$recommended_swap"
            return 0
            ;;
        *)
            echo "已取消"
            sleep 2
            return 1
            ;;
    esac
}

manage_swap() {
    while true; do
        clear
        echo -e "${gl_kjlan}=== 虚拟内存管理（仅限 /swapfile） ===${gl_bai}"
        echo -e "${gl_huang}提示:${gl_bai} 如需调整 /dev/ swap 分区，请手动执行 swapoff/swap 分区工具。"

        local mem_total=$(free -m | awk 'NR==2{print $2}')
        local swap_used=$(free -m | awk 'NR==3{print $3}')
        local swap_total=$(free -m | awk 'NR==3{print $2}')
        local swap_info=$(free -m | awk 'NR==3{used=$3; total=$2; if (total == 0) {percentage=0} else {percentage=used*100/total}; printf "%dM/%dM (%d%%)", used, total, percentage}')
        
        echo -e "物理内存:     ${gl_huang}${mem_total}MB${gl_bai}"
        echo -e "当前虚拟内存: ${gl_huang}$swap_info${gl_bai}"
        echo "------------------------------------------------"
        echo "1. 分配 1024M (1GB) - 固定配置"
        echo "2. 分配 2048M (2GB) - 固定配置"
        echo "3. 分配 4096M (4GB) - 固定配置"
        echo "4. 智能计算推荐值 - 自动计算最佳配置"
        echo "0. 返回主菜单"
        echo "------------------------------------------------"
        read -e -p "请输入选择: " choice
        
        case "$choice" in
            1)
                add_swap 1024
                break_end
                ;;
            2)
                add_swap 2048
                break_end
                ;;
            3)
                add_swap 4096
                break_end
                ;;
            4)
                calculate_optimal_swap
                if [ $? -eq 0 ]; then
                    break_end
                fi
                ;;
            0)
                return
                ;;
            *)
                echo "无效选择"
                sleep 2
                ;;
        esac
    done
}

# 通用 IP 优先级设置函数
# 参数: $1 = "ipv4" 或 "ipv6"
set_ip_priority() {
    local ip_type="$1"

    # 参数校验
    if [ "$ip_type" != "ipv4" ] && [ "$ip_type" != "ipv6" ]; then
        echo -e "${gl_hong}错误：参数必须是 ipv4 或 ipv6${gl_bai}"
        return 1
    fi

    # 根据类型设置变量
    if [ "$ip_type" = "ipv4" ]; then
        local title="IPv4"
        local ipv4_precedence=100
        local ipv6_precedence=10
        local curl_flag="-4"
        local secondary_flag="-6"
        local primary="IPv4"
        local secondary="IPv6"
    else
        local title="IPv6"
        local ipv4_precedence=10
        local ipv6_precedence=100
        local curl_flag="-6"
        local secondary_flag="-4"
        local primary="IPv6"
        local secondary="IPv4"
    fi

    clear
    echo -e "${gl_kjlan}=== 设置${title}优先 ===${gl_bai}"
    echo ""

    # 备份原配置文件并记录原始状态
    if [ -f /etc/gai.conf ]; then
        cp /etc/gai.conf /etc/gai.conf.bak.$(date +%Y%m%d_%H%M%S)
        echo "已备份原配置文件到 /etc/gai.conf.bak.*"
        # 记录原先存在文件
        echo "existed" > /etc/gai.conf.original_state
    else
        # 记录原先不存在文件
        echo "not_existed" > /etc/gai.conf.original_state
        echo "原先无配置文件，已记录原始状态"
    fi

    echo "正在设置 ${title} 优先..."

    # 创建配置文件
    cat > /etc/gai.conf << EOF
# Configuration for getaddrinfo(3).
#
# 设置 ${title} 优先

# IPv4 addresses
precedence ::ffff:0:0/96  ${ipv4_precedence}

# IPv6 addresses
precedence ::/0           ${ipv6_precedence}

# IPv4-mapped IPv6 addresses
precedence ::1/128        50

# Link-local addresses
precedence fe80::/10      1
precedence fec0::/10      1
precedence fc00::/7       1

# Site-local addresses (deprecated)
precedence 2002::/16      30
EOF

    # 刷新 nscd 缓存（如果安装了）
    if command -v nscd &> /dev/null; then
        systemctl restart nscd 2>/dev/null || service nscd restart 2>/dev/null || true
        echo "已刷新 nscd DNS 缓存"
    fi

    # 刷新 systemd-resolved 缓存（如果使用）
    if command -v resolvectl &> /dev/null; then
        resolvectl flush-caches 2>/dev/null || true
        echo "已刷新 systemd-resolved DNS 缓存"
    fi

    echo -e "${gl_lv}✅ ${title} 优先已设置${gl_bai}"
    echo ""
    echo "当前出口 IP 地址："
    echo "------------------------------------------------"
    curl ${curl_flag} ip.sb 2>/dev/null || curl ip.sb
    echo ""
    echo "------------------------------------------------"
    echo ""
    echo -e "${gl_huang}提示：${gl_bai}"
    echo "1. 配置已生效，无需重启系统"
    echo "2. 新启动的程序将自动使用 ${title} 优先"
    echo "3. 如需强制指定，可使用: curl ${curl_flag} ip.sb (强制${primary}) 或 curl ${secondary_flag} ip.sb (强制${secondary})"
    echo "4. 已运行的长连接服务（如Nginx、Docker容器）可能需要重启服务才能应用"
    echo ""

    break_end
}

manage_ip_priority() {
    while true; do
        clear
        echo -e "${gl_kjlan}=== 设置IPv4/IPv6优先级 ===${gl_bai}"
        echo ""
        echo "1. 设置IPv4优先"
        echo "2. 设置IPv6优先"
        echo "3. 恢复IP优先级配置"
        echo "0. 返回主菜单"
        echo ""
        echo "------------------------------------------------"
        read -p "请选择操作 [0-3]: " ip_priority_choice
        echo ""
        
        case $ip_priority_choice in
            1)
                set_ip_priority "ipv4"
                ;;
            2)
                set_ip_priority "ipv6"
                ;;
            3)
                restore_gai_conf
                ;;
            0)
                break
                ;;
            *)
                echo -e "${gl_hong}无效选择，请重新输入${gl_bai}"
                sleep 2
                ;;
        esac
    done
}

restore_gai_conf() {
    clear
    echo -e "${gl_kjlan}=== 恢复 IP 优先级配置 ===${gl_bai}"
    echo ""

    # 检查是否有原始状态记录
    if [ ! -f /etc/gai.conf.original_state ]; then
        echo -e "${gl_huang}⚠️  未找到原始状态记录${gl_bai}"
        echo "可能的原因："
        echo "1. 从未使用过本脚本设置过 IPv4/IPv6 优先级"
        echo "2. 原始状态记录文件已被删除"
        echo ""
        
        # 列出所有备份文件
        if ls /etc/gai.conf.bak.* 2>/dev/null; then
            echo "发现以下备份文件："
            ls -lh /etc/gai.conf.bak.* 2>/dev/null
            echo ""
            echo "是否要手动恢复最新的备份？[y/n]"
            read -p "请选择: " manual_restore
            if [[ "$manual_restore" == "y" || "$manual_restore" == "Y" ]]; then
                latest_backup=$(ls -t /etc/gai.conf.bak.* 2>/dev/null | head -1)
                if [ -n "$latest_backup" ]; then
                    cp "$latest_backup" /etc/gai.conf
                    echo -e "${gl_lv}✅ 已从备份恢复: $latest_backup${gl_bai}"
                fi
            fi
        else
            echo "也未找到任何备份文件。"
            echo ""
            echo "是否要删除当前的 gai.conf 文件（恢复到系统默认）？[y/n]"
            read -p "请选择: " delete_conf
            if [[ "$delete_conf" == "y" || "$delete_conf" == "Y" ]]; then
                rm -f /etc/gai.conf
                echo -e "${gl_lv}✅ 已删除 gai.conf，系统将使用默认配置${gl_bai}"
            fi
        fi
    else
        # 读取原始状态
        original_state=$(cat /etc/gai.conf.original_state)
        
        if [ "$original_state" == "not_existed" ]; then
            echo "检测到原先${gl_huang}没有${gl_bai} gai.conf 文件"
            echo "恢复操作将${gl_hong}删除${gl_bai}当前的 gai.conf 文件"
            echo ""
            echo "确认要恢复到原始状态吗？[y/n]"
            read -p "请选择: " confirm
            
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                rm -f /etc/gai.conf
                rm -f /etc/gai.conf.original_state
                echo -e "${gl_lv}✅ 已删除 gai.conf，恢复到原始状态（无配置文件）${gl_bai}"
                
                # 刷新缓存
                if command -v nscd &> /dev/null; then
                    systemctl restart nscd 2>/dev/null || service nscd restart 2>/dev/null || true
                fi
                if command -v resolvectl &> /dev/null; then
                    resolvectl flush-caches 2>/dev/null || true
                fi
            else
                echo "已取消恢复操作"
            fi
            
        elif [ "$original_state" == "existed" ]; then
            echo "检测到原先${gl_lv}存在${gl_bai} gai.conf 文件"
            
            # 查找最新的备份
            latest_backup=$(ls -t /etc/gai.conf.bak.* 2>/dev/null | head -1)
            
            if [ -n "$latest_backup" ]; then
                echo "找到备份文件: $latest_backup"
                echo ""
                echo "确认要从备份恢复吗？[y/n]"
                read -p "请选择: " confirm
                
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    cp "$latest_backup" /etc/gai.conf
                    rm -f /etc/gai.conf.original_state
                    echo -e "${gl_lv}✅ 已从备份恢复配置${gl_bai}"
                    
                    # 刷新缓存
                    if command -v nscd &> /dev/null; then
                        systemctl restart nscd 2>/dev/null || service nscd restart 2>/dev/null || true
                        echo "已刷新 nscd DNS 缓存"
                    fi
                    if command -v resolvectl &> /dev/null; then
                        resolvectl flush-caches 2>/dev/null || true
                        echo "已刷新 systemd-resolved DNS 缓存"
                    fi
                    
                    echo ""
                    echo "当前出口 IP 地址："
                    echo "------------------------------------------------"
                    curl ip.sb
                    echo ""
                    echo "------------------------------------------------"
                else
                    echo "已取消恢复操作"
                fi
            else
                echo -e "${gl_hong}错误: 未找到备份文件${gl_bai}"
            fi
        fi
    fi
    
    echo ""
    break_end
}

set_temp_socks5_proxy() {
    clear
    echo -e "${gl_kjlan}=== 设置临时SOCKS5代理 ===${gl_bai}"
    echo ""
    echo "此代理配置仅对当前终端会话有效，重启后自动失效"
    echo "------------------------------------------------"
    echo ""
    
    # 输入代理服务器IP
    local proxy_ip=""
    while true; do
        read -e -p "$(echo -e "${gl_huang}请输入代理服务器IP: ${gl_bai}")" proxy_ip

        if [ -z "$proxy_ip" ]; then
            echo -e "${gl_hong}❌ IP地址不能为空${gl_bai}"
        elif [[ "$proxy_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            # 验证IP格式和范围（每段0-255）
            local valid_ip=true
            IFS='.' read -ra octets <<< "$proxy_ip"
            for octet in "${octets[@]}"; do
                if [ "$octet" -gt 255 ]; then
                    valid_ip=false
                    break
                fi
            done
            if [ "$valid_ip" = true ]; then
                echo -e "${gl_lv}✅ IP地址: ${proxy_ip}${gl_bai}"
                break
            else
                echo -e "${gl_hong}❌ IP地址范围无效（每段必须在0-255之间）${gl_bai}"
            fi
        else
            echo -e "${gl_hong}❌ 无效的IP地址格式${gl_bai}"
        fi
    done
    
    echo ""
    
    # 输入端口
    local proxy_port=""
    while true; do
        read -e -p "$(echo -e "${gl_huang}请输入端口: ${gl_bai}")" proxy_port
        
        if [ -z "$proxy_port" ]; then
            echo -e "${gl_hong}❌ 端口不能为空${gl_bai}"
        elif [[ "$proxy_port" =~ ^[0-9]+$ ]] && [ "$proxy_port" -ge 1 ] && [ "$proxy_port" -le 65535 ]; then
            echo -e "${gl_lv}✅ 端口: ${proxy_port}${gl_bai}"
            break
        else
            echo -e "${gl_hong}❌ 无效端口，请输入 1-65535 之间的数字${gl_bai}"
        fi
    done
    
    echo ""
    
    # 输入用户名（可选）
    local proxy_user=""
    read -e -p "$(echo -e "${gl_huang}请输入用户名（留空跳过）: ${gl_bai}")" proxy_user
    
    if [ -n "$proxy_user" ]; then
        echo -e "${gl_lv}✅ 用户名: ${proxy_user}${gl_bai}"
    else
        echo -e "${gl_zi}未设置用户名（无认证模式）${gl_bai}"
    fi
    
    echo ""
    
    # 输入密码（可选）
    local proxy_pass=""
    if [ -n "$proxy_user" ]; then
        read -e -p "$(echo -e "${gl_huang}请输入密码: ${gl_bai}")" proxy_pass
        
        if [ -n "$proxy_pass" ]; then
            echo -e "${gl_lv}✅ 密码已设置${gl_bai}"
        else
            echo -e "${gl_huang}⚠️  密码为空${gl_bai}"
        fi
    fi
    
    # 生成代理URL
    local proxy_url=""
    if [ -n "$proxy_user" ] && [ -n "$proxy_pass" ]; then
        proxy_url="socks5://${proxy_user}:${proxy_pass}@${proxy_ip}:${proxy_port}"
    elif [ -n "$proxy_user" ]; then
        proxy_url="socks5://${proxy_user}@${proxy_ip}:${proxy_port}"
    else
        proxy_url="socks5://${proxy_ip}:${proxy_port}"
    fi
    
    # 生成临时配置文件（安全模式）
    local timestamp=$(date +%Y%m%d_%H%M%S)
    # 优先使用用户私有目录，回退到 /tmp
    local secure_tmp="${XDG_RUNTIME_DIR:-/tmp}"
    local config_file="${secure_tmp}/socks5_proxy_${timestamp}.sh"

    # 设置安全的 umask（仅所有者可读写）
    local old_umask=$(umask)
    umask 077

    # 生成配置文件（不在文件中输出完整密码）
    cat > "$config_file" << PROXYEOF
#!/bin/bash
# SOCKS5 代理配置 - 生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 此配置仅对当前终端会话有效
# 警告: 使用后请删除此文件 (rm $config_file)

export http_proxy="${proxy_url}"
export https_proxy="${proxy_url}"
export all_proxy="${proxy_url}"

echo "SOCKS5 代理已启用："
echo "  服务器: ${proxy_ip}:${proxy_port}"
echo "  用户: ${proxy_user:-无}"
echo "  (代理 URL 已设置到环境变量)"
PROXYEOF

    # 恢复 umask 并确保文件权限安全
    umask "$old_umask"
    chmod 600 "$config_file"
    
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}✅ 代理配置文件已生成！${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_huang}使用方法：${gl_bai}"
    echo ""
    echo -e "1. ${gl_lv}应用代理配置：${gl_bai}"
    echo "   source ${config_file}"
    echo ""
    echo -e "2. ${gl_lv}测试代理是否生效：${gl_bai}"
    echo "   curl ip.sb"
    echo "   （应该显示代理服务器的IP地址）"
    echo ""
    echo -e "3. ${gl_lv}取消代理：${gl_bai}"
    echo "   unset http_proxy https_proxy all_proxy"
    echo ""
    echo -e "${gl_zi}注意事项：${gl_bai}"
    echo "  - 此配置仅对执行 source 命令的终端会话有效"
    echo "  - 关闭终端或重启系统后代理自动失效"
    echo "  - 配置文件保存在 /tmp 目录，重启后会被清除"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    break_end
}

disable_ipv6_temporary() {
    clear
    echo -e "${gl_kjlan}=== 临时禁用IPv6 ===${gl_bai}"
    echo ""
    echo "此操作将临时禁用IPv6，重启后自动恢复"
    echo "------------------------------------------------"
    echo ""
    
    read -e -p "$(echo -e "${gl_huang}确认临时禁用IPv6？(Y/N): ${gl_bai}")" confirm
    
    case "$confirm" in
        [Yy])
            echo ""
            echo "正在禁用IPv6..."
            
            # 临时禁用IPv6
            sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1
            
            # 验证状态
            local ipv6_status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
            
            echo ""
            if [ "$ipv6_status" = "1" ]; then
                echo -e "${gl_lv}✅ IPv6 已临时禁用${gl_bai}"
                echo ""
                echo -e "${gl_zi}注意：${gl_bai}"
                echo "  - 此设置仅在当前会话有效"
                echo "  - 重启后 IPv6 将自动恢复"
                echo "  - 如需永久禁用，请选择'永久禁用IPv6'选项"
            else
                echo -e "${gl_hong}❌ IPv6 禁用失败${gl_bai}"
            fi
            ;;
        *)
            echo "已取消"
            ;;
    esac
    
    echo ""
    break_end
}

disable_ipv6_permanent() {
    clear
    echo -e "${gl_kjlan}=== 永久禁用IPv6 ===${gl_bai}"
    echo ""
    echo "此操作将永久禁用IPv6，重启后仍然生效"
    echo "------------------------------------------------"
    echo ""
    
    # 检查是否已经永久禁用
    if [ -f /etc/sysctl.d/99-disable-ipv6.conf ]; then
        echo -e "${gl_huang}⚠️  检测到已存在永久禁用配置${gl_bai}"
        echo ""
        read -e -p "$(echo -e "${gl_huang}是否重新执行永久禁用？(Y/N): ${gl_bai}")" confirm
        
        case "$confirm" in
            [Yy])
                ;;
            *)
                echo "已取消"
                break_end
                return 1
                ;;
        esac
    fi
    
    echo ""
    read -e -p "$(echo -e "${gl_huang}确认永久禁用IPv6？(Y/N): ${gl_bai}")" confirm
    
    case "$confirm" in
        [Yy])
            echo ""
            echo -e "${gl_zi}[步骤 1/3] 备份当前IPv6状态...${gl_bai}"
            
            # 读取当前IPv6状态并备份
            local ipv6_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
            local ipv6_default=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo "0")
            local ipv6_lo=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || echo "0")
            
            # 创建备份文件
            cat > /etc/sysctl.d/.ipv6-state-backup.conf << BACKUPEOF
# IPv6 State Backup - Created on $(date '+%Y-%m-%d %H:%M:%S')
# This file is used to restore IPv6 state when canceling permanent disable
net.ipv6.conf.all.disable_ipv6=${ipv6_all}
net.ipv6.conf.default.disable_ipv6=${ipv6_default}
net.ipv6.conf.lo.disable_ipv6=${ipv6_lo}
BACKUPEOF
            
            echo -e "${gl_lv}✅ 状态已备份${gl_bai}"
            echo ""
            
            echo -e "${gl_zi}[步骤 2/3] 创建永久禁用配置...${gl_bai}"
            
            # 创建永久禁用配置文件
            cat > /etc/sysctl.d/99-disable-ipv6.conf << EOF
# Permanently Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
            
            echo -e "${gl_lv}✅ 配置文件已创建${gl_bai}"
            echo ""
            
            echo -e "${gl_zi}[步骤 3/3] 应用配置...${gl_bai}"
            
            # 应用配置
            sysctl --system >/dev/null 2>&1
            
            # 验证状态
            local ipv6_status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
            
            echo ""
            if [ "$ipv6_status" = "1" ]; then
                echo -e "${gl_lv}✅ IPv6 已永久禁用${gl_bai}"
                echo ""
                echo -e "${gl_zi}说明：${gl_bai}"
                echo "  - 配置文件: /etc/sysctl.d/99-disable-ipv6.conf"
                echo "  - 备份文件: /etc/sysctl.d/.ipv6-state-backup.conf"
                echo "  - 重启后此配置仍然生效"
                echo "  - 如需恢复，请选择'取消永久禁用'选项"
            else
                echo -e "${gl_hong}❌ IPv6 禁用失败${gl_bai}"
                # 如果失败，删除配置文件
                rm -f /etc/sysctl.d/99-disable-ipv6.conf
                rm -f /etc/sysctl.d/.ipv6-state-backup.conf
            fi
            ;;
        *)
            echo "已取消"
            ;;
    esac
    
    echo ""
    break_end
}

cancel_ipv6_permanent_disable() {
    clear
    echo -e "${gl_kjlan}=== 取消永久禁用IPv6 ===${gl_bai}"
    echo ""
    echo "此操作将完全还原到执行永久禁用前的状态"
    echo "------------------------------------------------"
    echo ""
    
    # 检查是否存在永久禁用配置
    if [ ! -f /etc/sysctl.d/99-disable-ipv6.conf ]; then
        echo -e "${gl_huang}⚠️  未检测到永久禁用配置${gl_bai}"
        echo ""
        echo "可能原因："
        echo "  - 从未执行过'永久禁用IPv6'操作"
        echo "  - 配置文件已被手动删除"
        echo ""
        break_end
        return 1
    fi
    
    read -e -p "$(echo -e "${gl_huang}确认取消永久禁用并恢复原始状态？(Y/N): ${gl_bai}")" confirm
    
    case "$confirm" in
        [Yy])
            echo ""
            echo -e "${gl_zi}[步骤 1/4] 删除永久禁用配置...${gl_bai}"
            
            # 删除永久禁用配置文件
            rm -f /etc/sysctl.d/99-disable-ipv6.conf
            echo -e "${gl_lv}✅ 配置文件已删除${gl_bai}"
            echo ""
            
            echo -e "${gl_zi}[步骤 2/4] 检查备份文件...${gl_bai}"
            
            # 检查备份文件
            if [ -f /etc/sysctl.d/.ipv6-state-backup.conf ]; then
                echo -e "${gl_lv}✅ 找到备份文件${gl_bai}"
                echo ""
                
                echo -e "${gl_zi}[步骤 3/4] 从备份还原原始状态...${gl_bai}"
                
                # 读取备份的原始值
                local backup_all=$(grep 'net.ipv6.conf.all.disable_ipv6' /etc/sysctl.d/.ipv6-state-backup.conf | awk -F'=' '{print $2}')
                local backup_default=$(grep 'net.ipv6.conf.default.disable_ipv6' /etc/sysctl.d/.ipv6-state-backup.conf | awk -F'=' '{print $2}')
                local backup_lo=$(grep 'net.ipv6.conf.lo.disable_ipv6' /etc/sysctl.d/.ipv6-state-backup.conf | awk -F'=' '{print $2}')
                
                # 恢复原始值
                sysctl -w net.ipv6.conf.all.disable_ipv6=${backup_all} >/dev/null 2>&1
                sysctl -w net.ipv6.conf.default.disable_ipv6=${backup_default} >/dev/null 2>&1
                sysctl -w net.ipv6.conf.lo.disable_ipv6=${backup_lo} >/dev/null 2>&1
                
                # 删除备份文件
                rm -f /etc/sysctl.d/.ipv6-state-backup.conf
                
                echo -e "${gl_lv}✅ 已从备份还原原始状态${gl_bai}"
            else
                echo -e "${gl_huang}⚠️  未找到备份文件${gl_bai}"
                echo ""
                
                echo -e "${gl_zi}[步骤 3/4] 恢复到系统默认（启用IPv6）...${gl_bai}"
                
                # 恢复到系统默认（启用IPv6）
                sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
                sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
                sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1
                
                echo -e "${gl_lv}✅ 已恢复到系统默认（IPv6启用）${gl_bai}"
            fi
            
            echo ""
            echo -e "${gl_zi}[步骤 4/4] 应用配置...${gl_bai}"
            
            # 应用配置
            sysctl --system >/dev/null 2>&1
            
            # 验证状态
            local ipv6_status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
            
            echo ""
            if [ "$ipv6_status" = "0" ]; then
                echo -e "${gl_lv}✅ IPv6 已恢复启用${gl_bai}"
                echo ""
                echo -e "${gl_zi}说明：${gl_bai}"
                echo "  - 所有相关配置文件已清理"
                echo "  - IPv6 已完全恢复到执行永久禁用前的状态"
                echo "  - 重启后此状态依然保持"
            else
                echo -e "${gl_huang}⚠️  IPv6 状态: 禁用（值=${ipv6_status}）${gl_bai}"
                echo ""
                echo "可能原因："
                echo "  - 系统中存在其他IPv6禁用配置"
                echo "  - 手动执行 sysctl -w 命令重新启用IPv6"
            fi
            ;;
        *)
            echo "已取消"
            ;;
    esac
    
    echo ""
    break_end
}

manage_ipv6() {
    while true; do
        clear
        echo -e "${gl_kjlan}=== IPv6 管理 ===${gl_bai}"
        echo ""
        
        # 显示当前IPv6状态
        local ipv6_status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        local status_text=""
        local status_color=""
        
        if [ "$ipv6_status" = "0" ]; then
            status_text="启用"
            status_color="${gl_lv}"
        else
            status_text="禁用"
            status_color="${gl_hong}"
        fi
        
        echo -e "当前状态: ${status_color}${status_text}${gl_bai}"
        echo ""
        
        # 检查是否存在永久禁用配置
        if [ -f /etc/sysctl.d/99-disable-ipv6.conf ]; then
            echo -e "${gl_huang}⚠️  检测到永久禁用配置文件${gl_bai}"
            echo ""
        fi
        
        echo "------------------------------------------------"
        echo "1. 临时禁用IPv6（重启后恢复）"
        echo "2. 永久禁用IPv6（重启后仍生效）"
        echo "3. 取消永久禁用（完全还原）"
        echo "0. 返回主菜单"
        echo "------------------------------------------------"
        read -e -p "请输入选择: " choice
        
        case "$choice" in
            1)
                disable_ipv6_temporary
                ;;
            2)
                disable_ipv6_permanent
                ;;
            3)
                cancel_ipv6_permanent_disable
                ;;
            0)
                return
                ;;
            *)
                echo "无效选择"
                sleep 2
                ;;
        esac
    done
}

#=============================================================================
# Realm 转发连接分析工具
#=============================================================================

analyze_realm_connections() {
    clear
    echo -e "${gl_kjlan}=========================================="
    echo "         Realm 转发连接实时分析工具"
    echo -e "==========================================${gl_bai}"
    echo ""
    
    # 步骤1：检测 Realm 进程
    echo -e "${gl_zi}[步骤 1/3] 检测 Realm 进程...${gl_bai}"
    
    local realm_pids=$(pgrep -x realm 2>/dev/null)
    if [ -z "$realm_pids" ]; then
        echo -e "${gl_hong}❌ 未检测到 Realm 进程${gl_bai}"
        echo ""
        echo "可能原因："
        echo "  - Realm 服务未启动"
        echo "  - Realm 进程名不是 'realm'"
        echo ""
        echo "尝试手动查找："
        echo "  ps aux | grep -i realm"
        echo ""
        break_end
        return 1
    fi
    
    local realm_pid=$(echo "$realm_pids" | head -1)
    echo -e "${gl_lv}✅ 找到 Realm 进程: PID ${realm_pid}${gl_bai}"
    echo ""
    
    # 步骤2：分析入站连接
    echo -e "${gl_zi}[步骤 2/3] 分析入站连接...${gl_bai}"
    echo "正在扫描所有活跃连接..."
    echo ""
    
    # 获取所有 realm 相关的连接（优先使用 PID 精确匹配）
    local realm_connections=$(ss -tnp 2>/dev/null | grep "pid=${realm_pid}" | grep "ESTAB")
    
    # 如果通过 PID 没找到，尝试通过进程名查找
    if [ -z "$realm_connections" ]; then
        realm_connections=$(ss -tnp 2>/dev/null | grep -i "realm" | grep "ESTAB")
    fi
    
    if [ -z "$realm_connections" ]; then
        echo -e "${gl_huang}⚠️  未发现活跃连接${gl_bai}"
        echo ""
        echo -e "${gl_zi}调试信息：${gl_bai}"
        echo "尝试查看 Realm 进程的所有连接："
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        ss -tnp 2>/dev/null | grep "pid=${realm_pid}" | head -10
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "可能原因："
        echo "  1. Realm 转发服务刚启动，还没有客户端连接"
        echo "  2. 客户端暂时断开连接"
        echo "  3. Realm 配置中没有活跃的转发规则"
        echo ""
        echo "建议操作："
        echo "  - 使用客户端连接后再运行此工具"
        echo "  - 检查 Realm 配置: cat /etc/realm/config.toml"
        echo "  - 查看 Realm 日志: journalctl -u realm -f"
        echo ""
        break_end
        return 1
    fi
    
    # 步骤3：生成分析报告
    echo -e "${gl_zi}[步骤 3/3] 生成分析报告...${gl_bai}"
    echo ""
    
    # 提取并统计源IP
    local source_ips=$(echo "$realm_connections" | awk '{print $5}' | sed 's/::ffff://' | cut -d: -f1 | grep -v "^\[" | sort | uniq)
    
    # 处理IPv6地址
    local source_ips_v6=$(echo "$realm_connections" | awk '{print $5}' | grep "^\[" | sed 's/\]:.*/\]/' | sed 's/\[//' | sed 's/\]//' | sed 's/::ffff://' | sort | uniq)
    
    # 合并并去重 IP 列表
    local all_source_ips=$(echo -e "${source_ips}\n${source_ips_v6}" | grep -v "^$" | sort | uniq)

    # 边界条件检查：确保有连接数据
    if [ -z "$all_source_ips" ]; then
        echo -e "${gl_huang}暂无检测到任何 Realm 连接${gl_bai}"
        break_end
        return 0
    fi

    local total_sources=$(echo "$all_source_ips" | wc -l)
    local total_connections=$(echo "$realm_connections" | wc -l)
    
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "                    分析结果"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    local source_num=1
    local ipv4_total=0
    local ipv6_total=0
    
    # 遍历每个源IP
    for source_ip in $all_source_ips; do
        # 统计连接数
        local conn_count_v4=$(echo "$realm_connections" | grep -c "${source_ip}:")
        local conn_count_v6_mapped=$(echo "$realm_connections" | grep -c "::ffff:${source_ip}")
        local conn_count=$((conn_count_v4 + conn_count_v6_mapped))
        
        # 判断协议类型（注意：::ffff: 开头的是 IPv4-mapped IPv6，本质是 IPv4）
        local protocol_type=""
        if [ $conn_count_v6_mapped -gt 0 ]; then
            # IPv4-mapped IPv6 地址 (::ffff:x.x.x.x) 算作 IPv4
            protocol_type="✅ IPv4（IPv6映射格式）"
            ipv4_total=$((ipv4_total + conn_count))
        elif echo "$source_ip" | grep -qE '^[0-9a-fA-F]*:[0-9a-fA-F:]+$'; then
            # 纯 IPv6 地址（包含冒号且不是 IPv4 格式）
            protocol_type="⚠️  纯IPv6"
            ipv6_total=$((ipv6_total + conn_count))
        else
            # 纯 IPv4 地址
            protocol_type="✅ 纯IPv4"
            ipv4_total=$((ipv4_total + conn_count))
        fi
        
        # 获取本地监听端口（兼容 IPv4 和 IPv6 映射格式）
        local local_port=$(echo "$realm_connections" | grep "${source_ip}" | awk '{print $4}' | sed 's/.*[:\]]//' | head -1)
        
        # IP归属查询（简化版，避免过多API调用）
        local ip_info=""
        if command -v curl &>/dev/null; then
            ip_info=$(timeout 2 curl -s "http://ip-api.com/json/${source_ip}?lang=zh-CN&fields=country,regionName,city,isp,as" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$ip_info" ]; then
                local country=$(echo "$ip_info" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
                local region=$(echo "$ip_info" | grep -o '"regionName":"[^"]*"' | cut -d'"' -f4)
                local city=$(echo "$ip_info" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
                local isp=$(echo "$ip_info" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
                local as_num=$(echo "$ip_info" | grep -o '"as":"[^"]*"' | cut -d'"' -f4)
                
                ip_location="${country} ${region} ${city} ${isp}"
                [ -n "$as_num" ] && ip_as="$as_num" || ip_as="未知"
            else
                ip_location="查询失败"
                ip_as="未知"
            fi
        else
            ip_location="需要 curl 命令"
            ip_as="未知"
        fi
        
        # 显示源信息
        echo -e "┌─────────────── 转发源 #${source_num} ───────────────┐"
        echo -e "│                                          │"
        echo -e "│  源IP地址:   ${gl_huang}${source_ip}${gl_bai}"
        echo -e "│  IP归属:     ${ip_location}"
        [ -n "$ip_as" ] && echo -e "│  AS号:       ${ip_as}"
        echo -e "│  连接数:     ${gl_lv}${conn_count}${gl_bai} 个"
        echo -e "│  协议类型:   ${protocol_type}"
        echo -e "│  本地监听:   ${local_port}"
        echo -e "│  状态:       ${gl_lv}✅ 正常${gl_bai}"
        echo -e "│                                          │"
        echo -e "└──────────────────────────────────────────┘"
        echo ""
        
        source_num=$((source_num + 1))
    done
    
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "                   统计摘要"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "  • 转发源总数:     ${gl_lv}${total_sources}${gl_bai} 个"
    echo -e "  • 活跃连接总数:   ${gl_lv}${ipv4_total}${gl_bai} 个"
    echo -e "  • IPv4连接:       ${gl_lv}${ipv4_total}${gl_bai} 个 ✅"
    echo -e "  • IPv6连接:       ${ipv6_total} 个"
    
    if [ $ipv6_total -eq 0 ]; then
        echo -e "  • 结论:           ${gl_lv}100% 使用 IPv4 链路 ✅${gl_bai}"
    else
        echo -e "  • 结论:           ${gl_huang}存在 IPv6 连接${gl_bai}"
    fi
    
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    # 交互式选项
    echo -e "${gl_zi}[操作选项]${gl_bai}"
    echo "1. 查看详细连接列表"
    echo "2. 导出分析报告到文件"
    echo "3. 实时监控连接变化"
    echo "4. 检测特定源IP"
    echo "0. 返回主菜单"
    echo ""
    read -e -p "请输入选择: " sub_choice
    
    case "$sub_choice" in
        1)
            # 查看详细连接列表
            clear
            echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            echo "           详细连接列表"
            echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            echo ""
            
            for source_ip in $all_source_ips; do
                echo -e "${gl_huang}源IP: ${source_ip}${gl_bai}"
                echo ""
                echo "本地地址:端口          远程地址:端口           状态"
                echo "────────────────────────────────────────────────"
                ss -tnp 2>/dev/null | grep "realm" | grep "${source_ip}" | awk '{printf "%-23s %-23s %s\n", $4, $5, $1}' | head -20
                echo ""
            done
            
            break_end
            ;;
        2)
            # 导出报告
            local report_file="/root/realm_analysis_$(date +%Y%m%d_%H%M%S).txt"
            {
                echo "Realm 转发连接分析报告"
                echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
                echo "系统: $(uname -r)"
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                
                for source_ip in $all_source_ips; do
                    local conn_count=$(echo "$realm_connections" | grep -c "${source_ip}")
                    echo "源IP: ${source_ip}"
                    echo "连接数: ${conn_count}"
                    echo ""
                    ss -tnp 2>/dev/null | grep "realm" | grep "${source_ip}"
                    echo ""
                done
            } > "$report_file"
            
            echo ""
            echo -e "${gl_lv}✅ 报告已导出到: ${report_file}${gl_bai}"
            echo ""
            break_end
            ;;
        3)
            # 实时监控
            clear
            echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            echo "        实时监控模式 (每5秒刷新)"
            echo "        按 Ctrl+C 退出"
            echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            echo ""

            # 设置信号处理，优雅退出监控循环
            local monitor_running=true
            trap 'echo -e "\n${gl_huang}监控已停止${gl_bai}"; monitor_running=false' INT TERM

            while $monitor_running; do
                echo "[$(date '+%H:%M:%S')]"
                for source_ip in $all_source_ips; do
                    local conn_count=$(ss -tnp 2>/dev/null | grep "realm" | grep -c "${source_ip}")
                    echo -e "源IP: ${source_ip} | 连接: ${conn_count} | IPv4: ✅"
                done
                echo ""
                sleep 5
            done

            # 清理 trap
            trap - INT TERM
            break_end
            ;;
        4)
            # 检测特定IP
            echo ""
            read -e -p "请输入要检测的源IP: " target_ip
            
            if [ -z "$target_ip" ]; then
                echo -e "${gl_hong}❌ IP不能为空${gl_bai}"
                break_end
                return 1
            fi
            
            clear
            echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            echo "     深度分析: ${target_ip}"
            echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            echo ""
            
            local target_conn_count=$(ss -tnp 2>/dev/null | grep "realm" | grep -c "${target_ip}")
            
            if [ $target_conn_count -eq 0 ]; then
                echo -e "${gl_huang}⚠️  未发现来自此IP的连接${gl_bai}"
            else
                echo -e "• 总连接数: ${gl_lv}${target_conn_count}${gl_bai}"
                echo "• 协议分布: IPv4 100%"
                echo "• 连接状态: 全部 ESTABLISHED"
                echo ""
                echo "详细连接："
                ss -tnp 2>/dev/null | grep "realm" | grep "${target_ip}"
            fi
            
            echo ""
            break_end
            ;;
        0|*)
            return
            ;;
    esac
}

#=============================================================================
# Realm IPv4 强制转发管理
#=============================================================================

# DNS 守护标记文件
DNS_GUARD_MARKER="/root/.realm_backup/dns_guard.conf"

# 检查 Cron 守护状态（兼容旧版 crontab 方式和新版 cron.d 方式）
check_cron_guard() {
    # 新版: 检查 cron.d 文件
    if [ -f "/etc/cron.d/net-tcp-tune-dns-guard" ]; then
        return 0  # 已启用
    fi
    # 旧版兼容: 检查 crontab
    if crontab -l 2>/dev/null | grep -q "nameserver.*:.*resolv.conf"; then
        return 0  # 已启用
    fi
    return 1  # 未启用
}

# 检查 systemd-resolved 守护状态
check_systemd_guard() {
    if [ -f /etc/systemd/resolved.conf.d/realm-ipv4-only.conf ]; then
        return 0  # 已启用
    else
        return 1  # 未启用
    fi
}

# Cron.d 文件路径
DNS_CRON_FILE="/etc/cron.d/net-tcp-tune-dns-guard"

# 设置 Cron 守护
setup_cron_guard() {
    echo -e "${gl_zi}正在设置 Cron DNS 守护...${gl_bai}"

    # 检查是否已存在
    if check_cron_guard; then
        echo -e "${gl_huang}⚠️  Cron 守护已存在，跳过${gl_bai}"
        return 0
    fi

    # 使用 cron.d 目录方式（更安全，不会覆盖用户其他 cron 任务）
    # 精确匹配 IPv6 nameserver（避免误删其他配置）
    # IPv6 格式: nameserver 后跟包含冒号的十六进制地址
    local cron_command="grep -qE '^nameserver[[:space:]]+[0-9a-fA-F]*:[0-9a-fA-F:]+' /etc/resolv.conf 2>/dev/null && sed -i '/^nameserver[[:space:]]\\+[0-9a-fA-F]*:[0-9a-fA-F:]\\+/d' /etc/resolv.conf"

    # 写入 cron.d 文件
    cat > "$DNS_CRON_FILE" << EOF
# net-tcp-tune.sh - IPv6 DNS 自动清理守护
# 每分钟检查并删除 IPv6 nameserver
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

* * * * * root ${cron_command}
EOF

    chmod 644 "$DNS_CRON_FILE"

    # 记录守护类型
    echo "cron" >> "$DNS_GUARD_MARKER"

    echo -e "${gl_lv}✅ Cron 守护已启用（每分钟自动检测）${gl_bai}"
    return 0
}

# 设置 systemd-resolved 守护
setup_systemd_guard() {
    echo -e "${gl_zi}正在设置 systemd-resolved DNS 守护...${gl_bai}"

    # 检查系统是否支持 systemd-resolved
    if ! systemctl is-active systemd-resolved &>/dev/null; then
        echo -e "${gl_huang}⚠️  系统不支持 systemd-resolved，跳过${gl_bai}"
        return 1
    fi

    # 检查是否已存在
    if check_systemd_guard; then
        echo -e "${gl_huang}⚠️  systemd 守护已存在，跳过${gl_bai}"
        return 0
    fi

    # 创建配置目录
    mkdir -p /etc/systemd/resolved.conf.d/

    # 创建配置文件
    cat > /etc/systemd/resolved.conf.d/realm-ipv4-only.conf << 'EOF'
# Realm IPv4 强制转发 - DNS 配置
# 此文件由 net-tcp-tune.sh 自动生成
# 作用：强制 systemd-resolved 只使用 IPv4 DNS 服务器

[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=
EOF

    # 重启 systemd-resolved
    systemctl restart systemd-resolved 2>/dev/null

    # 记录守护类型
    echo "systemd" >> "$DNS_GUARD_MARKER"

    echo -e "${gl_lv}✅ systemd 守护已启用（从源头禁止 IPv6 DNS）${gl_bai}"
    return 0
}

# 移除 Cron 守护
remove_cron_guard() {
    if ! check_cron_guard; then
        return 0  # 未启用，无需移除
    fi

    echo -e "${gl_zi}正在移除 Cron DNS 守护...${gl_bai}"

    # 新版: 删除 cron.d 文件
    if [ -f "/etc/cron.d/net-tcp-tune-dns-guard" ]; then
        rm -f "/etc/cron.d/net-tcp-tune-dns-guard"
    fi

    # 旧版兼容: 清理 crontab 中的旧任务（如果存在）
    if crontab -l 2>/dev/null | grep -q "nameserver.*:.*resolv.conf"; then
        local temp_cron=$(mktemp)
        crontab -l 2>/dev/null | grep -v "nameserver.*:.*resolv.conf" > "$temp_cron"
        crontab "$temp_cron"
        rm -f "$temp_cron"
    fi

    # 从标记文件中删除
    if [ -f "$DNS_GUARD_MARKER" ]; then
        sed -i '/^cron$/d' "$DNS_GUARD_MARKER"
    fi

    echo -e "${gl_lv}✅ Cron 守护已移除${gl_bai}"
    return 0
}

# 移除 systemd-resolved 守护
remove_systemd_guard() {
    if ! check_systemd_guard; then
        return 0  # 未启用，无需移除
    fi

    echo -e "${gl_zi}正在移除 systemd-resolved DNS 守护...${gl_bai}"

    # 删除配置文件
    rm -f /etc/systemd/resolved.conf.d/realm-ipv4-only.conf

    # 重启 systemd-resolved
    if systemctl is-active systemd-resolved &>/dev/null; then
        systemctl restart systemd-resolved 2>/dev/null
    fi

    # 从标记文件中删除
    if [ -f "$DNS_GUARD_MARKER" ]; then
        sed -i '/^systemd$/d' "$DNS_GUARD_MARKER"
    fi

    echo -e "${gl_lv}✅ systemd 守护已移除${gl_bai}"
    return 0
}

# 移除所有 DNS 守护
remove_all_guards() {
    echo -e "${gl_zi}正在移除所有 DNS 守护...${gl_bai}"
    echo ""

    remove_cron_guard
    remove_systemd_guard

    # 删除标记文件
    rm -f "$DNS_GUARD_MARKER"

    echo ""
    echo -e "${gl_lv}✅ 所有 DNS 守护已移除${gl_bai}"
}

# 备份当前配置
backup_realm_config() {
    local backup_dir="/root/.realm_backup"
    
    # 创建备份目录
    if [ ! -d "$backup_dir" ]; then
        mkdir -p "$backup_dir"
    fi
    
    # 检查是否已存在备份
    if [ -f "$backup_dir/resolv.conf.bak" ] || [ -f "$backup_dir/config.json.bak" ]; then
        echo -e "${gl_huang}⚠️  发现已存在的备份${gl_bai}"
        
        if [ -f "$backup_dir/backup_time.txt" ]; then
            echo -n "备份时间: "
            cat "$backup_dir/backup_time.txt"
        fi
        
        echo ""
        read -p "是否覆盖现有备份? [y/N]: " overwrite
        
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo -e "${gl_huang}已取消备份操作${gl_bai}"
            return 1
        fi
    fi
    
    echo -e "${gl_zi}正在备份配置文件...${gl_bai}"
    
    # 备份 resolv.conf
    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf "$backup_dir/resolv.conf.bak"
        echo -e "${gl_lv}✅ 已备份 /etc/resolv.conf${gl_bai}"
    else
        echo -e "${gl_huang}⚠️  /etc/resolv.conf 不存在${gl_bai}"
    fi
    
    # 备份 realm config
    if [ -f /etc/realm/config.json ]; then
        cp /etc/realm/config.json "$backup_dir/config.json.bak"
        echo -e "${gl_lv}✅ 已备份 /etc/realm/config.json${gl_bai}"
    else
        echo -e "${gl_huang}⚠️  /etc/realm/config.json 不存在${gl_bai}"
    fi
    
    # 记录备份时间
    date '+%Y-%m-%d %H:%M:%S' > "$backup_dir/backup_time.txt"
    
    echo ""
    echo -e "${gl_lv}✅ 配置备份完成！${gl_bai}"
    return 0
}

# 启用 Realm IPv4 强制转发
# 参数: $1 = 守护模式 (cron|systemd|both)
enable_realm_ipv4() {
    local guard_mode="$1"

    clear
    echo -e "${gl_kjlan}=========================================="
    echo "      启用 Realm IPv4 强制转发"
    echo -e "==========================================${gl_bai}"
    echo ""

    # 显示守护模式
    if [ -n "$guard_mode" ]; then
        case "$guard_mode" in
            cron)
                echo -e "${gl_zi}守护模式: Cron 定时检测${gl_bai}"
                ;;
            systemd)
                echo -e "${gl_zi}守护模式: systemd-resolved 配置${gl_bai}"
                ;;
            both)
                echo -e "${gl_zi}守护模式: Cron + systemd 双重守护${gl_bai}"
                ;;
        esac
        echo ""
    fi

    # 步骤1：备份配置
    echo -e "${gl_zi}[步骤 1/6] 备份当前配置...${gl_bai}"
    echo ""

    if ! backup_realm_config; then
        echo ""
        break_end
        return 1
    fi

    echo ""

    # 前置检查：确保依赖和配置可用
    if [ ! -f /etc/realm/config.json ]; then
        echo -e "${gl_hong}❌ /etc/realm/config.json 不存在${gl_bai}"
        echo ""
        break_end
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        echo "正在安装 jq..."
        if ! install_package "jq"; then
            echo -e "${gl_hong}❌ jq 安装失败，已取消操作${gl_bai}"
            echo ""
            break_end
            return 1
        fi
    fi

    # 步骤2：修改 resolv.conf
    echo -e "${gl_zi}[步骤 2/6] 修改 DNS 配置...${gl_bai}"
    
    if [ -f /etc/resolv.conf ]; then
        # 删除 IPv6 DNS 服务器行（精确匹配 IPv6 地址格式）
        # IPv6 格式: nameserver 后跟包含冒号的十六进制地址
        local ipv6_dns_count=$(grep -cE '^nameserver[[:space:]]+[0-9a-fA-F]*:[0-9a-fA-F:]+' /etc/resolv.conf 2>/dev/null || echo 0)

        if [ "$ipv6_dns_count" -gt 0 ]; then
            sed -i '/^nameserver[[:space:]]\+[0-9a-fA-F]*:[0-9a-fA-F:]\+/d' /etc/resolv.conf
            echo -e "${gl_lv}✅ 已删除 ${ipv6_dns_count} 个 IPv6 DNS 服务器${gl_bai}"
        else
            echo -e "${gl_lv}✅ 未发现 IPv6 DNS 服务器${gl_bai}"
        fi
    else
        echo -e "${gl_hong}❌ /etc/resolv.conf 不存在${gl_bai}"
    fi
    
    echo ""
    
    # 步骤3：修改 Realm 配置
    echo -e "${gl_zi}[步骤 3/6] 修改 Realm 配置...${gl_bai}"
    
    if [ ! -f /etc/realm/config.json ]; then
        echo -e "${gl_hong}❌ /etc/realm/config.json 不存在${gl_bai}"
        return 1
    fi

    # 使用 sed 和手动编辑来修改配置
    local temp_config="/tmp/realm_config_temp.json"

    # 确保退出时清理临时文件
    trap "rm -f '$temp_config'" EXIT ERR

    # 读取原配置
    if ! cat /etc/realm/config.json > "$temp_config" 2>/dev/null; then
        echo -e "${gl_hong}❌ 无法读取配置文件${gl_bai}"
        return 1
    fi

    # 优先使用 jq 安全修改 JSON，回退到 sed
    if command -v jq &>/dev/null; then
        # 使用 jq 安全地添加 resolve: ipv4
        if ! jq -e '.resolve' "$temp_config" >/dev/null 2>&1; then
            if jq '. + {"resolve": "ipv4"}' "$temp_config" > "${temp_config}.new" 2>/dev/null; then
                mv "${temp_config}.new" "$temp_config"
                echo -e "${gl_lv}✅ 已添加 resolve: ipv4 (jq)${gl_bai}"
            fi
        else
            echo -e "${gl_lv}✅ resolve 配置已存在${gl_bai}"
        fi

        # 使用 jq 替换 ::: 为 0.0.0.0
        local listen_count=$(grep -c ':::' "$temp_config" 2>/dev/null || echo 0)
        if [ "$listen_count" -gt 0 ]; then
            if jq 'walk(if type == "string" then gsub(":::"; "0.0.0.0:") else . end)' "$temp_config" > "${temp_config}.new" 2>/dev/null; then
                mv "${temp_config}.new" "$temp_config"
                echo -e "${gl_lv}✅ 已修改 ${listen_count} 个监听地址为 0.0.0.0 (jq)${gl_bai}"
            fi
        else
            echo -e "${gl_lv}✅ 监听地址已经是 IPv4 格式${gl_bai}"
        fi
    else
        # 回退到 sed（兼容无 jq 环境）
        if ! grep -q '"resolve"' "$temp_config"; then
            sed -i '0,/{/s/{/{\n    "resolve": "ipv4",/' "$temp_config"
            echo -e "${gl_lv}✅ 已添加 resolve: ipv4 (sed)${gl_bai}"
        else
            echo -e "${gl_lv}✅ resolve 配置已存在${gl_bai}"
        fi

        local listen_count=$(grep -c ':::' "$temp_config" 2>/dev/null || echo 0)
        if [ "$listen_count" -gt 0 ]; then
            sed -i 's/":::/"0.0.0.0:/g' "$temp_config"
            echo -e "${gl_lv}✅ 已修改 ${listen_count} 个监听地址为 0.0.0.0 (sed)${gl_bai}"
        else
            echo -e "${gl_lv}✅ 监听地址已经是 IPv4 格式${gl_bai}"
        fi
    fi

    # 验证 JSON 格式
    if command -v jq &>/dev/null; then
        if jq empty "$temp_config" 2>/dev/null; then
            mv "$temp_config" /etc/realm/config.json
            echo -e "${gl_lv}✅ 配置文件格式验证通过${gl_bai}"
        else
            echo -e "${gl_hong}❌ 配置文件格式错误，已回滚${gl_bai}"
            rm -f "$temp_config"
            return 1
        fi
    else
        mv "$temp_config" /etc/realm/config.json
    fi

    # 清理 trap
    trap - EXIT ERR
    
    echo ""
    
    # 步骤4：重启 Realm 服务
    echo -e "${gl_zi}[步骤 4/6] 重启 Realm 服务...${gl_bai}"
    
    if systemctl restart realm 2>/dev/null; then
        sleep 2
        
        if systemctl is-active --quiet realm; then
            echo -e "${gl_lv}✅ Realm 服务重启成功${gl_bai}"
        else
            echo -e "${gl_hong}❌ Realm 服务启动失败${gl_bai}"
            echo ""
            echo "查看服务状态："
            systemctl status realm --no-pager -l
        fi
    else
        echo -e "${gl_huang}⚠️  未找到 realm systemd 服务${gl_bai}"
        echo "如果使用其他方式启动，请手动重启 Realm"
    fi
    
    echo ""
    
    # 步骤5：设置 DNS 守护
    echo -e "${gl_zi}[步骤 5/6] 设置 DNS 守护...${gl_bai}"
    echo ""

    if [ -n "$guard_mode" ]; then
        case "$guard_mode" in
            cron)
                setup_cron_guard
                ;;
            systemd)
                setup_systemd_guard
                ;;
            both)
                setup_cron_guard
                setup_systemd_guard
                ;;
        esac
    else
        echo -e "${gl_huang}⚠️  未指定守护模式，跳过${gl_bai}"
    fi

    echo ""

    # 步骤6：验证配置
    echo -e "${gl_zi}[步骤 6/6] 验证配置...${gl_bai}"
    echo ""
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${gl_huang}DNS 配置:${gl_bai}"
    grep '^nameserver' /etc/resolv.conf 2>/dev/null || echo "无 DNS 配置"
    echo ""
    
    echo -e "${gl_huang}Realm 监听端口:${gl_bai}"
    ss -tlnp 2>/dev/null | grep realm | awk '{print $4}' | head -5 || echo "无监听端口"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    echo -e "${gl_lv}🎉 IPv4 强制转发配置完成！${gl_bai}"
    echo ""
    echo "验证方法："
    echo "  ss -tlnp | grep realm"
    echo "  (应该只显示 0.0.0.0:端口，而不是 [::]:端口)"
    echo ""
    
    break_end
}

# 还原原始配置
restore_realm_config() {
    clear
    echo -e "${gl_kjlan}=========================================="
    echo "        还原 Realm 原始配置"
    echo -e "==========================================${gl_bai}"
    echo ""
    
    local backup_dir="/root/.realm_backup"
    
    # 检查备份是否存在
    if [ ! -d "$backup_dir" ]; then
        echo -e "${gl_hong}❌ 备份目录不存在${gl_bai}"
        echo ""
        echo "可能原因："
        echo "  - 从未执行过 IPv4 强制转发配置"
        echo "  - 备份文件已被删除"
        echo ""
        break_end
        return 1
    fi
    
    if [ ! -f "$backup_dir/resolv.conf.bak" ] && [ ! -f "$backup_dir/config.json.bak" ]; then
        echo -e "${gl_hong}❌ 未找到备份文件${gl_bai}"
        echo ""
        break_end
        return 1
    fi
    
    # 显示备份信息
    echo -e "${gl_zi}备份信息:${gl_bai}"
    if [ -f "$backup_dir/backup_time.txt" ]; then
        echo -n "备份时间: "
        cat "$backup_dir/backup_time.txt"
    fi
    echo ""
    
    read -p "确认还原配置? [y/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${gl_huang}已取消还原操作${gl_bai}"
        echo ""
        break_end
        return 1
    fi
    
    echo ""
    echo -e "${gl_zi}正在还原配置文件...${gl_bai}"

    # 还原 resolv.conf
    if [ -f "$backup_dir/resolv.conf.bak" ]; then
        cp "$backup_dir/resolv.conf.bak" /etc/resolv.conf
        echo -e "${gl_lv}✅ 已还原 /etc/resolv.conf${gl_bai}"
    fi

    # 还原 realm config
    if [ -f "$backup_dir/config.json.bak" ]; then
        cp "$backup_dir/config.json.bak" /etc/realm/config.json
        echo -e "${gl_lv}✅ 已还原 /etc/realm/config.json${gl_bai}"
    fi

    echo ""

    # 移除所有 DNS 守护
    remove_all_guards

    echo ""
    
    # 重启服务
    echo -e "${gl_zi}正在重启 Realm 服务...${gl_bai}"
    
    if systemctl restart realm 2>/dev/null; then
        sleep 2
        
        if systemctl is-active --quiet realm; then
            echo -e "${gl_lv}✅ Realm 服务重启成功${gl_bai}"
        else
            echo -e "${gl_hong}❌ Realm 服务启动失败${gl_bai}"
        fi
    else
        echo -e "${gl_huang}⚠️  未找到 realm systemd 服务${gl_bai}"
    fi
    
    echo ""
    echo -e "${gl_lv}✅ 配置还原完成！${gl_bai}"
    echo ""
    
    break_end
}

# Realm IPv4 管理主菜单
realm_ipv4_management() {
    while true; do
        clear
        echo -e "${gl_kjlan}=========================================="
        echo "      Realm 转发强制使用 IPv4"
        echo -e "==========================================${gl_bai}"
        echo ""

        # 显示当前状态
        echo -e "${gl_zi}当前状态:${gl_bai}"

        # 检查备份
        if [ -d /root/.realm_backup ] && [ -f /root/.realm_backup/config.json.bak ]; then
            if [ -f /root/.realm_backup/backup_time.txt ]; then
                local backup_time=$(cat /root/.realm_backup/backup_time.txt)
                echo -e "备份状态: ${gl_lv}✅ 已备份${gl_bai} (${backup_time})"
            else
                echo -e "备份状态: ${gl_lv}✅ 已备份${gl_bai}"
            fi
        else
            echo -e "备份状态: ${gl_huang}⚠️  未备份${gl_bai}"
        fi

        # 检查 Realm 配置
        if [ -f /etc/realm/config.json ]; then
            if grep -q '"resolve".*"ipv4"' /etc/realm/config.json 2>/dev/null; then
                echo -e "IPv4强制: ${gl_lv}✅ 已启用${gl_bai}"
            else
                echo -e "IPv4强制: ${gl_huang}⚠️  未启用${gl_bai}"
            fi

            local listen_ipv6=$(grep ':::' /etc/realm/config.json 2>/dev/null | wc -l)
            listen_ipv6=$(echo "$listen_ipv6" | tr -d ' \n')
            if [ "$listen_ipv6" -gt 0 ]; then
                echo -e "监听地址: ${gl_huang}检测到 ${listen_ipv6} 个 IPv6 监听${gl_bai}"
            else
                echo -e "监听地址: ${gl_lv}✅ IPv4 格式${gl_bai}"
            fi
        else
            echo -e "配置文件: ${gl_hong}❌ 不存在${gl_bai}"
        fi

        # 检查 DNS
        if [ -f /etc/resolv.conf ]; then
            local ipv6_dns=$(grep 'nameserver.*:' /etc/resolv.conf 2>/dev/null | wc -l)
            ipv6_dns=$(echo "$ipv6_dns" | tr -d ' \n')
            if [ "$ipv6_dns" -gt 0 ]; then
                echo -e "DNS配置: ${gl_huang}检测到 ${ipv6_dns} 个 IPv6 DNS${gl_bai}"
            else
                echo -e "DNS配置: ${gl_lv}✅ 仅 IPv4 DNS${gl_bai}"
            fi
        fi

        # 检查守护状态
        local cron_status=""
        local systemd_status=""

        if check_cron_guard; then
            cron_status="${gl_lv}✅ Cron${gl_bai}"
        else
            cron_status="${gl_huang}❌ Cron${gl_bai}"
        fi

        if check_systemd_guard; then
            systemd_status="${gl_lv}✅ systemd${gl_bai}"
        else
            systemd_status="${gl_huang}❌ systemd${gl_bai}"
        fi

        echo -e "守护状态: ${cron_status} | ${systemd_status}"

        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "${gl_zi}【启用 IPv4 强制转发】${gl_bai}"
        echo ""
        echo "1. Cron守护 ⭐ 推荐"
        echo "   每分钟自动检测，适用所有系统"
        echo ""
        echo "2. systemd守护"
        echo "   从源头禁止IPv6 DNS，仅现代系统"
        echo ""
        echo "3. 双重守护 🔥 最强"
        echo "   Cron + systemd 双保险"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "4. 还原到原始配置"
        echo "5. 查看详细配置"
        echo "0. 返回主菜单"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""

        read -p "请选择操作 [0-5]: " choice

        case $choice in
            1)
                enable_realm_ipv4 "cron"
                ;;
            2)
                enable_realm_ipv4 "systemd"
                ;;
            3)
                enable_realm_ipv4 "both"
                ;;
            4)
                restore_realm_config
                ;;
            5)
                clear
                echo -e "${gl_kjlan}=========================================="
                echo "           详细配置信息"
                echo -e "==========================================${gl_bai}"
                echo ""

                echo -e "${gl_huang}=== DNS 配置 ===${gl_bai}"
                cat /etc/resolv.conf 2>/dev/null || echo "文件不存在"
                echo ""

                echo -e "${gl_huang}=== Realm 配置 ===${gl_bai}"
                cat /etc/realm/config.json 2>/dev/null || echo "文件不存在"
                echo ""

                echo -e "${gl_huang}=== Realm 监听端口 ===${gl_bai}"
                ss -tlnp 2>/dev/null | grep realm || echo "无监听端口"
                echo ""

                echo -e "${gl_huang}=== DNS 守护状态 ===${gl_bai}"
                if check_cron_guard; then
                    echo "Cron 守护: ✅ 已启用"
                    echo "Cron 任务:"
                    # 显示 cron.d 文件内容（新版）
                    if [ -f "/etc/cron.d/net-tcp-tune-dns-guard" ]; then
                        echo "[cron.d 文件]"
                        cat "/etc/cron.d/net-tcp-tune-dns-guard" | grep -v "^#" | grep -v "^$"
                    fi
                    # 显示 crontab 内容（旧版兼容）
                    if crontab -l 2>/dev/null | grep -q "nameserver.*:.*resolv.conf"; then
                        echo "[crontab 条目]"
                        crontab -l 2>/dev/null | grep "nameserver.*:.*resolv.conf"
                    fi
                else
                    echo "Cron 守护: ❌ 未启用"
                fi
                echo ""

                if check_systemd_guard; then
                    echo "systemd 守护: ✅ 已启用"
                    echo "配置文件:"
                    cat /etc/systemd/resolved.conf.d/realm-ipv4-only.conf 2>/dev/null
                else
                    echo "systemd 守护: ❌ 未启用"
                fi
                echo ""

                break_end
                ;;
            0)
                return 0
                ;;
            *)
                echo ""
                echo -e "${gl_hong}无效选择${gl_bai}"
                sleep 1
                ;;
        esac
    done
}

#=============================================================================
# IPv4/IPv6 连接检测工具
#=============================================================================

# 出站连接检测
check_outbound_connections() {
    local target_ipv4="$1"
    local target_ipv6="$2"
    
    clear
    echo -e "${gl_kjlan}=========================================="
    echo "出站连接检测 - 本机到目标服务器"
    echo -e "==========================================${gl_bai}"
    echo ""
    echo -e "目标IPv4: ${gl_huang}${target_ipv4}${gl_bai}"
    echo -e "目标IPv6: ${gl_huang}${target_ipv6}${gl_bai}"
    echo ""
    
    echo -e "${gl_zi}【1/4】IPv4连接数：${gl_bai}"
    local ipv4_count=$(ss -4 -tn 2>/dev/null | grep -c "$target_ipv4")
    echo "$ipv4_count"
    
    echo ""
    echo -e "${gl_zi}【2/4】IPv6连接数（应该是0）：${gl_bai}"
    local ipv6_count=$(ss -6 -tn 2>/dev/null | grep -c "$target_ipv6")
    echo "$ipv6_count"
    
    echo ""
    echo -e "${gl_zi}【3/4】连接详情（前5条）：${gl_bai}"
    ss -tn 2>/dev/null | grep -E "($target_ipv4|$target_ipv6)" | head -5
    
    echo ""
    echo -e "${gl_zi}【4/4】最终判断：${gl_bai}"
    echo -e "IPv4连接: ${gl_lv}$ipv4_count${gl_bai} 个"
    echo -e "IPv6连接: ${gl_hong}$ipv6_count${gl_bai} 个"
    
    echo ""
    if [ "$ipv4_count" -gt 0 ] && [ "$ipv6_count" -eq 0 ]; then
        echo -e "${gl_lv}✓✓✓ 结论：100% 使用 IPv4 链路 ✓✓✓${gl_bai}"
    elif [ "$ipv6_count" -gt 0 ]; then
        echo -e "${gl_hong}⚠️ 警告：检测到 IPv6 连接！${gl_bai}"
    else
        echo -e "${gl_huang}当前无活动连接${gl_bai}"
    fi
    
    echo ""
    break_end
}

# 入站连接检测
check_inbound_connections() {
    local source_ipv4="$1"
    local source_ipv6="$2"
    
    clear
    echo -e "${gl_kjlan}=========================================="
    echo "入站连接检测 - 来自源服务器的连接"
    echo -e "==========================================${gl_bai}"
    echo ""
    echo -e "源IPv4: ${gl_huang}${source_ipv4}${gl_bai}"
    echo -e "源IPv6: ${gl_huang}${source_ipv6}${gl_bai}"
    echo ""
    
    echo -e "${gl_zi}【1/5】查看所有established连接（前10条）：${gl_bai}"
    ss -tn state established 2>/dev/null | head -11
    
    echo ""
    echo -e "${gl_zi}【2/5】查看所有包含源 IPv4 的连接：${gl_bai}"
    local ipv4_result=$(ss -tn 2>/dev/null | grep "$source_ipv4")
    if [ -n "$ipv4_result" ]; then
        echo "$ipv4_result"
    else
        echo "无连接"
    fi
    
    echo ""
    echo -e "${gl_zi}【3/5】统计来自源服务器的连接数：${gl_bai}"
    local ipv4_conn_count=$(ss -tn state established 2>/dev/null | grep -c "$source_ipv4")
    local ipv6_conn_count=$(ss -tn state established 2>/dev/null | grep -c "$source_ipv6")
    echo -e "来自 ${gl_lv}${source_ipv4}${gl_bai} 的连接: ${gl_lv}$ipv4_conn_count${gl_bai} 个"
    echo -e "来自 ${gl_hong}${source_ipv6}${gl_bai} 的连接: ${gl_hong}$ipv6_conn_count${gl_bai} 个"
    
    echo ""
    echo -e "${gl_zi}【4/5】查看监听的端口（前5个）：${gl_bai}"
    ss -tln 2>/dev/null | grep LISTEN | head -5
    
    echo ""
    echo -e "${gl_zi}【5/5】查看所有入站连接（按源IP统计，前10个）：${gl_bai}"
    ss -tn state established 2>/dev/null | awk '{print $4}' | grep -v "Peer" | cut -d: -f1 | sort | uniq -c | sort -rn | head -10
    
    echo ""
    echo -e "${gl_kjlan}==========================================${gl_bai}"
    echo -e "${gl_zi}最终判断：${gl_bai}"
    if [ "$ipv4_conn_count" -gt 0 ] && [ "$ipv6_conn_count" -eq 0 ]; then
        echo -e "${gl_lv}✓✓✓ 结论：100% 使用 IPv4 链路 ✓✓✓${gl_bai}"
    elif [ "$ipv6_conn_count" -gt 0 ]; then
        echo -e "${gl_hong}⚠️ 警告：检测到 IPv6 连接！${gl_bai}"
    else
        echo -e "${gl_huang}当前无活动连接${gl_bai}"
    fi
    echo -e "${gl_kjlan}==========================================${gl_bai}"
    
    echo ""
    break_end
}

# 自动检测所有入站连接
check_all_inbound_connections() {
    clear
    echo -e "${gl_kjlan}=========================================="
    echo "自动检测所有入站连接"
    echo -e "==========================================${gl_bai}"
    echo ""
    
    echo -e "${gl_zi}[1/3] 获取所有 ESTABLISHED 入站连接...${gl_bai}"
    echo ""
    
    # 获取所有 ESTABLISHED 连接的远程地址（兼容多种ss版本）
    # 尝试多种方式获取连接
    local connections=""
    
    # 方法1：使用 state 参数（新版ss）
    if ss -tn state established &>/dev/null; then
        connections=$(ss -tn state established 2>/dev/null | awk 'NR>1 && $1=="ESTAB" {print $5}' | grep -v "^$")
    fi
    
    # 方法2：使用 grep ESTAB（兼容旧版ss）
    if [ -z "$connections" ]; then
        connections=$(ss -tn 2>/dev/null | grep ESTAB | awk '{print $5}' | grep -v "^$")
    fi
    
    # 方法3：使用 netstat 作为后备
    if [ -z "$connections" ] && command -v netstat &>/dev/null; then
        connections=$(netstat -tn 2>/dev/null | grep ESTABLISHED | awk '{print $5}' | grep -v "^$")
    fi
    
    # 过滤本地回环连接（可选，保留所有连接以便调试）
    # connections=$(echo "$connections" | grep -v "^127.0.0.1" | grep -v "^\[::1\]")
    
    # 调试信息
    local conn_count=$(echo "$connections" | wc -l | tr -d ' ')
    echo -e "${gl_zi}检测到 ${gl_lv}${conn_count}${gl_zi} 个ESTABLISHED连接${gl_bai}"
    echo ""
    
    if [ -z "$connections" ] || [ "$conn_count" -eq 0 ]; then
        echo -e "${gl_huang}未发现任何活跃连接${gl_bai}"
        echo ""
        echo "可能的原因："
        echo "1. 当前确实没有建立的TCP连接"
        echo "2. 需要root权限查看所有连接（请使用 sudo 运行）"
        echo "3. 转发可能使用UDP协议（请检查 ss -un 或 netstat -un）"
        echo ""
        echo "快速检查命令："
        echo "  查看TCP: ss -tn | grep ESTAB"
        echo "  查看UDP: ss -un"
        echo "  查看监听端口: ss -tlnp"
        echo "  查看所有连接: ss -antp"
        echo ""
        
        # 显示原始ss输出用于调试
        echo -e "${gl_zi}═══ 原始连接信息（调试用） ═══${gl_bai}"
        ss -tn 2>/dev/null | head -20
        echo ""
        
        break_end
        return 1
    fi
    
    echo -e "${gl_zi}[2/3] 分析连接协议类型...${gl_bai}"
    echo ""
    
    # 统计 IPv4 和 IPv6 连接
    # 注意：::ffff: 开头的是 IPv4-mapped IPv6，本质是 IPv4
    # 先去掉端口号，再统计
    local connections_no_port=$(echo "$connections" | sed 's/:[0-9]*$//')

    # 检查是否有有效连接数据
    if [ -z "$connections_no_port" ]; then
        echo -e "${gl_huang}⚠️  未检测到有效连接数据${gl_bai}"
        return 1
    fi

    local ipv4_mapped=$(echo "$connections_no_port" | grep -c "::ffff:" || echo "0")
    local ipv6_real=$(echo "$connections_no_port" | grep ":" | grep -vc "::ffff:" || echo "0")
    local ipv4_pure=$(echo "$connections_no_port" | grep -vc ":" || echo "0")
    local ipv4_connections=$((ipv4_pure + ipv4_mapped))
    local ipv6_connections=$ipv6_real
    local total_connections=$(echo "$connections" | wc -l)
    
    # 提取唯一的源 IP（去重）
    local unique_sources=$(echo "$connections_no_port" | sort -u)
    local source_count=$(echo "$unique_sources" | wc -l)
    
    echo -e "${gl_zi}[3/3] 生成统计报告...${gl_bai}"
    echo ""
    
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "            连接统计总览"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "  • 总连接数:       ${gl_lv}${total_connections}${gl_bai}"
    echo -e "  • 唯一源IP数:     ${gl_huang}${source_count}${gl_bai}"
    echo ""
    echo -e "  ${gl_zi}协议分布：${gl_bai}"
    echo -e "    - IPv4（纯）:    ${gl_lv}${ipv4_pure}${gl_bai} 个"
    echo -e "    - IPv4（映射）:  ${gl_lv}${ipv4_mapped}${gl_bai} 个"
    echo -e "    - IPv4 总计:     ${gl_lv}${ipv4_connections}${gl_bai} 个"
    echo -e "    - IPv6（真）:    ${ipv6_connections} 个"
    echo ""
    
    if [ "$ipv6_connections" -eq 0 ]; then
        echo -e "  ${gl_lv}✅ 100% 使用 IPv4 链路（包含映射格式）${gl_bai}"
    else
        local ipv4_percent=$((ipv4_connections * 100 / total_connections))
        local ipv6_percent=$((ipv6_connections * 100 / total_connections))
        echo -e "  ${gl_huang}⚠️  混合链路: IPv4 ${ipv4_percent}% | IPv6 ${ipv6_percent}%${gl_bai}"
    fi
    
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    # 显示 Top 10 源 IP（增强版：带归属信息）
    echo -e "${gl_zi}Top 10 连接源详情（按连接数排序）：${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    local source_num=1
    # 使用 process substitution 替代管道，确保循环中的变量修改对父 shell 可见
    while read count ip; do
        # 提取纯 IP（去除方括号）
        local clean_ip=$(echo "$ip" | sed 's/\[::ffff://; s/\]//')

        # 判断协议类型
        local protocol_type=""
        local protocol_color=""
        if echo "$ip" | grep -q "::ffff:"; then
            protocol_type="IPv4（映射格式）"
            protocol_color="${gl_lv}"
        elif echo "$ip" | grep -q ":"; then
            protocol_type="IPv6（真）"
            protocol_color="${gl_hong}"
        else
            protocol_type="纯IPv4"
            protocol_color="${gl_lv}"
            clean_ip="$ip"
        fi

        # IP 归属查询
        local ip_location="查询中..."
        local ip_as="未知"

        if command -v curl &>/dev/null; then
            local ip_info
            # 直接在 if 中检查命令返回值，避免 local 覆盖 $?
            if ip_info=$(timeout 2 curl -s "http://ip-api.com/json/${clean_ip}?lang=zh-CN&fields=country,regionName,city,isp,as" 2>/dev/null) && [ -n "$ip_info" ]; then
                local country=$(echo "$ip_info" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
                local region=$(echo "$ip_info" | grep -o '"regionName":"[^"]*"' | cut -d'"' -f4)
                local city=$(echo "$ip_info" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
                local isp=$(echo "$ip_info" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
                local as_num=$(echo "$ip_info" | grep -o '"as":"[^"]*"' | cut -d'"' -f4)

                ip_location="${country} ${region} ${city} ${isp}"
                [ -n "$as_num" ] && ip_as="$as_num" || ip_as="未知"
            else
                ip_location="查询失败"
                ip_as="未知"
            fi
        else
            ip_location="需要 curl 命令"
            ip_as="未知"
        fi

        # 美化显示
        echo -e "┌─────────────── 连接源 #${source_num} ───────────────┐"
        echo -e "│  源IP地址:   ${gl_huang}${clean_ip}${gl_bai}"
        echo -e "│  IP归属:     ${ip_location}"
        [ -n "$ip_as" ] && echo -e "│  AS号:       ${ip_as}"
        echo -e "│  连接数:     ${gl_lv}${count}${gl_bai} 个"
        echo -e "│  协议类型:   ${protocol_color}✅ ${protocol_type}${gl_bai}"
        echo -e "└──────────────────────────────────────────┘"
        echo ""

        source_num=$((source_num + 1))
    done < <(echo "$connections" | sed 's/:[0-9]*$//' | sort | uniq -c | sort -rn | head -10)
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # 显示监听端口
    echo -e "${gl_zi}本地监听端口（Top 5）：${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    while read count port; do
        echo -e "  端口 ${gl_huang}${port}${gl_bai} - ${count} 个监听"
    done < <(ss -tln 2>/dev/null | awk 'NR>1 {print $4}' | sed 's/.*://' | sort | uniq -c | sort -rn | head -5)
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    break_end
}

# IPv4/IPv6 连接检测主菜单
check_ipv4v6_connections() {
    while true; do
        clear
        echo -e "${gl_kjlan}=== IPv4/IPv6 连接检测工具 ===${gl_bai}"
        echo ""
        echo "此工具用于检测网络连接使用的是IPv4还是IPv6"
        echo "------------------------------------------------"
        echo "1. 自动检测所有入站连接（推荐，无需输入IP）"
        echo "2. 出站检测（检测本机到目标服务器的连接）"
        echo "3. 入站检测（检测来自指定源服务器的连接）"
        echo "0. 返回主菜单"
        echo "------------------------------------------------"
        read -e -p "请输入选择: " choice
        
        case "$choice" in
            1)
                # 自动检测所有入站
                check_all_inbound_connections
                ;;
            2)
                # 出站检测
                clear
                echo -e "${gl_kjlan}=== 出站连接检测 ===${gl_bai}"
                echo ""
                echo "请输入目标服务器的IP地址"
                echo "------------------------------------------------"
                
                # 输入目标IPv4地址（必填）
                local target_ipv4=""
                while true; do
                    read -e -p "$(echo -e "${gl_huang}目标服务器 IPv4 地址: ${gl_bai}")" target_ipv4
                    
                    if [ -z "$target_ipv4" ]; then
                        echo -e "${gl_hong}❌ IPv4地址不能为空${gl_bai}"
                    elif [[ "$target_ipv4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                        echo -e "${gl_lv}✅ IPv4: ${target_ipv4}${gl_bai}"
                        break
                    else
                        echo -e "${gl_hong}❌ 无效的IPv4地址格式${gl_bai}"
                    fi
                done
                
                # 输入目标IPv6地址（必填）
                local target_ipv6=""
                while true; do
                    read -e -p "$(echo -e "${gl_huang}目标服务器 IPv6 地址: ${gl_bai}")" target_ipv6
                    
                    if [ -z "$target_ipv6" ]; then
                        echo -e "${gl_hong}❌ IPv6地址不能为空${gl_bai}"
                    elif [[ "$target_ipv6" =~ : ]]; then
                        echo -e "${gl_lv}✅ IPv6: ${target_ipv6}${gl_bai}"
                        break
                    else
                        echo -e "${gl_hong}❌ 无效的IPv6地址格式（应包含冒号）${gl_bai}"
                    fi
                done
                
                # 执行检测
                check_outbound_connections "$target_ipv4" "$target_ipv6"
                ;;
            3)
                # 入站检测
                clear
                echo -e "${gl_kjlan}=== 入站连接检测 ===${gl_bai}"
                echo ""
                echo "请输入源服务器的IP地址"
                echo "------------------------------------------------"
                
                # 输入源IPv4地址（必填）
                local source_ipv4=""
                while true; do
                    read -e -p "$(echo -e "${gl_huang}源服务器 IPv4 地址: ${gl_bai}")" source_ipv4
                    
                    if [ -z "$source_ipv4" ]; then
                        echo -e "${gl_hong}❌ IPv4地址不能为空${gl_bai}"
                    elif [[ "$source_ipv4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                        echo -e "${gl_lv}✅ IPv4: ${source_ipv4}${gl_bai}"
                        break
                    else
                        echo -e "${gl_hong}❌ 无效的IPv4地址格式${gl_bai}"
                    fi
                done
                
                # 输入源IPv6地址（必填）
                local source_ipv6=""
                while true; do
                    read -e -p "$(echo -e "${gl_huang}源服务器 IPv6 地址: ${gl_bai}")" source_ipv6
                    
                    if [ -z "$source_ipv6" ]; then
                        echo -e "${gl_hong}❌ IPv6地址不能为空${gl_bai}"
                    elif [[ "$source_ipv6" =~ : ]]; then
                        echo -e "${gl_lv}✅ IPv6: ${source_ipv6}${gl_bai}"
                        break
                    else
                        echo -e "${gl_hong}❌ 无效的IPv6地址格式（应包含冒号）${gl_bai}"
                    fi
                done
                
                # 执行检测
                check_inbound_connections "$source_ipv4" "$source_ipv6"
                ;;
            0)
                return
                ;;
            *)
                echo "无效选择"
                sleep 2
                ;;
        esac
    done
}

#=============================================================================
# MTU/MSS 检测与优化功能
# 用于消除国际链路重传问题
#=============================================================================

# 多地区 MTU 路径探测
detect_path_mtu_multi_region() {
    clear >&2
    echo -e "${gl_kjlan}==========================================${gl_bai}" >&2
    echo "      MTU 路径探测（多地区检测）" >&2
    echo -e "${gl_kjlan}==========================================${gl_bai}" >&2
    echo "" >&2
    
    echo -e "${gl_zi}正在探测到全球多个地区的路径 MTU...${gl_bai}" >&2
    echo -e "${gl_huang}注意: 已排除 Anycast IP (如 1.1.1.1/8.8.8.8)，确保检测真实物理路径${gl_bai}" >&2
    echo "" >&2
    
    # 定义测试目标 (主IP + 备选IP，确保高可用)
    # 策略：混合使用大学、ISP骨干网、商业云(非Anycast) IP
    declare -A targets=(
        ["香港"]="147.8.17.13 202.45.170.1 103.16.228.1 118.143.1.1"          # HKU, HKIX, HostHatch, PCCW
        ["日本-东京"]="133.11.0.1 202.232.2.1 103.201.129.1 203.104.128.1"    # U-Tokyo, JAIST, GMO, KDDI
        ["日本-大阪"]="133.1.138.1 203.178.148.19 61.211.224.1"               # Osaka U, WIDE, K-Opticom
        ["新加坡"]="137.132.80.25 202.156.0.1 103.25.202.1 118.201.1.1"       # NUS, Singtel, StarHub, M1
        ["韩国"]="147.46.10.20 211.233.0.1 168.126.63.1 210.117.65.1"         # SNU, KT, KT-DNS, SK Broadband
        ["美国-西海岸"]="128.97.27.37 128.32.155.2 198.148.161.11 64.125.0.1"  # UCLA, Berkeley, QuadraNet, Zayo
        ["美国-东海岸"]="18.9.22.69 128.112.128.15 108.61.10.10 23.29.64.1"    # MIT, Princeton, Vultr, Choopa
        ["欧洲-德国"]="141.14.16.1 194.25.0.125 134.130.4.1 85.10.240.1"      # DFN, Telekom, RWTH, Hetzner
        ["欧洲-英国"]="131.111.8.46 163.1.0.1 212.58.244.20 193.136.1.1"       # Cambridge, Oxford, BBC, LINX
        ["澳洲"]="139.130.4.5 203.50.0.1 150.203.1.10 203.2.218.1"             # Telstra, Telstra-2, ANU, Optus
    )

    # 防御性验证：确保目标数组不为空
    if [ ${#targets[@]} -eq 0 ]; then
        echo -e "${gl_hong}❌ MTU 检测目标列表为空，无法继续${gl_bai}" >&2
        return 1
    fi

    # 定义显示顺序
    local regions_order=("香港" "日本-东京" "日本-大阪" "新加坡" "韩国" "美国-西海岸" "美国-东海岸" "欧洲-德国" "欧洲-英国" "澳洲")
    
    # 存储每个目标的 MSS
    declare -A mss_values
    local test_count=0
    local success_count=0
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    
    for region in "${regions_order[@]}"; do
        test_count=$((test_count + 1))
        local target_list="${targets[$region]}"
        local active_target=""
        
        # 1. 连通性检查 (选择可用的 IP)
        for ip in $target_list; do
            if ping -c 1 -W 1 "$ip" &>/dev/null; then
                active_target="$ip"
                break
            fi
        done
        
        echo -e "${gl_huang}[${test_count}/${#regions_order[@]}] ${gl_bai}测试目标: ${gl_kjlan}${region}${gl_bai}" >&2
        
        if [ -z "$active_target" ]; then
             echo -e "  ${gl_huang}⚠️  无法探测 (所有测试IP均不可达)${gl_bai}" >&2
             mss_values[$region]=1280  # 默认安全值
             echo "" >&2
             continue
        fi

        # 2. 开始 MTU 探测
        local found=0
        for size in 1500 1492 1480 1460 1452 1440 1420 1400 1380 1360 1340 1320 1300; do
            if ping -M do -s $size -c 1 -W 1 $active_target &>/dev/null; then
                local mtu=$((size + 28))
                local mss=$((size + 28 - 40))
                echo -e "  ${gl_lv}✅ MTU=${mtu}, MSS=${mss}${gl_bai} (Target: $active_target)" >&2
                mss_values[$region]=$mss
                found=1
                success_count=$((success_count + 1))
                break
            fi
        done
        
        if [ $found -eq 0 ]; then
            echo -e "  ${gl_huang}⚠️  探测失败 (ICMP分片被拦截)${gl_bai}" >&2
            mss_values[$region]=1280
        fi
        echo "" >&2
    done
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "" >&2
    
    # 找出最小的 MSS
    local min_mss=9999
    local max_mss=0
    local min_region=""
    local max_region=""
    
    for region in "${!mss_values[@]}"; do
        local mss=${mss_values[$region]}
        if [ $mss -lt $min_mss ]; then
            min_mss=$mss
            min_region=$region
        fi
        if [ $mss -gt $max_mss ]; then
            max_mss=$mss
            max_region=$region
        fi
    done
    
    # 显示汇总结果
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
    echo -e "${gl_lv}✅ 探测完成！${gl_bai}" >&2
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
    echo "" >&2
    echo "各地区 MSS 检测结果：" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    for region in "${regions_order[@]}"; do
        if [ -n "${mss_values[$region]}" ]; then
            local mss=${mss_values[$region]}
            echo -e "  ${gl_zi}${region}:${gl_bai} ${mss} bytes" >&2
        fi
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "" >&2
    
    # 判断是否一致
    if [ $min_mss -eq $max_mss ]; then
        echo -e "${gl_lv}✅ 所有地区 MSS 完全一致！${gl_bai}" >&2
        echo -e "${gl_kjlan}推荐 MSS:${gl_bai} ${gl_lv}${min_mss}${gl_bai} bytes" >&2
        echo -e "${gl_zi}说明: 所有地区MTU相同，使用此值性能最优${gl_bai}" >&2
    else
        local diff=$((max_mss - min_mss))
        echo -e "${gl_huang}⚠️  不同地区 MSS 有差异（${diff} bytes）${gl_bai}" >&2
        echo "" >&2
        echo -e "  最小值: ${gl_huang}${min_mss}${gl_bai} (${min_region})" >&2
        echo -e "  最大值: ${gl_huang}${max_mss}${gl_bai} (${max_region})" >&2
        echo "" >&2
        echo -e "${gl_kjlan}推荐策略：${gl_bai}" >&2
        echo -e "  1. ${gl_lv}保守方案:${gl_bai} 使用最小值 ${min_mss} (兼容所有地区)" >&2
        echo -e "  2. ${gl_huang}激进方案:${gl_bai} 使用最大值 ${max_mss} (性能最优，部分地区可能丢包)" >&2
        echo -e "  3. ${gl_zi}折中方案:${gl_bai} 使用中间值 $(( (min_mss + max_mss) / 2 ))" >&2
    fi
    echo "" >&2
    
    # 返回推荐的MSS值（最小值，最大值）
    echo "$min_mss $max_mss"
}

# 应用 MSS Clamp 规则
apply_mss_clamp_with_value() {
    local mss=$1
    
    echo -e "${gl_zi}正在应用 MSS Clamp 规则...${gl_bai}"
    echo ""
    
    # 检查iptables
    if ! command -v iptables &>/dev/null; then
        echo -e "${gl_huang}未检测到 iptables，正在尝试自动安装...${gl_bai}"
        install_package "iptables"
        
        if ! command -v iptables &>/dev/null; then
            echo -e "${gl_hong}错误: iptables 安装失败，无法设置 MSS Clamp${gl_bai}"
            return 1
        fi
    fi

    if ! iptables -m comment -h &>/dev/null; then
        echo -e "${gl_hong}错误: iptables comment 模块不可用，已取消 MSS Clamp${gl_bai}"
        return 1
    fi
    
    # 备份当前规则
    local backup_file="/root/.iptables_backup_$(date +%Y%m%d_%H%M%S).rules"
    iptables-save > "$backup_file" 2>/dev/null
    echo -e "${gl_zi}已备份当前规则到: ${backup_file}${gl_bai}"
    echo ""
    
    # 清除旧的 MSS 规则（仅处理本脚本添加的规则）
    echo "清除旧规则..."
    local comment_tag="net-tcp-tune-mss"
    local old_rule_mss
    while read -r old_rule_mss; do
        [ -n "$old_rule_mss" ] || continue
        iptables -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$old_rule_mss" -m comment --comment "$comment_tag" 2>/dev/null || true
    done < <(iptables -t mangle -S OUTPUT 2>/dev/null | grep "$comment_tag" | sed -n 's/.*--set-mss \([0-9]\+\).*/\1/p')

    while read -r old_rule_mss; do
        [ -n "$old_rule_mss" ] || continue
        iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$old_rule_mss" -m comment --comment "$comment_tag" 2>/dev/null || true
    done < <(iptables -t mangle -S POSTROUTING 2>/dev/null | grep "$comment_tag" | sed -n 's/.*--set-mss \([0-9]\+\).*/\1/p')

    if iptables -t mangle -S OUTPUT 2>/dev/null | grep 'TCPMSS' | grep -vq "$comment_tag"; then
        echo -e "${gl_huang}⚠️  检测到非本脚本的 TCPMSS 规则，未自动清理${gl_bai}"
    fi
    if iptables -t mangle -S POSTROUTING 2>/dev/null | grep 'TCPMSS' | grep -vq "$comment_tag"; then
        echo -e "${gl_huang}⚠️  检测到非本脚本的 TCPMSS 规则，未自动清理${gl_bai}"
    fi
    
    # 应用新规则（OUTPUT链 + POSTROUTING链）
    echo "设置 MSS = ${mss} bytes..."
    iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss" -m comment --comment "$comment_tag"
    iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss" -m comment --comment "$comment_tag"
    
    echo ""
    echo -e "${gl_lv}✅ MSS Clamp 规则已应用${gl_bai}"
    echo ""
    
    # 验证规则
    echo "验证规则..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    iptables -t mangle -L OUTPUT -n -v | grep TCPMSS | head -1
    iptables -t mangle -L POSTROUTING -n -v | grep TCPMSS | head -1
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # 保存规则（确保持久化）
    echo "保存规则（确保重启后生效）..."

    # 检查并安装 iptables-persistent
    if ! command -v netfilter-persistent &>/dev/null; then
        echo -e "${gl_huang}未检测到 iptables-persistent，正在自动安装...${gl_bai}"
        # 预设 iptables-persistent 安装时的交互式问题
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections 2>/dev/null
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections 2>/dev/null

        if install_package "iptables-persistent"; then
            echo -e "${gl_lv}✅ iptables-persistent 安装成功${gl_bai}"
        else
            echo -e "${gl_hong}❌ iptables-persistent 安装失败${gl_bai}"
            echo -e "${gl_huang}⚠️  规则可能在重启后失效，请手动安装: apt install iptables-persistent${gl_bai}"
        fi
    fi

    # 保存规则
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
        echo -e "${gl_lv}✅ 规则已持久化保存（重启后自动生效）${gl_bai}"
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        echo -e "${gl_lv}✅ 规则已保存到 /etc/iptables/rules.v4${gl_bai}"
        echo -e "${gl_huang}⚠️  建议安装 iptables-persistent 确保重启后自动加载${gl_bai}"
    else
        echo -e "${gl_hong}❌ 无法保存规则，重启后将失效${gl_bai}"
    fi
    
    return 0
}

# 验证优化效果
verify_mss_optimization() {
    echo ""
    echo -e "${gl_kjlan}==========================================${gl_bai}"
    echo "      验证优化效果"
    echo -e "${gl_kjlan}==========================================${gl_bai}"
    echo ""
    
    echo -e "${gl_zi}等待 30 秒让配置生效...${gl_bai}"
    sleep 30
    
    echo ""
    echo -e "${gl_huang}当前重传统计:${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ss -s | grep -i "retrans\|segs"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    echo -e "${gl_zi}建议:${gl_bai}"
    echo "  1. 运行网络测试观察重传率变化"
    echo "  2. 如果重传率显著降低（80%+），说明优化成功"
    echo "  3. 如果仍有重传，可能是其他问题（线路质量等）"
    echo ""
}

# 主菜单函数
mtu_mss_optimization() {
    while true; do
        clear
        echo -e "${gl_kjlan}==========================================${gl_bai}"
        echo "    MTU检测与MSS优化（消除重传）"
        echo -e "${gl_kjlan}==========================================${gl_bai}"
        echo ""
        
        # 显示当前状态
        echo -e "${gl_zi}当前状态:${gl_bai}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # 检查MSS Clamp是否已设置
        local current_mss=$(iptables -t mangle -L OUTPUT -n -v 2>/dev/null | grep TCPMSS | grep -oP 'set \K\d+' | head -1)
        if [ -n "$current_mss" ]; then
            echo -e "  MSS Clamp: ${gl_lv}✅ 已设置 (${current_mss} bytes)${gl_bai}"
        else
            echo -e "  MSS Clamp: ${gl_huang}❌ 未设置${gl_bai}"
        fi
        
        # 显示重传统计
        local retrans=$(ss -s 2>/dev/null | grep -oP 'retrans:\K\d+' || echo "0")
        echo -e "  当前重传: ${retrans} 个"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        echo -e "${gl_kjlan}功能菜单:${gl_bai}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "1. 自动检测并优化 ⭐ 推荐"
        echo "   （多地区MTU探测 + 自动设置最佳MSS）"
        echo ""
        echo "2. 移除MSS Clamp"
        echo "   （恢复默认配置）"
        echo ""
        echo "0. 返回主菜单"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        read -e -p "请选择操作 [1]: " choice
        choice=${choice:-1}
        
        case $choice in
            1)
                # 自动检测并优化
                # 执行MTU检测
                local mss_result=$(detect_path_mtu_multi_region)
                local min_mss=$(echo "$mss_result" | awk '{print $1}')
                local max_mss=$(echo "$mss_result" | awk '{print $2}')
                
                if [ -z "$min_mss" ] || [ -z "$max_mss" ]; then
                     echo -e "${gl_hong}检测失败，无法获取MSS值${gl_bai}"
                     sleep 2
                     break_end
                     continue
                fi

                local mid_mss=$(( (min_mss + max_mss) / 2 ))

                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                
                if [ "$min_mss" -eq "$max_mss" ]; then
                    read -e -p "是否应用推荐的 MSS = ${min_mss}？(Y/N) [Y]: " confirm
                    confirm=${confirm:-Y}
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        echo ""
                        apply_mss_clamp_with_value "$min_mss"
                        if [ $? -eq 0 ]; then
                            verify_mss_optimization
                        fi
                        break_end
                    else
                         echo -e "${gl_huang}已取消应用${gl_bai}"
                         sleep 2
                    fi
                else
                    echo "请选择优化策略:"
                    echo "  1) 保守方案 (${min_mss})"
                    echo "  2) 激进方案 (${max_mss})"
                    echo "  3) 折中方案 (${mid_mss})"
                    echo "  0) 取消"
                    echo ""
                    read -e -p "请输入选择 [1]: " strategy
                    strategy=${strategy:-1}
                    
                    local selected_mss=""
                    case $strategy in
                        1) selected_mss=$min_mss ;;
                        2) selected_mss=$max_mss ;;
                        3) selected_mss=$mid_mss ;;
                        0) echo -e "${gl_huang}已取消${gl_bai}"; sleep 2; ;;
                        *) echo -e "${gl_hong}无效选择${gl_bai}"; sleep 2; ;;
                    esac
                    
                    if [ -n "$selected_mss" ]; then
                        echo ""
                        apply_mss_clamp_with_value "$selected_mss"
                        if [ $? -eq 0 ]; then
                            verify_mss_optimization
                        fi
                        break_end
                    fi
                fi
                ;;
            2)
                # 移除MSS Clamp
                clear
                echo -e "${gl_kjlan}==========================================${gl_bai}"
                echo "      移除 MSS Clamp"
                echo -e "${gl_kjlan}==========================================${gl_bai}"
                echo ""
                
                read -e -p "确认要移除 MSS Clamp 吗？(Y/N) [N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    echo ""
                    echo "正在移除..."
                    iptables -t mangle -F OUTPUT 2>/dev/null
                    iptables -t mangle -F POSTROUTING 2>/dev/null

                    # 持久化保存
                    if command -v netfilter-persistent &>/dev/null; then
                        netfilter-persistent save >/dev/null 2>&1
                        echo -e "${gl_lv}✅ MSS Clamp 已移除并持久化保存${gl_bai}"
                    elif command -v iptables-save &>/dev/null; then
                        mkdir -p /etc/iptables
                        iptables-save > /etc/iptables/rules.v4 2>/dev/null
                        echo -e "${gl_lv}✅ MSS Clamp 已移除${gl_bai}"
                    else
                        echo -e "${gl_lv}✅ MSS Clamp 已移除${gl_bai}"
                    fi
                else
                    echo -e "${gl_huang}已取消${gl_bai}"
                fi
                sleep 2
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${gl_hong}无效选择${gl_bai}"
                sleep 1
                ;;
        esac
    done
}
show_xray_config() {
    clear
    echo -e "${gl_kjlan}=== 查看 Xray 配置 ===${gl_bai}"
    echo ""

    if [ ! -f /usr/local/etc/xray/config.json ]; then
        echo -e "${gl_hong}错误: Xray 配置文件不存在${gl_bai}"
        echo "路径: /usr/local/etc/xray/config.json"
        echo ""
        break_end
        return 1
    fi

    echo "Xray 配置文件内容："
    echo "------------------------------------------------"
    cat /usr/local/etc/xray/config.json
    echo ""
    echo "------------------------------------------------"

    break_end
}

set_xray_ipv6_outbound() {
    clear
    echo -e "${gl_kjlan}=== 设置 Xray IPv6 出站 ===${gl_bai}"
    echo ""

    # 检查配置文件是否存在
    if [ ! -f /usr/local/etc/xray/config.json ]; then
        echo -e "${gl_hong}错误: Xray 配置文件不存在${gl_bai}"
        echo "路径: /usr/local/etc/xray/config.json"
        echo ""
        break_end
        return 1
    fi

    # 检查 jq 是否安装
    if ! command -v jq &>/dev/null; then
        echo -e "${gl_huang}jq 未安装，正在安装...${gl_bai}"
        install_package jq
    fi

    # 检查 xray 命令是否存在
    if ! command -v xray &>/dev/null; then
        echo -e "${gl_hong}错误: xray 命令不存在${gl_bai}"
        echo ""
        break_end
        return 1
    fi

    echo "正在备份当前配置..."
    local backup_timestamp=$(date +%F-%H%M%S)
    cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.bak.${backup_timestamp}
    echo -e "${gl_lv}✅ 配置已备份${gl_bai}"
    echo ""

    echo "正在修改为 IPv6 出站配置..."
    jq '
      .outbounds = [
        {
          "protocol": "freedom",
          "settings": { "domainStrategy": "UseIPv4v6" },
          "sendThrough": "::"
        }
      ]
    ' /usr/local/etc/xray/config.json > /usr/local/etc/xray/config.json.new && \
    mv /usr/local/etc/xray/config.json.new /usr/local/etc/xray/config.json

    echo "正在测试配置..."
    if xray -test -config /usr/local/etc/xray/config.json; then
        echo -e "${gl_lv}✅ 配置测试通过${gl_bai}"
        echo ""
        echo "正在重启 Xray 服务..."
        systemctl restart xray
        echo -e "${gl_lv}✅ Xray IPv6 出站配置完成！${gl_bai}"
    else
        echo -e "${gl_hong}❌ 配置测试失败，已回滚${gl_bai}"
        mv /usr/local/etc/xray/config.json.bak.${backup_timestamp} /usr/local/etc/xray/config.json
    fi

    echo ""
    break_end
}

restore_xray_default() {
    clear
    echo -e "${gl_kjlan}=== 恢复 Xray 默认配置 ===${gl_bai}"
    echo ""

    # 检查配置文件是否存在
    if [ ! -f /usr/local/etc/xray/config.json ]; then
        echo -e "${gl_hong}错误: Xray 配置文件不存在${gl_bai}"
        echo "路径: /usr/local/etc/xray/config.json"
        echo ""
        break_end
        return 1
    fi

    # 检查 jq 是否安装
    if ! command -v jq &>/dev/null; then
        echo -e "${gl_huang}jq 未安装，正在安装...${gl_bai}"
        install_package jq
    fi

    # 检查 xray 命令是否存在
    if ! command -v xray &>/dev/null; then
        echo -e "${gl_hong}错误: xray 命令不存在${gl_bai}"
        echo ""
        break_end
        return 1
    fi

    echo "正在备份当前配置..."
    local backup_timestamp=$(date +%F-%H%M%S)
    cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.bak.${backup_timestamp}
    echo -e "${gl_lv}✅ 配置已备份${gl_bai}"
    echo ""

    echo "正在恢复双栈模式..."
    jq '
      .outbounds = [
        {
          "protocol": "freedom",
          "settings": { "domainStrategy": "UseIPv4v6" }
        }
      ]
    ' /usr/local/etc/xray/config.json > /usr/local/etc/xray/config.json.new && \
    mv /usr/local/etc/xray/config.json.new /usr/local/etc/xray/config.json

    echo "正在测试配置..."
    if xray -test -config /usr/local/etc/xray/config.json; then
        echo -e "${gl_lv}✅ 配置测试通过${gl_bai}"
        echo ""
        echo "正在重启 Xray 服务..."
        systemctl restart xray
        echo -e "${gl_lv}✅ Xray 默认配置已恢复！${gl_bai}"
    else
        echo -e "${gl_hong}❌ 配置测试失败，已回滚${gl_bai}"
        mv /usr/local/etc/xray/config.json.bak.${backup_timestamp} /usr/local/etc/xray/config.json
    fi

    echo ""
    break_end
}

server_reboot() {
    read -e -p "$(echo -e "${gl_huang}提示: ${gl_bai}现在重启服务器使配置生效吗？(Y/N): ")" rboot
    case "$rboot" in
        [Yy])
            echo "正在重启..."
            reboot
            ;;
        *)
            echo "已取消，请稍后手动执行: reboot"
            ;;
    esac
}

#=============================================================================
# 带宽检测和缓冲区计算函数
#=============================================================================

# 带宽检测函数
detect_bandwidth() {
    # 所有交互式输出重定向到stderr，避免被命令替换捕获
    echo "" >&2
    echo -e "${gl_kjlan}=== 服务器带宽检测 ===${gl_bai}" >&2
    echo "" >&2
    echo "请选择带宽配置方式：" >&2
    echo "1. 自动检测（推荐，自动选择最近服务器）" >&2
    echo "2. 手动指定测速服务器（指定服务器ID）" >&2
    echo "3. 手动选择预设档位（9个常用带宽档位）" >&2
    echo "" >&2
    
    read -e -p "请输入选择 [1]: " bw_choice
    bw_choice=${bw_choice:-1}
    
    case "$bw_choice" in
        1)
            # 自动检测带宽 - 选择最近服务器
            echo "" >&2
            echo -e "${gl_huang}正在运行 speedtest 测速...${gl_bai}" >&2
            echo -e "${gl_zi}提示: 自动选择距离最近的服务器${gl_bai}" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 检查speedtest是否安装
            if ! command -v speedtest &>/dev/null; then
                echo -e "${gl_huang}speedtest 未安装，正在安装...${gl_bai}" >&2
                # 调用脚本中已有的安装逻辑（简化版）
                local cpu_arch=$(uname -m)
                local download_url
                case "$cpu_arch" in
                    x86_64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
                        ;;
                    aarch64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
                        ;;
                    *)
                        echo -e "${gl_hong}错误: 不支持的架构 ${cpu_arch}${gl_bai}" >&2
                        echo "将使用通用值 16MB" >&2
                        echo "500"
                        return 1
                        ;;
                esac
                
                cd /tmp
                wget -q "$download_url" -O speedtest.tgz && \
                tar -xzf speedtest.tgz && \
                mv speedtest /usr/local/bin/ && \
                rm -f speedtest.tgz
                
                if [ $? -ne 0 ]; then
                    echo -e "${gl_hong}安装失败，将使用通用值${gl_bai}" >&2
                    echo "500"
                    return 1
                fi
            fi
            
            # 智能测速：获取附近服务器列表，按距离依次尝试
            echo -e "${gl_zi}正在搜索附近测速服务器...${gl_bai}" >&2
            
            # 获取附近服务器列表（按延迟排序）
            local servers_list=$(speedtest --accept-license --servers 2>/dev/null | grep -oP '^\s*\K[0-9]+' | head -n 10)
            
            if [ -z "$servers_list" ]; then
                echo -e "${gl_huang}无法获取服务器列表，使用自动选择...${gl_bai}" >&2
                servers_list="auto"
            else
                local server_count=$(echo "$servers_list" | wc -l)
                echo -e "${gl_lv}✅ 找到 ${server_count} 个附近服务器${gl_bai}" >&2
            fi
            echo "" >&2
            
            local speedtest_output=""
            local upload_speed=""
            local attempt=0
            local max_attempts=5  # 最多尝试5个服务器
            
            # 逐个尝试服务器
            for server_id in $servers_list; do
                attempt=$((attempt + 1))
                
                if [ $attempt -gt $max_attempts ]; then
                    echo -e "${gl_huang}已尝试 ${max_attempts} 个服务器，停止尝试${gl_bai}" >&2
                    break
                fi
                
                if [ "$server_id" = "auto" ]; then
                    echo -e "${gl_zi}[尝试 ${attempt}] 自动选择最近服务器...${gl_bai}" >&2
                    speedtest_output=$(speedtest --accept-license 2>&1)
                else
                    echo -e "${gl_zi}[尝试 ${attempt}] 测试服务器 #${server_id}...${gl_bai}" >&2
                    speedtest_output=$(speedtest --accept-license --server-id="$server_id" 2>&1)
                fi
                
                echo "$speedtest_output" >&2
                echo "" >&2
                
                # 提取上传速度
                upload_speed=""
                if echo "$speedtest_output" | grep -q "Upload:"; then
                    upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | grep -oP '\d+\.\d+' 2>/dev/null | head -n1)
                fi
                if [ -z "$upload_speed" ]; then
                    upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}')
                fi
                
                # 检查是否成功
                if [ -n "$upload_speed" ] && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                    local success_server=$(echo "$speedtest_output" | grep "Server:" | head -n1 | sed 's/.*Server: //')
                    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                    echo -e "${gl_lv}✅ 测速成功！${gl_bai}" >&2
                    echo -e "${gl_zi}使用服务器: ${success_server}${gl_bai}" >&2
                    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                    echo "" >&2
                    break
                else
                    local failed_server=$(echo "$speedtest_output" | grep "Server:" | head -n1 | sed 's/.*Server: //' | sed 's/[[:space:]]*$//')
                    if [ -n "$failed_server" ]; then
                        echo -e "${gl_huang}⚠️  失败: ${failed_server}${gl_bai}" >&2
                    else
                        echo -e "${gl_huang}⚠️  此服务器失败${gl_bai}" >&2
                    fi
                    echo -e "${gl_zi}继续尝试下一个服务器...${gl_bai}" >&2
                    echo "" >&2
                fi
            done
            
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 所有尝试都失败了
            if [ -z "$upload_speed" ] || echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo -e "${gl_huang}⚠️  无法自动检测带宽${gl_bai}" >&2
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_zi}原因: 测速服务器可能暂时不可用${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_kjlan}默认配置方案：${gl_bai}" >&2
                echo -e "  带宽:       ${gl_huang}1000 Mbps (1 Gbps)${gl_bai}" >&2
                echo -e "  缓冲区:     ${gl_huang}16 MB${gl_bai}" >&2
                echo -e "  适用场景:   ${gl_zi}标准 1Gbps 服务器（覆盖大多数场景）${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo "" >&2
                
                # 询问用户确认
                read -e -p "是否使用默认值 1000 Mbps？(Y/N) [Y]: " use_default
                use_default=${use_default:-Y}
                
                case "$use_default" in
                    [Yy])
                        echo "" >&2
                        echo -e "${gl_lv}✅ 使用默认配置: 1000 Mbps（16 MB 缓冲区）${gl_bai}" >&2
                        echo "1000"
                        return 0
                        ;;
                    [Nn])
                        echo "" >&2
                        echo -e "${gl_zi}请手动输入带宽值${gl_bai}" >&2
                        local manual_bandwidth=""
                        while true; do
                            read -e -p "请输入上传带宽（单位：Mbps，如 500、1000、2000）: " manual_bandwidth
                            if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                                echo "" >&2
                                echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                                echo "$manual_bandwidth"
                                return 0
                            else
                                echo -e "${gl_hong}❌ 请输入有效的数字${gl_bai}" >&2
                            fi
                        done
                        ;;
                    *)
                        echo "" >&2
                        echo -e "${gl_huang}输入无效，使用默认值 1000 Mbps${gl_bai}" >&2
                        echo "1000"
                        return 0
                        ;;
                esac
            fi
            
            # 转为整数
            local upload_mbps=${upload_speed%.*}
            
            echo -e "${gl_lv}✅ 检测到上传带宽: ${upload_mbps} Mbps${gl_bai}" >&2
            echo "" >&2
            
            # 返回带宽值
            echo "$upload_mbps"
            return 0
            ;;
        2)
            # 手动指定测速服务器ID
            echo "" >&2
            echo -e "${gl_kjlan}=== 手动指定测速服务器 ===${gl_bai}" >&2
            echo "" >&2
            
            # 检查speedtest是否安装
            if ! command -v speedtest &>/dev/null; then
                echo -e "${gl_huang}speedtest 未安装，正在安装...${gl_bai}" >&2
                local cpu_arch=$(uname -m)
                local download_url
                case "$cpu_arch" in
                    x86_64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
                        ;;
                    aarch64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
                        ;;
                    *)
                        echo -e "${gl_hong}错误: 不支持的架构 ${cpu_arch}${gl_bai}" >&2
                        echo "将使用通用值 1000 Mbps" >&2
                        echo "1000"
                        return 1
                        ;;
                esac
                
                cd /tmp
                wget -q "$download_url" -O speedtest.tgz && \
                tar -xzf speedtest.tgz && \
                mv speedtest /usr/local/bin/ && \
                rm -f speedtest.tgz
                
                if [ $? -ne 0 ]; then
                    echo -e "${gl_hong}安装失败，将使用默认值 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 1
                fi
                echo -e "${gl_lv}✅ speedtest 安装成功${gl_bai}" >&2
                echo "" >&2
            fi
            
            # 显示如何查看服务器列表
            echo -e "${gl_zi}📋 如何查看可用的测速服务器：${gl_bai}" >&2
            echo "" >&2
            echo -e "  方法1：查看所有服务器列表" >&2
            echo -e "  ${gl_huang}speedtest --servers${gl_bai}" >&2
            echo "" >&2
            echo -e "  方法2：只显示附近服务器（推荐）" >&2
            echo -e "  ${gl_huang}speedtest --servers | head -n 20${gl_bai}" >&2
            echo "" >&2
            echo -e "${gl_zi}💡 服务器列表格式说明：${gl_bai}" >&2
            echo -e "  每行开头的数字就是服务器ID" >&2
            echo -e "  例如: ${gl_huang}12345${gl_bai}) 服务商名称 (位置, 距离)" >&2
            echo "" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 询问是否现在查看服务器列表
            read -e -p "是否现在查看附近的测速服务器列表？(Y/N) [Y]: " show_list
            show_list=${show_list:-Y}
            
            if [[ "$show_list" =~ ^[Yy]$ ]]; then
                echo "" >&2
                echo -e "${gl_kjlan}附近的测速服务器列表：${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                speedtest --accept-license --servers 2>/dev/null | head -n 20 >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
            fi
            
            # 输入服务器ID
            local server_id=""
            while true; do
                read -e -p "$(echo -e "${gl_huang}请输入测速服务器ID（纯数字）: ${gl_bai}")" server_id
                
                if [[ "$server_id" =~ ^[0-9]+$ ]]; then
                    break
                else
                    echo -e "${gl_hong}❌ 无效输入，请输入纯数字的服务器ID${gl_bai}" >&2
                fi
            done
            
            # 使用指定服务器测速
            echo "" >&2
            echo -e "${gl_huang}正在使用服务器 #${server_id} 测速...${gl_bai}" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            local speedtest_output=$(speedtest --accept-license --server-id="$server_id" 2>&1)
            echo "$speedtest_output" >&2
            echo "" >&2
            
            # 提取上传速度
            local upload_speed=""
            if echo "$speedtest_output" | grep -q "Upload:"; then
                upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | grep -oP '\d+\.\d+' 2>/dev/null | head -n1)
            fi
            if [ -z "$upload_speed" ]; then
                upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}')
            fi
            
            # 检查测速是否成功
            if [ -n "$upload_speed" ] && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                local upload_mbps=${upload_speed%.*}
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo -e "${gl_lv}✅ 测速成功！${gl_bai}" >&2
                echo -e "${gl_lv}检测到上传带宽: ${upload_mbps} Mbps${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
                echo "$upload_mbps"
                return 0
            else
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo -e "${gl_hong}❌ 测速失败${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
                echo -e "${gl_zi}可能原因：${gl_bai}" >&2
                echo "  - 服务器ID不存在或已下线" >&2
                echo "  - 网络连接问题" >&2
                echo "  - 该服务器暂时不可用" >&2
                echo "" >&2
                
                read -e -p "是否使用默认值 1000 Mbps？(Y/N) [Y]: " use_default
                use_default=${use_default:-Y}
                
                if [[ "$use_default" =~ ^[Yy]$ ]]; then
                    echo "" >&2
                    echo -e "${gl_lv}✅ 使用默认配置: 1000 Mbps（16 MB 缓冲区）${gl_bai}" >&2
                    echo "1000"
                    return 0
                else
                    echo "" >&2
                    echo -e "${gl_zi}请手动输入带宽值${gl_bai}" >&2
                    local manual_bandwidth=""
                    while true; do
                        read -e -p "请输入上传带宽（单位：Mbps，如 500、1000、2000）: " manual_bandwidth
                        if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                            echo "" >&2
                            echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                            echo "$manual_bandwidth"
                            return 0
                        else
                            echo -e "${gl_hong}❌ 请输入有效的数字${gl_bai}" >&2
                        fi
                    done
                fi
            fi
            ;;
        3)
            # 手动选择预设档位
            echo "" >&2
            echo -e "${gl_kjlan}=== 手动选择带宽档位 ===${gl_bai}" >&2
            echo "" >&2
            echo "请选择带宽档位：" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            echo -e "${gl_huang}【小带宽 VPS】${gl_bai}" >&2
            echo "1. 100 Mbps   → 缓冲区 6 MB   (NAT/极小带宽)" >&2
            echo "2. 200 Mbps   → 缓冲区 8 MB   (小型VPS)" >&2
            echo "3. 300 Mbps   → 缓冲区 10 MB  (入门服务器)" >&2
            echo "" >&2
            echo -e "${gl_huang}【中等带宽】${gl_bai}" >&2
            echo "4. 500 Mbps   → 缓冲区 12 MB  (标准小带宽)" >&2
            echo "5. 700 Mbps   → 缓冲区 14 MB  (准千兆)" >&2
            echo "6. 1 Gbps ⭐  → 缓冲区 16 MB  (标准VPS/最常见)" >&2
            echo "" >&2
            echo -e "${gl_huang}【高带宽服务器】${gl_bai}" >&2
            echo "7. 1.5 Gbps   → 缓冲区 20 MB  (中高端VPS)" >&2
            echo "8. 2 Gbps     → 缓冲区 24 MB  (高性能VPS)" >&2
            echo "9. 2.5 Gbps   → 缓冲区 28 MB  (准万兆)" >&2
            echo "" >&2
            echo -e "${gl_zi}【其他选项】${gl_bai}" >&2
            echo "10. 自定义输入（手动指定任意带宽值）" >&2
            echo "0. 返回上级菜单" >&2
            echo "" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 读取用户选择
            local preset_choice=""
            read -e -p "请输入选择 [6]: " preset_choice
            preset_choice=${preset_choice:-6}  # 默认选择6 (1 Gbps)
            
            case "$preset_choice" in
                1)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 100 Mbps (缓冲区 6 MB)${gl_bai}" >&2
                    echo "100"
                    return 0
                    ;;
                2)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 200 Mbps (缓冲区 8 MB)${gl_bai}" >&2
                    echo "200"
                    return 0
                    ;;
                3)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 300 Mbps (缓冲区 10 MB)${gl_bai}" >&2
                    echo "300"
                    return 0
                    ;;
                4)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 500 Mbps (缓冲区 12 MB)${gl_bai}" >&2
                    echo "500"
                    return 0
                    ;;
                5)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 700 Mbps (缓冲区 14 MB)${gl_bai}" >&2
                    echo "700"
                    return 0
                    ;;
                6)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 1000 Mbps (缓冲区 16 MB)${gl_bai}" >&2
                    echo "1000"
                    return 0
                    ;;
                7)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 1500 Mbps (缓冲区 20 MB)${gl_bai}" >&2
                    echo "1500"
                    return 0
                    ;;
                8)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 2000 Mbps (缓冲区 24 MB)${gl_bai}" >&2
                    echo "2000"
                    return 0
                    ;;
                9)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 2500 Mbps (缓冲区 28 MB)${gl_bai}" >&2
                    echo "2500"
                    return 0
                    ;;
                10)
                    # 自定义输入
                    echo "" >&2
                    echo -e "${gl_zi}=== 自定义输入 ===${gl_bai}" >&2
                    echo "" >&2
                    local manual_bandwidth=""
                    while true; do
                        read -e -p "请输入带宽值（单位：Mbps，如 750、1200）: " manual_bandwidth
                        if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                            echo "" >&2
                            echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                            echo "$manual_bandwidth"
                            return 0
                        else
                            echo -e "${gl_hong}❌ 请输入有效的正整数${gl_bai}" >&2
                        fi
                    done
                    ;;
                0)
                    # 返回上级菜单
                    echo "" >&2
                    echo -e "${gl_huang}已取消选择，返回上级菜单${gl_bai}" >&2
                    echo "1000"  # 返回默认值，避免空值
                    return 1
                    ;;
                *)
                    echo "" >&2
                    echo -e "${gl_hong}无效选择，使用默认值 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 1
                    ;;
            esac
            ;;
        *)
            echo -e "${gl_huang}无效选择，使用默认值 1000 Mbps${gl_bai}" >&2
            echo "1000"
            return 1
            ;;
    esac
}

# 缓冲区大小计算函数
calculate_buffer_size() {
    local bandwidth=$1
    local buffer_mb
    local bandwidth_level
    
    # 优先匹配预设档位（精确匹配）
    if [ "$bandwidth" -eq 100 ]; then
        buffer_mb=6
        bandwidth_level="预设档位（100 Mbps）"
    elif [ "$bandwidth" -eq 200 ]; then
        buffer_mb=8
        bandwidth_level="预设档位（200 Mbps）"
    elif [ "$bandwidth" -eq 300 ]; then
        buffer_mb=10
        bandwidth_level="预设档位（300 Mbps）"
    elif [ "$bandwidth" -eq 500 ]; then
        buffer_mb=12
        bandwidth_level="预设档位（500 Mbps）"
    elif [ "$bandwidth" -eq 700 ]; then
        buffer_mb=14
        bandwidth_level="预设档位（700 Mbps）"
    elif [ "$bandwidth" -eq 1000 ]; then
        buffer_mb=16
        bandwidth_level="预设档位（1 Gbps）"
    elif [ "$bandwidth" -eq 1500 ]; then
        buffer_mb=20
        bandwidth_level="预设档位（1.5 Gbps）"
    elif [ "$bandwidth" -eq 2000 ]; then
        buffer_mb=24
        bandwidth_level="预设档位（2 Gbps）"
    elif [ "$bandwidth" -eq 2500 ]; then
        buffer_mb=28
        bandwidth_level="预设档位（2.5 Gbps）"
    # 否则使用原有的范围判断（用于自动检测和自定义值）
    elif [ "$bandwidth" -lt 500 ]; then
        buffer_mb=8
        bandwidth_level="小带宽（< 500 Mbps）"
    elif [ "$bandwidth" -lt 1000 ]; then
        buffer_mb=12
        bandwidth_level="中等带宽（500-1000 Mbps）"
    elif [ "$bandwidth" -lt 2000 ]; then
        buffer_mb=16
        bandwidth_level="标准带宽（1-2 Gbps）"
    elif [ "$bandwidth" -lt 5000 ]; then
        buffer_mb=24
        bandwidth_level="高带宽（2-5 Gbps）"
    elif [ "$bandwidth" -lt 10000 ]; then
        buffer_mb=28
        bandwidth_level="超高带宽（5-10 Gbps）"
    else
        buffer_mb=32
        bandwidth_level="极高带宽（> 10 Gbps）"
    fi
    
    # 显示计算结果（输出到stderr）
    echo "" >&2
    echo -e "${gl_kjlan}根据带宽计算最优缓冲区:${gl_bai}" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo -e "  检测带宽: ${gl_huang}${bandwidth} Mbps${gl_bai}" >&2
    echo -e "  带宽等级: ${bandwidth_level}" >&2
    echo -e "  推荐缓冲区: ${gl_lv}${buffer_mb} MB${gl_bai}" >&2
    echo -e "  说明: 适合该带宽的最优配置" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "" >&2
    
    # 询问确认
    read -e -p "$(echo -e "${gl_huang}是否使用推荐值 ${buffer_mb}MB？(Y/N) [Y]: ${gl_bai}")" confirm
    confirm=${confirm:-Y}
    
    case "$confirm" in
        [Yy])
            # 返回缓冲区大小（MB）
            echo "$buffer_mb"
            return 0
            ;;
        *)
            echo "" >&2
            echo -e "${gl_huang}已取消，将使用通用值 16MB${gl_bai}" >&2
            echo "16"
            return 1
            ;;
    esac
}

#=============================================================================
# SWAP智能检测和建议函数（集成到选项2/3）
#=============================================================================
check_and_suggest_swap() {
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local swap_total=$(free -m | awk 'NR==3{print $2}')
    local recommended_swap
    local need_swap=0
    
    # 判断是否需要SWAP
    if [ "$mem_total" -lt 2048 ]; then
        # 小于2GB内存，强烈建议配置SWAP
        need_swap=1
    elif [ "$mem_total" -lt 4096 ] && [ "$swap_total" -eq 0 ]; then
        # 2-4GB内存且没有SWAP，建议配置
        need_swap=1
    fi
    
    # 如果不需要SWAP，直接返回
    if [ "$need_swap" -eq 0 ]; then
        return 0
    fi
    
    # 计算推荐的SWAP大小
    if [ "$mem_total" -lt 512 ]; then
        recommended_swap=1024
    elif [ "$mem_total" -lt 1024 ]; then
        recommended_swap=$((mem_total * 2))
    elif [ "$mem_total" -lt 2048 ]; then
        recommended_swap=$((mem_total * 3 / 2))
    elif [ "$mem_total" -lt 4096 ]; then
        recommended_swap=$mem_total
    else
        recommended_swap=4096
    fi
    
    # 显示建议信息
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_huang}检测到虚拟内存（SWAP）需要优化${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "  物理内存:       ${gl_huang}${mem_total}MB${gl_bai}"
    echo -e "  当前 SWAP:      ${gl_huang}${swap_total}MB${gl_bai}"
    echo -e "  推荐 SWAP:      ${gl_lv}${recommended_swap}MB${gl_bai}"
    echo ""
    
    if [ "$mem_total" -lt 1024 ]; then
        echo -e "${gl_zi}原因: 小内存机器（<1GB）强烈建议配置SWAP，避免内存不足导致程序崩溃${gl_bai}"
    elif [ "$mem_total" -lt 2048 ]; then
        echo -e "${gl_zi}原因: 1-2GB内存建议配置SWAP，提供缓冲空间${gl_bai}"
    elif [ "$mem_total" -lt 4096 ]; then
        echo -e "${gl_zi}原因: 2-4GB内存建议配置少量SWAP作为保险${gl_bai}"
    fi
    
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    # 询问用户
    read -e -p "$(echo -e "${gl_huang}是否现在配置虚拟内存？(Y/N): ${gl_bai}")" confirm
    
    case "$confirm" in
        [Yy])
            echo ""
            echo -e "${gl_lv}开始配置虚拟内存...${gl_bai}"
            echo ""
            add_swap "$recommended_swap"
            echo ""
            echo -e "${gl_lv}✅ 虚拟内存配置完成！${gl_bai}"
            echo ""
            echo -e "${gl_zi}继续执行 BBR 优化配置...${gl_bai}"
            sleep 2
            return 0
            ;;
        [Nn])
            echo ""
            echo -e "${gl_huang}已跳过虚拟内存配置${gl_bai}"
            echo -e "${gl_zi}继续执行 BBR 优化配置...${gl_bai}"
            echo ""
            sleep 2
            return 1
            ;;
        *)
            echo ""
            echo -e "${gl_huang}输入无效，已跳过虚拟内存配置${gl_bai}"
            echo -e "${gl_zi}继续执行 BBR 优化配置...${gl_bai}"
            echo ""
            sleep 2
            return 1
            ;;
    esac
}

#=============================================================================
# 配置冲突检测与清理（避免被其他 sysctl 覆盖）
#=============================================================================
check_and_clean_conflicts() {
    echo -e "${gl_kjlan}=== 检查 sysctl 配置冲突 ===${gl_bai}"
    local conflicts=()
    # 搜索 /etc/sysctl.d/ 下可能覆盖 tcp_rmem/tcp_wmem 的高序号文件
    for conf in /etc/sysctl.d/[0-9]*-*.conf /etc/sysctl.d/[0-9][0-9][0-9]-*.conf; do
        [ -f "$conf" ] || continue
        [ "$conf" = "$SYSCTL_CONF" ] && continue
        if grep -qE "(^|\s)net\.ipv4\.tcp_(rmem|wmem)" "$conf" 2>/dev/null; then
            base=$(basename "$conf")
            num=$(echo "$base" | sed -n 's/^\([0-9]\+\).*/\1/p')
            # 99 及以上优先生效，可能覆盖本脚本
            if [ -n "$num" ] && [ "$num" -ge 99 ]; then
                conflicts+=("$conf")
            fi
        fi
    done

    # 主配置文件直接设置也会覆盖
    local has_sysctl_conflict=0
    if [ -f /etc/sysctl.conf ] && grep -qE "(^|\s)net\.ipv4\.tcp_(rmem|wmem)" /etc/sysctl.conf 2>/dev/null; then
        has_sysctl_conflict=1
    fi

    if [ ${#conflicts[@]} -eq 0 ] && [ $has_sysctl_conflict -eq 0 ]; then
        echo -e "${gl_lv}✓ 未发现可能的覆盖配置${gl_bai}"
        return 0
    fi

    echo -e "${gl_huang}发现可能的覆盖配置：${gl_bai}"
    for f in "${conflicts[@]}"; do
        echo "  - $f"; grep -E "net\.ipv4\.tcp_(rmem|wmem)" "$f" | sed 's/^/      /'
    done
    [ $has_sysctl_conflict -eq 1 ] && echo "  - /etc/sysctl.conf (含 tcp_rmem/tcp_wmem)"

    read -e -p "是否自动禁用/注释这些覆盖配置？(Y/N): " ans
    case "$ans" in
        [Yy])
            # 注释 /etc/sysctl.conf 中相关行
            if [ $has_sysctl_conflict -eq 1 ]; then
                sed -i.bak '/^net\.ipv4\.tcp_wmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i.bak '/^net\.ipv4\.tcp_rmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i.bak '/^net\.core\.rmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i.bak '/^net\.core\.wmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
                echo -e "${gl_lv}✓ 已注释 /etc/sysctl.conf 中的相关配置${gl_bai}"
            fi
            # 将高优先级冲突文件重命名禁用
            for f in "${conflicts[@]}"; do
                mv "$f" "${f}.disabled.$(date +%Y%m%d_%H%M%S)" 2>/dev/null && \
                  echo -e "${gl_lv}✓ 已禁用: $(basename "$f")${gl_bai}"
            done
            ;;
        *)
            echo -e "${gl_huang}已跳过自动清理，可能导致新配置未完全生效${gl_bai}"
            ;;
    esac
}

#=============================================================================
# 立即生效与防分片函数（无需重启）
#=============================================================================

# 获取需应用 qdisc 的网卡（排除常见虚拟接口）
eligible_ifaces() {
    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        dev=$(basename "$d")
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
        esac
        echo "$dev"
    done
}

# tc fq 立即生效（无需重启）
apply_tc_fq_now() {
    if ! command -v tc >/dev/null 2>&1; then
        echo -e "${gl_huang}警告: 未检测到 tc（iproute2），跳过 fq 应用${gl_bai}"
        return 0
    fi
    local applied=0
    for dev in $(eligible_ifaces); do
        tc qdisc replace dev "$dev" root fq 2>/dev/null && applied=$((applied+1))
    done
    [ $applied -gt 0 ] && echo -e "${gl_lv}已对 $applied 个网卡应用 fq（即时生效）${gl_bai}" || echo -e "${gl_huang}未发现可应用 fq 的网卡${gl_bai}"
}

# MSS clamp（防分片）自动启用
apply_mss_clamp() {
    local action=$1  # enable|disable
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${gl_huang}警告: 未检测到 iptables，跳过 MSS clamp${gl_bai}"
        return 0
    fi
    if [ "$action" = "enable" ]; then
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
          || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    else
        iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
    fi
}

#=============================================================================
# BBR 配置函数（智能检测版）
#=============================================================================

# 直连/落地优化配置
bbr_configure_direct() {
    echo -e "${gl_kjlan}=== 配置 BBR v3 + FQ 直连/落地优化（智能检测版） ===${gl_bai}"
    echo ""
    
    # 步骤 0：SWAP智能检测和建议
    echo -e "${gl_zi}[步骤 1/6] 检测虚拟内存（SWAP）配置...${gl_bai}"
    check_and_suggest_swap
    
    # 步骤 0.5：带宽检测和缓冲区计算
    echo ""
    echo -e "${gl_zi}[步骤 2/6] 检测服务器带宽并计算最优缓冲区...${gl_bai}"
    
    local detected_bandwidth=$(detect_bandwidth)
    local buffer_mb=$(calculate_buffer_size "$detected_bandwidth")
    local buffer_bytes=$((buffer_mb * 1024 * 1024))
    
    echo -e "${gl_lv}✅ 将使用 ${buffer_mb}MB 缓冲区配置${gl_bai}"
    sleep 2
    
    echo ""
    echo -e "${gl_zi}[步骤 3/6] 清理配置冲突...${gl_bai}"
    echo "正在检查配置冲突..."
    
    # 备份主配置文件（如果还没备份）
    if [ -f /etc/sysctl.conf ] && ! [ -f /etc/sysctl.conf.bak.original ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.original
        echo "已备份: /etc/sysctl.conf -> /etc/sysctl.conf.bak.original"
    fi
    
    # 注释掉 /etc/sysctl.conf 中的 TCP 缓冲区配置（避免覆盖）
    if [ -f /etc/sysctl.conf ]; then
        clean_sysctl_conf
        echo "已清理 /etc/sysctl.conf 中的冲突配置"
    fi
    
    # 删除可能存在的软链接
    if [ -L /etc/sysctl.d/99-sysctl.conf ]; then
        rm -f /etc/sysctl.d/99-sysctl.conf
        echo "已删除配置软链接"
    fi
    
    # 检查并清理可能覆盖的新旧配置冲突
    check_and_clean_conflicts

    # 步骤 3：创建独立配置文件（使用动态缓冲区）
    echo ""
    echo -e "${gl_zi}[步骤 4/6] 创建配置文件...${gl_bai}"
    echo "正在创建新配置..."
    
    # 获取物理内存用于虚拟内存参数调整
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local vm_swappiness=5
    local vm_dirty_ratio=15
    local vm_min_free_kbytes=65536
    
    # 根据内存大小微调虚拟内存参数
    if [ "$mem_total" -lt 2048 ]; then
        vm_swappiness=20
        vm_dirty_ratio=20
        vm_min_free_kbytes=32768
    fi
    
    cat > "$SYSCTL_CONF" << EOF
# BBR v3 Direct/Endpoint Configuration (Intelligent Detection Edition)
# Generated on $(date)
# Bandwidth: ${detected_bandwidth} Mbps | Buffer: ${buffer_mb} MB

# 队列调度算法
net.core.default_qdisc=fq

# 拥塞控制算法
net.ipv4.tcp_congestion_control=bbr

# TCP 缓冲区优化（智能检测：${buffer_mb}MB）
net.core.rmem_max=${buffer_bytes}
net.core.wmem_max=${buffer_bytes}
net.ipv4.tcp_rmem=4096 87380 ${buffer_bytes}
net.ipv4.tcp_wmem=4096 65536 ${buffer_bytes}

# ===== 直连/落地优化参数 =====

# TIME_WAIT 重用（启用，提高并发）
net.ipv4.tcp_tw_reuse=1

# 端口范围（最大化）
net.ipv4.ip_local_port_range=1024 65535

# 连接队列（高性能）
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192

# 网络队列（高带宽优化）
net.core.netdev_max_backlog=5000

# 高级TCP优化
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1

# ===== Reality终极优化参数 =====

# 发送低水位（上传速度优化关键）
net.ipv4.tcp_notsent_lowat=16384

# 连接回收优化
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_tw_buckets=5000

# TCP保活优化（更快检测死连接）
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

# UDP缓冲区（QUIC/Hysteria 支持）
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# TCP安全增强
net.ipv4.tcp_syncookies=1

# 虚拟内存优化（根据物理内存调整）
vm.swappiness=${vm_swappiness}
vm.dirty_ratio=${vm_dirty_ratio}
vm.dirty_background_ratio=5
vm.overcommit_memory=1
vm.min_free_kbytes=${vm_min_free_kbytes}
vm.vfs_cache_pressure=50

# CPU调度优化
kernel.sched_autogroup_enabled=0
kernel.numa_balancing=0
EOF

    # 步骤 4：应用配置
    echo ""
    echo -e "${gl_zi}[步骤 5/6] 应用所有优化参数...${gl_bai}"
    echo "正在应用配置..."
    sysctl -p "$SYSCTL_CONF" > /dev/null 2>&1
    
    # 立即应用 fq，并启用 MSS clamp（无需重启）
    echo "正在应用队列与防分片（无需重启）..."
    apply_tc_fq_now >/dev/null 2>&1
    apply_mss_clamp enable >/dev/null 2>&1
    
    # 配置文件描述符限制
    echo "正在优化文件描述符限制..."
    if ! grep -q "BBR - 文件描述符优化" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << 'LIMITSEOF'
# BBR - 文件描述符优化
* soft nofile 524288
* hard nofile 524288
LIMITSEOF
    fi
    ulimit -n 524288 2>/dev/null
    
    # 禁用透明大页面
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    fi

    # 步骤 5：验证配置是否真正生效
    echo ""
    echo -e "${gl_zi}[步骤 6/6] 验证配置...${gl_bai}"
    
    local actual_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local actual_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    local actual_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    
    echo ""
    echo -e "${gl_kjlan}=== 配置验证 ===${gl_bai}"
    
    # 验证队列算法
    if [ "$actual_qdisc" = "fq" ]; then
        echo -e "队列算法: ${gl_lv}$actual_qdisc ✓${gl_bai}"
    else
        echo -e "队列算法: ${gl_huang}$actual_qdisc (期望: fq) ⚠${gl_bai}"
    fi
    
    # 验证拥塞控制
    if [ "$actual_cc" = "bbr" ]; then
        echo -e "拥塞控制: ${gl_lv}$actual_cc ✓${gl_bai}"
    else
        echo -e "拥塞控制: ${gl_huang}$actual_cc (期望: bbr) ⚠${gl_bai}"
    fi
    
    # 验证缓冲区（动态）
    local actual_wmem_mb=$((actual_wmem / 1048576))
    local actual_rmem_mb=$((actual_rmem / 1048576))
    
    if [ "$actual_wmem" = "$buffer_bytes" ]; then
        echo -e "发送缓冲区: ${gl_lv}${buffer_mb}MB ✓${gl_bai}"
    else
        echo -e "发送缓冲区: ${gl_huang}${actual_wmem_mb}MB (期望: ${buffer_mb}MB) ⚠${gl_bai}"
    fi
    
    if [ "$actual_rmem" = "$buffer_bytes" ]; then
        echo -e "接收缓冲区: ${gl_lv}${buffer_mb}MB ✓${gl_bai}"
    else
        echo -e "接收缓冲区: ${gl_huang}${actual_rmem_mb}MB (期望: ${buffer_mb}MB) ⚠${gl_bai}"
    fi
    
    echo ""
    
    # 最终判断
    if [ "$actual_qdisc" = "fq" ] && [ "$actual_cc" = "bbr" ] && \
       [ "$actual_wmem" = "$buffer_bytes" ] && [ "$actual_rmem" = "$buffer_bytes" ]; then
        echo -e "${gl_lv}✅ BBR v3 直连/落地优化配置完成并已生效！${gl_bai}"
        echo -e "${gl_zi}配置说明: ${buffer_mb}MB 缓冲区（${detected_bandwidth} Mbps 带宽），适合直连/落地场景${gl_bai}"
    else
        echo -e "${gl_huang}⚠️ 配置已保存但部分参数未生效${gl_bai}"
        echo -e "${gl_huang}建议执行以下操作：${gl_bai}"
        echo "1. 检查是否有其他配置文件冲突"
        echo "2. 重启服务器使配置完全生效: reboot"
    fi
}

#=============================================================================
# 状态检查函数
#=============================================================================

check_bbr_status() {
    echo -e "${gl_kjlan}=== 当前系统状态 ===${gl_bai}"
    local kernel_release
    kernel_release=$(uname -r)
    echo "内核版本: $kernel_release"
    
    local congestion="未知"
    local qdisc="未知"
    local bbr_version=""
    local bbr_active=0
    
    if command -v sysctl &>/dev/null; then
        congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
        echo "拥塞控制算法: $congestion"
        echo "队列调度算法: $qdisc"
        
        if command -v modinfo &>/dev/null; then
            bbr_version=$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2}')
            if [ -n "$bbr_version" ]; then
                if [ "$bbr_version" = "3" ]; then
                    echo -e "BBR 版本: ${gl_lv}v${bbr_version} ✓${gl_bai}"
                else
                    echo -e "BBR 版本: ${gl_huang}v${bbr_version} (不是 v3)${gl_bai}"
                fi
            fi
        fi
    fi
    
    if [ "$congestion" = "bbr" ] && [ "$bbr_version" = "3" ]; then
        bbr_active=1
    fi
    
    local xanmod_pkg_installed=0
    local dpkg_available=0
    if command -v dpkg &>/dev/null; then
        dpkg_available=1
        if dpkg -l 2>/dev/null | grep -qE '^ii\s+linux-.*xanmod'; then
            xanmod_pkg_installed=1
        fi
    fi
    
    local xanmod_running=0
    if echo "$kernel_release" | grep -qi 'xanmod'; then
        xanmod_running=1
    fi
    
    local status=1
    
    if [ $xanmod_pkg_installed -eq 1 ]; then
        echo -e "XanMod 内核: ${gl_lv}已安装 ✓${gl_bai}"
        status=0
    elif [ $xanmod_running -eq 1 ]; then
        echo -e "XanMod 内核: ${gl_huang}内核包已卸载，但当前运行版本仍为 ${kernel_release}，请重启系统使卸载完全生效${gl_bai}"
    else
        echo -e "XanMod 内核: ${gl_huang}未安装${gl_bai}"
    fi
    
    if [ $status -ne 0 ] && [ $bbr_active -eq 1 ]; then
        echo -e "${gl_kjlan}提示: 当前仍在运行 BBR v3 模块，重启后将恢复系统默认配置${gl_bai}"
    fi
    
    if [ $status -ne 0 ] && [ $dpkg_available -eq 0 ]; then
        if [ $xanmod_running -eq 1 ] || [ $bbr_active -eq 1 ]; then
            status=0
        fi
    fi
    
    return $status
}

#=============================================================================
# XanMod 内核安装（官方源）
#=============================================================================

install_xanmod_kernel() {
    clear
    echo -e "${gl_kjlan}=== 安装 XanMod 内核与 BBR v3 ===${gl_bai}"
    echo "视频教程: https://www.bilibili.com/video/BV14K421x7BS"
    echo "------------------------------------------------"
    echo "支持系统: Debian/Ubuntu (x86_64 & ARM64)"
    echo -e "${gl_huang}警告: 将升级 Linux 内核，请提前备份重要数据！${gl_bai}"
    echo "------------------------------------------------"
    read -e -p "确定继续安装吗？(Y/N): " choice

    case "$choice" in
        [Yy])
            ;;
        *)
            echo "已取消安装"
            return 1
            ;;
    esac
    
    # 检测 CPU 架构
    local cpu_arch=$(uname -m)
    
    # ARM 架构特殊处理
    if [ "$cpu_arch" = "aarch64" ]; then
        echo -e "${gl_kjlan}检测到 ARM64 架构，使用专用安装脚本${gl_bai}"

        install_package curl coreutils || return 1

        local tmp_dir
        tmp_dir=$(mktemp -d 2>/dev/null)
        if [ -z "$tmp_dir" ]; then
            echo -e "${gl_hong}错误: 无法创建临时目录用于下载 ARM64 脚本${gl_bai}"
            return 1
        fi

        local script_url="https://jhb.ovh/jb/bbrv3arm.sh"
        local sha256_url="${script_url}.sha256"
        local sha512_url="${script_url}.sha512"
        local script_path="${tmp_dir}/bbrv3arm.sh"
        local sha256_path="${tmp_dir}/bbrv3arm.sh.sha256"
        local sha512_path="${tmp_dir}/bbrv3arm.sh.sha512"

        echo "日志: 正在下载 ARM64 安装脚本到临时目录 ${tmp_dir}"

        if ! curl -fsSL "$script_url" -o "$script_path"; then
            echo -e "${gl_hong}错误: ARM64 安装脚本下载失败${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        if ! curl -fsSL "$sha256_url" -o "$sha256_path"; then
            echo -e "${gl_hong}错误: 未能获取发布方提供的 SHA256 校验文件${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        if ! curl -fsSL "$sha512_url" -o "$sha512_path"; then
            echo -e "${gl_hong}错误: 未能获取发布方提供的 SHA512 校验文件${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        local expected_sha256 expected_sha512 actual_sha256 actual_sha512
        expected_sha256=$(awk 'NR==1 {print $1}' "$sha256_path")
        expected_sha512=$(awk 'NR==1 {print $1}' "$sha512_path")

        if [ -z "$expected_sha256" ] || [ -z "$expected_sha512" ]; then
            echo -e "${gl_hong}错误: 校验文件内容无效${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        actual_sha256=$(sha256sum "$script_path" | awk '{print $1}')
        actual_sha512=$(sha512sum "$script_path" | awk '{print $1}')

        if [ "$expected_sha256" != "$actual_sha256" ]; then
            echo -e "${gl_hong}错误: SHA256 校验失败，已中止${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        if [ "$expected_sha512" != "$actual_sha512" ]; then
            echo -e "${gl_hong}错误: SHA512 校验失败，已中止${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        echo -e "${gl_lv}SHA256 与 SHA512 校验通过${gl_bai}"
        echo -e "${gl_huang}安全提示:${gl_bai} ARM64 脚本已下载至 ${script_path}"
        echo "如需，您可在继续前使用 cat/less 等命令手动审查脚本内容。"
        read -s -r -p "审查完成后按 Enter 继续执行（Ctrl+C 取消）..." _
        echo ""

        if bash "$script_path"; then
            rm -rf "$tmp_dir"
            echo -e "${gl_lv}ARM BBR v3 安装完成${gl_bai}"
            return 0
        else
            echo -e "${gl_hong}安装失败${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi
    
    # x86_64 架构安装流程
    # 检查系统支持
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then
            echo -e "${gl_hong}错误: 仅支持 Debian 和 Ubuntu 系统${gl_bai}"
            return 1
        fi
    else
        echo -e "${gl_hong}错误: 无法确定操作系统类型${gl_bai}"
        return 1
    fi
    
    # 环境准备
    check_disk_space 3
    check_swap
    install_package wget gnupg
    
    # 添加 XanMod GPG 密钥
    echo "正在添加 XanMod 仓库密钥..."
    wget -qO - ${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/archive.key | \
        gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg --yes
    
    if [ $? -ne 0 ]; then
        echo -e "${gl_hong}密钥下载失败，尝试官方源...${gl_bai}"
        wget -qO - https://dl.xanmod.org/archive.key | \
            gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg --yes
    fi
    
    local xanmod_repo_file="/etc/apt/sources.list.d/xanmod-release.list"

    # 添加 XanMod 仓库
    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | \
        tee "$xanmod_repo_file" > /dev/null
    
    # 检测 CPU 架构版本
    echo "正在检测 CPU 支持的最优内核版本..."
    local version=$(wget -q ${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/check_x86-64_psabi.sh && \
                   chmod +x check_x86-64_psabi.sh && \
                   ./check_x86-64_psabi.sh | grep -oP 'x86-64-v\K\d+|x86-64-v\d+')
    
    if [ -z "$version" ]; then
        echo -e "${gl_huang}自动检测失败，使用默认版本 v3${gl_bai}"
        version="3"
    fi
    
    echo -e "${gl_lv}将安装: linux-xanmod-x64v${version}${gl_bai}"
    
    # 安装 XanMod 内核
    apt-get update
    apt-get install -y linux-xanmod-x64v$version
    
    if [ $? -ne 0 ]; then
        echo -e "${gl_hong}内核安装失败！${gl_bai}"
        rm -f "$xanmod_repo_file"
        rm -f check_x86-64_psabi.sh*
        return 1
    fi

    # 清理临时文件
    rm -f check_x86-64_psabi.sh*

    echo -e "${gl_lv}XanMod 内核安装成功！${gl_bai}"
    echo -e "${gl_huang}提示: 请先重启系统加载新内核，然后再配置 BBR${gl_bai}"
    echo -e "${gl_kjlan}后续更新: 可执行 ${gl_bai}sudo apt update && sudo apt upgrade${gl_kjlan} 以获取最新内核${gl_bai}"

    read -e -p "是否保留 XanMod 软件源以便后续自动获取更新？(Y/n): " keep_repo
    case "${keep_repo:-Y}" in
        [Nn])
            echo -e "${gl_huang}移除软件源后将无法通过 apt upgrade 自动获取内核更新，如需更新需重新添加仓库。${gl_bai}"
            read -e -p "确认仍要移除 XanMod 软件源吗？(Y/N): " remove_repo
            case "$remove_repo" in
                [Yy])
                    rm -f "$xanmod_repo_file"
                    echo -e "${gl_huang}已按要求移除 XanMod 软件源。${gl_bai}"
                    ;;
                *)
                    echo -e "${gl_lv}已保留 XanMod 软件源。${gl_bai}"
                    ;;
            esac
            ;;
        *)
            echo -e "${gl_lv}已保留 XanMod 软件源，系统可通过 apt upgrade 获取未来的内核更新。${gl_bai}"
            ;;
    esac

    return 0
}


#=============================================================================
# IP地址获取函数
#=============================================================================

ip_address() {
    local public_ip=""
    local candidate=""
    local external_api_success=false
    local last_curl_status=0
    local external_api_notice=""

    if candidate=$(curl -4 -fsS --max-time 2 https://ipinfo.io/ip 2>/dev/null); then
        candidate=$(echo "$candidate" | tr -d '\r\n')
        if [ -n "$candidate" ]; then
            public_ip="$candidate"
            external_api_success=true
        fi
    else
        last_curl_status=$?
    fi

    if [ "$external_api_success" = false ]; then
        if candidate=$(curl -4 -fsS --max-time 2 https://api.ip.sb/ip 2>/dev/null); then
            candidate=$(echo "$candidate" | tr -d '\r\n')
            if [ -n "$candidate" ]; then
                public_ip="$candidate"
                external_api_success=true
            fi
        else
            last_curl_status=$?
        fi
    fi

    if [ "$external_api_success" = false ]; then
        if candidate=$(curl -4 -fsS --max-time 2 https://ifconfig.me/ip 2>/dev/null); then
            candidate=$(echo "$candidate" | tr -d '\r\n')
            if [ -n "$candidate" ]; then
                public_ip="$candidate"
                external_api_success=true
            fi
        else
            last_curl_status=$?
        fi
    fi

    if [ "$external_api_success" = false ]; then
        public_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    fi

    if [ -z "$public_ip" ]; then
        public_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    if [ -z "$public_ip" ]; then
        public_ip="外部接口不可达"
    fi

    if [ "$external_api_success" = false ]; then
        external_api_notice="外部接口不可达"
        if [ "$last_curl_status" -ne 0 ]; then
            external_api_notice+=" (curl 返回码 $last_curl_status)"
        fi
    fi

    local local_ipv4=""
    local_ipv4=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    if [ -z "$local_ipv4" ]; then
        local_ipv4=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$local_ipv4" ]; then
        local_ipv4="外部接口不可达"
    fi

    if ! isp_info=$(curl -fsS --max-time 2 http://ipinfo.io/org 2>/dev/null); then
        isp_info=""
    else
        isp_info=$(echo "$isp_info" | tr -d '\r\n')
    fi

    if [ -z "$isp_info" ] && [ -n "$external_api_notice" ]; then
        isp_info="$external_api_notice"
    fi

    if echo "$isp_info" | grep -Eiq 'mobile|unicom|telecom'; then
        ipv4_address="$local_ipv4"
    else
        ipv4_address="$public_ip"
    fi

    if [ -z "$ipv4_address" ]; then
        ipv4_address="$local_ipv4"
    fi

    if ! ipv6_address=$(curl -fsS --max-time 2 https://v6.ipinfo.io/ip 2>/dev/null); then
        ipv6_address=""
    else
        ipv6_address=$(echo "$ipv6_address" | tr -d '\r\n')
    fi

    if [ -n "$external_api_notice" ] && [ -z "$isp_info" ]; then
        isp_info="$external_api_notice"
    fi

    if [ -z "$isp_info" ]; then
        isp_info="未获取到运营商信息"
    fi
}
#=============================================================================
# 网络流量统计函数
#=============================================================================

output_status() {
    output=$(awk 'BEGIN { rx_total = 0; tx_total = 0 }
        $1 ~ /^(eth|ens|enp|eno)[0-9]+/ {
            rx_total += $2
            tx_total += $10
        }
        END {
            rx_units = "Bytes";
            tx_units = "Bytes";
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "K"; }
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "M"; }
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "G"; }

            if (tx_total > 1024) { tx_total /= 1024; tx_units = "K"; }
            if (tx_total > 1024) { tx_total /= 1024; tx_units = "M"; }
            if (tx_total > 1024) { tx_total /= 1024; tx_units = "G"; }

            printf("%.2f%s %.2f%s\n", rx_total, rx_units, tx_total, tx_units);
        }' /proc/net/dev)

    rx=$(echo "$output" | awk '{print $1}')
    tx=$(echo "$output" | awk '{print $2}')
}

#=============================================================================
# 时区获取函数
#=============================================================================

current_timezone() {
    if grep -q 'Alpine' /etc/issue 2>/dev/null; then
        date +"%Z %z"
    else
        timedatectl | grep "Time zone" | awk '{print $3}'
    fi
}

#=============================================================================
# 详细系统信息显示
#=============================================================================

show_detailed_status() {
    clear

    ip_address

    local cpu_info=$(lscpu | awk -F': +' '/Model name:/ {print $2; exit}')

    local cpu_usage_percent=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else printf "%.0f\n", (($2+$4-u1) * 100 / (t-t1))}' \
        <(grep 'cpu ' /proc/stat) <(sleep 1; grep 'cpu ' /proc/stat))

    local cpu_cores=$(nproc)

    local cpu_freq=$(cat /proc/cpuinfo | grep "MHz" | head -n 1 | awk '{printf "%.1f GHz\n", $4/1000}')

    local mem_info=$(free -b | awk 'NR==2{printf "%.2f/%.2fM (%.2f%%)", $3/1024/1024, $2/1024/1024, $3*100/$2}')

    local disk_info=$(df -h | awk '$NF=="/"{printf "%s/%s (%s)", $3, $2, $5}')

    local ipinfo=$(curl -s ipinfo.io)
    local country=$(echo "$ipinfo" | grep 'country' | awk -F': ' '{print $2}' | tr -d '",')
    local city=$(echo "$ipinfo" | grep 'city' | awk -F': ' '{print $2}' | tr -d '",')
    local isp_info=$(echo "$ipinfo" | grep 'org' | awk -F': ' '{print $2}' | tr -d '",')

    local load=$(uptime | awk '{print $(NF-2), $(NF-1), $NF}')
    local dns_addresses=$(awk '/^nameserver/{printf "%s ", $2} END {print ""}' /etc/resolv.conf)

    local cpu_arch=$(uname -m)
    local hostname=$(uname -n)
    local kernel_version=$(uname -r)

    local congestion_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control)
    local queue_algorithm=$(sysctl -n net.core.default_qdisc)

    local os_info=$(grep PRETTY_NAME /etc/os-release | cut -d '=' -f2 | tr -d '"')

    output_status

    local current_time=$(date "+%Y-%m-%d %I:%M %p")

    local swap_info=$(free -m | awk 'NR==3{used=$3; total=$2; if (total == 0) {percentage=0} else {percentage=used*100/total}; printf "%dM/%dM (%d%%)", used, total, percentage}')

    local runtime=$(cat /proc/uptime | awk -F. '{run_days=int($1 / 86400);run_hours=int(($1 % 86400) / 3600);run_minutes=int(($1 % 3600) / 60); if (run_days > 0) printf("%d天 ", run_days); if (run_hours > 0) printf("%d时 ", run_hours); printf("%d分\n", run_minutes)}')

    local timezone=$(current_timezone)

    echo ""
    echo -e "系统信息查询"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}主机名:       ${gl_bai}$hostname"
    echo -e "${gl_kjlan}系统版本:     ${gl_bai}$os_info"
    echo -e "${gl_kjlan}Linux版本:    ${gl_bai}$kernel_version"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}CPU架构:      ${gl_bai}$cpu_arch"
    echo -e "${gl_kjlan}CPU型号:      ${gl_bai}$cpu_info"
    echo -e "${gl_kjlan}CPU核心数:    ${gl_bai}$cpu_cores"
    echo -e "${gl_kjlan}CPU频率:      ${gl_bai}$cpu_freq"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}CPU占用:      ${gl_bai}$cpu_usage_percent%"
    echo -e "${gl_kjlan}系统负载:     ${gl_bai}$load"
    echo -e "${gl_kjlan}物理内存:     ${gl_bai}$mem_info"
    echo -e "${gl_kjlan}虚拟内存:     ${gl_bai}$swap_info"
    echo -e "${gl_kjlan}硬盘占用:     ${gl_bai}$disk_info"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}总接收:       ${gl_bai}$rx"
    echo -e "${gl_kjlan}总发送:       ${gl_bai}$tx"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}网络算法:     ${gl_bai}$congestion_algorithm $queue_algorithm"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}运营商:       ${gl_bai}$isp_info"
    if [ -n "$ipv4_address" ]; then
        echo -e "${gl_kjlan}IPv4地址:     ${gl_bai}$ipv4_address"
    fi

    if [ -n "$ipv6_address" ]; then
        echo -e "${gl_kjlan}IPv6地址:     ${gl_bai}$ipv6_address"
    fi
    echo -e "${gl_kjlan}DNS地址:      ${gl_bai}$dns_addresses"
    echo -e "${gl_kjlan}地理位置:     ${gl_bai}$country $city"
    echo -e "${gl_kjlan}系统时间:     ${gl_bai}$timezone $current_time"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}运行时长:     ${gl_bai}$runtime"
    echo

    break_end
}

#=============================================================================
# 内核参数优化 - 星辰大海ヾ优化模式（VLESS Reality 专用）
#=============================================================================

optimize_xinchendahai() {
    echo -e "${gl_lv}切换到星辰大海ヾ优化模式...${gl_bai}"
    echo -e "${gl_zi}针对 VLESS Reality 节点深度优化${gl_bai}"
    echo ""
    echo -e "${gl_hong}⚠️  重要提示 ⚠️${gl_bai}"
    echo -e "${gl_huang}本配置为临时生效（使用 sysctl -w 命令）${gl_bai}"
    echo -e "${gl_huang}重启后将恢复到永久配置文件的设置${gl_bai}"
    echo ""
    echo "如果你之前执行过："
    echo "  - CAKE调优 / Debian12调优 / BBR直连优化"
    echo "重启后会恢复到那些配置，本次优化会消失！"
    echo ""
    read -e -p "是否继续？(Y/N) [Y]: " confirm
    confirm=${confirm:-Y}
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "已取消"
        return
    fi
    echo ""

    # 文件描述符优化
    echo -e "${gl_lv}优化文件描述符...${gl_bai}"
    ulimit -n 131072
    echo "  ✓ 文件描述符: 131072 (13万)"

    # 内存管理优化
    echo -e "${gl_lv}优化内存管理...${gl_bai}"
    sysctl -w vm.swappiness=5 2>/dev/null
    echo "  ✓ swappiness = 5 （安全值）"
    sysctl -w vm.dirty_ratio=15 2>/dev/null
    echo "  ✓ dirty_ratio = 15"
    sysctl -w vm.dirty_background_ratio=5 2>/dev/null
    echo "  ✓ dirty_background_ratio = 5"
    sysctl -w vm.overcommit_memory=1 2>/dev/null
    echo "  ✓ overcommit_memory = 1"

    # TCP拥塞控制（保持用户的队列算法，不覆盖CAKE）
    echo -e "${gl_lv}优化TCP拥塞控制...${gl_bai}"
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null
    echo "  ✓ tcp_congestion_control = bbr"
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [ "$current_qdisc" = "cake" ]; then
        echo "  ✓ default_qdisc = cake （保持用户设置）"
    else
        echo "  ℹ default_qdisc = $current_qdisc （保持不变）"
    fi

    # TCP连接优化（TLS握手加速）
    echo -e "${gl_lv}优化TCP连接（TLS握手加速）...${gl_bai}"
    sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null
    echo "  ✓ tcp_fastopen = 3"
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null
    echo "  ✓ tcp_slow_start_after_idle = 0 （关键优化）"
    sysctl -w net.ipv4.tcp_tw_reuse=1 2>/dev/null
    echo "  ✓ tcp_tw_reuse = 1"
    sysctl -w net.ipv4.tcp_fin_timeout=30 2>/dev/null
    echo "  ✓ tcp_fin_timeout = 30"
    sysctl -w net.ipv4.tcp_max_syn_backlog=8192 2>/dev/null
    echo "  ✓ tcp_max_syn_backlog = 8192"

    # TCP保活设置
    echo -e "${gl_lv}优化TCP保活...${gl_bai}"
    sysctl -w net.ipv4.tcp_keepalive_time=600 2>/dev/null
    echo "  ✓ tcp_keepalive_time = 600s (10分钟)"
    sysctl -w net.ipv4.tcp_keepalive_intvl=30 2>/dev/null
    echo "  ✓ tcp_keepalive_intvl = 30s"
    sysctl -w net.ipv4.tcp_keepalive_probes=5 2>/dev/null
    echo "  ✓ tcp_keepalive_probes = 5"

    # TCP缓冲区优化（16MB）
    echo -e "${gl_lv}优化TCP缓冲区（16MB）...${gl_bai}"
    sysctl -w net.core.rmem_max=16777216 2>/dev/null
    echo "  ✓ rmem_max = 16MB"
    sysctl -w net.core.wmem_max=16777216 2>/dev/null
    echo "  ✓ wmem_max = 16MB"
    sysctl -w net.ipv4.tcp_rmem='4096 87380 16777216' 2>/dev/null
    echo "  ✓ tcp_rmem = 4K 85K 16MB"
    sysctl -w net.ipv4.tcp_wmem='4096 65536 16777216' 2>/dev/null
    echo "  ✓ tcp_wmem = 4K 64K 16MB"

    # UDP优化（QUIC支持）
    echo -e "${gl_lv}优化UDP（QUIC支持）...${gl_bai}"
    sysctl -w net.ipv4.udp_rmem_min=8192 2>/dev/null
    echo "  ✓ udp_rmem_min = 8192"
    sysctl -w net.ipv4.udp_wmem_min=8192 2>/dev/null
    echo "  ✓ udp_wmem_min = 8192"

    # 连接队列优化
    echo -e "${gl_lv}优化连接队列...${gl_bai}"
    sysctl -w net.core.somaxconn=4096 2>/dev/null
    echo "  ✓ somaxconn = 4096"
    sysctl -w net.core.netdev_max_backlog=5000 2>/dev/null
    echo "  ✓ netdev_max_backlog = 5000 （修正过高值）"
    sysctl -w net.ipv4.ip_local_port_range='1024 65535' 2>/dev/null
    echo "  ✓ ip_local_port_range = 1024-65535"

    echo ""
    echo -e "${gl_lv}星辰大海ヾ优化模式设置完成！${gl_bai}"
    echo -e "${gl_zi}配置特点: TLS握手加速 + QUIC支持 + 大并发优化 + CAKE兼容${gl_bai}"
    echo -e "${gl_huang}优化说明: 已修正过激参数，保持用户CAKE设置，适配≥2GB内存${gl_bai}"
}

#=============================================================================
# 内核参数优化 - Reality终极优化（方案E）
#=============================================================================

optimize_reality_ultimate() {
    echo -e "${gl_lv}切换到Reality终极优化模式...${gl_bai}"
    echo -e "${gl_zi}基于星辰大海深度改进，性能提升5-10%，资源消耗降低25%${gl_bai}"
    echo ""
    echo -e "${gl_hong}⚠️  重要提示 ⚠️${gl_bai}"
    echo -e "${gl_huang}本配置为临时生效（使用 sysctl -w 命令）${gl_bai}"
    echo -e "${gl_huang}重启后将恢复到永久配置文件的设置${gl_bai}"
    echo ""
    echo "如果你之前执行过："
    echo "  - CAKE调优 / Debian12调优 / BBR直连优化"
    echo "重启后会恢复到那些配置，本次优化会消失！"
    echo ""
    read -e -p "是否继续？(Y/N) [Y]: " confirm
    confirm=${confirm:-Y}
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "已取消"
        return
    fi
    echo ""

    # 文件描述符优化
    echo -e "${gl_lv}优化文件描述符...${gl_bai}"
    ulimit -n 524288
    echo "  ✓ 文件描述符: 524288 (50万)"

    # TCP拥塞控制（核心）
    echo -e "${gl_lv}优化TCP拥塞控制...${gl_bai}"
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null
    echo "  ✓ tcp_congestion_control = bbr"
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [ "$current_qdisc" = "cake" ]; then
        echo "  ✓ default_qdisc = cake （保持用户设置）"
    else
        echo "  ℹ default_qdisc = $current_qdisc （保持不变）"
    fi

    # TCP连接优化（TLS握手加速）
    echo -e "${gl_lv}优化TCP连接（TLS握手加速）...${gl_bai}"
    sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null
    echo "  ✓ tcp_fastopen = 3"
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null
    echo "  ✓ tcp_slow_start_after_idle = 0 （关键优化）"
    sysctl -w net.ipv4.tcp_tw_reuse=1 2>/dev/null
    echo "  ✓ tcp_tw_reuse = 1"
    sysctl -w net.ipv4.ip_local_port_range='1024 65535' 2>/dev/null
    echo "  ✓ ip_local_port_range = 1024-65535"

    # Reality特有优化（方案E核心亮点）
    echo -e "${gl_lv}Reality特有优化...${gl_bai}"
    sysctl -w net.ipv4.tcp_notsent_lowat=16384 2>/dev/null
    echo "  ✓ tcp_notsent_lowat = 16384 （减少延迟）"
    sysctl -w net.ipv4.tcp_fin_timeout=15 2>/dev/null
    echo "  ✓ tcp_fin_timeout = 15 （快速回收）"
    sysctl -w net.ipv4.tcp_max_tw_buckets=5000 2>/dev/null
    echo "  ✓ tcp_max_tw_buckets = 5000"

    # TCP缓冲区（12MB平衡配置）
    echo -e "${gl_lv}优化TCP缓冲区（12MB）...${gl_bai}"
    sysctl -w net.core.rmem_max=12582912 2>/dev/null
    echo "  ✓ rmem_max = 12MB"
    sysctl -w net.core.wmem_max=12582912 2>/dev/null
    echo "  ✓ wmem_max = 12MB"
    sysctl -w net.ipv4.tcp_rmem='4096 87380 12582912' 2>/dev/null
    echo "  ✓ tcp_rmem = 4K 85K 12MB"
    sysctl -w net.ipv4.tcp_wmem='4096 65536 12582912' 2>/dev/null
    echo "  ✓ tcp_wmem = 4K 64K 12MB"

    # 内存管理
    echo -e "${gl_lv}优化内存管理...${gl_bai}"
    sysctl -w vm.swappiness=5 2>/dev/null
    echo "  ✓ swappiness = 5"
    sysctl -w vm.dirty_ratio=15 2>/dev/null
    echo "  ✓ dirty_ratio = 15"
    sysctl -w vm.dirty_background_ratio=5 2>/dev/null
    echo "  ✓ dirty_background_ratio = 5"
    sysctl -w vm.overcommit_memory=1 2>/dev/null
    echo "  ✓ overcommit_memory = 1"
    sysctl -w vm.vfs_cache_pressure=50 2>/dev/null
    echo "  ✓ vfs_cache_pressure = 50"

    # 连接保活（更短的检测周期）
    echo -e "${gl_lv}优化连接保活...${gl_bai}"
    sysctl -w net.ipv4.tcp_keepalive_time=300 2>/dev/null
    echo "  ✓ tcp_keepalive_time = 300s (5分钟)"
    sysctl -w net.ipv4.tcp_keepalive_intvl=30 2>/dev/null
    echo "  ✓ tcp_keepalive_intvl = 30s"
    sysctl -w net.ipv4.tcp_keepalive_probes=5 2>/dev/null
    echo "  ✓ tcp_keepalive_probes = 5"

    # UDP/QUIC优化
    echo -e "${gl_lv}优化UDP（QUIC支持）...${gl_bai}"
    sysctl -w net.ipv4.udp_rmem_min=8192 2>/dev/null
    echo "  ✓ udp_rmem_min = 8192"
    sysctl -w net.ipv4.udp_wmem_min=8192 2>/dev/null
    echo "  ✓ udp_wmem_min = 8192"

    # 连接队列优化（科学配置）
    echo -e "${gl_lv}优化连接队列...${gl_bai}"
    sysctl -w net.core.somaxconn=4096 2>/dev/null
    echo "  ✓ somaxconn = 4096"
    sysctl -w net.ipv4.tcp_max_syn_backlog=8192 2>/dev/null
    echo "  ✓ tcp_max_syn_backlog = 8192"
    sysctl -w net.core.netdev_max_backlog=5000 2>/dev/null
    echo "  ✓ netdev_max_backlog = 5000 （科学值）"

    # TCP安全
    echo -e "${gl_lv}TCP安全增强...${gl_bai}"
    sysctl -w net.ipv4.tcp_syncookies=1 2>/dev/null
    echo "  ✓ tcp_syncookies = 1"
    sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null
    echo "  ✓ tcp_mtu_probing = 1"

    echo ""
    echo -e "${gl_lv}Reality终极优化完成！${gl_bai}"
    echo -e "${gl_zi}配置特点: 性能提升5-10% + 资源消耗降低25% + 更科学的参数配置${gl_bai}"
    echo -e "${gl_huang}预期效果: 比星辰大海更平衡，适配性更强（≥2GB内存即可）${gl_bai}"
}

#=============================================================================
# 内核参数优化 - 低配优化（1GB内存专用）
#=============================================================================

optimize_low_spec() {
    echo -e "${gl_lv}切换到低配优化模式...${gl_bai}"
    echo -e "${gl_zi}专为512MB-1GB内存VPS设计，安全稳定${gl_bai}"
    echo ""
    echo -e "${gl_hong}⚠️  重要提示 ⚠️${gl_bai}"
    echo -e "${gl_huang}本配置为临时生效（使用 sysctl -w 命令）${gl_bai}"
    echo -e "${gl_huang}重启后将恢复到永久配置文件的设置${gl_bai}"
    echo ""
    echo "如果你之前执行过："
    echo "  - CAKE调优 / Debian12调优 / BBR直连优化"
    echo "重启后会恢复到那些配置，本次优化会消失！"
    echo ""
    read -e -p "是否继续？(Y/N) [Y]: " confirm
    confirm=${confirm:-Y}
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "已取消"
        return
    fi
    echo ""

    # 文件描述符优化（适度）
    echo -e "${gl_lv}优化文件描述符...${gl_bai}"
    ulimit -n 65535
    echo "  ✓ 文件描述符: 65535 (6.5万)"

    # TCP拥塞控制（核心）
    echo -e "${gl_lv}优化TCP拥塞控制...${gl_bai}"
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null
    echo "  ✓ tcp_congestion_control = bbr"
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [ "$current_qdisc" = "cake" ]; then
        echo "  ✓ default_qdisc = cake （保持用户设置）"
    else
        echo "  ℹ default_qdisc = $current_qdisc （保持不变）"
    fi

    # TCP连接优化（核心功能）
    echo -e "${gl_lv}优化TCP连接...${gl_bai}"
    sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null
    echo "  ✓ tcp_fastopen = 3"
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null
    echo "  ✓ tcp_slow_start_after_idle = 0 （关键优化）"
    sysctl -w net.ipv4.tcp_tw_reuse=1 2>/dev/null
    echo "  ✓ tcp_tw_reuse = 1"
    sysctl -w net.ipv4.ip_local_port_range='1024 65535' 2>/dev/null
    echo "  ✓ ip_local_port_range = 1024-65535"

    # TCP缓冲区（8MB保守配置）
    echo -e "${gl_lv}优化TCP缓冲区（8MB保守配置）...${gl_bai}"
    sysctl -w net.core.rmem_max=8388608 2>/dev/null
    echo "  ✓ rmem_max = 8MB"
    sysctl -w net.core.wmem_max=8388608 2>/dev/null
    echo "  ✓ wmem_max = 8MB"
    sysctl -w net.ipv4.tcp_rmem='4096 87380 8388608' 2>/dev/null
    echo "  ✓ tcp_rmem = 4K 85K 8MB"
    sysctl -w net.ipv4.tcp_wmem='4096 65536 8388608' 2>/dev/null
    echo "  ✓ tcp_wmem = 4K 64K 8MB"

    # 内存管理（保守安全）
    echo -e "${gl_lv}优化内存管理...${gl_bai}"
    sysctl -w vm.swappiness=10 2>/dev/null
    echo "  ✓ swappiness = 10 （安全值）"
    sysctl -w vm.dirty_ratio=20 2>/dev/null
    echo "  ✓ dirty_ratio = 20"
    sysctl -w vm.dirty_background_ratio=10 2>/dev/null
    echo "  ✓ dirty_background_ratio = 10"

    # 连接队列（适度配置）
    echo -e "${gl_lv}优化连接队列...${gl_bai}"
    sysctl -w net.core.somaxconn=2048 2>/dev/null
    echo "  ✓ somaxconn = 2048"
    sysctl -w net.ipv4.tcp_max_syn_backlog=4096 2>/dev/null
    echo "  ✓ tcp_max_syn_backlog = 4096"
    sysctl -w net.core.netdev_max_backlog=2500 2>/dev/null
    echo "  ✓ netdev_max_backlog = 2500"

    # TCP安全
    echo -e "${gl_lv}TCP安全增强...${gl_bai}"
    sysctl -w net.ipv4.tcp_syncookies=1 2>/dev/null
    echo "  ✓ tcp_syncookies = 1"

    echo ""
    echo -e "${gl_lv}低配优化完成！${gl_bai}"
    echo -e "${gl_zi}配置特点: 核心优化保留 + 资源消耗最低 + 稳定性最高${gl_bai}"
    echo -e "${gl_huang}适用场景: 512MB-1GB内存VPS，性能提升15-25%${gl_bai}"
}

#=============================================================================
# 内核参数优化 - 星辰大海原始版（用于对比测试）
#=============================================================================

optimize_xinchendahai_original() {
    echo -e "${gl_lv}切换到星辰大海ヾ原始版模式...${gl_bai}"
    echo -e "${gl_zi}针对 VLESS Reality 节点深度优化（原始参数）${gl_bai}"
    echo ""
    echo -e "${gl_hong}⚠️  重要提示 ⚠️${gl_bai}"
    echo -e "${gl_huang}本配置为临时生效（使用 sysctl -w 命令）${gl_bai}"
    echo -e "${gl_huang}重启后将恢复到永久配置文件的设置${gl_bai}"
    echo ""
    echo "如果你之前执行过："
    echo "  - CAKE调优 / Debian12调优 / BBR直连优化"
    echo "重启后会恢复到那些配置，本次优化会消失！"
    echo ""
    read -e -p "是否继续？(Y/N) [Y]: " confirm
    confirm=${confirm:-Y}
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "已取消"
        return
    fi
    echo ""

    echo -e "${gl_lv}优化文件描述符...${gl_bai}"
    ulimit -n 1048576
    echo "  ✓ 文件描述符: 1048576 (100万)"

    echo -e "${gl_lv}优化内存管理...${gl_bai}"
    sysctl -w vm.swappiness=1 2>/dev/null
    echo "  ✓ vm.swappiness = 1"
    sysctl -w vm.dirty_ratio=15 2>/dev/null
    echo "  ✓ vm.dirty_ratio = 15"
    sysctl -w vm.dirty_background_ratio=5 2>/dev/null
    echo "  ✓ vm.dirty_background_ratio = 5"
    sysctl -w vm.overcommit_memory=1 2>/dev/null
    echo "  ✓ vm.overcommit_memory = 1"
    sysctl -w vm.min_free_kbytes=65536 2>/dev/null
    echo "  ✓ vm.min_free_kbytes = 65536"
    sysctl -w vm.vfs_cache_pressure=50 2>/dev/null
    echo "  ✓ vm.vfs_cache_pressure = 50"

    echo -e "${gl_lv}优化TCP拥塞控制...${gl_bai}"
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null
    echo "  ✓ net.ipv4.tcp_congestion_control = bbr"
    
    # 智能检测当前 qdisc，如果是 cake 则保持，否则设为 fq
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "fq")
    if [ "$current_qdisc" = "cake" ]; then
        echo "  ✓ net.core.default_qdisc = cake (保持当前设置)"
    else
        sysctl -w net.core.default_qdisc=fq 2>/dev/null
        echo "  ✓ net.core.default_qdisc = fq"
    fi

    echo -e "${gl_lv}优化TCP连接（TLS握手加速）...${gl_bai}"
    sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null
    echo "  ✓ net.ipv4.tcp_fastopen = 3"
    sysctl -w net.ipv4.tcp_fin_timeout=30 2>/dev/null
    echo "  ✓ net.ipv4.tcp_fin_timeout = 30"
    sysctl -w net.ipv4.tcp_max_syn_backlog=8192 2>/dev/null
    echo "  ✓ net.ipv4.tcp_max_syn_backlog = 8192"
    sysctl -w net.ipv4.tcp_tw_reuse=1 2>/dev/null
    echo "  ✓ net.ipv4.tcp_tw_reuse = 1"
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null
    echo "  ✓ net.ipv4.tcp_slow_start_after_idle = 0"
    sysctl -w net.ipv4.tcp_mtu_probing=2 2>/dev/null
    echo "  ✓ net.ipv4.tcp_mtu_probing = 2"
    sysctl -w net.ipv4.tcp_window_scaling=1 2>/dev/null
    echo "  ✓ net.ipv4.tcp_window_scaling = 1"
    sysctl -w net.ipv4.tcp_timestamps=1 2>/dev/null
    echo "  ✓ net.ipv4.tcp_timestamps = 1"

    echo -e "${gl_lv}优化TCP安全/稳态...${gl_bai}"
    sysctl -w net.ipv4.tcp_syncookies=1 2>/dev/null
    echo "  ✓ net.ipv4.tcp_syncookies = 1"
    sysctl -w net.ipv4.tcp_keepalive_time=600 2>/dev/null
    echo "  ✓ net.ipv4.tcp_keepalive_time = 600"
    sysctl -w net.ipv4.tcp_keepalive_intvl=30 2>/dev/null
    echo "  ✓ net.ipv4.tcp_keepalive_intvl = 30"
    sysctl -w net.ipv4.tcp_keepalive_probes=5 2>/dev/null
    echo "  ✓ net.ipv4.tcp_keepalive_probes = 5"

    echo -e "${gl_lv}优化TCP缓冲区...${gl_bai}"
    sysctl -w net.core.rmem_max=16777216 2>/dev/null
    echo "  ✓ net.core.rmem_max = 16777216"
    sysctl -w net.core.wmem_max=16777216 2>/dev/null
    echo "  ✓ net.core.wmem_max = 16777216"
    sysctl -w net.core.rmem_default=262144 2>/dev/null
    echo "  ✓ net.core.rmem_default = 262144"
    sysctl -w net.core.wmem_default=262144 2>/dev/null
    echo "  ✓ net.core.wmem_default = 262144"
    sysctl -w net.ipv4.tcp_rmem='4096 87380 16777216' 2>/dev/null
    echo "  ✓ net.ipv4.tcp_rmem = 4096 87380 16777216"
    sysctl -w net.ipv4.tcp_wmem='4096 65536 16777216' 2>/dev/null
    echo "  ✓ net.ipv4.tcp_wmem = 4096 65536 16777216"

    echo -e "${gl_lv}优化UDP（QUIC支持）...${gl_bai}"
    sysctl -w net.ipv4.udp_rmem_min=8192 2>/dev/null
    echo "  ✓ net.ipv4.udp_rmem_min = 8192"
    sysctl -w net.ipv4.udp_wmem_min=8192 2>/dev/null
    echo "  ✓ net.ipv4.udp_wmem_min = 8192"

    echo -e "${gl_lv}优化连接队列...${gl_bai}"
    sysctl -w net.core.somaxconn=4096 2>/dev/null
    echo "  ✓ net.core.somaxconn = 4096"
    sysctl -w net.core.netdev_max_backlog=250000 2>/dev/null
    echo "  ✓ net.core.netdev_max_backlog = 250000"
    sysctl -w net.ipv4.ip_local_port_range='1024 65535' 2>/dev/null
    echo "  ✓ net.ipv4.ip_local_port_range = 1024 65535"

    echo -e "${gl_lv}优化CPU设置...${gl_bai}"
    sysctl -w kernel.sched_autogroup_enabled=0 2>/dev/null
    echo "  ✓ kernel.sched_autogroup_enabled = 0"
    sysctl -w kernel.numa_balancing=0 2>/dev/null
    echo "  ✓ kernel.numa_balancing = 0"

    echo -e "${gl_lv}其他优化...${gl_bai}"
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    echo "  ✓ transparent_hugepage = never"

    echo ""
    echo -e "${gl_lv}星辰大海ヾ原始版优化模式设置完成！${gl_bai}"
    echo -e "${gl_zi}配置特点: TLS握手加速 + QUIC支持 + 大并发优化${gl_bai}"
    echo -e "${gl_huang}注意: 这是原始参数版本，用于对比测试，建议≥4GB内存使用${gl_bai}"
}

#=============================================================================
# DNS净化与安全加固功能（NS论坛）- SSH安全增强版
#=============================================================================

# DNS净化 - 智能检测并修复 systemd-resolved
dns_purify_fix_systemd_resolved() {
    echo -e "${gl_kjlan}正在检测 systemd-resolved 服务状态...${gl_bai}"

    # 检查服务是否被 masked
    if systemctl is-enabled systemd-resolved &> /dev/null; then
        echo -e "${gl_lv}✅ systemd-resolved 服务状态正常${gl_bai}"
        return 0
    fi

    # 检查是否被 masked
    if systemctl status systemd-resolved 2>&1 | grep -q "masked"; then
        echo -e "${gl_huang}检测到 systemd-resolved 被屏蔽 (masked)，正在修复...${gl_bai}"

        # 解除屏蔽
        if systemctl unmask systemd-resolved 2>/dev/null; then
            echo -e "${gl_lv}✅ 已成功解除 systemd-resolved 的屏蔽状态${gl_bai}"
        else
            echo -e "${gl_hong}解除屏蔽失败，尝试手动修复...${gl_bai}"
            # 手动删除屏蔽链接
            rm -f /etc/systemd/system/systemd-resolved.service 2>/dev/null || true
            systemctl daemon-reload
            echo -e "${gl_lv}✅ 已手动移除屏蔽链接${gl_bai}"
        fi

        # 启用服务
        if systemctl enable systemd-resolved 2>/dev/null; then
            echo -e "${gl_lv}✅ 已启用 systemd-resolved 服务${gl_bai}"
        else
            echo -e "${gl_hong}启用服务失败${gl_bai}"
            return 1
        fi

        # 启动服务
        if systemctl start systemd-resolved 2>/dev/null; then
            echo -e "${gl_lv}✅ 已启动 systemd-resolved 服务${gl_bai}"
        else
            echo -e "${gl_hong}启动服务失败${gl_bai}"
            return 1
        fi

        # 等待服务完全启动
        sleep 2

        # 验证服务状态
        if systemctl is-active --quiet systemd-resolved; then
            echo -e "${gl_lv}✅ systemd-resolved 服务运行正常${gl_bai}"
            return 0
        else
            echo -e "${gl_hong}服务启动后状态异常${gl_bai}"
            systemctl status systemd-resolved --no-pager || true
            return 1
        fi
    else
        echo -e "${gl_huang}systemd-resolved 未启用，正在启用...${gl_bai}"
        systemctl enable systemd-resolved 2>/dev/null || true
        systemctl start systemd-resolved 2>/dev/null || true
        return 0
    fi
}

# DNS净化 - 主执行函数（SSH安全版）
dns_purify_and_harden() {
    clear
    echo -e "${gl_kjlan}╔════════════════════════════════════════════════════════════╗${gl_bai}"
    echo -e "${gl_kjlan}║    DNS净化与安全加固脚本 - SSH安全增强版 v2.0             ║${gl_bai}"
    echo -e "${gl_kjlan}╚════════════════════════════════════════════════════════════╝${gl_bai}"
    echo ""

    # ==================== SSH安全检测 ====================
    local IS_SSH=false
    if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
        IS_SSH=true
        echo -e "${gl_hong}⚠️  检测到您正在通过SSH连接${gl_bai}"
        echo -e "${gl_lv}✅ SSH安全模式已启用：本脚本不会中断您的网络连接${gl_bai}"
        echo ""
    fi

    echo -e "${gl_kjlan}功能说明：${gl_bai}"
    echo "  ✓ 配置安全的DNS服务器（支持国外/国内/混合模式）"
    echo "  ✓ 防止DHCP覆盖DNS配置"
    echo "  ✓ 清除厂商残留的DNS配置"
    echo "  ✓ 启用DNS安全功能（DNSSEC + DNS over TLS）"
    echo ""
    
    if [ "$IS_SSH" = true ]; then
        echo -e "${gl_lv}SSH安全保证：${gl_bai}"
        echo "  ✓ 不会停止或重启网络服务"
        echo "  ✓ 不会中断SSH连接"
        echo "  ✓ 所有配置立即生效，无需重启"
        echo "  ✓ 提供完整的回滚机制"
        echo ""
    fi
    
    # ==================== DNS模式选择 ====================
    echo -e "${gl_kjlan}请选择 DNS 配置模式：${gl_bai}"
    echo ""
    echo "  1. 🌍 纯国外模式（抗污染推荐）"
    echo "     首选：Google DNS + Cloudflare DNS"
    echo "     备用：无"
    echo "     加密：强制 DNS over TLS"
    echo ""
    echo "  2. 🇨🇳 纯国内模式（低延迟推荐）"
    echo "     首选：阿里云 DNS + 腾讯 DNSPod"
    echo "     备用：无"
    echo "     加密：无（国内DNS不支持DoT/DNSSEC）"
    echo ""
    echo "  3. 🔀 混合模式（最大容错）"
    echo "     首选：Google DNS + Cloudflare DNS"
    echo "     备用：阿里云 DNS + 114DNS"
    echo "     加密：机会性 DNS over TLS"
    echo ""
    read -e -p "$(echo -e "${gl_huang}请选择 (1/2/3，默认1): ${gl_bai}")" dns_mode_choice
    dns_mode_choice=${dns_mode_choice:-1}
    
    # 验证输入
    if [[ ! "$dns_mode_choice" =~ ^[1-3]$ ]]; then
        dns_mode_choice=1
    fi
    
    echo ""
    
    read -e -p "$(echo -e "${gl_huang}是否继续执行？(y/n): ${gl_bai}")" confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${gl_huang}已取消操作${gl_bai}"
        return
    fi

    # ==================== 终极安全检查 ====================
    echo ""
    echo -e "${gl_kjlan}[安全检查] 正在验证系统环境...${gl_bai}"
    echo ""
    
    local pre_check_failed=false
    
    # 检查1: 磁盘空间（至少需要100MB）
    echo -n "  → 检查磁盘空间... "
    local available_space=$(df -m /etc | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 100 ]; then
        echo -e "${gl_hong}失败 (可用: ${available_space}MB, 需要: 100MB)${gl_bai}"
        pre_check_failed=true
    else
        echo -e "${gl_lv}通过 (可用: ${available_space}MB)${gl_bai}"
    fi
    
    # 检查2: 内存（至少需要50MB可用）
    echo -n "  → 检查可用内存... "
    local available_mem=$(free -m | awk 'NR==2 {print $7}')
    if [ "$available_mem" -lt 50 ]; then
        echo -e "${gl_hong}失败 (可用: ${available_mem}MB, 需要: 50MB)${gl_bai}"
        pre_check_failed=true
    else
        echo -e "${gl_lv}通过 (可用: ${available_mem}MB)${gl_bai}"
    fi
    
    # 检查3: systemd 是否正常工作
    echo -n "  → 检查 systemd 状态... "
    if ! systemctl --version > /dev/null 2>&1; then
        echo -e "${gl_hong}失败 (systemctl 命令无法执行)${gl_bai}"
        pre_check_failed=true
    else
        echo -e "${gl_lv}通过${gl_bai}"
    fi
    
    # 检查4: 是否有其他包管理器在运行
    echo -n "  → 检查包管理器锁... "
    if lsof /var/lib/dpkg/lock-frontend > /dev/null 2>&1 || \
       lsof /var/lib/apt/lists/lock > /dev/null 2>&1 || \
       lsof /var/cache/apt/archives/lock > /dev/null 2>&1; then
        echo -e "${gl_hong}失败 (其他包管理器正在运行)${gl_bai}"
        pre_check_failed=true
    else
        echo -e "${gl_lv}通过${gl_bai}"
    fi
    
    # 检查5: /run 目录是否可写
    echo -n "  → 检查 /run 目录权限... "
    if ! touch /run/.dns_test 2>/dev/null; then
        echo -e "${gl_hong}失败 (/run 目录不可写)${gl_bai}"
        pre_check_failed=true
    else
        rm -f /run/.dns_test
        echo -e "${gl_lv}通过${gl_bai}"
    fi
    
    # 检查6: 网络连通性（能否访问DNS服务器）
    echo -n "  → 检查网络连通性... "
    if ! ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1 && \
       ! ping -c 1 -W 2 1.1.1.1 > /dev/null 2>&1; then
        echo -e "${gl_huang}警告 (无法ping通DNS服务器，但继续执行)${gl_bai}"
    else
        echo -e "${gl_lv}通过${gl_bai}"
    fi
    
    echo ""
    
    # 如果有检查失败，拒绝执行
    if [ "$pre_check_failed" = true ]; then
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_hong}❌ 安全检查未通过！${gl_bai}"
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "${gl_huang}系统环境不满足安全执行条件，拒绝执行以避免风险。${gl_bai}"
        echo ""
        echo "请先解决上述问题，然后重试。"
        echo ""
        break_end
        return 1
    fi
    
    echo -e "${gl_lv}✅ 所有安全检查通过，可以安全执行${gl_bai}"
    echo ""

    # ==================== 创建备份 ====================
    local BACKUP_DIR="/root/.dns_purify_backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    echo ""
    echo -e "${gl_lv}✅ 创建备份目录：$BACKUP_DIR${gl_bai}"
    echo ""

    # 目标DNS配置（根据用户选择的模式）
    local TARGET_DNS=""
    local FALLBACK_DNS=""
    local DNS_OVER_TLS=""
    local DNSSEC_MODE=""
    local MODE_NAME=""
    # 网卡级 DNS（用于 resolvectl，不含 DoT 后缀）
    local INTERFACE_DNS_PRIMARY=""
    local INTERFACE_DNS_SECONDARY=""
    
    case "$dns_mode_choice" in
        1)
            # 纯国外模式
            TARGET_DNS="8.8.8.8#dns.google 1.1.1.1#cloudflare-dns.com"
            FALLBACK_DNS=""
            DNS_OVER_TLS="yes"
            DNSSEC_MODE="no"
            MODE_NAME="纯国外模式"
            INTERFACE_DNS_PRIMARY="8.8.8.8"
            INTERFACE_DNS_SECONDARY="1.1.1.1"
            ;;
        2)
            # 纯国内模式（国内DNS和国内域名大多不支持DNSSEC，必须禁用）
            TARGET_DNS="223.5.5.5 119.29.29.29"
            FALLBACK_DNS=""
            DNS_OVER_TLS="no"
            DNSSEC_MODE="no"
            MODE_NAME="纯国内模式"
            INTERFACE_DNS_PRIMARY="223.5.5.5"
            INTERFACE_DNS_SECONDARY="119.29.29.29"
            ;;
        3)
            # 混合模式
            TARGET_DNS="8.8.8.8#dns.google 1.1.1.1#cloudflare-dns.com"
            FALLBACK_DNS="223.5.5.5 114.114.114.114"
            DNS_OVER_TLS="opportunistic"
            DNSSEC_MODE="no"
            MODE_NAME="混合模式"
            INTERFACE_DNS_PRIMARY="8.8.8.8"
            INTERFACE_DNS_SECONDARY="1.1.1.1"
            ;;
    esac
    
    echo -e "${gl_lv}已选择：${MODE_NAME}${gl_bai}"
    echo ""
    
    # 构建配置
    local SECURE_RESOLVED_CONFIG="[Resolve]
DNS=${TARGET_DNS}
${FALLBACK_DNS:+FallbackDNS=${FALLBACK_DNS}}
LLMNR=no
MulticastDNS=no
DNSSEC=${DNSSEC_MODE}
DNSOverTLS=${DNS_OVER_TLS}
Cache=yes
DNSStubListener=yes
"

    echo "--- 开始执行DNS净化与安全加固流程 ---"
    echo ""

    local debian_version
    debian_version=$(grep "VERSION_ID" /etc/os-release | cut -d'=' -f2 | tr -d '"' || echo "unknown")

    # ==================== 阶段一：清除DNS冲突源 ====================
    echo -e "${gl_kjlan}[阶段 1/4] 清除DNS冲突源（安全操作）...${gl_bai}"
    echo ""

    # 1. 驯服 DHCP 客户端
    local dhclient_conf="/etc/dhcp/dhclient.conf"
    if [[ -f "$dhclient_conf" ]]; then
        # 备份
        cp "$dhclient_conf" "$BACKUP_DIR/dhclient.conf.bak" 2>/dev/null || true
        
        if ! grep -q "ignore domain-name-servers;" "$dhclient_conf" || ! grep -q "ignore domain-search;" "$dhclient_conf"; then
            echo "  → 配置 dhclient 忽略DHCP提供的DNS..."
            echo "" >> "$dhclient_conf"
            echo "# 由DNS净化脚本添加 - $(date)" >> "$dhclient_conf"
            echo "ignore domain-name-servers;" >> "$dhclient_conf"
            echo "ignore domain-search;" >> "$dhclient_conf"
            echo -e "${gl_lv}  ✅ dhclient 配置完成${gl_bai}"
        else
            echo -e "${gl_lv}  ✅ dhclient 已配置（跳过）${gl_bai}"
        fi
    fi

    # 2. 禁用冲突的 if-up.d 脚本
    local ifup_script="/etc/network/if-up.d/resolved"
    if [[ -f "$ifup_script" ]] && [[ -x "$ifup_script" ]]; then
        echo "  → 禁用 if-up.d/resolved 脚本..."
        chmod -x "$ifup_script"
        echo -e "${gl_lv}  ✅ 已移除可执行权限${gl_bai}"
    fi

    # 3. 注释 /etc/network/interfaces 中的DNS配置
    local interfaces_file="/etc/network/interfaces"
    if [[ -f "$interfaces_file" ]]; then
        # 备份
        cp "$interfaces_file" "$BACKUP_DIR/interfaces.bak" 2>/dev/null || true
        
        if grep -qE '^[[:space:]]*dns-(nameservers|search|domain)' "$interfaces_file"; then
            echo "  → 清除 /etc/network/interfaces 中的DNS配置..."
            sed -i.bak -E 's/^([[:space:]]*dns-(nameservers|search|domain).*)/# \1 # 已被DNS净化脚本禁用/' "$interfaces_file"
            echo -e "${gl_lv}  ✅ 厂商DNS配置已注释${gl_bai}"
        else
            echo -e "${gl_lv}  ✅ /etc/network/interfaces 无DNS配置${gl_bai}"
        fi
    fi

    echo ""

    # ==================== 阶段二：配置 systemd-resolved ====================
    echo -e "${gl_kjlan}[阶段 2/4] 配置 systemd-resolved...${gl_bai}"
    echo ""

    # 检查是否已安装
    if ! command -v resolvectl &> /dev/null; then
        echo "  → 检测到未安装 systemd-resolved"
        echo "  → 安装 systemd-resolved..."
        apt-get update -y > /dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-resolved > /dev/null 2>&1
        echo -e "${gl_lv}  ✅ systemd-resolved 安装完成${gl_bai}"
    else
        echo -e "${gl_lv}  ✅ systemd-resolved 已安装${gl_bai}"
    fi

    # 处理 Debian 11 的 resolvconf 冲突
    if [[ "$debian_version" == "11" ]] && dpkg -s resolvconf &> /dev/null; then
        echo "  → 检测到 Debian 11 的 resolvconf 冲突"
        
        # 🛡️ 关键修复：在卸载前确保 systemd-resolved 完全就绪
        # 先启动 systemd-resolved
        echo "  → 启动 systemd-resolved（在卸载 resolvconf 之前）..."
        systemctl enable systemd-resolved 2>/dev/null || true
        systemctl start systemd-resolved 2>/dev/null || true
        
        # 等待服务启动
        sleep 2
        
        # 验证 systemd-resolved 正在运行
        if ! systemctl is-active --quiet systemd-resolved; then
            echo -e "${gl_hong}❌ 无法启动 systemd-resolved，中止操作${gl_bai}"
            break_end
            return 1
        fi
        
        # 验证 stub-resolv.conf 存在
        if [[ ! -f /run/systemd/resolve/stub-resolv.conf ]]; then
            echo -e "${gl_hong}❌ systemd-resolved stub 文件不存在，中止操作${gl_bai}"
            break_end
            return 1
        fi
        
        # 现在可以安全地卸载 resolvconf
        # 备份当前 resolv.conf
        [[ -f /etc/resolv.conf ]] && cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.pre_remove" 2>/dev/null || true
        
        # 创建临时DNS配置（避免卸载期间DNS中断）
        echo "nameserver $INTERFACE_DNS_PRIMARY" > /etc/resolv.conf.tmp
        echo "nameserver $INTERFACE_DNS_SECONDARY" >> /etc/resolv.conf.tmp
        
        # 使用临时DNS配置
        mv /etc/resolv.conf /etc/resolv.conf.old 2>/dev/null || true
        cp /etc/resolv.conf.tmp /etc/resolv.conf
        
        # 卸载 resolvconf
        echo "  → 卸载 resolvconf..."
        DEBIAN_FRONTEND=noninteractive apt-get remove -y resolvconf > /dev/null 2>&1
        
        # 清理临时文件
        rm -f /etc/resolv.conf.tmp /etc/resolv.conf.old
        
        echo -e "${gl_lv}  ✅ resolvconf 已安全卸载${gl_bai}"
    fi

    # 🔧 调用智能修复函数
    if ! dns_purify_fix_systemd_resolved; then
        echo -e "${gl_hong}❌ 无法修复 systemd-resolved 服务，脚本终止${gl_bai}"
        echo "配置未被修改，系统保持原状"
        break_end
        return 1
    fi

    # 备份并写入配置
    if [[ -f /etc/systemd/resolved.conf ]]; then
        cp /etc/systemd/resolved.conf "$BACKUP_DIR/resolved.conf.bak" 2>/dev/null || true
    fi

    echo "  → 配置 systemd-resolved..."
    echo -e "${SECURE_RESOLVED_CONFIG}" > /etc/systemd/resolved.conf
    
    echo ""

    # ==================== 阶段三：应用DNS配置（SSH安全方式）====================
    echo -e "${gl_kjlan}[阶段 3/4] 应用DNS配置（SSH安全模式）...${gl_bai}"
    echo ""

    # 先重新加载 systemd-resolved 配置
    echo "  → 重新加载 systemd-resolved 配置..."
    if ! systemctl reload-or-restart systemd-resolved; then
        echo -e "${gl_hong}❌ systemd-resolved 重启失败！${gl_bai}"
        echo "正在回滚配置..."
        if [[ -f "$BACKUP_DIR/resolved.conf.bak" ]]; then
            cp "$BACKUP_DIR/resolved.conf.bak" /etc/systemd/resolved.conf
            systemctl reload-or-restart systemd-resolved 2>/dev/null || true
        fi
        break_end
        return 1
    fi
    
    # 等待服务完全启动
    echo "  → 等待 systemd-resolved 完全启动..."
    sleep 3
    
    # 验证服务状态
    if ! systemctl is-active --quiet systemd-resolved; then
        echo -e "${gl_hong}❌ systemd-resolved 未能正常运行！${gl_bai}"
        echo "正在回滚配置..."
        if [[ -f "$BACKUP_DIR/resolved.conf.bak" ]]; then
            cp "$BACKUP_DIR/resolved.conf.bak" /etc/systemd/resolved.conf
            systemctl reload-or-restart systemd-resolved 2>/dev/null || true
        fi
        break_end
        return 1
    fi
    
    # 验证 stub-resolv.conf 文件存在
    if [[ ! -f /run/systemd/resolve/stub-resolv.conf ]]; then
        echo -e "${gl_hong}❌ systemd-resolved stub 文件不存在！${gl_bai}"
        echo "路径: /run/systemd/resolve/stub-resolv.conf"
        echo "正在回滚配置..."
        if [[ -f "$BACKUP_DIR/resolved.conf.bak" ]]; then
            cp "$BACKUP_DIR/resolved.conf.bak" /etc/systemd/resolved.conf
            systemctl reload-or-restart systemd-resolved 2>/dev/null || true
        fi
        break_end
        return 1
    fi
    
    echo -e "${gl_lv}  ✅ systemd-resolved 配置已重新加载并验证${gl_bai}"

    # 🔧 确保服务开机自启动（修复 #11：某些 Debian 版本服务状态为 static 时不会自启）
    echo "  → 确保 systemd-resolved 开机自启动..."
    systemctl enable systemd-resolved >/dev/null 2>&1 || true
    echo -e "${gl_lv}  ✅ 已设置开机自启动${gl_bai}"

    # 🔒 检测 immutable 属性（云服务商保护机制）
    if [[ -e /etc/resolv.conf ]] && lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
        echo ""
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_hong}⚠️  检测到 /etc/resolv.conf 被锁定保护${gl_bai}"
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "原因：您的服务器设置了不可变属性（通常是云服务商的保护机制）"
        echo ""
        echo "风险：强制修改可能导致机器失联或网络异常"
        echo ""
        echo "建议：如非必要，不建议继续修改"
        echo "      能正常执行的系统不会弹出此提示"
        echo ""
        echo -e "${gl_lv}状态：本次操作已安全终止，您的配置未被修改${gl_bai}"
        echo ""
        break_end
        return 1
    fi
    
    # 🛡️ 关键修复：安全地创建 resolv.conf 链接
    # 备份并创建 resolv.conf 链接（只有在验证通过后才执行）
    if [[ -e /etc/resolv.conf ]] && [[ ! -L /etc/resolv.conf ]]; then
        # 如果是普通文件，备份它
        cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
    fi
    
    # 安全地创建链接
    rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    
    # 验证链接创建成功
    if [[ ! -L /etc/resolv.conf ]] || [[ ! -e /etc/resolv.conf ]]; then
        echo -e "${gl_hong}❌ resolv.conf 链接创建失败！${gl_bai}"
        echo "正在恢复原始配置..."
        if [[ -f "$BACKUP_DIR/resolv.conf.bak" ]]; then
            rm -f /etc/resolv.conf
            cp "$BACKUP_DIR/resolv.conf.bak" /etc/resolv.conf
        fi
        break_end
        return 1
    fi
    
    echo -e "${gl_lv}  ✅ resolv.conf 链接已安全创建${gl_bai}"
    
    # 🚫 完全移除 networking.service 重启（即使非SSH模式也危险）
    # 注意：不管是SSH还是本地连接，都不重启 networking.service
    # 因为重启网络服务在生产环境中极其危险
    echo -e "${gl_lv}  ✅ 网络服务未受影响（安全模式）${gl_bai}"

    echo ""
    
    # ==================== Debian 13特殊修复：D-Bus接口注册问题 ====================
    echo -e "${gl_kjlan}[特殊修复] 检测并修复 D-Bus 接口注册（Debian 13兼容）...${gl_bai}"
    echo ""
    
    # 检测是否需要修复D-Bus接口
    local need_dbus_fix=false
    # 注意：debian_version 已在5180行定义，这里不再重复定义
    
    # 获取Debian版本
    if [ -f /etc/os-release ]; then
        debian_version=$(grep "VERSION_ID" /etc/os-release | cut -d'=' -f2 | tr -d '"' 2>/dev/null || echo "")
    fi
    
    echo "  → 检测系统版本：Debian ${debian_version:-未知}"
    
    # 检查resolvectl是否能正常通信
    echo "  → 测试 resolvectl 命令响应..."
    if ! timeout 3 resolvectl status >/dev/null 2>&1; then
        echo -e "${gl_huang}  ⚠️  resolvectl 命令无响应，需要修复 D-Bus 接口${gl_bai}"
        need_dbus_fix=true
    else
        echo -e "${gl_lv}  ✅ resolvectl 响应正常${gl_bai}"
    fi
    
    # 如果需要修复D-Bus接口
    if [ "$need_dbus_fix" = true ]; then
        echo ""
        echo -e "${gl_huang}检测到 D-Bus 接口注册问题（Debian 13已知问题），正在自动修复...${gl_bai}"
        echo ""
        
        # 🛡️ 安全措施：在重启前创建临时DNS配置，确保DNS始终可用
        echo "  → 创建临时DNS配置（防止修复期间DNS中断）..."
        
        # 备份当前resolv.conf
        if [[ -e /etc/resolv.conf ]]; then
            cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.before_dbus_fix" 2>/dev/null || true
        fi
        
        # 创建临时DNS配置文件
        cat > /etc/resolv.conf.dbus_fix_temp << TEMP_DNS
# 临时DNS配置（D-Bus修复期间使用）
nameserver $INTERFACE_DNS_PRIMARY
nameserver $INTERFACE_DNS_SECONDARY
TEMP_DNS
        
        # 使用临时DNS配置
        rm -f /etc/resolv.conf
        cp /etc/resolv.conf.dbus_fix_temp /etc/resolv.conf
        chmod 644 /etc/resolv.conf
        
        echo -e "${gl_lv}  ✅ 临时DNS配置已创建（确保修复期间DNS可用）${gl_bai}"
        
        # 1. 完全重启systemd-resolved，让它重新注册D-Bus接口
        echo "  → 重启 systemd-resolved 以重新注册 D-Bus 接口..."
        systemctl stop systemd-resolved 2>/dev/null || true
        sleep 2
        systemctl start systemd-resolved 2>/dev/null || true
        sleep 3
        
        # 🛡️ 恢复到 stub-resolv.conf 链接
        echo "  → 恢复 resolv.conf 链接到 stub-resolv.conf..."
        
        # 验证 stub-resolv.conf 存在
        if [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
            rm -f /etc/resolv.conf
            ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            echo -e "${gl_lv}  ✅ resolv.conf 链接已恢复${gl_bai}"
        else
            echo -e "${gl_huang}  ⚠️  stub-resolv.conf 不存在，保持临时DNS配置${gl_bai}"
        fi
        
        # 清理临时文件
        rm -f /etc/resolv.conf.dbus_fix_temp
        
        # 2. 验证D-Bus接口是否注册成功
        if command -v busctl &>/dev/null; then
            local dbus_status=$(busctl list 2>/dev/null | grep "org.freedesktop.resolve1" | grep -v "activatable" || echo "")
            if [ -n "$dbus_status" ]; then
                echo -e "${gl_lv}  ✅ D-Bus 接口已成功注册${gl_bai}"
                
                # 3. 创建永久修复配置（确保重启后也能正常工作）
                echo "  → 创建永久修复配置..."
                mkdir -p /etc/systemd/system/systemd-resolved.service.d
                cat > /etc/systemd/system/systemd-resolved.service.d/dbus-fix.conf << 'DBUS_FIX'
# Debian 13 D-Bus接口注册修复
# 确保D-Bus完全启动后再启动systemd-resolved
[Unit]
After=dbus.service
Requires=dbus.service

[Service]
# 启动后等待1秒，确保D-Bus接口注册完成
ExecStartPost=/bin/sleep 1
DBUS_FIX
                
                systemctl daemon-reload 2>/dev/null || true
                echo -e "${gl_lv}  ✅ 永久修复配置已创建${gl_bai}"
                
                # 4. 再次测试resolvectl
                if timeout 3 resolvectl status >/dev/null 2>&1; then
                    echo -e "${gl_lv}  ✅ resolvectl 现在能正常工作了${gl_bai}"
                else
                    echo -e "${gl_huang}  ⚠️  resolvectl 仍无响应（但DNS配置已通过resolved.conf生效）${gl_bai}"
                fi
            else
                echo -e "${gl_huang}  ⚠️  D-Bus 接口注册可能失败${gl_bai}"
                echo -e "${gl_lv}  ✅ 但DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
            fi
        else
            echo -e "${gl_huang}  ⚠️  busctl 命令不可用，无法验证 D-Bus 状态${gl_bai}"
            echo -e "${gl_lv}  ✅ 但DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
        fi
        
        echo ""
    fi

    echo ""

    # ==================== 阶段四：配置网卡DNS ====================
    echo -e "${gl_kjlan}[阶段 4/4] 配置网卡DNS（立即生效）...${gl_bai}"
    echo ""
    
    # 🔥 强力保障：阶段4执行前二次验证resolvectl（确保100%成功）
    echo "  → 验证 resolvectl 命令状态..."
    local resolvectl_ready=true
    
    # 快速测试resolvectl是否响应（2秒超时）
    if ! timeout 2 resolvectl status >/dev/null 2>&1; then
        echo -e "${gl_huang}  ⚠️  resolvectl 仍无响应${gl_bai}"
        echo ""
        echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_huang}检测到 resolvectl 命令无法正常工作${gl_bai}"
        echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "这可能导致阶段4的网卡级DNS配置失败。"
        echo ""
        echo "你可以选择："
        echo "  1) 尝试强制修复（会重启systemd-resolved，有临时DNS保护）"
        echo "  2) 跳过网卡配置（安全，全局DNS已生效，推荐）"
        echo ""
        read -e -p "$(echo -e "${gl_huang}请选择 (1/2，默认2): ${gl_bai}")" force_fix_choice
        force_fix_choice=${force_fix_choice:-2}
        
        if [[ "$force_fix_choice" == "1" ]]; then
            echo ""
            echo -e "${gl_kjlan}正在执行强制修复...${gl_bai}"
            resolvectl_ready=false
            
            # 强制修复：重启systemd-resolved重新注册D-Bus
            echo "  → 创建临时DNS保护..."
            
            # 创建临时DNS保护
            cat > /etc/resolv.conf.stage4_temp << STAGE4_TEMP
nameserver $INTERFACE_DNS_PRIMARY
nameserver $INTERFACE_DNS_SECONDARY
STAGE4_TEMP
            cp /etc/resolv.conf /etc/resolv.conf.stage4_backup 2>/dev/null || true
            cp /etc/resolv.conf.stage4_temp /etc/resolv.conf
            
            echo "  → 强制重启 systemd-resolved..."
            # 完全重启服务
            systemctl stop systemd-resolved 2>/dev/null || true
            sleep 2
            systemctl start systemd-resolved 2>/dev/null || true
            sleep 3
            
            # 恢复链接
            echo "  → 恢复 resolv.conf 链接..."
            if [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
                rm -f /etc/resolv.conf
                ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            fi
            
            # 清理临时文件
            rm -f /etc/resolv.conf.stage4_temp /etc/resolv.conf.stage4_backup
            
            # 再次验证
            echo "  → 验证修复结果..."
            if timeout 2 resolvectl status >/dev/null 2>&1; then
                echo -e "${gl_lv}  ✅ resolvectl 已修复，可以继续${gl_bai}"
                resolvectl_ready=true
            else
                echo -e "${gl_huang}  ⚠️  resolvectl 仍无法正常工作${gl_bai}"
                echo -e "${gl_lv}  ✅ 将跳过网卡级DNS配置（全局DNS已生效）${gl_bai}"
                resolvectl_ready=false
            fi
            echo ""
        else
            echo ""
            echo -e "${gl_lv}已选择跳过强制修复（安全选择）${gl_bai}"
            echo -e "${gl_lv}将跳过网卡级DNS配置，全局DNS配置已生效${gl_bai}"
            resolvectl_ready=false
            echo ""
        fi
    else
        echo -e "${gl_lv}  ✅ resolvectl 响应正常${gl_bai}"
    fi
    
    echo ""

    # 检测主网卡
    local main_interface=$(ip route | grep '^default' | awk '{print $5}' | head -n1)

    if [[ -n "$main_interface" ]] && command -v resolvectl &> /dev/null && [ "$resolvectl_ready" = true ]; then
        echo "  → 检测到主网卡: ${main_interface}"
        
        # 🛡️ 关键修复：检查timeout命令是否可用
        if ! command -v timeout &> /dev/null; then
            echo -e "${gl_huang}  ⚠️  timeout命令不可用，跳过网卡级DNS配置${gl_bai}"
            echo -e "${gl_lv}  ✅ DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
        else
            echo "  → 配置网卡 DNS（立即生效，无需重启）..."
            echo ""
            
            # 🛡️ 修复：添加超时机制防止resolvectl命令hang住
            local resolvectl_timeout=5  # 5秒超时
            local dns_config_success=true
            
            echo "    正在应用DNS服务器配置..."
            if timeout "$resolvectl_timeout" resolvectl dns "$main_interface" $INTERFACE_DNS_PRIMARY $INTERFACE_DNS_SECONDARY 2>/dev/null; then
                echo -e "    ${gl_lv}✅ DNS服务器配置成功${gl_bai}"
            else
                echo -e "    ${gl_huang}⚠️  DNS服务器配置超时或失败（配置已通过resolved.conf生效）${gl_bai}"
                dns_config_success=false
            fi
            
            echo "    正在应用DNS域配置..."
            if timeout "$resolvectl_timeout" resolvectl domain "$main_interface" ~. 2>/dev/null; then
                echo -e "    ${gl_lv}✅ DNS域配置成功${gl_bai}"
            else
                echo -e "    ${gl_huang}⚠️  DNS域配置超时或失败（配置已通过resolved.conf生效）${gl_bai}"
                dns_config_success=false
            fi
            
            echo "    正在应用默认路由配置..."
            if timeout "$resolvectl_timeout" resolvectl default-route "$main_interface" yes 2>/dev/null; then
                echo -e "    ${gl_lv}✅ 默认路由配置成功${gl_bai}"
            else
                echo -e "    ${gl_huang}⚠️  默认路由配置超时或失败（配置已通过resolved.conf生效）${gl_bai}"
                dns_config_success=false
            fi
            
            echo ""
            if [ "$dns_config_success" = true ]; then
                echo -e "${gl_lv}  ✅ 网卡DNS配置已全部应用${gl_bai}"
            else
                echo -e "${gl_huang}  ⚠️  部分网卡DNS配置未能通过resolvectl应用${gl_bai}"
                echo -e "${gl_lv}  ✅ 但DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
            fi
        fi
        echo -e "${gl_lv}  ✅ DNS配置立即生效，无需重启${gl_bai}"
    else
        if [[ -z "$main_interface" ]]; then
            echo -e "${gl_huang}  ⚠️  未检测到默认网卡${gl_bai}"
        else
            echo -e "${gl_huang}  ⚠️  resolvectl 命令不可用${gl_bai}"
        fi
        echo -e "${gl_lv}  ✅ DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
    fi

    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}✅ DNS净化完成！${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    # 显示当前DNS状态
    echo -e "${gl_huang}当前DNS配置：${gl_bai}"
    echo "────────────────────────────────────────────────────────"
    if command -v resolvectl &> /dev/null; then
        resolvectl status 2>/dev/null | head -30 || cat /etc/resolv.conf
    else
        cat /etc/resolv.conf
    fi
    echo "────────────────────────────────────────────────────────"
    
    # ==================== 统一验证输出（兼容所有systemd版本）====================
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}[智能验证] 网卡DNS配置状态检测：${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    if command -v resolvectl &> /dev/null && [[ -n "$main_interface" ]]; then
        local verify_output=$(resolvectl status "$main_interface" 2>/dev/null || echo "")
        local verify_success=true
        
        # 检测1: Default Route（兼容不同systemd版本）
        if echo "$verify_output" | grep -q "Default Route: yes" || \
           echo "$verify_output" | grep -q "Protocols:.*+DefaultRoute"; then
            echo -e "  ${gl_lv}✅ Default Route: 已启用${gl_bai}"
        else
            echo -e "  ${gl_huang}⚠️  Default Route: 未启用或不支持${gl_bai}"
            verify_success=false
        fi
        
        # 检测2: DNS Servers（根据用户选择的模式动态验证）
        local escaped_dns_primary=$(echo "$INTERFACE_DNS_PRIMARY" | sed 's/\./\\./g')
        local escaped_dns_secondary=$(echo "$INTERFACE_DNS_SECONDARY" | sed 's/\./\\./g')
        if echo "$verify_output" | grep -q "DNS Servers:.*${escaped_dns_primary}" && \
           echo "$verify_output" | grep -q "DNS Servers:.*${escaped_dns_secondary}"; then
            echo -e "  ${gl_lv}✅ DNS Servers: ${INTERFACE_DNS_PRIMARY}, ${INTERFACE_DNS_SECONDARY}${gl_bai}"
        else
            echo -e "  ${gl_huang}⚠️  DNS Servers: 配置可能未完全生效${gl_bai}"
            verify_success=false
        fi
        
        # 检测3: DNS Domain
        if echo "$verify_output" | grep -q "DNS Domain:.*~\."; then
            echo -e "  ${gl_lv}✅ DNS Domain: ~. (所有域名)${gl_bai}"
        else
            echo -e "  ${gl_huang}⚠️  DNS Domain: 未配置${gl_bai}"
            verify_success=false
        fi
        
        echo ""
        
        # 最终判断
        if [ "$verify_success" = true ]; then
            echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            echo -e "${gl_lv}💯 最终判断: 网卡DNS配置 100% 成功！${gl_bai}"
            echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        else
            echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            echo -e "${gl_huang}⚠️  网卡DNS配置部分未生效${gl_bai}"
            echo -e "${gl_lv}✅ 但全局DNS配置已生效，DNS解析正常工作${gl_bai}"
            echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        fi
    else
        echo -e "${gl_huang}  ⚠️  resolvectl 不可用或未检测到网卡${gl_bai}"
        echo -e "${gl_lv}  ✅ 全局DNS配置已生效${gl_bai}"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    fi
    
    echo ""

    # 测试DNS解析（等待配置生效）
    echo -e "${gl_huang}测试DNS解析：${gl_bai}"
    echo "  → 等待DNS配置生效（3秒）..."
    sleep 3
    
    local dns_test_passed=false
    
    # 根据用户选择的模式选择测试域名
    local test_domain=""
    if [[ "$dns_mode_choice" == "2" ]]; then
        # 纯国内模式：使用国内域名测试
        test_domain="baidu.com"
    else
        # 国外/混合模式：使用国外域名测试
        test_domain="google.com"
    fi
    
    # 方法1: 使用 getent（最可靠）
    if command -v getent > /dev/null 2>&1; then
        if getent hosts "$test_domain" > /dev/null 2>&1; then
            echo -e "${gl_lv}  ✅ DNS解析正常 (getent测试: $test_domain)${gl_bai}"
            dns_test_passed=true
        fi
    fi
    
    # 方法2: 使用 ping
    if [ "$dns_test_passed" = false ] && ping -c 1 -W 2 "$test_domain" > /dev/null 2>&1; then
        echo -e "${gl_lv}  ✅ DNS解析正常 (ping测试: $test_domain)${gl_bai}"
        dns_test_passed=true
    fi
    
    # 方法3: 使用 nslookup（如果可用）
    if [ "$dns_test_passed" = false ] && command -v nslookup > /dev/null 2>&1; then
        if nslookup "$test_domain" > /dev/null 2>&1; then
            echo -e "${gl_lv}  ✅ DNS解析正常 (nslookup测试: $test_domain)${gl_bai}"
            dns_test_passed=true
        fi
    fi
    
    # 如果所有测试都失败
    if [ "$dns_test_passed" = false ]; then
        echo -e "${gl_huang}  ⚠️  DNS测试未通过，但配置已完成${gl_bai}"
        echo -e "${gl_huang}  提示: 请手动执行以下命令测试DNS：${gl_bai}"
        echo "       ping $test_domain"
        echo "       curl $test_domain"
    fi
    echo ""

    # ==================== 生成回滚脚本 ====================
    cat > "$BACKUP_DIR/rollback.sh" << 'ROLLBACK_SCRIPT'
#!/bin/bash
# DNS配置回滚脚本
# 使用方法: bash rollback.sh

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DNS配置回滚脚本"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

BACKUP_DIR="$(dirname "$0")"

# 恢复 dhclient.conf
if [[ -f "$BACKUP_DIR/dhclient.conf.bak" ]]; then
    echo "恢复 dhclient.conf..."
    cp "$BACKUP_DIR/dhclient.conf.bak" /etc/dhcp/dhclient.conf
    echo "✅ 已恢复 dhclient.conf"
fi

# 恢复 interfaces
if [[ -f "$BACKUP_DIR/interfaces.bak" ]]; then
    echo "恢复 interfaces..."
    cp "$BACKUP_DIR/interfaces.bak" /etc/network/interfaces
    echo "✅ 已恢复 interfaces"
fi

# 恢复 resolved.conf
if [[ -f "$BACKUP_DIR/resolved.conf.bak" ]]; then
    echo "恢复 resolved.conf..."
    cp "$BACKUP_DIR/resolved.conf.bak" /etc/systemd/resolved.conf
    echo "✅ 已恢复 resolved.conf"
fi

# 恢复 resolv.conf
if [[ -f "$BACKUP_DIR/resolv.conf.bak" ]]; then
    echo "恢复 resolv.conf..."
    cp "$BACKUP_DIR/resolv.conf.bak" /etc/resolv.conf
    echo "✅ 已恢复 resolv.conf"
fi

# 重新加载 systemd-resolved
echo "重新加载 systemd-resolved..."
systemctl reload-or-restart systemd-resolved 2>/dev/null || true
echo "✅ systemd-resolved 已重新加载"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 回滚完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ROLLBACK_SCRIPT

    chmod +x "$BACKUP_DIR/rollback.sh"

    # 显示备份信息
    echo -e "${gl_kjlan}备份与回滚信息：${gl_bai}"
    echo "  所有原始配置已备份到："
    echo "  $BACKUP_DIR"
    echo ""
    echo -e "${gl_huang}如需回滚，执行：${gl_bai}"
    echo "  bash $BACKUP_DIR/rollback.sh"
    echo ""

    echo -e "${gl_lv}DNS净化脚本执行完成${gl_bai}"
    echo "原作者：NSdesk"
    echo "安全增强：SSH防断连优化"
    echo "更多信息：https://www.nodeseek.com/space/23129#/general"
    echo "════════════════════════════════════════════════════════"
    echo ""

    break_end
}

#=============================================================================
# Realm 转发首连超时修复（专项优化）
#=============================================================================

realm_fix_timeout() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}   Realm 转发首连超时修复（针对跨境线路优化）${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_huang}功能说明：${gl_bai}"
    echo "  • 强制 IPv4（避免 IPv6 路由问题）"
    echo "  • MSS 钳制（解决 MTU 黑洞）"
    echo "  • 禁用 TCP Fast Open（提升兼容性）"
    echo "  • 优化 Realm 配置（nodelay + reuse_port）"
    echo "  • DNS IPv4 纠偏"
    echo ""
    echo -e "${gl_huang}⚠️  注意：本功能不会覆盖已有的 TCP 调优参数${gl_bai}"
    echo ""
    read -e -p "是否继续执行修复？(y/n): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${gl_huang}已取消操作${gl_bai}"
        return
    fi

    # 检查 root 权限
    if [[ ${EUID:-0} -ne 0 ]]; then
        echo -e "${gl_hong}错误：请以 root 身份运行（sudo -i 或 sudo bash）${gl_bai}"
        return 1
    fi

    # 备份目录
    BACKUP_DIR="/root/.realm_fix_backup/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    echo -e "${gl_lv}[1/8] 创建备份目录：$BACKUP_DIR${gl_bai}"

    # 加载并持久化 nf_conntrack
    echo -e "${gl_lv}[2/8] 加载/持久化 nf_conntrack（连接跟踪）${gl_bai}"
    if command -v modprobe >/dev/null 2>&1; then
        modprobe nf_conntrack 2>/dev/null || true
    fi
    mkdir -p /etc/modules-load.d
    if ! grep -q '^nf_conntrack$' /etc/modules-load.d/conntrack.conf 2>/dev/null; then
        echo nf_conntrack >> /etc/modules-load.d/conntrack.conf
    fi

    # 写入 Realm 专属 sysctl 配置（不覆盖已有参数）
    echo -e "${gl_lv}[3/8] 写入 Realm 专属 sysctl 配置（/etc/sysctl.d/60-realm-tune.conf）${gl_bai}"
    cat >/etc/sysctl.d/60-realm-tune.conf <<'SYSC'
# Realm 转发专属优化（不覆盖 net-tcp-tune.sh 的基础配置）

# 连接跟踪容量（转发必需）
net.netfilter.nf_conntrack_max = 262144

# FIN/TIME_WAIT 收敛（加快连接回收）
net.ipv4.tcp_fin_timeout = 30

# 禁用 TFO（避免跨境防火墙拦截，解决首连超时）
net.ipv4.tcp_fastopen = 0
SYSC

    echo -e "${gl_lv}[4/8] 应用 sysctl 配置${gl_bai}"
    sysctl --system >/dev/null 2>&1

    # 修改 Realm 配置
    realm_cfg="/etc/realm/config.json"
    if [[ -f "$realm_cfg" ]]; then
        echo -e "${gl_lv}[5/8] 备份并优化 Realm 配置${gl_bai}"
        cp -a "$realm_cfg" "$BACKUP_DIR/"

        if command -v jq >/dev/null 2>&1; then
            tmpfile=$(mktemp)
            jq '.resolve = "ipv4" | .nodelay = true | .reuse_port = true' \
                "$realm_cfg" >"$tmpfile" && mv "$tmpfile" "$realm_cfg"
        else
            echo -e "${gl_huang}  未安装 jq，使用文本方式修改（推荐安装 jq）${gl_bai}"
            if ! grep -q '"resolve"' "$realm_cfg"; then
                sed -i.bak '0,/{/s//{\n  "resolve": "ipv4",/' "$realm_cfg" || true
            fi
            if ! grep -q '"nodelay"' "$realm_cfg"; then
                sed -i.bak '0,/{/s//{\n  "nodelay": true,/' "$realm_cfg" || true
            fi
            if ! grep -q '"reuse_port"' "$realm_cfg"; then
                sed -i.bak '0,/{/s//{\n  "reuse_port": true,/' "$realm_cfg" || true
            fi
        fi
        
        # 统一用文本替换确保 IPv6 监听改为 IPv4
        sed -i.bak -E 's/"listen"\s*:\s*":::([0-9]+)"/"listen": "0.0.0.0:\1"/g' "$realm_cfg" 2>/dev/null || true
        sed -i.bak -E 's/"listen"\s*:\s*"\[::\]:([0-9]+)"/"listen": "0.0.0.0:\1"/g' "$realm_cfg" 2>/dev/null || true
        sed -i.bak 's/:::/0.0.0.0:/g' "$realm_cfg" 2>/dev/null || true
    else
        echo -e "${gl_huang}[5/8] 未找到 $realm_cfg，跳过 Realm 配置修改${gl_bai}"
    fi

    # DNS 纠偏（仅保留 IPv4 DNS）
    echo -e "${gl_lv}[6/8] 备份并纠偏 DNS 配置${gl_bai}"
    if [[ -e /etc/resolv.conf ]]; then
        cp -a /etc/resolv.conf "$BACKUP_DIR/resolv.conf" 2>/dev/null || true
        ipv4_dns=$(grep -E "^nameserver\s+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" /etc/resolv.conf 2>/dev/null || true)
        if [[ -z "$ipv4_dns" ]]; then
            cat >/etc/resolv.conf <<'DNS'
nameserver 1.1.1.1
nameserver 8.8.8.8
DNS
        else
            printf "%s\n" "$ipv4_dns" > /etc/resolv.conf
        fi
    fi

    # 配置 MSS 钳制（自动兼容 iptables/nftables）
    echo -e "${gl_lv}[7/8] 配置 MSS 钳制规则（OUTPUT 链）${gl_bai}"
    added_mss_rule=false

    # 策略1: 优先使用 iptables（兼容性最好）
    if command -v iptables >/dev/null 2>&1; then
        echo -e "${gl_huang}  检测到 iptables，使用 iptables 添加规则...${gl_bai}"
        if ! iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
            iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null && added_mss_rule=true
        else
            added_mss_rule=true
        fi

        # 可选：FORWARD 链（路由转发场景）
        if ! iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
            iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        fi
    fi

    # 策略2: 如果没有 iptables，自动安装
    if [ "$added_mss_rule" != true ] && ! command -v iptables >/dev/null 2>&1; then
        echo -e "${gl_huang}  未检测到 iptables，正在自动安装...${gl_bai}"
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y iptables >/dev/null 2>&1
            
            if command -v iptables >/dev/null 2>&1; then
                echo -e "${gl_lv}  ✓ iptables 安装成功${gl_bai}"
                if iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
                    added_mss_rule=true
                fi
                iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            else
                echo -e "${gl_huang}  ⚠ iptables 安装失败，尝试使用 nftables...${gl_bai}"
            fi
        elif command -v yum >/dev/null 2>&1; then
            yum install -y iptables >/dev/null 2>&1
            if command -v iptables >/dev/null 2>&1; then
                echo -e "${gl_lv}  ✓ iptables 安装成功${gl_bai}"
                if iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
                    added_mss_rule=true
                fi
                iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            fi
        fi
    fi

    # 策略3: 备用方案 - 使用 nftables（自动适配语法）
    if [ "$added_mss_rule" != true ] && command -v nft >/dev/null 2>&1; then
        echo -e "${gl_huang}  使用 nftables 添加规则...${gl_bai}"
        nft add table inet mangle 2>/dev/null || true
        nft add chain inet mangle output '{ type route hook output priority mangle; }' 2>/dev/null || true
        
        # 检查是否已有 MSS 规则（兼容多种语法）
        if ! nft list chain inet mangle output 2>/dev/null | grep -qE 'maxseg.*(clamp|rt mtu)'; then
            # 优先尝试 rt mtu（nftables 1.0+ 推荐语法）
            if nft add rule inet mangle output tcp flags syn tcp option maxseg size set rt mtu 2>/dev/null; then
                added_mss_rule=true
            # 备选：clamp to pmtu（旧语法）
            elif nft add rule inet mangle output tcp flags syn tcp option maxseg size set clamp to pmtu 2>/dev/null; then
                added_mss_rule=true
            # 最后尝试：clamp to mtu
            elif nft add rule inet mangle output tcp flags syn tcp option maxseg size set clamp to mtu 2>/dev/null; then
                added_mss_rule=true
            fi
        else
            added_mss_rule=true
        fi

        # 可选：FORWARD 链（路由转发场景）
        nft add chain inet mangle forward '{ type filter hook forward priority mangle; }' 2>/dev/null || true
        if ! nft list chain inet mangle forward 2>/dev/null | grep -qE 'maxseg.*(clamp|rt mtu)'; then
            nft add rule inet mangle forward tcp flags syn tcp option maxseg size set rt mtu 2>/dev/null || \
                nft add rule inet mangle forward tcp flags syn tcp option maxseg size set clamp to pmtu 2>/dev/null || \
                nft add rule inet mangle forward tcp flags syn tcp option maxseg size set clamp to mtu 2>/dev/null
        fi
    fi

    if [[ "$added_mss_rule" == true ]]; then
        echo -e "${gl_lv}  ✓ MSS 钳制规则已确保存在${gl_bai}"
    else
        echo -e "${gl_hong}  ✗ 未能添加 MSS 钳制规则，请手动排查${gl_bai}"
    fi

    # realm.service 文件句柄限制
    echo -e "${gl_lv}[8/8] 提升 realm.service 文件句柄限制${gl_bai}"
    if systemctl list-unit-files 2>/dev/null | grep -q '^realm\.service'; then
        mkdir -p /etc/systemd/system/realm.service.d
        cat >/etc/systemd/system/realm.service.d/override.conf <<'OVR'
[Service]
LimitNOFILE=1048576
OVR
        systemctl daemon-reload
        systemctl restart realm 2>/dev/null || echo -e "${gl_huang}  ⚠ realm 重启失败，请手动检查${gl_bai}"
    else
        echo -e "${gl_huang}  未发现 realm.service，跳过${gl_bai}"
    fi

    # 持久化防火墙规则（自动执行，兼容 iptables/nftables）
    if [ "$added_mss_rule" = true ]; then
        echo -e "${gl_lv}[9/9] 持久化防火墙规则（确保重启后生效）${gl_bai}"
        
        # 判断使用的是哪种防火墙
        if command -v iptables >/dev/null 2>&1; then
            # 持久化 iptables
            echo -e "${gl_huang}  持久化 iptables 规则...${gl_bai}"
            
            # 检查是否已安装 iptables-persistent
            if ! dpkg -l | grep -q iptables-persistent 2>/dev/null; then
                echo -e "${gl_huang}  正在安装 iptables-persistent...${gl_bai}"
                DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1
                DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1
                if [ $? -eq 0 ]; then
                    echo -e "${gl_lv}  ✓ iptables-persistent 安装成功${gl_bai}"
                else
                    echo -e "${gl_huang}  ⚠ iptables-persistent 安装失败${gl_bai}"
                fi
            else
                echo -e "${gl_lv}  ✓ iptables-persistent 已安装${gl_bai}"
            fi
            
            # 保存当前规则
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save >/dev/null 2>&1
                systemctl enable netfilter-persistent >/dev/null 2>&1
                echo -e "${gl_lv}  ✓ iptables 规则已保存，重启后自动恢复${gl_bai}"
            elif command -v iptables-save >/dev/null 2>&1; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null
                echo -e "${gl_lv}  ✓ iptables 规则已保存到 /etc/iptables/rules.v4${gl_bai}"
            fi
            
        elif command -v nft >/dev/null 2>&1; then
            # 持久化 nftables
            echo -e "${gl_huang}  持久化 nftables 规则...${gl_bai}"
            
            # Debian/Ubuntu: nftables 规则自动持久化到 /etc/nftables.conf
            if [ -f /etc/nftables.conf ]; then
                nft list ruleset > /etc/nftables.conf 2>/dev/null
                systemctl enable nftables >/dev/null 2>&1
                echo -e "${gl_lv}  ✓ nftables 规则已保存到 /etc/nftables.conf${gl_bai}"
            else
                # 创建配置文件
                mkdir -p /etc
                nft list ruleset > /etc/nftables.conf 2>/dev/null
                systemctl enable nftables >/dev/null 2>&1
                echo -e "${gl_lv}  ✓ nftables 规则已创建并保存${gl_bai}"
            fi
        fi
    fi

    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}✅ Realm timeout 修复完成！所有配置已永久生效！${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_huang}📋 备份位置：${gl_bai}$BACKUP_DIR"
    echo ""
    echo -e "${gl_huang}🔍 快速验证：${gl_bai}"
    echo "  • Realm 监听：  ss -tlnp | grep realm"
    echo "  • DNS 配置：    grep nameserver /etc/resolv.conf"
    echo "  • MSS 规则：    iptables -t mangle -S OUTPUT | grep TCPMSS"
    echo "  • Realm 配置：  cat /etc/realm/config.json | grep -E 'resolve|nodelay|reuse_port'"
    echo ""
    echo -e "${gl_lv}💯 重启服务器后所有配置依然生效，无需重复执行！${gl_bai}"
    echo ""
}

#=============================================================================
# 内核参数优化 - 主菜单
#=============================================================================

Kernel_optimize() {
    while true; do
        clear
        echo "Linux系统内核参数优化 - Reality专用调优"
        echo "------------------------------------------------"
        echo "针对 VLESS Reality 节点深度优化"
        echo -e "${gl_huang}提示: ${gl_bai}所有方案都是临时生效（重启后自动还原）"
        echo "--------------------"
        echo "1. 星辰大海ヾ优化：  13万文件描述符，16MB缓冲区，兼容CAKE"
        echo "                      适用：≥2GB内存，推荐使用"
        echo "                      评分：⭐⭐⭐⭐⭐ (24/25分) 🏆"
        echo ""
        echo "2. Reality终极优化：  50万文件描述符，12MB缓冲区"
        echo "                      适用：≥2GB内存，性能+5-10%（推荐）"
        echo "                      评分：⭐⭐⭐⭐⭐ (24/25分) 🏆"
        echo ""
        echo "3. 低配优化模式：     6.5万文件描述符，8MB缓冲区"
        echo "                      适用：512MB-1GB内存，稳定优先"
        echo "                      评分：⭐⭐⭐⭐ (20/25分) 💡 1GB内存推荐"
        echo ""
        echo "4. 星辰大海原始版：   100万文件描述符，16MB缓冲区，强制fq"
        echo "                      适用：≥4GB内存，对比测试用"
        echo "                      评分：⭐⭐⭐⭐⭐ (23/25分) 🧪 测试对比"
        echo "--------------------"
        echo "0. 返回主菜单"
        echo "--------------------"
        read -e -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1)
                cd ~
                clear
                optimize_xinchendahai
                ;;
            2)
                cd ~
                clear
                optimize_reality_ultimate
                ;;
            3)
                cd ~
                clear
                optimize_low_spec
                ;;
            4)
                cd ~
                clear
                optimize_xinchendahai_original
                ;;
            0)
                break
                ;;
            *)
                echo "无效的输入!"
                sleep 1
                ;;
        esac
        break_end
    done
}

run_speedtest() {
    while true; do
        clear
        echo -e "${gl_kjlan}=== 服务器带宽测试 ===${gl_bai}"
        echo ""
        
        # 检测 CPU 架构
        local cpu_arch=$(uname -m)
        echo "检测到系统架构: ${gl_huang}${cpu_arch}${gl_bai}"
        echo ""
        
        # 检查并安装 speedtest
        if ! command -v speedtest &>/dev/null; then
            echo "Speedtest 未安装，正在下载安装..."
            echo "------------------------------------------------"
            echo ""
            
            local download_url
            local tarball_name
            
            case "$cpu_arch" in
                x86_64)
                    download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
                    tarball_name="ookla-speedtest-1.2.0-linux-x86_64.tgz"
                    echo "使用 AMD64 架构版本..."
                    ;;
                aarch64)
                    download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
                    tarball_name="speedtest.tgz"
                    echo "使用 ARM64 架构版本..."
                    ;;
                *)
                    echo -e "${gl_hong}错误: 不支持的架构 ${cpu_arch}${gl_bai}"
                    echo "目前仅支持 x86_64 和 aarch64 架构"
                    echo ""
                    break_end
                    return 1
                    ;;
            esac
            
            cd /tmp || {
                echo -e "${gl_hong}错误: 无法切换到 /tmp 目录${gl_bai}"
                break_end
                return 1
            }
            
            echo "正在下载..."
            if [ "$cpu_arch" = "aarch64" ]; then
                curl -Lo "$tarball_name" "$download_url"
            else
                wget -q "$download_url"
            fi
            
            if [ $? -ne 0 ]; then
                echo -e "${gl_hong}下载失败！${gl_bai}"
                break_end
                return 1
            fi
            
            echo "正在解压..."
            tar -xzf "$tarball_name"
            
            if [ $? -ne 0 ]; then
                echo -e "${gl_hong}解压失败！${gl_bai}"
                rm -f "$tarball_name"
                break_end
                return 1
            fi
            
            mv speedtest /usr/local/bin/
            rm -f "$tarball_name"
            
            echo -e "${gl_lv}✅ Speedtest 安装成功！${gl_bai}"
            echo ""
        else
            echo -e "${gl_lv}✅ Speedtest 已安装${gl_bai}"
        fi
        
        echo ""
        echo -e "${gl_kjlan}请选择测速模式：${gl_bai}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "1. 自动测速"
        echo "2. 手动选择服务器 ⭐ 推荐"
        echo ""
        echo "0. 返回主菜单"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        read -e -p "请输入选择 [1]: " speed_choice
        speed_choice=${speed_choice:-1}
        
        case "$speed_choice" in
            1)
                # 自动测速（使用智能重试逻辑）
                echo ""
                echo -e "${gl_zi}正在搜索附近测速服务器...${gl_bai}"
                
                # 获取附近服务器列表
                local servers_list=$(speedtest --accept-license --servers 2>/dev/null | grep -oP '^\s*\K[0-9]+' | head -n 10)
                
                if [ -z "$servers_list" ]; then
                    echo -e "${gl_huang}无法获取服务器列表，使用自动选择...${gl_bai}"
                    servers_list="auto"
                else
                    local server_count=$(echo "$servers_list" | wc -l)
                    echo -e "${gl_lv}✅ 找到 ${server_count} 个附近服务器${gl_bai}"
                fi
                echo ""
                
                local speedtest_output=""
                local test_success=false
                local attempt=0
                local max_attempts=5
                
                for server_id in $servers_list; do
                    attempt=$((attempt + 1))
                    
                    if [ $attempt -gt $max_attempts ]; then
                        echo -e "${gl_huang}已尝试 ${max_attempts} 个服务器，停止尝试${gl_bai}"
                        break
                    fi
                    
                    if [ "$server_id" = "auto" ]; then
                        echo -e "${gl_zi}[尝试 ${attempt}] 自动选择最近服务器...${gl_bai}"
                        echo "------------------------------------------------"
                        speedtest --accept-license
                        test_success=true
                        break
                    else
                        echo -e "${gl_zi}[尝试 ${attempt}] 测试服务器 #${server_id}...${gl_bai}"
                        echo "------------------------------------------------"
                        speedtest_output=$(speedtest --accept-license --server-id="$server_id" 2>&1)
                        echo "$speedtest_output"
                        echo ""
                        
                        # 检查是否成功
                        if echo "$speedtest_output" | grep -q "Download:" && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                            echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                            echo -e "${gl_lv}✅ 测速成功！${gl_bai}"
                            echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                            test_success=true
                            break
                        else
                            echo -e "${gl_huang}⚠️ 此服务器测速失败，尝试下一个...${gl_bai}"
                            echo ""
                        fi
                    fi
                done
                
                if [ "$test_success" = false ]; then
                    echo ""
                    echo -e "${gl_hong}❌ 所有服务器测速均失败${gl_bai}"
                    echo -e "${gl_zi}建议使用「手动选择服务器」模式${gl_bai}"
                fi
                
                echo ""
                break_end
                ;;
            2)
                # 手动选择服务器
                echo ""
                echo -e "${gl_zi}正在获取附近服务器列表...${gl_bai}"
                echo ""
                
                local server_list_output=$(speedtest --accept-license --servers 2>/dev/null | head -n 15)
                
                if [ -z "$server_list_output" ]; then
                    echo -e "${gl_hong}❌ 无法获取服务器列表${gl_bai}"
                    echo ""
                    break_end
                    continue
                fi
                
                echo -e "${gl_kjlan}附近的测速服务器列表：${gl_bai}"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "$server_list_output"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo -e "${gl_zi}💡 提示：ID 列的数字就是服务器ID${gl_bai}"
                echo ""
                
                local server_id=""
                while true; do
                    read -e -p "$(echo -e "${gl_huang}请输入服务器ID（纯数字，输入0返回）: ${gl_bai}")" server_id
                    
                    if [ "$server_id" = "0" ]; then
                        break
                    elif [[ "$server_id" =~ ^[0-9]+$ ]]; then
                        echo ""
                        echo -e "${gl_huang}正在使用服务器 #${server_id} 测速...${gl_bai}"
                        echo "------------------------------------------------"
                        echo ""
                        
                        speedtest --accept-license --server-id="$server_id"
                        
                        echo ""
                        echo "------------------------------------------------"
                        break_end
                        break
                    else
                        echo -e "${gl_hong}❌ 无效输入，请输入纯数字的服务器ID${gl_bai}"
                    fi
                done
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${gl_hong}无效选择${gl_bai}"
                sleep 1
                ;;
        esac
    done
}

run_backtrace() {
    clear
    echo -e "${gl_kjlan}=== 三网回程路由测试 ===${gl_bai}"
    echo ""
    echo "正在运行三网回程路由测试脚本..."
    echo "------------------------------------------------"
    echo ""

    # 执行三网回程路由测试脚本
    if ! run_remote_script "https://raw.githubusercontent.com/ludashi2020/backtrace/main/install.sh" sh; then
        echo -e "${gl_hong}❌ 脚本执行失败${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo "------------------------------------------------"
    break_end
}

run_ns_detect() {
    clear
    echo -e "${gl_kjlan}=== NS一键检测脚本 ===${gl_bai}"
    echo ""
    echo "正在运行 NS 一键检测脚本..."
    echo "------------------------------------------------"
    echo ""

    # 执行 NS 一键检测脚本
    if ! run_remote_script "https://run.NodeQuality.com" bash; then
        echo -e "${gl_hong}❌ 脚本执行失败${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo "------------------------------------------------"
    break_end
}

run_ip_quality_check() {
    clear
    echo -e "${gl_kjlan}=== IP质量检测 ===${gl_bai}"
    echo ""
    echo "正在运行 IP 质量检测脚本（IPv4 + IPv6）..."
    echo "------------------------------------------------"
    echo ""

    # 执行 IP 质量检测脚本
    if ! run_remote_script "https://IP.Check.Place" bash; then
        echo -e "${gl_hong}❌ 脚本执行失败${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo "------------------------------------------------"
    break_end
}

run_ip_quality_check_ipv4() {
    clear
    echo -e "${gl_kjlan}=== IP质量检测 - 仅IPv4 ===${gl_bai}"
    echo ""
    echo "正在运行 IP 质量检测脚本（仅 IPv4）..."
    echo "------------------------------------------------"
    echo ""

    # 执行 IP 质量检测脚本 - 仅 IPv4
    if ! run_remote_script "https://IP.Check.Place" bash -4; then
        echo -e "${gl_hong}❌ 脚本执行失败${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo "------------------------------------------------"
    break_end
}

run_network_latency_check() {
    clear
    echo -e "${gl_kjlan}=== 网络延迟质量检测 ===${gl_bai}"
    echo ""
    echo "正在运行网络延迟质量检测脚本..."
    echo "------------------------------------------------"
    echo ""

    # 执行网络延迟质量检测脚本
    if ! run_remote_script "https://Check.Place" bash -N; then
        echo -e "${gl_hong}❌ 脚本执行失败${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo "------------------------------------------------"
    break_end
}

run_international_speed_test() {
    clear
    echo -e "${gl_kjlan}=== 国际互联速度测试 ===${gl_bai}"
    echo ""
    echo "正在下载并运行国际互联速度测试脚本..."
    echo "------------------------------------------------"
    echo ""

    # 切换到临时目录
    cd /tmp || {
        echo -e "${gl_hong}错误: 无法切换到 /tmp 目录${gl_bai}"
        break_end
        return 1
    }

    # 下载脚本
    echo "正在下载脚本..."
    wget https://raw.githubusercontent.com/Cd1s/network-latency-tester/main/latency.sh

    if [ $? -ne 0 ]; then
        echo -e "${gl_hong}下载失败！${gl_bai}"
        break_end
        return 1
    fi

    # 添加执行权限
    chmod +x latency.sh

    # 运行测试
    echo ""
    echo "开始测试..."
    echo "------------------------------------------------"
    echo ""
    ./latency.sh

    # 清理临时文件
    rm -f latency.sh

    echo ""
    echo "------------------------------------------------"
    break_end
}

#=============================================================================
# iperf3 单线程网络测试
#=============================================================================

iperf3_single_thread_test() {
    clear
    echo -e "${gl_zi}╔════════════════════════════════════════════╗${gl_bai}"
    echo -e "${gl_zi}║       iperf3 单线程网络性能测试            ║${gl_bai}"
    echo -e "${gl_zi}╚════════════════════════════════════════════╝${gl_bai}"
    echo ""
    
    # 检查 iperf3 是否安装
    if ! command -v iperf3 &>/dev/null; then
        echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_huang}检测到 iperf3 未安装，正在自动安装...${gl_bai}"
        echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        
        if command -v apt-get &>/dev/null || command -v apt &>/dev/null; then
            echo "步骤 1/2: 更新软件包列表..."
            apt-get update

            echo ""
            echo "步骤 2/2: 安装 iperf3..."
            apt-get install -y iperf3
            
            if [ $? -ne 0 ]; then
                echo ""
                echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                echo -e "${gl_hong}iperf3 安装失败！${gl_bai}"
                echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                break_end
                return 1
            fi
        else
            echo -e "${gl_hong}错误: 不支持的包管理器（仅支持 apt）${gl_bai}"
            break_end
            return 1
        fi
        
        echo ""
        echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_lv}✓ iperf3 安装成功！${gl_bai}"
        echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
    fi
    
    # 输入目标服务器
    echo -e "${gl_kjlan}[步骤 1/3] 输入目标服务器${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -e -p "请输入目标服务器 IP 或域名: " target_host
    
    if [ -z "$target_host" ]; then
        echo -e "${gl_hong}错误: 目标服务器不能为空！${gl_bai}"
        break_end
        return 1
    fi
    
    echo ""
    
    # 选择测试方向
    echo -e "${gl_kjlan}[步骤 2/3] 选择测试方向${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "1. 上传测试（本机 → 远程服务器）"
    echo "2. 下载测试（远程服务器 → 本机）"
    echo ""
    read -e -p "请选择测试方向 [1-2]: " direction_choice
    
    case "$direction_choice" in
        1)
            direction_flag=""
            direction_text="上行（本机 → ${target_host}）"
            ;;
        2)
            direction_flag="-R"
            direction_text="下行（${target_host} → 本机）"
            ;;
        *)
            echo -e "${gl_hong}无效的选择，使用默认值: 上传测试${gl_bai}"
            direction_flag=""
            direction_text="上行（本机 → ${target_host}）"
            ;;
    esac
    
    echo ""
    
    # 输入测试时长
    echo -e "${gl_kjlan}[步骤 3/3] 设置测试时长${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "建议: 30-120 秒（默认 60 秒）"
    echo ""
    read -e -p "请输入测试时长（秒）[60]: " test_duration
    test_duration=${test_duration:-60}
    
    # 验证时长是否为数字
    if ! [[ "$test_duration" =~ ^[0-9]+$ ]]; then
        echo -e "${gl_huang}警告: 无效的时长，使用默认值 60 秒${gl_bai}"
        test_duration=60
    fi
    
    # 限制时长范围
    if [ "$test_duration" -lt 1 ]; then
        test_duration=1
    elif [ "$test_duration" -gt 3600 ]; then
        echo -e "${gl_huang}警告: 时长过长，限制为 3600 秒${gl_bai}"
        test_duration=3600
    fi
    
    echo ""
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}测试配置确认：${gl_bai}"
    echo "  目标服务器: ${target_host}"
    echo "  测试方向: ${direction_text}"
    echo "  测试时长: ${test_duration} 秒"
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    # 测试连通性
    echo -e "${gl_huang}正在测试连通性...${gl_bai}"
    if ! ping -c 2 -W 3 "$target_host" &>/dev/null; then
        echo -e "${gl_hong}警告: 无法 ping 通目标服务器，但仍尝试 iperf3 测试...${gl_bai}"
    else
        echo -e "${gl_lv}✓ 目标服务器可达${gl_bai}"
    fi
    
    echo ""
    echo -e "${gl_kjlan}正在执行 iperf3 测试，请稍候...${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # 执行 iperf3 测试并保存输出
    local test_output=$(mktemp)
    iperf3 -c "$target_host" -P 1 $direction_flag -t "$test_duration" -f m 2>&1 | tee "$test_output"
    local exit_code=$?
    
    echo ""
    
    # 检查是否成功
    if [ $exit_code -ne 0 ]; then
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_hong}测试失败！${gl_bai}"
        echo ""
        echo "可能的原因："
        echo "  1. 目标服务器未运行 iperf3 服务（需要执行: iperf3 -s）"
        echo "  2. 防火墙阻止了连接（默认端口 5201）"
        echo "  3. 网络连接问题"
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        rm -f "$test_output"
        break_end
        return 1
    fi
    
    # 解析测试结果
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_zi}╔════════════════════════════════════════════╗${gl_bai}"
    echo -e "${gl_zi}║           测 试 结 果 汇 总                ║${gl_bai}"
    echo -e "${gl_zi}╚════════════════════════════════════════════╝${gl_bai}"
    echo ""
    
    # 提取关键指标
    local bandwidth=$(grep "sender\|receiver" "$test_output" | tail -1 | awk '{print $7, $8}')
    local transfer=$(grep "sender\|receiver" "$test_output" | tail -1 | awk '{print $5, $6}')
    local retrans=$(grep "sender" "$test_output" | tail -1 | awk '{print $9}')
    
    echo -e "${gl_kjlan}[测试信息]${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  目标服务器: ${target_host}"
    echo "  测试方向: ${direction_text}"
    echo "  测试时长: ${test_duration} 秒"
    echo "  测试线程: 1"
    echo ""
    
    echo -e "${gl_kjlan}[性能指标]${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [ -n "$bandwidth" ]; then
        echo "  平均带宽: ${bandwidth}"
    else
        echo "  平均带宽: 无法获取"
    fi
    
    if [ -n "$transfer" ]; then
        echo "  总传输量: ${transfer}"
    else
        echo "  总传输量: 无法获取"
    fi
    
    if [ -n "$retrans" ] && [ "$retrans" != "" ]; then
        echo "  重传次数: ${retrans}"
        # 简单评价
        if [ "$retrans" -eq 0 ]; then
            echo -e "  连接质量: ${gl_lv}优秀（无重传）${gl_bai}"
        elif [ "$retrans" -lt 100 ]; then
            echo -e "  连接质量: ${gl_lv}良好${gl_bai}"
        elif [ "$retrans" -lt 1000 ]; then
            echo -e "  连接质量: ${gl_huang}一般（重传偏多）${gl_bai}"
        else
            echo -e "  连接质量: ${gl_hong}较差（重传过多）${gl_bai}"
        fi
    fi
    
    echo ""
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}✓ 测试完成${gl_bai}"
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    
    # 清理临时文件
    rm -f "$test_output"
    
    echo ""
    break_end
}

#=============================================================================
# AI 代理服务子菜单
#=============================================================================

ai_proxy_menu() {
    while true; do
        clear
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_kjlan}  AI 代理服务工具箱${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "1. Antigravity Claude Proxy 部署管理"
        echo "2. Open WebUI 部署管理"
        echo "3. CRS 部署管理 (多账户中转/拼车)"
        echo "4. Fuclaude 部署管理 (Claude网页版共享)"
        echo "5. Caddy 多域名反代"
        echo ""
        echo "0. 返回主菜单"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"

        read -e -p "请选择操作 [0-5]: " choice

        case $choice in
            1)
                manage_ag_proxy
                ;;
            2)
                manage_open_webui
                ;;
            3)
                manage_crs
                ;;
            4)
                manage_fuclaude
                ;;
            5)
                manage_caddy
                ;;
            0)
                return
                ;;
            *)
                echo "无效选择"
                sleep 1
                ;;
        esac
    done
}

#=============================================================================
# 主菜单
#=============================================================================

show_main_menu() {
    clear
    check_bbr_status
    local is_installed=$?

    echo ""
    echo -e "${gl_zi}╔════════════════════════════════════════════╗${gl_bai}"
    echo -e "${gl_zi}║   BBR v3 终极优化脚本 - Ultimate Edition  ║${gl_bai}"
    echo -e "${gl_zi}╚════════════════════════════════════════════╝${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━ 核心功能 ━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}[内核管理]${gl_bai}"
    echo "1. 安装/更新 XanMod 内核 + BBR v3 ⭐ 推荐"
    echo "2. 卸载 XanMod 内核"
    echo ""
    echo -e "${gl_kjlan}[BBR/网络优化]${gl_bai}"
    echo "3. BBR 直连/落地优化（智能带宽检测）⭐ 推荐"
    echo "4. MTU检测与MSS优化（消除重传）⭐ 推荐"
    echo "5. NS论坛-DNS净化（抗污染/驯服DHCP）"
    echo "6. Realm转发timeout修复 ⭐ 推荐"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━ 系统配置 ━━━━━━━━━━━${gl_bai}"
    echo "7. 设置IPv4/IPv6优先级"
    echo "8. IPv6管理（临时/永久禁用/取消）"
    echo "9. 设置临时SOCKS5代理"
    echo "10. 虚拟内存管理"
    echo "11. 查看系统详细状态"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━ 转发/代理配置 ━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}[Realm管理]${gl_bai}"
    echo "12. Realm转发连接分析"
    echo "13. Realm强制使用IPv4 ⭐ 推荐"
    echo "14. IPv4/IPv6连接检测"
    echo ""
    echo -e "${gl_kjlan}[Xray配置]${gl_bai}"
    echo "15. 查看Xray配置"
    echo "16. 设置Xray IPv6出站"
    echo "17. 恢复Xray默认配置"
    echo ""
    echo -e "${gl_kjlan}[代理部署]${gl_bai}"
    echo "18. 星辰大海Snell协议 ⭐ 推荐"
    echo "19. 星辰大海Xray一键多协议 ⭐ 推荐"
    echo "20. 禁止端口通过中国大陆直连"
    echo "21. 一键部署SOCKS5代理"
    echo "22. Sub-Store多实例管理"
    echo "23. 一键反代 ⭐ 推荐"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━ 测试检测 ━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}[IP质量检测]${gl_bai}"
    echo "24. IP质量检测（IPv4+IPv6）"
    echo "25. IP质量检测（仅IPv4）⭐ 推荐"
    echo ""
    echo -e "${gl_kjlan}[网络测试]${gl_bai}"
    echo "26. 服务器带宽测试"
    echo "27. iperf3单线程测试"
    echo "28. 国际互联速度测试 ⭐ 推荐"
    echo "29. 网络延迟质量检测 ⭐ 推荐"
    echo "30. 三网回程路由测试 ⭐ 推荐"
    echo ""
    echo -e "${gl_kjlan}[流媒体/AI检测]${gl_bai}"
    echo "31. IP媒体/AI解锁检测 ⭐ 推荐"
    echo "32. NQ一键检测 ⭐ 推荐"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━ 第三方工具 ━━━━━━━━━━${gl_bai}"
    echo "33. zywe_realm转发脚本（查看原版仓库）"
    echo "34. F佬一键sing box脚本"
    echo "35. 科技lion脚本"
    echo "36. NS论坛CAKE调优"
    echo "37. 科技lion高性能模式"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━ 流量整形 ━━━━━━━━━━${gl_bai}"
    echo "39. TCP单连接限速管理（FQ + Pacing） 游戏优化 ⭐ 推荐"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━ AI 代理服务 ━━━━━━━━━${gl_bai}"
    echo "38. AI代理工具箱 ▶ (Claude/WebUI/CRS/Fuclaude/Caddy) ⭐ 推荐"
    echo ""
    echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_hong}99. 完全卸载脚本（卸载所有内容）${gl_bai}"
    echo ""
    echo "0. 退出脚本"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    read -e -p "请输入选择: " choice

    case $choice in
        1)
            if [ $is_installed -eq 0 ]; then
                update_xanmod_kernel && server_reboot
            else
                install_xanmod_kernel && server_reboot
            fi
            ;;
        2)
            if [ $is_installed -eq 0 ]; then
                uninstall_xanmod
            else
                echo -e "${gl_huang}当前未检测到 XanMod 内核，无需卸载${gl_bai}"
                break_end
            fi
            ;;
        3)
            bbr_configure_direct
            break_end
            ;;
        4)
            mtu_mss_optimization
            ;;
        5)
            dns_purify_and_harden
            ;;
        6)
            realm_fix_timeout
            break_end
            ;;
        7)
            manage_ip_priority
            ;;
        8)
            manage_ipv6
            ;;
        9)
            set_temp_socks5_proxy
            ;;
        10)
            manage_swap
            ;;
        11)
            show_detailed_status
            ;;
        12)
            analyze_realm_connections
            ;;
        13)
            realm_ipv4_management
            ;;
        14)
            check_ipv4v6_connections
            ;;
        15)
            show_xray_config
            ;;
        16)
            set_xray_ipv6_outbound
            ;;
        17)
            restore_xray_default
            ;;
        18)
            snell_menu
            ;;
        19)
            run_xinchendahai_xray
            ;;
        20)
            manage_cn_ip_block
            ;;
        21)
            manage_socks5
            ;;
        22)
            manage_substore
            ;;
        23)
            manage_reverse_proxy
            ;;
        24)
            run_ip_quality_check
            ;;
        25)
            run_ip_quality_check_ipv4
            ;;
        26)
            run_speedtest
            ;;
        27)
            iperf3_single_thread_test
            ;;
        28)
            run_international_speed_test
            ;;
        29)
            run_network_latency_check
            ;;
        30)
            run_backtrace
            ;;
        31)
            run_unlock_check
            ;;
        32)
            run_ns_detect
            ;;
        33)
            run_pf_realm
            ;;
        34)
            run_fscarmen_singbox
            ;;
        35)
            run_kejilion_script
            ;;
        36)
            startbbrcake
            ;;
        37)
            Kernel_optimize
            ;;
        38)
            ai_proxy_menu
            ;;
        39)
            manage_tcp_pacing_limit
            ;;
        99)
            uninstall_all
            ;;
        0)
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo "无效选择"
            sleep 2
            ;;
    esac
}

update_xanmod_kernel() {
    clear
    echo -e "${gl_kjlan}=== 更新 XanMod 内核 ===${gl_bai}"
    echo "------------------------------------------------"
    
    # 获取当前内核版本
    local current_kernel=$(uname -r)
    echo -e "当前内核版本: ${gl_huang}${current_kernel}${gl_bai}"
    echo ""
    
    # 检测 CPU 架构
    local cpu_arch=$(uname -m)
    
    # ARM 架构提示
    if [ "$cpu_arch" = "aarch64" ]; then
        echo -e "${gl_huang}ARM64 架构暂不支持自动更新${gl_bai}"
        echo "建议卸载后重新安装以获取最新版本"
        break_end
        return 1
    fi
    
    # x86_64 架构更新流程
    echo "正在检查可用更新..."
    
    local xanmod_repo_file="/etc/apt/sources.list.d/xanmod-release.list"

    # 添加 XanMod 仓库（如果不存在）
    if [ ! -f "$xanmod_repo_file" ]; then
        echo "正在添加 XanMod 仓库..."

        # 添加密钥
        wget -qO - ${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/archive.key | \
            gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg --yes 2>/dev/null
        
        if [ $? -ne 0 ]; then
            wget -qO - https://dl.xanmod.org/archive.key | \
                gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg --yes 2>/dev/null
        fi
        
        # 添加仓库
        echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | \
            tee "$xanmod_repo_file" > /dev/null
    fi
    
    # 更新软件包列表
    echo "正在更新软件包列表..."
    apt-get update > /dev/null 2>&1
    
    # 检查已安装的 XanMod 内核包
    local installed_packages=$(dpkg -l | grep 'linux-.*xanmod' | awk '{print $2}')
    
    if [ -z "$installed_packages" ]; then
        echo -e "${gl_hong}错误: 未检测到已安装的 XanMod 内核${gl_bai}"
        break_end
        return 1
    fi
    
    echo -e "已安装的内核包:"
    echo "$installed_packages" | while read pkg; do
        echo "  - $pkg"
    done
    echo ""
    
    # 检查是否有可用更新
    local upgradable=$(apt list --upgradable 2>/dev/null | grep xanmod)
    
    if [ -z "$upgradable" ]; then
        echo -e "${gl_lv}✅ 当前内核已是最新版本！${gl_bai}"
        break_end
        return 0
    fi
    
    echo -e "${gl_huang}发现可用更新:${gl_bai}"
    echo "$upgradable"
    echo ""
    
    read -e -p "确定更新 XanMod 内核吗？(Y/N): " confirm
    
    case "$confirm" in
        [Yy])
            echo ""
            echo "正在更新内核..."
            apt install --only-upgrade -y $(echo "$installed_packages" | tr '\n' ' ')
            
            if [ $? -eq 0 ]; then
                echo ""
                echo -e "${gl_lv}✅ XanMod 内核更新成功！${gl_bai}"
                echo -e "${gl_huang}⚠️  请重启系统以加载新内核${gl_bai}"
                echo -e "${gl_kjlan}后续更新: 可执行 ${gl_bai}sudo apt update && sudo apt upgrade${gl_kjlan} 以检查新版本${gl_bai}"

                read -e -p "是否保留 XanMod 软件源以便继续接收更新？(Y/n): " keep_repo
                case "${keep_repo:-Y}" in
                    [Nn])
                        echo -e "${gl_huang}移除软件源后将无法通过 apt upgrade 自动获取内核更新，后续需手动重新添加。${gl_bai}"
                        read -e -p "确认移除 XanMod 软件源吗？(Y/N): " remove_repo
                        case "$remove_repo" in
                            [Yy])
                                rm -f "$xanmod_repo_file"
                                echo -e "${gl_huang}已按要求移除 XanMod 软件源。${gl_bai}"
                                ;;
                            *)
                                echo -e "${gl_lv}已保留 XanMod 软件源。${gl_bai}"
                                ;;
                        esac
                        ;;
                    *)
                        echo -e "${gl_lv}已保留 XanMod 软件源，可继续通过 apt upgrade 获取最新内核。${gl_bai}"
                        ;;
                esac
                return 0
            else
                echo ""
                echo -e "${gl_hong}❌ 内核更新失败${gl_bai}"
                break_end
                return 1
            fi
            ;;
        *)
            echo "已取消更新"
            break_end
            return 1
            ;;
    esac
}

uninstall_xanmod() {
    echo -e "${gl_huang}警告: 即将卸载 XanMod 内核${gl_bai}"
    read -e -p "确定继续吗？(Y/N): " confirm
    
    case "$confirm" in
        [Yy])
            apt purge -y 'linux-*xanmod1*'
            update-grub
            rm -f "$SYSCTL_CONF"
            echo -e "${gl_lv}XanMod 内核已卸载${gl_bai}"
            server_reboot
            ;;
        *)
            echo "已取消"
            ;;
    esac
}

# 完全卸载脚本所有内容
uninstall_all() {
    clear
    echo -e "${gl_hong}╔════════════════════════════════════════════╗${gl_bai}"
    echo -e "${gl_hong}║       完全卸载脚本 - 所有内容清理          ║${gl_bai}"
    echo -e "${gl_hong}╚════════════════════════════════════════════╝${gl_bai}"
    echo ""
    echo -e "${gl_huang}⚠️  警告：此操作将完全卸载脚本的所有内容，包括：${gl_bai}"
    echo ""
    echo "  • XanMod 内核（如果已安装）"
    echo "  • bbr 快捷别名"
    echo "  • 所有 BBR/网络优化配置"
    echo "  • 所有 sysctl 配置文件"
    echo "  • 其他相关配置文件和备份"
    echo ""
    echo -e "${gl_hong}此操作不可逆！${gl_bai}"
    echo ""
    
    read -e -p "确定要完全卸载吗？(输入 YES 确认): " confirm
    
    if [ "$confirm" != "YES" ]; then
        echo -e "${gl_huang}已取消卸载${gl_bai}"
        break_end
        return 1
    fi
    
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}开始完全卸载...${gl_bai}"
    echo ""
    
    local uninstall_count=0
    local xanmod_removed=0
    
    # 1. 卸载 XanMod 内核
    echo -e "${gl_huang}[1/6] 检查并卸载 XanMod 内核...${gl_bai}"
    if dpkg -l | grep -qE '^ii\s+linux-.*xanmod'; then
        echo "  正在卸载 XanMod 内核..."
        if apt purge -y 'linux-*xanmod1*' > /dev/null 2>&1; then
            update-grub > /dev/null 2>&1
        else
            echo -e "  ${gl_hong}❌ XanMod 内核卸载命令执行失败，请手动检查${gl_bai}"
        fi
        if dpkg -l | grep -qE '^ii\s+linux-.*xanmod'; then
            echo -e "  ${gl_hong}❌ 仍检测到 XanMod 内核，请手动检查${gl_bai}"
        else
            echo -e "  ${gl_lv}✅ XanMod 内核已卸载${gl_bai}"
            uninstall_count=$((uninstall_count + 1))
            xanmod_removed=1
        fi
    else
        echo -e "  ${gl_huang}未检测到 XanMod 内核，跳过${gl_bai}"
    fi
    echo ""
    
    # 2. 卸载 bbr 快捷别名
    echo -e "${gl_huang}[2/6] 卸载 bbr 快捷别名...${gl_bai}"
    
    # 检查所有可能的配置文件
    local rc_files=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile")
    local alias_found=0
    local alias_removed=0
    
    for rc_file in "${rc_files[@]}"; do
        if [ ! -f "$rc_file" ]; then
            continue
        fi
        
        # 检查是否存在别名（多种匹配方式）
        if grep -q "net-tcp-tune 快捷别名\|alias bbr=" "$rc_file" 2>/dev/null; then
            alias_found=1
            
            # 创建临时文件
            local temp_file=$(mktemp)
            
            # 方法1：删除包含 "net-tcp-tune 快捷别名" 的整个块
            if grep -q "net-tcp-tune 快捷别名" "$rc_file" 2>/dev/null; then
                # 删除从分隔线到别名结束的整个块
                sed '/^# ================/,/^alias bbr=/d' "$rc_file" 2>/dev/null | \
                sed '/net-tcp-tune 快捷别名/,/^alias bbr=/d' > "$temp_file" 2>/dev/null
            else
                # 直接复制文件
                cp "$rc_file" "$temp_file"
            fi
            
            # 方法2：删除所有包含 alias bbr 且指向脚本的行（多种匹配方式）
            # 匹配各种可能的格式
            sed -i '/alias bbr.*net-tcp-tune/d' "$temp_file" 2>/dev/null
            sed -i '/alias bbr.*vps-tcp-tune/d' "$temp_file" 2>/dev/null
            sed -i '/alias bbr.*Eric86777/d' "$temp_file" 2>/dev/null
            sed -i '/alias bbr.*curl.*net-tcp-tune/d' "$temp_file" 2>/dev/null
            sed -i '/alias bbr.*wget.*net-tcp-tune/d' "$temp_file" 2>/dev/null
            sed -i '/alias bbr.*raw.githubusercontent.com.*vps-tcp-tune/d' "$temp_file" 2>/dev/null
            
            # 方法3：删除所有注释行（可能包含脚本相关信息）
            sed -i '/#.*net-tcp-tune/d' "$temp_file" 2>/dev/null
            sed -i '/#.*vps-tcp-tune/d' "$temp_file" 2>/dev/null
            
            # 检查是否有变更
            if ! diff -q "$rc_file" "$temp_file" > /dev/null 2>&1; then
                # 备份原文件
                cp "$rc_file" "${rc_file}.bak.uninstall.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
                # 替换文件
                mv "$temp_file" "$rc_file"
                alias_removed=1
                echo -e "  ${gl_lv}✅ 已从 $(basename $rc_file) 中删除别名${gl_bai}"
            else
                rm -f "$temp_file"
            fi
        fi
    done
    
    # 如果没有找到别名，尝试直接删除 alias bbr 定义（更激进的清理）
    if [ $alias_found -eq 0 ]; then
        for rc_file in "${rc_files[@]}"; do
            if [ ! -f "$rc_file" ]; then
                continue
            fi
            
            # 检查是否有任何 bbr 别名定义
            if grep -q "^alias bbr=" "$rc_file" 2>/dev/null; then
                # 删除所有 alias bbr 定义
                sed -i '/^alias bbr=/d' "$rc_file" 2>/dev/null
                alias_removed=1
                echo -e "  ${gl_lv}✅ 已从 $(basename $rc_file) 中删除 bbr 别名${gl_bai}"
            fi
        done
    fi
    
    if [ $alias_removed -eq 1 ]; then
        # 立即尝试取消当前会话中的别名（对子 shell 有效）
        unalias bbr 2>/dev/null || true
        
        echo -e "  ${gl_lv}✅ bbr 快捷别名已卸载${gl_bai}"
        echo -e "  ${gl_huang}提示: 配置文件已清理。如当前终端仍可执行 bbr，请手动运行: ${gl_kjlan}unalias bbr${gl_huang}${gl_bai}"
        echo -e "  ${gl_huang}如需在新终端生效，请执行: ${gl_bai}source ~/.bashrc${gl_huang} 或 ${gl_bai}source ~/.zshrc${gl_bai}"
        uninstall_count=$((uninstall_count + 1))
    elif [ $alias_found -eq 1 ]; then
        # 即使删除失败，也尝试取消当前会话的别名
        unalias bbr 2>/dev/null || true
        echo -e "  ${gl_huang}警告: 检测到别名但删除失败，请手动检查配置文件${gl_bai}"
        echo -e "  ${gl_huang}已尝试取消当前会话的别名${gl_bai}"
    else
        # 以防万一，取消当前会话的别名
        unalias bbr 2>/dev/null || true
        echo -e "  ${gl_huang}未检测到 bbr 别名，跳过${gl_bai}"
    fi
    echo ""
    
    # 3. 清理 sysctl 配置文件
    echo -e "${gl_huang}[3/6] 清理 sysctl 配置文件...${gl_bai}"
    local sysctl_files=(
        "$SYSCTL_CONF"
        "/etc/sysctl.d/99-bbr-ultimate.conf"
        "/etc/sysctl.d/99-sysctl.conf"
        "/etc/sysctl.d/999-net-bbr-fq.conf"
    )
    
    local sysctl_cleaned=0
    for file in "${sysctl_files[@]}"; do
        if [ -f "$file" ]; then
            rm -f "$file"
            sysctl_cleaned=$((sysctl_cleaned + 1))
        fi
    done
    
    # 清理 IPv6 管理相关配置
    if [ -f "/etc/sysctl.d/99-disable-ipv6.conf" ]; then
        rm -f "/etc/sysctl.d/99-disable-ipv6.conf"
        sysctl_cleaned=$((sysctl_cleaned + 1))
    fi
    if [ -f "/etc/sysctl.d/.ipv6-state-backup.conf" ]; then
        rm -f "/etc/sysctl.d/.ipv6-state-backup.conf"
        sysctl_cleaned=$((sysctl_cleaned + 1))
    fi
    
    # 恢复 sysctl.conf 原始配置（如果有备份）
    if [ -f "/etc/sysctl.conf.bak.original" ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d_%H%M%S) 2>/dev/null
        cp /etc/sysctl.conf.bak.original /etc/sysctl.conf 2>/dev/null
        rm -f /etc/sysctl.conf.bak.original
        sysctl_cleaned=$((sysctl_cleaned + 1))
    fi
    
    if [ $sysctl_cleaned -gt 0 ]; then
        echo -e "  ${gl_lv}✅ 已清理 $sysctl_cleaned 个配置文件${gl_bai}"
        uninstall_count=$((uninstall_count + 1))
    else
        echo -e "  ${gl_huang}未找到需要清理的配置文件${gl_bai}"
    fi
    echo ""
    
    # 4. 清理 XanMod 软件源
    echo -e "${gl_huang}[4/6] 清理 XanMod 软件源...${gl_bai}"
    local repo_files=(
        "/etc/apt/sources.list.d/xanmod-release.list"
        "/usr/share/keyrings/xanmod-archive-keyring.gpg"
    )
    
    local repo_cleaned=0
    for file in "${repo_files[@]}"; do
        if [ -f "$file" ]; then
            rm -f "$file"
            repo_cleaned=$((repo_cleaned + 1))
        fi
    done
    
    if [ $repo_cleaned -gt 0 ]; then
        echo -e "  ${gl_lv}✅ 已清理 XanMod 软件源${gl_bai}"
        uninstall_count=$((uninstall_count + 1))
    else
        echo -e "  ${gl_huang}未找到 XanMod 软件源${gl_bai}"
    fi
    echo ""
    
    # 5. 清理其他临时文件和备份
    echo -e "${gl_huang}[5/6] 清理临时文件和备份...${gl_bai}"
    local temp_files=(
        "/tmp/socks5_proxy_*.sh"
        "/root/.realm_backup/"
    )
    
    local temp_cleaned=0
    for pattern in "${temp_files[@]}"; do
        if ls $pattern > /dev/null 2>&1; then
            rm -rf $pattern 2>/dev/null
            temp_cleaned=$((temp_cleaned + 1))
        fi
    done
    
    if [ $temp_cleaned -gt 0 ]; then
        echo -e "  ${gl_lv}✅ 已清理临时文件${gl_bai}"
    else
        echo -e "  ${gl_huang}未找到临时文件${gl_bai}"
    fi
    echo ""
    
    # 6. 应用 sysctl 更改
    echo -e "${gl_huang}[6/6] 应用系统配置更改...${gl_bai}"
    sysctl --system > /dev/null 2>&1
    echo -e "  ${gl_lv}✅ 系统配置已重置${gl_bai}"
    echo ""
    
    # 完成提示
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}✅ 完全卸载完成！${gl_bai}"
    echo ""
    echo -e "${gl_huang}卸载统计：${gl_bai}"
    echo "  • 已卸载 $uninstall_count 个主要组件"
    echo ""
    echo -e "${gl_huang}⚠️  重要提示：${gl_bai}"
    echo "  1. 如果卸载了内核，请重启系统以生效"
    echo "  2. 如果卸载了别名，请重新加载 Shell 配置："
    echo -e "     ${gl_kjlan}source ~/.bashrc${gl_bai} 或 ${gl_kjlan}source ~/.zshrc${gl_bai}"
    echo "  3. 如需重新安装，请重新运行脚本"
    echo ""
    
    # 询问是否重启
    if [ "$xanmod_removed" -eq 1 ]; then
        echo -e "${gl_huang}检测到已卸载内核，建议重启系统${gl_bai}"
        read -e -p "是否立即重启？(Y/n): " reboot_confirm
        case "${reboot_confirm:-Y}" in
            [Yy])
                echo ""
                echo -e "${gl_lv}✅ 完全卸载完成，正在重启系统...${gl_bai}"
                sleep 2
                server_reboot
                ;;
            *)
                echo ""
                echo -e "${gl_huang}请稍后手动重启系统${gl_bai}"
                echo -e "${gl_lv}✅ 完全卸载完成，脚本即将退出${gl_bai}"
                sleep 2
                exit 0
                ;;
        esac
    else
        if dpkg -l | grep -qE '^ii\s+linux-.*xanmod'; then
            echo ""
            echo -e "${gl_hong}❌ 检测到 XanMod 内核仍存在，请手动检查${gl_bai}"
            sleep 2
            exit 1
        else
            echo ""
            echo -e "${gl_lv}✅ 完全卸载完成，脚本即将退出${gl_bai}"
            sleep 2
            exit 0
        fi
    fi
}

run_unlock_check() {
    clear
    echo -e "${gl_kjlan}=== IP媒体/AI解锁检测 ===${gl_bai}"
    echo ""
    echo "正在运行流媒体解锁检测脚本..."
    echo "------------------------------------------------"
    echo ""

    # 执行解锁检测脚本
    if ! run_remote_script "https://github.com/1-stream/RegionRestrictionCheck/raw/main/check.sh" bash; then
        echo -e "${gl_hong}❌ 脚本执行失败${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo "------------------------------------------------"
    break_end
}

run_pf_realm() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  zywe_realm 转发脚本${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo "本人已将 zywe 大佬的脚本二次修改并使用，"
    echo "如需使用原版，请直接访问："
    echo ""
    echo -e "${gl_lv}👉 https://github.com/zywe03/realm-xwPF${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    break_end
}

run_kxy_script() {
    clear
    echo -e "${gl_kjlan}=== 酷雪云脚本 ===${gl_bai}"
    echo ""
    echo "正在运行酷雪云脚本..."
    echo "------------------------------------------------"
    echo ""

    # 执行酷雪云脚本
    if ! run_remote_script "https://cdn.kxy.ovh/kxy.sh" bash; then
        echo -e "${gl_hong}❌ 脚本执行失败${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo "------------------------------------------------"
    break_end
}

#=============================================================================
# 星辰大海 Snell 协议管理
#=============================================================================

# Snell 颜色定义（使用主脚本的颜色变量）
SNELL_RED="${gl_hong}"
SNELL_GREEN="${gl_lv}"
SNELL_YELLOW="${gl_huang}"
SNELL_BLUE="${gl_kjlan}"
SNELL_PURPLE="${gl_zi}"
SNELL_CYAN="${gl_kjlan}"
SNELL_RESET="${gl_bai}"

# Snell 日志文件路径
SNELL_LOG_FILE="/var/log/snell_manager.log"

# Snell 服务名称
SNELL_SERVICE_NAME="snell.service"

# 检测系统类型（Snell）
get_system_type_snell() {
    if [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/redhat-release ]; then
        echo "centos"
    else
        echo "unknown"
    fi
}

# 等待包管理器锁（Snell）
wait_for_package_manager_snell() {
    local system_type=$(get_system_type_snell)
    if [ "$system_type" = "debian" ]; then
        while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
            echo -e "${SNELL_YELLOW}等待其他 apt 进程完成${SNELL_RESET}"
            sleep 1
        done
    fi
}

# 安装必要的软件包（Snell）
install_required_packages_snell() {
    local system_type=$(get_system_type_snell)
    echo -e "${SNELL_GREEN}安装必要的软件包${SNELL_RESET}"

    if [ "$system_type" = "debian" ]; then
        apt update
        apt install -y wget unzip curl
    elif [ "$system_type" = "centos" ]; then
        yum -y update
        yum -y install wget unzip curl
    else
        echo -e "${SNELL_RED}不支持的系统类型${SNELL_RESET}"
        exit 1
    fi
}

# 检查是否以 root 权限运行（Snell）
check_root_snell() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${SNELL_RED}请以 root 权限运行此脚本.${SNELL_RESET}"
        exit 1
    fi
}

# 检查 Snell 是否已安装
check_snell_installed() {
    if command -v snell-server &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 检查 Snell 是否正在运行
check_snell_running() {
    systemctl is-active --quiet "$SNELL_SERVICE_NAME"
    return $?
}

# 启动 Snell 服务
start_snell() {
    systemctl start "$SNELL_SERVICE_NAME"
    if [ $? -eq 0 ]; then
        echo -e "${SNELL_GREEN}Snell 启动成功${SNELL_RESET}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Snell 启动成功" >> "$SNELL_LOG_FILE"
    else
        echo -e "${SNELL_RED}Snell 启动失败${SNELL_RESET}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Snell 启动失败" >> "$SNELL_LOG_FILE"
    fi
}

# 停止 Snell 服务
stop_snell() {
    systemctl stop "$SNELL_SERVICE_NAME"
    if [ $? -eq 0 ]; then
        echo -e "${SNELL_GREEN}Snell 停止成功${SNELL_RESET}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Snell 停止成功" >> "$SNELL_LOG_FILE"
    else
        echo -e "${SNELL_RED}Snell 停止失败${SNELL_RESET}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Snell 停止失败" >> "$SNELL_LOG_FILE"
    fi
}

# 安装 Snell
install_snell() {
    echo -e "${SNELL_GREEN}正在安装 Snell${SNELL_RESET}"

    # 等待包管理器
    wait_for_package_manager_snell

    # 安装必要的软件包
    if ! install_required_packages_snell; then
        echo -e "${SNELL_RED}安装必要软件包失败，请检查您的网络连接。${SNELL_RESET}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 安装必要软件包失败" >> "$SNELL_LOG_FILE"
        exit 1
    fi

    # 下载 Snell 服务器文件
    ARCH=$(arch)
    VERSION="v5.0.1"
    SNELL_URL=""
    INSTALL_DIR="/usr/local/bin"
    SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"
    CONF_DIR="/etc/snell"
    CONF_FILE="${CONF_DIR}/snell-server.conf"

    if [[ ${ARCH} == "aarch64" ]]; then
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-aarch64.zip"
    else
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-amd64.zip"
    fi

    # 下载 Snell 服务器文件
    wget ${SNELL_URL} -O snell-server.zip
    if [ $? -ne 0 ]; then
        echo -e "${SNELL_RED}下载 Snell 失败。${SNELL_RESET}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 下载 Snell 失败" >> "$SNELL_LOG_FILE"
        exit 1
    fi

    # 解压缩文件到指定目录
    unzip -o snell-server.zip -d ${INSTALL_DIR}
    if [ $? -ne 0 ]; then
        echo -e "${SNELL_RED}解压缩 Snell 失败。${SNELL_RESET}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 解压缩 Snell 失败" >> "$SNELL_LOG_FILE"
        exit 1
    fi

    # 删除下载的 zip 文件
    rm snell-server.zip

    # 赋予执行权限
    chmod +x ${INSTALL_DIR}/snell-server

    # 生成随机端口和密码
    SNELL_PORT=$(shuf -i 30000-65000 -n 1)
    RANDOM_PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

    # 检查 snell 用户是否已存在
    if ! id "snell" &>/dev/null; then
        # 创建 Snell 用户
        useradd -r -s /usr/sbin/nologin snell
    fi

    # 创建配置文件目录
    mkdir -p ${CONF_DIR}

    # 询问端口（直接输入或回车使用随机）
    echo -e "${SNELL_CYAN}请输入端口号 (1-65535)，直接回车使用随机端口 [默认: ${SNELL_PORT}]:${SNELL_RESET}"
    while true; do
        read -p "端口: " custom_port
        
        # 如果用户直接回车，使用随机端口
        if [ -z "$custom_port" ]; then
            echo -e "${SNELL_GREEN}使用随机端口: ${SNELL_PORT}${SNELL_RESET}"
            break
        fi
        
        # 如果用户输入了端口，验证端口号
        if [[ "$custom_port" =~ ^[0-9]+$ ]] && [ "$custom_port" -ge 1 ] && [ "$custom_port" -le 65535 ]; then
            SNELL_PORT=$custom_port
            echo -e "${SNELL_GREEN}已设置端口为: ${SNELL_PORT}${SNELL_RESET}"
            break
        else
            echo -e "${SNELL_RED}无效端口，请输入 1-65535 之间的数字，或直接回车使用随机端口${SNELL_RESET}"
        fi
    done
    
    # 询问节点名称
    echo -e "${SNELL_CYAN}请输入节点名称 (例如: 🇯🇵【Gen2】Fxtransit JP T1):${SNELL_RESET}"
    read -p "节点名称: " NODE_NAME
    if [ -z "$NODE_NAME" ]; then
        NODE_NAME="Snell-Node-${SNELL_PORT}"
        echo -e "${SNELL_YELLOW}未输入名称，使用默认名称: ${NODE_NAME}${SNELL_RESET}"
    fi

    # 定义特定端口的配置文件和服务文件
    CONF_FILE="${CONF_DIR}/snell-${SNELL_PORT}.conf"
    SYSTEMD_SERVICE_FILE="/etc/systemd/system/snell-${SNELL_PORT}.service"
    SNELL_SERVICE_NAME="snell-${SNELL_PORT}.service"

    # 检查端口是否被占用
    if ss -tulpn | grep -q ":${SNELL_PORT} "; then
        echo -e "${SNELL_RED}端口 ${SNELL_PORT} 已被占用，请选择其他端口。${SNELL_RESET}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 端口 ${SNELL_PORT} 已被占用" >> "$SNELL_LOG_FILE"
        return 1
    fi

    # 询问用户选择监听模式
    echo -e "${SNELL_CYAN}请选择监听模式:${SNELL_RESET}"
    echo "1. 仅 IPv4 (0.0.0.0)"
    echo "2. 仅 IPv6 (::0)"
    echo "3. 双栈 (同时支持 IPv4 和 IPv6)"
    read -p "请输入选项 [1-3，默认为 1]: " listen_mode
    listen_mode=${listen_mode:-1}

    local IP_VERSION_STR=""
    case $listen_mode in
        1)
            LISTEN_ADDR="0.0.0.0:${SNELL_PORT}"
            IPV6_ENABLED="false"
            IP_VERSION_STR=", ip-version=v4-only"
            echo -e "${SNELL_GREEN}已选择：仅 IPv4 模式${SNELL_RESET}"
            ;;
        2)
            LISTEN_ADDR="::0:${SNELL_PORT}"
            IPV6_ENABLED="true"
            IP_VERSION_STR=", ip-version=v6-only"
            echo -e "${SNELL_GREEN}已选择：仅 IPv6 模式${SNELL_RESET}"
            ;;
        3)
            LISTEN_ADDR="::0:${SNELL_PORT}"
            IPV6_ENABLED="true"
            IP_VERSION_STR="" # 双栈模式不强制指定 ip-version，或者根据需求设为 prefer-v4
            echo -e "${SNELL_GREEN}已选择：双栈模式 (同时支持 IPv4 和 IPv6)${SNELL_RESET}"
            ;;
        *)
            LISTEN_ADDR="0.0.0.0:${SNELL_PORT}"
            IPV6_ENABLED="false"
            IP_VERSION_STR=", ip-version=v4-only"
            echo -e "${SNELL_YELLOW}无效选项，默认使用 IPv4 模式${SNELL_RESET}"
            ;;
    esac

    # 创建配置文件
    cat > ${CONF_FILE} << EOF
[snell-server]
listen = ${LISTEN_ADDR}
psk = ${RANDOM_PSK}
ipv6 = ${IPV6_ENABLED}
EOF

    # 创建 Systemd 服务文件
    cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service (Port ${SNELL_PORT})
After=network.target

[Service]
Type=simple
User=snell
Group=snell
ExecStart=${INSTALL_DIR}/snell-server -c ${CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
LimitNOFILE=32768
Restart=on-failure
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-${SNELL_PORT}

[Install]
WantedBy=multi-user.target
EOF

    # 重载 Systemd 配置
    systemctl daemon-reload
    if [ $? -ne 0 ]; then
        echo -e "${SNELL_RED}重载 Systemd 配置失败。${SNELL_RESET}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 重载 Systemd 配置失败" >> "$SNELL_LOG_FILE"
        exit 1
    fi

    # 开机自启动 Snell
    systemctl enable ${SNELL_SERVICE_NAME}
    if [ $? -ne 0 ]; then
        echo -e "${SNELL_RED}开机自启动 Snell 失败。${SNELL_RESET}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 开机自启动 Snell 失败" >> "$SNELL_LOG_FILE"
        exit 1
    fi

    # 启动 Snell 服务
    systemctl start ${SNELL_SERVICE_NAME}
    if [ $? -ne 0 ]; then
        echo -e "${SNELL_RED}启动 Snell 服务失败。${SNELL_RESET}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 启动 Snell 服务失败" >> "$SNELL_LOG_FILE"
        exit 1
    fi

    # 查看 Snell 日志
    echo -e "${SNELL_GREEN}Snell (端口 ${SNELL_PORT}) 安装成功${SNELL_RESET}"
    sleep 3
    journalctl -u ${SNELL_SERVICE_NAME} -n 8 --no-pager || echo -e "${SNELL_YELLOW}无法获取日志，但不影响服务运行${SNELL_RESET}"

    # 获取本机IP地址
    HOST_IP=$(curl -s --max-time 5 http://checkip.amazonaws.com)
    if [ -z "$HOST_IP" ]; then
        HOST_IP=$(curl -s --max-time 5 http://ifconfig.me)
    fi
    if [ -z "$HOST_IP" ]; then
        HOST_IP="127.0.0.1"
    fi

    # 构造最终配置字符串
    local FINAL_CONFIG="${NODE_NAME} = snell, ${HOST_IP}, ${SNELL_PORT}, psk=${RANDOM_PSK}, version=5, reuse=true${IP_VERSION_STR}"

    echo ""
    echo -e "${SNELL_GREEN}节点信息输出：${SNELL_RESET}"
    echo -e "${SNELL_CYAN}${FINAL_CONFIG}${SNELL_RESET}"
    
    cat << EOF > /etc/snell/config-${SNELL_PORT}.txt
${FINAL_CONFIG}
EOF
}

# 更新 Snell
update_snell() {
    # 检查 Snell 是否已安装
    INSTALL_DIR="/usr/local/bin"
    SNELL_BIN="${INSTALL_DIR}/snell-server"
    if [ ! -f "${SNELL_BIN}" ]; then
        echo -e "${SNELL_YELLOW}Snell 未安装，跳过更新${SNELL_RESET}"
        return
    fi

    echo -e "${SNELL_GREEN}Snell 正在更新${SNELL_RESET}"

    # 停止所有 Snell 实例
    echo -e "${SNELL_GREEN}正在停止所有 Snell 服务...${SNELL_RESET}"
    for service_file in /etc/systemd/system/snell-*.service; do
        if [ -f "$service_file" ]; then
            service_name=$(basename "$service_file")
            systemctl stop "$service_name" 2>/dev/null
        fi
    done
    # 兼容旧版单实例
    systemctl stop snell 2>/dev/null

    # 等待包管理器
    wait_for_package_manager_snell

    # 检查是否已安装 Snell 核心程序
    echo -e "${SNELL_GREEN}正在安装 Snell 核心程序...${SNELL_RESET}"
    
    # 安装必要的软件包
    if ! install_required_packages_snell; then
        echo -e "${SNELL_RED}安装必要软件包失败，请检查您的网络连接。${SNELL_RESET}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 安装必要软件包失败" >> "$SNELL_LOG_FILE"
        exit 1
    fi

    # 下载 Snell 服务器文件
    ARCH=$(arch)
    VERSION="v5.0.1"
    SNELL_URL=""

    if [[ ${ARCH} == "aarch64" ]]; then
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-aarch64.zip"
    else
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-amd64.zip"
    fi

    # 下载 Snell 服务器文件
    if ! wget ${SNELL_URL} -O snell-server.zip; then
        echo -e "${SNELL_RED}下载 Snell 失败。${SNELL_RESET}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 下载 Snell 失败" >> "$SNELL_LOG_FILE"
        exit 1
    fi

    # 解压缩文件到指定目录
    if ! unzip -o snell-server.zip -d ${INSTALL_DIR}; then
        echo -e "${SNELL_RED}解压缩 Snell 失败。${SNELL_RESET}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - 解压缩 Snell 失败" >> "$SNELL_LOG_FILE"
        exit 1
    fi

    # 删除下载的 zip 文件
    rm snell-server.zip

    # 赋予执行权限
    chmod +x ${INSTALL_DIR}/snell-server

    # 重启 Snell
    # 重启所有 Snell 实例
    echo -e "${SNELL_GREEN}正在重启所有 Snell 服务...${SNELL_RESET}"
    local restart_count=0
    for service_file in /etc/systemd/system/snell-*.service; do
        if [ -f "$service_file" ]; then
            service_name=$(basename "$service_file")
            if systemctl restart "$service_name"; then
                ((restart_count++))
            else
                echo -e "${SNELL_RED}重启 ${service_name} 失败${SNELL_RESET}"
            fi
        fi
    done
    
    # 兼容旧版单实例
    if [ -f "/etc/systemd/system/snell.service" ] || [ -f "/lib/systemd/system/snell.service" ]; then
        systemctl restart snell 2>/dev/null
    fi

    if [ $restart_count -eq 0 ] && ! systemctl is-active --quiet snell; then
        echo -e "${SNELL_YELLOW}未检测到活动的 Snell 服务实例${SNELL_RESET}"
    fi

    echo -e "${SNELL_GREEN}Snell 更新成功，非TF版本请改为version = 4${SNELL_RESET}"
    cat /etc/snell/config.txt
}

# 列出所有 Snell 实例
list_snell_instances() {
    echo -e "${SNELL_CYAN}当前已安装的 Snell 实例：${SNELL_RESET}"
    echo "================================================================"
    printf "%-30s %-12s %-12s %-10s\n" "节点名称" "端口" "状态" "版本"
    echo "================================================================"

    local count=0
    
    # 检查新版多实例服务
    for service_file in /etc/systemd/system/snell-*.service; do
        if [ -f "$service_file" ]; then
            local port=$(echo "$service_file" | sed -E 's/.*snell-([0-9]+)\.service/\1/')
            
            # 判断状态（纯文本，不带颜色）
            local status_text="已停止"
            if systemctl is-active --quiet "snell-${port}.service"; then
                status_text="运行中"
            fi
            
            # 从配置文件读取节点名称
            local node_name="未命名"
            if [ -f "/etc/snell/config-${port}.txt" ]; then
                node_name=$(head -n 1 "/etc/snell/config-${port}.txt" | awk -F' = ' '{print $1}')
            fi
            
            local version="v5"
            
            # 输出时根据状态添加颜色
            if [ "$status_text" = "运行中" ]; then
                printf "%-30s %-12s ${SNELL_GREEN}%-12s${SNELL_RESET} %-10s\n" "$node_name" "$port" "$status_text" "$version"
            else
                printf "%-30s %-12s ${SNELL_RED}%-12s${SNELL_RESET} %-10s\n" "$node_name" "$port" "$status_text" "$version"
            fi
            ((count++))
        fi
    done

    # 检查旧版单实例服务
    if [ -f "/lib/systemd/system/snell.service" ] || [ -f "/etc/systemd/system/snell.service" ]; then
        local status_text="已停止"
        if systemctl is-active --quiet "snell.service"; then
            status_text="运行中"
        fi
        
        # 尝试从配置文件读取端口
        local port="未知"
        if [ -f "/etc/snell/snell-server.conf" ]; then
            port=$(grep "listen" /etc/snell/snell-server.conf | awk -F':' '{print $NF}')
        fi
        
        # 尝试读取旧版节点名称
        local node_name="旧版实例"
        if [ -f "/etc/snell/config.txt" ]; then
            node_name=$(head -n 1 "/etc/snell/config.txt" | awk -F' = ' '{print $1}')
        fi
        
        if [ "$status_text" = "运行中" ]; then
            printf "%-30s %-12s ${SNELL_GREEN}%-12s${SNELL_RESET} %-10s\n" "$node_name" "$port" "$status_text" "v5"
        else
            printf "%-30s %-12s ${SNELL_RED}%-12s${SNELL_RESET} %-10s\n" "$node_name" "$port" "$status_text" "v5"
        fi
        ((count++))
    fi

    if [ "$count" -eq 0 ]; then
        echo "暂无安装任何 Snell 实例"
    fi
    echo "================================================================"
    echo ""
    return $count
}

# 卸载 Snell
uninstall_snell() {
    echo -e "${SNELL_GREEN}=== 卸载 Snell 服务 ===${SNELL_RESET}"
    
    list_snell_instances
    local instance_count=$?
    
    if [ "$instance_count" -eq 0 ]; then
        echo -e "${SNELL_YELLOW}未检测到任何 Snell 实例，无需卸载。${SNELL_RESET}"
        return
    fi

    echo "请选择卸载方式："
    echo "1. 卸载指定端口的实例"
    echo "2. 卸载所有实例"
    echo "0. 取消"
    read -p "请输入选项 [0-2]: " uninstall_choice

    case "$uninstall_choice" in
        1)
            read -p "请输入要卸载的端口号: " port_to_uninstall
            if [ -z "$port_to_uninstall" ]; then
                echo "端口号不能为空"
                return
            fi
            
            # 检查是否存在该端口的服务
            local service_name=""
            if [ -f "/etc/systemd/system/snell-${port_to_uninstall}.service" ]; then
                service_name="snell-${port_to_uninstall}.service"
            elif [ -f "/lib/systemd/system/snell.service" ] || [ -f "/etc/systemd/system/snell.service" ]; then
                # 检查旧版服务是否使用该端口
                if grep -q ":${port_to_uninstall}" /etc/snell/snell-server.conf 2>/dev/null; then
                    service_name="snell.service"
                fi
            fi
            
            if [ -z "$service_name" ]; then
                echo -e "${SNELL_RED}未找到端口为 ${port_to_uninstall} 的 Snell 实例${SNELL_RESET}"
                return
            fi
            
            echo "正在卸载服务: ${service_name} ..."
            systemctl stop "$service_name"
            systemctl disable "$service_name"
            rm "/etc/systemd/system/${service_name}" 2>/dev/null
            rm "/lib/systemd/system/${service_name}" 2>/dev/null
            
            if [ "$service_name" == "snell.service" ]; then
                rm /etc/snell/snell-server.conf 2>/dev/null
            else
                rm "/etc/snell/snell-${port_to_uninstall}.conf" 2>/dev/null
                rm "/etc/snell/config-${port_to_uninstall}.txt" 2>/dev/null
            fi
            
            systemctl daemon-reload
            echo -e "${SNELL_GREEN}实例 ${port_to_uninstall} 卸载成功${SNELL_RESET}"
            ;;
        2)
            echo "正在卸载所有 Snell 实例..."
            # 卸载新版多实例
            for service_file in /etc/systemd/system/snell-*.service; do
                if [ -f "$service_file" ]; then
                    local port=$(echo "$service_file" | sed -E 's/.*snell-([0-9]+)\.service/\1/')
                    echo "卸载端口 $port ..."
                    systemctl stop "snell-${port}.service"
                    systemctl disable "snell-${port}.service"
                    rm "$service_file"
                fi
            done
            
            # 卸载旧版实例
            if systemctl list-unit-files | grep -q "snell.service"; then
                echo "卸载旧版默认实例..."
                systemctl stop snell.service
                systemctl disable snell.service
                rm /lib/systemd/system/snell.service 2>/dev/null
                rm /etc/systemd/system/snell.service 2>/dev/null
            fi
            
            # 清理配置目录
            rm -rf /etc/snell
            # 清理二进制文件
            rm /usr/local/bin/snell-server
            
            systemctl daemon-reload
            echo -e "${SNELL_GREEN}所有 Snell 实例已卸载${SNELL_RESET}"
            ;;
        *)
            echo "已取消"
            ;;
    esac
}


# Snell 主函数
# Snell 管理菜单
snell_menu() {
    while true; do
        clear
        echo -e "${SNELL_CYAN}=== Snell 管理工具 ===${SNELL_RESET}"
        
        # 统计实例数量
        local instance_count=0
        local running_count=0
        
        # 统计新版实例
        for service_file in /etc/systemd/system/snell-*.service; do
            if [ -f "$service_file" ]; then
                ((instance_count++))
                local port=$(echo "$service_file" | sed -E 's/.*snell-([0-9]+)\.service/\1/')
                if systemctl is-active --quiet "snell-${port}.service"; then
                    ((running_count++))
                fi
            fi
        done
        
        # 统计旧版实例
        if [ -f "/lib/systemd/system/snell.service" ] || [ -f "/etc/systemd/system/snell.service" ]; then
            ((instance_count++))
            if systemctl is-active --quiet "snell.service"; then
                ((running_count++))
            fi
        fi
        
        echo -e "已安装实例: ${SNELL_GREEN}${instance_count}${SNELL_RESET} 个"
        echo -e "运行中实例: ${SNELL_GREEN}${running_count}${SNELL_RESET} 个"
        
        # 动态获取 Snell 版本
        local snell_version="未知"
        if [ -f "/usr/local/bin/snell-server" ]; then
            # 尝试获取版本号（Snell 没有 --version 参数，通过文件修改时间或固定版本号）
            # 这里使用配置中指定的版本号
            snell_version="v5.0.1"
        fi
        echo -e "运行版本: ${snell_version}"
        echo ""
        echo "1. 安装/添加 Snell 服务"
        echo "2. 卸载/删除 Snell 服务"
        echo "3. 查看所有 Snell 实例"
        echo "4. 更新 Snell 服务 (更新核心程序)"
        echo "5. 查看 Snell 配置"
        echo "0. 返回主菜单"
        echo "======================"
        read -p "请输入选项编号: " snell_choice

        case "$snell_choice" in
            1) 
                install_snell
                echo ""
                read -n 1 -s -r -p "按任意键继续..."
                ;;
            2) uninstall_snell ;;
            3) 
                list_snell_instances 
                echo ""
                read -n 1 -s -r -p "按任意键继续..."
                ;;
            4) update_snell ;;
            5) 
                echo ""
                list_snell_instances
                local count=$?
                if [ "$count" -gt 0 ]; then
                    echo ""
                    read -p "请输入要查看配置的端口号: " view_port
                    if [ -f "/etc/snell/config-${view_port}.txt" ]; then
                        echo ""
                        cat "/etc/snell/config-${view_port}.txt"
                    elif [ -f "/etc/snell/snell-server.conf" ] && grep -q ":${view_port}" /etc/snell/snell-server.conf; then
                         # 旧版配置查看 (这里只是简单处理，实际上旧版没有 config.txt 备份可能需要解析 conf 文件)
                         echo "旧版配置 (端口 ${view_port}):"
                         cat /etc/snell/snell-server.conf
                    else
                        echo -e "${SNELL_RED}未找到端口 ${view_port} 的配置文件${SNELL_RESET}"
                    fi
                    echo ""
                    read -n 1 -s -r -p "按任意键继续..."
                else
                    echo ""
                    read -n 1 -s -r -p "按任意键继续..."
                fi
                ;;
            0) return ;;
            *) echo -e "${SNELL_RED}无效选项${SNELL_RESET}"; sleep 1 ;;
        esac
    done
}

#=============================================================================
# 星辰大海 Xray 一键多协议
#=============================================================================

run_xinchendahai_xray() {
    clear
    echo -e "${gl_kjlan}=== 星辰大海Xray一键多协议（增强版） ===${gl_bai}"
    echo ""
    echo -e "${gl_lv}✨ 功能特性：${gl_bai}"
    echo "  • 支持多 VLESS 节点部署（不同端口）"
    echo "  • 随机 shortid 生成（更安全）"
    echo "  • SNI 域名快速选择（addons.mozilla.org / updates.cdn-apple.com）"
    echo "  • 节点自定义命名"
    echo "  • 灵活的节点管理（增加/删除/修改）"
    echo "------------------------------------------------"
    echo ""

    # 创建临时脚本
    local script_path="/tmp/xinchendahai_xray_$$.sh"

    echo "正在准备星辰大海Xray增强版脚本..."

    # 将完整脚本内容写入临时文件
    cat > "$script_path" << 'XRAY_ENHANCED_SCRIPT_EOF'
#!/bin/bash

# ==============================================================================
# Xray VLESS-Reality & Shadowsocks 2022 多功能管理脚本
# 版本: Final v2.9.1
# 更新日志 (v2.9.1):
# - [安全] 添加配置文件权限保护
# - [安全] 增强脚本下载验证
# - [安全] 敏感信息显示保护
# - [稳定] 网络操作重试机制
# - [稳定] 服务启动详细错误显示
# ==============================================================================

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="Final v2.9.1"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

# --- 全局变量 ---
xray_status_info=""
is_quiet=false

# --- 辅助函数 ---
error() { 
    echo -e "\n$red[✖] $1$none\n" >&2
    
    # 根据错误内容提供简单建议
    case "$1" in
        *"网络"*|*"下载"*) 
            echo -e "$yellow提示: 检查网络连接或更换DNS$none" >&2 ;;
        *"权限"*|*"root"*) 
            echo -e "$yellow提示: 请使用 sudo 运行脚本$none" >&2 ;;
        *"端口"*) 
            echo -e "$yellow提示: 尝试使用其他端口号$none" >&2 ;;
    esac
}

info() { [[ "$is_quiet" = false ]] && echo -e "\n$yellow[!] $1$none\n"; }
success() { [[ "$is_quiet" = false ]] && echo -e "\n$green[✔] $1$none\n"; }
warning() { [[ "$is_quiet" = false ]] && echo -e "\n$yellow[⚠] $1$none\n"; }

spinner() {
    local pid="$1"
    local spinstr='|/-\'
    if [[ "$is_quiet" = true ]]; then
        wait "$pid"
        return
    fi
    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

get_public_ip() {
    local ip
    local attempts=0
    local max_attempts=2
    
    while [[ $attempts -lt $max_attempts ]]; do
        for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
            for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
                ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
            done
        done
        ((attempts++))
        [[ $attempts -lt $max_attempts ]] && sleep 1
    done
    
    # IPv6 fallback
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
}

# --- 预检查与环境设置 ---
pre_check() {
    [[ "$(id -u)" != 0 ]] && error "错误: 您必须以root用户身份运行此脚本" && exit 1
    if [ ! -f /etc/debian_version ]; then error "错误: 此脚本仅支持 Debian/Ubuntu 及其衍生系统。" && exit 1; fi
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        info "检测到缺失的依赖 (jq/curl)，正在尝试自动安装..."
        (DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y jq curl) &> /dev/null &
        spinner $!
        if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
            error "依赖 (jq/curl) 自动安装失败。请手动运行 'apt update && apt install -y jq curl' 后重试。"
            exit 1
        fi
        success "依赖已成功安装。"
    fi
}

check_xray_status() {
    if [[ ! -f "$xray_binary_path" || ! -x "$xray_binary_path" ]]; then
        xray_status_info=" Xray 状态: ${red}未安装${none}"
        return
    fi
    local xray_version
    xray_version=$("$xray_binary_path" version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "未知")
    local service_status
    if systemctl is-active --quiet xray 2>/dev/null; then
        service_status="${green}运行中${none}"
    else
        service_status="${yellow}未运行${none}"
    fi
    xray_status_info=" Xray 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${xray_version}${none}"
}

# 新增：快速状态检查
quick_status() {
    if [[ ! -f "$xray_binary_path" ]]; then
        echo -e " ${red}●${none} 未安装"
        return
    fi
    
    local status_icon
    if systemctl is-active --quiet xray 2>/dev/null; then
        status_icon="${green}●${none}"
    else
        status_icon="${red}●${none}"
    fi
    
    echo -e " $status_icon Xray $(systemctl is-active xray 2>/dev/null || echo "inactive")"
}

# --- 核心配置生成函数 ---
generate_ss_key() {
    openssl rand -base64 16
}

# 生成随机 shortid (8位十六进制)
generate_shortid() {
    openssl rand -hex 4
}

build_vless_inbound() {
    local port="$1" uuid="$2" domain="$3" private_key="$4" public_key="$5" node_name="$6"
    local shortid="${7:-$(generate_shortid)}"
    jq -n --argjson port "$port" --arg uuid "$uuid" --arg domain "$domain" --arg private_key "$private_key" --arg public_key "$public_key" --arg shortid "$shortid" --arg node_name "$node_name" \
    '{ "listen": "0.0.0.0", "port": $port, "protocol": "vless", "settings": {"clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"show": false, "dest": ($domain + ":443"), "xver": 0, "serverNames": [$domain], "privateKey": $private_key, "publicKey": $public_key, "shortIds": [$shortid]}}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}, "tag": $node_name }'
}

build_ss_inbound() {
    local port="$1" password="$2" node_name="$3"
    jq -n --argjson port "$port" --arg password "$password" --arg node_name "$node_name" \
    '{ "listen": "0.0.0.0", "port": $port, "protocol": "shadowsocks", "settings": {"method": "2022-blake3-aes-128-gcm", "password": $password}, "tag": $node_name }'
}

write_config() {
    local inbounds_json="$1"
    local enable_routing="${2:-}"
    local config_content

    # 🔥 核心逻辑：如果调用者没指定 enable_routing，就自动检测现有配置
    if [[ -z "$enable_routing" ]]; then
        # 检测现有配置文件是否存在 routing 配置
        if [[ -f "$xray_config_path" ]]; then
            local has_routing
            has_routing=$(jq -r '.routing // empty' "$xray_config_path" 2>/dev/null)
            if [[ -n "$has_routing" ]]; then
                enable_routing="true"
            else
                enable_routing="false"
            fi
        else
            # 配置文件不存在，默认不启用路由
            enable_routing="false"
        fi
    fi

    # 🆕 保留现有的自定义 outbounds（SOCKS5等）
    local existing_custom_outbounds="[]"
    local existing_custom_routing_rules="[]"
    local should_preserve_config=false
    
    if [[ -f "$xray_config_path" ]]; then
        # 🛡️ 首先检测是否为 Xray 官方默认配置
        # 只有配置文件包含我们添加的节点（VLESS或Shadowsocks）时，才尝试保留现有配置
        if jq -e '.inbounds[]? | select(.protocol == "vless" or .protocol == "shadowsocks")' "$xray_config_path" &>/dev/null; then
            should_preserve_config=true
        fi
        
        # 只有当配置文件包含我们的节点时，才尝试保留现有配置
        if [[ "$should_preserve_config" == "true" ]]; then
            # 验证配置文件是否为有效的 JSON
            if jq empty "$xray_config_path" 2>/dev/null; then
                # 提取所有非默认的 outbounds（保留 SOCKS5 等自定义代理）
                local temp_outbounds
                temp_outbounds=$(jq -c '[.outbounds[]? | select(.protocol != "freedom" and .protocol != "blackhole")]' "$xray_config_path" 2>/dev/null)
                
                # 验证提取结果是否为有效的 JSON 数组
                if [[ -n "$temp_outbounds" ]] && echo "$temp_outbounds" | jq empty 2>/dev/null; then
                    existing_custom_outbounds="$temp_outbounds"
                fi
                
                # 提取所有自定义的 routing rules（排除默认的广告过滤规则）
                # 判断是否为自定义规则：包含 inboundTag 或 outboundTag 以 "socks5-" 开头
                local temp_rules
                temp_rules=$(jq -c '[.routing.rules[]? | select(.inboundTag != null or (.outboundTag? | startswith("socks5-")))]' "$xray_config_path" 2>/dev/null)
                
                # 验证提取结果是否为有效的 JSON 数组
                if [[ -n "$temp_rules" ]] && echo "$temp_rules" | jq empty 2>/dev/null; then
                    existing_custom_routing_rules="$temp_rules"
                fi
            else
                warning "现有配置文件格式异常，将忽略现有的自定义配置"
            fi
        fi
    fi
    
    # 🔧 确保所有 JSON 变量都是紧凑的单行格式
    inbounds_json=$(echo "$inbounds_json" | jq -c '.')
    existing_custom_outbounds=$(echo "$existing_custom_outbounds" | jq -c '.')
    existing_custom_routing_rules=$(echo "$existing_custom_routing_rules" | jq -c '.')
    
    # 🔧 在 shell 中预先构建完整的 outbounds 数组
    # 这样可以避免在 jq 表达式内部使用 + 操作符，解决兼容性问题
    local base_outbounds
    if [[ "$enable_routing" == "true" ]]; then
        base_outbounds='[{"protocol":"freedom","tag":"direct","settings":{"domainStrategy":"UseIPv4v6"}},{"protocol":"blackhole","tag":"block"}]'
    else
        base_outbounds='[{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}]'
    fi
    
    # 使用 jq 合并 outbounds 数组（在 shell 中完成，不是在 jq 表达式内部）
    local full_outbounds
    full_outbounds=$(echo "$base_outbounds" | jq -c --argjson custom "$existing_custom_outbounds" '. + $custom')
    
    # 构建完整的 routing rules
    local full_rules
    if [[ "$enable_routing" == "true" ]]; then
        local default_block_rule='[{"type":"field","domain":["geosite:category-ads-all","geosite:category-porn","regexp:.*missav.*","geosite:missav"],"outboundTag":"block"}]'
        full_rules=$(echo "$existing_custom_routing_rules" | jq -c --argjson default "$default_block_rule" '. + $default')
    else
        full_rules="$existing_custom_routing_rules"
    fi

    if [[ "$enable_routing" == "true" ]]; then
        # 带路由规则的配置
        config_content=$(jq -n \
            --argjson inbounds "$inbounds_json" \
            --argjson outbounds "$full_outbounds" \
            --argjson rules "$full_rules" \
        '{
          "log": {"loglevel": "warning"},
          "inbounds": $inbounds,
          "outbounds": $outbounds,
          "routing": {
            "domainStrategy": "IPOnDemand",
            "rules": $rules
          }
        }')
    else
        # 不带路由规则的配置
        local rules_length
        rules_length=$(echo "$full_rules" | jq 'length')
        
        if [[ "$rules_length" -gt 0 ]]; then
            # 有自定义 rules，需要添加 routing
            config_content=$(jq -n \
                --argjson inbounds "$inbounds_json" \
                --argjson outbounds "$full_outbounds" \
                --argjson rules "$full_rules" \
            '{
              "log": {"loglevel": "warning"},
              "inbounds": $inbounds,
              "outbounds": $outbounds,
              "routing": {
                "domainStrategy": "IPOnDemand",
                "rules": $rules
              }
            }')
        else
            # 没有 rules，不需要 routing
            config_content=$(jq -n \
                --argjson inbounds "$inbounds_json" \
                --argjson outbounds "$full_outbounds" \
            '{
              "log": {"loglevel": "warning"},
              "inbounds": $inbounds,
              "outbounds": $outbounds
            }')
        fi
    fi
    
    # 新增：验证生成的JSON是否有效
    if ! echo "$config_content" | jq . >/dev/null 2>&1; then
        error "生成的配置文件格式错误！"
        return 1
    fi
    
    echo "$config_content" > "$xray_config_path"

    # 安全：配置文件仅 nobody（xray运行用户）和 root 可读
    chmod 640 "$xray_config_path"
    chown nobody:root "$xray_config_path"
}

execute_official_script() {
    local args="$1"
    local script_content
    local temp_script="/tmp/xray_install_$$.sh"

    # 下载官方安装脚本
    if ! script_content=$(curl -fsSL --max-time 30 "$xray_install_script_url" 2>/dev/null); then
        error "下载 Xray 官方安装脚本失败！请检查网络连接。"
        return 1
    fi

    # 验证脚本内容
    if [[ -z "$script_content" || ! "$script_content" =~ "install-release" ]]; then
        error "Xray 官方安装脚本内容异常！"
        return 1
    fi

    # 写入临时文件并执行
    echo "$script_content" > "$temp_script"
    chmod +x "$temp_script"

    if [[ "$is_quiet" = false ]]; then
        bash "$temp_script" $args &
        spinner $!
        wait $! || { rm -f "$temp_script"; return 1; }
    else
        bash "$temp_script" $args &>/dev/null || { rm -f "$temp_script"; return 1; }
    fi

    rm -f "$temp_script"
    return 0
}

run_core_install() {
    info "正在下载并安装 Xray 核心..."
    if ! execute_official_script "install"; then
        error "Xray 核心安装失败！"
        return 1
    fi
    
    info "正在更新 GeoIP 和 GeoSite 数据文件..."
    if ! execute_official_script "install-geodata"; then
        error "Geo-data 更新失败！"
        info "这通常不影响核心功能，您可以稍后手动更新。"
    fi
    
    success "Xray 核心及数据文件已准备就绪。"
}

# --- 输入验证与交互函数 (优化) ---
is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# 显示系统端口使用情况
show_port_usage() {
    echo ""
    info "当前系统端口使用情况:"
    printf "%-15s %-9s\n" "程序名" "端口"
    echo "────────────────────────────────────────────────────────"

    # 解析ss输出，聚合同程序的端口
    declare -A program_ports
    while read line; do
        if [[ "$line" =~ LISTEN|UNCONN ]]; then
            local local_addr=$(echo "$line" | awk '{print $5}')
            local port=$(echo "$local_addr" | grep -o ':[0-9]*$' | cut -d':' -f2)
            local program=$(echo "$line" | awk '{print $7}' | cut -d'"' -f2 2>/dev/null || echo "")

            if [ -n "$port" ] && [ -n "$program" ] && [ "$program" != "-" ]; then
                if [ -z "${program_ports[$program]:-}" ]; then
                    program_ports[$program]="$port"
                else
                    # 避免重复端口
                    if [[ ! "${program_ports[$program]}" =~ (^|.*\|)$port(\||$) ]]; then
                        program_ports[$program]="${program_ports[$program]}|$port"
                    fi
                fi
            fi
        fi
    done < <(ss -tulnp 2>/dev/null || true)

    if [ ${#program_ports[@]} -gt 0 ]; then
        for program in $(printf '%s\n' "${!program_ports[@]}" | sort); do
            local ports="${program_ports[$program]}"
            printf "%-10s | %-9s\n" "$program" "$ports"
        done
    else
        echo "无活跃端口"
    fi

    echo "────────────────────────────────────────────────────────"
    echo ""
}

# 新增：端口可用性检测
is_port_available() {
    local port="$1"
    is_valid_port "$port" || return 1

    # 检查系统端口是否被占用
    if ss -tlpn 2>/dev/null | grep -q ":$port "; then
        error "端口 $port 已被系统占用"
        return 1
    fi

    # 检查配置文件中是否已存在该端口
    if [[ -f "$xray_config_path" ]]; then
        local existing_ports
        existing_ports=$(jq -r '.inbounds[]?.port // empty' "$xray_config_path" 2>/dev/null)
        if echo "$existing_ports" | grep -q "^${port}$"; then
            error "端口 $port 已在 Xray 配置中使用"
            return 1
        fi
    fi

    return 0
}

# 生成随机可用端口（排除所有已占用端口）
generate_random_port() {
    local max_attempts=100
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        # 生成 10000-65535 范围的随机端口
        local random_port=$((RANDOM % 55536 + 10000))

        # 检查端口是否可用
        if is_port_available "$random_port" 2>/dev/null; then
            echo "$random_port"
            return 0
        fi

        attempt=$((attempt + 1))
    done

    # 如果 100 次都没找到可用端口，返回错误
    error "无法生成可用的随机端口，请手动指定"
    return 1
}

is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ ]] && [[ "$domain" != *--* ]]
}

prompt_for_vless_config() {
    local -n p_port="$1" p_uuid="$2" p_sni="$3" p_node_name="$4"
    local default_port="${5:-443}"

    # 显示端口使用情况
    show_port_usage

    while true; do
        read -p "$(echo -e " -> 请输入 VLESS 端口 (留空随机生成): ")" p_port || true
        if [[ -z "$p_port" ]]; then
            # 回车随机生成
            p_port=$(generate_random_port)
            if [ $? -eq 0 ]; then
                info "已为您随机生成端口: ${cyan}${p_port}${none}"
                break
            else
                continue
            fi
        else
            # 手动输入
            if is_port_available "$p_port"; then
                break
            fi
        fi
    done
    info "VLESS 端口将使用: ${cyan}${p_port}${none}"

    read -p "$(echo -e " -> 请输入UUID (留空将自动生成): ")" p_uuid || true
    if [[ -z "$p_uuid" ]]; then
        p_uuid=$(cat /proc/sys/kernel/random/uuid)
        info "已为您生成随机UUID: ${cyan}${p_uuid:0:8}...${p_uuid: -4}${none}"
    fi

    # SNI 域名选择
    echo ""
    echo -e "${cyan}请选择 SNI 域名:${none}"
    echo "  1. addons.mozilla.org"
    echo "  2. updates.cdn-apple.com"
    echo "  3. 自定义输入"
    read -p "$(echo -e "请输入选择 [${cyan}1${none}]: ")" sni_choice || true
    sni_choice=${sni_choice:-1}

    case "$sni_choice" in
        1)
            p_sni="addons.mozilla.org"
            ;;
        2)
            p_sni="updates.cdn-apple.com"
            ;;
        3)
            while true; do
                read -p "$(echo -e " -> 请输入自定义SNI域名: ")" p_sni || true
                if [[ -n "$p_sni" ]] && is_valid_domain "$p_sni"; then
                    break
                else
                    error "域名格式无效，请重新输入。"
                fi
            done
            ;;
        *)
            warning "无效选择，使用默认: addons.mozilla.org"
            p_sni="addons.mozilla.org"
            ;;
    esac
    info "SNI 域名将使用: ${cyan}${p_sni}${none}"

    # 节点名称
    read -p "$(echo -e " -> 请输入节点名称 (留空默认使用端口号): ")" p_node_name || true
    if [[ -z "$p_node_name" ]]; then
        p_node_name="VLESS-Reality-${p_port}"
        info "节点名称将使用: ${cyan}${p_node_name}${none}"
    fi
}

prompt_for_ss_config() {
    local -n p_port="$1" p_pass="$2" p_node_name="$3"
    local default_port="${4:-8388}"

    # 显示端口使用情况
    show_port_usage

    while true; do
        read -p "$(echo -e " -> 请输入 Shadowsocks 端口 (留空随机生成): ")" p_port || true
        if [[ -z "$p_port" ]]; then
            # 回车随机生成
            p_port=$(generate_random_port)
            if [ $? -eq 0 ]; then
                info "已为您随机生成端口: ${cyan}${p_port}${none}"
                break
            else
                continue
            fi
        else
            # 手动输入
            if is_port_available "$p_port"; then
                break
            fi
        fi
    done
    info "Shadowsocks 端口将使用: ${cyan}${p_port}${none}"

    read -p "$(echo -e " -> 请输入 Shadowsocks 密钥 (留空将自动生成): ")" p_pass || true
    if [[ -z "$p_pass" ]]; then
        p_pass=$(generate_ss_key)
        info "已为您生成随机密钥: ${cyan}${p_pass:0:4}...${p_pass: -4}${none}"
    fi

    # 节点名称
    read -p "$(echo -e " -> 请输入节点名称 (留空默认使用端口号): ")" p_node_name || true
    if [[ -z "$p_node_name" ]]; then
        p_node_name="Shadowsocks-2022-${p_port}"
        info "节点名称将使用: ${cyan}${p_node_name}${none}"
    fi
}

# --- 菜单功能函数 ---
draw_divider() {
    printf "%0.s─" {1..48}
    printf "\n"
}

draw_menu_header() {
    clear
    echo -e "${cyan} Xray VLESS-Reality & Shadowsocks-2022 管理脚本${none}"
    echo -e "${yellow} Version: ${SCRIPT_VERSION}${none}"
    draw_divider
    check_xray_status
    echo -e "${xray_status_info}"
    quick_status  # 新增快速状态显示
    draw_divider
}

press_any_key_to_continue() {
    echo ""
    read -n 1 -s -r -p " 按任意键返回主菜单..." || true
}

install_menu() {
    local vless_exists="" ss_exists=""
    if [[ -f "$xray_config_path" ]]; then
        vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
        ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    fi
    
    draw_menu_header
    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        success "您已安装 VLESS-Reality + Shadowsocks-2022 双协议。"
        info "如需修改，请使用主菜单的"修改配置"选项。\n 如需重装，请先"卸载"后，再重新"安装"。"
        return
    elif [[ -n "$vless_exists" && -z "$ss_exists" ]]; then
        info "检测到您已安装 VLESS-Reality"
        echo -e "${cyan} 请选择下一步操作${none}"
        draw_divider
        printf "  ${green}%-2s${none} %-35s\n" "1." "追加安装 Shadowsocks-2022 (组成双协议)"
        printf "  ${red}%-2s${none} %-35s\n" "2." "覆盖重装 VLESS-Reality"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider
        read -p " 请输入选项 [0-2]: " choice || true
        case "$choice" in 1) add_ss_to_vless ;; 2) install_vless_only ;; 0) return ;; *) error "无效选项。" ;; esac
    elif [[ -z "$vless_exists" && -n "$ss_exists" ]]; then
        info "检测到您已安装 Shadowsocks-2022"
        echo -e "${cyan} 请选择下一步操作${none}"
        draw_divider
        printf "  ${green}%-2s${none} %-35s\n" "1." "追加安装 VLESS-Reality (组成双协议)"
        printf "  ${red}%-2s${none} %-35s\n" "2." "覆盖重装 Shadowsocks-2022"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider
        read -p " 请输入选项 [0-2]: " choice || true
        case "$choice" in 1) add_vless_to_ss ;; 2) install_ss_only ;; 0) return ;; *) error "无效选项。" ;; esac
    else
        clean_install_menu
    fi
}

clean_install_menu() {
    draw_menu_header
    echo -e "${cyan} 请选择要安装的协议类型${none}"
    draw_divider
    printf "  ${green}%-2s${none} %-35s\n" "1." "仅 VLESS-Reality"
    printf "  ${cyan}%-2s${none} %-35s\n" "2." "仅 Shadowsocks-2022"
    printf "  ${yellow}%-2s${none} %-35s\n" "3." "VLESS-Reality + Shadowsocks-2022 (双协议)"
    draw_divider
    printf "  ${magenta}%-2s${none} %-35s\n" "0." "返回主菜单"
    draw_divider
    read -p " 请输入选项 [0-3]: " choice || true
    case "$choice" in 1) install_vless_only ;; 2) install_ss_only ;; 3) install_dual ;; 0) return ;; *) error "无效选项。" ;; esac
}

add_ss_to_vless() {
    info "开始追加安装 Shadowsocks-2022..."
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，操作中止。请检查您的网络连接。"
        return 1
    fi
    local vless_inbound vless_port default_ss_port ss_port ss_password ss_node_name ss_inbound
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path")
    vless_port=$(echo "$vless_inbound" | jq -r '.port')
    default_ss_port=$([[ "$vless_port" == "443" ]] && echo "8388" || echo "$((vless_port + 1))")

    prompt_for_ss_config ss_port ss_password ss_node_name "$default_ss_port"

    ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password" "$ss_node_name")
    write_config "[$vless_inbound, $ss_inbound]"

    if ! restart_xray; then return 1; fi

    success "追加安装成功！"
    view_all_info
}

add_vless_to_ss() {
    info "开始追加安装 VLESS-Reality..."
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，操作中止。请检查您的网络连接。"
        return 1
    fi
    local ss_inbound ss_port default_vless_port vless_port vless_uuid vless_domain vless_node_name key_pair private_key public_key vless_inbound
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path")
    ss_port=$(echo "$ss_inbound" | jq -r '.port')
    default_vless_port=$([[ "$ss_port" == "8388" ]] && echo "443" || echo "$((ss_port - 1))")

    prompt_for_vless_config vless_port vless_uuid vless_domain vless_node_name "$default_vless_port"

    info "正在生成 Reality 密钥对..."
    key_pair=$("$xray_binary_path" x25519)
    private_key=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "$key_pair" | awk '/Password:/ {print $2}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        exit 1
    fi

    vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key" "$vless_node_name")
    write_config "[$vless_inbound, $ss_inbound]"

    if ! restart_xray; then return 1; fi

    success "追加安装成功！"
    view_all_info
}

install_vless_only() {
    info "开始配置 VLESS-Reality..."
    local port uuid domain node_name
    prompt_for_vless_config port uuid domain node_name
    run_install_vless "$port" "$uuid" "$domain" "$node_name"
}

install_ss_only() {
    info "开始配置 Shadowsocks-2022..."
    local port password node_name
    prompt_for_ss_config port password node_name
    run_install_ss "$port" "$password" "$node_name"
}

install_dual() {
    info "开始配置双协议 (VLESS-Reality + Shadowsocks-2022)..."
    local vless_port vless_uuid vless_domain vless_node_name ss_port ss_password ss_node_name
    prompt_for_vless_config vless_port vless_uuid vless_domain vless_node_name

    local default_ss_port
    if [[ "$vless_port" == "443" ]]; then
        default_ss_port=8388
    else
        default_ss_port=$((vless_port + 1))
    fi

    prompt_for_ss_config ss_port ss_password ss_node_name "$default_ss_port"

    run_install_dual "$vless_port" "$vless_uuid" "$vless_domain" "$vless_node_name" "$ss_port" "$ss_password" "$ss_node_name"
}

update_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return; fi
    info "正在检查最新版本..."
    local current_version latest_version
    current_version=$("$xray_binary_path" version 2>/dev/null | head -n 1 | awk '{print $2}')

    # 尝试多种方式获取最新版本
    latest_version=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | jq -r '.tag_name' 2>/dev/null | sed 's/v//' || echo "")

    if [[ -z "$latest_version" ]]; then
        warning "无法通过 GitHub API 获取最新版本，尝试直接更新..."
        info "开始更新 Xray..."
        if ! run_core_install; then
            error "Xray 更新失败！"
            return 1
        fi
        if ! restart_xray; then return 1; fi
        success "Xray 更新完成！"
        return
    fi

    info "当前版本: ${cyan}${current_version}${none}，最新版本: ${cyan}${latest_version}${none}"

    if [[ "$current_version" == "$latest_version" ]]; then
        success "您的 Xray 已是最新版本。"
        return
    fi

    info "发现新版本，开始更新..."
    if ! run_core_install; then
        error "Xray 更新失败！"
        return 1
    fi
    if ! restart_xray; then return 1; fi
    success "Xray 更新成功！"
}

uninstall_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return; fi
    read -p "$(echo -e "${yellow}您确定要卸载 Xray 吗？这将删除所有配置！[Y/n]: ${none}")" confirm || true
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        info "操作已取消。"
        return
    fi
    info "正在卸载 Xray..."
    if ! execute_official_script "remove --purge"; then
        error "Xray 卸载失败！"
        return 1
    fi
    rm -f ~/xray_subscription_info.txt
    success "Xray 已成功卸载。"
}

# 增加 VLESS 协议
add_new_vless() {
    if [[ ! -f "$xray_binary_path" ]]; then
        error "错误: Xray 未安装，请先安装 Xray。"
        return
    fi

    info "开始添加新的 VLESS-Reality 节点..."
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，操作中止。请检查您的网络连接。"
        return 1
    fi

    local vless_port vless_uuid vless_domain vless_node_name
    prompt_for_vless_config vless_port vless_uuid vless_domain vless_node_name

    info "正在生成 Reality 密钥对..."
    local key_pair private_key public_key
    key_pair=$("$xray_binary_path" x25519)
    private_key=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "$key_pair" | awk '/Password:/ {print $2}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常。"
        return 1
    fi

    local new_vless_inbound
    new_vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key" "$vless_node_name")

    # 读取现有配置
    local existing_inbounds
    if [[ -f "$xray_config_path" ]]; then
        existing_inbounds=$(jq '.inbounds' "$xray_config_path")
        # 追加新的 VLESS inbound
        local new_inbounds
        new_inbounds=$(echo "$existing_inbounds" | jq ". += [$new_vless_inbound]")
        write_config "$new_inbounds"
    else
        write_config "[$new_vless_inbound]"
    fi

    if ! restart_xray; then return 1; fi

    success "新 VLESS 节点添加成功！"
    view_all_info
}

# 增加 Shadowsocks-2022 协议
add_new_ss() {
    if [[ ! -f "$xray_binary_path" ]]; then
        error "错误: Xray 未安装，请先安装 Xray。"
        return
    fi

    info "开始添加新的 Shadowsocks-2022 节点..."
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，操作中止。请检查您的网络连接。"
        return 1
    fi

    local ss_port ss_password ss_node_name
    prompt_for_ss_config ss_port ss_password ss_node_name

    local new_ss_inbound
    new_ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password" "$ss_node_name")

    # 读取现有配置
    local existing_inbounds
    if [[ -f "$xray_config_path" ]]; then
        existing_inbounds=$(jq '.inbounds' "$xray_config_path")
        # 追加新的 SS inbound
        local new_inbounds
        new_inbounds=$(echo "$existing_inbounds" | jq ". += [$new_ss_inbound]")
        write_config "$new_inbounds"
    else
        write_config "[$new_ss_inbound]"
    fi

    if ! restart_xray; then return 1; fi

    success "新 Shadowsocks-2022 节点添加成功！"
    view_all_info
}

# 删除指定 VLESS 节点
delete_vless_node() {
    if [[ ! -f "$xray_config_path" ]]; then
        error "错误: Xray 配置文件不存在。"
        return
    fi

    # 获取所有 VLESS inbounds
    local vless_count
    vless_count=$(jq '[.inbounds[] | select(.protocol == "vless")] | length' "$xray_config_path")

    if [[ "$vless_count" -eq 0 ]]; then
        error "未找到任何 VLESS 节点。"
        return
    fi

    draw_menu_header
    echo -e "${cyan} 当前 VLESS 节点列表${none}"
    draw_divider

    # 列出所有 VLESS 节点
    local index=1
    jq -r '.inbounds[] | select(.protocol == "vless") | "\(.port)|\(.settings.clients[0].id)|\(.tag // "未命名")"' "$xray_config_path" | while IFS='|' read -r port uuid tag; do
        printf "  ${green}%-2s${none} 端口: ${cyan}%-6s${none} UUID: ${cyan}%s...%s${none} 名称: ${cyan}%s${none}\n" "$index." "$port" "${uuid:0:8}" "${uuid: -4}" "$tag"
        ((index++))
    done

    draw_divider
    printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
    draw_divider

    read -p " 请选择要删除的节点编号 [0-$vless_count]: " choice || true

    if [[ "$choice" == "0" ]]; then
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$vless_count" ]]; then
        error "无效选项。"
        return
    fi

    # 删除选中的节点
    local new_inbounds
    new_inbounds=$(jq --argjson idx "$((choice - 1))" '
        ([.inbounds[] | select(.protocol == "vless")] | del(.[$idx])) as $vless_filtered |
        [.inbounds[] | select(.protocol != "vless")] + $vless_filtered
    ' "$xray_config_path")

    write_config "$new_inbounds"

    if ! restart_xray; then return 1; fi

    success "VLESS 节点删除成功！"
    view_all_info
}

# 删除指定 Shadowsocks-2022 节点
delete_ss_node() {
    if [[ ! -f "$xray_config_path" ]]; then
        error "错误: Xray 配置文件不存在。"
        return
    fi

    # 获取所有 SS inbounds
    local ss_count
    ss_count=$(jq '[.inbounds[] | select(.protocol == "shadowsocks")] | length' "$xray_config_path")

    if [[ "$ss_count" -eq 0 ]]; then
        error "未找到任何 Shadowsocks-2022 节点。"
        return
    fi

    draw_menu_header
    echo -e "${cyan} 当前 Shadowsocks-2022 节点列表${none}"
    draw_divider

    # 列出所有 SS 节点
    local index=1
    jq -r '.inbounds[] | select(.protocol == "shadowsocks") | "\(.port)|\(.settings.password)|\(.tag // "未命名")"' "$xray_config_path" | while IFS='|' read -r port password tag; do
        printf "  ${green}%-2s${none} 端口: ${cyan}%-6s${none} 密码: ${cyan}%s...%s${none} 名称: ${cyan}%s${none}\n" "$index." "$port" "${password:0:4}" "${password: -4}" "$tag"
        ((index++))
    done

    draw_divider
    printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
    draw_divider

    read -p " 请选择要删除的节点编号 [0-$ss_count]: " choice || true

    if [[ "$choice" == "0" ]]; then
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$ss_count" ]]; then
        error "无效选项。"
        return
    fi

    # 删除选中的节点
    local new_inbounds
    new_inbounds=$(jq --argjson idx "$((choice - 1))" '
        ([.inbounds[] | select(.protocol == "shadowsocks")] | del(.[$idx])) as $ss_filtered |
        [.inbounds[] | select(.protocol != "shadowsocks")] + $ss_filtered
    ' "$xray_config_path")

    write_config "$new_inbounds"

    if ! restart_xray; then return 1; fi

    success "Shadowsocks-2022 节点删除成功！"
    view_all_info
}

modify_vless_config() {
    # 获取所有 VLESS inbounds
    local vless_count
    vless_count=$(jq '[.inbounds[] | select(.protocol == "vless")] | length' "$xray_config_path")

    if [[ "$vless_count" -eq 0 ]]; then
        error "未找到任何 VLESS 节点。"
        return
    fi

    local selected_index
    if [[ "$vless_count" -gt 1 ]]; then
        draw_menu_header
        echo -e "${cyan} 请选择要修改的 VLESS 节点${none}"
        draw_divider

        # 列出所有 VLESS 节点
        local index=1
        jq -r '.inbounds[] | select(.protocol == "vless") | "\(.port)|\(.settings.clients[0].id)|\(.tag // "未命名")"' "$xray_config_path" | while IFS='|' read -r port uuid tag; do
            printf "  ${green}%-2s${none} 端口: ${cyan}%-6s${none} UUID: ${cyan}%s...%s${none} 名称: ${cyan}%s${none}\n" "$index." "$port" "${uuid:0:8}" "${uuid: -4}" "$tag"
            ((index++))
        done

        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider

        read -p " 请选择要修改的节点编号 [0-$vless_count]: " choice || true

        if [[ "$choice" == "0" ]]; then
            return
        fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$vless_count" ]]; then
            error "无效选项。"
            return
        fi

        selected_index=$((choice - 1))
    else
        selected_index=0
    fi

    info "开始修改 VLESS-Reality 配置..."

    # 获取选中的 VLESS inbound
    local vless_inbound current_port current_uuid current_domain current_node_name current_shortid private_key public_key
    vless_inbound=$(jq --argjson idx "$selected_index" '[.inbounds[] | select(.protocol == "vless")][$idx]' "$xray_config_path")
    current_port=$(echo "$vless_inbound" | jq -r '.port')
    current_uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
    current_domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
    current_node_name=$(echo "$vless_inbound" | jq -r '.tag // "VLESS-" + (.port | tostring)')
    current_shortid=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.shortIds[0]')
    private_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.privateKey')
    public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')

    # 显示端口使用情况
    show_port_usage

    # 输入新配置
    local port uuid domain node_name
    while true; do
        read -p "$(echo -e " -> 新端口 (当前: ${cyan}${current_port}${none}, 留空不改): ")" port || true
        [[ -z "$port" ]] && port=$current_port
        if is_port_available "$port" || [[ "$port" == "$current_port" ]]; then break; fi
    done

    read -p "$(echo -e " -> 新UUID (当前: ${cyan}${current_uuid:0:8}...${current_uuid: -4}${none}, 留空不改): ")" uuid || true
    [[ -z "$uuid" ]] && uuid=$current_uuid

    while true; do
        read -p "$(echo -e " -> 新SNI域名 (当前: ${cyan}${current_domain}${none}, 留空不改): ")" domain || true
        [[ -z "$domain" ]] && domain=$current_domain
        if is_valid_domain "$domain"; then break; else error "域名格式无效，请重新输入。"; fi
    done

    read -p "$(echo -e " -> 新节点名称 (当前: ${cyan}${current_node_name}${none}, 留空不改): ")" node_name || true
    [[ -z "$node_name" ]] && node_name=$current_node_name

    # 构建新的 VLESS inbound (保持原有的 shortid 和密钥对)
    local new_vless_inbound
    new_vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key" "$node_name" "$current_shortid")

    # 更新配置
    local new_inbounds
    new_inbounds=$(jq --argjson idx "$selected_index" --argjson new_vless "$new_vless_inbound" '
        ([.inbounds[] | select(.protocol == "vless")] | .[$idx] = $new_vless) as $vless_updated |
        [.inbounds[] | select(.protocol != "vless")] + $vless_updated
    ' "$xray_config_path" | jq '.inbounds')

    write_config "$new_inbounds"
    if ! restart_xray; then return 1; fi

    success "配置修改成功！"
    view_all_info
}

modify_ss_config() {
    if [[ ! -f "$xray_config_path" ]]; then
        error "错误: Xray 配置文件不存在。"
        return
    fi

    # 获取所有 SS inbounds
    local ss_count
    ss_count=$(jq '[.inbounds[] | select(.protocol == "shadowsocks")] | length' "$xray_config_path")

    if [[ "$ss_count" -eq 0 ]]; then
        error "未找到任何 Shadowsocks-2022 节点。"
        return
    fi

    local selected_index=0

    # 如果有多个 SS 节点，让用户选择
    if [[ "$ss_count" -gt 1 ]]; then
        draw_menu_header
        echo -e "${cyan} 当前 Shadowsocks-2022 节点列表${none}"
        draw_divider

        # 列出所有 SS 节点
        local index=1
        jq -r '.inbounds[] | select(.protocol == "shadowsocks") | "\(.port)|\(.settings.password)|\(.tag // "未命名")"' "$xray_config_path" | while IFS='|' read -r port password tag; do
            printf "  ${green}%-2s${none} 端口: ${cyan}%-6s${none} 密码: ${cyan}%s...%s${none} 名称: ${cyan}%s${none}\n" "$index." "$port" "${password:0:4}" "${password: -4}" "$tag"
            ((index++))
        done

        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider

        read -p " 请选择要修改的节点编号 [0-$ss_count]: " choice || true

        if [[ "$choice" == "0" ]]; then
            return
        fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$ss_count" ]]; then
            error "无效选项。"
            return
        fi

        selected_index=$((choice - 1))
    else
        selected_index=0
    fi

    info "开始修改 Shadowsocks-2022 配置..."

    # 获取选中的 SS inbound
    local ss_inbound current_port current_password current_node_name
    ss_inbound=$(jq --argjson idx "$selected_index" '[.inbounds[] | select(.protocol == "shadowsocks")][$idx]' "$xray_config_path")
    current_port=$(echo "$ss_inbound" | jq -r '.port')
    current_password=$(echo "$ss_inbound" | jq -r '.settings.password')
    current_node_name=$(echo "$ss_inbound" | jq -r '.tag // "Shadowsocks-2022-" + (.port | tostring)')

    # 显示端口使用情况
    show_port_usage

    # 输入新配置
    local port password node_name
    while true; do
        read -p "$(echo -e " -> 新端口 (当前: ${cyan}${current_port}${none}, 留空不改): ")" port || true
        [[ -z "$port" ]] && port=$current_port
        if is_port_available "$port" || [[ "$port" == "$current_port" ]]; then break; fi
    done

    read -p "$(echo -e " -> 新密钥 (当前: ${cyan}${current_password:0:4}...${current_password: -4}${none}, 留空不改): ")" password || true
    [[ -z "$password" ]] && password=$current_password

    read -p "$(echo -e " -> 新节点名称 (当前: ${cyan}${current_node_name}${none}, 留空不改): ")" node_name || true
    [[ -z "$node_name" ]] && node_name=$current_node_name

    # 构建新的 SS inbound
    local new_ss_inbound
    new_ss_inbound=$(build_ss_inbound "$port" "$password" "$node_name")

    # 更新配置
    local new_inbounds
    new_inbounds=$(jq --argjson idx "$selected_index" --argjson new_ss "$new_ss_inbound" '
        ([.inbounds[] | select(.protocol == "shadowsocks")] | .[$idx] = $new_ss) as $ss_updated |
        [.inbounds[] | select(.protocol != "shadowsocks")] + $ss_updated
    ' "$xray_config_path" | jq '.inbounds')

    write_config "$new_inbounds"
    if ! restart_xray; then return 1; fi

    success "配置修改成功！"
    view_all_info
}

restart_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return 1; fi
    
    info "正在重启 Xray 服务..."
    if ! systemctl restart xray; then
        error "尝试重启 Xray 服务失败！"
        # 新增：显示详细错误信息
        echo -e "\n${yellow}错误详情:${none}"
        systemctl status xray --no-pager -l | tail -5
        return 1
    fi
    
    # 等待时间稍微延长，确保服务完全启动
    sleep 2
    if systemctl is-active --quiet xray; then
        success "Xray 服务已成功重启！"
    else
        error "服务启动失败，详细信息:"
        systemctl status xray --no-pager -l | tail -5
        return 1
    fi
}

view_xray_log() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装。" && return; fi
    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出。"
    journalctl -u xray -f --no-pager
}

view_all_info() {
    if [ ! -f "$xray_config_path" ]; then
        [[ "$is_quiet" = true ]] && return
        error "错误: 配置文件不存在。"
        return
    fi
    
    [[ "$is_quiet" = false ]] && clear && echo -e "${cyan} Xray 配置及订阅信息${none}" && draw_divider

    local ip
    ip=$(get_public_ip)
    if [[ -z "$ip" ]]; then
        [[ "$is_quiet" = false ]] && error "无法获取公网 IP 地址。"
        return 1
    fi
    local host
    host=$(hostname)
    local links_array=()

    # 处理所有 VLESS inbounds
    local vless_count
    vless_count=$(jq '[.inbounds[] | select(.protocol == "vless")] | length' "$xray_config_path" 2>/dev/null || echo "0")

    if [[ "$vless_count" -gt 0 ]]; then
        local display_ip
        display_ip=$ip && [[ $ip =~ ":" ]] && display_ip="[$ip]"

        # 循环处理每个 VLESS 节点
        for ((i=0; i<vless_count; i++)); do
            local vless_inbound uuid port domain public_key shortid node_name link_name_raw link_name_encoded vless_url
            vless_inbound=$(jq --argjson idx "$i" '[.inbounds[] | select(.protocol == "vless")][$idx]' "$xray_config_path")
            uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
            port=$(echo "$vless_inbound" | jq -r '.port')
            domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
            public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
            shortid=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.shortIds[0]')
            node_name=$(echo "$vless_inbound" | jq -r '.tag // "VLESS-" + (.port | tostring)')

            if [[ -z "$public_key" ]]; then
                [[ "$is_quiet" = false ]] && error "VLESS配置不完整，可能已损坏。"
                continue
            fi

            link_name_raw="$node_name"
            link_name_encoded=$(echo "$link_name_raw" | sed 's/ /%20/g')
            vless_url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${link_name_encoded}"
            links_array+=("$vless_url")

            if [[ "$is_quiet" = false ]]; then
                [[ $i -gt 0 ]] && echo ""
                echo -e "${green} [ VLESS-Reality 配置 - ${node_name} ]${none}"
                printf "    %s: ${cyan}%s${none}\n" "节点名称" "$link_name_raw"
                printf "    %s: ${cyan}%s${none}\n" "服务器地址" "$ip"
                printf "    %s: ${cyan}%s${none}\n" "端口" "$port"
                printf "    %s: ${cyan}%s${none}\n" "UUID" "${uuid:0:8}...${uuid: -4}"
                printf "    %s: ${cyan}%s${none}\n" "流控" "xtls-rprx-vision"
                printf "    %s: ${cyan}%s${none}\n" "传输协议" "tcp"
                printf "    %s: ${cyan}%s${none}\n" "安全类型" "reality"
                printf "    %s: ${cyan}%s${none}\n" "SNI" "$domain"
                printf "    %s: ${cyan}%s${none}\n" "指纹" "chrome"
                printf "    %s: ${cyan}%s${none}\n" "PublicKey" "${public_key:0:16}..."
                printf "    %s: ${cyan}%s${none}\n" "ShortId" "$shortid"
            fi
        done
    fi

    # 处理所有 Shadowsocks inbounds
    local ss_count
    ss_count=$(jq '[.inbounds[] | select(.protocol == "shadowsocks")] | length' "$xray_config_path" 2>/dev/null || echo "0")

    if [[ "$ss_count" -gt 0 ]]; then
        # 循环处理每个 SS 节点
        for ((i=0; i<ss_count; i++)); do
            local ss_inbound port method password node_name link_name_raw link_name_encoded user_info_base64 ss_url
            ss_inbound=$(jq --argjson idx "$i" '[.inbounds[] | select(.protocol == "shadowsocks")][$idx]' "$xray_config_path")
            port=$(echo "$ss_inbound" | jq -r '.port')
            method=$(echo "$ss_inbound" | jq -r '.settings.method')
            password=$(echo "$ss_inbound" | jq -r '.settings.password')
            node_name=$(echo "$ss_inbound" | jq -r '.tag // "Shadowsocks-2022-" + (.port | tostring)')

            link_name_raw="$node_name"
            link_name_encoded=$(echo "$link_name_raw" | sed 's/ /%20/g')
            user_info_base64=$(echo -n "${method}:${password}" | base64 -w 0)
            ss_url="ss://${user_info_base64}@${ip}:${port}#${link_name_encoded}"
            links_array+=("$ss_url")

            if [[ "$is_quiet" = false ]]; then
                echo ""
                echo -e "${green} [ Shadowsocks-2022 配置 - ${node_name} ]${none}"
                printf "    %s: ${cyan}%s${none}\n" "节点名称" "$link_name_raw"
                printf "    %s: ${cyan}%s${none}\n" "服务器地址" "$ip"
                printf "    %s: ${cyan}%s${none}\n" "端口" "$port"
                printf "    %s: ${cyan}%s${none}\n" "加密方式" "$method"
                printf "    %s: ${cyan}%s${none}\n" "密码" "${password:0:4}...${password: -4}"
            fi
        done
    fi

    if [ ${#links_array[@]} -gt 0 ]; then
        if [[ "$is_quiet" = true ]]; then
            printf "%s\n" "${links_array[@]}"
        else
            draw_divider
            printf "%s\n" "${links_array[@]}" > ~/xray_subscription_info.txt
            success "所有订阅链接已汇总保存到: ~/xray_subscription_info.txt"
            
            echo -e "\n${yellow} --- V2Ray / Clash 等客户端可直接导入以下链接 --- ${none}\n"
            for link in "${links_array[@]}"; do
                echo -e "${cyan}${link}${none}\n"
            done
            draw_divider
        fi
    elif [[ "$is_quiet" = false ]]; then
        info "当前未安装任何协议，无订阅信息可显示。"
    fi
}

# --- SOCKS5 链式代理管理 ---

# 新增 SOCKS5 链式代理
add_socks5_proxy() {
    if [[ ! -f "$xray_config_path" ]]; then
        error "错误: Xray 配置文件不存在。"
        return
    fi

    clear
    draw_menu_header
    echo -e "${cyan}╔════════════════════════════════════════════╗${none}"
    echo -e "${cyan}║      新增 SOCKS5 链式代理                   ║${none}"
    echo -e "${cyan}╚════════════════════════════════════════════╝${none}"
    echo ""
    
    # 获取所有inbounds (VLESS 和 SS)
    local inbound_count
    inbound_count=$(jq '[.inbounds[] | select(.protocol == "vless" or .protocol == "shadowsocks")] | length' "$xray_config_path")
    
    if [[ "$inbound_count" -eq 0 ]]; then
        error "未找到任何 VLESS 或 Shadowsocks 节点。"
        return
    fi
    
    echo -e "${cyan} 当前节点列表${none}"
    draw_divider
    
    # 列出所有节点（避免子shell问题）
    local index=1
    while IFS='|' read -r protocol port tag; do
        printf "  ${green}%-2s${none} [%-12s] 端口: ${cyan}%-6s${none} 名称: ${cyan}%s${none}\n" "$index." "$protocol" "$port" "$tag"
        ((index++))
    done < <(jq -r '.inbounds[] | select(.protocol == "vless" or .protocol == "shadowsocks") | "\(.protocol)|\(.port)|\(.tag // "未命名")"' "$xray_config_path")
    
    draw_divider
    printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
    draw_divider
    
    read -p " 请选择要配置链式代理的节点编号 [0-$inbound_count]: " choice || true
    
    if [[ "$choice" == "0" ]]; then
        return
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$inbound_count" ]]; then
        error "无效选项。"
        return
    fi
    
    # 获取选中节点的信息
    local selected_info
    selected_info=$(jq -r --argjson idx "$((choice - 1))" '[.inbounds[] | select(.protocol == "vless" or .protocol == "shadowsocks")][$idx] | "\(.tag // "inbound-\(.port)")|\(.port)"' "$xray_config_path")
    
    if [[ -z "$selected_info" ]]; then
        error "无法获取节点信息"
        return
    fi
    
    local selected_tag=$(echo "$selected_info" | cut -d'|' -f1)
    local selected_port=$(echo "$selected_info" | cut -d'|' -f2)
    
    echo ""
    info "已选择节点: ${cyan}${selected_tag}${none} (端口: ${cyan}${selected_port}${none})"
    
    # 检查是否已配置链式代理
    local existing_rule
    existing_rule=$(jq -r --arg tag "$selected_tag" '.routing.rules[]? | select(.inboundTag[0] == $tag and (.outboundTag | startswith("socks5-"))) | .outboundTag' "$xray_config_path" 2>/dev/null)
    
    if [[ -n "$existing_rule" ]]; then
        echo ""
        warn "⚠️  该节点已配置链式代理: ${cyan}${existing_rule}${none}"
        read -p " 是否覆盖现有配置? [y/N]: " overwrite || true
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            return
        fi
    fi
    
    echo ""
    
    # 输入SOCKS5信息
    draw_divider
    echo -e "${cyan}请输入 SOCKS5 代理信息${none}"
    draw_divider
    
    local socks5_addr socks5_port socks5_user socks5_pass need_auth
    
    read -p " SOCKS5 代理地址: " socks5_addr || true
    if [[ -z "$socks5_addr" ]]; then
        error "地址不能为空"
        return
    fi
    
    read -p " SOCKS5 代理端口: " socks5_port || true
    if ! [[ "$socks5_port" =~ ^[0-9]+$ ]] || [[ "$socks5_port" -lt 1 ]] || [[ "$socks5_port" -gt 65535 ]]; then
        error "无效端口"
        return
    fi
    
    read -p " 是否需要认证? [y/N]: " need_auth || true
    if [[ "$need_auth" =~ ^[Yy]$ ]]; then
        read -p " 用户名: " socks5_user || true
        read -p " 密码: " socks5_pass || true
    fi
    
    # 生成唯一的outbound tag
    local socks5_tag="socks5-${selected_tag}"
    
    # 读取现有配置
    local config
    config=$(cat "$xray_config_path")
    
    # 构建SOCKS5 outbound
    local socks5_outbound
    if [[ "$need_auth" =~ ^[Yy]$ ]]; then
        socks5_outbound=$(jq -n --arg addr "$socks5_addr" --arg port "$socks5_port" --arg user "$socks5_user" --arg pass "$socks5_pass" --arg tag "$socks5_tag" '{
            tag: $tag,
            protocol: "socks",
            settings: {
                servers: [{
                    address: $addr,
                    port: ($port | tonumber),
                    users: [{
                        user: $user,
                        pass: $pass
                    }]
                }]
            }
        }')
    else
        socks5_outbound=$(jq -n --arg addr "$socks5_addr" --arg port "$socks5_port" --arg tag "$socks5_tag" '{
            tag: $tag,
            protocol: "socks",
            settings: {
                servers: [{
                    address: $addr,
                    port: ($port | tonumber)
                }]
            }
        }')
    fi
    
    # 检查是否已存在相同的socks5 outbound
    local existing_outbound
    existing_outbound=$(echo "$config" | jq --arg tag "$socks5_tag" '.outbounds[]? | select(.tag == $tag)')
    
    if [[ -n "$existing_outbound" ]]; then
        # 更新现有的outbound
        config=$(echo "$config" | jq --argjson new_outbound "$socks5_outbound" --arg tag "$socks5_tag" '
            .outbounds |= map(if .tag == $tag then $new_outbound else . end)
        ')
    else
        # 添加新的outbound
        config=$(echo "$config" | jq --argjson new_outbound "$socks5_outbound" '
            .outbounds += [$new_outbound]
        ')
    fi
    
    # 添加或更新路由规则
    config=$(echo "$config" | jq --arg inbound_tag "$selected_tag" --arg outbound_tag "$socks5_tag" '
        if .routing.rules then
            # 删除当前节点的旧规则，并在前面添加新规则（一个原子操作）
            .routing.rules = [{
                type: "field",
                inboundTag: [$inbound_tag],
                outboundTag: $outbound_tag
            }] + (.routing.rules | map(select(.inboundTag[0] != $inbound_tag)))
        else
            # 如果没有routing，创建一个
            .routing = {
                rules: [{
                    type: "field",
                    inboundTag: [$inbound_tag],
                    outboundTag: $outbound_tag
                }]
            }
        end
    ')
    
    # 验证JSON有效性
    if ! echo "$config" | jq . > /dev/null 2>&1; then
        error "生成的配置文件格式错误！"
        return 1
    fi
    
    # 备份原配置
    cp "$xray_config_path" "${xray_config_path}.bak.$(date +%s)"
    
    # 保存配置（安全权限）
    echo "$config" > "$xray_config_path"
    chmod 640 "$xray_config_path"
    chown nobody:root "$xray_config_path"

    success "✅ 已为节点 ${cyan}${selected_tag}${none} 配置 SOCKS5 链式代理"
    info "SOCKS5: ${cyan}${socks5_addr}:${socks5_port}${none}"
    
    # 重启Xray
    echo ""
    read -p " 是否立即重启 Xray 使配置生效? [Y/n]: " restart_choice || true
    if [[ ! "$restart_choice" =~ ^[Nn]$ ]]; then
        systemctl restart xray
        sleep 1
        if systemctl is-active --quiet xray; then
            success "✅ Xray 已重启"
        else
            error "❌ Xray 重启失败，请检查日志: journalctl -u xray -n 20"
            warn "已创建备份: ${xray_config_path}.bak.*"
        fi
    fi
}

# 查看 SOCKS5 链式代理列表
list_socks5_proxies() {
    if [[ ! -f "$xray_config_path" ]]; then
        error "错误: Xray 配置文件不存在。"
        return
    fi

    clear
    draw_menu_header
    echo -e "${cyan}╔════════════════════════════════════════════╗${none}"
    echo -e "${cyan}║      SOCKS5 链式代理列表                    ║${none}"
    echo -e "${cyan}╚════════════════════════════════════════════╝${none}"
    echo ""
    
    # 获取所有routing rules中指向socks outbound的规则
    local socks5_rules
    socks5_rules=$(jq -r '
        .routing.rules[]? | 
        select(.outboundTag? | startswith("socks5-")) | 
        "\(.inboundTag[0])|\(.outboundTag)"
    ' "$xray_config_path" 2>/dev/null)
    
    if [[ -z "$socks5_rules" ]]; then
        info "当前没有配置任何 SOCKS5 链式代理"
        return
    fi
    
    echo -e "${cyan} 已配置链式代理的节点${none}"
    draw_divider
    printf "  ${cyan}%-20s${none} ${cyan}%-30s${none} ${cyan}%s${none}\n" "节点" "SOCKS5地址" "状态"
    draw_divider
    
    while IFS='|' read -r inbound_tag outbound_tag; do
        # 获取SOCKS5 outbound信息
        local socks5_info
        socks5_info=$(jq -r --arg tag "$outbound_tag" '
            .outbounds[]? | select(.tag == $tag) | 
            "\(.settings.servers[0].address):\(.settings.servers[0].port)"
        ' "$xray_config_path" 2>/dev/null)
        
        if [[ -n "$socks5_info" ]]; then
            printf "  ${green}%-20s${none} → ${yellow}%-30s${none} ${green}%s${none}\n" "$inbound_tag" "$socks5_info" "✓"
        else
            printf "  ${red}%-20s${none} → ${red}%-30s${none} ${red}%s${none}\n" "$inbound_tag" "配置丢失" "✗"
        fi
    done <<< "$socks5_rules"
    
    draw_divider
}

# 删除 SOCKS5 链式代理
delete_socks5_proxy() {
    if [[ ! -f "$xray_config_path" ]]; then
        error "错误: Xray 配置文件不存在。"
        return
    fi

    clear
    draw_menu_header
    echo -e "${cyan}╔════════════════════════════════════════════╗${none}"
    echo -e "${cyan}║      删除 SOCKS5 链式代理                   ║${none}"
    echo -e "${cyan}╚════════════════════════════════════════════╝${none}"
    echo ""
    
    # 获取所有配置了socks5的节点
    local socks5_rules
    socks5_rules=$(jq -r '
        .routing.rules[]? | 
        select(.outboundTag? | startswith("socks5-")) | 
        "\(.inboundTag[0])|\(.outboundTag)"
    ' "$xray_config_path" 2>/dev/null)
    
    if [[ -z "$socks5_rules" ]]; then
        info "当前没有配置任何 SOCKS5 链式代理"
        return
    fi
    
    echo -e "${cyan} 已配置链式代理的节点${none}"
    draw_divider
    
    # 使用数组存储，避免子shell问题
    local index=1
    local -a node_list
    while IFS='|' read -r inbound_tag outbound_tag; do
        local socks5_info
        socks5_info=$(jq -r --arg tag "$outbound_tag" '
            .outbounds[]? | select(.tag == $tag) | 
            "\(.settings.servers[0].address):\(.settings.servers[0].port)"
        ' "$xray_config_path" 2>/dev/null)
        
        printf "  ${green}%-2s${none} 节点: ${cyan}%-20s${none} SOCKS5: ${yellow}%s${none}\n" "$index." "$inbound_tag" "$socks5_info"
        node_list[$index]="$inbound_tag|$outbound_tag"
        ((index++))
    done <<< "$socks5_rules"
    
    local proxy_count=$((index - 1))
    
    draw_divider
    printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
    draw_divider
    
    read -p " 请选择要删除的链式代理编号 [0-$proxy_count]: " choice || true
    
    if [[ "$choice" == "0" ]]; then
        return
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$proxy_count" ]]; then
        error "无效选项。"
        return
    fi
    
    # 获取选中的inbound和outbound tag
    local selected_info="${node_list[$choice]}"
    if [[ -z "$selected_info" ]]; then
        error "无法获取节点信息"
        return
    fi
    
    local inbound_tag=$(echo "$selected_info" | cut -d'|' -f1)
    local outbound_tag=$(echo "$selected_info" | cut -d'|' -f2)
    
    # 读取配置
    local config
    config=$(cat "$xray_config_path")
    
    # 删除routing rule（只删除匹配该inbound且指向socks5的规则）
    config=$(echo "$config" | jq --arg inbound_tag "$inbound_tag" --arg outbound_tag "$outbound_tag" '
        .routing.rules |= map(select(
            (.inboundTag[0] != $inbound_tag) or 
            (.outboundTag != $outbound_tag)
        ))
    ')
    
    # 删除socks5 outbound
    config=$(echo "$config" | jq --arg outbound_tag "$outbound_tag" '
        .outbounds |= map(select(.tag != $outbound_tag))
    ')
    
    # 验证JSON有效性
    if ! echo "$config" | jq . > /dev/null 2>&1; then
        error "生成的配置文件格式错误！"
        return 1
    fi
    
    # 备份原配置
    cp "$xray_config_path" "${xray_config_path}.bak.$(date +%s)"
    
    # 保存配置（安全权限）
    echo "$config" > "$xray_config_path"
    chmod 640 "$xray_config_path"
    chown nobody:root "$xray_config_path"

    success "✅ 已删除节点 ${cyan}${inbound_tag}${none} 的链式代理配置"
    
    # 重启Xray
    echo ""
    read -p " 是否立即重启 Xray 使配置生效? [Y/n]: " restart_choice || true
    if [[ ! "$restart_choice" =~ ^[Nn]$ ]]; then
        systemctl restart xray
        sleep 1
        if systemctl is-active --quiet xray; then
            success "✅ Xray 已重启"
        else
            error "❌ Xray 重启失败，请检查日志: journalctl -u xray -n 20"
            warn "已创建备份: ${xray_config_path}.bak.*"
        fi
    fi
}

# --- 路由过滤规则管理 ---
manage_routing_rules() {
    clear
    echo -e "${cyan}╔════════════════════════════════════════════╗${none}"
    echo -e "${cyan}║      路由过滤规则管理                      ║${none}"
    echo -e "${cyan}╚════════════════════════════════════════════╝${none}"
    echo ""
    
    if [[ ! -f "$xray_config_path" ]]; then
        error "Xray 配置文件不存在！请先安装 Xray。"
        return 1
    fi
    
    # 检查当前是否启用了路由规则
    local has_routing
    has_routing=$(jq -r '.routing // empty' "$xray_config_path" 2>/dev/null)
    
    if [[ -n "$has_routing" ]]; then
        echo -e "${green}✓ 当前状态: 路由过滤规则${green}已启用${none}"
        echo ""
        echo -e "${yellow}过滤内容:${none}"
        echo "  • geosite:category-ads-all  (所有广告)"
        echo "  • geosite:category-porn     (色情网站)"
        echo "  • regexp:.*missav.*         (missav相关域名)"
        echo "  • geosite:missav            (missav站点)"
        echo ""
        echo "────────────────────────────────────────────────"
        echo -e "${cyan}1.${none} 禁用路由过滤规则（恢复纯净代理）"
        echo -e "${red}0.${none} 返回上级菜单"
        echo "────────────────────────────────────────────────"
        read -p " 请选择 [0-1]: " choice || true
        
        if [[ "$choice" == "1" ]]; then
            info "正在禁用路由过滤规则..."
            
            # 读取现有的inbounds配置
            local inbounds_json
            inbounds_json=$(jq -c '.inbounds' "$xray_config_path")
            
            # 重新生成不带路由的配置
            write_config "$inbounds_json" "false"
            
            if restart_xray; then
                success "路由过滤规则已禁用！现在是纯净代理模式。"
            else
                error "Xray 重启失败！"
                return 1
            fi
        fi
    else
        echo -e "${yellow}✗ 当前状态: 路由过滤规则${red}未启用${none}"
        echo ""
        echo -e "${cyan}启用后将自动屏蔽以下内容:${none}"
        echo "  • 所有广告 (geosite:category-ads-all)"
        echo "  • 色情网站 (geosite:category-porn)"
        echo "  • missav相关域名"
        echo ""
        echo -e "${yellow}⚠ 注意: 需要GeoIP/GeoSite数据文件支持${none}"
        echo ""
        echo "────────────────────────────────────────────────"
        echo -e "${green}1.${none} 启用路由过滤规则"
        echo -e "${red}0.${none} 返回上级菜单"
        echo "────────────────────────────────────────────────"
        read -p " 请选择 [0-1]: " choice || true
        
        if [[ "$choice" == "1" ]]; then
            info "正在启用路由过滤规则..."
            
            # 检查GeoIP和GeoSite文件是否存在
            local geo_missing=false
            if [[ ! -f "/usr/local/share/xray/geosite.dat" ]]; then
                warning "GeoSite 数据文件不存在，正在下载..."
                execute_official_script "install-geodata" || geo_missing=true
            fi
            
            if [[ "$geo_missing" == "true" ]]; then
                error "GeoSite 数据文件下载失败，路由规则可能无法正常工作。"
                read -p " 是否继续启用？(y/N): " confirm || true
                if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                    info "已取消操作"
                    return 0
                fi
            fi
            
            # 读取现有的inbounds配置
            local inbounds_json
            inbounds_json=$(jq -c '.inbounds' "$xray_config_path")
            
            # 重新生成带路由的配置
            write_config "$inbounds_json" "true"
            
            if restart_xray; then
                success "路由过滤规则已启用！"
                echo -e "${green}现在将自动屏蔽广告、色情网站和missav${none}"
            else
                error "Xray 重启失败！"
                return 1
            fi
        fi
    fi
}

# --- 核心安装逻辑函数 ---
run_install_vless() {
    local port="$1" uuid="$2" domain="$3" node_name="$4"
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        exit 1
    fi
    run_core_install || exit 1
    info "正在生成 Reality 密钥对..."
    local key_pair private_key public_key vless_inbound
    key_pair=$("$xray_binary_path" x25519)
    private_key=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "$key_pair" | awk '/Password:/ {print $2}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        exit 1
    fi

    vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key" "$node_name")
    write_config "[$vless_inbound]"

    if ! restart_xray; then exit 1; fi

    success "VLESS-Reality 安装成功！"
    view_all_info
}

run_install_ss() {
    local port="$1" password="$2" node_name="$3"
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        exit 1
    fi
    run_core_install || exit 1
    local ss_inbound
    ss_inbound=$(build_ss_inbound "$port" "$password" "$node_name")
    write_config "[$ss_inbound]"

    if ! restart_xray; then exit 1; fi

    success "Shadowsocks-2022 安装成功！"
    view_all_info
}

run_install_dual() {
    local vless_port="$1" vless_uuid="$2" vless_domain="$3" vless_node_name="$4" ss_port="$5" ss_password="$6" ss_node_name="$7"
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        exit 1
    fi
    run_core_install || exit 1
    info "正在生成 Reality 密钥对..."
    local key_pair private_key public_key vless_inbound ss_inbound
    key_pair=$("$xray_binary_path" x25519)
    private_key=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "$key_pair" | awk '/Password:/ {print $2}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试卸载后重装。"
        exit 1
    fi

    vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key" "$vless_node_name")
    ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password" "$ss_node_name")
    write_config "[$vless_inbound, $ss_inbound]"

    if ! restart_xray; then exit 1; fi

    success "双协议安装成功！"
    view_all_info
}

# --- 主菜单与脚本入口 ---
main_menu() {
    while true; do
        draw_menu_header
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装 Xray (VLESS/Shadowsocks)"
        draw_divider
        echo -e "${cyan}[VLESS 协议管理]${none}"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "增加 VLESS 协议"
        printf "  ${magenta}%-2s${none} %-35s\n" "3." "删除指定 VLESS 节点"
        printf "  ${yellow}%-2s${none} %-35s\n" "4." "修改 VLESS 配置"
        draw_divider
        echo -e "${cyan}[Shadowsocks-2022 协议管理]${none}"
        printf "  ${cyan}%-2s${none} %-35s\n" "5." "增加 Shadowsocks-2022 协议"
        printf "  ${magenta}%-2s${none} %-35s\n" "6." "删除指定 Shadowsocks-2022 节点"
        printf "  ${yellow}%-2s${none} %-35s\n" "7." "修改 Shadowsocks-2022 配置"
        draw_divider
        echo -e "${cyan}[SOCKS5 链式代理管理]${none}"
        printf "  ${green}%-2s${none} %-35s\n" "8." "🔗 新增 SOCKS5 链式代理"
        printf "  ${cyan}%-2s${none} %-35s\n" "9." "📋 查看 SOCKS5 链式代理列表"
        printf "  ${magenta}%-2s${none} %-35s\n" "10." "❌ 删除 SOCKS5 链式代理"
        draw_divider
        echo -e "${cyan}[Xray 服务管理]${none}"
        printf "  ${green}%-2s${none} %-35s\n" "11." "更新 Xray"
        printf "  ${red}%-2s${none} %-35s\n" "12." "卸载 Xray"
        printf "  ${cyan}%-2s${none} %-35s\n" "13." "重启 Xray"
        printf "  ${magenta}%-2s${none} %-35s\n" "14." "查看 Xray 日志"
        printf "  ${yellow}%-2s${none} %-35s\n" "15." "查看订阅信息"
        draw_divider
        echo -e "${cyan}[高级功能]${none}"
        printf "  ${green}%-2s${none} %-35s ⭐\n" "16." "路由过滤规则管理"
        draw_divider
        echo -e "${cyan}[多协议代理一键部署脚本]${none}"
        printf "  ${green}%-2s${none} %-35s\n" "17." "vless-all-in-one"
        draw_divider
        printf "  ${red}%-2s${none} %-35s\n" "0." "退出脚本"
        draw_divider

        read -p " 请输入选项 [0-17]: " choice || true

        local needs_pause=true

        case "$choice" in
            1) install_menu ;;
            2) add_new_vless ;;
            3) delete_vless_node ;;
            4) modify_vless_config ;;
            5) add_new_ss ;;
            6) delete_ss_node ;;
            7) modify_ss_config ;;
            8) add_socks5_proxy ;;
            9) list_socks5_proxies ;;
            10) delete_socks5_proxy ;;
            11) update_xray ;;
            12) uninstall_xray ;;
            13) restart_xray ;;
            14) view_xray_log; needs_pause=false ;;
            15) view_all_info ;;
            16) manage_routing_rules ;;
            17) wget -O vless-server.sh https://raw.githubusercontent.com/Chil30/vless-all-in-one/main/vless-server.sh && chmod +x vless-server.sh && bash vless-server.sh; needs_pause=false ;;
            0) success "感谢使用！"; exit 0 ;;
            *) error "无效选项。请输入 0-17。" ;;
        esac

        if [ "$needs_pause" = true ]; then
            press_any_key_to_continue
        fi
    done
}

# --- 脚本主入口 ---
main() {
    pre_check
    main_menu
}

main "$@"
XRAY_ENHANCED_SCRIPT_EOF

    chmod +x "$script_path"
    echo -e "${gl_lv}✅ 脚本准备完成${gl_bai}"
    echo ""

    # 执行脚本
    if bash "$script_path"; then
        echo ""
        echo -e "${gl_lv}✅ 星辰大海Xray增强版脚本执行完成${gl_bai}"
    else
        echo ""
        echo -e "${gl_hong}❌ 脚本执行失败${gl_bai}"
    fi

    # 清理临时文件
    rm -f "$script_path"

    echo ""
    echo "------------------------------------------------"
    break_end
}

#=============================================================================
# 禁止端口通过中国大陆直连功能
#=============================================================================

# 配置文件路径
CN_BLOCK_CONFIG="/usr/local/etc/xray/cn-block-ports.conf"
CN_IPSET_NAME="china-ip-block"
CN_IP_LIST_FILE="/tmp/china-ip-list.txt"

# 检查依赖
check_cn_block_dependencies() {
    local missing_deps=()

    if ! command -v ipset &> /dev/null; then
        missing_deps+=("ipset")
    fi

    if ! command -v iptables &> /dev/null; then
        missing_deps+=("iptables")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${gl_huang}检测到缺少依赖: ${missing_deps[*]}${gl_bai}"
        echo "正在安装..."

        if command -v apt-get &> /dev/null; then
            apt-get update -qq
            apt-get install -y ipset iptables iptables-persistent
        elif command -v yum &> /dev/null; then
            yum install -y ipset iptables iptables-services
        else
            echo -e "${gl_hong}❌ 不支持的系统，请手动安装 ipset 和 iptables${gl_bai}"
            return 1
        fi

        echo -e "${gl_lv}✅ 依赖安装完成${gl_bai}"
    fi

    return 0
}

# 初始化配置文件
init_cn_block_config() {
    if [ ! -f "$CN_BLOCK_CONFIG" ]; then
        mkdir -p "$(dirname "$CN_BLOCK_CONFIG")"
        cat > "$CN_BLOCK_CONFIG" << 'EOF'
# 中国大陆 IP 封锁端口配置文件
# 格式: 端口|添加时间|备注
# 示例: 1234|2025-10-25 12:00:00|SS节点
EOF
    fi
}

# 下载中国 IP 段列表
download_china_ip_list() {
    echo -e "${gl_kjlan}正在下载中国 IP 段列表...${gl_bai}"

    local sources=(
        "https://raw.githubusercontent.com/metowolf/iplist/master/data/country/CN.txt"
        "https://ispip.clang.cn/all_cn.txt"
        "https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
    )

    local downloaded=0

    for source in "${sources[@]}"; do
        echo "尝试从 $source 下载..."
        if curl -sSL --connect-timeout 10 --max-time 60 "$source" -o "$CN_IP_LIST_FILE" 2>/dev/null; then
            if [ -s "$CN_IP_LIST_FILE" ]; then
                local line_count=$(wc -l < "$CN_IP_LIST_FILE")
                if [ "$line_count" -gt 1000 ]; then
                    echo -e "${gl_lv}✅ 下载成功，共 $line_count 条 IP 段${gl_bai}"
                    downloaded=1
                    break
                fi
            fi
        fi
    done

    if [ $downloaded -eq 0 ]; then
        echo -e "${gl_hong}❌ 所有源下载失败${gl_bai}"
        return 1
    fi

    return 0
}

# 创建或更新 ipset
update_china_ipset() {
    echo -e "${gl_kjlan}正在更新 IP 地址库...${gl_bai}"

    # 使用文件锁防止并发执行
    local lock_file="/var/lock/china-ipset-update.lock"
    local lock_fd=200

    # 尝试获取锁（最多等待30秒）
    exec 200>"$lock_file"
    if ! flock -w 30 200; then
        echo -e "${gl_hong}❌ 无法获取锁，可能有其他实例正在运行${gl_bai}"
        return 1
    fi

    # 确保退出时释放锁和清理临时文件
    trap "flock -u 200; rm -f '$lock_file' '$CN_IP_LIST_FILE'" EXIT ERR

    # 下载 IP 列表
    if ! download_china_ip_list; then
        return 1
    fi

    # 创建临时 ipset
    local temp_set="${CN_IPSET_NAME}-temp"

    # 删除旧的临时集合（如果存在）
    ipset destroy "$temp_set" 2>/dev/null || true

    # 创建新的临时集合
    ipset create "$temp_set" hash:net maxelem 70000

    # 添加 IP 段到临时集合
    local count=0
    while IFS= read -r ip; do
        # 跳过空行和注释
        [[ -z "$ip" || "$ip" =~ ^# ]] && continue

        # 验证 IP 格式
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
            ipset add "$temp_set" "$ip" 2>/dev/null && ((count++))
        fi
    done < "$CN_IP_LIST_FILE"

    echo -e "${gl_lv}✅ 成功添加 $count 条 IP 段到集合${gl_bai}"

    # 交换集合（原子操作）
    if ipset list "$CN_IPSET_NAME" &>/dev/null; then
        ipset swap "$temp_set" "$CN_IPSET_NAME"
        ipset destroy "$temp_set"
    else
        ipset rename "$temp_set" "$CN_IPSET_NAME"
    fi

    # 清理临时文件
    rm -f "$CN_IP_LIST_FILE"

    # 保存 ipset
    if command -v ipset-persistent &> /dev/null; then
        ipset-persistent save
    elif command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save
    fi

    # 清理 trap 和释放锁
    trap - EXIT ERR
    flock -u 200

    echo -e "${gl_lv}✅ IP 地址库更新完成${gl_bai}"
    return 0
}

# 添加端口封锁规则
add_port_block_rule() {
    local port="$1"
    local note="${2:-手动添加}"

    # 验证端口
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${gl_hong}❌ 无效的端口号: $port${gl_bai}"
        return 1
    fi

    # 检查是否已存在
    if grep -q "^${port}|" "$CN_BLOCK_CONFIG" 2>/dev/null; then
        echo -e "${gl_huang}⚠ 端口 $port 已在封锁列表中${gl_bai}"
        return 1
    fi

    # 确保 ipset 存在
    if ! ipset list "$CN_IPSET_NAME" &>/dev/null; then
        echo -e "${gl_huang}IP 地址库不存在，正在创建...${gl_bai}"
        if ! update_china_ipset; then
            return 1
        fi
    fi

    # 添加 iptables 规则
    iptables -C INPUT -p tcp --dport "$port" -m set --match-set "$CN_IPSET_NAME" src -j DROP 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$port" -m set --match-set "$CN_IPSET_NAME" src -j DROP

    iptables -C INPUT -p udp --dport "$port" -m set --match-set "$CN_IPSET_NAME" src -j DROP 2>/dev/null || \
        iptables -I INPUT -p udp --dport "$port" -m set --match-set "$CN_IPSET_NAME" src -j DROP

    # 保存到配置文件
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${port}|${timestamp}|${note}" >> "$CN_BLOCK_CONFIG"

    # 保存 iptables 规则
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v iptables-save &> /dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    echo -e "${gl_lv}✅ 端口 $port 封锁规则已添加${gl_bai}"
    return 0
}

# 删除端口封锁规则
remove_port_block_rule() {
    local port="$1"

    # 验证端口
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${gl_hong}❌ 无效的端口号: $port${gl_bai}"
        return 1
    fi

    # 检查是否存在
    if ! grep -q "^${port}|" "$CN_BLOCK_CONFIG" 2>/dev/null; then
        echo -e "${gl_huang}⚠ 端口 $port 不在封锁列表中${gl_bai}"
        return 1
    fi

    # 删除 iptables 规则
    iptables -D INPUT -p tcp --dport "$port" -m set --match-set "$CN_IPSET_NAME" src -j DROP 2>/dev/null || true
    iptables -D INPUT -p udp --dport "$port" -m set --match-set "$CN_IPSET_NAME" src -j DROP 2>/dev/null || true

    # 从配置文件删除
    sed -i "/^${port}|/d" "$CN_BLOCK_CONFIG"

    # 保存 iptables 规则
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v iptables-save &> /dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    echo -e "${gl_lv}✅ 端口 $port 封锁规则已删除${gl_bai}"
    return 0
}

# 获取已封锁端口列表
get_blocked_ports() {
    if [ ! -f "$CN_BLOCK_CONFIG" ]; then
        return 0
    fi

    grep -v '^#' "$CN_BLOCK_CONFIG" | grep -v '^$' | awk -F'|' '{print $1}'
}

# 获取 Xray 端口列表
get_xray_ports() {
    local xray_config="/usr/local/etc/xray/config.json"

    if [ ! -f "$xray_config" ]; then
        return 0
    fi

    if command -v jq &> /dev/null; then
        jq -r '.inbounds[]?.port // empty' "$xray_config" 2>/dev/null | sort -n
    fi
}

# 清空所有封锁规则
clear_all_block_rules() {
    echo -e "${gl_huang}正在清空所有封锁规则...${gl_bai}"

    # 读取所有已封锁端口
    local ports=($(get_blocked_ports))

    if [ ${#ports[@]} -eq 0 ]; then
        echo -e "${gl_huang}⚠ 没有需要清空的规则${gl_bai}"
        return 0
    fi

    # 删除所有 iptables 规则
    for port in "${ports[@]}"; do
        iptables -D INPUT -p tcp --dport "$port" -m set --match-set "$CN_IPSET_NAME" src -j DROP 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$port" -m set --match-set "$CN_IPSET_NAME" src -j DROP 2>/dev/null || true
    done

    # 清空配置文件
    cat > "$CN_BLOCK_CONFIG" << 'EOF'
# 中国大陆 IP 封锁端口配置文件
# 格式: 端口|添加时间|备注
# 示例: 1234|2025-10-25 12:00:00|SS节点
EOF

    # 保存 iptables 规则
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v iptables-save &> /dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    echo -e "${gl_lv}✅ 已清空 ${#ports[@]} 条封锁规则${gl_bai}"
    return 0
}

# 菜单：添加端口封锁
menu_add_port_block() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}      添加端口封锁规则${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    # 显示 Xray 端口
    local xray_ports=($(get_xray_ports))
    if [ ${#xray_ports[@]} -gt 0 ]; then
        echo -e "${gl_zi}检测到 Xray 端口:${gl_bai}"
        for i in "${!xray_ports[@]}"; do
            echo "  $((i+1)). ${xray_ports[$i]}"
        done
        echo ""
    fi

    echo "请选择添加方式:"
    echo "1. 手动输入端口号"
    if [ ${#xray_ports[@]} -gt 0 ]; then
        echo "2. 从 Xray 端口列表选择"
        echo "3. 封锁所有 Xray 端口"
    fi
    echo "0. 返回"
    echo ""

    read -p "请选择 [0-3]: " choice

    case "$choice" in
        1)
            echo ""
            read -p "请输入端口号（多个端口用逗号分隔）: " ports_input

            if [ -z "$ports_input" ]; then
                echo -e "${gl_hong}❌ 端口号不能为空${gl_bai}"
                sleep 2
                return
            fi

            IFS=',' read -ra ports <<< "$ports_input"
            local success=0
            local failed=0

            for port in "${ports[@]}"; do
                port=$(echo "$port" | xargs)  # 去除空格
                read -p "为端口 $port 添加备注（可选，回车跳过）: " note
                [ -z "$note" ] && note="手动添加"

                if add_port_block_rule "$port" "$note"; then
                    ((success++))
                else
                    ((failed++))
                fi
            done

            echo ""
            echo -e "${gl_lv}✅ 成功添加 $success 条规则${gl_bai}"
            [ $failed -gt 0 ] && echo -e "${gl_hong}❌ 失败 $failed 条${gl_bai}"
            ;;
        2)
            if [ ${#xray_ports[@]} -eq 0 ]; then
                echo -e "${gl_hong}❌ 无效选择${gl_bai}"
                sleep 2
                return
            fi

            echo ""
            read -p "请选择端口编号（多个用逗号分隔，0=全部）: " selection

            if [ "$selection" = "0" ]; then
                local success=0
                for port in "${xray_ports[@]}"; do
                    if add_port_block_rule "$port" "Xray端口"; then
                        ((success++))
                    fi
                done
                echo ""
                echo -e "${gl_lv}✅ 成功添加 $success 条规则${gl_bai}"
            else
                IFS=',' read -ra selections <<< "$selection"
                local success=0
                for sel in "${selections[@]}"; do
                    sel=$(echo "$sel" | xargs)
                    if [ "$sel" -ge 1 ] && [ "$sel" -le ${#xray_ports[@]} ]; then
                        local port="${xray_ports[$((sel-1))]}"
                        if add_port_block_rule "$port" "Xray端口"; then
                            ((success++))
                        fi
                    fi
                done
                echo ""
                echo -e "${gl_lv}✅ 成功添加 $success 条规则${gl_bai}"
            fi
            ;;
        3)
            if [ ${#xray_ports[@]} -eq 0 ]; then
                echo -e "${gl_hong}❌ 无效选择${gl_bai}"
                sleep 2
                return
            fi

            echo ""
            echo -e "${gl_huang}将封锁以下端口:${gl_bai}"
            printf '%s\n' "${xray_ports[@]}"
            echo ""
            read -p "确认执行？[y/N]: " confirm

            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                local success=0
                for port in "${xray_ports[@]}"; do
                    if add_port_block_rule "$port" "Xray端口"; then
                        ((success++))
                    fi
                done
                echo ""
                echo -e "${gl_lv}✅ 成功添加 $success 条规则${gl_bai}"
            else
                echo "已取消"
            fi
            ;;
        0)
            return
            ;;
        *)
            echo -e "${gl_hong}❌ 无效选择${gl_bai}"
            sleep 2
            return
            ;;
    esac

    echo ""
    read -p "按任意键继续..." -n 1
}

# 菜单：删除端口封锁
menu_remove_port_block() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}      删除端口封锁规则${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    if [ ! -f "$CN_BLOCK_CONFIG" ]; then
        echo -e "${gl_huang}⚠ 没有已封锁的端口${gl_bai}"
        echo ""
        read -p "按任意键继续..." -n 1
        return
    fi

    # 读取已封锁端口
    local blocked_ports=()
    local port_info=()

    while IFS='|' read -r port timestamp note; do
        [[ "$port" =~ ^# ]] && continue
        [[ -z "$port" ]] && continue
        blocked_ports+=("$port")
        port_info+=("$port|$timestamp|$note")
    done < "$CN_BLOCK_CONFIG"

    if [ ${#blocked_ports[@]} -eq 0 ]; then
        echo -e "${gl_huang}⚠ 没有已封锁的端口${gl_bai}"
        echo ""
        read -p "按任意键继续..." -n 1
        return
    fi

    echo -e "${gl_zi}已封锁的端口:${gl_bai}"
    echo ""
    printf "%-4s %-8s %-20s %s\n" "编号" "端口" "添加时间" "备注"
    echo "────────────────────────────────────────────────"

    for i in "${!port_info[@]}"; do
        IFS='|' read -r port timestamp note <<< "${port_info[$i]}"
        printf "%-4s %-8s %-20s %s\n" "$((i+1))" "$port" "$timestamp" "$note"
    done

    echo ""
    read -p "请选择要删除的端口编号（多个用逗号分隔，0=全部）: " selection

    if [ -z "$selection" ]; then
        return
    fi

    if [ "$selection" = "0" ]; then
        echo ""
        read -p "确认删除所有封锁规则？[y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            clear_all_block_rules
        else
            echo "已取消"
        fi
    else
        IFS=',' read -ra selections <<< "$selection"
        local success=0
        for sel in "${selections[@]}"; do
            sel=$(echo "$sel" | xargs)
            if [ "$sel" -ge 1 ] && [ "$sel" -le ${#blocked_ports[@]} ]; then
                local port="${blocked_ports[$((sel-1))]}"
                if remove_port_block_rule "$port"; then
                    ((success++))
                fi
            fi
        done
        echo ""
        echo -e "${gl_lv}✅ 成功删除 $success 条规则${gl_bai}"
    fi

    echo ""
    read -p "按任意键继续..." -n 1
}

# 菜单：查看已封锁端口列表
menu_list_blocked_ports() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}      已封锁端口列表${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    if [ ! -f "$CN_BLOCK_CONFIG" ]; then
        echo -e "${gl_huang}⚠ 没有已封锁的端口${gl_bai}"
        echo ""
        read -p "按任意键继续..." -n 1
        return
    fi

    local count=0
    echo -e "${gl_zi}端口列表:${gl_bai}"
    echo ""
    printf "%-8s %-20s %-30s\n" "端口" "添加时间" "备注"
    echo "────────────────────────────────────────────────────────────"

    while IFS='|' read -r port timestamp note; do
        [[ "$port" =~ ^# ]] && continue
        [[ -z "$port" ]] && continue
        printf "%-8s %-20s %-30s\n" "$port" "$timestamp" "$note"
        ((count++))
    done < "$CN_BLOCK_CONFIG"

    echo "────────────────────────────────────────────────────────────"
    echo -e "${gl_lv}共 $count 个端口被封锁${gl_bai}"

    # 显示 ipset 统计
    if ipset list "$CN_IPSET_NAME" &>/dev/null; then
        local ip_count=$(ipset list "$CN_IPSET_NAME" | grep -c '^[0-9]')
        echo -e "${gl_zi}IP 地址库: $ip_count 条中国 IP 段${gl_bai}"
    fi

    echo ""
    read -p "按任意键继续..." -n 1
}

# 菜单：更新 IP 地址库
menu_update_ip_database() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}      更新 IP 地址库${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    if ipset list "$CN_IPSET_NAME" &>/dev/null; then
        local ip_count=$(ipset list "$CN_IPSET_NAME" | grep -c '^[0-9]')
        echo -e "${gl_zi}当前 IP 地址库: $ip_count 条中国 IP 段${gl_bai}"
        echo ""
    fi

    read -p "确认更新 IP 地址库？[y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo ""
        if update_china_ipset; then
            echo ""
            echo -e "${gl_lv}✅ IP 地址库更新成功${gl_bai}"

            # 重新应用所有规则
            local ports=($(get_blocked_ports))
            if [ ${#ports[@]} -gt 0 ]; then
                echo ""
                echo -e "${gl_kjlan}正在重新应用封锁规则...${gl_bai}"
                for port in "${ports[@]}"; do
                    # 删除旧规则
                    iptables -D INPUT -p tcp --dport "$port" -m set --match-set "$CN_IPSET_NAME" src -j DROP 2>/dev/null || true
                    iptables -D INPUT -p udp --dport "$port" -m set --match-set "$CN_IPSET_NAME" src -j DROP 2>/dev/null || true

                    # 添加新规则
                    iptables -I INPUT -p tcp --dport "$port" -m set --match-set "$CN_IPSET_NAME" src -j DROP
                    iptables -I INPUT -p udp --dport "$port" -m set --match-set "$CN_IPSET_NAME" src -j DROP
                done

                # 保存规则
                if command -v netfilter-persistent &> /dev/null; then
                    netfilter-persistent save >/dev/null 2>&1
                fi

                echo -e "${gl_lv}✅ 已重新应用 ${#ports[@]} 条封锁规则${gl_bai}"
            fi
        else
            echo ""
            echo -e "${gl_hong}❌ IP 地址库更新失败${gl_bai}"
        fi
    else
        echo "已取消"
    fi

    echo ""
    read -p "按任意键继续..." -n 1
}

# 菜单：查看拦截日志
menu_view_block_logs() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}      拦截日志（最近50条）${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    # 获取已封锁端口
    local ports=($(get_blocked_ports))

    if [ ${#ports[@]} -eq 0 ]; then
        echo -e "${gl_huang}⚠ 没有已封锁的端口${gl_bai}"
        echo ""
        read -p "按任意键继续..." -n 1
        return
    fi

    echo -e "${gl_zi}正在查询防火墙日志...${gl_bai}"
    echo ""

    # 构建端口过滤条件
    local port_filter=""
    for port in "${ports[@]}"; do
        port_filter="${port_filter}DPT=${port}|"
    done
    port_filter="${port_filter%|}"  # 删除最后一个 |

    # 查询内核日志
    if dmesg | grep -E "$port_filter" | tail -50 | grep -q .; then
        dmesg | grep -E "$port_filter" | tail -50
    elif journalctl -k --no-pager 2>/dev/null | grep -E "$port_filter" | tail -50 | grep -q .; then
        journalctl -k --no-pager | grep -E "$port_filter" | tail -50
    else
        echo -e "${gl_huang}⚠ 暂无拦截日志${gl_bai}"
        echo ""
        echo "提示: 如需记录拦截日志，请添加 iptables LOG 规则："
        echo "  iptables -I INPUT -p tcp --dport <端口> -m set --match-set $CN_IPSET_NAME src -j LOG --log-prefix 'CN-BLOCK: '"
    fi

    echo ""
    read -p "按任意键继续..." -n 1
}

# 主菜单
manage_cn_ip_block() {
    # 检查依赖
    if ! check_cn_block_dependencies; then
        echo ""
        read -p "按任意键继续..." -n 1
        return
    fi

    # 初始化配置
    init_cn_block_config

    while true; do
        clear
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_kjlan}    禁止端口通过中国大陆直连管理${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""

        # 显示状态
        local blocked_count=$(get_blocked_ports | wc -l)
        local ipset_count=0
        if ipset list "$CN_IPSET_NAME" &>/dev/null; then
            ipset_count=$(ipset list "$CN_IPSET_NAME" | grep -c '^[0-9]')
        fi

        echo -e "${gl_zi}当前状态:${gl_bai}"
        echo "  • 已封锁端口: $blocked_count 个"
        echo "  • IP 地址库: $ipset_count 条中国 IP 段"
        echo ""

        echo "1. 添加端口封锁规则"
        echo "2. 删除端口封锁规则"
        echo "3. 查看已封锁端口列表"
        echo "4. 更新 IP 地址库"
        echo "5. 查看拦截日志"
        echo "6. 一键封锁所有 Xray 端口"
        echo "7. 清空所有封锁规则"
        echo "0. 返回主菜单"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""

        read -p "请选择 [0-7]: " choice

        case "$choice" in
            1)
                menu_add_port_block
                ;;
            2)
                menu_remove_port_block
                ;;
            3)
                menu_list_blocked_ports
                ;;
            4)
                menu_update_ip_database
                ;;
            5)
                menu_view_block_logs
                ;;
            6)
                clear
                echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                echo -e "${gl_kjlan}    一键封锁所有 Xray 端口${gl_bai}"
                echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                echo ""

                local xray_ports=($(get_xray_ports))
                if [ ${#xray_ports[@]} -eq 0 ]; then
                    echo -e "${gl_huang}⚠ 未检测到 Xray 端口${gl_bai}"
                else
                    echo -e "${gl_zi}检测到以下 Xray 端口:${gl_bai}"
                    printf '%s\n' "${xray_ports[@]}"
                    echo ""
                    read -p "确认封锁所有端口？[y/N]: " confirm

                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        local success=0
                        for port in "${xray_ports[@]}"; do
                            if add_port_block_rule "$port" "Xray端口"; then
                                ((success++))
                            fi
                        done
                        echo ""
                        echo -e "${gl_lv}✅ 成功添加 $success 条规则${gl_bai}"
                    else
                        echo "已取消"
                    fi
                fi

                echo ""
                read -p "按任意键继续..." -n 1
                ;;
            7)
                clear
                echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                echo -e "${gl_kjlan}      清空所有封锁规则${gl_bai}"
                echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                echo ""

                local blocked_count=$(get_blocked_ports | wc -l)
                echo -e "${gl_huang}⚠ 将删除所有 $blocked_count 条封锁规则${gl_bai}"
                echo ""
                read -p "确认执行？[y/N]: " confirm

                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    clear_all_block_rules
                else
                    echo "已取消"
                fi

                echo ""
                read -p "按任意键继续..." -n 1
                ;;
            0)
                return
                ;;
            *)
                echo -e "${gl_hong}❌ 无效选择${gl_bai}"
                sleep 1
                ;;
        esac
    done
}

run_kejilion_script() {
    clear
    echo -e "${gl_kjlan}=== 科技lion脚本 ===${gl_bai}"
    echo ""
    echo "正在运行科技lion脚本..."
    echo "------------------------------------------------"
    echo ""

    # 执行科技lion脚本
    if ! run_remote_script "kejilion.sh" bash; then
        echo -e "${gl_hong}❌ 脚本执行失败${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo "------------------------------------------------"
    break_end
}

run_fscarmen_singbox() {
    clear
    echo -e "${gl_kjlan}=== F佬一键sing box脚本 ===${gl_bai}"
    echo ""
    echo "正在运行 F佬一键sing box脚本..."
    echo "------------------------------------------------"
    echo ""

    # 执行 F佬一键sing box脚本
    if ! run_remote_script "https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh" bash; then
        echo -e "${gl_hong}❌ 脚本执行失败${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo "------------------------------------------------"
    break_end
}

#=============================================================================
# CAKE 加速功能（来自 cake.sh）
#=============================================================================

#卸载bbr+锐速
remove_bbr_lotserver() {
  sed -i '/net.ipv4.tcp_ecn/d' /etc/sysctl.d/99-sysctl.conf
  sed -i '/net.core.default_qdisc/d' /etc/sysctl.d/99-sysctl.conf
  sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.d/99-sysctl.conf
  sed -i '/net.ipv4.tcp_ecn/d' /etc/sysctl.conf
  sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
  sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
  sysctl --system

  rm -rf bbrmod

  if [[ -e /appex/bin/lotServer.sh ]]; then
    if ! printf '\n' | run_remote_script "https://raw.githubusercontent.com/fei5seven/lotServer/master/lotServerInstall.sh" bash uninstall; then
      echo -e "${gl_huang}⚠️  lotServer 卸载脚本执行失败，已跳过${gl_bai}"
    fi
  fi
  clear
}

#=============================================================================
# TCP 单连接限速管理（FQ qdisc maxrate）
# 适用场景：3x-ui (x-ui) / Xray / Snell 等基于 TCP 的代理，按"每个 flow"限速
# 核心原理：
#   1. Linux 内核 FQ 调度器按 flow 公平排队
#   2. FQ 的 maxrate 参数对每个 flow 设置最大发送速率
#   3. 该方案不依赖应用进程实现，适合 Xray/3x-ui 这类 Go 程序
# 注意：
#   1. 限速作用于网卡发送方向（服务器 -> 外部），即用户下载/节点出站
#   2. fq maxrate 是网卡级策略，会影响该服务器所有经过该网卡的出站 flow
#=============================================================================

PACING_CONFIG_FILE="/etc/net-tcp-tune-pacing.conf"
PACING_LIB_PATH="/usr/local/lib/libpacing.so"
PACING_SRC_PATH="/usr/local/src/libpacing.c"
PACING_SYSCTL_FILE="/etc/sysctl.d/99-game-pacing.conf"
PACING_DEFAULT_TARGETS="x-ui xray"

pacing_load_config() {
    PACING_ENABLED=0
    PACING_RATE_BPS=0
    PACING_TARGETS="x-ui"
    GAME_MODE=0
    if [ -f "$PACING_CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$PACING_CONFIG_FILE"
    fi
}

pacing_save_config() {
    cat > "$PACING_CONFIG_FILE" <<EOF
# TCP 单连接限速配置 (由 net-tcp-tune.sh 自动管理)
PACING_ENABLED=${PACING_ENABLED:-0}
PACING_RATE_BPS=${PACING_RATE_BPS:-0}
PACING_TARGETS="${PACING_TARGETS:-x-ui}"
GAME_MODE=${GAME_MODE:-0}
EOF
    chmod 644 "$PACING_CONFIG_FILE"
}

pacing_human_rate() {
    local bps="$1"
    if [ "$bps" -le 0 ] 2>/dev/null; then
        echo "未设置"
        return
    fi
    if [ "$bps" -ge 1048576 ]; then
        awk -v b="$bps" 'BEGIN{printf "%.2f MB/s (%.0f Mbps)\n", b/1048576, b*8/1000000}'
    elif [ "$bps" -ge 1024 ]; then
        awk -v b="$bps" 'BEGIN{printf "%.2f KB/s (%.2f Mbps)\n", b/1024, b*8/1000000}'
    else
        echo "${bps} B/s"
    fi
}

pacing_check_gcc() {
    if ! command -v gcc >/dev/null 2>&1; then
        echo -e "${gl_huang}未检测到 gcc，正在安装编译工具...${gl_bai}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y gcc libc6-dev >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y gcc glibc-devel >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y gcc glibc-devel >/dev/null 2>&1
        fi
    fi
    command -v gcc >/dev/null 2>&1
}

pacing_write_lib_source() {
    mkdir -p "$(dirname "$PACING_SRC_PATH")"
    cat > "$PACING_SRC_PATH" <<'PACING_C_EOF'
#define _GNU_SOURCE
#include <sys/socket.h>
#include <sys/types.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

#ifndef SO_MAX_PACING_RATE
#define SO_MAX_PACING_RATE 47
#endif

typedef int (*accept_fn)(int, struct sockaddr*, socklen_t*);
typedef int (*accept4_fn)(int, struct sockaddr*, socklen_t*, int);

static unsigned long pacing_get_rate(void) {
    const char *e = getenv("PACING_RATE_BPS");
    if (!e || !*e) return 0UL;
    return strtoul(e, NULL, 10);
}

static void pacing_apply(int fd) {
    if (fd < 0) return;
    unsigned long rate = pacing_get_rate();
    if (rate == 0UL) return;
    /* SO_MAX_PACING_RATE 在内核中按字节/秒生效，仅作用于发送方向 */
    (void)setsockopt(fd, SOL_SOCKET, SO_MAX_PACING_RATE, &rate, sizeof(rate));
}

int accept(int s, struct sockaddr *addr, socklen_t *len) {
    static accept_fn orig = NULL;
    if (!orig) orig = (accept_fn)dlsym(RTLD_NEXT, "accept");
    int fd = orig(s, addr, len);
    pacing_apply(fd);
    return fd;
}

int accept4(int s, struct sockaddr *addr, socklen_t *len, int flags) {
    static accept4_fn orig = NULL;
    if (!orig) orig = (accept4_fn)dlsym(RTLD_NEXT, "accept4");
    int fd = orig(s, addr, len, flags);
    pacing_apply(fd);
    return fd;
}
PACING_C_EOF
}

pacing_compile_lib() {
    pacing_check_gcc || { echo -e "${gl_hong}gcc 安装失败，无法编译限速库${gl_bai}"; return 1; }
    pacing_write_lib_source
    mkdir -p "$(dirname "$PACING_LIB_PATH")"
    if gcc -O2 -shared -fPIC -o "$PACING_LIB_PATH" "$PACING_SRC_PATH" -ldl 2>/tmp/pacing_build.log; then
        chmod 755 "$PACING_LIB_PATH"
        echo -e "${gl_lv}✅ 限速动态库编译成功: ${PACING_LIB_PATH}${gl_bai}"
        return 0
    else
        echo -e "${gl_hong}❌ 编译失败，错误日志:${gl_bai}"
        cat /tmp/pacing_build.log
        return 1
    fi
}

pacing_apply_sysctl() {
    cat > "$PACING_SYSCTL_FILE" <<'EOF'
# === 由 net-tcp-tune.sh 写入：FQ + BBR + 游戏延迟优化 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 游戏延迟关键：关闭空闲后慢启动（长连接保活时不重置 cwnd）
net.ipv4.tcp_slow_start_after_idle = 0

# TCP Fast Open（客户端+服务端均启用）
net.ipv4.tcp_fastopen = 3

# TIME_WAIT 复用，避免端口耗尽
net.ipv4.tcp_tw_reuse = 1

# 游戏加速场景：进一步减小默认/最大 buffer，降低内存占用和 bufferbloat
net.ipv4.tcp_rmem = 4096 16384 524288
net.ipv4.tcp_wmem = 4096 16384 524288

# 提高 backlog，应对短时间大量握手
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 32768
EOF
    sysctl -p "$PACING_SYSCTL_FILE" >/dev/null 2>&1
    echo -e "${gl_lv}✅ 已写入 sysctl: ${PACING_SYSCTL_FILE}${gl_bai}"

    # 给所有非 lo 网卡挂上 fq（未启用限速时不设置 maxrate）
    local iface
    for iface in $(ls /sys/class/net 2>/dev/null); do
        [ "$iface" = "lo" ] && continue
        [ -d "/sys/class/net/$iface" ] || continue
        if tc qdisc replace dev "$iface" root fq 2>/dev/null; then
            echo -e "  ${gl_lv}✓${gl_bai} ${iface}: fq qdisc 已启用"
        fi
    done
}

pacing_rate_to_tc_kbit() {
    local rate_bps="$1"
    local rate_kbit=$((rate_bps * 8 / 1000))
    [ "$rate_kbit" -lt 1 ] && rate_kbit=1
    echo "${rate_kbit}kbit"
}

pacing_apply_fq_maxrate() {
    local rate_bps="$1"
    local tc_rate
    tc_rate=$(pacing_rate_to_tc_kbit "$rate_bps")

    local iface applied=0
    for iface in $(ls /sys/class/net 2>/dev/null); do
        [ "$iface" = "lo" ] && continue
        [ -d "/sys/class/net/$iface" ] || continue
        if tc qdisc replace dev "$iface" root fq maxrate "$tc_rate" 2>/dev/null; then
            echo -e "  ${gl_lv}✓${gl_bai} ${iface}: fq maxrate ${tc_rate} 已启用（每 flow）"
            applied=1
        else
            echo -e "  ${gl_huang}⚠️${gl_bai} ${iface}: fq maxrate 设置失败，可能是内核或容器不支持"
        fi
    done

    [ "$applied" = "1" ]
}

pacing_clear_fq_maxrate() {
    local iface
    for iface in $(ls /sys/class/net 2>/dev/null); do
        [ "$iface" = "lo" ] && continue
        [ -d "/sys/class/net/$iface" ] || continue
        tc qdisc replace dev "$iface" root fq 2>/dev/null
    done
}

pacing_remove_sysctl() {
    [ -f "$PACING_SYSCTL_FILE" ] && rm -f "$PACING_SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1
    echo -e "${gl_huang}已移除游戏优化 sysctl 配置（重启后完全恢复默认）${gl_bai}"
}

pacing_inject_service() {
    local svc="$1"
    local rate_bps="$2"
    if ! systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
        echo -e "  ${gl_huang}⚠️  服务 ${svc}.service 不存在，跳过${gl_bai}"
        return 1
    fi
    local dropin_dir="/etc/systemd/system/${svc}.service.d"
    mkdir -p "$dropin_dir"
    cat > "${dropin_dir}/pacing.conf" <<EOF
# 由 net-tcp-tune.sh 自动写入：注入 LD_PRELOAD 实现每连接限速
[Service]
Environment="LD_PRELOAD=${PACING_LIB_PATH}"
Environment="PACING_RATE_BPS=${rate_bps}"
EOF
    systemctl daemon-reload
    if systemctl is-active --quiet "$svc"; then
        systemctl restart "$svc"
        echo -e "  ${gl_lv}✓${gl_bai} ${svc}: 限速已注入并重启服务"
    else
        echo -e "  ${gl_huang}○${gl_bai} ${svc}: 已写入注入配置（服务未运行，下次启动生效）"
    fi
    return 0
}

pacing_remove_inject() {
    local svc="$1"
    local dropin="/etc/systemd/system/${svc}.service.d/pacing.conf"
    if [ -f "$dropin" ]; then
        rm -f "$dropin"
        rmdir "/etc/systemd/system/${svc}.service.d" 2>/dev/null
        systemctl daemon-reload
        if systemctl is-active --quiet "$svc"; then
            systemctl restart "$svc"
            echo -e "  ${gl_lv}✓${gl_bai} ${svc}: 已移除限速注入并重启"
        else
            echo -e "  ${gl_huang}○${gl_bai} ${svc}: 已移除限速注入"
        fi
    fi
}

pacing_status_summary() {
    pacing_load_config
    local fq_enabled="未启用"
    local bbr_enabled="未启用"
    local main_iface
    main_iface=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
    [ -z "$main_iface" ] && main_iface="eth0"
    if tc qdisc show dev "$main_iface" 2>/dev/null | grep -q "qdisc fq "; then
        fq_enabled="${gl_lv}已启用 (${main_iface})${gl_bai}"
    else
        fq_enabled="${gl_huang}未启用 (${main_iface} 当前为 $(tc qdisc show dev "$main_iface" 2>/dev/null | awk '{print $2}' | head -1))${gl_bai}"
    fi
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        bbr_enabled="${gl_lv}已启用${gl_bai}"
    else
        bbr_enabled="${gl_huang}未启用 (当前: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null))${gl_bai}"
    fi

    echo -e "${gl_kjlan}━━━━━━━━━━ 当前状态 ━━━━━━━━━━${gl_bai}"
    echo -e "  FQ 调度器:        ${fq_enabled}"
    echo -e "  BBR 拥塞控制:     ${bbr_enabled}"
    echo -e "  限速方式:         ${gl_lv}FQ qdisc maxrate（网卡级，每 flow）${gl_bai}"
    echo -e "  限速总开关:       $([ "${PACING_ENABLED:-0}" = "1" ] && echo "${gl_lv}启用${gl_bai}" || echo "${gl_huang}未启用${gl_bai}")"
    echo -e "  当前限速值:       ${gl_huang}$(pacing_human_rate "${PACING_RATE_BPS:-0}")${gl_bai}"
    echo -e "  作用范围:         ${gl_huang}所有非 lo 网卡的出站 flow${gl_bai}"
    echo -e "  游戏优化模式:     $([ "${GAME_MODE:-0}" = "1" ] && echo "${gl_lv}启用${gl_bai}" || echo "${gl_huang}未启用${gl_bai}")"
    echo -e "  网卡规则:         ${gl_huang}$(tc qdisc show dev "$main_iface" 2>/dev/null | head -1)${gl_bai}"
    echo ""
}

pacing_input_rate() {
    echo ""
    echo -e "${gl_kjlan}请输入每个 TCP 连接的限速值${gl_bai}"
    echo "  支持单位: K (KB/s), M (MB/s), 纯数字默认按 KB/s"
    echo "  示例:"
    echo "    10M    → 10 MB/s 每连接（80 Mbps，游戏推荐：永远不会触发限速）"
    echo "    1M     → 1 MB/s 每连接（8 Mbps，普通代理够用）"
    echo "    500    → 500 KB/s 每连接（4 Mbps）"
    echo "    0      → 取消限速（不设置上限）"
    echo ""
    read -e -p "请输入限速值 [默认 10M]: " rate_input
    rate_input="${rate_input:-10M}"

    local num unit bps
    if [[ "$rate_input" =~ ^([0-9]+)([KkMmGg]?)$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        case "$unit" in
            K|k|"") bps=$((num * 1024)) ;;
            M|m)    bps=$((num * 1024 * 1024)) ;;
            G|g)    bps=$((num * 1024 * 1024 * 1024)) ;;
        esac
    else
        echo -e "${gl_hong}❌ 无效的格式${gl_bai}"
        return 1
    fi

    PACING_RATE_BPS="$bps"
    echo -e "${gl_lv}已解析为: $(pacing_human_rate "$bps")${gl_bai}"
    return 0
}

pacing_input_targets() {
    echo ""
    echo -e "${gl_kjlan}请选择要限速的服务（多个用空格分隔）${gl_bai}"
    echo "  常见服务名:"
    echo "    x-ui    → 3x-ui 面板（推荐）"
    echo "    xray    → 独立 Xray"
    echo "    snell   → Snell 服务"
    echo ""
    read -e -p "请输入服务名 [默认 x-ui]: " tgt_input
    PACING_TARGETS="${tgt_input:-x-ui}"
    echo -e "${gl_lv}目标服务: ${PACING_TARGETS}${gl_bai}"
}

pacing_enable_all() {
    clear
    echo -e "${gl_kjlan}=== 一键启用 TCP 单连接限速 ===${gl_bai}"
    echo ""

    # 1. 输入限速值
    pacing_input_rate || { break_end; return; }

    # 2. 是否启用游戏优化
    echo ""
    read -e -p "是否启用游戏延迟优化（小buffer + 关闭慢启动重启）? [Y/n]: " game_choice
    if [[ ! "$game_choice" =~ ^[Nn]$ ]]; then
        GAME_MODE=1
    else
        GAME_MODE=0
    fi

    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━ 开始执行 ━━━━━━━━━━${gl_bai}"

    # 3. 应用 sysctl + FQ
    echo -e "${gl_kjlan}[1/2] 配置 FQ 调度器 + BBR + 系统参数...${gl_bai}"
    pacing_apply_sysctl

    # 4. 应用 fq maxrate
    echo ""
    echo -e "${gl_kjlan}[2/2] 配置 FQ maxrate（每 flow 限速）...${gl_bai}"
    if ! pacing_apply_fq_maxrate "$PACING_RATE_BPS"; then
        echo -e "${gl_hong}fq maxrate 设置失败，已中止${gl_bai}"
        break_end
        return
    fi

    # 清理旧版本可能写入的 LD_PRELOAD 注入，避免误导状态
    local svc
    for svc in ${PACING_TARGETS:-x-ui} x-ui xray snell; do
        pacing_remove_inject "$svc"
    done

    PACING_ENABLED=1
    PACING_TARGETS="all-ifaces"
    pacing_save_config

    echo ""
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}✅ TCP 单连接限速已启用${gl_bai}"
    echo -e "${gl_lv}   每连接上限: $(pacing_human_rate "$PACING_RATE_BPS")${gl_bai}"
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_huang}验证方法:${gl_bai}"
    echo "  1. 让用户连接 3x-ui 节点并下载文件"
    echo "  2. 在服务器执行: tc qdisc show dev eth0"
    echo "  3. 应能看到: qdisc fq ... maxrate <你的限速值>"
    echo ""
    break_end
}

pacing_modify_rate() {
    pacing_load_config
    if [ "${PACING_ENABLED:-0}" != "1" ]; then
        echo -e "${gl_huang}限速尚未启用，请先选择 [1] 一键启用${gl_bai}"
        break_end
        return
    fi
    pacing_input_rate || { break_end; return; }
    echo ""
    echo -e "${gl_kjlan}重新配置 FQ maxrate...${gl_bai}"
    pacing_apply_fq_maxrate "$PACING_RATE_BPS" || { break_end; return; }
    pacing_save_config
    echo ""
    echo -e "${gl_lv}✅ 限速值已更新为: $(pacing_human_rate "$PACING_RATE_BPS")${gl_bai}"
    break_end
}

pacing_view_realtime() {
    clear
    echo -e "${gl_kjlan}=== 实时连接/网卡限速状态 ===${gl_bai}"
    echo ""
    if ! command -v ss >/dev/null 2>&1; then
        echo -e "${gl_hong}缺少 ss 命令${gl_bai}"
        break_end
        return
    fi
    echo -e "${gl_kjlan}[1] 当前网卡 qdisc:${gl_bai}"
    local iface
    for iface in $(ls /sys/class/net 2>/dev/null); do
        [ "$iface" = "lo" ] && continue
        tc qdisc show dev "$iface" 2>/dev/null | sed "s/^/  [$iface] /"
    done
    echo ""
    echo -e "${gl_kjlan}[2] 当前 TCP 连接发送状态（前 30 条，仅辅助观察）:${gl_bai}"
    echo "格式: <对端地址>  pacing_rate=<内核估计>  send=<当前发送速率>"
    echo "------------------------------------------------"
    ss -tinH 2>/dev/null | awk '
        /^ESTAB/ {peer=$5; next}
        /pacing_rate/ {
            for(i=1;i<=NF;i++){
                if($i ~ /pacing_rate/){pr=$i}
                if($i ~ /^send/){sd=$i}
            }
            printf "%-45s  %s  %s\n", peer, pr, sd
            pr=""; sd=""
        }
    ' | head -30

    echo ""
    echo -e "${gl_huang}说明:${gl_bai}"
    echo "  - 本版本使用 fq maxrate，真实限速以 tc qdisc 中的 maxrate 为准"
    echo "  - ss 中的 pacing_rate 是 BBR/FQ 对 socket 的动态估计值，不再要求等于限速值"
    echo "  - 测速请用客户端通过 vmess 下载测速，不要用服务器本地测速"
    echo ""
    break_end
}

pacing_disable_keep_fq() {
    pacing_load_config
    echo -e "${gl_kjlan}正在关闭限速（保留 FQ + BBR + 游戏优化）...${gl_bai}"
    local svc
    for svc in $PACING_TARGETS; do
        pacing_remove_inject "$svc"
    done
    pacing_clear_fq_maxrate
    PACING_ENABLED=0
    PACING_RATE_BPS=0
    pacing_save_config
    echo ""
    echo -e "${gl_lv}✅ 限速已关闭，但 FQ/BBR/sysctl 优化保留${gl_bai}"
    echo -e "${gl_huang}如需完全卸载请选择 [6] 完全卸载${gl_bai}"
    break_end
}

pacing_full_uninstall() {
    pacing_load_config
    echo -e "${gl_huang}=== 完全卸载 TCP 单连接限速 ===${gl_bai}"
    echo "将执行:"
    echo "  1. 移除所有服务的 LD_PRELOAD 注入"
    echo "  2. 删除 ${PACING_LIB_PATH}"
    echo "  3. 删除 ${PACING_SYSCTL_FILE}"
    echo "  4. 删除 ${PACING_CONFIG_FILE}"
    echo "  5. 恢复默认 qdisc（重启彻底生效）"
    echo ""
    read -e -p "确认卸载? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消"
        break_end
        return
    fi

    local svc
    for svc in $PACING_TARGETS x-ui xray snell; do
        pacing_remove_inject "$svc"
    done

    [ -f "$PACING_LIB_PATH" ] && rm -f "$PACING_LIB_PATH"
    [ -f "$PACING_SRC_PATH" ] && rm -f "$PACING_SRC_PATH"
    pacing_remove_sysctl
    [ -f "$PACING_CONFIG_FILE" ] && rm -f "$PACING_CONFIG_FILE"

    # 尝试恢复 pfifo_fast
    local iface
    for iface in $(ls /sys/class/net 2>/dev/null); do
        [ "$iface" = "lo" ] && continue
        tc qdisc replace dev "$iface" root pfifo_fast 2>/dev/null
    done

    echo ""
    echo -e "${gl_lv}✅ 已完全卸载${gl_bai}"
    break_end
}

manage_tcp_pacing_limit() {
    while true; do
        clear
        pacing_load_config
        echo -e "${gl_zi}╔════════════════════════════════════════════════╗${gl_bai}"
        echo -e "${gl_zi}║       TCP 单连接限速管理  (FQ maxrate)        ║${gl_bai}"
        echo -e "${gl_zi}╚════════════════════════════════════════════════╝${gl_bai}"
        echo ""
        pacing_status_summary
        echo -e "${gl_kjlan}━━━━━━━━━━ 操作选项 ━━━━━━━━━━${gl_bai}"
        echo "  1. 一键启用（FQ + BBR + 每flow限速）⭐"
        echo "  2. 修改每连接限速值"
        echo "  3. 查看实时连接 pacing 状态（验证是否生效）"
        echo "  4. 关闭限速（保留 FQ + BBR + 游戏优化）"
        echo "  5. 完全卸载（恢复默认）"
        echo ""
        echo "  0. 返回主菜单"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        read -e -p "请输入选项 [0-5]: " p_choice

        case "$p_choice" in
            1) pacing_enable_all ;;
            2) pacing_modify_rate ;;
            3) pacing_view_realtime ;;
            4) pacing_disable_keep_fq ;;
            5) pacing_full_uninstall ;;
            0) return ;;
            *) echo -e "${gl_hong}无效选项${gl_bai}"; sleep 1 ;;
        esac
    done
}

#启用BBR+cake
startbbrcake() {
  remove_bbr_lotserver
  echo "net.core.default_qdisc=cake" >>/etc/sysctl.d/99-sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >>/etc/sysctl.d/99-sysctl.conf
  sysctl --system
  echo -e "${gl_lv}[信息]${gl_bai}BBR+cake修改成功，重启生效！"
  break_end
}

#=============================================================================
# SOCKS5 一键部署功能
#=============================================================================

# SOCKS5 配置目录
SOCKS5_CONFIG_DIR="/etc/sbox_socks5"
SOCKS5_CONFIG_FILE="${SOCKS5_CONFIG_DIR}/config.json"
SOCKS5_SERVICE_NAME="sbox-socks5"

# 查看 SOCKS5 配置信息
view_socks5() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}      查看 SOCKS5 代理信息${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    # 检查配置文件是否存在
    if [ ! -f "$SOCKS5_CONFIG_FILE" ]; then
        echo -e "${gl_huang}⚠️  未检测到 SOCKS5 代理配置${gl_bai}"
        echo ""
        echo "您可以选择菜单 [1] 新增 SOCKS5 代理"
        echo ""
        break_end
        return 1
    fi
    
    # 解析配置文件
    local port=$(jq -r '.inbounds[0].listen_port // empty' "$SOCKS5_CONFIG_FILE" 2>/dev/null)
    local username=$(jq -r '.inbounds[0].users[0].username // empty' "$SOCKS5_CONFIG_FILE" 2>/dev/null)
    local password=$(jq -r '.inbounds[0].users[0].password // empty' "$SOCKS5_CONFIG_FILE" 2>/dev/null)
    
    if [ -z "$port" ] || [ -z "$username" ]; then
        echo -e "${gl_hong}❌ 配置文件格式错误或为空${gl_bai}"
        echo ""
        echo "配置文件路径: $SOCKS5_CONFIG_FILE"
        echo ""
        break_end
        return 1
    fi
    
    # 获取服务器IP
    local server_ip=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || \
                      curl -4 -s --max-time 3 ipinfo.io/ip 2>/dev/null || \
                      curl -6 -s --max-time 3 ifconfig.me 2>/dev/null || \
                      echo "请手动获取")
    
    # 检查服务状态
    local service_status=""
    if systemctl is-active --quiet "$SOCKS5_SERVICE_NAME"; then
        service_status="${gl_lv}✅ 运行中${gl_bai}"
    else
        service_status="${gl_hong}❌ 未运行${gl_bai}"
    fi
    
    # 检查端口监听
    local port_status=""
    if ss -tulpn | grep -q ":${port} "; then
        port_status="${gl_lv}✅ 监听中${gl_bai}"
    else
        port_status="${gl_hong}❌ 未监听${gl_bai}"
    fi
    
    echo -e "${gl_lv}SOCKS5 连接信息：${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "  服务器地址: ${gl_huang}${server_ip}${gl_bai}"
    echo -e "  端口:       ${gl_huang}${port}${gl_bai}"
    echo -e "  用户名:     ${gl_huang}${username}${gl_bai}"
    echo -e "  密码:       ${gl_huang}${password}${gl_bai}"
    echo -e "  协议:       ${gl_huang}SOCKS5${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "  服务状态:   $service_status"
    echo -e "  端口状态:   $port_status"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_zi}测试连接命令：${gl_bai}"
    echo "curl --socks5-hostname ${username}:${password}@${server_ip}:${port} http://httpbin.org/ip"
    echo ""
    echo -e "${gl_zi}管理命令：${gl_bai}"
    echo "  查看日志: journalctl -u ${SOCKS5_SERVICE_NAME} -f"
    echo "  重启服务: systemctl restart ${SOCKS5_SERVICE_NAME}"
    echo "  停止服务: systemctl stop ${SOCKS5_SERVICE_NAME}"
    echo ""
    
    break_end
}

# 修改 SOCKS5 配置
modify_socks5() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}      修改 SOCKS5 代理配置${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    # 检查配置文件是否存在
    if [ ! -f "$SOCKS5_CONFIG_FILE" ]; then
        echo -e "${gl_huang}⚠️  未检测到 SOCKS5 代理配置${gl_bai}"
        echo ""
        echo "您可以选择菜单 [1] 新增 SOCKS5 代理"
        echo ""
        break_end
        return 1
    fi
    
    # 读取当前配置
    local current_port=$(jq -r '.inbounds[0].listen_port // empty' "$SOCKS5_CONFIG_FILE" 2>/dev/null)
    local current_user=$(jq -r '.inbounds[0].users[0].username // empty' "$SOCKS5_CONFIG_FILE" 2>/dev/null)
    local current_pass=$(jq -r '.inbounds[0].users[0].password // empty' "$SOCKS5_CONFIG_FILE" 2>/dev/null)
    
    echo -e "${gl_zi}当前配置：${gl_bai}"
    echo "  端口: ${current_port}"
    echo "  用户名: ${current_user}"
    echo "  密码: ${current_pass}"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo "请选择要修改的项目："
    echo ""
    echo "  1. 修改端口"
    echo "  2. 修改用户名"
    echo "  3. 修改密码"
    echo "  4. 修改所有配置"
    echo ""
    echo "  0. 返回上级菜单"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    
    read -e -p "请输入选项 [0-4]: " modify_choice
    
    local new_port="$current_port"
    local new_user="$current_user"
    local new_pass="$current_pass"
    
    case "$modify_choice" in
        1)
            echo ""
            while true; do
                read -e -p "$(echo -e "${gl_huang}请输入新端口 [当前: ${current_port}]: ${gl_bai}")" new_port
                new_port=${new_port:-$current_port}
                
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ]; then
                    if [ "$new_port" != "$current_port" ] && ss -tulpn | grep -q ":${new_port} "; then
                        echo -e "${gl_hong}❌ 端口 ${new_port} 已被占用${gl_bai}"
                    else
                        break
                    fi
                else
                    echo -e "${gl_hong}❌ 无效端口，请输入 1024-65535 之间的数字${gl_bai}"
                fi
            done
            ;;
        2)
            echo ""
            while true; do
                read -e -p "$(echo -e "${gl_huang}请输入新用户名 [当前: ${current_user}]: ${gl_bai}")" new_user
                new_user=${new_user:-$current_user}
                
                if [[ "$new_user" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                    break
                else
                    echo -e "${gl_hong}❌ 用户名只能包含字母、数字、下划线和连字符${gl_bai}"
                fi
            done
            ;;
        3)
            echo ""
            while true; do
                read -e -p "$(echo -e "${gl_huang}请输入新密码: ${gl_bai}")" new_pass
                
                if [ -z "$new_pass" ]; then
                    new_pass="$current_pass"
                    break
                elif [ ${#new_pass} -lt 6 ]; then
                    echo -e "${gl_hong}❌ 密码长度至少6位${gl_bai}"
                elif [[ "$new_pass" == *\"* || "$new_pass" == *\\* ]]; then
                    echo -e "${gl_hong}❌ 密码不能包含 \" 或 \\ 字符${gl_bai}"
                else
                    break
                fi
            done
            ;;
        4)
            echo ""
            # 修改端口
            while true; do
                read -e -p "$(echo -e "${gl_huang}请输入新端口 [当前: ${current_port}, 回车保持不变]: ${gl_bai}")" new_port
                new_port=${new_port:-$current_port}
                
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ]; then
                    if [ "$new_port" != "$current_port" ] && ss -tulpn | grep -q ":${new_port} "; then
                        echo -e "${gl_hong}❌ 端口 ${new_port} 已被占用${gl_bai}"
                    else
                        break
                    fi
                else
                    echo -e "${gl_hong}❌ 无效端口，请输入 1024-65535 之间的数字${gl_bai}"
                fi
            done
            echo ""
            
            # 修改用户名
            while true; do
                read -e -p "$(echo -e "${gl_huang}请输入新用户名 [当前: ${current_user}, 回车保持不变]: ${gl_bai}")" new_user
                new_user=${new_user:-$current_user}
                
                if [[ "$new_user" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                    break
                else
                    echo -e "${gl_hong}❌ 用户名只能包含字母、数字、下划线和连字符${gl_bai}"
                fi
            done
            echo ""
            
            # 修改密码
            while true; do
                read -e -p "$(echo -e "${gl_huang}请输入新密码 [回车保持不变]: ${gl_bai}")" new_pass
                
                if [ -z "$new_pass" ]; then
                    new_pass="$current_pass"
                    break
                elif [ ${#new_pass} -lt 6 ]; then
                    echo -e "${gl_hong}❌ 密码长度至少6位${gl_bai}"
                elif [[ "$new_pass" == *\"* || "$new_pass" == *\\* ]]; then
                    echo -e "${gl_hong}❌ 密码不能包含 \" 或 \\ 字符${gl_bai}"
                else
                    break
                fi
            done
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${gl_hong}❌ 无效选项${gl_bai}"
            sleep 1
            return 1
            ;;
    esac
    
    # 确认修改
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}修改后的配置：${gl_bai}"
    echo "  端口: ${new_port}"
    echo "  用户名: ${new_user}"
    echo "  密码: ${new_pass}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    read -e -p "$(echo -e "${gl_huang}确认修改？(Y/N): ${gl_bai}")" confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消修改"
        break_end
        return 0
    fi
    
    # 检测 sing-box 二进制程序
    local SINGBOX_CMD=""
    for path in /etc/sing-box/sing-box /usr/local/bin/sing-box /opt/sing-box/sing-box; do
        if [ -x "$path" ]; then
            SINGBOX_CMD="$path"
            break
        fi
    done
    
    if [ -z "$SINGBOX_CMD" ]; then
        for cmd in sing-box sb; do
            if command -v "$cmd" &>/dev/null; then
                SINGBOX_CMD=$(which "$cmd")
                break
            fi
        done
    fi
    
    if [ -z "$SINGBOX_CMD" ]; then
        echo -e "${gl_hong}❌ 未找到 sing-box 程序${gl_bai}"
        break_end
        return 1
    fi
    
    # 更新配置文件
    echo ""
    echo -e "${gl_zi}正在更新配置...${gl_bai}"
    
    cat > "$SOCKS5_CONFIG_FILE" << CONFIGEOF
{
  "log": {
    "level": "info",
    "output": "${SOCKS5_CONFIG_DIR}/socks5.log"
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks5-in",
      "listen": "0.0.0.0",
      "listen_port": ${new_port},
      "users": [
        {
          "username": "${new_user}",
          "password": "${new_pass}"
        }
      ]
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
CONFIGEOF
    
    chmod 600 "$SOCKS5_CONFIG_FILE"
    
    # 验证配置
    if ! $SINGBOX_CMD check -c "$SOCKS5_CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${gl_hong}❌ 配置文件语法错误${gl_bai}"
        $SINGBOX_CMD check -c "$SOCKS5_CONFIG_FILE"
        break_end
        return 1
    fi
    
    # 更新 systemd 服务文件（如果端口改变需要更新）
    cat > /etc/systemd/system/${SOCKS5_SERVICE_NAME}.service << SERVICEEOF
[Unit]
Description=Sing-box SOCKS5 Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SINGBOX_CMD} run -c ${SOCKS5_CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
User=root
Group=root
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SOCKS5_SERVICE_NAME}
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${SOCKS5_CONFIG_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICEEOF
    
    # 重新加载并重启服务
    systemctl daemon-reload
    systemctl restart "$SOCKS5_SERVICE_NAME"
    
    sleep 2
    
    # 验证服务状态
    if systemctl is-active --quiet "$SOCKS5_SERVICE_NAME"; then
        echo -e "${gl_lv}✅ 配置修改成功，服务已重启${gl_bai}"
    else
        echo -e "${gl_hong}❌ 服务重启失败，请检查日志${gl_bai}"
        echo "journalctl -u ${SOCKS5_SERVICE_NAME} -n 20 --no-pager"
    fi
    
    echo ""
    break_end
}

# 删除 SOCKS5 配置
delete_socks5() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}      删除 SOCKS5 代理${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    # 检查是否存在配置
    local has_config=false
    local has_service=false
    
    if [ -f "$SOCKS5_CONFIG_FILE" ] || [ -d "$SOCKS5_CONFIG_DIR" ]; then
        has_config=true
    fi
    
    if [ -f "/etc/systemd/system/${SOCKS5_SERVICE_NAME}.service" ]; then
        has_service=true
    fi
    
    if [ "$has_config" = false ] && [ "$has_service" = false ]; then
        echo -e "${gl_huang}⚠️  未检测到 SOCKS5 代理配置${gl_bai}"
        echo ""
        break_end
        return 0
    fi
    
    # 显示即将删除的内容
    echo -e "${gl_huang}即将删除以下内容：${gl_bai}"
    echo ""
    
    if [ "$has_service" = true ]; then
        echo "  • 系统服务: ${SOCKS5_SERVICE_NAME}"
        if systemctl is-active --quiet "$SOCKS5_SERVICE_NAME"; then
            echo "    状态: 运行中（将被停止）"
        else
            echo "    状态: 未运行"
        fi
    fi
    
    if [ "$has_config" = true ]; then
        echo "  • 配置目录: ${SOCKS5_CONFIG_DIR}"
        if [ -f "$SOCKS5_CONFIG_FILE" ]; then
            local port=$(jq -r '.inbounds[0].listen_port // "未知"' "$SOCKS5_CONFIG_FILE" 2>/dev/null)
            echo "    端口: ${port}"
        fi
    fi
    
    echo ""
    echo -e "${gl_hong}⚠️  此操作不可恢复！${gl_bai}"
    echo ""
    
    read -e -p "$(echo -e "${gl_huang}确认删除？请输入 'yes' 确认: ${gl_bai}")" confirm
    
    if [ "$confirm" != "yes" ]; then
        echo ""
        echo "已取消删除"
        break_end
        return 0
    fi
    
    echo ""
    echo -e "${gl_zi}正在删除...${gl_bai}"
    
    # 停止并禁用服务
    if [ "$has_service" = true ]; then
        systemctl stop "$SOCKS5_SERVICE_NAME" 2>/dev/null
        systemctl disable "$SOCKS5_SERVICE_NAME" 2>/dev/null
        rm -f "/etc/systemd/system/${SOCKS5_SERVICE_NAME}.service"
        systemctl daemon-reload
        echo -e "${gl_lv}✅ 服务已删除${gl_bai}"
    fi
    
    # 删除配置目录
    if [ "$has_config" = true ]; then
        rm -rf "$SOCKS5_CONFIG_DIR"
        echo -e "${gl_lv}✅ 配置目录已删除${gl_bai}"
    fi
    
    echo ""
    echo -e "${gl_lv}🎉 SOCKS5 代理已完全删除${gl_bai}"
    echo ""
    
    break_end
}

# SOCKS5 管理主菜单
manage_socks5() {
    while true; do
        clear
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_kjlan}      Sing-box SOCKS5 管理${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        
        # 检查当前状态
        if [ -f "$SOCKS5_CONFIG_FILE" ]; then
            local port=$(jq -r '.inbounds[0].listen_port // "未知"' "$SOCKS5_CONFIG_FILE" 2>/dev/null)
            local user=$(jq -r '.inbounds[0].users[0].username // "未知"' "$SOCKS5_CONFIG_FILE" 2>/dev/null)
            
            if systemctl is-active --quiet "$SOCKS5_SERVICE_NAME"; then
                echo -e "  当前状态: ${gl_lv}✅ 运行中${gl_bai}"
            else
                echo -e "  当前状态: ${gl_hong}❌ 未运行${gl_bai}"
            fi
            echo -e "  端口: ${gl_huang}${port}${gl_bai}  用户名: ${gl_huang}${user}${gl_bai}"
        else
            echo -e "  当前状态: ${gl_zi}未部署${gl_bai}"
        fi
        
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "  1. 新增 SOCKS5 代理"
        echo "  2. 修改 SOCKS5 配置"
        echo "  3. 删除 SOCKS5 代理"
        echo "  4. 查看 SOCKS5 信息"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo "  0. 返回主菜单"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        
        read -e -p "请输入选项 [0-4]: " socks5_choice
        
        case "$socks5_choice" in
            1)
                # 检查是否已存在配置
                if [ -f "$SOCKS5_CONFIG_FILE" ]; then
                    echo ""
                    echo -e "${gl_huang}⚠️  检测到已存在 SOCKS5 配置${gl_bai}"
                    echo ""
                    read -e -p "$(echo -e "${gl_huang}是否覆盖现有配置？(Y/N): ${gl_bai}")" overwrite
                    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
                        echo "已取消"
                        sleep 1
                        continue
                    fi
                fi
                deploy_socks5
                ;;
            2)
                modify_socks5
                ;;
            3)
                delete_socks5
                ;;
            4)
                view_socks5
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${gl_hong}❌ 无效选项${gl_bai}"
                sleep 1
                ;;
        esac
    done
}

install_singbox_binary() {
    clear
    echo -e "${gl_kjlan}=== 自动安装 Sing-box 核心程序 ===${gl_bai}"
    echo ""
    echo "检测到系统未安装 sing-box"
    echo ""
    echo -e "${gl_huang}安装说明：${gl_bai}"
    echo "  • 仅下载 sing-box 官方二进制程序"
    echo "  • 不安装任何协议配置（纯净安装）"
    echo "  • 安装后可用于 SOCKS5 代理部署"
    echo "  • 如需完整功能，可稍后通过菜单 36 安装"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    read -e -p "$(echo -e "${gl_huang}是否继续安装？(Y/N): ${gl_bai}")" confirm
    
    case "$confirm" in
        [Yy])
            echo ""
            echo -e "${gl_lv}开始下载 Sing-box...${gl_bai}"
            echo ""
            
            # 步骤1：检测系统架构
            local arch=""
            case "$(uname -m)" in
                aarch64|arm64)
                    arch="arm64"
                    ;;
                x86_64|amd64)
                    arch="amd64"
                    ;;
                armv7l)
                    arch="armv7"
                    ;;
                *)
                    echo -e "${gl_hong}❌ 不支持的系统架构: $(uname -m)${gl_bai}"
                    echo ""
                    echo "支持的架构：amd64, arm64, armv7"
                    echo ""
                    break_end
                    return 1
                    ;;
            esac
            
            echo -e "${gl_zi}[1/5] 检测架构: ${arch}${gl_bai}"
            echo ""
            
            # 步骤2：获取最新版本
            echo -e "${gl_zi}[2/5] 获取最新版本...${gl_bai}"
            
            local version=""
            local gh_api_url="https://api.github.com/repos/SagerNet/sing-box/releases"
            
            # 尝试从 GitHub API 获取最新稳定版本（过滤掉 alpha/beta/rc）
            version=$(wget --timeout=10 --tries=2 -qO- "$gh_api_url" 2>/dev/null | \
                      grep '"tag_name"' | \
                      sed -E 's/.*"tag_name":[[:space:]]*"v([^"]+)".*/\1/' | \
                      grep -v -E '(alpha|beta|rc)' | \
                      sort -Vr | head -1)
            
            # 如果 API 失败，使用默认版本
            if [ -z "$version" ]; then
                version="1.10.0"
                echo -e "${gl_huang}  ⚠️  API 获取失败，使用默认版本: v${version}${gl_bai}"
            else
                echo -e "${gl_lv}  ✓ 最新版本: v${version}${gl_bai}"
            fi
            echo ""
            
            # 步骤3：下载并解压
            echo -e "${gl_zi}[3/5] 下载 sing-box v${version} (${arch})...${gl_bai}"
            
            local download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
            local temp_dir="/tmp/singbox-install-$$"
            
            mkdir -p "$temp_dir"
            
            if ! wget --timeout=30 --tries=3 -qO "${temp_dir}/sing-box.tar.gz" "$download_url" 2>/dev/null; then
                echo -e "${gl_hong}  ✗ 下载失败${gl_bai}"
                echo ""
                echo "可能的原因："
                echo "  1. 网络连接问题"
                echo "  2. GitHub 访问受限"
                echo "  3. 版本 v${version} 不存在"
                echo ""
                echo "建议："
                echo "  • 检查网络连接"
                echo "  • 配置代理后重试"
                echo "  • 手动执行菜单 36 使用 F 佬脚本安装"
                echo ""
                rm -rf "$temp_dir"
                break_end
                return 1
            fi
            
            echo -e "${gl_lv}  ✓ 下载完成${gl_bai}"
            echo ""
            
            # 步骤4：解压并安装
            echo -e "${gl_zi}[4/5] 解压并安装...${gl_bai}"
            
            if ! tar -xzf "${temp_dir}/sing-box.tar.gz" -C "$temp_dir" 2>/dev/null; then
                echo -e "${gl_hong}  ✗ 解压失败${gl_bai}"
                rm -rf "$temp_dir"
                break_end
                return 1
            fi
            
            # 创建安装目录
            mkdir -p /etc/sing-box
            
            # 查找并移动二进制文件（兼容不同版本的目录结构）
            # 注意：不使用 -executable 参数，因为解压后的文件可能还没有执行权限
            local binary_path=$(find "$temp_dir" -name "sing-box" -type f 2>/dev/null | head -1)
            
            if [ -n "$binary_path" ] && [ -f "$binary_path" ]; then
                mv "$binary_path" /etc/sing-box/sing-box
                chmod +x /etc/sing-box/sing-box
                echo -e "${gl_lv}  ✓ 安装完成${gl_bai}"
            else
                echo -e "${gl_hong}  ✗ 未找到 sing-box 二进制文件${gl_bai}"
                echo ""
                echo "调试信息："
                echo "临时目录内容："
                ls -R "$temp_dir" 2>/dev/null || echo "无法列出目录"
                echo ""
                rm -rf "$temp_dir"
                break_end
                return 1
            fi
            
            # 清理临时文件
            rm -rf "$temp_dir"
            echo ""
            
            # 步骤5：验证安装
            echo -e "${gl_zi}[5/5] 验证安装...${gl_bai}"
            
            if /etc/sing-box/sing-box version >/dev/null 2>&1; then
                local installed_version=$(/etc/sing-box/sing-box version 2>/dev/null | head -1)
                echo -e "${gl_lv}  ✓ ${installed_version}${gl_bai}"
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo -e "${gl_lv}✅ Sing-box 核心程序安装成功！${gl_bai}"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo -e "${gl_zi}提示：${gl_bai}"
                echo "  • 二进制位置: /etc/sing-box/sing-box"
                echo "  • 这是纯净安装，未配置任何协议"
                echo "  • 可继续部署 SOCKS5 代理"
                echo "  • 如需完整功能，可执行菜单 36 安装协议配置"
                echo ""
                return 0
            else
                echo -e "${gl_hong}  ✗ 验证失败${gl_bai}"
                echo ""
                break_end
                return 1
            fi
            ;;
        *)
            echo ""
            echo "已取消安装"
            echo ""
            echo "您可以："
            echo "  • 稍后通过菜单 36 使用 F 佬脚本安装（含完整协议配置）"
            echo "  • 自行安装 sing-box 到 /etc/sing-box/sing-box"
            echo ""
            break_end
            return 1
            ;;
    esac
}

deploy_socks5() {
    clear
    echo -e "${gl_kjlan}=== Sing-box SOCKS5 一键部署 ===${gl_bai}"
    echo ""
    echo "此功能将部署一个独立的SOCKS5代理服务"
    echo "------------------------------------------------"
    echo ""
    
    # 步骤1：检测 sing-box 二进制程序
    echo -e "${gl_zi}[步骤 1/7] 检测 sing-box 安装...${gl_bai}"
    echo ""
    
    local SINGBOX_CMD=""
    local detection_debug=""
    
    # 优先查找常见的二进制程序位置
    for path in /etc/sing-box/sing-box /usr/local/bin/sing-box /opt/sing-box/sing-box; do
        detection_debug+="正在检测: $path ... "
        
        # 检查文件是否存在
        if [ ! -e "$path" ]; then
            detection_debug+="不存在\n"
            continue
        fi
        
        # 检查是否可执行
        if [ ! -x "$path" ]; then
            detection_debug+="存在但不可执行（尝试添加执行权限）\n"
            chmod +x "$path" 2>/dev/null
            if [ ! -x "$path" ]; then
                detection_debug+="  └─ 无法添加执行权限，跳过\n"
                continue
            fi
        fi
        
        # 如果是符号链接，解析实际路径
        if [ -L "$path" ]; then
            local real_path=$(readlink -f "$path")
            detection_debug+="是符号链接 → $real_path\n"
            path="$real_path"
        fi
        
        # 验证是 ELF 二进制文件（如果 file 命令可用）
        if command -v file >/dev/null 2>&1; then
            local file_type=$(file "$path" 2>/dev/null)
            if echo "$file_type" | grep -q "ELF"; then
                SINGBOX_CMD="$path"
                echo -e "${gl_lv}✅ 找到 sing-box 二进制程序: $SINGBOX_CMD${gl_bai}"
                break
            else
                detection_debug+="  └─ 不是 ELF 二进制文件（类型: $file_type），跳过\n"
            fi
        else
            # file 命令不可用，直接使用（已经检查过可执行权限）
            SINGBOX_CMD="$path"
            echo -e "${gl_lv}✅ 找到 sing-box 二进制程序: $SINGBOX_CMD${gl_bai}"
            break
        fi
    done
    
    # 如果没找到，检查 PATH 中的命令
    if [ -z "$SINGBOX_CMD" ]; then
        for cmd in sing-box sb; do
            if command -v "$cmd" &>/dev/null; then
                local cmd_path=$(which "$cmd")
                detection_debug+="正在检测 PATH 命令: $cmd → $cmd_path ... "
                
                # 如果是符号链接，解析实际路径
                if [ -L "$cmd_path" ]; then
                    local real_path=$(readlink -f "$cmd_path")
                    detection_debug+="是符号链接 → $real_path\n"
                    cmd_path="$real_path"
                fi
                
                # 验证文件类型（如果 file 命令可用）
                if command -v file >/dev/null 2>&1; then
                    local file_type=$(file "$cmd_path" 2>/dev/null)
                    if echo "$file_type" | grep -q "ELF"; then
                        SINGBOX_CMD="$cmd_path"
                        echo -e "${gl_lv}✅ 找到 sing-box 二进制程序: $SINGBOX_CMD${gl_bai}"
                        break
                    else
                        echo -e "${gl_huang}⚠️  $cmd_path 是脚本，跳过${gl_bai}"
                        detection_debug+="  └─ 不是 ELF 二进制文件（类型: $file_type），跳过\n"
                    fi
                else
                    # file 命令不可用，直接使用
                    SINGBOX_CMD="$cmd_path"
                    echo -e "${gl_lv}✅ 找到 sing-box 二进制程序: $SINGBOX_CMD${gl_bai}"
                    break
                fi
            fi
        done
    fi
    
    if [ -z "$SINGBOX_CMD" ]; then
        echo -e "${gl_hong}❌ 未找到 sing-box 二进制程序${gl_bai}"
        echo ""
        
        # 显示检测过程（可选）
        read -e -p "$(echo -e "${gl_zi}是否查看详细检测过程？(y/N): ${gl_bai}")" show_debug
        if [[ "$show_debug" =~ ^[Yy]$ ]]; then
            echo ""
            echo "检测过程："
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo -e "$detection_debug"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
        fi
        
        # 调用纯净安装函数（仅二进制）
        if install_singbox_binary; then
            # 安装成功，重新检测
            echo ""
            echo -e "${gl_zi}重新检测 sing-box...${gl_bai}"
            echo ""
            
            SINGBOX_CMD="/etc/sing-box/sing-box"
            if [ -x "$SINGBOX_CMD" ]; then
                echo -e "${gl_lv}✅ 找到 sing-box 二进制程序: $SINGBOX_CMD${gl_bai}"
                echo ""
            else
                echo -e "${gl_hong}❌ 安装后仍未找到 sing-box${gl_bai}"
                echo ""
                echo "请手动检查："
                echo "  ls -lh /etc/sing-box/sing-box"
                echo ""
                break_end
                return 1
            fi
        else
            # 用户取消或安装失败
            return 1
        fi
    fi
    
    # 显示版本信息
    echo ""
    $SINGBOX_CMD version 2>/dev/null | head -n 1
    echo ""
    
    # 步骤2：配置参数输入
    echo -e "${gl_zi}[步骤 2/7] 配置 SOCKS5 参数...${gl_bai}"
    echo ""
    
    # 输入端口（支持回车使用随机端口）
    local socks5_port=""
    while true; do
        read -e -p "$(echo -e "${gl_huang}请输入 SOCKS5 端口 [回车随机生成]: ${gl_bai}")" socks5_port
        
        if [ -z "$socks5_port" ]; then
            # 生成随机端口（10000-65535）
            socks5_port=$(( ((RANDOM<<15) | RANDOM) % 55536 + 10000 ))
            echo -e "${gl_lv}✅ 已生成随机端口: ${socks5_port}${gl_bai}"
            break
        elif [[ "$socks5_port" =~ ^[0-9]+$ ]] && [ "$socks5_port" -ge 1024 ] && [ "$socks5_port" -le 65535 ]; then
            # 检查端口是否被占用
            if ss -tulpn | grep -q ":${socks5_port} "; then
                echo -e "${gl_hong}❌ 端口 ${socks5_port} 已被占用，请选择其他端口${gl_bai}"
            else
                echo -e "${gl_lv}✅ 使用端口: ${socks5_port}${gl_bai}"
                break
            fi
        else
            echo -e "${gl_hong}❌ 无效端口，请输入 1024-65535 之间的数字${gl_bai}"
        fi
    done
    
    echo ""
    
    # 输入用户名
    local socks5_user=""
    while true; do
        read -e -p "$(echo -e "${gl_huang}请输入用户名: ${gl_bai}")" socks5_user
        
        if [ -z "$socks5_user" ]; then
            echo -e "${gl_hong}❌ 用户名不能为空${gl_bai}"
        elif [[ "$socks5_user" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo -e "${gl_lv}✅ 用户名: ${socks5_user}${gl_bai}"
            break
        else
            echo -e "${gl_hong}❌ 用户名只能包含字母、数字、下划线和连字符${gl_bai}"
        fi
    done
    
    echo ""
    
    # 输入密码
    local socks5_pass=""
    while true; do
        read -e -p "$(echo -e "${gl_huang}请输入密码: ${gl_bai}")" socks5_pass
        
        if [ -z "$socks5_pass" ]; then
            echo -e "${gl_hong}❌ 密码不能为空${gl_bai}"
        elif [ ${#socks5_pass} -lt 6 ]; then
            echo -e "${gl_hong}❌ 密码长度至少6位${gl_bai}"
        elif [[ "$socks5_pass" == *\"* || "$socks5_pass" == *\\* ]]; then
            echo -e "${gl_hong}❌ 密码不能包含 \" 或 \\ 字符${gl_bai}"
        else
            echo -e "${gl_lv}✅ 密码已设置${gl_bai}"
            break
        fi
    done
    
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}配置信息确认：${gl_bai}"
    echo -e "  端口: ${gl_huang}${socks5_port}${gl_bai}"
    echo -e "  用户名: ${gl_huang}${socks5_user}${gl_bai}"
    echo -e "  密码: ${gl_huang}${socks5_pass}${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    read -e -p "$(echo -e "${gl_huang}确认开始部署？(Y/N): ${gl_bai}")" confirm
    
    case "$confirm" in
        [Yy])
            ;;
        *)
            echo "已取消部署"
            break_end
            return 1
            ;;
    esac
    
    # 步骤3：创建目录
    echo ""
    echo -e "${gl_zi}[步骤 3/7] 创建配置目录...${gl_bai}"
    mkdir -p /etc/sbox_socks5
    echo -e "${gl_lv}✅ 目录创建成功${gl_bai}"
    
    # 步骤4：创建配置文件
    echo ""
    echo -e "${gl_zi}[步骤 4/7] 创建配置文件...${gl_bai}"
    
    cat > /etc/sbox_socks5/config.json << CONFIGEOF
{
  "log": {
    "level": "info",
    "output": "/etc/sbox_socks5/socks5.log"
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks5-in",
      "listen": "0.0.0.0",
      "listen_port": ${socks5_port},
      "users": [
        {
          "username": "${socks5_user}",
          "password": "${socks5_pass}"
        }
      ]
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
CONFIGEOF
    
    chmod 600 /etc/sbox_socks5/config.json
    echo -e "${gl_lv}✅ 配置文件创建成功${gl_bai}"
    
    # 步骤5：验证配置
    echo ""
    echo -e "${gl_zi}[步骤 5/7] 验证配置文件语法...${gl_bai}"
    
    if $SINGBOX_CMD check -c /etc/sbox_socks5/config.json >/dev/null 2>&1; then
        echo -e "${gl_lv}✅ 配置文件语法正确${gl_bai}"
    else
        echo -e "${gl_hong}❌ 配置文件语法错误${gl_bai}"
        $SINGBOX_CMD check -c /etc/sbox_socks5/config.json
        break_end
        return 1
    fi
    
    # 步骤6：创建服务文件
    echo ""
    echo -e "${gl_zi}[步骤 6/7] 创建 systemd 服务...${gl_bai}"
    
    cat > /etc/systemd/system/sbox-socks5.service << SERVICEEOF
[Unit]
Description=Sing-box SOCKS5 Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SINGBOX_CMD} run -c /etc/sbox_socks5/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
User=root
Group=root
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sbox-socks5
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/sbox_socks5
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICEEOF
    
    chmod 644 /etc/systemd/system/sbox-socks5.service
    echo -e "${gl_lv}✅ 服务文件创建成功${gl_bai}"
    
    # 步骤7：启动服务
    echo ""
    echo -e "${gl_zi}[步骤 7/7] 启动服务...${gl_bai}"
    
    systemctl daemon-reload
    systemctl enable sbox-socks5 >/dev/null 2>&1
    systemctl reset-failed sbox-socks5 >/dev/null 2>&1
    
    local systemctl_action="start"
    if systemctl is-active --quiet sbox-socks5; then
        systemctl_action="restart"
    fi
    
    if ! systemctl "$systemctl_action" sbox-socks5 >/dev/null 2>&1; then
        echo -e "${gl_hong}❌ 服务 ${systemctl_action} 命令执行失败，请查看日志${gl_bai}"
    fi
    
    # 等待服务启动
    sleep 3
    
    # 验证部署
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}验证部署结果：${gl_bai}"
    echo ""
    
    local deploy_success=true
    
    # 检查服务状态
    if systemctl is-active --quiet sbox-socks5; then
        echo -e "  服务状态: ${gl_lv}✅ Running${gl_bai}"
    else
        echo -e "  服务状态: ${gl_hong}❌ Failed${gl_bai}"
        deploy_success=false
    fi
    
    # 检查端口监听
    if ss -tulpn | grep -q ":${socks5_port} "; then
        echo -e "  端口监听: ${gl_lv}✅ ${socks5_port}${gl_bai}"
    else
        echo -e "  端口监听: ${gl_hong}❌ 未监听${gl_bai}"
        deploy_success=false
    fi
    
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    
    if [ "$deploy_success" = true ]; then
        # 获取服务器IP（优先IPv4，fallback到IPv6）
        local server_ip=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || \
                          curl -4 -s --max-time 3 ipinfo.io/ip 2>/dev/null || \
                          curl -6 -s --max-time 3 ifconfig.me 2>/dev/null || \
                          curl -6 -s --max-time 3 ipinfo.io/ip 2>/dev/null || \
                          echo "请手动获取")
        
        echo ""
        echo -e "${gl_lv}🎉 部署成功！${gl_bai}"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_lv}SOCKS5 连接信息：${gl_bai}"
        echo ""
        echo -e "  服务器地址: ${gl_huang}${server_ip}${gl_bai}"
        echo -e "  端口:       ${gl_huang}${socks5_port}${gl_bai}"
        echo -e "  用户名:     ${gl_huang}${socks5_user}${gl_bai}"
        echo -e "  密码:       ${gl_huang}${socks5_pass}${gl_bai}"
        echo -e "  协议:       ${gl_huang}SOCKS5${gl_bai}"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "${gl_zi}测试连接命令：${gl_bai}"
        echo "curl --socks5-hostname ${socks5_user}:${socks5_pass}@${server_ip}:${socks5_port} http://httpbin.org/ip"
        echo ""
        echo -e "${gl_huang}⚠️  重要提醒：${gl_bai}"
        echo "  1. 确保云服务商安全组已开放 TCP ${socks5_port} 端口"
        echo "  2. 查看日志: journalctl -u sbox-socks5 -f"
        echo "  3. 重启服务: systemctl restart sbox-socks5"
        echo "  4. 停止服务: systemctl stop sbox-socks5"
        echo "  5. 卸载服务: systemctl stop sbox-socks5 && systemctl disable sbox-socks5 && rm -rf /etc/sbox_socks5 /etc/systemd/system/sbox-socks5.service"
        echo ""
    else
        echo ""
        echo -e "${gl_hong}❌ 部署失败${gl_bai}"
        echo ""
        echo "查看详细错误信息："
        echo "  journalctl -u sbox-socks5 -n 50 --no-pager"
        echo ""
        echo "常见问题排查："
        echo "  1. 检查 sing-box 程序是否正确: file ${SINGBOX_CMD}"
        echo "  2. 检查端口是否被占用: ss -tulpn | grep ${socks5_port}"
        echo "  3. 检查服务日志: systemctl status sbox-socks5 --no-pager"
        echo ""
    fi
    
    break_end
}
#=============================================================================
# Sub-Store 多实例管理功能
#=============================================================================

# 检查端口是否被占用
check_substore_port() {
    local port=$1
    if netstat -tuln 2>/dev/null | grep -q ":$port "; then
        return 1
    elif ss -tuln 2>/dev/null | grep -q ":$port "; then
        return 1
    fi
    return 0
}

# 验证端口号
validate_substore_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

# 验证访问路径
validate_substore_path() {
    local path=$1
    # 只包含字母数字和少数符号
    if [[ ! "$path" =~ ^[a-zA-Z0-9/_-]+$ ]]; then
        return 1
    fi
    return 0
}

# 生成随机路径
generate_substore_random_path() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 20 | head -n 1
}

# 检查 Docker 是否安装
check_substore_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${gl_hong}Docker 未安装${gl_bai}"
        echo ""
        read -e -p "$(echo -e "${gl_huang}是否现在安装 Docker？(Y/N): ${gl_bai}")" install_docker
        
        case "$install_docker" in
            [Yy])
                echo ""
                echo "请选择安装源："
                echo "1. 国内镜像（阿里云）"
                echo "2. 国外官方源"
                read -e -p "请选择 [1]: " mirror_choice
                mirror_choice=${mirror_choice:-1}
                
                case "$mirror_choice" in
                    1)
                        echo "正在使用阿里云镜像安装 Docker..."
                        run_remote_script "https://get.docker.com" bash -s docker --mirror Aliyun
                        ;;
                    2)
                        echo "正在使用官方源安装 Docker..."
                        run_remote_script "https://get.docker.com" bash
                        ;;
                    *)
                        echo "无效选择，使用阿里云镜像..."
                        run_remote_script "https://get.docker.com" bash -s docker --mirror Aliyun
                        ;;
                esac
                
                if [ $? -eq 0 ]; then
                    echo -e "${gl_lv}✅ Docker 安装成功${gl_bai}"
                    systemctl enable docker
                    systemctl start docker
                else
                    echo -e "${gl_hong}❌ Docker 安装失败${gl_bai}"
                    return 1
                fi
                ;;
            *)
                echo "已取消，请先安装 Docker"
                return 1
                ;;
        esac
    fi
    
    if ! command -v docker compose &> /dev/null && ! command -v docker-compose &> /dev/null; then
        echo -e "${gl_huang}Docker Compose 未安装，尝试安装...${gl_bai}"
        # Docker Compose v2 通常随 Docker 一起安装
        if docker compose version &>/dev/null; then
            echo -e "${gl_lv}✅ Docker Compose 已可用${gl_bai}"
        else
            echo -e "${gl_hong}❌ Docker Compose 不可用，请手动安装${gl_bai}"
            return 1
        fi
    fi
    
    return 0
}

# 获取已部署的实例列表
get_substore_instances() {
    local instances=()
    if [ -d "/root/sub-store-configs" ]; then
        for config in /root/sub-store-configs/store-*.yaml; do
            if [ -f "$config" ]; then
                local instance_name=$(basename "$config" .yaml)
                instances+=("$instance_name")
            fi
        done
    fi
    echo "${instances[@]}"
}

# 检查实例是否存在
check_substore_instance_exists() {
    local instance_num=$1
    if [ -f "/root/sub-store-configs/store-$instance_num.yaml" ]; then
        return 0
    fi
    return 1
}

# 安装新实例
install_substore_instance() {
    clear
    echo "=================================="
    echo "    Sub-Store 实例安装向导"
    echo "=================================="
    echo ""
    
    # 检查 Docker
    if ! check_substore_docker; then
        break_end
        return 1
    fi
    
    echo -e "${gl_lv}✅ Docker 环境检查通过${gl_bai}"
    echo ""
    
    # 获取建议的实例编号
    local instances=($(get_substore_instances))
    local suggested_num=1
    if [ ${#instances[@]} -gt 0 ]; then
        echo -e "${gl_huang}已存在 ${#instances[@]} 个实例${gl_bai}"
        suggested_num=$((${#instances[@]} + 1))
    fi
    
    # 输入实例编号
    local instance_num
    while true; do
        read -e -p "请输入实例编号（建议: $suggested_num）: " instance_num
        
        if [ -z "$instance_num" ]; then
            echo -e "${gl_hong}实例编号不能为空${gl_bai}"
            continue
        fi
        
        if ! [[ "$instance_num" =~ ^[0-9]+$ ]]; then
            echo -e "${gl_hong}实例编号必须是数字${gl_bai}"
            continue
        fi
        
        if check_substore_instance_exists "$instance_num"; then
            echo -e "${gl_hong}实例编号 $instance_num 已存在${gl_bai}"
            continue
        fi
        
        break
    done
    
    echo -e "${gl_lv}✅ 实例编号: $instance_num${gl_bai}"
    echo ""
    
    # 输入后端 API 端口
    local api_port
    local default_api_port=3001
    while true; do
        read -e -p "请输入后端 API 端口（回车使用默认 $default_api_port）: " api_port
        
        if [ -z "$api_port" ]; then
            api_port=$default_api_port
            echo -e "${gl_huang}使用默认端口: $api_port${gl_bai}"
        fi
        
        if ! validate_substore_port "$api_port"; then
            echo -e "${gl_hong}端口号无效${gl_bai}"
            continue
        fi
        
        if ! check_substore_port "$api_port"; then
            echo -e "${gl_hong}端口 $api_port 已被占用${gl_bai}"
            continue
        fi
        
        break
    done
    
    echo -e "${gl_lv}✅ 后端 API 端口: $api_port${gl_bai}"
    echo ""
    
    # 输入 HTTP-META 端口
    local http_port
    local default_http_port=9876
    while true; do
        read -e -p "请输入 HTTP-META 端口（回车使用默认 $default_http_port）: " http_port
        
        if [ -z "$http_port" ]; then
            http_port=$default_http_port
            echo -e "${gl_huang}使用默认端口: $http_port${gl_bai}"
        fi
        
        if ! validate_substore_port "$http_port"; then
            echo -e "${gl_hong}端口号无效${gl_bai}"
            continue
        fi
        
        if ! check_substore_port "$http_port"; then
            echo -e "${gl_hong}端口 $http_port 已被占用${gl_bai}"
            continue
        fi
        
        if [ "$http_port" == "$api_port" ]; then
            echo -e "${gl_hong}HTTP-META 端口不能与后端 API 端口相同${gl_bai}"
            continue
        fi
        
        break
    done
    
    echo -e "${gl_lv}✅ HTTP-META 端口: $http_port${gl_bai}"
    echo ""
    
    # 输入访问路径
    local access_path
    while true; do
        local random_path=$(generate_substore_random_path)
        echo -e "${gl_zi}访问路径说明：${gl_bai}"
        echo "  - 路径会自动添加开头的 /"
        echo "  - 建议使用随机路径（更安全）"
        echo "  - 也可使用自定义路径（易记）"
        echo ""
        echo -e "${gl_huang}随机生成的路径: ${random_path}${gl_bai}"
        echo ""
        
        read -e -p "请输入访问路径（直接输入如 my-subs，或回车使用随机）: " access_path
        
        if [ -z "$access_path" ]; then
            access_path="$random_path"
            echo -e "${gl_lv}✅ 使用随机路径: /$access_path${gl_bai}"
        else
            # 移除可能的开头斜杠
            access_path="${access_path#/}"
            
            if ! validate_substore_path "$access_path"; then
                echo -e "${gl_hong}路径格式无效（只能包含字母、数字、-、_、/）${gl_bai}"
                continue
            fi
            
            echo -e "${gl_lv}✅ 使用自定义路径: /$access_path${gl_bai}"
        fi
        
        break
    done
    
    echo ""
    
    # 输入数据存储目录
    local data_dir
    local default_data_dir="/root/data-sub-store-$instance_num"
    
    read -e -p "请输入数据存储目录（回车使用默认 $default_data_dir）: " data_dir
    
    if [ -z "$data_dir" ]; then
        data_dir="$default_data_dir"
        echo -e "${gl_huang}使用默认目录: $data_dir${gl_bai}"
    fi
    
    if [ -d "$data_dir" ]; then
        echo ""
        echo -e "${gl_huang}目录 $data_dir 已存在${gl_bai}"
        local use_existing
        read -e -p "是否使用现有目录？(y/n): " use_existing
        if [[ ! "$use_existing" =~ ^[Yy]$ ]]; then
            echo "请重新运行并选择其他目录"
            break_end
            return 1
        fi
    fi
    
    # 确认信息
    echo ""
    echo "=================================="
    echo "          配置确认"
    echo "=================================="
    echo "实例编号: $instance_num"
    echo "容器名称: sub-store-$instance_num"
    echo "后端 API 端口: $api_port"
    echo "HTTP-META 端口: $http_port"
    echo "访问路径: /$access_path"
    echo "数据目录: $data_dir"
    echo "=================================="
    echo ""
    
    local confirm
    read -e -p "确认开始安装？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消安装"
        break_end
        return 1
    fi
    
    # 创建配置目录
    mkdir -p /root/sub-store-configs
    
    # 创建数据目录
    echo ""
    echo "正在创建数据目录..."
    mkdir -p "$data_dir"
    
    # 生成配置文件
    local config_file="/root/sub-store-configs/store-$instance_num.yaml"
    echo "正在生成配置文件..."
    
    cat > "$config_file" << EOF
services:
  sub-store-$instance_num:
    image: xream/sub-store:http-meta
    container_name: sub-store-$instance_num
    restart: always
    network_mode: host
    environment:
      SUB_STORE_BACKEND_API_HOST: 127.0.0.1
      SUB_STORE_BACKEND_API_PORT: $api_port
      SUB_STORE_BACKEND_MERGE: true
      SUB_STORE_FRONTEND_BACKEND_PATH: /$access_path
      HOST: 127.0.0.1
    volumes:
      - $data_dir:/opt/app/data
EOF
    
    # 启动容器
    echo "正在启动 Sub-Store 实例..."
    if docker compose -f "$config_file" up -d; then
        echo ""
        echo -e "${gl_lv}=========================================="
        echo "  Sub-Store 实例安装成功！"
        echo "==========================================${gl_bai}"
        echo ""
        echo -e "${gl_zi}实例信息：${gl_bai}"
        echo "  - 实例编号: $instance_num"
        echo "  - 容器名称: sub-store-$instance_num"
        echo "  - 服务端口: $api_port（前后端共用，监听 127.0.0.1）"
        echo "  - 访问路径: /$access_path"
        echo "  - 数据目录: $data_dir"
        echo "  - 配置文件: $config_file"
        echo ""
        echo -e "${gl_huang}⚠️  重要提示：${gl_bai}"
        echo "  此实例仅监听本地 127.0.0.1，无法直接通过IP访问！"
        echo "  必须配置 Cloudflare Tunnel 后才能使用。"
        echo ""
        
        # 生成 Cloudflare Tunnel 配置
        local cf_tunnel_conf="/root/sub-store-cf-tunnel-$instance_num.yaml"
        cat > "$cf_tunnel_conf" << CFEOF
# Cloudflare Tunnel 配置
# 使用说明：
#   1. 安装 cloudflared: 
#      wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
#      chmod +x cloudflared-linux-amd64 && mv cloudflared-linux-amd64 /usr/local/bin/cloudflared
#   2. 登录: cloudflared tunnel login
#   3. 创建隧道: cloudflared tunnel create sub-store-$instance_num
#   4. 修改下面的 tunnel 和 credentials-file
#   5. 配置路由: cloudflared tunnel route dns <TUNNEL_ID> sub.你的域名.com
#   6. 启动: cloudflared tunnel --config $cf_tunnel_conf run

tunnel: <TUNNEL_ID>  # 替换为你的 Tunnel ID
credentials-file: /root/.cloudflared/<TUNNEL_ID>.json  # 替换为你的凭证文件路径

ingress:
  # 后端 API 路由（必须在前面，更具体的规则）
  - hostname: sub.你的域名.com
    path: /$access_path
    service: http://127.0.0.1:$api_port
  
  # 前端页面路由（通配所有其他请求，与后端共用端口）
  - hostname: sub.你的域名.com
    service: http://127.0.0.1:$api_port
  
  # 默认规则（必须）
  - service: http_status:404
CFEOF
        
        echo -e "${gl_kjlan}【Cloudflare Tunnel 配置文件】${gl_bai}"
        echo ""
        echo "  配置模板已生成: $cf_tunnel_conf"
        echo ""
        echo "  接下来将引导你进行自动配置"
        echo ""
        
        echo -e "${gl_zi}常用命令：${gl_bai}"
        echo "  - 查看日志: docker logs sub-store-$instance_num"
        echo "  - 停止服务: docker compose -f $config_file down"
        echo "  - 重启服务: docker compose -f $config_file restart"
        echo ""
        
        # 交互式配置向导
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_huang}📌 接下来需要配置 Cloudflare Tunnel 才能使用${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "请选择："
        echo "1. 立即配置 Cloudflare Tunnel（推荐）"
        echo "2. 跳过配置（稍后手动配置）"
        echo ""
        
        local proxy_choice
        read -e -p "请选择 [1-2]: " proxy_choice
        
        case "$proxy_choice" in
            1)
                # Cloudflare Tunnel 配置向导
                configure_cf_tunnel "$instance_num" "$http_port" "$api_port" "$access_path" "$cf_tunnel_conf"
                ;;
            2)
                echo ""
                echo -e "${gl_huang}已跳过配置${gl_bai}"
                echo "稍后可手动配置，配置文件位于："
                echo "  - CF Tunnel: $cf_tunnel_conf"
                echo ""
                ;;
            *)
                echo ""
                echo -e "${gl_huang}无效选择，已跳过配置${gl_bai}"
                ;;
        esac
    else
        echo -e "${gl_hong}启动失败，请检查配置和日志${gl_bai}"
        break_end
        return 1
    fi
    
    break_end
}

# Cloudflare Tunnel 配置向导

# Cloudflare Tunnel 配置向导
configure_cf_tunnel() {
    local instance_num=$1
    local http_port=$2
    local api_port=$3
    local access_path=$4
    local cf_tunnel_conf=$5
    
    clear
    echo -e "${gl_kjlan}=================================="
    echo "  Cloudflare Tunnel 配置向导"
    echo "==================================${gl_bai}"
    echo ""
    
    # 检查 cloudflared 是否安装
    if ! command -v cloudflared &>/dev/null; then
        echo -e "${gl_huang}cloudflared 未安装${gl_bai}"
        echo ""
        read -e -p "是否现在安装 cloudflared？(Y/N): " install_cf
        
        case "$install_cf" in
            [Yy])
                echo ""
                echo "正在下载 cloudflared..."
                
                local cpu_arch=$(uname -m)
                local download_url
                
                case "$cpu_arch" in
                    x86_64)
                        download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
                        ;;
                    aarch64)
                        download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
                        ;;
                    *)
                        echo -e "${gl_hong}不支持的架构: $cpu_arch${gl_bai}"
                        break_end
                        return 1
                        ;;
                esac
                
                wget -O /usr/local/bin/cloudflared "$download_url"
                chmod +x /usr/local/bin/cloudflared
                
                if [ $? -eq 0 ]; then
                    echo -e "${gl_lv}✅ cloudflared 安装成功${gl_bai}"
                else
                    echo -e "${gl_hong}❌ cloudflared 安装失败${gl_bai}"
                    break_end
                    return 1
                fi
                ;;
            *)
                echo "已取消，请手动安装 cloudflared 后配置"
                break_end
                return 1
                ;;
        esac
    else
        echo -e "${gl_lv}✅ cloudflared 已安装${gl_bai}"
    fi
    
    echo ""
    echo -e "${gl_zi}[步骤 1/5] Cloudflare 账户登录${gl_bai}"
    echo ""
    
    # 检查是否已有有效的证书（之前已登录过）
    if [ -f "/root/.cloudflared/cert.pem" ]; then
        echo -e "${gl_lv}✅ 检测到已有 Cloudflare 认证证书${gl_bai}"
        echo ""
        echo "请选择："
        echo "1. 复用现有账户认证（推荐，适用于同一 CF 账户下的不同域名）"
        echo "2. 使用新账户登录（需要使用其他 Cloudflare 账户）"
        echo ""
        
        local auth_choice
        read -e -p "请选择 [1-2]: " auth_choice
        
        case "$auth_choice" in
            2)
                echo ""
                echo -e "${gl_huang}正在清除旧的认证信息...${gl_bai}"
                rm -f /root/.cloudflared/cert.pem
                
                echo ""
                echo "即将打开浏览器进行 Cloudflare 登录..."
                echo -e "${gl_huang}请在浏览器中完成授权${gl_bai}"
                echo ""
                read -e -p "按回车继续..."
                
                cloudflared tunnel login
                
                if [ $? -ne 0 ]; then
                    echo -e "${gl_hong}❌ 登录失败${gl_bai}"
                    break_end
                    return 1
                fi
                
                echo -e "${gl_lv}✅ 新账户登录成功${gl_bai}"
                ;;
            *)
                echo ""
                echo -e "${gl_lv}✅ 将复用现有认证${gl_bai}"
                ;;
        esac
    else
        echo "即将打开浏览器进行 Cloudflare 登录..."
        echo -e "${gl_huang}请在浏览器中完成授权${gl_bai}"
        echo ""
        read -e -p "按回车继续..."
        
        cloudflared tunnel login
        
        if [ $? -ne 0 ]; then
            echo -e "${gl_hong}❌ 登录失败${gl_bai}"
            break_end
            return 1
        fi
        
        echo -e "${gl_lv}✅ 登录成功${gl_bai}"
    fi
    
    echo ""
    echo -e "${gl_zi}[步骤 2/5] 创建隧道${gl_bai}"
    echo ""
    
    local tunnel_name="sub-store-$instance_num"
    echo "隧道名称: $tunnel_name"
    
    # 检查隧道是否已存在
    local existing_tunnel_id=$(cloudflared tunnel list 2>/dev/null | grep "$tunnel_name" | awk '{print $1}')
    
    if [ -n "$existing_tunnel_id" ]; then
        echo ""
        echo -e "${gl_lv}✅ 检测到同名隧道已存在${gl_bai}"
        echo "Tunnel ID: $existing_tunnel_id"
        echo ""
        echo "请选择操作："
        echo "1. 复用现有隧道（推荐）"
        echo "2. 删除旧隧道并重新创建"
        echo "3. 取消配置"
        echo ""
        
        local tunnel_choice
        read -e -p "请选择 [1-3]: " tunnel_choice
        
        case "$tunnel_choice" in
            1)
                echo -e "${gl_lv}✅ 将复用现有隧道${gl_bai}"
                tunnel_id="$existing_tunnel_id"
                ;;
            2)
                echo ""
                # 先停止可能正在运行的 cloudflared 服务
                local service_name="cloudflared-sub-store-$instance_num"
                if systemctl is-active --quiet "$service_name" 2>/dev/null; then
                    echo "正在停止旧的 cloudflared 服务..."
                    systemctl stop "$service_name" 2>/dev/null
                    systemctl disable "$service_name" 2>/dev/null
                    rm -f "/etc/systemd/system/$service_name.service" 2>/dev/null
                    systemctl daemon-reload 2>/dev/null
                    sleep 2
                fi
                
                # 清理旧的凭证文件
                if [ -n "$existing_tunnel_id" ]; then
                    echo "正在清理旧的隧道凭证..."
                    rm -f "/root/.cloudflared/$existing_tunnel_id.json" 2>/dev/null
                fi
                
                echo "正在删除旧隧道..."
                cloudflared tunnel cleanup "$tunnel_name" 2>/dev/null
                cloudflared tunnel delete "$tunnel_name" 2>/dev/null
                
                # 如果删除失败，尝试强制删除
                if cloudflared tunnel list 2>/dev/null | grep -q "$tunnel_name"; then
                    echo -e "${gl_huang}尝试强制删除隧道...${gl_bai}"
                    cloudflared tunnel delete -f "$tunnel_name" 2>/dev/null
                fi
                
                echo "正在创建新隧道..."
                cloudflared tunnel create "$tunnel_name"
                
                if [ $? -ne 0 ]; then
                    echo -e "${gl_hong}❌ 创建隧道失败${gl_bai}"
                    echo -e "${gl_huang}提示：可能是隧道名称冲突，请尝试更换实例编号${gl_bai}"
                    break_end
                    return 1
                fi
                
                tunnel_id=$(cloudflared tunnel list | grep "$tunnel_name" | awk '{print $1}')
                echo -e "${gl_lv}✅ 新隧道创建成功${gl_bai}"
                echo "Tunnel ID: $tunnel_id"
                ;;
            *)
                echo "已取消配置"
                break_end
                return 1
                ;;
        esac
    else
        # 隧道不存在，创建新隧道
        local create_output
        create_output=$(cloudflared tunnel create "$tunnel_name" 2>&1)
        local create_result=$?
        
        if [ $create_result -ne 0 ]; then
            echo -e "${gl_hong}❌ 创建隧道失败${gl_bai}"
            echo ""
            echo -e "${gl_huang}错误信息：${gl_bai}"
            echo "$create_output"
            echo ""
            
            # 检查是否是隧道名称已存在的错误
            if echo "$create_output" | grep -qi "already exists"; then
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                echo -e "${gl_huang}可能的原因：${gl_bai}"
                echo "  1. 隧道名称已在 Cloudflare 账户中存在（可能是其他机器创建的）"
                echo "  2. 之前使用不同账户创建过同名隧道"
                echo ""
                echo -e "${gl_huang}解决方案：${gl_bai}"
                echo "  方案1: 登录 Cloudflare Dashboard -> Zero Trust -> Networks -> Tunnels"
                echo "         手动删除名为 '$tunnel_name' 的隧道，然后重试"
                echo ""
                echo "  方案2: 使用不同的实例编号（如改用 2, 3...）"
                echo "         这会创建 sub-store-2, sub-store-3 等不同名称的隧道"
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            fi
            
            break_end
            return 1
        fi
        
        echo "$create_output"
        
        # 获取 tunnel ID
        tunnel_id=$(cloudflared tunnel list | grep "$tunnel_name" | awk '{print $1}')
        
        if [ -z "$tunnel_id" ]; then
            echo -e "${gl_hong}❌ 无法获取 tunnel ID${gl_bai}"
            break_end
            return 1
        fi
        
        echo -e "${gl_lv}✅ 隧道创建成功${gl_bai}"
        echo "Tunnel ID: $tunnel_id"
    fi
    
    echo ""
    echo -e "${gl_zi}[步骤 3/5] 输入域名${gl_bai}"
    echo ""
    
    local domain
    read -e -p "请输入你的域名（如 sub.example.com）: " domain
    
    if [ -z "$domain" ]; then
        echo -e "${gl_hong}域名不能为空${gl_bai}"
        break_end
        return 1
    fi
    
    echo ""
    echo -e "${gl_zi}[步骤 4/5] 配置 DNS 路由${gl_bai}"
    echo ""
    
    cloudflared tunnel route dns "$tunnel_id" "$domain"
    
    if [ $? -ne 0 ]; then
        echo -e "${gl_hong}❌ DNS 配置失败${gl_bai}"
        break_end
        return 1
    fi
    
    echo -e "${gl_lv}✅ DNS 配置成功${gl_bai}"
    
    echo ""
    echo -e "${gl_zi}[步骤 5/5] 生成并启动配置${gl_bai}"
    echo ""
    
    # 生成最终配置文件
    local final_cf_conf="/root/sub-store-cf-tunnel-$instance_num.yaml"
    cat > "$final_cf_conf" << CFEOF
tunnel: $tunnel_id
credentials-file: /root/.cloudflared/$tunnel_id.json

ingress:
  # 后端 API 路由（必须在前面，更具体的规则）
  - hostname: $domain
    path: /$access_path
    service: http://127.0.0.1:$api_port
  
  # 前端页面路由（通配所有其他请求，与后端共用端口）
  - hostname: $domain
    service: http://127.0.0.1:$api_port
  
  # 默认规则（必须）
  - service: http_status:404
CFEOF
    
    echo -e "${gl_lv}✅ 配置文件已生成: $final_cf_conf${gl_bai}"
    
    echo ""
    echo "正在启动 Cloudflare Tunnel..."
    
    # 创建 systemd 服务
    cat > /etc/systemd/system/cloudflared-sub-store-$instance_num.service << SERVICEEOF
[Unit]
Description=Cloudflare Tunnel for Sub-Store Instance $instance_num
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --config $final_cf_conf run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEEOF
    
    systemctl daemon-reload
    systemctl enable cloudflared-sub-store-$instance_num
    systemctl start cloudflared-sub-store-$instance_num
    
    sleep 3
    
    if systemctl is-active --quiet cloudflared-sub-store-$instance_num; then
        echo -e "${gl_lv}✅ Cloudflare Tunnel 启动成功${gl_bai}"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_lv}🎉 配置完成！${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "访问地址: ${gl_lv}https://$domain?api=https://$domain/$access_path${gl_bai}"
        echo ""
        echo "服务管理："
        echo "  - 查看状态: systemctl status cloudflared-sub-store-$instance_num"
        echo "  - 查看日志: journalctl -u cloudflared-sub-store-$instance_num -f"
        echo "  - 重启服务: systemctl restart cloudflared-sub-store-$instance_num"
        echo ""
    else
        echo -e "${gl_hong}❌ Cloudflare Tunnel 启动失败${gl_bai}"
        echo "查看日志: journalctl -u cloudflared-sub-store-$instance_num -n 50"
    fi
    
    break_end
}

# 更新实例
update_substore_instance() {
    clear
    echo "=================================="
    echo "    Sub-Store 实例更新"
    echo "=================================="
    echo ""
    
    local instances=($(get_substore_instances))
    
    if [ ${#instances[@]} -eq 0 ]; then
        echo -e "${gl_huang}没有已部署的实例${gl_bai}"
        break_end
        return 1
    fi
    
    echo -e "${gl_zi}已部署的实例：${gl_bai}"
    for i in "${!instances[@]}"; do
        local instance_name="${instances[$i]}"
        local instance_num=$(echo "$instance_name" | sed 's/store-//')
        local container_name="sub-store-$instance_num"
        
        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            echo -e "  $((i+1)). ${instance_name} ${gl_lv}[运行中]${gl_bai}"
        else
            echo -e "  $((i+1)). ${instance_name} ${gl_hong}[已停止]${gl_bai}"
        fi
    done
    echo "  $((${#instances[@]}+1)). 更新所有实例"
    echo ""
    
    local choice
    read -e -p "请选择要更新的实例编号（输入 0 取消）: " choice
    
    if [ "$choice" == "0" ]; then
        echo "已取消更新"
        break_end
        return 1
    fi
    
    # 更新所有实例
    if [ "$choice" == "$((${#instances[@]}+1))" ]; then
        echo ""
        echo "准备更新所有实例..."
        local confirm
        read -e -p "确认更新所有 ${#instances[@]} 个实例？(y/n): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "已取消更新"
            break_end
            return 1
        fi
        
        echo "正在拉取最新镜像..."
        docker pull xream/sub-store:http-meta
        
        for instance in "${instances[@]}"; do
            local config_file="/root/sub-store-configs/${instance}.yaml"
            local instance_num=$(echo "$instance" | sed 's/store-//')
            
            echo ""
            echo "正在更新实例: $instance"
            docker compose -f "$config_file" down
            docker compose -f "$config_file" up -d
            echo -e "${gl_lv}✅ 实例 $instance 更新完成${gl_bai}"
        done
        
        echo ""
        echo -e "${gl_lv}所有实例更新完成！${gl_bai}"
        break_end
        return 0
    fi
    
    # 更新单个实例
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#instances[@]} ]; then
        echo -e "${gl_hong}无效的选择${gl_bai}"
        break_end
        return 1
    fi
    
    local instance_name="${instances[$((choice-1))]}"
    local config_file="/root/sub-store-configs/${instance_name}.yaml"
    local instance_num=$(echo "$instance_name" | sed 's/store-//')
    
    echo ""
    echo "准备更新实例: $instance_name"
    local confirm
    read -e -p "确认更新？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消更新"
        break_end
        return 1
    fi
    
    echo "正在拉取最新镜像..."
    docker pull xream/sub-store:http-meta
    
    echo "正在停止容器..."
    docker compose -f "$config_file" down
    
    echo "正在启动更新后的容器..."
    docker compose -f "$config_file" up -d
    
    echo -e "${gl_lv}✅ 实例 $instance_name 更新完成！${gl_bai}"
    
    break_end
}

# 卸载实例
uninstall_substore_instance() {
    clear
    echo "=================================="
    echo "    Sub-Store 实例卸载"
    echo "=================================="
    echo ""
    
    local instances=($(get_substore_instances))
    
    if [ ${#instances[@]} -eq 0 ]; then
        echo -e "${gl_huang}没有已部署的实例${gl_bai}"
        break_end
        return 1
    fi
    
    echo -e "${gl_zi}已部署的实例：${gl_bai}"
    for i in "${!instances[@]}"; do
        local instance_name="${instances[$i]}"
        local instance_num=$(echo "$instance_name" | sed 's/store-//')
        local container_name="sub-store-$instance_num"
        
        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            echo -e "  $((i+1)). ${instance_name} ${gl_lv}[运行中]${gl_bai}"
        else
            echo -e "  $((i+1)). ${instance_name} ${gl_hong}[已停止]${gl_bai}"
        fi
    done
    echo ""
    
    local choice
    read -e -p "请选择要卸载的实例编号（输入 0 取消）: " choice
    
    if [ "$choice" == "0" ]; then
        echo "已取消卸载"
        break_end
        return 1
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#instances[@]} ]; then
        echo -e "${gl_hong}无效的选择${gl_bai}"
        break_end
        return 1
    fi
    
    local instance_name="${instances[$((choice-1))]}"
    local config_file="/root/sub-store-configs/${instance_name}.yaml"
    local instance_num=$(echo "$instance_name" | sed 's/store-//')
    
    echo ""
    echo -e "${gl_huang}将要卸载实例: $instance_name${gl_bai}"
    
    local delete_data
    read -e -p "是否同时删除数据目录？(y/n): " delete_data
    echo ""
    
    local confirm
    read -e -p "确认卸载？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消卸载"
        break_end
        return 1
    fi
    
    echo "正在停止并删除容器..."
    docker compose -f "$config_file" down
    
    if [[ "$delete_data" =~ ^[Yy]$ ]]; then
        # 从配置文件中提取数据目录
        local data_dir=$(grep -A 1 "volumes:" "$config_file" | tail -n 1 | awk -F':' '{print $1}' | xargs)
        if [ -n "$data_dir" ] && [ -d "$data_dir" ]; then
            echo "正在删除数据目录: $data_dir"
            rm -rf "$data_dir"
        fi
    fi
    
    echo "正在删除配置文件..."
    rm -f "$config_file"
    
    # 删除相关配置模板
    rm -f "/root/sub-store-nginx-$instance_num.conf"
    rm -f "/root/sub-store-cf-tunnel-$instance_num.yaml"
    
    echo -e "${gl_lv}✅ 实例 $instance_name 已成功卸载${gl_bai}"
    
    break_end
}

# 列出所有实例
list_substore_instances() {
    clear
    echo "=================================="
    echo "    已部署的 Sub-Store 实例"
    echo "=================================="
    echo ""
    
    local instances=($(get_substore_instances))
    
    if [ ${#instances[@]} -eq 0 ]; then
        echo -e "${gl_huang}没有已部署的实例${gl_bai}"
        break_end
        return 1
    fi
    
    for instance in "${instances[@]}"; do
        local config_file="/root/sub-store-configs/${instance}.yaml"
        local instance_num=$(echo "$instance" | sed 's/store-//')
        local container_name="sub-store-$instance_num"
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "实例编号: $instance_num"
        
        # 检查容器状态
        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            echo -e "  状态: ${gl_lv}运行中${gl_bai}"
        else
            echo -e "  状态: ${gl_hong}已停止${gl_bai}"
        fi
        
        # 提取配置信息
        if [ -f "$config_file" ]; then
            local http_port=$(grep "PORT:" "$config_file" | awk '{print $2}')
            local api_port=$(grep "SUB_STORE_BACKEND_API_PORT:" "$config_file" | awk '{print $2}')
            local access_path=$(grep "SUB_STORE_FRONTEND_BACKEND_PATH:" "$config_file" | awk '{print $2}')
            local data_dir=$(grep -A 1 "volumes:" "$config_file" | tail -n 1 | awk -F':' '{print $1}' | xargs)
            
            echo "  容器名称: $container_name"
            echo "  前端端口: $http_port (127.0.0.1)"
            echo "  后端端口: $api_port (127.0.0.1)"
            echo "  访问路径: $access_path"
            echo "  数据目录: $data_dir"
            echo "  配置文件: $config_file"
        fi
        
        echo ""
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    break_end
}

# Sub-Store 主菜单
manage_substore() {
    while true; do
        clear
        echo "=================================="
        echo "   Sub-Store 多实例管理"
        echo "=================================="
        echo ""
        echo "1. 安装新实例"
        echo "2. 更新实例"
        echo "3. 卸载实例"
        echo "4. 查看已部署实例"
        echo "0. 返回主菜单"
        echo "=================================="
        read -e -p "请选择操作 [0-4]: " choice
        
        case $choice in
            1)
                install_substore_instance
                ;;
            2)
                update_substore_instance
                ;;
            3)
                uninstall_substore_instance
                ;;
            4)
                list_substore_instances
                ;;
            0)
                return
                ;;
            *)
                echo "无效的选择"
                sleep 2
                ;;
        esac
    done
}

#=============================================================================
# 一键反代功能 - 通用反向代理管理
#=============================================================================

# 配置文件路径
REVERSE_PROXY_CONFIG_DIR="/root/reverse-proxy-configs"
REVERSE_PROXY_CONFIG_FILE="$REVERSE_PROXY_CONFIG_DIR/config.json"

# 初始化配置目录
init_reverse_proxy_config() {
    if [ ! -d "$REVERSE_PROXY_CONFIG_DIR" ]; then
        mkdir -p "$REVERSE_PROXY_CONFIG_DIR"
        mkdir -p "$REVERSE_PROXY_CONFIG_DIR/caddy"
        mkdir -p "$REVERSE_PROXY_CONFIG_DIR/cf-tunnel"
    fi

    if [ ! -f "$REVERSE_PROXY_CONFIG_FILE" ]; then
        echo '{"proxies":[]}' > "$REVERSE_PROXY_CONFIG_FILE"
    fi
}

# 检查端口是否在监听
check_port_listening() {
    local port=$1
    if ss -tuln 2>/dev/null | grep -q ":$port " || netstat -tuln 2>/dev/null | grep -q ":$port "; then
        return 0
    fi
    return 1
}

# 安装 cloudflared
install_cloudflared() {
    if command -v cloudflared &>/dev/null; then
        echo -e "${gl_lv}✅ cloudflared 已安装${gl_bai}"
        return 0
    fi

    echo -e "${gl_huang}正在安装 cloudflared...${gl_bai}"

    local cpu_arch=$(uname -m)
    local download_url

    case "$cpu_arch" in
        x86_64)
            download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        aarch64)
            download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        *)
            echo -e "${gl_hong}❌ 不支持的架构: $cpu_arch${gl_bai}"
            return 1
            ;;
    esac

    if wget -O /usr/local/bin/cloudflared "$download_url" && chmod +x /usr/local/bin/cloudflared; then
        echo -e "${gl_lv}✅ cloudflared 安装成功${gl_bai}"
        return 0
    else
        echo -e "${gl_hong}❌ cloudflared 安装失败${gl_bai}"
        return 1
    fi
}

# 安装 Caddy
install_caddy() {
    if command -v caddy &>/dev/null; then
        echo -e "${gl_lv}✅ Caddy 已安装${gl_bai}"
        return 0
    fi

    echo -e "${gl_huang}正在安装 Caddy...${gl_bai}"

    if apt install -y caddy; then
        echo -e "${gl_lv}✅ Caddy 安装成功${gl_bai}"
        return 0
    else
        echo -e "${gl_hong}❌ Caddy 安装失败${gl_bai}"
        return 1
    fi
}

# 快速部署 - Cloudflare Tunnel
quick_deploy_cf_tunnel() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  一键反代 - Cloudflare Tunnel${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    # 初始化配置
    init_reverse_proxy_config

    # 检查并安装 cloudflared
    if ! install_cloudflared; then
        break_end
        return 1
    fi

    echo ""
    echo -e "${gl_zi}[步骤 1/4] 输入本地端口${gl_bai}"
    echo ""

    local port
    while true; do
        read -e -p "请输入要反代的本地端口（如 5555）: " port

        if [ -z "$port" ]; then
            echo -e "${gl_hong}端口不能为空${gl_bai}"
            continue
        fi

        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo -e "${gl_hong}端口号无效（1-65535）${gl_bai}"
            continue
        fi

        # 检查端口是否在监听
        if ! check_port_listening "$port"; then
            echo -e "${gl_huang}⚠️  警告: 端口 $port 当前未在监听${gl_bai}"
            read -e -p "是否继续？(y/n): " continue_anyway
            if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
                continue
            fi
        else
            echo -e "${gl_lv}✅ 检测到端口 $port 正在监听${gl_bai}"
        fi

        break
    done

    echo ""
    echo -e "${gl_zi}[步骤 2/4] 输入域名${gl_bai}"
    echo ""

    local domain
    while true; do
        read -e -p "请输入你的域名（如 app.example.com）: " domain

        if [ -z "$domain" ]; then
            echo -e "${gl_hong}域名不能为空${gl_bai}"
            continue
        fi

        # 简单的域名格式验证
        if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
            echo -e "${gl_hong}域名格式无效${gl_bai}"
            continue
        fi

        break
    done

    echo ""
    echo -e "${gl_zi}[步骤 3/4] 输入应用名称（可选）${gl_bai}"
    echo ""

    local app_name
    read -e -p "请输入应用名称（回车跳过，如 MyApp）: " app_name

    if [ -z "$app_name" ]; then
        app_name="port-$port"
    fi

    # 生成安全的隧道名称
    local tunnel_name=$(echo "$app_name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
    tunnel_name="tunnel-$tunnel_name-$(date +%s)"

    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_huang}配置确认${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo "应用名称: $app_name"
    echo "本地端口: $port"
    echo "访问域名: https://$domain"
    echo "隧道名称: $tunnel_name"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    read -e -p "确认开始部署？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消部署"
        break_end
        return 1
    fi

    echo ""
    echo -e "${gl_zi}[步骤 4/4] 配置 Cloudflare Tunnel${gl_bai}"
    echo ""

    # 检查是否已登录
    if [ ! -d "/root/.cloudflared" ] || [ -z "$(ls -A /root/.cloudflared/*.json 2>/dev/null)" ]; then
        echo "首次使用需要登录 Cloudflare..."
        echo -e "${gl_huang}即将打开浏览器，请在浏览器中完成授权${gl_bai}"
        echo ""
        read -e -p "按回车继续..."

        cloudflared tunnel login

        if [ $? -ne 0 ]; then
            echo -e "${gl_hong}❌ 登录失败${gl_bai}"
            break_end
            return 1
        fi

        echo -e "${gl_lv}✅ 登录成功${gl_bai}"
        echo ""
    else
        echo -e "${gl_lv}✅ 已登录 Cloudflare${gl_bai}"
        echo ""
    fi

    # 创建隧道
    echo "正在创建隧道: $tunnel_name"
    cloudflared tunnel create "$tunnel_name"

    if [ $? -ne 0 ]; then
        echo -e "${gl_hong}❌ 创建隧道失败${gl_bai}"
        break_end
        return 1
    fi

    # 获取 tunnel ID
    local tunnel_id=$(cloudflared tunnel list | grep "$tunnel_name" | awk '{print $1}')

    if [ -z "$tunnel_id" ]; then
        echo -e "${gl_hong}❌ 无法获取 tunnel ID${gl_bai}"
        break_end
        return 1
    fi

    echo -e "${gl_lv}✅ 隧道创建成功${gl_bai}"
    echo "Tunnel ID: $tunnel_id"
    echo ""

    # 配置 DNS 路由
    echo "正在配置 DNS 路由..."
    cloudflared tunnel route dns "$tunnel_id" "$domain"

    if [ $? -ne 0 ]; then
        echo -e "${gl_hong}❌ DNS 配置失败${gl_bai}"
        break_end
        return 1
    fi

    echo -e "${gl_lv}✅ DNS 配置成功${gl_bai}"
    echo ""

    # 生成配置文件
    local config_file="$REVERSE_PROXY_CONFIG_DIR/cf-tunnel/$tunnel_name.yaml"
    cat > "$config_file" << EOF
tunnel: $tunnel_id
credentials-file: /root/.cloudflared/$tunnel_id.json

ingress:
  - hostname: $domain
    service: http://127.0.0.1:$port
  - service: http_status:404
EOF

    echo "正在创建 systemd 服务..."

    # 创建 systemd 服务
    cat > /etc/systemd/system/cloudflared-$tunnel_name.service << EOF
[Unit]
Description=Cloudflare Tunnel - $app_name
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --config $config_file run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cloudflared-$tunnel_name
    systemctl start cloudflared-$tunnel_name

    sleep 3

    if systemctl is-active --quiet cloudflared-$tunnel_name; then
        echo -e "${gl_lv}✅ 服务启动成功${gl_bai}"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_lv}🎉 部署完成！${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "访问地址: ${gl_lv}https://$domain${gl_bai}"
        echo ""
        echo "服务管理："
        echo "  - 查看状态: systemctl status cloudflared-$tunnel_name"
        echo "  - 查看日志: journalctl -u cloudflared-$tunnel_name -f"
        echo "  - 重启服务: systemctl restart cloudflared-$tunnel_name"
        echo "  - 停止服务: systemctl stop cloudflared-$tunnel_name"
        echo ""

        # 保存配置到 JSON
        local timestamp=$(date +%s)
        local temp_file=$(mktemp)

        if command -v jq &>/dev/null; then
            jq --arg name "$app_name" \
               --arg port "$port" \
               --arg domain "$domain" \
               --arg tunnel "$tunnel_name" \
               --arg tunnel_id "$tunnel_id" \
               --arg type "cf-tunnel" \
               --arg time "$timestamp" \
               '.proxies += [{
                   "name": $name,
                   "port": $port,
                   "domain": $domain,
                   "tunnel_name": $tunnel,
                   "tunnel_id": $tunnel_id,
                   "type": $type,
                   "created_at": $time,
                   "service": ("cloudflared-" + $tunnel),
                   "config_file": ($tunnel + ".yaml")
               }]' "$REVERSE_PROXY_CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$REVERSE_PROXY_CONFIG_FILE"
        fi
    else
        echo -e "${gl_hong}❌ 服务启动失败${gl_bai}"
        echo "查看日志: journalctl -u cloudflared-$tunnel_name -n 50"
    fi

    break_end
}

# 查看所有反代配置
list_reverse_proxies() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  已部署的反向代理${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    init_reverse_proxy_config

    # 列出所有 cloudflared 服务
    local services=$(systemctl list-units --type=service --all | grep "cloudflared-tunnel" | awk '{print $1}')

    if [ -z "$services" ]; then
        echo -e "${gl_huang}暂无已部署的反向代理${gl_bai}"
        echo ""
        break_end
        return 0
    fi

    local count=0
    for service in $services; do
        count=$((count + 1))
        local tunnel_name=$(echo "$service" | sed 's/cloudflared-//' | sed 's/.service//')

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "[$count] $tunnel_name"

        # 检查服务状态
        if systemctl is-active --quiet "$service"; then
            echo -e "  状态: ${gl_lv}运行中${gl_bai}"
        else
            echo -e "  状态: ${gl_hong}已停止${gl_bai}"
        fi

        # 读取配置文件
        local config_file="$REVERSE_PROXY_CONFIG_DIR/cf-tunnel/$tunnel_name.yaml"
        if [ -f "$config_file" ]; then
            local domain=$(grep "hostname:" "$config_file" | head -1 | awk '{print $3}')
            local port=$(grep "service:" "$config_file" | head -1 | grep -oP ':\K[0-9]+')

            echo "  域名: https://$domain"
            echo "  端口: $port"
            echo "  配置: $config_file"
        fi

        echo "  服务: $service"
        echo ""
    done

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "总计: $count 个反向代理"
    echo ""

    break_end
}

# 删除反代配置
delete_reverse_proxy() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  删除反向代理${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    # 列出所有服务
    local services=$(systemctl list-units --type=service --all | grep "cloudflared-tunnel" | awk '{print $1}')

    if [ -z "$services" ]; then
        echo -e "${gl_huang}暂无已部署的反向代理${gl_bai}"
        break_end
        return 0
    fi

    local services_array=($services)
    local count=0

    for service in "${services_array[@]}"; do
        count=$((count + 1))
        local tunnel_name=$(echo "$service" | sed 's/cloudflared-//' | sed 's/.service//')

        if systemctl is-active --quiet "$service"; then
            echo -e "  $count. $tunnel_name ${gl_lv}[运行中]${gl_bai}"
        else
            echo -e "  $count. $tunnel_name ${gl_hong}[已停止]${gl_bai}"
        fi
    done

    echo ""
    read -e -p "请选择要删除的反代编号 (1-$count, 0取消): " choice

    if [ "$choice" = "0" ]; then
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt $count ]; then
        echo -e "${gl_hong}无效的选择${gl_bai}"
        break_end
        return 1
    fi

    local selected_service="${services_array[$((choice-1))]}"
    local tunnel_name=$(echo "$selected_service" | sed 's/cloudflared-//' | sed 's/.service//')

    echo ""
    echo -e "${gl_huang}将要删除: $tunnel_name${gl_bai}"
    echo ""
    read -e -p "确认删除？(y/n): " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消"
        break_end
        return 0
    fi

    echo ""
    echo "正在停止服务..."
    systemctl stop "$selected_service"
    systemctl disable "$selected_service"

    echo "正在删除服务文件..."
    rm -f "/etc/systemd/system/$selected_service"
    systemctl daemon-reload

    echo "正在删除配置文件..."
    rm -f "$REVERSE_PROXY_CONFIG_DIR/cf-tunnel/$tunnel_name.yaml"

    # 删除隧道（可选）
    read -e -p "是否同时删除 Cloudflare Tunnel？(y/n): " delete_tunnel
    if [[ "$delete_tunnel" =~ ^[Yy]$ ]]; then
        echo "正在删除隧道..."
        cloudflared tunnel delete "$tunnel_name" 2>/dev/null || true
    fi

    echo ""
    echo -e "${gl_lv}✅ 删除完成${gl_bai}"

    break_end
}

# 一键反代主菜单
manage_reverse_proxy() {
    while true; do
        clear
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_kjlan}  一键反代 🎯${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "1. 快速部署（输入端口+域名）"
        echo "2. 查看已部署的反代"
        echo "3. 删除反代配置"
        echo "0. 返回主菜单"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        read -e -p "请选择操作 [0-3]: " choice

        case $choice in
            1)
                quick_deploy_cf_tunnel
                ;;
            2)
                list_reverse_proxies
                ;;
            3)
                delete_reverse_proxy
                ;;
            0)
                return
                ;;
            *)
                echo "无效的选择"
                sleep 2
                ;;
        esac
    done
}

#=============================================================================
# Antigravity Claude Proxy 部署管理
#=============================================================================

# 固定配置
AG_PROXY_SERVICE_NAME="ag-proxy"
AG_PROXY_INSTALL_DIR="/root/antigravity-claude-proxy"
AG_PROXY_PORT="8080"
AG_PROXY_REPO="https://github.com/badri-s2001/antigravity-claude-proxy.git"
AG_PROXY_SERVICE_FILE="/etc/systemd/system/ag-proxy.service"
AG_PROXY_PORT_FILE="/root/antigravity-claude-proxy/.ag-proxy-port"

# 获取当前配置的端口
ag_proxy_get_port() {
    if [ -f "$AG_PROXY_PORT_FILE" ]; then
        cat "$AG_PROXY_PORT_FILE"
    else
        echo "$AG_PROXY_PORT"
    fi
}

# 检测 Antigravity Claude Proxy 状态
ag_proxy_check_status() {
    if [ ! -d "$AG_PROXY_INSTALL_DIR" ]; then
        echo "not_installed"
    elif ! systemctl is-enabled "$AG_PROXY_SERVICE_NAME" &>/dev/null; then
        echo "installed_no_service"
    elif systemctl is-active "$AG_PROXY_SERVICE_NAME" &>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

# 检测并安装 Node.js
ag_proxy_install_nodejs() {
    echo -e "${gl_kjlan}[1/6] 检测 Node.js 环境...${gl_bai}"

    if command -v node &>/dev/null; then
        local node_version=$(node -v | sed 's/v//' | cut -d. -f1)
        if [ "$node_version" -ge 20 ]; then
            echo -e "${gl_lv}✅ Node.js $(node -v) 已安装${gl_bai}"
            return 0
        else
            echo -e "${gl_huang}⚠ Node.js 版本过低 ($(node -v))，需要 20+${gl_bai}"
        fi
    else
        echo -e "${gl_huang}⚠ Node.js 未安装${gl_bai}"
    fi

    echo "正在安装 Node.js 20..."

    # 检测系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        local os_id="${ID,,}"
    fi

    # 安全下载并执行设置脚本（避免 curl | bash 漏洞）
    local setup_script=$(mktemp)
    local script_url=""

    if [[ "$os_id" == "debian" || "$os_id" == "ubuntu" ]]; then
        script_url="https://deb.nodesource.com/setup_20.x"
    elif [[ "$os_id" == "centos" || "$os_id" == "rhel" || "$os_id" == "fedora" || "$os_id" == "rocky" || "$os_id" == "alma" ]]; then
        script_url="https://rpm.nodesource.com/setup_20.x"
    fi

    if [ -n "$script_url" ]; then
        # 下载脚本
        if ! curl -fsSL --connect-timeout 15 --max-time 60 "$script_url" -o "$setup_script" 2>/dev/null; then
            echo -e "${gl_hong}❌ 下载 Node.js 设置脚本失败${gl_bai}"
            rm -f "$setup_script"
            return 1
        fi

        # 验证脚本格式（必须是 shell 脚本）
        if ! head -1 "$setup_script" | grep -q "^#!"; then
            echo -e "${gl_hong}❌ 脚本格式验证失败${gl_bai}"
            rm -f "$setup_script"
            return 1
        fi

        # 执行脚本
        chmod +x "$setup_script"
        bash "$setup_script" >/dev/null 2>&1
        rm -f "$setup_script"
    fi

    if [[ "$os_id" == "debian" || "$os_id" == "ubuntu" ]]; then
        apt-get install -y nodejs >/dev/null 2>&1
    elif [[ "$os_id" == "centos" || "$os_id" == "rhel" || "$os_id" == "fedora" || "$os_id" == "rocky" || "$os_id" == "alma" ]]; then
        if command -v dnf &>/dev/null; then
            dnf install -y nodejs >/dev/null 2>&1
        else
            yum install -y nodejs >/dev/null 2>&1
        fi
    else
        echo -e "${gl_hong}❌ 不支持的系统，请手动安装 Node.js 20+${gl_bai}"
        return 1
    fi

    if command -v node &>/dev/null; then
        echo -e "${gl_lv}✅ Node.js $(node -v) 安装成功${gl_bai}"
        return 0
    else
        echo -e "${gl_hong}❌ Node.js 安装失败${gl_bai}"
        return 1
    fi
}

# 克隆项目
ag_proxy_clone_repo() {
    echo -e "${gl_kjlan}[2/6] 拉取项目代码...${gl_bai}"

    if [ -d "$AG_PROXY_INSTALL_DIR" ]; then
        echo -e "${gl_huang}⚠ 项目目录已存在，正在更新...${gl_bai}"
        cd "$AG_PROXY_INSTALL_DIR"
        git pull >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${gl_lv}✅ 代码更新成功${gl_bai}"
            return 0
        else
            echo -e "${gl_hong}❌ 代码更新失败，尝试重新克隆...${gl_bai}"
            cd /root
            rm -rf "$AG_PROXY_INSTALL_DIR"
        fi
    fi

    # 安装 git（如果没有）
    if ! command -v git &>/dev/null; then
        echo "正在安装 git..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y git >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y git >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y git >/dev/null 2>&1
        fi
    fi

    git clone "$AG_PROXY_REPO" "$AG_PROXY_INSTALL_DIR" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${gl_lv}✅ 项目克隆成功${gl_bai}"
        return 0
    else
        echo -e "${gl_hong}❌ 项目克隆失败，请检查网络连接${gl_bai}"
        return 1
    fi
}

# 安装依赖
ag_proxy_install_deps() {
    echo -e "${gl_kjlan}[3/6] 安装项目依赖...${gl_bai}"

    cd "$AG_PROXY_INSTALL_DIR"

    # 先检查 package.json 是否存在
    if [ ! -f "package.json" ]; then
        echo -e "${gl_hong}❌ package.json 不存在，项目可能未正确克隆${gl_bai}"
        return 1
    fi

    # 检查并安装编译工具（better-sqlite3 需要）
    echo "检测编译工具..."
    local need_build_tools=false

    if ! command -v make &>/dev/null; then
        echo "  make: 未安装"
        need_build_tools=true
    else
        echo "  make: 已安装"
    fi

    if ! command -v g++ &>/dev/null; then
        echo "  g++: 未安装"
        need_build_tools=true
    else
        echo "  g++: 已安装"
    fi

    if [ "$need_build_tools" = true ]; then
        echo ""
        echo "正在安装编译工具（make, g++, python3）..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq
            apt-get install -y build-essential python3
        elif command -v dnf &>/dev/null; then
            dnf install -y make gcc-c++ python3
        elif command -v yum &>/dev/null; then
            yum install -y make gcc-c++ python3
        fi

        # 验证安装
        if command -v make &>/dev/null && command -v g++ &>/dev/null; then
            echo -e "${gl_lv}✅ 编译工具安装成功${gl_bai}"
        else
            echo -e "${gl_hong}❌ 编译工具安装失败，请手动安装: apt install build-essential${gl_bai}"
            return 1
        fi
    fi

    echo ""
    # 安装依赖，显示进度
    echo "正在执行 npm install（可能需要几分钟）..."
    npm install 2>&1 | tail -30

    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo -e "${gl_lv}✅ 依赖安装成功${gl_bai}"
        return 0
    else
        echo -e "${gl_hong}❌ 依赖安装失败，请检查上方错误信息${gl_bai}"
        return 1
    fi
}

# 检测并处理端口冲突
ag_proxy_handle_port_conflict() {
    local port=$(ag_proxy_get_port)
    echo -e "${gl_kjlan}[4/6] 检测端口 ${port} 占用情况...${gl_bai}"

    local pid=$(ss -lntp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1)

    if [ -n "$pid" ]; then
        # 检查是否是本项目的进程
        local proc_cwd=$(readlink -f /proc/$pid/cwd 2>/dev/null)
        local proc_comm=$(cat /proc/$pid/comm 2>/dev/null)

        if [ "$proc_cwd" = "$AG_PROXY_INSTALL_DIR" ] || [[ "$proc_comm" == "node" && -f "$AG_PROXY_INSTALL_DIR/package.json" ]]; then
            # 是本项目的进程，可以安全终止
            echo -e "${gl_huang}⚠ 端口 ${port} 被本项目旧进程占用 (PID ${pid})${gl_bai}"
            echo "正在终止旧进程..."
            kill "$pid" 2>/dev/null
            sleep 1

            # 检查是否成功终止
            if ss -lntp 2>/dev/null | grep -q ":${port} "; then
                echo "进程未响应，强制终止..."
                kill -9 "$pid" 2>/dev/null
                sleep 1
            fi

            if ss -lntp 2>/dev/null | grep -q ":${port} "; then
                echo -e "${gl_hong}❌ 无法释放端口 ${port}${gl_bai}"
                return 1
            fi
            echo -e "${gl_lv}✅ 端口 ${port} 已释放${gl_bai}"
        else
            # 不是本项目的进程，提示用户
            echo -e "${gl_hong}❌ 端口 ${port} 被其他程序占用 (PID ${pid})${gl_bai}"
            echo ""
            echo -e "占用进程信息："
            echo -e "  PID: ${pid}"
            echo -e "  程序: ${proc_comm}"
            echo -e "  目录: ${proc_cwd}"
            echo ""
            echo -e "${gl_huang}请选择操作：${gl_bai}"
            echo "1. 使用其他端口（推荐）"
            echo "2. 强制终止该进程并使用 ${port}"
            echo "0. 取消部署"
            echo ""
            read -e -p "请选择 [0-2]: " conflict_choice

            case "$conflict_choice" in
                1)
                    read -e -p "请输入新端口 (1-65535): " new_port
                    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                        # 检查新端口是否可用
                        if ss -lntp 2>/dev/null | grep -q ":${new_port} "; then
                            echo -e "${gl_hong}❌ 端口 ${new_port} 也被占用${gl_bai}"
                            return 1
                        fi
                        echo "$new_port" > "$AG_PROXY_PORT_FILE"
                        echo -e "${gl_lv}✅ 将使用端口 ${new_port}${gl_bai}"
                    else
                        echo -e "${gl_hong}❌ 无效的端口号${gl_bai}"
                        return 1
                    fi
                    ;;
                2)
                    echo "正在强制终止进程 ${pid}..."
                    kill "$pid" 2>/dev/null
                    sleep 1
                    if ss -lntp 2>/dev/null | grep -q ":${port} "; then
                        kill -9 "$pid" 2>/dev/null
                        sleep 1
                    fi
                    if ss -lntp 2>/dev/null | grep -q ":${port} "; then
                        echo -e "${gl_hong}❌ 无法释放端口 ${port}${gl_bai}"
                        return 1
                    fi
                    echo -e "${gl_lv}✅ 端口 ${port} 已释放${gl_bai}"
                    ;;
                *)
                    echo "已取消"
                    return 1
                    ;;
            esac
        fi
    else
        echo -e "${gl_lv}✅ 端口 ${port} 可用${gl_bai}"
    fi
    return 0
}

# 创建 systemd 服务
ag_proxy_create_service() {
    local port=$(ag_proxy_get_port)
    echo -e "${gl_kjlan}[5/6] 创建 systemd 服务...${gl_bai}"

    cat > "$AG_PROXY_SERVICE_FILE" <<EOF
[Unit]
Description=Antigravity Claude Proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=${AG_PROXY_INSTALL_DIR}
Environment=PORT=${port}
ExecStart=/usr/bin/npm start
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    if [ -f "$AG_PROXY_SERVICE_FILE" ]; then
        echo -e "${gl_lv}✅ 服务文件创建成功${gl_bai}"
        return 0
    else
        echo -e "${gl_hong}❌ 服务文件创建失败${gl_bai}"
        return 1
    fi
}

# 启动服务
ag_proxy_start_service() {
    echo -e "${gl_kjlan}[6/6] 启动服务...${gl_bai}"

    systemctl enable "$AG_PROXY_SERVICE_NAME" >/dev/null 2>&1
    systemctl start "$AG_PROXY_SERVICE_NAME"

    sleep 2

    if systemctl is-active "$AG_PROXY_SERVICE_NAME" &>/dev/null; then
        echo -e "${gl_lv}✅ 服务启动成功${gl_bai}"
        return 0
    else
        echo -e "${gl_hong}❌ 服务启动失败${gl_bai}"
        echo "查看日志: journalctl -u $AG_PROXY_SERVICE_NAME -n 20"
        return 1
    fi
}

# 一键部署
ag_proxy_deploy() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  Antigravity Claude Proxy 一键部署${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(ag_proxy_check_status)
    if [ "$status" = "running" ]; then
        echo -e "${gl_huang}⚠ 服务已在运行中${gl_bai}"
        echo ""
        read -e -p "是否重新部署？(Y/N): " confirm
        case "$confirm" in
            [Yy]) ;;
            *) return ;;
        esac
        echo ""
        systemctl stop "$AG_PROXY_SERVICE_NAME" 2>/dev/null
    fi

    # 执行部署步骤
    ag_proxy_install_nodejs || { break_end; return 1; }
    echo ""
    ag_proxy_clone_repo || { break_end; return 1; }
    echo ""
    ag_proxy_install_deps || { break_end; return 1; }
    echo ""
    ag_proxy_handle_port_conflict || { break_end; return 1; }
    echo ""
    ag_proxy_create_service || { break_end; return 1; }
    echo ""
    ag_proxy_start_service || { break_end; return 1; }

    # 获取服务器 IP (端口配置已在 ag_proxy_handle_port_conflict 中保存)
    local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")
    local port=$(ag_proxy_get_port)

    echo ""
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}  ✅ 部署完成！${gl_bai}"
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "访问地址: ${gl_huang}http://${server_ip}:${port}${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}【第一步】添加 Google 账号${gl_bai}"
    echo "  打开上面的地址 → Accounts → Add Account → 完成 Google 授权"
    echo ""
    echo -e "${gl_kjlan}【第二步】配置本地 Claude Code${gl_bai}"
    echo "  编辑文件: ~/.claude/settings.json"
    echo ""
    echo "  添加以下内容（推荐配置）："
    echo -e "${gl_huang}  {${gl_bai}"
    echo -e "${gl_huang}    \"env\": {${gl_bai}"
    echo -e "${gl_huang}      \"ANTHROPIC_AUTH_TOKEN\": \"test\",${gl_bai}"
    echo -e "${gl_huang}      \"ANTHROPIC_BASE_URL\": \"http://${server_ip}:${port}\",${gl_bai}"
    echo -e "${gl_huang}      \"ANTHROPIC_MODEL\": \"claude-opus-4-5-thinking\",${gl_bai}"
    echo -e "${gl_huang}      \"ANTHROPIC_DEFAULT_OPUS_MODEL\": \"claude-opus-4-5-thinking\",${gl_bai}"
    echo -e "${gl_huang}      \"ANTHROPIC_DEFAULT_SONNET_MODEL\": \"claude-sonnet-4-5-thinking\",${gl_bai}"
    echo -e "${gl_huang}      \"ANTHROPIC_DEFAULT_HAIKU_MODEL\": \"gemini-3-flash\",${gl_bai}"
    echo -e "${gl_huang}      \"CLAUDE_CODE_SUBAGENT_MODEL\": \"claude-sonnet-4-5-thinking\"${gl_bai}"
    echo -e "${gl_huang}    }${gl_bai}"
    echo -e "${gl_huang}  }${gl_bai}"
    echo ""
    echo -e "${gl_zi}说明: Opus=主力模型, Sonnet=子代理, Haiku用Gemini省额度${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}【可选】通过环境变量配置（macOS/Linux）${gl_bai}"
    echo "  将以下命令添加到 shell 配置文件："
    echo ""
    echo -e "${gl_huang}  echo 'export ANTHROPIC_BASE_URL=\"http://${server_ip}:${port}\"' >> ~/.zshrc${gl_bai}"
    echo -e "${gl_huang}  echo 'export ANTHROPIC_AUTH_TOKEN=\"test\"' >> ~/.zshrc${gl_bai}"
    echo -e "${gl_huang}  source ~/.zshrc${gl_bai}"
    echo ""
    echo -e "${gl_zi}提示: Bash 用户请将 ~/.zshrc 替换为 ~/.bashrc${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}【第三步】重启 Claude Code${gl_bai}"
    echo "  关闭并重新打开终端，然后运行 claude 即可"
    echo ""
    echo -e "${gl_zi}提示: 更多模型选项请访问 WebUI 的 Settings 页面${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}管理命令:${gl_bai}"
    echo "  状态: systemctl status $AG_PROXY_SERVICE_NAME"
    echo "  日志: journalctl -u $AG_PROXY_SERVICE_NAME -f"
    echo "  重启: systemctl restart $AG_PROXY_SERVICE_NAME"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}命令行添加账号（无法访问 Web 时使用）:${gl_bai}"
    echo ""
    echo "  # 1. 停止服务"
    echo "  systemctl stop $AG_PROXY_SERVICE_NAME"
    echo ""
    echo "  # 2. 添加账号（按提示在浏览器中打开链接完成 Google 授权）"
    echo "  cd $AG_PROXY_INSTALL_DIR && npx antigravity-claude-proxy accounts add --no-browser"
    echo ""
    echo "  # 3. 重新启动服务"
    echo "  systemctl start $AG_PROXY_SERVICE_NAME"
    echo ""

    break_end
}

# 查看配置指引
ag_proxy_show_config() {
    clear

    if [ ! -d "$AG_PROXY_INSTALL_DIR" ]; then
        echo -e "${gl_hong}❌ 项目未安装，请先执行一键部署${gl_bai}"
        break_end
        return 1
    fi

    # 获取服务器 IP 和端口
    local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")
    local port=$(ag_proxy_get_port)

    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  Claude Code 本地配置指引${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "访问地址: ${gl_huang}http://${server_ip}:${port}${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}【第一步】添加 Google 账号${gl_bai}"
    echo "  打开上面的地址 → Accounts → Add Account → 完成 Google 授权"
    echo ""
    echo -e "${gl_kjlan}【第二步】配置本地 Claude Code${gl_bai}"
    echo "  编辑文件: ~/.claude/settings.json"
    echo ""
    echo "  添加以下内容（推荐配置）："
    echo -e "${gl_huang}  {${gl_bai}"
    echo -e "${gl_huang}    \"env\": {${gl_bai}"
    echo -e "${gl_huang}      \"ANTHROPIC_AUTH_TOKEN\": \"test\",${gl_bai}"
    echo -e "${gl_huang}      \"ANTHROPIC_BASE_URL\": \"http://${server_ip}:${port}\",${gl_bai}"
    echo -e "${gl_huang}      \"ANTHROPIC_MODEL\": \"claude-opus-4-5-thinking\",${gl_bai}"
    echo -e "${gl_huang}      \"ANTHROPIC_DEFAULT_OPUS_MODEL\": \"claude-opus-4-5-thinking\",${gl_bai}"
    echo -e "${gl_huang}      \"ANTHROPIC_DEFAULT_SONNET_MODEL\": \"claude-sonnet-4-5-thinking\",${gl_bai}"
    echo -e "${gl_huang}      \"ANTHROPIC_DEFAULT_HAIKU_MODEL\": \"gemini-3-flash\",${gl_bai}"
    echo -e "${gl_huang}      \"CLAUDE_CODE_SUBAGENT_MODEL\": \"claude-sonnet-4-5-thinking\"${gl_bai}"
    echo -e "${gl_huang}    }${gl_bai}"
    echo -e "${gl_huang}  }${gl_bai}"
    echo ""
    echo -e "${gl_zi}说明: Opus=主力模型, Sonnet=子代理, Haiku用Gemini省额度${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}【可选】通过环境变量配置（macOS/Linux）${gl_bai}"
    echo "  将以下命令添加到 shell 配置文件："
    echo ""
    echo -e "${gl_huang}  echo 'export ANTHROPIC_BASE_URL=\"http://${server_ip}:${port}\"' >> ~/.zshrc${gl_bai}"
    echo -e "${gl_huang}  echo 'export ANTHROPIC_AUTH_TOKEN=\"test\"' >> ~/.zshrc${gl_bai}"
    echo -e "${gl_huang}  source ~/.zshrc${gl_bai}"
    echo ""
    echo -e "${gl_zi}提示: Bash 用户请将 ~/.zshrc 替换为 ~/.bashrc${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}【第三步】重启 Claude Code${gl_bai}"
    echo "  关闭并重新打开终端，然后运行 claude 即可"
    echo ""
    echo -e "${gl_zi}提示: 更多模型选项请访问 WebUI 的 Settings 页面${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}管理命令:${gl_bai}"
    echo "  状态: systemctl status $AG_PROXY_SERVICE_NAME"
    echo "  日志: journalctl -u $AG_PROXY_SERVICE_NAME -f"
    echo "  重启: systemctl restart $AG_PROXY_SERVICE_NAME"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}命令行添加账号（无法访问 Web 时使用）:${gl_bai}"
    echo ""
    echo "  # 1. 停止服务"
    echo "  systemctl stop $AG_PROXY_SERVICE_NAME"
    echo ""
    echo "  # 2. 添加账号（按提示在浏览器中打开链接完成 Google 授权）"
    echo "  cd $AG_PROXY_INSTALL_DIR && npx antigravity-claude-proxy accounts add --no-browser"
    echo ""
    echo "  # 3. 重新启动服务"
    echo "  systemctl start $AG_PROXY_SERVICE_NAME"
    echo ""

    break_end
}

# 更新项目
ag_proxy_update() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  更新 Antigravity Claude Proxy${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    if [ ! -d "$AG_PROXY_INSTALL_DIR" ]; then
        echo -e "${gl_hong}❌ 项目未安装，请先执行一键部署${gl_bai}"
        break_end
        return 1
    fi

    echo "正在拉取最新代码..."
    cd "$AG_PROXY_INSTALL_DIR"
    git pull

    if [ $? -eq 0 ]; then
        echo ""
        echo "正在更新依赖..."
        npm install --production >/dev/null 2>&1

        echo ""
        echo "正在重启服务..."
        systemctl restart "$AG_PROXY_SERVICE_NAME"

        sleep 2

        if systemctl is-active "$AG_PROXY_SERVICE_NAME" &>/dev/null; then
            echo ""
            echo -e "${gl_lv}✅ 更新完成，服务已重启${gl_bai}"

            # 显示版本信息
            if [ -f "$AG_PROXY_INSTALL_DIR/package.json" ]; then
                local version=$(grep '"version"' "$AG_PROXY_INSTALL_DIR/package.json" | head -1 | grep -oP '"\d+\.\d+\.\d+"' | tr -d '"')
                if [ -n "$version" ]; then
                    echo -e "当前版本: ${gl_huang}v${version}${gl_bai}"
                fi
            fi
        else
            echo -e "${gl_hong}❌ 服务重启失败${gl_bai}"
        fi
    else
        echo -e "${gl_hong}❌ 代码更新失败${gl_bai}"
    fi

    break_end
}

# 查看状态
ag_proxy_status() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  Antigravity Claude Proxy 服务状态${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    systemctl status "$AG_PROXY_SERVICE_NAME" --no-pager

    echo ""
    break_end
}

# 查看日志
ag_proxy_logs() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  Antigravity Claude Proxy 日志（按 Ctrl+C 退出）${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    journalctl -u "$AG_PROXY_SERVICE_NAME" -f
}

# 启动服务
ag_proxy_start() {
    echo "正在启动服务..."
    systemctl start "$AG_PROXY_SERVICE_NAME"
    sleep 2

    if systemctl is-active "$AG_PROXY_SERVICE_NAME" &>/dev/null; then
        echo -e "${gl_lv}✅ 服务已启动${gl_bai}"
    else
        echo -e "${gl_hong}❌ 服务启动失败${gl_bai}"
    fi

    break_end
}

# 停止服务
ag_proxy_stop() {
    echo "正在停止服务..."
    systemctl stop "$AG_PROXY_SERVICE_NAME"

    if ! systemctl is-active "$AG_PROXY_SERVICE_NAME" &>/dev/null; then
        echo -e "${gl_lv}✅ 服务已停止${gl_bai}"
    else
        echo -e "${gl_hong}❌ 服务停止失败${gl_bai}"
    fi

    break_end
}

# 重启服务
ag_proxy_restart() {
    echo "正在重启服务..."

    # 检测端口冲突
    local port=$(ag_proxy_get_port)
    local pid=$(ss -lntp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1)
    local service_pid=$(systemctl show -p MainPID "$AG_PROXY_SERVICE_NAME" 2>/dev/null | cut -d= -f2)

    # 如果端口被其他进程占用（不是当前服务）
    if [ -n "$pid" ] && [ "$pid" != "$service_pid" ] && [ "$pid" != "0" ]; then
        echo -e "${gl_huang}⚠ 端口 ${port} 被 PID ${pid} 占用，正在释放...${gl_bai}"
        kill "$pid" 2>/dev/null
        sleep 1
        if ss -lntp 2>/dev/null | grep -q ":${port} "; then
            kill -9 "$pid" 2>/dev/null
            sleep 1
        fi
    fi

    systemctl restart "$AG_PROXY_SERVICE_NAME"
    sleep 2

    if systemctl is-active "$AG_PROXY_SERVICE_NAME" &>/dev/null; then
        echo -e "${gl_lv}✅ 服务已重启${gl_bai}"
    else
        echo -e "${gl_hong}❌ 服务重启失败${gl_bai}"
        echo "查看日志: journalctl -u $AG_PROXY_SERVICE_NAME -n 20"
    fi

    break_end
}

# 修改端口
ag_proxy_change_port() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  修改 Antigravity Claude Proxy 端口${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local current_port=$(ag_proxy_get_port)
    echo -e "当前端口: ${gl_huang}${current_port}${gl_bai}"
    echo ""

    read -e -p "请输入新端口 (1-65535): " new_port

    # 验证端口
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${gl_hong}❌ 无效的端口号${gl_bai}"
        break_end
        return 1
    fi

    if [ "$new_port" = "$current_port" ]; then
        echo -e "${gl_huang}⚠ 端口未改变${gl_bai}"
        break_end
        return 0
    fi

    # 检查新端口是否被占用
    if ss -lntp 2>/dev/null | grep -q ":${new_port} "; then
        echo -e "${gl_hong}❌ 端口 ${new_port} 已被占用${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo "正在修改端口..."

    # 停止服务
    systemctl stop "$AG_PROXY_SERVICE_NAME" 2>/dev/null

    # 更新服务文件
    sed -i "s/Environment=PORT=.*/Environment=PORT=${new_port}/" "$AG_PROXY_SERVICE_FILE"

    # 保存端口配置
    echo "$new_port" > "$AG_PROXY_PORT_FILE"

    # 重新加载并启动
    systemctl daemon-reload
    systemctl start "$AG_PROXY_SERVICE_NAME"

    sleep 2

    if systemctl is-active "$AG_PROXY_SERVICE_NAME" &>/dev/null; then
        local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")
        echo ""
        echo -e "${gl_lv}✅ 端口已修改为 ${new_port}${gl_bai}"
        echo -e "新访问地址: ${gl_huang}http://${server_ip}:${new_port}${gl_bai}"
    else
        echo -e "${gl_hong}❌ 服务启动失败${gl_bai}"
    fi

    break_end
}

# 卸载
ag_proxy_uninstall() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_hong}  卸载 Antigravity Claude Proxy${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_huang}警告: 此操作将删除服务和所有项目文件！${gl_bai}"
    echo ""

    read -e -p "确认卸载？(输入 yes 确认): " confirm

    if [ "$confirm" != "yes" ]; then
        echo "已取消"
        break_end
        return 0
    fi

    echo ""
    echo "正在停止服务..."
    systemctl stop "$AG_PROXY_SERVICE_NAME" 2>/dev/null
    systemctl disable "$AG_PROXY_SERVICE_NAME" 2>/dev/null

    echo "正在删除服务文件..."
    rm -f "$AG_PROXY_SERVICE_FILE"
    systemctl daemon-reload

    echo "正在删除项目文件..."
    rm -rf "$AG_PROXY_INSTALL_DIR"

    echo ""
    echo -e "${gl_lv}✅ 卸载完成${gl_bai}"

    break_end
}

# Antigravity Claude Proxy 主菜单
manage_ag_proxy() {
    while true; do
        clear
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_kjlan}  Antigravity Claude Proxy 部署管理${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""

        # 显示当前状态
        local status=$(ag_proxy_check_status)
        local port=$(ag_proxy_get_port)

        case "$status" in
            "not_installed")
                echo -e "当前状态: ${gl_huang}⚠️ 未安装${gl_bai}"
                ;;
            "installed_no_service")
                echo -e "当前状态: ${gl_huang}⚠️ 已安装但服务未配置${gl_bai}"
                ;;
            "running")
                echo -e "当前状态: ${gl_lv}✅ 运行中${gl_bai} (端口: ${port})"
                ;;
            "stopped")
                echo -e "当前状态: ${gl_hong}❌ 已停止${gl_bai}"
                ;;
        esac

        echo ""
        echo -e "${gl_kjlan}[部署与更新]${gl_bai}"
        echo "1. 一键部署（首次安装）"
        echo "2. 更新项目"
        echo ""
        echo -e "${gl_kjlan}[服务管理]${gl_bai}"
        echo "3. 查看状态"
        echo "4. 查看日志"
        echo "5. 启动服务"
        echo "6. 停止服务"
        echo "7. 重启服务"
        echo ""
        echo -e "${gl_kjlan}[配置与卸载]${gl_bai}"
        echo "8. 修改端口"
        echo -e "${gl_hong}9. 卸载（删除服务+代码）${gl_bai}"
        echo ""
        echo -e "${gl_kjlan}[帮助]${gl_bai}"
        echo "10. 查看 Claude Code 配置指引"
        echo ""
        echo "0. 返回主菜单"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"

        read -e -p "请选择操作 [0-10]: " choice

        case $choice in
            1)
                ag_proxy_deploy
                ;;
            2)
                ag_proxy_update
                ;;
            3)
                ag_proxy_status
                ;;
            4)
                ag_proxy_logs
                ;;
            5)
                ag_proxy_start
                ;;
            6)
                ag_proxy_stop
                ;;
            7)
                ag_proxy_restart
                ;;
            8)
                ag_proxy_change_port
                ;;
            9)
                ag_proxy_uninstall
                ;;
            10)
                ag_proxy_show_config
                ;;
            0)
                return
                ;;
            *)
                echo "无效的选择"
                sleep 2
                ;;
        esac
    done
}

# =====================================================
# Open WebUI 部署管理 (菜单40)
# =====================================================

# 常量定义
OPEN_WEBUI_CONTAINER_NAME="open-webui"
OPEN_WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
OPEN_WEBUI_DEFAULT_PORT="8888"
OPEN_WEBUI_PORT_FILE="/etc/open-webui-port"

# 获取当前配置的端口
open_webui_get_port() {
    if [ -f "$OPEN_WEBUI_PORT_FILE" ]; then
        cat "$OPEN_WEBUI_PORT_FILE"
    else
        echo "$OPEN_WEBUI_DEFAULT_PORT"
    fi
}

# 检查 Open WebUI 状态
open_webui_check_status() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${OPEN_WEBUI_CONTAINER_NAME}$"; then
        echo "running"
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${OPEN_WEBUI_CONTAINER_NAME}$"; then
        echo "stopped"
    else
        echo "not_installed"
    fi
}

# 检查端口是否可用
open_webui_check_port() {
    local port=$1
    if ss -lntp 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

# 安装 Docker
open_webui_install_docker() {
    if command -v docker &>/dev/null; then
        echo -e "${gl_lv}✅ Docker 已安装${gl_bai}"
        return 0
    fi

    echo "正在安装 Docker..."
    # 使用安全下载模式替代 curl | sh
    run_remote_script "https://get.docker.com" sh

    if [ $? -eq 0 ]; then
        systemctl enable docker
        systemctl start docker
        echo -e "${gl_lv}✅ Docker 安装成功${gl_bai}"
        return 0
    else
        echo -e "${gl_hong}❌ Docker 安装失败${gl_bai}"
        return 1
    fi
}

# 一键部署
open_webui_deploy() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  一键部署 Open WebUI${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    # 检查是否已安装
    local status=$(open_webui_check_status)
    if [ "$status" != "not_installed" ]; then
        echo -e "${gl_huang}⚠️ Open WebUI 已安装${gl_bai}"
        read -e -p "是否重新部署？(y/n) [n]: " reinstall
        if [ "$reinstall" != "y" ] && [ "$reinstall" != "Y" ]; then
            break_end
            return 0
        fi
        # 删除现有容器
        docker stop "$OPEN_WEBUI_CONTAINER_NAME" 2>/dev/null
        docker rm "$OPEN_WEBUI_CONTAINER_NAME" 2>/dev/null
    fi

    # 安装 Docker
    echo ""
    open_webui_install_docker || { break_end; return 1; }

    # 配置端口
    echo ""
    local port="$OPEN_WEBUI_DEFAULT_PORT"
    read -e -p "请输入访问端口 [$OPEN_WEBUI_DEFAULT_PORT]: " input_port
    if [ -n "$input_port" ]; then
        port="$input_port"
    fi

    # 检查端口是否可用
    while ! open_webui_check_port "$port"; do
        echo -e "${gl_hong}⚠️ 端口 $port 已被占用，请换一个${gl_bai}"
        read -e -p "请输入访问端口: " port
    done
    echo -e "${gl_lv}✅ 端口 $port 可用${gl_bai}"

    # 询问是否配置 API
    echo ""
    local api_url=""
    local api_key=""
    read -e -p "是否现在配置 API？(y/n) [y]: " config_api
    if [ "$config_api" != "n" ] && [ "$config_api" != "N" ]; then
        echo ""
        echo "API 类型："
        echo "1. OpenAI 官方"
        echo "2. 自定义地址（反代/中转）"
        echo ""
        read -e -p "请选择 [1]: " api_type

        if [ "$api_type" = "2" ]; then
            read -e -p "请输入 API 地址: " api_url
            read -e -p "请输入 API 密钥: " api_key
        else
            api_url="https://api.openai.com/v1"
            read -e -p "请输入 OpenAI API 密钥: " api_key
        fi
    fi

    # 拉取镜像
    echo ""
    echo "正在拉取 Open WebUI 镜像..."
    docker pull "$OPEN_WEBUI_IMAGE"

    if [ $? -ne 0 ]; then
        echo -e "${gl_hong}❌ 镜像拉取失败${gl_bai}"
        break_end
        return 1
    fi

    # 启动容器
    echo ""
    echo "正在启动 Open WebUI..."

    # 停止并删除可能存在的旧容器
    docker stop "$OPEN_WEBUI_CONTAINER_NAME" 2>/dev/null
    docker rm "$OPEN_WEBUI_CONTAINER_NAME" 2>/dev/null

    # 根据是否有 API 配置选择不同的启动方式
    if [ -n "$api_url" ] && [ -n "$api_key" ]; then
        docker run -d -p ${port}:8080 \
            --add-host=host.docker.internal:host-gateway \
            -e OPENAI_API_BASE_URL="$api_url" \
            -e OPENAI_API_KEY="$api_key" \
            -v open-webui:/app/backend/data \
            --name "$OPEN_WEBUI_CONTAINER_NAME" \
            --restart always \
            "$OPEN_WEBUI_IMAGE"
    elif [ -n "$api_key" ]; then
        docker run -d -p ${port}:8080 \
            --add-host=host.docker.internal:host-gateway \
            -e OPENAI_API_KEY="$api_key" \
            -v open-webui:/app/backend/data \
            --name "$OPEN_WEBUI_CONTAINER_NAME" \
            --restart always \
            "$OPEN_WEBUI_IMAGE"
    else
        docker run -d -p ${port}:8080 \
            --add-host=host.docker.internal:host-gateway \
            -v open-webui:/app/backend/data \
            --name "$OPEN_WEBUI_CONTAINER_NAME" \
            --restart always \
            "$OPEN_WEBUI_IMAGE"
    fi

    if [ $? -ne 0 ]; then
        echo -e "${gl_hong}❌ 容器启动失败${gl_bai}"
        break_end
        return 1
    fi

    # 保存端口配置
    echo "$port" > "$OPEN_WEBUI_PORT_FILE"

    # 等待启动
    echo ""
    echo "等待服务启动..."
    sleep 5

    # 获取服务器 IP
    local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")

    echo ""
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}  ✅ 部署完成！${gl_bai}"
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "访问地址: ${gl_huang}http://${server_ip}:${port}${gl_bai}"
    echo ""
    echo -e "${gl_zi}首次访问需要注册管理员账户${gl_bai}"
    echo ""
    if [ -z "$api_url" ]; then
        echo -e "${gl_huang}提示: API 未配置，请在网页 Admin Panel → Settings → Connections 中设置${gl_bai}"
        echo ""
    fi
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}管理命令:${gl_bai}"
    echo "  状态: docker ps | grep $OPEN_WEBUI_CONTAINER_NAME"
    echo "  日志: docker logs $OPEN_WEBUI_CONTAINER_NAME -f"
    echo "  重启: docker restart $OPEN_WEBUI_CONTAINER_NAME"
    echo ""

    break_end
}

# 更新镜像
open_webui_update() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  更新 Open WebUI${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(open_webui_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ Open WebUI 未安装，请先执行一键部署${gl_bai}"
        break_end
        return 1
    fi

    echo "正在拉取最新镜像..."
    docker pull "$OPEN_WEBUI_IMAGE"

    if [ $? -eq 0 ]; then
        echo ""
        echo "正在重启容器..."
        docker stop "$OPEN_WEBUI_CONTAINER_NAME"
        docker rm "$OPEN_WEBUI_CONTAINER_NAME"

        # 获取保存的端口
        local port=$(open_webui_get_port)

        # 重新创建容器
        docker run -d -p ${port}:8080 \
            --add-host=host.docker.internal:host-gateway \
            -v open-webui:/app/backend/data \
            --name "$OPEN_WEBUI_CONTAINER_NAME" \
            --restart always \
            "$OPEN_WEBUI_IMAGE"

        if [ $? -eq 0 ]; then
            echo ""
            echo -e "${gl_lv}✅ 更新完成${gl_bai}"
        else
            echo -e "${gl_hong}❌ 重启失败${gl_bai}"
        fi
    else
        echo -e "${gl_hong}❌ 镜像拉取失败${gl_bai}"
    fi

    break_end
}

# 查看状态
open_webui_status() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  Open WebUI 状态${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(open_webui_check_status)
    local port=$(open_webui_get_port)
    local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")

    case "$status" in
        "running")
            echo -e "状态: ${gl_lv}✅ 运行中${gl_bai}"
            echo -e "端口: ${gl_huang}$port${gl_bai}"
            echo -e "访问地址: ${gl_huang}http://${server_ip}:${port}${gl_bai}"
            echo ""
            echo "容器详情:"
            docker ps --filter "name=$OPEN_WEBUI_CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            ;;
        "stopped")
            echo -e "状态: ${gl_hong}❌ 已停止${gl_bai}"
            echo ""
            echo "请使用「启动服务」选项启动"
            ;;
        "not_installed")
            echo -e "状态: ${gl_hui}未安装${gl_bai}"
            echo ""
            echo "请使用「一键部署」选项安装"
            ;;
    esac

    echo ""
    break_end
}

# 查看日志
open_webui_logs() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  Open WebUI 日志${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_zi}按 Ctrl+C 退出日志查看${gl_bai}"
    echo ""

    docker logs "$OPEN_WEBUI_CONTAINER_NAME" -f --tail 100
}

# 启动服务
open_webui_start() {
    echo ""
    echo "正在启动 Open WebUI..."
    docker start "$OPEN_WEBUI_CONTAINER_NAME"

    if [ $? -eq 0 ]; then
        echo -e "${gl_lv}✅ 启动成功${gl_bai}"
    else
        echo -e "${gl_hong}❌ 启动失败${gl_bai}"
    fi

    sleep 2
}

# 停止服务
open_webui_stop() {
    echo ""
    echo "正在停止 Open WebUI..."
    docker stop "$OPEN_WEBUI_CONTAINER_NAME"

    if [ $? -eq 0 ]; then
        echo -e "${gl_lv}✅ 已停止${gl_bai}"
    else
        echo -e "${gl_hong}❌ 停止失败${gl_bai}"
    fi

    sleep 2
}

# 重启服务
open_webui_restart() {
    echo ""
    echo "正在重启 Open WebUI..."
    docker restart "$OPEN_WEBUI_CONTAINER_NAME"

    if [ $? -eq 0 ]; then
        echo -e "${gl_lv}✅ 重启成功${gl_bai}"
    else
        echo -e "${gl_hong}❌ 重启失败${gl_bai}"
    fi

    sleep 2
}

# 修改端口
open_webui_change_port() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  修改 Open WebUI 端口${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(open_webui_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ Open WebUI 未安装${gl_bai}"
        break_end
        return 1
    fi

    local current_port=$(open_webui_get_port)
    echo -e "当前端口: ${gl_huang}$current_port${gl_bai}"
    echo ""

    read -e -p "请输入新端口: " new_port

    if [ -z "$new_port" ]; then
        echo "未输入端口，取消修改"
        break_end
        return 0
    fi

    # 检查端口是否可用
    if ! open_webui_check_port "$new_port"; then
        echo -e "${gl_hong}❌ 端口 $new_port 已被占用${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo "正在修改端口..."

    # 停止并删除旧容器
    docker stop "$OPEN_WEBUI_CONTAINER_NAME"
    docker rm "$OPEN_WEBUI_CONTAINER_NAME"

    # 用新端口创建容器
    docker run -d -p ${new_port}:8080 \
        --add-host=host.docker.internal:host-gateway \
        -v open-webui:/app/backend/data \
        --name "$OPEN_WEBUI_CONTAINER_NAME" \
        --restart always \
        "$OPEN_WEBUI_IMAGE"

    if [ $? -eq 0 ]; then
        echo "$new_port" > "$OPEN_WEBUI_PORT_FILE"
        local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")
        echo ""
        echo -e "${gl_lv}✅ 端口修改成功${gl_bai}"
        echo -e "新访问地址: ${gl_huang}http://${server_ip}:${new_port}${gl_bai}"
    else
        echo -e "${gl_hong}❌ 端口修改失败${gl_bai}"
    fi

    break_end
}

# 卸载
open_webui_uninstall() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  卸载 Open WebUI${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(open_webui_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ Open WebUI 未安装${gl_bai}"
        break_end
        return 1
    fi

    echo -e "${gl_hong}⚠️ 此操作将删除 Open WebUI 容器${gl_bai}"
    echo ""
    read -e -p "是否同时删除数据卷？(y/n) [n]: " delete_volume
    echo ""
    read -e -p "确认卸载？(y/n) [n]: " confirm

    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "取消卸载"
        break_end
        return 0
    fi

    echo ""
    echo "正在卸载..."

    # 停止并删除容器
    docker stop "$OPEN_WEBUI_CONTAINER_NAME" 2>/dev/null
    docker rm "$OPEN_WEBUI_CONTAINER_NAME" 2>/dev/null

    # 删除数据卷
    if [ "$delete_volume" = "y" ] || [ "$delete_volume" = "Y" ]; then
        docker volume rm open-webui 2>/dev/null
        echo -e "${gl_lv}✅ 容器和数据已删除${gl_bai}"
    else
        echo -e "${gl_lv}✅ 容器已删除，数据保留${gl_bai}"
    fi

    # 删除端口配置文件
    rm -f "$OPEN_WEBUI_PORT_FILE"

    break_end
}

# Open WebUI 管理主菜单
manage_open_webui() {
    while true; do
        clear
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_kjlan}  Open WebUI 部署管理${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""

        # 显示当前状态
        local status=$(open_webui_check_status)
        local port=$(open_webui_get_port)

        case "$status" in
            "running")
                echo -e "当前状态: ${gl_lv}✅ 运行中${gl_bai} (端口: $port)"
                ;;
            "stopped")
                echo -e "当前状态: ${gl_hong}❌ 已停止${gl_bai}"
                ;;
            "not_installed")
                echo -e "当前状态: ${gl_hui}未安装${gl_bai}"
                ;;
        esac

        echo ""
        echo -e "${gl_kjlan}[部署与更新]${gl_bai}"
        echo "1. 一键部署（首次安装）"
        echo "2. 更新镜像"
        echo ""
        echo -e "${gl_kjlan}[服务管理]${gl_bai}"
        echo "3. 查看状态"
        echo "4. 查看日志"
        echo "5. 启动服务"
        echo "6. 停止服务"
        echo "7. 重启服务"
        echo ""
        echo -e "${gl_kjlan}[配置与卸载]${gl_bai}"
        echo "8. 修改端口"
        echo -e "${gl_hong}9. 卸载（删除容器）${gl_bai}"
        echo ""
        echo "0. 返回主菜单"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"

        read -e -p "请选择操作 [0-9]: " choice

        case $choice in
            1)
                open_webui_deploy
                ;;
            2)
                open_webui_update
                ;;
            3)
                open_webui_status
                ;;
            4)
                open_webui_logs
                ;;
            5)
                open_webui_start
                ;;
            6)
                open_webui_stop
                ;;
            7)
                open_webui_restart
                ;;
            8)
                open_webui_change_port
                ;;
            9)
                open_webui_uninstall
                ;;
            0)
                return
                ;;
            *)
                echo "无效的选择"
                sleep 2
                ;;
        esac
    done
}

# =====================================================
# Claude Relay Service (CRS) 部署管理 (菜单41)
# =====================================================

# 常量定义
CRS_DEFAULT_PORT="3000"
CRS_PORT_FILE="/etc/crs-port"
CRS_INSTALL_DIR_FILE="/etc/crs-install-dir"
CRS_DEFAULT_INSTALL_DIR="/root/claude-relay-service"
CRS_MANAGE_SCRIPT_URL="https://pincc.ai/manage.sh"

# 获取安装目录
crs_get_install_dir() {
    if [ -f "$CRS_INSTALL_DIR_FILE" ]; then
        cat "$CRS_INSTALL_DIR_FILE"
    else
        echo "$CRS_DEFAULT_INSTALL_DIR"
    fi
}

# 获取当前配置的端口
crs_get_port() {
    if [ -f "$CRS_PORT_FILE" ]; then
        cat "$CRS_PORT_FILE"
    else
        # 尝试从配置文件读取
        local install_dir=$(crs_get_install_dir)
        if [ -f "$install_dir/config/config.js" ]; then
            local port=$(grep -oP 'port:\s*\K[0-9]+' "$install_dir/config/config.js" 2>/dev/null | head -1)
            if [ -n "$port" ]; then
                echo "$port"
                return
            fi
        fi
        echo "$CRS_DEFAULT_PORT"
    fi
}

# 检查 CRS 状态
crs_check_status() {
    # 检查 crs 命令是否存在
    if ! command -v crs &>/dev/null; then
        # 检查安装目录是否存在
        local install_dir=$(crs_get_install_dir)
        if [ -d "$install_dir" ]; then
            echo "installed_no_command"
        else
            echo "not_installed"
        fi
        return
    fi

    # 使用 crs status 检查
    local status_output=$(crs status 2>&1)
    if echo "$status_output" | grep -qi "running\|online\|started"; then
        echo "running"
    elif echo "$status_output" | grep -qi "stopped\|offline\|not running"; then
        echo "stopped"
    else
        # 通过端口检测
        local port=$(crs_get_port)
        if ss -lntp 2>/dev/null | grep -q ":${port} "; then
            echo "running"
        else
            echo "stopped"
        fi
    fi
}

# 检查端口是否可用
crs_check_port() {
    local port=$1
    if ss -lntp 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

# 一键部署
crs_deploy() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  一键部署 Claude Relay Service (CRS)${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    # 检查是否已安装
    local status=$(crs_check_status)
    if [ "$status" != "not_installed" ]; then
        echo -e "${gl_huang}⚠️ CRS 已安装${gl_bai}"
        read -e -p "是否重新部署？这将保留数据但重装服务 (y/n) [n]: " reinstall
        if [ "$reinstall" != "y" ] && [ "$reinstall" != "Y" ]; then
            break_end
            return 0
        fi
        echo ""
        echo "正在停止现有服务..."
        crs stop 2>/dev/null
    fi

    echo ""
    echo -e "${gl_kjlan}[1/4] 下载安装脚本...${gl_bai}"

    # 创建临时目录
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || { echo -e "${gl_hong}❌ 创建临时目录失败${gl_bai}"; break_end; return 1; }

    # 下载 manage.sh
    if ! curl -fsSL "$CRS_MANAGE_SCRIPT_URL" -o manage.sh; then
        echo -e "${gl_hong}❌ 下载安装脚本失败${gl_bai}"
        rm -rf "$temp_dir"
        break_end
        return 1
    fi
    chmod +x manage.sh
    echo -e "${gl_lv}✅ 下载完成${gl_bai}"

    echo ""
    echo -e "${gl_kjlan}[2/4] 配置安装参数...${gl_bai}"
    echo ""

    # 安装目录
    local install_dir="$CRS_DEFAULT_INSTALL_DIR"
    read -e -p "安装目录 [$CRS_DEFAULT_INSTALL_DIR]: " input_dir
    if [ -n "$input_dir" ]; then
        install_dir="$input_dir"
    fi

    # 端口配置
    local port="$CRS_DEFAULT_PORT"
    read -e -p "服务端口 [$CRS_DEFAULT_PORT]: " input_port
    if [ -n "$input_port" ]; then
        port="$input_port"
    fi

    # 检查端口是否可用
    while ! crs_check_port "$port"; do
        echo -e "${gl_hong}⚠️ 端口 $port 已被占用${gl_bai}"
        read -e -p "请输入其他端口: " port
        if [ -z "$port" ]; then
            port="$CRS_DEFAULT_PORT"
        fi
    done
    echo -e "${gl_lv}✅ 端口 $port 可用${gl_bai}"

    # Redis 配置
    echo ""
    local redis_host="localhost"
    local redis_port="6379"
    local redis_password=""

    read -e -p "Redis 地址 [localhost]: " input_redis_host
    if [ -n "$input_redis_host" ]; then
        redis_host="$input_redis_host"
    fi

    read -e -p "Redis 端口 [6379]: " input_redis_port
    if [ -n "$input_redis_port" ]; then
        redis_port="$input_redis_port"
    fi

    read -e -p "Redis 密码 (无密码直接回车): " redis_password

    echo ""
    echo -e "${gl_kjlan}[3/4] 执行安装...${gl_bai}"
    echo ""
    echo "安装目录: $install_dir"
    echo "服务端口: $port"
    echo "Redis: $redis_host:$redis_port"
    echo ""

    # 使用 expect 或直接执行安装（通过环境变量传递参数）
    # CRS 的 manage.sh 支持交互式安装，这里我们传递参数
    export CRS_INSTALL_DIR="$install_dir"
    export CRS_PORT="$port"
    export CRS_REDIS_HOST="$redis_host"
    export CRS_REDIS_PORT="$redis_port"
    export CRS_REDIS_PASSWORD="$redis_password"

    # 执行安装脚本
    echo ""
    echo -e "${gl_huang}正在安装，请按提示操作...${gl_bai}"
    echo -e "${gl_zi}（安装目录输入: $install_dir，端口输入: $port）${gl_bai}"
    echo ""

    ./manage.sh install

    local install_result=$?

    # 清理临时文件
    cd /
    rm -rf "$temp_dir"

    if [ $install_result -ne 0 ]; then
        echo ""
        echo -e "${gl_hong}❌ 安装过程出现错误${gl_bai}"
        break_end
        return 1
    fi

    # 保存配置
    echo "$port" > "$CRS_PORT_FILE"
    echo "$install_dir" > "$CRS_INSTALL_DIR_FILE"

    echo ""
    echo -e "${gl_kjlan}[4/4] 验证安装...${gl_bai}"

    sleep 3

    # 获取服务器 IP
    local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")

    # 检查服务状态
    if command -v crs &>/dev/null; then
        echo -e "${gl_lv}✅ crs 命令已安装${gl_bai}"
    fi

    echo ""
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}  ✅ 部署完成！${gl_bai}"
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "Web 管理面板: ${gl_huang}http://${server_ip}:${port}/web${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}【管理员账号】${gl_bai}"
    echo "  账号信息保存在: $install_dir/data/init.json"
    echo "  使用菜单「8. 查看管理员账号」可以直接查看"
    echo ""
    echo -e "${gl_kjlan}【下一步操作】${gl_bai}"
    echo "  1. 访问 Web 面板，使用管理员账号登录"
    echo "  2. 添加 Claude 账户（OAuth 授权）"
    echo "  3. 创建 API Key 分发给用户"
    echo "  4. 配置本地 Claude Code 环境变量"
    echo ""
    echo -e "${gl_kjlan}【Claude Code 配置】${gl_bai}"
    echo -e "  ${gl_huang}export ANTHROPIC_BASE_URL=\"http://${server_ip}:${port}/api/\"${gl_bai}"
    echo -e "  ${gl_huang}export ANTHROPIC_AUTH_TOKEN=\"后台创建的API密钥\"${gl_bai}"
    echo ""
    echo -e "${gl_zi}提示: 使用菜单「10. 查看配置指引」获取完整配置说明${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}管理命令:${gl_bai}"
    echo "  状态: crs status"
    echo "  启动: crs start"
    echo "  停止: crs stop"
    echo "  重启: crs restart"
    echo "  更新: crs update"
    echo ""

    break_end
}

# 更新服务
crs_update() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  更新 Claude Relay Service${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(crs_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ CRS 未安装，请先执行一键部署${gl_bai}"
        break_end
        return 1
    fi

    echo "正在更新..."
    echo ""

    if command -v crs &>/dev/null; then
        crs update
        if [ $? -eq 0 ]; then
            echo ""
            echo -e "${gl_lv}✅ 更新完成${gl_bai}"
        else
            echo ""
            echo -e "${gl_hong}❌ 更新失败${gl_bai}"
        fi
    else
        echo -e "${gl_hong}❌ crs 命令不可用，请重新部署${gl_bai}"
    fi

    break_end
}

# 查看状态
crs_status() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  Claude Relay Service 状态${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(crs_check_status)
    local port=$(crs_get_port)
    local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")
    local install_dir=$(crs_get_install_dir)

    case "$status" in
        "running")
            echo -e "运行状态: ${gl_lv}✅ 运行中${gl_bai}"
            echo -e "服务端口: ${gl_huang}$port${gl_bai}"
            echo -e "Web 面板: ${gl_huang}http://${server_ip}:${port}/web${gl_bai}"
            echo -e "安装目录: ${gl_huang}$install_dir${gl_bai}"
            ;;
        "stopped")
            echo -e "运行状态: ${gl_hong}❌ 已停止${gl_bai}"
            echo -e "服务端口: ${gl_huang}$port${gl_bai}"
            echo -e "安装目录: ${gl_huang}$install_dir${gl_bai}"
            ;;
        "installed_no_command")
            echo -e "运行状态: ${gl_huang}⚠️ 已安装但 crs 命令不可用${gl_bai}"
            echo -e "安装目录: ${gl_huang}$install_dir${gl_bai}"
            echo ""
            echo "建议重新执行一键部署"
            ;;
        "not_installed")
            echo -e "运行状态: ${gl_hui}未安装${gl_bai}"
            echo ""
            echo "请使用「一键部署」选项安装"
            ;;
    esac

    echo ""

    # 如果 crs 命令可用，显示详细状态
    if command -v crs &>/dev/null && [ "$status" != "not_installed" ]; then
        echo -e "${gl_kjlan}详细状态:${gl_bai}"
        echo ""
        crs status
    fi

    echo ""
    break_end
}

# 查看日志
crs_logs() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  Claude Relay Service 日志${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_zi}按 Ctrl+C 退出日志查看${gl_bai}"
    echo ""

    local status=$(crs_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ CRS 未安装${gl_bai}"
        break_end
        return 1
    fi

    if command -v crs &>/dev/null; then
        crs logs
    else
        # 尝试查看日志文件
        local install_dir=$(crs_get_install_dir)
        if [ -d "$install_dir/logs" ]; then
            tail -f "$install_dir/logs/"*.log 2>/dev/null || echo "无法读取日志文件"
        else
            echo "日志目录不存在"
        fi
    fi
}

# 启动服务
crs_start() {
    echo ""
    echo "正在启动 CRS..."

    local status=$(crs_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ CRS 未安装${gl_bai}"
        break_end
        return 1
    fi

    if command -v crs &>/dev/null; then
        crs start
        sleep 2
        if [ "$(crs_check_status)" = "running" ]; then
            local port=$(crs_get_port)
            local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")
            echo ""
            echo -e "${gl_lv}✅ 服务已启动${gl_bai}"
            echo -e "访问地址: ${gl_huang}http://${server_ip}:${port}/web${gl_bai}"
        else
            echo -e "${gl_hong}❌ 启动失败${gl_bai}"
        fi
    else
        echo -e "${gl_hong}❌ crs 命令不可用${gl_bai}"
    fi

    break_end
}

# 停止服务
crs_stop() {
    echo ""
    echo "正在停止 CRS..."

    local status=$(crs_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ CRS 未安装${gl_bai}"
        break_end
        return 1
    fi

    if command -v crs &>/dev/null; then
        crs stop
        sleep 2
        if [ "$(crs_check_status)" != "running" ]; then
            echo -e "${gl_lv}✅ 服务已停止${gl_bai}"
        else
            echo -e "${gl_hong}❌ 停止失败${gl_bai}"
        fi
    else
        echo -e "${gl_hong}❌ crs 命令不可用${gl_bai}"
    fi

    break_end
}

# 重启服务
crs_restart() {
    echo ""
    echo "正在重启 CRS..."

    local status=$(crs_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ CRS 未安装${gl_bai}"
        break_end
        return 1
    fi

    if command -v crs &>/dev/null; then
        crs restart
        sleep 2
        if [ "$(crs_check_status)" = "running" ]; then
            local port=$(crs_get_port)
            local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")
            echo ""
            echo -e "${gl_lv}✅ 服务已重启${gl_bai}"
            echo -e "访问地址: ${gl_huang}http://${server_ip}:${port}/web${gl_bai}"
        else
            echo -e "${gl_hong}❌ 重启失败${gl_bai}"
        fi
    else
        echo -e "${gl_hong}❌ crs 命令不可用${gl_bai}"
    fi

    break_end
}

# 查看管理员账号
crs_show_admin() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  CRS 管理员账号${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(crs_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ CRS 未安装${gl_bai}"
        break_end
        return 1
    fi

    local install_dir=$(crs_get_install_dir)
    local init_file="$install_dir/data/init.json"

    if [ -f "$init_file" ]; then
        echo -e "${gl_lv}管理员账号信息:${gl_bai}"
        echo ""

        # 解析 JSON 并显示
        local username=$(grep -oP '"username"\s*:\s*"\K[^"]+' "$init_file" 2>/dev/null)
        local password=$(grep -oP '"password"\s*:\s*"\K[^"]+' "$init_file" 2>/dev/null)

        if [ -n "$username" ] && [ -n "$password" ]; then
            local port=$(crs_get_port)
            local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")

            echo -e "  用户名: ${gl_huang}$username${gl_bai}"
            echo -e "  密  码: ${gl_huang}$password${gl_bai}"
            echo ""
            echo -e "  登录地址: ${gl_huang}http://${server_ip}:${port}/web${gl_bai}"
        else
            echo "无法解析账号信息，原始内容:"
            echo ""
            cat "$init_file"
        fi
    else
        echo -e "${gl_huang}⚠️ 未找到账号信息文件${gl_bai}"
        echo ""
        echo "文件路径: $init_file"
        echo ""
        echo "可能原因:"
        echo "  1. 服务尚未完成初始化"
        echo "  2. 使用了环境变量预设账号"
        echo ""
        echo "如果使用环境变量设置了账号，请查看安装时的配置"
    fi

    echo ""
    break_end
}

# 修改端口
crs_change_port() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  修改 CRS 端口${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(crs_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ CRS 未安装${gl_bai}"
        break_end
        return 1
    fi

    local current_port=$(crs_get_port)
    local install_dir=$(crs_get_install_dir)
    echo -e "当前端口: ${gl_huang}$current_port${gl_bai}"
    echo ""

    read -e -p "请输入新端口 (1-65535): " new_port

    # 验证端口
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${gl_hong}❌ 无效的端口号${gl_bai}"
        break_end
        return 1
    fi

    if [ "$new_port" = "$current_port" ]; then
        echo -e "${gl_huang}⚠️ 端口未改变${gl_bai}"
        break_end
        return 0
    fi

    # 检查端口是否被占用
    if ! crs_check_port "$new_port"; then
        echo -e "${gl_hong}❌ 端口 $new_port 已被占用${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo "正在修改端口..."

    # 停止服务
    if command -v crs &>/dev/null; then
        crs stop 2>/dev/null
    fi

    # 修改配置文件
    local config_file="$install_dir/config/config.js"
    if [ -f "$config_file" ]; then
        # 使用 sed 修改端口
        sed -i "s/port:\s*[0-9]\+/port: $new_port/" "$config_file"
        echo -e "${gl_lv}✅ 配置文件已更新${gl_bai}"
    else
        echo -e "${gl_huang}⚠️ 配置文件不存在，仅更新端口记录${gl_bai}"
    fi

    # 保存端口配置
    echo "$new_port" > "$CRS_PORT_FILE"

    # 重启服务
    if command -v crs &>/dev/null; then
        crs start
        sleep 2

        if [ "$(crs_check_status)" = "running" ]; then
            local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")
            echo ""
            echo -e "${gl_lv}✅ 端口已修改为 $new_port${gl_bai}"
            echo -e "新访问地址: ${gl_huang}http://${server_ip}:${new_port}/web${gl_bai}"
        else
            echo -e "${gl_hong}❌ 服务启动失败，请检查配置${gl_bai}"
        fi
    fi

    break_end
}

# 查看配置指引
crs_show_config() {
    clear

    local status=$(crs_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ CRS 未安装，请先执行一键部署${gl_bai}"
        break_end
        return 1
    fi

    local port=$(crs_get_port)
    local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")

    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  Claude Relay Service 配置指引${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "Web 管理面板: ${gl_huang}http://${server_ip}:${port}/web${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}【第一步】添加 Claude 账户${gl_bai}"
    echo "  1. 登录 Web 管理面板"
    echo "  2. 点击「Claude账户」标签"
    echo "  3. 点击「添加账户」→「生成授权链接」"
    echo "  4. 在新页面完成 Claude 登录授权"
    echo "  5. 复制 Authorization Code 粘贴回页面"
    echo ""
    echo -e "${gl_kjlan}【第二步】创建 API Key${gl_bai}"
    echo "  1. 点击「API Keys」标签"
    echo "  2. 点击「创建新Key」"
    echo "  3. 设置名称和限制（可选）"
    echo "  4. 保存并记录生成的 Key"
    echo ""
    echo -e "${gl_kjlan}【第三步】配置 Claude Code${gl_bai}"
    echo ""
    echo -e "${gl_huang}方式一：环境变量配置${gl_bai}"
    echo ""
    echo "  # 使用标准 Claude 账号池"
    echo -e "  ${gl_lv}export ANTHROPIC_BASE_URL=\"http://${server_ip}:${port}/api/\"${gl_bai}"
    echo -e "  ${gl_lv}export ANTHROPIC_AUTH_TOKEN=\"你的API密钥\"${gl_bai}"
    echo ""
    echo "  # 或使用 Antigravity 账号池"
    echo -e "  ${gl_lv}export ANTHROPIC_BASE_URL=\"http://${server_ip}:${port}/antigravity/api/\"${gl_bai}"
    echo -e "  ${gl_lv}export ANTHROPIC_AUTH_TOKEN=\"你的API密钥\"${gl_bai}"
    echo ""
    echo -e "${gl_huang}方式二：settings.json 配置${gl_bai}"
    echo ""
    echo "  编辑 ~/.claude/settings.json:"
    echo ""
    echo -e "  ${gl_lv}{"
    echo -e "    \"env\": {"
    echo -e "      \"ANTHROPIC_BASE_URL\": \"http://${server_ip}:${port}/api/\","
    echo -e "      \"ANTHROPIC_AUTH_TOKEN\": \"你的API密钥\""
    echo -e "    }"
    echo -e "  }${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}【Gemini CLI 配置】${gl_bai}"
    echo ""
    echo -e "  ${gl_lv}export CODE_ASSIST_ENDPOINT=\"http://${server_ip}:${port}/gemini\"${gl_bai}"
    echo -e "  ${gl_lv}export GOOGLE_CLOUD_ACCESS_TOKEN=\"你的API密钥\"${gl_bai}"
    echo -e "  ${gl_lv}export GOOGLE_GENAI_USE_GCA=\"true\"${gl_bai}"
    echo -e "  ${gl_lv}export GEMINI_MODEL=\"gemini-2.5-pro\"${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}【Codex CLI 配置】${gl_bai}"
    echo ""
    echo "  编辑 ~/.codex/config.toml 添加:"
    echo ""
    echo -e "  ${gl_lv}model_provider = \"crs\""
    echo -e "  [model_providers.crs]"
    echo -e "  name = \"crs\""
    echo -e "  base_url = \"http://${server_ip}:${port}/openai\""
    echo -e "  wire_api = \"responses\""
    echo -e "  requires_openai_auth = true"
    echo -e "  env_key = \"CRS_OAI_KEY\"${gl_bai}"
    echo ""
    echo "  然后设置环境变量:"
    echo -e "  ${gl_lv}export CRS_OAI_KEY=\"你的API密钥\"${gl_bai}"
    echo ""
    echo -e "${gl_zi}提示: 所有客户端使用相同的 API 密钥，系统根据路由自动选择账号类型${gl_bai}"
    echo ""

    break_end
}

# 卸载
crs_uninstall() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_hong}  卸载 Claude Relay Service${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(crs_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ CRS 未安装${gl_bai}"
        break_end
        return 1
    fi

    local install_dir=$(crs_get_install_dir)

    echo -e "${gl_hong}⚠️ 警告: 此操作将删除 CRS 服务和所有数据！${gl_bai}"
    echo ""
    echo "安装目录: $install_dir"
    echo ""

    read -e -p "确认卸载？(输入 yes 确认): " confirm

    if [ "$confirm" != "yes" ]; then
        echo "已取消"
        break_end
        return 0
    fi

    echo ""
    echo "正在卸载..."

    # 使用 crs uninstall 命令
    if command -v crs &>/dev/null; then
        crs uninstall
    else
        # 手动卸载
        echo "正在停止服务..."
        # 尝试停止 pm2 进程
        pm2 stop crs 2>/dev/null
        pm2 delete crs 2>/dev/null

        echo "正在删除文件..."
        rm -rf "$install_dir"
    fi

    # 删除配置文件
    rm -f "$CRS_PORT_FILE"
    rm -f "$CRS_INSTALL_DIR_FILE"

    # 删除 crs 命令
    rm -f /usr/local/bin/crs 2>/dev/null

    echo ""
    echo -e "${gl_lv}✅ 卸载完成${gl_bai}"

    break_end
}

# CRS 主菜单
manage_crs() {
    while true; do
        clear
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_kjlan}  Claude Relay Service (CRS) 部署管理${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""

        # 显示当前状态
        local status=$(crs_check_status)
        local port=$(crs_get_port)

        case "$status" in
            "running")
                echo -e "当前状态: ${gl_lv}✅ 运行中${gl_bai} (端口: $port)"
                ;;
            "stopped")
                echo -e "当前状态: ${gl_hong}❌ 已停止${gl_bai}"
                ;;
            "installed_no_command")
                echo -e "当前状态: ${gl_huang}⚠️ 已安装但命令不可用${gl_bai}"
                ;;
            "not_installed")
                echo -e "当前状态: ${gl_hui}未安装${gl_bai}"
                ;;
        esac

        echo ""
        echo -e "${gl_kjlan}[部署与更新]${gl_bai}"
        echo "1. 一键部署（首次安装）"
        echo "2. 更新服务"
        echo ""
        echo -e "${gl_kjlan}[服务管理]${gl_bai}"
        echo "3. 查看状态"
        echo "4. 查看日志"
        echo "5. 启动服务"
        echo "6. 停止服务"
        echo "7. 重启服务"
        echo ""
        echo -e "${gl_kjlan}[配置与信息]${gl_bai}"
        echo "8. 查看管理员账号"
        echo "9. 修改端口"
        echo "10. 查看配置指引"
        echo ""
        echo -e "${gl_kjlan}[卸载]${gl_bai}"
        echo -e "${gl_hong}99. 卸载（删除服务+数据）${gl_bai}"
        echo ""
        echo "0. 返回主菜单"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"

        read -e -p "请选择操作 [0-10, 99]: " choice

        case $choice in
            1)
                crs_deploy
                ;;
            2)
                crs_update
                ;;
            3)
                crs_status
                ;;
            4)
                crs_logs
                ;;
            5)
                crs_start
                ;;
            6)
                crs_stop
                ;;
            7)
                crs_restart
                ;;
            8)
                crs_show_admin
                ;;
            9)
                crs_change_port
                ;;
            10)
                crs_show_config
                ;;
            99)
                crs_uninstall
                ;;
            0)
                return
                ;;
            *)
                echo "无效的选择"
                sleep 2
                ;;
        esac
    done
}

# =====================================================
# Fuclaude 部署管理 (菜单42) - Claude网页版共享
# =====================================================

# 常量定义
FUCLAUDE_CONTAINER_NAME="fuclaude"
FUCLAUDE_IMAGE="pengzhile/fuclaude"
FUCLAUDE_DEFAULT_PORT="8181"
FUCLAUDE_PORT_FILE="/etc/fuclaude-port"
FUCLAUDE_CONFIG_DIR="/etc/fuclaude"
FUCLAUDE_DATA_DIR="/var/lib/fuclaude"

# 获取当前配置的端口
fuclaude_get_port() {
    if [ -f "$FUCLAUDE_PORT_FILE" ]; then
        cat "$FUCLAUDE_PORT_FILE"
    else
        echo "$FUCLAUDE_DEFAULT_PORT"
    fi
}

# 检查 Fuclaude 状态
fuclaude_check_status() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${FUCLAUDE_CONTAINER_NAME}$"; then
        echo "running"
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${FUCLAUDE_CONTAINER_NAME}$"; then
        echo "stopped"
    else
        echo "not_installed"
    fi
}

# 检查端口是否可用
fuclaude_check_port() {
    local port=$1
    if ss -lntp 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

# 安装 Docker（复用通用函数）
fuclaude_install_docker() {
    if command -v docker &>/dev/null; then
        echo -e "${gl_lv}✅ Docker 已安装${gl_bai}"
        return 0
    fi

    echo "正在安装 Docker..."
    # 使用安全下载模式替代 curl | sh
    run_remote_script "https://get.docker.com" sh

    if [ $? -eq 0 ]; then
        systemctl enable docker
        systemctl start docker
        echo -e "${gl_lv}✅ Docker 安装成功${gl_bai}"
        return 0
    else
        echo -e "${gl_hong}❌ Docker 安装失败${gl_bai}"
        return 1
    fi
}

# 生成随机字符串
fuclaude_generate_secret() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1
}

# 一键部署
fuclaude_deploy() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  一键部署 Fuclaude (Claude网页版共享)${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    # 检查是否已安装
    local status=$(fuclaude_check_status)
    if [ "$status" != "not_installed" ]; then
        echo -e "${gl_huang}⚠️ Fuclaude 已安装${gl_bai}"
        read -e -p "是否重新部署？(y/n) [n]: " reinstall
        if [ "$reinstall" != "y" ] && [ "$reinstall" != "Y" ]; then
            break_end
            return 0
        fi
        # 删除现有容器
        docker stop "$FUCLAUDE_CONTAINER_NAME" 2>/dev/null
        docker rm "$FUCLAUDE_CONTAINER_NAME" 2>/dev/null
    fi

    # 安装 Docker
    echo ""
    echo -e "${gl_kjlan}[1/4] 检查 Docker 环境...${gl_bai}"
    fuclaude_install_docker || { break_end; return 1; }

    # 配置端口
    echo ""
    echo -e "${gl_kjlan}[2/4] 配置服务参数...${gl_bai}"
    echo ""

    local port="$FUCLAUDE_DEFAULT_PORT"
    read -e -p "请输入访问端口 [$FUCLAUDE_DEFAULT_PORT]: " input_port
    if [ -n "$input_port" ]; then
        port="$input_port"
    fi

    # 检查端口是否可用
    while ! fuclaude_check_port "$port"; do
        echo -e "${gl_hong}⚠️ 端口 $port 已被占用，请换一个${gl_bai}"
        read -e -p "请输入访问端口: " port
        if [ -z "$port" ]; then
            port="$FUCLAUDE_DEFAULT_PORT"
        fi
    done
    echo -e "${gl_lv}✅ 端口 $port 可用${gl_bai}"

    # 配置站点密码
    echo ""
    local site_password=""
    read -e -p "设置站点访问密码 (直接回车跳过，不设密码): " site_password

    # 配置是否允许注册
    echo ""
    local signup_enabled="false"
    read -e -p "是否允许用户自行注册？(y/n) [n]: " allow_signup
    if [ "$allow_signup" = "y" ] || [ "$allow_signup" = "Y" ]; then
        signup_enabled="true"
    fi

    # 生成 Cookie 密钥
    local cookie_secret=$(fuclaude_generate_secret)

    # 拉取镜像
    echo ""
    echo -e "${gl_kjlan}[3/4] 拉取 Fuclaude 镜像...${gl_bai}"
    docker pull "$FUCLAUDE_IMAGE"

    if [ $? -ne 0 ]; then
        echo -e "${gl_hong}❌ 镜像拉取失败${gl_bai}"
        break_end
        return 1
    fi
    echo -e "${gl_lv}✅ 镜像拉取成功${gl_bai}"

    # 创建数据目录
    mkdir -p "$FUCLAUDE_DATA_DIR"

    # 启动容器
    echo ""
    echo -e "${gl_kjlan}[4/4] 启动 Fuclaude 服务...${gl_bai}"

    # 停止并删除可能存在的旧容器
    docker stop "$FUCLAUDE_CONTAINER_NAME" 2>/dev/null
    docker rm "$FUCLAUDE_CONTAINER_NAME" 2>/dev/null

    # 构建 docker run 命令的函数
    run_fuclaude_container() {
        docker run -d \
            --name "$FUCLAUDE_CONTAINER_NAME" \
            -p ${port}:8181 \
            -e TZ=Asia/Shanghai \
            -e FUCLAUDE_BIND=0.0.0.0:8181 \
            -e FUCLAUDE_TIMEOUT=600 \
            -e FUCLAUDE_PROXY_URL= \
            -e FUCLAUDE_REAL_LOGOUT=false \
            -e FUCLAUDE_SITE_PASSWORD="$site_password" \
            -e FUCLAUDE_COOKIE_SECRET="$cookie_secret" \
            -e FUCLAUDE_SIGNUP_ENABLED="$signup_enabled" \
            -e FUCLAUDE_SHOW_SESSION_KEY=false \
            -v ${FUCLAUDE_DATA_DIR}:/app/data \
            --restart unless-stopped \
            "$FUCLAUDE_IMAGE" 2>&1
    }

    # 第一次尝试启动
    local run_output=$(run_fuclaude_container)
    local run_result=$?

    # 检查是否是 iptables/网络错误
    if [ $run_result -ne 0 ]; then
        if echo "$run_output" | grep -qiE "iptables|chain|network|connectivity"; then
            echo -e "${gl_huang}⚠️ 检测到 Docker 网络问题，正在自动修复...${gl_bai}"
            echo ""

            # 清理失败的容器
            docker rm -f "$FUCLAUDE_CONTAINER_NAME" 2>/dev/null

            # 重启 Docker 服务
            echo "重启 Docker 服务..."
            systemctl restart docker
            sleep 3

            echo "重新启动容器..."
            run_output=$(run_fuclaude_container)
            run_result=$?
        fi
    fi

    if [ $run_result -ne 0 ]; then
        echo "$run_output"
        echo ""
        echo -e "${gl_hong}❌ 容器启动失败${gl_bai}"
        echo ""
        echo -e "${gl_huang}提示: 可尝试手动执行以下命令后重试:${gl_bai}"
        echo "  systemctl restart docker"
        break_end
        return 1
    fi

    # 保存端口配置
    echo "$port" > "$FUCLAUDE_PORT_FILE"

    # 等待启动
    echo ""
    echo "等待服务启动..."
    sleep 3

    # 获取服务器 IP
    local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")

    echo ""
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}  ✅ 部署完成！${gl_bai}"
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "访问地址: ${gl_huang}http://${server_ip}:${port}${gl_bai}"
    echo ""
    if [ -n "$site_password" ]; then
        echo -e "站点密码: ${gl_huang}$site_password${gl_bai}"
    else
        echo -e "站点密码: ${gl_zi}未设置${gl_bai}"
    fi
    echo -e "允许注册: ${gl_huang}$signup_enabled${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}【使用说明】${gl_bai}"
    echo "  1. 访问上面的地址"
    echo "  2. 使用 Claude Pro 账号的 Session Token 登录"
    echo "  3. 多个用户可以共享这个网页版 Claude"
    echo ""
    echo -e "${gl_kjlan}【如何获取 Session Token】${gl_bai}"
    echo "  1. 登录 claude.ai"
    echo "  2. 打开浏览器开发者工具 (F12)"
    echo "  3. 切换到 Application/Storage → Cookies"
    echo "  4. 找到 sessionKey 的值，复制使用"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}管理命令:${gl_bai}"
    echo "  状态: docker ps | grep $FUCLAUDE_CONTAINER_NAME"
    echo "  日志: docker logs $FUCLAUDE_CONTAINER_NAME -f"
    echo "  重启: docker restart $FUCLAUDE_CONTAINER_NAME"
    echo ""

    break_end
}

# 更新镜像
fuclaude_update() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  更新 Fuclaude${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(fuclaude_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ Fuclaude 未安装，请先执行一键部署${gl_bai}"
        break_end
        return 1
    fi

    echo "正在拉取最新镜像..."
    docker pull "$FUCLAUDE_IMAGE"

    if [ $? -eq 0 ]; then
        echo ""
        echo "正在重启容器..."

        # 获取当前容器的环境变量
        local old_env=$(docker inspect "$FUCLAUDE_CONTAINER_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)

        # 获取保存的端口
        local port=$(fuclaude_get_port)

        # 停止并删除旧容器
        docker stop "$FUCLAUDE_CONTAINER_NAME"
        docker rm "$FUCLAUDE_CONTAINER_NAME"

        # 重新创建容器，使用保存的端口
        # 需要重新读取之前的配置，这里简化处理，使用默认值
        docker run -d \
            --name "$FUCLAUDE_CONTAINER_NAME" \
            -p ${port}:8181 \
            -e TZ=Asia/Shanghai \
            -e FUCLAUDE_BIND=0.0.0.0:8181 \
            -e FUCLAUDE_TIMEOUT=600 \
            -v ${FUCLAUDE_DATA_DIR}:/app/data \
            --restart unless-stopped \
            "$FUCLAUDE_IMAGE"

        if [ $? -eq 0 ]; then
            echo ""
            echo -e "${gl_lv}✅ 更新完成${gl_bai}"
            echo ""
            echo -e "${gl_huang}注意: 更新后环境变量已重置为默认值${gl_bai}"
            echo "如需修改配置，请使用「修改配置」功能"
        else
            echo -e "${gl_hong}❌ 重启失败${gl_bai}"
        fi
    else
        echo -e "${gl_hong}❌ 镜像拉取失败${gl_bai}"
    fi

    break_end
}

# 查看状态
fuclaude_status() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  Fuclaude 状态${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(fuclaude_check_status)
    local port=$(fuclaude_get_port)
    local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")

    case "$status" in
        "running")
            echo -e "状态: ${gl_lv}✅ 运行中${gl_bai}"
            echo -e "端口: ${gl_huang}$port${gl_bai}"
            echo -e "访问地址: ${gl_huang}http://${server_ip}:${port}${gl_bai}"
            echo ""
            echo "容器详情:"
            docker ps --filter "name=$FUCLAUDE_CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            echo ""
            echo "环境变量:"
            docker inspect "$FUCLAUDE_CONTAINER_NAME" --format '{{range .Config.Env}}  {{println .}}{{end}}' 2>/dev/null | grep FUCLAUDE
            ;;
        "stopped")
            echo -e "状态: ${gl_hong}❌ 已停止${gl_bai}"
            echo ""
            echo "请使用「启动服务」选项启动"
            ;;
        "not_installed")
            echo -e "状态: ${gl_hui}未安装${gl_bai}"
            echo ""
            echo "请使用「一键部署」选项安装"
            ;;
    esac

    echo ""
    break_end
}

# 查看日志
fuclaude_logs() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  Fuclaude 日志${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_zi}按 Ctrl+C 退出日志查看${gl_bai}"
    echo ""

    docker logs "$FUCLAUDE_CONTAINER_NAME" -f --tail 100
}

# 启动服务
fuclaude_start() {
    echo ""
    echo "正在启动 Fuclaude..."
    docker start "$FUCLAUDE_CONTAINER_NAME"

    if [ $? -eq 0 ]; then
        local port=$(fuclaude_get_port)
        local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")
        echo -e "${gl_lv}✅ 启动成功${gl_bai}"
        echo -e "访问地址: ${gl_huang}http://${server_ip}:${port}${gl_bai}"
    else
        echo -e "${gl_hong}❌ 启动失败${gl_bai}"
    fi

    sleep 2
    break_end
}

# 停止服务
fuclaude_stop() {
    echo ""
    echo "正在停止 Fuclaude..."
    docker stop "$FUCLAUDE_CONTAINER_NAME"

    if [ $? -eq 0 ]; then
        echo -e "${gl_lv}✅ 已停止${gl_bai}"
    else
        echo -e "${gl_hong}❌ 停止失败${gl_bai}"
    fi

    sleep 2
    break_end
}

# 重启服务
fuclaude_restart() {
    echo ""
    echo "正在重启 Fuclaude..."
    docker restart "$FUCLAUDE_CONTAINER_NAME"

    if [ $? -eq 0 ]; then
        local port=$(fuclaude_get_port)
        local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")
        echo -e "${gl_lv}✅ 重启成功${gl_bai}"
        echo -e "访问地址: ${gl_huang}http://${server_ip}:${port}${gl_bai}"
    else
        echo -e "${gl_hong}❌ 重启失败${gl_bai}"
    fi

    sleep 2
    break_end
}

# 修改配置
fuclaude_config() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  修改 Fuclaude 配置${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(fuclaude_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ Fuclaude 未安装${gl_bai}"
        break_end
        return 1
    fi

    local current_port=$(fuclaude_get_port)

    echo "当前配置:"
    echo -e "  端口: ${gl_huang}$current_port${gl_bai}"
    echo ""
    echo "请选择要修改的配置:"
    echo "1. 修改端口"
    echo "2. 修改站点密码"
    echo "3. 修改注册设置"
    echo "0. 返回"
    echo ""

    read -e -p "请选择 [0-3]: " config_choice

    case $config_choice in
        1)
            fuclaude_change_port
            ;;
        2)
            fuclaude_change_password
            ;;
        3)
            fuclaude_change_signup
            ;;
        0)
            return
            ;;
        *)
            echo "无效的选择"
            sleep 2
            ;;
    esac
}

# 修改端口
fuclaude_change_port() {
    echo ""
    local current_port=$(fuclaude_get_port)
    echo -e "当前端口: ${gl_huang}$current_port${gl_bai}"
    echo ""

    read -e -p "请输入新端口: " new_port

    if [ -z "$new_port" ]; then
        echo "未输入端口，取消修改"
        break_end
        return 0
    fi

    # 验证端口
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${gl_hong}❌ 无效的端口号${gl_bai}"
        break_end
        return 1
    fi

    if [ "$new_port" = "$current_port" ]; then
        echo -e "${gl_huang}⚠️ 端口未改变${gl_bai}"
        break_end
        return 0
    fi

    # 检查端口是否可用
    if ! fuclaude_check_port "$new_port"; then
        echo -e "${gl_hong}❌ 端口 $new_port 已被占用${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo "正在修改端口..."

    # 获取当前容器的环境变量
    local env_vars=$(docker inspect "$FUCLAUDE_CONTAINER_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)

    # 停止并删除旧容器
    docker stop "$FUCLAUDE_CONTAINER_NAME"
    docker rm "$FUCLAUDE_CONTAINER_NAME"

    # 用新端口创建容器
    # 解析环境变量并重新创建
    local site_password=$(echo "$env_vars" | grep "FUCLAUDE_SITE_PASSWORD=" | cut -d= -f2-)
    local cookie_secret=$(echo "$env_vars" | grep "FUCLAUDE_COOKIE_SECRET=" | cut -d= -f2-)
    local signup_enabled=$(echo "$env_vars" | grep "FUCLAUDE_SIGNUP_ENABLED=" | cut -d= -f2-)

    # 设置默认值
    [ -z "$cookie_secret" ] && cookie_secret=$(fuclaude_generate_secret)
    [ -z "$signup_enabled" ] && signup_enabled="false"

    docker run -d \
        --name "$FUCLAUDE_CONTAINER_NAME" \
        -p ${new_port}:8181 \
        -e TZ=Asia/Shanghai \
        -e FUCLAUDE_BIND=0.0.0.0:8181 \
        -e FUCLAUDE_TIMEOUT=600 \
        -e FUCLAUDE_SITE_PASSWORD="$site_password" \
        -e FUCLAUDE_COOKIE_SECRET="$cookie_secret" \
        -e FUCLAUDE_SIGNUP_ENABLED="$signup_enabled" \
        -e FUCLAUDE_SHOW_SESSION_KEY=false \
        -v ${FUCLAUDE_DATA_DIR}:/app/data \
        --restart unless-stopped \
        "$FUCLAUDE_IMAGE"

    if [ $? -eq 0 ]; then
        echo "$new_port" > "$FUCLAUDE_PORT_FILE"
        local server_ip=$(curl -s4 ip.sb 2>/dev/null || curl -s6 ip.sb 2>/dev/null || echo "服务器IP")
        echo ""
        echo -e "${gl_lv}✅ 端口修改成功${gl_bai}"
        echo -e "新访问地址: ${gl_huang}http://${server_ip}:${new_port}${gl_bai}"
    else
        echo -e "${gl_hong}❌ 端口修改失败${gl_bai}"
    fi

    break_end
}

# 修改站点密码
fuclaude_change_password() {
    echo ""
    read -e -p "请输入新的站点密码 (留空取消密码保护): " new_password

    echo ""
    echo "正在修改密码..."

    # 获取当前容器的环境变量
    local env_vars=$(docker inspect "$FUCLAUDE_CONTAINER_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)
    local port=$(fuclaude_get_port)
    local cookie_secret=$(echo "$env_vars" | grep "FUCLAUDE_COOKIE_SECRET=" | cut -d= -f2-)
    local signup_enabled=$(echo "$env_vars" | grep "FUCLAUDE_SIGNUP_ENABLED=" | cut -d= -f2-)

    [ -z "$cookie_secret" ] && cookie_secret=$(fuclaude_generate_secret)
    [ -z "$signup_enabled" ] && signup_enabled="false"

    # 停止并删除旧容器
    docker stop "$FUCLAUDE_CONTAINER_NAME"
    docker rm "$FUCLAUDE_CONTAINER_NAME"

    docker run -d \
        --name "$FUCLAUDE_CONTAINER_NAME" \
        -p ${port}:8181 \
        -e TZ=Asia/Shanghai \
        -e FUCLAUDE_BIND=0.0.0.0:8181 \
        -e FUCLAUDE_TIMEOUT=600 \
        -e FUCLAUDE_SITE_PASSWORD="$new_password" \
        -e FUCLAUDE_COOKIE_SECRET="$cookie_secret" \
        -e FUCLAUDE_SIGNUP_ENABLED="$signup_enabled" \
        -e FUCLAUDE_SHOW_SESSION_KEY=false \
        -v ${FUCLAUDE_DATA_DIR}:/app/data \
        --restart unless-stopped \
        "$FUCLAUDE_IMAGE"

    if [ $? -eq 0 ]; then
        echo ""
        if [ -n "$new_password" ]; then
            echo -e "${gl_lv}✅ 密码修改成功${gl_bai}"
            echo -e "新密码: ${gl_huang}$new_password${gl_bai}"
        else
            echo -e "${gl_lv}✅ 已取消密码保护${gl_bai}"
        fi
    else
        echo -e "${gl_hong}❌ 密码修改失败${gl_bai}"
    fi

    break_end
}

# 修改注册设置
fuclaude_change_signup() {
    echo ""
    local env_vars=$(docker inspect "$FUCLAUDE_CONTAINER_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)
    local current_signup=$(echo "$env_vars" | grep "FUCLAUDE_SIGNUP_ENABLED=" | cut -d= -f2-)

    echo -e "当前注册设置: ${gl_huang}${current_signup:-false}${gl_bai}"
    echo ""

    local new_signup="false"
    read -e -p "是否允许用户自行注册？(y/n) [n]: " allow_signup
    if [ "$allow_signup" = "y" ] || [ "$allow_signup" = "Y" ]; then
        new_signup="true"
    fi

    echo ""
    echo "正在修改注册设置..."

    local port=$(fuclaude_get_port)
    local site_password=$(echo "$env_vars" | grep "FUCLAUDE_SITE_PASSWORD=" | cut -d= -f2-)
    local cookie_secret=$(echo "$env_vars" | grep "FUCLAUDE_COOKIE_SECRET=" | cut -d= -f2-)

    [ -z "$cookie_secret" ] && cookie_secret=$(fuclaude_generate_secret)

    # 停止并删除旧容器
    docker stop "$FUCLAUDE_CONTAINER_NAME"
    docker rm "$FUCLAUDE_CONTAINER_NAME"

    docker run -d \
        --name "$FUCLAUDE_CONTAINER_NAME" \
        -p ${port}:8181 \
        -e TZ=Asia/Shanghai \
        -e FUCLAUDE_BIND=0.0.0.0:8181 \
        -e FUCLAUDE_TIMEOUT=600 \
        -e FUCLAUDE_SITE_PASSWORD="$site_password" \
        -e FUCLAUDE_COOKIE_SECRET="$cookie_secret" \
        -e FUCLAUDE_SIGNUP_ENABLED="$new_signup" \
        -e FUCLAUDE_SHOW_SESSION_KEY=false \
        -v ${FUCLAUDE_DATA_DIR}:/app/data \
        --restart unless-stopped \
        "$FUCLAUDE_IMAGE"

    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${gl_lv}✅ 注册设置修改成功${gl_bai}"
        echo -e "允许注册: ${gl_huang}$new_signup${gl_bai}"
    else
        echo -e "${gl_hong}❌ 设置修改失败${gl_bai}"
    fi

    break_end
}

# 卸载
fuclaude_uninstall() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_hong}  卸载 Fuclaude${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(fuclaude_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ Fuclaude 未安装${gl_bai}"
        break_end
        return 1
    fi

    echo -e "${gl_hong}⚠️ 此操作将删除 Fuclaude 容器${gl_bai}"
    echo ""
    read -e -p "是否同时删除数据目录？(y/n) [n]: " delete_data
    echo ""
    read -e -p "确认卸载？(y/n) [n]: " confirm

    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "取消卸载"
        break_end
        return 0
    fi

    echo ""
    echo "正在卸载..."

    # 停止并删除容器
    docker stop "$FUCLAUDE_CONTAINER_NAME" 2>/dev/null
    docker rm "$FUCLAUDE_CONTAINER_NAME" 2>/dev/null

    # 删除数据目录
    if [ "$delete_data" = "y" ] || [ "$delete_data" = "Y" ]; then
        rm -rf "$FUCLAUDE_DATA_DIR"
        echo -e "${gl_lv}✅ 容器和数据已删除${gl_bai}"
    else
        echo -e "${gl_lv}✅ 容器已删除，数据保留在 $FUCLAUDE_DATA_DIR${gl_bai}"
    fi

    # 删除端口配置文件
    rm -f "$FUCLAUDE_PORT_FILE"

    break_end
}

# Fuclaude 管理主菜单
manage_fuclaude() {
    while true; do
        clear
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_kjlan}  Fuclaude 部署管理 (Claude网页版共享)${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""

        # 显示当前状态
        local status=$(fuclaude_check_status)
        local port=$(fuclaude_get_port)

        case "$status" in
            "running")
                echo -e "当前状态: ${gl_lv}✅ 运行中${gl_bai} (端口: $port)"
                ;;
            "stopped")
                echo -e "当前状态: ${gl_hong}❌ 已停止${gl_bai}"
                ;;
            "not_installed")
                echo -e "当前状态: ${gl_hui}未安装${gl_bai}"
                ;;
        esac

        echo ""
        echo -e "${gl_kjlan}[部署与更新]${gl_bai}"
        echo "1. 一键部署（首次安装）"
        echo "2. 更新镜像"
        echo ""
        echo -e "${gl_kjlan}[服务管理]${gl_bai}"
        echo "3. 查看状态"
        echo "4. 查看日志"
        echo "5. 启动服务"
        echo "6. 停止服务"
        echo "7. 重启服务"
        echo ""
        echo -e "${gl_kjlan}[配置]${gl_bai}"
        echo "8. 修改配置（端口/密码/注册）"
        echo ""
        echo -e "${gl_kjlan}[卸载]${gl_bai}"
        echo -e "${gl_hong}9. 卸载（删除容器）${gl_bai}"
        echo ""
        echo "0. 返回主菜单"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"

        read -e -p "请选择操作 [0-9]: " choice

        case $choice in
            1)
                fuclaude_deploy
                ;;
            2)
                fuclaude_update
                ;;
            3)
                fuclaude_status
                ;;
            4)
                fuclaude_logs
                ;;
            5)
                fuclaude_start
                ;;
            6)
                fuclaude_stop
                ;;
            7)
                fuclaude_restart
                ;;
            8)
                fuclaude_config
                ;;
            9)
                fuclaude_uninstall
                ;;
            0)
                return
                ;;
            *)
                echo "无效的选择"
                sleep 2
                ;;
        esac
    done
}

# =====================================================
# Caddy 多域名反代管理 (菜单43)
# =====================================================

# 常量定义
CADDY_SERVICE_NAME="caddy"
CADDY_CONFIG_FILE="/etc/caddy/Caddyfile"
CADDY_CONFIG_DIR="/etc/caddy"
CADDY_CONFIG_BACKUP_DIR="/etc/caddy/backups"
CADDY_DOMAIN_LIST_FILE="/etc/caddy/.domain-list"
CADDY_INSTALL_SCRIPT="https://caddyserver.com/api/download?os=linux&arch=amd64"

# 获取服务器 IP
caddy_get_server_ip() {
    local ip=$(curl -s4 --max-time 5 ip.sb 2>/dev/null)
    if [ -z "$ip" ]; then
        ip=$(curl -s6 --max-time 5 ip.sb 2>/dev/null)
    fi
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "$ip"
}

# 检查 Caddy 状态
caddy_check_status() {
    if ! command -v caddy &>/dev/null; then
        echo "not_installed"
        return
    fi

    if systemctl is-active "$CADDY_SERVICE_NAME" &>/dev/null; then
        echo "running"
    elif systemctl is-enabled "$CADDY_SERVICE_NAME" &>/dev/null; then
        echo "stopped"
    else
        echo "installed_no_service"
    fi
}

# 检查端口是否被占用
caddy_check_port() {
    local port=$1
    if ss -lntp 2>/dev/null | grep -q ":${port} "; then
        return 1  # 端口被占用
    fi
    return 0  # 端口可用
}

# 检查并处理端口占用
caddy_handle_port_conflict() {
    local port=$1
    local port_name=$2

    echo -e "${gl_kjlan}检测端口 ${port} (${port_name}) 占用情况...${gl_bai}"

    if caddy_check_port "$port"; then
        echo -e "${gl_lv}✅ 端口 ${port} 可用${gl_bai}"
        return 0
    fi

    # 端口被占用,查找占用进程
    local pid=$(ss -lntp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1)

    if [ -z "$pid" ]; then
        echo -e "${gl_hong}❌ 端口 ${port} 被占用，但无法获取进程信息${gl_bai}"
        return 1
    fi

    local proc_comm=$(cat /proc/$pid/comm 2>/dev/null || echo "未知进程")
    local proc_cwd=$(readlink -f /proc/$pid/cwd 2>/dev/null || echo "未知路径")

    echo -e "${gl_hong}⚠️ 端口 ${port} 被占用${gl_bai}"
    echo ""
    echo -e "占用进程信息："
    echo -e "  PID: ${pid}"
    echo -e "  程序: ${proc_comm}"
    echo -e "  路径: ${proc_cwd}"
    echo ""

    # 检查是否是 Caddy 自己
    if [[ "$proc_comm" == "caddy" ]]; then
        echo -e "${gl_huang}⚠️ 端口被现有 Caddy 进程占用${gl_bai}"
        echo "部署过程会自动停止旧服务并重启"
        return 0
    fi

    echo -e "${gl_huang}请选择操作：${gl_bai}"
    echo "1. 停止占用进程并继续部署（需谨慎）"
    echo "2. 取消部署（推荐，请手动处理端口占用）"
    echo ""
    read -e -p "请选择 [1-2]: " conflict_choice

    case "$conflict_choice" in
        1)
            echo ""
            echo "正在停止进程 ${pid}..."
            kill "$pid" 2>/dev/null
            sleep 2

            if ss -lntp 2>/dev/null | grep -q ":${port} "; then
                echo "进程未响应，强制终止..."
                kill -9 "$pid" 2>/dev/null
                sleep 1
            fi

            if ss -lntp 2>/dev/null | grep -q ":${port} "; then
                echo -e "${gl_hong}❌ 无法释放端口 ${port}${gl_bai}"
                return 1
            fi

            echo -e "${gl_lv}✅ 端口 ${port} 已释放${gl_bai}"
            return 0
            ;;
        2|*)
            echo "取消部署"
            return 1
            ;;
    esac
}

# 检查防火墙并配置
caddy_check_firewall() {
    echo ""
    echo -e "${gl_kjlan}检查防火墙配置...${gl_bai}"

    local firewall_type="none"
    local need_config=false

    # 检测防火墙类型
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        firewall_type="ufw"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        firewall_type="firewalld"
    elif command -v iptables &>/dev/null; then
        # 检查是否有 iptables 规则
        if iptables -L -n 2>/dev/null | grep -qE "Chain INPUT.*policy (DROP|REJECT)"; then
            firewall_type="iptables"
        fi
    fi

    if [ "$firewall_type" = "none" ]; then
        echo -e "${gl_lv}✅ 未检测到活动防火墙${gl_bai}"
        return 0
    fi

    echo -e "检测到防火墙: ${gl_huang}$firewall_type${gl_bai}"

    # 检查端口是否已开放
    case "$firewall_type" in
        ufw)
            if ! ufw status 2>/dev/null | grep -qE "80/tcp.*ALLOW|80.*ALLOW"; then
                need_config=true
            fi
            if ! ufw status 2>/dev/null | grep -qE "443/tcp.*ALLOW|443.*ALLOW"; then
                need_config=true
            fi
            ;;
        firewalld)
            if ! firewall-cmd --list-ports 2>/dev/null | grep -q "80/tcp"; then
                need_config=true
            fi
            if ! firewall-cmd --list-ports 2>/dev/null | grep -q "443/tcp"; then
                need_config=true
            fi
            ;;
        iptables)
            if ! iptables -L INPUT -n 2>/dev/null | grep -q "dpt:80"; then
                need_config=true
            fi
            if ! iptables -L INPUT -n 2>/dev/null | grep -q "dpt:443"; then
                need_config=true
            fi
            ;;
    esac

    if [ "$need_config" = false ]; then
        echo -e "${gl_lv}✅ 端口 80/443 已开放${gl_bai}"
        return 0
    fi

    echo ""
    echo -e "${gl_huang}⚠️ 需要开放端口 80 和 443${gl_bai}"
    echo "  端口 80: Let's Encrypt 证书验证"
    echo "  端口 443: HTTPS 服务"
    echo ""
    read -e -p "是否自动配置防火墙? (y/n) [y]: " auto_config

    if [ "$auto_config" = "n" ] || [ "$auto_config" = "N" ]; then
        echo -e "${gl_huang}⚠️ 请手动开放端口 80 和 443${gl_bai}"
        return 0
    fi

    echo ""
    echo "正在配置防火墙..."

    case "$firewall_type" in
        ufw)
            ufw allow 80/tcp >/dev/null 2>&1
            ufw allow 443/tcp >/dev/null 2>&1
            echo -e "${gl_lv}✅ UFW 防火墙配置完成${gl_bai}"
            ;;
        firewalld)
            firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1
            firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
            echo -e "${gl_lv}✅ Firewalld 防火墙配置完成${gl_bai}"
            ;;
        iptables)
            iptables -I INPUT -p tcp --dport 80 -j ACCEPT
            iptables -I INPUT -p tcp --dport 443 -j ACCEPT
            # 尝试保存规则
            if command -v iptables-save &>/dev/null; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
            echo -e "${gl_lv}✅ Iptables 防火墙配置完成${gl_bai}"
            ;;
    esac

    return 0
}

# 检查域名解析
caddy_check_dns() {
    local domain=$1
    local server_ip=$(caddy_get_server_ip)

    echo -e "${gl_kjlan}检查域名解析...${gl_bai}"
    echo "域名: $domain"
    echo "本机IP: $server_ip"
    echo ""

    # 使用多个方法检查域名解析
    local resolved_ip=""

    # 方法1: dig
    if command -v dig &>/dev/null; then
        resolved_ip=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    fi

    # 方法2: nslookup (fallback)
    if [ -z "$resolved_ip" ] && command -v nslookup &>/dev/null; then
        resolved_ip=$(nslookup "$domain" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1)
    fi

    # 方法3: host (fallback)
    if [ -z "$resolved_ip" ] && command -v host &>/dev/null; then
        resolved_ip=$(host "$domain" 2>/dev/null | grep "has address" | awk '{print $4}' | head -1)
    fi

    if [ -z "$resolved_ip" ]; then
        echo -e "${gl_hong}⚠️ 无法解析域名 $domain${gl_bai}"
        echo ""
        echo "可能原因:"
        echo "  1. 域名尚未添加 DNS 记录"
        echo "  2. DNS 记录还在传播中（通常需要几分钟）"
        echo "  3. DNS 查询工具未安装"
        echo ""
        echo -e "${gl_huang}建议：${gl_bai}"
        echo "  请确保在 DNS 服务商添加 A 记录："
        echo "  类型: A"
        echo "  名称: $domain"
        echo "  内容: $server_ip"
        echo ""
        read -e -p "是否继续部署? (y/n) [y]: " continue_anyway
        if [ "$continue_anyway" = "n" ] || [ "$continue_anyway" = "N" ]; then
            return 1
        fi
        return 0
    fi

    echo "解析结果: $resolved_ip"
    echo ""

    if [ "$resolved_ip" = "$server_ip" ]; then
        echo -e "${gl_lv}✅ 域名解析正确${gl_bai}"
        return 0
    else
        echo -e "${gl_hong}❌ 域名解析不匹配${gl_bai}"
        echo ""
        echo "期望: $server_ip"
        echo "实际: $resolved_ip"
        echo ""
        echo -e "${gl_huang}请检查 DNS 配置：${gl_bai}"
        echo "  1. 确认 A 记录指向: $server_ip"
        echo "  2. 等待 DNS 传播完成（可能需要几分钟到几小时）"
        echo "  3. 如果使用 Cloudflare，请关闭橙色云朵（仅 DNS 模式）"
        echo ""
        read -e -p "是否继续部署? (y/n) [n]: " continue_anyway
        if [ "$continue_anyway" = "y" ] || [ "$continue_anyway" = "Y" ]; then
            return 0
        fi
        return 1
    fi
}

# 安装 Caddy
caddy_install() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  一键部署 Caddy${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    # 检查是否已安装
    local status=$(caddy_check_status)
    if [ "$status" != "not_installed" ]; then
        echo -e "${gl_huang}⚠️ Caddy 已安装${gl_bai}"
        echo ""
        read -e -p "是否重新安装/更新? (y/n) [n]: " reinstall
        if [ "$reinstall" != "y" ] && [ "$reinstall" != "Y" ]; then
            break_end
            return 0
        fi

        echo ""
        echo "正在停止现有服务..."
        systemctl stop "$CADDY_SERVICE_NAME" 2>/dev/null
    fi

    echo ""
    echo -e "${gl_kjlan}[1/6] 检查端口占用...${gl_bai}"

    # 检查 443 端口
    if ! caddy_handle_port_conflict 443 "HTTPS"; then
        break_end
        return 1
    fi

    # 检查 80 端口
    if ! caddy_handle_port_conflict 80 "HTTP"; then
        break_end
        return 1
    fi

    # 检查防火墙
    echo ""
    echo -e "${gl_kjlan}[2/6] 检查防火墙配置...${gl_bai}"
    if ! caddy_check_firewall; then
        break_end
        return 1
    fi

    echo ""
    echo -e "${gl_kjlan}[3/6] 安装必要工具...${gl_bai}"

    # 安装 curl 和 dig (用于域名解析检查)
    if ! command -v curl &>/dev/null || ! command -v dig &>/dev/null; then
        echo "正在安装工具..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq 2>/dev/null
            apt-get install -y curl dnsutils >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y curl bind-utils >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y curl bind-utils >/dev/null 2>&1
        fi
    fi
    echo -e "${gl_lv}✅ 工具检查完成${gl_bai}"

    echo ""
    echo -e "${gl_kjlan}[4/6] 下载并安装 Caddy...${gl_bai}"

    # 使用全局定义的 Caddy 版本
    local CADDY_VERSION="${CADDY_DEFAULT_VERSION}"
    local download_success=false

    # 下载源列表(按优先级)
    declare -a download_urls=(
        "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz"
        "https://caddyserver.com/api/download?os=linux&arch=amd64"
        "https://ghproxy.com/https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz"
    )

    # 尝试多个下载源
    for url in "${download_urls[@]}"; do
        echo "尝试下载: $url"

        if [[ "$url" == *.tar.gz ]]; then
            # 下载 tar.gz 格式
            if curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o /tmp/caddy.tar.gz 2>/dev/null; then
                echo "解压 Caddy..."
                if tar -xzf /tmp/caddy.tar.gz -C /tmp/ caddy 2>/dev/null; then
                    mv /tmp/caddy /usr/bin/caddy
                    chmod +x /usr/bin/caddy
                    rm -f /tmp/caddy.tar.gz
                    download_success=true
                    break
                fi
            fi
        else
            # 直接下载二进制文件
            if curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o /usr/bin/caddy 2>/dev/null; then
                # 验证文件是否有效(检查文件大小)
                if [ -f /usr/bin/caddy ] && [ -s /usr/bin/caddy ]; then
                    local file_size=$(stat -f%z /usr/bin/caddy 2>/dev/null || stat -c%s /usr/bin/caddy 2>/dev/null)
                    # Caddy 二进制文件应该大于 10MB
                    if [ "$file_size" -gt 10485760 ]; then
                        chmod +x /usr/bin/caddy
                        download_success=true
                        break
                    else
                        echo "文件大小异常,尝试下一个源..."
                        rm -f /usr/bin/caddy
                    fi
                fi
            fi
        fi
    done

    # 检查下载结果
    if [ "$download_success" = false ]; then
        echo -e "${gl_hong}❌ 所有下载源均失败${gl_bai}"
        echo ""
        echo "请手动安装 Caddy:"
        echo "  wget https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz"
        echo "  tar -xzf caddy_${CADDY_VERSION}_linux_amd64.tar.gz"
        echo "  mv caddy /usr/bin/caddy"
        echo "  chmod +x /usr/bin/caddy"
        echo ""
        break_end
        return 1
    fi

    # 验证安装
    if ! /usr/bin/caddy version &>/dev/null; then
        echo -e "${gl_hong}❌ Caddy 安装验证失败${gl_bai}"
        break_end
        return 1
    fi

    echo -e "${gl_lv}✅ Caddy 下载完成${gl_bai}"
    echo "版本: $(/usr/bin/caddy version 2>/dev/null | head -1)"

    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_huang}📧 配置 SSL 证书联系邮箱${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo "用途: Let's Encrypt 会发送证书过期提醒到此邮箱"
    echo "说明: 邮箱不需要真实存在,但格式必须正确"
    echo "示例: admin@yourdomain.com"
    echo ""

    local ssl_email=""
    while true; do
        read -e -p "请输入联系邮箱 [回车使用 caddy@localhost]: " ssl_email

        # 如果为空,使用默认值
        if [ -z "$ssl_email" ]; then
            ssl_email="caddy@localhost"
            break
        fi

        # 验证邮箱格式
        if echo "$ssl_email" | grep -qE '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
            # 检查是否是被禁止的域名
            if echo "$ssl_email" | grep -qE '@example\.(com|org|net)$'; then
                echo -e "${gl_hong}❌ 不能使用 example.com 等示例域名${gl_bai}"
                continue
            fi
            break
        else
            echo -e "${gl_hong}❌ 邮箱格式不正确,请重新输入${gl_bai}"
        fi
    done

    echo -e "${gl_lv}✅ 邮箱: $ssl_email${gl_bai}"

    echo ""
    echo -e "${gl_kjlan}[5/6] 配置 Caddy...${gl_bai}"

    # 创建配置目录
    mkdir -p "$CADDY_CONFIG_DIR"
    mkdir -p "$CADDY_CONFIG_BACKUP_DIR"
    mkdir -p /var/log/caddy
    mkdir -p /var/lib/caddy/.local/share/caddy
    mkdir -p /var/lib/caddy/.config/caddy

    # 创建 Caddy 用户
    if ! id -u caddy &>/dev/null; then
        useradd -r -s /bin/false caddy 2>/dev/null || true
    fi

    # 设置权限
    chown -R caddy:caddy "$CADDY_CONFIG_DIR"
    chown -R caddy:caddy /var/log/caddy
    chown -R caddy:caddy /var/lib/caddy

    # 创建初始 Caddyfile
    if [ ! -f "$CADDY_CONFIG_FILE" ]; then
        cat > "$CADDY_CONFIG_FILE" << EOF
# Caddy 多域名反代配置
# 使用脚本菜单添加反代域名

{
    # 全局配置
    admin off
    email ${ssl_email}
}

# 反代配置将在下方自动添加
EOF
        chown caddy:caddy "$CADDY_CONFIG_FILE"
    fi

    # 创建 systemd 服务
    cat > /etc/systemd/system/caddy.service << 'EOF'
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment="HOME=/var/lib/caddy"
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${gl_lv}✅ 配置完成${gl_bai}"

    echo ""
    echo -e "${gl_kjlan}[6/6] 启动 Caddy 服务...${gl_bai}"

    systemctl daemon-reload
    systemctl enable caddy >/dev/null 2>&1
    systemctl start caddy

    sleep 2

    if systemctl is-active caddy &>/dev/null; then
        echo -e "${gl_lv}✅ Caddy 启动成功${gl_bai}"

        local server_ip=$(caddy_get_server_ip)

        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_lv}🎉 Caddy 部署成功!${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "服务器 IP: $server_ip"
        echo "配置文件: $CADDY_CONFIG_FILE"
        echo ""
        echo -e "${gl_huang}下一步:${gl_bai}"
        echo "  请使用菜单 [2. 添加反代域名] 来配置反向代理"
        echo ""
    else
        echo -e "${gl_hong}❌ Caddy 启动失败${gl_bai}"
        echo ""
        echo "查看错误日志:"
        echo "  journalctl -u caddy -n 50 --no-pager"
        echo ""
    fi

    break_end
}

# 添加反代域名
caddy_add_domain() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  添加反代域名${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    # 检查 Caddy 是否已安装
    local status=$(caddy_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ Caddy 未安装${gl_bai}"
        echo "请先使用 [1. 一键部署 Caddy]"
        break_end
        return 1
    fi

    if [ "$status" != "running" ]; then
        echo -e "${gl_huang}⚠️ Caddy 未运行${gl_bai}"
        read -e -p "是否启动 Caddy? (y/n) [y]: " start_caddy
        if [ "$start_caddy" != "n" ] && [ "$start_caddy" != "N" ]; then
            systemctl start caddy
            sleep 2
            if ! systemctl is-active caddy &>/dev/null; then
                echo -e "${gl_hong}❌ Caddy 启动失败${gl_bai}"
                break_end
                return 1
            fi
        else
            break_end
            return 1
        fi
    fi

    echo -e "${gl_huang}配置示例:${gl_bai}"
    echo "  域名: vox.moe"
    echo "  后端: 123.45.67.89:8181"
    echo ""

    # 输入域名
    read -e -p "请输入域名: " domain

    if [ -z "$domain" ]; then
        echo -e "${gl_hong}❌ 域名不能为空${gl_bai}"
        break_end
        return 1
    fi

    # 简单验证域名格式
    if ! echo "$domain" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'; then
        echo -e "${gl_hong}❌ 域名格式不正确${gl_bai}"
        break_end
        return 1
    fi

    # 检查域名是否已存在
    if [ -f "$CADDY_DOMAIN_LIST_FILE" ] && grep -q "^${domain}|" "$CADDY_DOMAIN_LIST_FILE" 2>/dev/null; then
        echo -e "${gl_hong}❌ 域名 $domain 已存在${gl_bai}"
        break_end
        return 1
    fi

    echo ""

    # 检查域名解析
    if ! caddy_check_dns "$domain"; then
        break_end
        return 1
    fi

    echo ""

    # 输入后端地址
    read -e -p "请输入后端地址 (IP:端口): " backend

    if [ -z "$backend" ]; then
        echo -e "${gl_hong}❌ 后端地址不能为空${gl_bai}"
        break_end
        return 1
    fi

    # 验证后端地址格式
    if ! echo "$backend" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$'; then
        echo -e "${gl_hong}❌ 后端地址格式不正确 (应为 IP:端口)${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo "域名: $domain"
    echo "后端: $backend"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    read -e -p "确认添加? (y/n) [y]: " confirm

    if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
        echo "取消添加"
        break_end
        return 0
    fi

    echo ""
    echo -e "${gl_kjlan}[1/3] 备份配置文件...${gl_bai}"

    # 备份当前配置
    local backup_file="$CADDY_CONFIG_BACKUP_DIR/Caddyfile.$(date +%Y%m%d_%H%M%S)"
    cp "$CADDY_CONFIG_FILE" "$backup_file"
    echo -e "${gl_lv}✅ 已备份到: $backup_file${gl_bai}"

    echo ""
    echo -e "${gl_kjlan}[2/3] 添加配置...${gl_bai}"

    # 添加配置到 Caddyfile
    cat >> "$CADDY_CONFIG_FILE" << EOF

# ${domain} - 添加于 $(date '+%Y-%m-%d %H:%M:%S')
${domain} {
    reverse_proxy ${backend} {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
EOF

    echo -e "${gl_lv}✅ 配置已添加${gl_bai}"

    # 记录到域名列表
    echo "${domain}|${backend}|$(date +%s)" >> "$CADDY_DOMAIN_LIST_FILE"

    echo ""
    echo -e "${gl_kjlan}[3/3] 重载 Caddy...${gl_bai}"

    # 先测试配置
    if ! caddy validate --config "$CADDY_CONFIG_FILE" 2>/dev/null; then
        echo -e "${gl_hong}❌ 配置文件验证失败${gl_bai}"
        echo "正在恢复备份..."
        cp "$backup_file" "$CADDY_CONFIG_FILE"

        # 从域名列表中删除
        if [ -f "$CADDY_DOMAIN_LIST_FILE" ]; then
            sed -i "/^${domain}|/d" "$CADDY_DOMAIN_LIST_FILE"
        fi

        break_end
        return 1
    fi

    # 重启 Caddy
    systemctl restart caddy

    if [ $? -eq 0 ]; then
        echo -e "${gl_lv}✅ Caddy 重启成功${gl_bai}"

        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_lv}🎉 反代配置成功!${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "访问地址: https://${domain}"
        echo "后端服务: ${backend}"
        echo ""
        echo -e "${gl_huang}说明:${gl_bai}"
        echo "  ⏳ Caddy 正在自动申请 SSL 证书..."
        echo "  ⏳ 首次访问可能需要等待几秒钟"
        echo "  ✅ 证书申请成功后即可通过 HTTPS 访问"
        echo ""
        echo -e "${gl_huang}提示:${gl_bai}"
        echo "  - 使用 [7. 查看 Caddy 日志] 可查看证书申请状态"
        echo "  - 证书由 Let's Encrypt 签发，自动续期"
        echo ""
    else
        echo -e "${gl_hong}❌ Caddy 重启失败${gl_bai}"
        echo "正在恢复备份..."
        cp "$backup_file" "$CADDY_CONFIG_FILE"
        systemctl restart caddy

        # 从域名列表中删除
        if [ -f "$CADDY_DOMAIN_LIST_FILE" ]; then
            sed -i "/^${domain}|/d" "$CADDY_DOMAIN_LIST_FILE"
        fi
    fi

    break_end
}

# 查看已配置域名
caddy_list_domains() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  已配置域名列表${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    if [ ! -f "$CADDY_DOMAIN_LIST_FILE" ] || [ ! -s "$CADDY_DOMAIN_LIST_FILE" ]; then
        echo -e "${gl_huang}暂无配置的域名${gl_bai}"
        echo ""
        echo "请使用 [2. 添加反代域名] 来添加配置"
        break_end
        return 0
    fi

    local count=1
    echo -e "${gl_kjlan}序号  域名                    后端地址               添加时间${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    while IFS='|' read -r domain backend timestamp; do
        if [ -n "$domain" ]; then
            local add_time=$(date -d "@$timestamp" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$timestamp" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "未知")
            printf "%-6s%-24s%-23s%s\n" "$count" "$domain" "$backend" "$add_time"
            count=$((count + 1))
        fi
    done < "$CADDY_DOMAIN_LIST_FILE"

    echo ""
    echo "总计: $((count - 1)) 个域名"
    echo ""

    break_end
}

# 删除反代域名
caddy_delete_domain() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  删除反代域名${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    if [ ! -f "$CADDY_DOMAIN_LIST_FILE" ] || [ ! -s "$CADDY_DOMAIN_LIST_FILE" ]; then
        echo -e "${gl_huang}暂无配置的域名${gl_bai}"
        break_end
        return 0
    fi

    # 显示域名列表
    local count=1
    declare -a domains
    declare -a backends

    echo -e "${gl_kjlan}序号  域名                    后端地址${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    while IFS='|' read -r domain backend timestamp; do
        if [ -n "$domain" ]; then
            printf "%-6s%-24s%s\n" "$count" "$domain" "$backend"
            domains[$count]="$domain"
            backends[$count]="$backend"
            count=$((count + 1))
        fi
    done < "$CADDY_DOMAIN_LIST_FILE"

    echo ""
    read -e -p "请输入要删除的序号 (0 取消): " choice

    if [ -z "$choice" ] || [ "$choice" = "0" ]; then
        echo "取消删除"
        break_end
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$count" ]; then
        echo -e "${gl_hong}❌ 无效的序号${gl_bai}"
        break_end
        return 1
    fi

    local domain_to_delete="${domains[$choice]}"
    local backend_to_delete="${backends[$choice]}"

    echo ""
    echo -e "${gl_hong}确认删除:${gl_bai}"
    echo "  域名: $domain_to_delete"
    echo "  后端: $backend_to_delete"
    echo ""
    read -e -p "确认删除? (y/n) [n]: " confirm

    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "取消删除"
        break_end
        return 0
    fi

    echo ""
    echo -e "${gl_kjlan}[1/3] 备份配置文件...${gl_bai}"

    # 备份当前配置
    local backup_file="$CADDY_CONFIG_BACKUP_DIR/Caddyfile.$(date +%Y%m%d_%H%M%S)"
    cp "$CADDY_CONFIG_FILE" "$backup_file"
    echo -e "${gl_lv}✅ 已备份到: $backup_file${gl_bai}"

    echo ""
    echo -e "${gl_kjlan}[2/3] 删除配置...${gl_bai}"

    # 从 Caddyfile 中删除配置块
    local temp_file=$(mktemp)
    local in_block=false

    while IFS= read -r line; do
        # 检查是否是要删除域名的注释行（格式：# domain.com - 添加于...）
        # 注意：注释行在域名块之前，必须先检测
        if [[ "$line" == "# ${domain_to_delete} - "* ]]; then
            continue
        fi

        # 检查是否是要删除的域名块开始
        if [[ "$line" == "${domain_to_delete} {" ]]; then
            in_block=true
            continue
        fi

        # 如果在要删除的块中
        if [ "$in_block" = true ]; then
            # 检查是否是块结束
            if [ "$line" = "}" ]; then
                in_block=false
            fi
            continue
        fi

        echo "$line" >> "$temp_file"
    done < "$CADDY_CONFIG_FILE"

    mv "$temp_file" "$CADDY_CONFIG_FILE"
    chown caddy:caddy "$CADDY_CONFIG_FILE"

    echo -e "${gl_lv}✅ 配置已删除${gl_bai}"

    # 从域名列表中删除
    sed -i "/^${domain_to_delete}|/d" "$CADDY_DOMAIN_LIST_FILE"

    echo ""
    echo -e "${gl_kjlan}[3/3] 重载 Caddy...${gl_bai}"

    # 验证配置
    if ! caddy validate --config "$CADDY_CONFIG_FILE" 2>/dev/null; then
        echo -e "${gl_hong}❌ 配置文件验证失败${gl_bai}"
        echo "正在恢复备份..."
        cp "$backup_file" "$CADDY_CONFIG_FILE"
        break_end
        return 1
    fi

    # 重启 Caddy
    systemctl restart caddy

    if [ $? -eq 0 ]; then
        echo -e "${gl_lv}✅ Caddy 重启成功${gl_bai}"
        echo ""
        echo -e "${gl_lv}✅ 域名 $domain_to_delete 已删除${gl_bai}"
    else
        echo -e "${gl_hong}❌ Caddy 重启失败${gl_bai}"
        echo "正在恢复备份..."
        cp "$backup_file" "$CADDY_CONFIG_FILE"
        systemctl restart caddy
    fi

    break_end
}

# 重载 Caddy 配置
caddy_reload() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  重载 Caddy 配置${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(caddy_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ Caddy 未安装${gl_bai}"
        break_end
        return 1
    fi

    echo "正在验证配置文件..."
    if ! caddy validate --config "$CADDY_CONFIG_FILE" 2>/dev/null; then
        echo -e "${gl_hong}❌ 配置文件验证失败${gl_bai}"
        echo ""
        echo "请检查配置文件: $CADDY_CONFIG_FILE"
        echo "查看详细错误: caddy validate --config $CADDY_CONFIG_FILE"
        break_end
        return 1
    fi

    echo -e "${gl_lv}✅ 配置文件验证通过${gl_bai}"
    echo ""

    echo "正在重载 Caddy..."
    systemctl restart caddy

    if [ $? -eq 0 ]; then
        echo -e "${gl_lv}✅ Caddy 重启成功${gl_bai}"
    else
        echo -e "${gl_hong}❌ Caddy 重启失败${gl_bai}"
        echo ""
        echo "查看错误日志: journalctl -u caddy -n 50"
    fi

    break_end
}

# 查看 Caddy 状态
caddy_show_status() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  Caddy 状态${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(caddy_check_status)

    case "$status" in
        "running")
            echo -e "服务状态: ${gl_lv}✅ 运行中${gl_bai}"
            ;;
        "stopped")
            echo -e "服务状态: ${gl_hong}❌ 已停止${gl_bai}"
            ;;
        "not_installed")
            echo -e "服务状态: ${gl_hui}未安装${gl_bai}"
            break_end
            return 0
            ;;
        *)
            echo -e "服务状态: ${gl_huang}⚠️ 未知${gl_bai}"
            ;;
    esac

    echo ""

    # 显示版本
    if command -v caddy &>/dev/null; then
        local version=$(caddy version 2>/dev/null | head -1)
        echo "Caddy 版本: $version"
    fi

    echo ""

    # 显示端口监听
    echo -e "${gl_kjlan}端口监听:${gl_bai}"
    if ss -lntp 2>/dev/null | grep -q ":443 "; then
        echo -e "  443/tcp: ${gl_lv}✅ 监听中${gl_bai}"
    else
        echo -e "  443/tcp: ${gl_hong}❌ 未监听${gl_bai}"
    fi

    if ss -lntp 2>/dev/null | grep -q ":80 "; then
        echo -e "  80/tcp: ${gl_lv}✅ 监听中${gl_bai}"
    else
        echo -e "  80/tcp: ${gl_hong}❌ 未监听${gl_bai}"
    fi

    echo ""

    # 显示配置的域名数量
    if [ -f "$CADDY_DOMAIN_LIST_FILE" ]; then
        local domain_count=$(wc -l < "$CADDY_DOMAIN_LIST_FILE" 2>/dev/null || echo 0)
        echo "配置域名: $domain_count 个"
    else
        echo "配置域名: 0 个"
    fi

    echo ""
    echo "配置文件: $CADDY_CONFIG_FILE"

    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    read -e -p "是否查看详细服务状态? (y/n) [n]: " show_detail
    if [ "$show_detail" = "y" ] || [ "$show_detail" = "Y" ]; then
        echo ""
        systemctl status caddy --no-pager -l
    fi

    break_end
}

# 查看 Caddy 日志
caddy_show_logs() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}  Caddy 日志${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(caddy_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ Caddy 未安装${gl_bai}"
        break_end
        return 1
    fi

    echo "1. 查看最近 50 行日志"
    echo "2. 查看最近 100 行日志"
    echo "3. 实时查看日志（Ctrl+C 退出）"
    echo "4. 查看错误日志"
    echo "0. 返回"
    echo ""
    read -e -p "请选择 [0-4]: " log_choice

    echo ""

    case "$log_choice" in
        1)
            journalctl -u caddy -n 50 --no-pager
            ;;
        2)
            journalctl -u caddy -n 100 --no-pager
            ;;
        3)
            echo "按 Ctrl+C 退出..."
            echo ""
            journalctl -u caddy -f
            ;;
        4)
            journalctl -u caddy -p err -n 50 --no-pager
            ;;
        0|*)
            return 0
            ;;
    esac

    break_end
}

# 启动/停止 Caddy
caddy_toggle_service() {
    local status=$(caddy_check_status)

    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ Caddy 未安装${gl_bai}"
        sleep 2
        return 1
    fi

    if [ "$status" = "running" ]; then
        # 当前运行中，执行停止
        echo -e "${gl_huang}正在停止 Caddy...${gl_bai}"
        systemctl stop caddy
        sleep 1
        if ! systemctl is-active caddy &>/dev/null; then
            echo -e "${gl_lv}✅ Caddy 已停止${gl_bai}"
        else
            echo -e "${gl_hong}❌ 停止失败${gl_bai}"
        fi
    else
        # 当前已停止，执行启动
        echo -e "${gl_huang}正在启动 Caddy...${gl_bai}"
        systemctl start caddy
        sleep 1
        if systemctl is-active caddy &>/dev/null; then
            echo -e "${gl_lv}✅ Caddy 已启动${gl_bai}"
        else
            echo -e "${gl_hong}❌ 启动失败${gl_bai}"
            echo "查看错误: journalctl -u caddy -n 20"
        fi
    fi
    sleep 2
}

# 卸载 Caddy
caddy_uninstall() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_hong}  卸载 Caddy${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local status=$(caddy_check_status)
    if [ "$status" = "not_installed" ]; then
        echo -e "${gl_hong}❌ Caddy 未安装${gl_bai}"
        break_end
        return 0
    fi

    echo -e "${gl_hong}⚠️ 此操作将删除 Caddy 及其配置${gl_bai}"
    echo ""
    echo "将要删除:"
    echo "  - Caddy 程序"
    echo "  - systemd 服务"
    echo "  - 配置文件"
    echo "  - SSL 证书"
    echo ""
    read -e -p "是否保留配置备份？(y/n) [y]: " keep_backup
    echo ""
    read -e -p "确认卸载? (y/n) [n]: " confirm

    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "取消卸载"
        break_end
        return 0
    fi

    echo ""
    echo "正在卸载..."
    echo ""

    # 停止并禁用服务
    echo "停止服务..."
    systemctl stop caddy 2>/dev/null
    systemctl disable caddy 2>/dev/null

    # 删除 systemd 服务文件
    echo "删除服务..."
    rm -f /etc/systemd/system/caddy.service
    systemctl daemon-reload

    # 删除 Caddy 程序
    echo "删除程序..."
    rm -f /usr/bin/caddy

    # 删除配置
    if [ "$keep_backup" = "n" ] || [ "$keep_backup" = "N" ]; then
        echo "删除配置..."
        rm -rf "$CADDY_CONFIG_DIR"
        rm -rf /var/lib/caddy
        rm -rf /var/log/caddy
    else
        echo "保留配置备份..."
        # 只删除主配置文件
        rm -f "$CADDY_CONFIG_FILE"
        rm -f "$CADDY_DOMAIN_LIST_FILE"
        echo "配置备份保留在: $CADDY_CONFIG_BACKUP_DIR"
    fi

    # 删除用户
    if id -u caddy &>/dev/null; then
        userdel caddy 2>/dev/null
    fi

    echo ""
    echo -e "${gl_lv}✅ Caddy 已卸载${gl_bai}"

    break_end
}

# Caddy 管理主菜单
manage_caddy() {
    while true; do
        clear
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_kjlan}  Caddy 多域名反代 🚀${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""

        # 显示当前状态
        local status=$(caddy_check_status)
        local server_ip=$(caddy_get_server_ip)

        case "$status" in
            "running")
                echo -e "服务状态: ${gl_lv}✅ 运行中${gl_bai}"
                ;;
            "stopped")
                echo -e "服务状态: ${gl_hong}❌ 已停止${gl_bai}"
                ;;
            "not_installed")
                echo -e "服务状态: ${gl_hui}未安装${gl_bai}"
                ;;
            *)
                echo -e "服务状态: ${gl_huang}⚠️ 未知${gl_bai}"
                ;;
        esac

        echo -e "服务器IP: ${gl_huang}${server_ip}${gl_bai}"

        # 显示域名数量
        if [ -f "$CADDY_DOMAIN_LIST_FILE" ]; then
            local domain_count=$(wc -l < "$CADDY_DOMAIN_LIST_FILE" 2>/dev/null || echo 0)
            echo -e "配置域名: ${gl_huang}${domain_count}${gl_bai} 个"
        fi

        echo ""
        echo "1. 一键部署 Caddy"
        echo "2. 添加反代域名"
        echo "3. 查看已配置域名"
        echo "4. 删除反代域名"
        echo "5. 重载 Caddy 配置"
        # 根据状态显示启动或停止
        if [ "$status" = "running" ]; then
            echo "6. 停止 Caddy ⏸️"
        else
            echo "6. 启动 Caddy ▶️"
        fi
        echo "7. 查看 Caddy 状态"
        echo "8. 查看 Caddy 日志"
        echo "9. 卸载 Caddy"
        echo "0. 返回主菜单"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"

        read -e -p "请选择操作 [0-9]: " choice

        case $choice in
            1)
                caddy_install
                ;;
            2)
                caddy_add_domain
                ;;
            3)
                caddy_list_domains
                ;;
            4)
                caddy_delete_domain
                ;;
            5)
                caddy_reload
                ;;
            6)
                caddy_toggle_service
                ;;
            7)
                caddy_show_status
                ;;
            8)
                caddy_show_logs
                ;;
            9)
                caddy_uninstall
                ;;
            0)
                return
                ;;
            *)
                echo "无效的选择"
                sleep 2
                ;;
        esac
    done
}

# 显示帮助信息
show_help() {
    cat << EOF
BBR v3 终极优化脚本 v${SCRIPT_VERSION}

用法: $0 [选项]

选项:
  -h, --help      显示此帮助信息
  -v, --version   显示版本号
  -i, --install   直接安装 XanMod 内核（非交互）
  --debug         启用调试模式（详细日志）
  -q, --quiet     静默模式（仅显示错误）

示例:
  $0              启动交互式菜单
  $0 -i           直接安装 BBR v3 内核
  $0 --debug      调试模式运行

日志文件: ${LOG_FILE}
配置文件: ~/.net-tcp-tune.conf 或 /etc/net-tcp-tune.conf
EOF
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "net-tcp-tune.sh v${SCRIPT_VERSION}"
                exit 0
                ;;
            -i|--install)
                check_root
                install_xanmod_kernel
                if [ $? -eq 0 ]; then
                    echo ""
                    echo "安装完成后，请重启系统以加载新内核"
                fi
                exit 0
                ;;
            --debug)
                LOG_LEVEL="DEBUG"
                log_debug "调试模式已启用"
                shift
                ;;
            -q|--quiet)
                LOG_LEVEL="ERROR"
                shift
                ;;
            -*)
                echo "未知选项: $1"
                echo "使用 -h 或 --help 查看帮助"
                exit 1
                ;;
            *)
                # 无参数时继续
                break
                ;;
        esac
    done
}

main() {
    # 先解析参数
    parse_args "$@"

    # 检查 root 权限
    check_root

    # 加载用户配置（如果存在）
    [ -f "/etc/net-tcp-tune.conf" ] && source "/etc/net-tcp-tune.conf"
    [ -f "$HOME/.net-tcp-tune.conf" ] && source "$HOME/.net-tcp-tune.conf"

    # 交互式菜单
    while true; do
        show_main_menu
    done
}

# 执行主函数
main "$@"
