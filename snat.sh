#!/bin/bash

###########################################
# SNAT 配置和管理脚本
# 入口: ens20 (自动检测IP段)
# 出口: ens18 (自动检测公网IP)
# 功能: 配置SNAT、管理允许转发的IP
###########################################

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

# 定义网卡接口
INTERNAL_IF="ens20"  # 内网接口
EXTERNAL_IF="ens18"  # 外网接口

# 默认允许转发的IP列表（初始配置时使用）
DEFAULT_ALLOWED_IPS=(
    "192.168.1.100"
    "192.168.1.101"
    # 添加更多默认允许的IP
)

# 检查网卡是否存在
check_interface() {
    if ! ip link show "$1" &> /dev/null; then
        log_error "网卡 $1 不存在"
        exit 1
    fi
    log_debug "网卡 $1 检查通过"
}

# 获取内网网段
get_internal_network() {
    local network=$(ip -o -f inet addr show "$INTERNAL_IF" | awk '{print $4}')
    if [ -z "$network" ]; then
        log_error "无法从 $INTERNAL_IF 获取IP段"
        exit 1
    fi
    echo "$network"
}

# 获取外网IP
get_external_ip() {
    local ip=$(ip -o -f inet addr show "$EXTERNAL_IF" | awk '{print $4}' | cut -d'/' -f1)
    if [ -z "$ip" ]; then
        log_error "无法从 $EXTERNAL_IF 获取公网IP"
        exit 1
    fi
    echo "$ip"
}

# 保存iptables规则
save_iptables() {
    log_info "保存 iptables 规则..."
    if command -v iptables-save &> /dev/null; then
        # 对于 Debian/Ubuntu
        if [ -d /etc/iptables ]; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4
        # 对于 CentOS/RHEL 7
        elif [ -f /usr/libexec/iptables/iptables.init ]; then
            /usr/libexec/iptables/iptables.init save
        # 对于 CentOS/RHEL 6
        elif command -v service &> /dev/null && service iptables status &>/dev/null; then
            service iptables save
        else
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4
            log_warn "规则已保存到 /etc/iptables/rules.v4，请配置开机自启"
        fi
        log_info "规则已保存"
    else
        log_warn "未找到 iptables-save 命令，规则未持久化"
    fi
}

# 初始化SNAT配置
init_snat() {
    check_root
    
    log_info "开始初始化 SNAT 配置..."
    
    # 检查网卡
    check_interface "$INTERNAL_IF"
    check_interface "$EXTERNAL_IF"
    
    # 获取网络信息
    INTERNAL_NETWORK=$(get_internal_network)
    EXTERNAL_IP=$(get_external_ip)
    
    log_info "内网网段: $INTERNAL_NETWORK"
    log_info "外网IP: $EXTERNAL_IP"
    
    # 启用IP转发
    log_info "启用IP转发..."
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # 永久生效
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi
    
    # 清除现有的自定义链（如果存在）
    iptables -t nat -D POSTROUTING -s "$INTERNAL_NETWORK" -o "$EXTERNAL_IF" -j SNAT --to-source "$EXTERNAL_IP" 2>/dev/null
    
    # 设置FORWARD链默认策略
    log_info "设置默认策略..."
    iptables -P FORWARD DROP
    
    # 清除旧的FORWARD规则（谨慎使用）
    # 只删除与我们接口相关的规则
    iptables -D FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j LOG 2>/dev/null
    iptables -D FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j REJECT 2>/dev/null
    
    # 允许已建立的连接
    if ! iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
        log_info "允许已建立和相关的连接..."
        iptables -I FORWARD 1 -m state --state ESTABLISHED,RELATED -j ACCEPT
    fi
    
    # 添加默认允许的IP
    log_info "配置默认允许转发的IP..."
    for ip in "${DEFAULT_ALLOWED_IPS[@]}"; do
        add_allowed_ip "$ip" "silent"
    done
    
    # 拒绝其他所有转发请求
    log_info "配置拒绝其他IP的转发..."
    if ! iptables -C FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j LOG --log-prefix "FORWARD_REJECT: " 2>/dev/null; then
        iptables -A FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j LOG --log-prefix "FORWARD_REJECT: " --log-level 4
    fi
    if ! iptables -C FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j REJECT 2>/dev/null; then
        iptables -A FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j REJECT --reject-with icmp-host-prohibited
    fi
    
    # 配置SNAT
    log_info "配置 SNAT 规则..."
    iptables -t nat -A POSTROUTING -s "$INTERNAL_NETWORK" -o "$EXTERNAL_IF" -j SNAT --to-source "$EXTERNAL_IP"
    
    # 保存规则
    save_iptables
    
    # 显示配置结果
    echo ""
    log_info "========================================="
    log_info "SNAT 初始化配置完成！"
    log_info "========================================="
    log_info "内网段: $INTERNAL_NETWORK ($INTERNAL_IF)"
    log_info "公网IP: $EXTERNAL_IP ($EXTERNAL_IF)"
    log_info "允许转发的IP数量: ${#DEFAULT_ALLOWED_IPS[@]}"
    log_info "========================================="
    echo ""
    
    show_rules
}

# 添加允许转发的IP
add_allowed_ip() {
    check_root
    local ip="$1"
    local mode="$2"  # silent模式不显示详细信息
    
    if [ -z "$ip" ]; then
        log_error "请指定IP地址"
        return 1
    fi
    
    # 验证IP格式（简单验证）
    if ! [[ "$ip" =~ ^[0-9./]+$ ]]; then
        log_error "无效的IP地址格式: $ip"
        return 1
    fi
    
    # 检查规则是否已存在
    if iptables -C FORWARD -s "$ip" -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j ACCEPT 2>/dev/null; then
        if [ "$mode" != "silent" ]; then
            log_warn "IP $ip 已在允许列表中"
        fi
        return 0
    fi
    
    # 插入到FORWARD链的第二条（第一条是ESTABLISHED,RELATED）
    iptables -I FORWARD 2 -s "$ip" -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j ACCEPT
    
    if [ $? -eq 0 ]; then
        if [ "$mode" != "silent" ]; then
            log_info "已添加 $ip 到允许转发列表"
            save_iptables
        fi
        return 0
    else
        log_error "添加 $ip 失败"
        return 1
    fi
}

# 删除允许转发的IP
del_allowed_ip() {
    check_root
    local ip="$1"
    
    if [ -z "$ip" ]; then
        log_error "请指定IP地址"
        return 1
    fi
    
    # 检查规则是否存在
    if ! iptables -C FORWARD -s "$ip" -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j ACCEPT 2>/dev/null; then
        log_warn "IP $ip 不在允许列表中"
        return 1
    fi
    
    iptables -D FORWARD -s "$ip" -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j ACCEPT
    
    if [ $? -eq 0 ]; then
        log_info "已从允许列表删除 $ip"
        save_iptables
        return 0
    else
        log_error "删除 $ip 失败"
        return 1
    fi
}

# 列出所有允许转发的IP
list_allowed_ips() {
    echo ""
    log_info "========================================="
    log_info "当前允许转发的IP列表:"
    log_info "========================================="
    
    # 显示网络信息
    INTERNAL_NETWORK=$(get_internal_network)
    EXTERNAL_IP=$(get_external_ip)
    echo -e "${BLUE}内网接口:${NC} $INTERNAL_IF ($INTERNAL_NETWORK)"
    echo -e "${BLUE}外网接口:${NC} $EXTERNAL_IF ($EXTERNAL_IP)"
    echo ""
    
    # 提取允许的IP规则
    local rules=$(iptables -L FORWARD -n -v --line-numbers | grep "$EXTERNAL_IF" | grep ACCEPT | grep -v "state RELATED,ESTABLISHED")
    
    if [ -z "$rules" ]; then
        log_warn "当前没有配置允许转发的IP"
    else
        echo -e "${GREEN}序号  数据包  字节数    源地址          ${NC}"
        echo "-------------------------------------------"
        echo "$rules" | awk '{printf "%-6s%-8s%-10s%s\n", $1, $2, $3, $8}'
    fi
    
    echo ""
    log_info "========================================="
    
    # 显示NAT规则
    echo ""
    log_info "当前 SNAT 规则:"
    iptables -t nat -L POSTROUTING -n -v --line-numbers | grep "$EXTERNAL_IF"
    echo ""
}

# 显示所有相关规则
show_rules() {
    echo ""
    log_info "========================================="
    log_info "完整的 FORWARD 规则:"
    log_info "========================================="
    iptables -L FORWARD -n -v --line-numbers
    
    echo ""
    log_info "========================================="
    log_info "完整的 NAT 规则:"
    log_info "========================================="
    iptables -t nat -L POSTROUTING -n -v --line-numbers
    echo ""
}

# 清除所有SNAT配置
clear_snat() {
    check_root
    
    log_warn "准备清除所有 SNAT 配置..."
    read -p "确定要清除吗？(yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "取消操作"
        return 0
    fi
    
    INTERNAL_NETWORK=$(get_internal_network)
    EXTERNAL_IP=$(get_external_ip)
    
    # 删除NAT规则
    log_info "删除 SNAT 规则..."
    iptables -t nat -D POSTROUTING -s "$INTERNAL_NETWORK" -o "$EXTERNAL_IF" -j SNAT --to-source "$EXTERNAL_IP" 2>/dev/null
    
    # 删除FORWARD规则
    log_info "删除 FORWARD 规则..."
    
    # 删除所有与该接口相关的规则
    while iptables -L FORWARD -n --line-numbers | grep "$EXTERNAL_IF" | grep -v "state RELATED,ESTABLISHED" | head -1 | awk '{print $1}' | xargs -I {} iptables -D FORWARD {} 2>/dev/null; do
        :
    done
    
    save_iptables
    log_info "SNAT 配置已清除"
}

# 显示帮助信息
show_help() {
    cat << EOF

${GREEN}SNAT 配置和管理脚本${NC}

${YELLOW}用法:${NC}
    $0 <command> [options]

${YELLOW}命令:${NC}
    ${BLUE}init${NC}              初始化SNAT配置（首次运行）
    ${BLUE}add${NC} <IP>          添加允许转发的IP地址
    ${BLUE}del${NC} <IP>          删除允许转发的IP地址
    ${BLUE}list${NC}              列出所有允许转发的IP
    ${BLUE}show${NC}              显示所有iptables规则
    ${BLUE}clear${NC}             清除所有SNAT配置
    ${BLUE}help${NC}              显示此帮助信息

${YELLOW}示例:${NC}
    # 初始化配置
    $0 init

    # 添加允许转发的IP
    $0 add 192.168.1.105
    $0 add 192.168.1.0/24

    # 删除IP
    $0 del 192.168.1.105

    # 查看允许列表
    $0 list

    # 查看所有规则
    $0 show

    # 清除配置
    $0 clear

${YELLOW}配置说明:${NC}
    内网接口: $INTERNAL_IF
    外网接口: $EXTERNAL_IF
    
    修改默认允许的IP列表，请编辑脚本中的 DEFAULT_ALLOWED_IPS 数组

${YELLOW}注意事项:${NC}
    - 必须使用 root 权限运行
    - 首次使用请先运行 'init' 命令
    - 规则会自动保存并持久化
    - IP地址支持单个IP或CIDR格式的网段

EOF
}

# 主函数
main() {
    case "$1" in
        init)
            init_snat
            ;;
        add)
            if [ -z "$2" ]; then
                log_error "请指定IP地址"
                echo "用法: $0 add <IP地址>"
                exit 1
            fi
            check_interface "$INTERNAL_IF"
            check_interface "$EXTERNAL_IF"
            add_allowed_ip "$2"
            ;;
        del|delete|remove)
            if [ -z "$2" ]; then
                log_error "请指定IP地址"
                echo "用法: $0 del <IP地址>"
                exit 1
            fi
            check_interface "$INTERNAL_IF"
            check_interface "$EXTERNAL_IF"
            del_allowed_ip "$2"
            ;;
        list|ls)
            check_interface "$INTERNAL_IF"
            check_interface "$EXTERNAL_IF"
            list_allowed_ips
            ;;
        show|status)
            show_rules
            ;;
        clear|reset)
            clear_snat
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            if [ -z "$1" ]; then
                show_help
            else
                log_error "未知命令: $1"
                echo ""
                show_help
            fi
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"