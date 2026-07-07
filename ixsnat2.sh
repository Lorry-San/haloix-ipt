#!/bin/bash
###########################################
# SNAT + 策略路由 一体化配置脚本
# 功能：
# 1. 配置SNAT（内网接口 -> IX/公网接口）
# 2. 远程配置策略路由（通过SSH）
# 3. IX端内网接口网关指向本机内网 IP
# 4. IX端路由配置持久化
# 5. IX端DNS配置并持久化
###########################################
# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
green() {
    echo -e "${GREEN}$1${NC}"
}
yellow() {
    echo -e "${YELLOW}$1${NC}"
}
red() {
    echo -e "${RED}$1${NC}"
}
# 全局变量
INTERNAL_IF=""      # 内网接口，自动检测：ens20 或 eth2
EXTERNAL_IF=""      # IX/公网接口，自动检测：ens18 或 eth0
ALLOWED_IPS=()       # 允许转发的IP数组
LOCAL_eth2_IP=""    # 本机内网 IP（作为 IX 端内网网关）
###########################################
# 工具函数
###########################################
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
  else
    OS=$(uname -s)
  fi
  echo "$OS"
}
OS=$(detect_os)
install_dependencies() {
  # 1. 自动分析：检查 sshpass 是否已安装
  if command -v sshpass >/dev/null 2>&1; then
    green "检测到 sshpass 已存在，跳过安装。"
    return 0
  fi

  # 2. 如果不存在，则进行安装
  yellow "未检测到 sshpass，准备安装..."
  case "$OS" in
    ubuntu|debian)
      sudo apt update
      sudo apt install -y sshpass >/dev/null 2>&1
      ;;
    centos|rhel|rocky|alma)
      # sshpass 在 EPEL 源中
      if ! rpm -q epel-release >/dev/null 2>&1; then
          sudo yum install -y epel-release >/dev/null 2>&1
      fi
      sudo yum install -y sshpass >/dev/null 2>&1
      ;;
    alpine)
      sudo apk update
      sudo apk add --no-cache sshpass
      ;;
    *)
      red "不支持的系统: $OS，请手动安装 sshpass"
      exit 1
      ;;
  esac

  # 3. 安装后验证
  if command -v sshpass >/dev/null 2>&1; then
    green "sshpass 安装成功！"
  else
    red "sshpass 安装失败，请检查网络或源设置。"
    exit 1
  fi
}
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
log_step() {
    echo -e "${PURPLE}[STEP]${NC} $1"
}
print_header() {
    echo ""
    echo -e "${CYAN}===========================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}===========================================${NC}"
    echo ""
}
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}
check_interface() {
    if ! ip link show "$1" &> /dev/null; then
        log_error "网卡 $1 不存在"
        exit 1
    fi
    log_debug "网卡 $1 检查通过"
}
detect_interfaces() {
    if ip link show ens18 &>/dev/null && ip link show ens20 &>/dev/null; then
        EXTERNAL_IF="ens18"
        INTERNAL_IF="ens20"
    elif ip link show eth0 &>/dev/null && ip link show eth2 &>/dev/null; then
        EXTERNAL_IF="eth0"
        INTERNAL_IF="eth2"
    else
        log_error "无法自动识别网卡：需要 ens18/ens20 或 eth0/eth2 组合"
        exit 1
    fi

    log_debug "接口自动检测: IX/公网=$EXTERNAL_IF, 内网=$INTERNAL_IF"
}
get_internal_network() {
    local network=$(ip -o -f inet addr show "$INTERNAL_IF" | awk '{print $4}')
    if [ -z "$network" ]; then
        log_error "无法从 $INTERNAL_IF 获取IP段"
        exit 1
    fi
    echo "$network"
}
get_internal_ip() {
    local ip=$(ip -o -f inet addr show "$INTERNAL_IF" | awk '{print $4}' | cut -d'/' -f1)
    if [ -z "$ip" ]; then
        log_error "无法从 $INTERNAL_IF 获取IP地址"
        exit 1
    fi
    echo "$ip"
}
get_external_ip() {
    local ip=$(ip -o -f inet addr show "$EXTERNAL_IF" | awk '{print $4}' | cut -d'/' -f1)
    if [ -z "$ip" ]; then
        log_error "无法从 $EXTERNAL_IF 获取公网IP"
        exit 1
    fi
    echo "$ip"
}
validate_ip() {
    local ip=$1
    # 支持单个IP和CIDR格式
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        return 0
    else
        return 1
    fi
}
save_iptables() {
    log_debug "保存 iptables 规则..."
    if command -v iptables-save &> /dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        log_debug "规则已保存"
    else
        log_warn "未找到 iptables-save 命令，规则未持久化"
    fi
}
###########################################
# SNAT 配置函数
###########################################
init_snat() {
    log_step "初始化 SNAT 配置..."

    detect_interfaces

    # 检查网卡
    check_interface "$INTERNAL_IF"
    check_interface "$EXTERNAL_IF"
    
    # 获取网络信息
    INTERNAL_NETWORK=$(get_internal_network)
    EXTERNAL_IP=$(get_external_ip)
    LOCAL_eth2_IP=$(get_internal_ip)
    
    log_info "内网网段: $INTERNAL_NETWORK"
    log_info "内网IP ($INTERNAL_IF): $LOCAL_eth2_IP"
    log_info "IX/公网IP ($EXTERNAL_IF): $EXTERNAL_IP"
    
    # 启用IP转发
    log_debug "启用IP转发..."
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # 永久生效
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi
    
    # 清除现有的SNAT规则
    iptables -t nat -D POSTROUTING -s "$INTERNAL_NETWORK" -o "$EXTERNAL_IF" -j SNAT --to-source "$EXTERNAL_IP" 2>/dev/null
    
    # 设置FORWARD链默认策略
    log_debug "设置默认策略..."
    iptables -P FORWARD DROP
    
    # 清除旧的FORWARD规则
    iptables -D FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j LOG 2>/dev/null
    iptables -D FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j REJECT 2>/dev/null
    
    # 允许已建立的连接
    if ! iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
        log_debug "允许已建立和相关的连接..."
        iptables -I FORWARD 1 -m state --state ESTABLISHED,RELATED -j ACCEPT
    fi
    
    # 添加允许转发的IP
    log_debug "配置允许转发的IP..."
    for ip in "${ALLOWED_IPS[@]}"; do
        add_allowed_ip "$ip" "silent"
    done
    
    # 拒绝其他所有转发请求
    log_debug "配置拒绝其他IP的转发..."
    if ! iptables -C FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j LOG --log-prefix "FORWARD_REJECT: " 2>/dev/null; then
        iptables -A FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j LOG --log-prefix "FORWARD_REJECT: " --log-level 4
    fi
    if ! iptables -C FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j REJECT 2>/dev/null; then
        iptables -A FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j REJECT --reject-with icmp-host-prohibited
    fi
    
    # 配置SNAT
    log_debug "配置 SNAT 规则..."
    iptables -t nat -A POSTROUTING -s "$INTERNAL_NETWORK" -o "$EXTERNAL_IF" -j SNAT --to-source "$EXTERNAL_IP"
    
    # 保存规则
    save_iptables
    
    log_info "✅ SNAT 配置完成"
}
add_allowed_ip() {
    local ip="$1"
    local mode="$2"  # silent模式不显示详细信息
    
    if [ -z "$ip" ]; then
        log_error "请指定IP地址"
        return 1
    fi
    
    # 验证IP格式
    if ! validate_ip "$ip"; then
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
    
    # 插入到FORWARD链的第二条
    iptables -I FORWARD 2 -s "$ip" -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j ACCEPT
    
    if [ $? -eq 0 ]; then
        if [ "$mode" != "silent" ]; then
            log_info "✅ 已添加 $ip 到允许转发列表"
        fi
        return 0
    else
        log_error "添加 $ip 失败"
        return 1
    fi
}
show_snat_summary() {
    print_header "SNAT 配置摘要"
    
    detect_interfaces
    INTERNAL_NETWORK=$(get_internal_network)
    EXTERNAL_IP=$(get_external_ip)
    LOCAL_eth2_IP=$(get_internal_ip)
    
    echo -e "${CYAN}内网接口:${NC} $INTERNAL_IF"
    echo -e "  • IP: $LOCAL_eth2_IP"
    echo -e "  • 网段: $INTERNAL_NETWORK"
    echo -e "${CYAN}IX/公网接口:${NC} $EXTERNAL_IF ($EXTERNAL_IP)"
    echo -e "${CYAN}允许转发的IP:${NC}"
    
    for ip in "${ALLOWED_IPS[@]}"; do
        echo "  • $ip"
    done
    
    echo ""
}
###########################################
# 远程策略路由配置函数
###########################################
configure_remote_policy_routing() {
    print_header "远程策略路由配置"
    
    local remote_ip="$1"
    local remote_password="$2"
    local gateway_ip="$3"  # 本机内网 IP，作为 IX 端内网网关
    
    log_info "目标服务器: $remote_ip"
    log_info "IX 端内网网关将设置为: $gateway_ip (本机 $INTERNAL_IF)"
    
    # SSH配置
    local ssh_port=22
    local ssh_user="root"
    
    install_dependencies
    
    # 检测SSH连接
    log_step "测试 SSH 连接..."
    
    if ! command -v sshpass &> /dev/null; then
        log_error "需要安装 sshpass 工具"
        echo ""
        echo "请运行: apt install sshpass  或  yum install sshpass"
        return 1
    fi
    
    if ! sshpass -p "$remote_password" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p $ssh_port ${ssh_user}@${remote_ip} "echo 'SSH 连接成功'" 2>/dev/null; then
        log_error "SSH 连接失败，请检查 IP 和密码！"
        return 1
    fi
    
    log_info "✅ SSH 连接测试通过"
    
    # 生成远程执行脚本 - 使用文件方式避免转义问题
    log_step "生成策略路由配置脚本..."
    
    # 创建临时脚本文件
    local temp_script="/tmp/remote_policy_routing_$$.sh"
    
    cat > "$temp_script" << 'EOF'
#!/bin/bash
# 远程执行的策略路由配置脚本
# 在 IX 端禁用 apt-daily-upgrade 防止更新覆盖路由配置
systemctl stop apt-daily-upgrade.timer
systemctl stop apt-daily-upgrade.service
systemctl disable apt-daily-upgrade.timer
systemctl disable apt-daily-upgrade.service
echo "Disabled apt-daily-upgrade services"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'
print_header() {
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}==========================================${NC}"
}
print_success() {
    echo -e "${GREEN}   ✅ $1${NC}"
}
print_info() {
    echo -e "${YELLOW}   ℹ️  $1${NC}"
}
print_error() {
    echo -e "${RED}   ❌ $1${NC}"
    exit 1
}
get_ip() {
    local interface=$1
    ip addr show $interface 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1
}
get_network() {
    local interface=$1
    # Derive network prefix (CIDR) for interface
    # Try route table link-scope routes first
    local rt
    rt=$(ip route show dev "$interface" scope link 2>/dev/null | awk 'NR==1{print $1}')
    if [ -n "$rt" ]; then
        echo "$rt"
    else
        # Fallback: get IP/CIDR from address
        ip -o -f inet addr show "$interface" | awk '{print $4}' | head -n1
    fi
}
get_gateway() {
    local interface=$1
    ip route | grep "dev $interface" | grep via | awk '{print $3}' | head -n1
}
detect_ix_interfaces() {
    if ip link show ens18 &>/dev/null && ip link show ens20 &>/dev/null; then
        IX_IF="ens18"
        LAN_IF="ens20"
    elif ip link show eth0 &>/dev/null && ip link show eth2 &>/dev/null; then
        IX_IF="eth0"
        LAN_IF="eth2"
    else
        print_error "无法自动识别网卡：需要 ens18/ens20 或 eth0/eth2 组合"
    fi

    print_info "接口自动检测: IX/公网=$IX_IF, 内网=$LAN_IF"
}
check_interface() {
    local interface=$1
    if ! ip link show $interface &>/dev/null; then
        print_error "网卡 $interface 不存在！"
    fi
}
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
    else
        OS="unknown"
    fi
    
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        NETWORK_MANAGER="NetworkManager"
    elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        NETWORK_MANAGER="systemd-networkd"
    elif [ -f /etc/network/interfaces ]; then
        NETWORK_MANAGER="interfaces"
    elif [ -d /etc/sysconfig/network-scripts ]; then
        NETWORK_MANAGER="network-scripts"
    else
        NETWORK_MANAGER="unknown"
    fi
    
    print_info "系统: $OS, 网络管理: $NETWORK_MANAGER"
}
configure_dns() {
    print_info "配置 DNS 服务器..."
    
    DNS1="1.1.1.1"
    DNS2="8.8.8.8"
    
    # 备份原有配置
    if [ -f /etc/resolv.conf ] && [ ! -f /etc/resolv.conf.backup ]; then
        cp /etc/resolv.conf /etc/resolv.conf.backup
        print_info "已备份原 DNS 配置到 /etc/resolv.conf.backup"
    fi
    
    case "$NETWORK_MANAGER" in
        NetworkManager)
            configure_dns_networkmanager
            ;;
        systemd-networkd)
            configure_dns_systemd_networkd
            ;;
        *)
            configure_dns_generic
            ;;
    esac
    
    # 立即应用 DNS 设置
    cat > /etc/resolv.conf << DNSEOF
# DNS Configuration - Managed by policy routing script
nameserver $DNS1
nameserver $DNS2
options timeout:2 attempts:3 rotate single-request-reopen
DNSEOF
    
    print_success "DNS 已配置: $DNS1, $DNS2"
}
configure_dns_networkmanager() {
    print_info "使用 NetworkManager 持久化 DNS..."
    
    # 禁止 NetworkManager 自动修改 resolv.conf
    if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
        if ! grep -q "dns=none" /etc/NetworkManager/NetworkManager.conf; then
            sed -i '/\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
        fi
    fi
    
    # 使用 nmcli 配置 DNS（如果有具体连接）
    if command -v nmcli &>/dev/null; then
        # 获取活动连接
        ACTIVE_CONN=$(nmcli -t -f NAME,DEVICE connection show --active | grep "$LAN_IF" | cut -d: -f1 | head -n1)
        if [ -n "$ACTIVE_CONN" ]; then
            nmcli connection modify "$ACTIVE_CONN" ipv4.dns "1.1.1.1 8.8.8.8" 2>/dev/null
            nmcli connection modify "$ACTIVE_CONN" ipv4.ignore-auto-dns yes 2>/dev/null
            print_info "已通过 NetworkManager 设置 DNS"
        fi
    fi
    
    # 保护 resolv.conf 不被覆盖
    chattr -i /etc/resolv.conf 2>/dev/null
    cat > /etc/resolv.conf << NMRESOLVEOF
# DNS Configuration - Protected
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3 rotate single-request-reopen
NMRESOLVEOF
    chattr +i /etc/resolv.conf 2>/dev/null
    
    print_success "NetworkManager DNS 配置完成"
}
configure_dns_systemd_networkd() {
    print_info "使用 systemd-networkd 持久化 DNS..."
    
    # 配置 systemd-resolved
    if [ -f /etc/systemd/resolved.conf ]; then
        cat > /etc/systemd/resolved.conf << RESOLVEDCONF
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.0.0.1 8.8.4.4
DNSSEC=allow-downgrade
DNSOverTLS=no
RESOLVEDCONF
        
        systemctl restart systemd-resolved 2>/dev/null
        print_info "已配置 systemd-resolved"
    fi
    
    # 确保 resolv.conf 链接正确
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    fi
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || \
    cat > /etc/resolv.conf << SDRESOLVEOF
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3 rotate single-request-reopen
SDRESOLVEOF
    
    print_success "systemd-networkd DNS 配置完成"
}
configure_dns_generic() {
    print_info "使用通用方法持久化 DNS..."
    
    # 创建 DNS 配置脚本
    cat > /usr/local/bin/setup-dns.sh << 'DNSSCRIPT'
#!/bin/bash
# DNS 配置脚本
# 移除不可变属性
chattr -i /etc/resolv.conf 2>/dev/null
# 配置 DNS
cat > /etc/resolv.conf << RESOLVEOF
# DNS Configuration - Auto configured
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3 rotate single-request-reopen
RESOLVEOF
# 设置为不可变（防止被覆盖）
chattr +i /etc/resolv.conf 2>/dev/null
logger "DNS 配置已应用"
DNSSCRIPT
    chmod +x /usr/local/bin/setup-dns.sh
    
    # 立即执行
    /usr/local/bin/setup-dns.sh
    
    # 添加到 rc.local
    if [ -f /etc/rc.local ]; then
        if ! grep -q "setup-dns.sh" /etc/rc.local; then
            sed -i '/^exit 0/d' /etc/rc.local
            echo "/usr/local/bin/setup-dns.sh" >> /etc/rc.local
            echo "exit 0" >> /etc/rc.local
        fi
    fi
    
    # 创建 systemd 服务
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/dns-setup.service << 'DNSSERVICE'
[Unit]
Description=DNS Configuration
After=network.target
Before=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-dns.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
DNSSERVICE
        
        systemctl daemon-reload
        systemctl enable dns-setup.service 2>/dev/null
        print_info "已创建 DNS systemd 服务"
    fi
    
    print_success "通用 DNS 配置完成"
}
persist_routes() {
    print_info "开始持久化路由配置..."
    
    case "$NETWORK_MANAGER" in
        NetworkManager)
            persist_routes_networkmanager
            ;;
        systemd-networkd)
            persist_routes_systemd_networkd
            ;;
        interfaces)
            persist_routes_interfaces
            ;;
        network-scripts)
            persist_routes_network_scripts
            ;;
        *)
            print_info "使用通用方法持久化..."
            persist_routes_generic
            ;;
    esac
}
persist_routes_networkmanager() {
    print_info "使用 NetworkManager 持久化路由..."
    
    mkdir -p /etc/NetworkManager/dispatcher.d
    
    cat > /etc/NetworkManager/dispatcher.d/99-policy-routing << 'NMSCRIPT'
#!/bin/bash
detect_policy_interfaces() {
    if ip link show ens18 &>/dev/null && ip link show ens20 &>/dev/null; then
        IX_IF="ens18"
        LAN_IF="ens20"
    elif ip link show eth0 &>/dev/null && ip link show eth2 &>/dev/null; then
        IX_IF="eth0"
        LAN_IF="eth2"
    else
        logger "policy-routing: no supported interface pair found"
        exit 1
    fi
}

if [ "$2" = "up" ]; then
    sleep 2
    detect_policy_interfaces
    
    IX_IP=$(ip addr show "$IX_IF" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
    IX_GATEWAY=$(ip route | grep "dev $IX_IF" | grep via | awk '{print $3}' | head -n1)
    LAN_GATEWAY="__GATEWAY_IP__"
    
    IX_TABLE="ix_return"
    IX_TABLE_ID="100"
    IX_MARK="100"
    
    if ! grep -q "$IX_TABLE" /etc/iproute2/rt_tables; then
        echo "$IX_TABLE_ID $IX_TABLE" >> /etc/iproute2/rt_tables
    fi
    
    ip rule del from "$IX_IP" table "$IX_TABLE" 2>/dev/null
    [ -n "$IX_IP" ] && ip rule add from "$IX_IP" table "$IX_TABLE" priority 100
    
    ip rule del fwmark "$IX_MARK" table "$IX_TABLE" 2>/dev/null
    ip rule add fwmark "$IX_MARK" table "$IX_TABLE" priority 99
    
    ip route flush table "$IX_TABLE"
    
    [ -n "$IX_GATEWAY" ] && ip route add default via "$IX_GATEWAY" dev "$IX_IF" table "$IX_TABLE"
    
    for iface in "$IX_IF" "$LAN_IF" ens19; do
        if ip link show $iface &>/dev/null; then
            NETWORK=$(ip addr show $iface 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -n1)
            SRC_IP=$(ip addr show $iface 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
            [ -n "$NETWORK" ] && [ -n "$SRC_IP" ] && ip route add "$NETWORK" dev "$iface" src "$SRC_IP" table "$IX_TABLE"
        fi
    done
    
    ip route del default 2>/dev/null
    ip route add default via "$LAN_GATEWAY" dev "$LAN_IF"
    ip route flush cache 2>/dev/null
    
    # 确保 DNS 配置
    /usr/local/bin/setup-dns.sh 2>/dev/null
fi
NMSCRIPT
    
    sed -i "s/__GATEWAY_IP__/$LAN_GATEWAY/g" /etc/NetworkManager/dispatcher.d/99-policy-routing
    chmod +x /etc/NetworkManager/dispatcher.d/99-policy-routing
    print_success "NetworkManager dispatcher 脚本已创建"
}
persist_routes_systemd_networkd() {
    print_info "使用 systemd-networkd 持久化路由..."
    
    cat > /usr/local/bin/setup-policy-routing.sh << 'SDSCRIPT'
#!/bin/bash
detect_policy_interfaces() {
    if ip link show ens18 &>/dev/null && ip link show ens20 &>/dev/null; then
        IX_IF="ens18"
        LAN_IF="ens20"
    elif ip link show eth0 &>/dev/null && ip link show eth2 &>/dev/null; then
        IX_IF="eth0"
        LAN_IF="eth2"
    else
        logger "policy-routing: no supported interface pair found"
        exit 1
    fi
}
detect_policy_interfaces
IX_IP=$(ip addr show "$IX_IF" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
IX_GATEWAY=$(ip route | grep "dev $IX_IF" | grep via | awk '{print $3}' | head -n1)
LAN_GATEWAY="__GATEWAY_IP__"
IX_TABLE="ix_return"
IX_TABLE_ID="100"
IX_MARK="100"
if ! grep -q "$IX_TABLE" /etc/iproute2/rt_tables; then
    echo "$IX_TABLE_ID $IX_TABLE" >> /etc/iproute2/rt_tables
fi
ip rule del from "$IX_IP" table "$IX_TABLE" 2>/dev/null
[ -n "$IX_IP" ] && ip rule add from "$IX_IP" table "$IX_TABLE" priority 100
ip rule del fwmark "$IX_MARK" table "$IX_TABLE" 2>/dev/null
ip rule add fwmark "$IX_MARK" table "$IX_TABLE" priority 99
ip route flush table "$IX_TABLE"
[ -n "$IX_GATEWAY" ] && ip route add default via "$IX_GATEWAY" dev "$IX_IF" table "$IX_TABLE"
for iface in "$IX_IF" "$LAN_IF" ens19; do
    if ip link show $iface &>/dev/null; then
        NETWORK=$(ip addr show $iface 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -n1)
        SRC_IP=$(ip addr show $iface 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
        [ -n "$NETWORK" ] && [ -n "$SRC_IP" ] && ip route add "$NETWORK" dev "$iface" src "$SRC_IP" table "$IX_TABLE"
    fi
done
ip route del default 2>/dev/null
ip route add default via "$LAN_GATEWAY" dev "$LAN_IF"
ip route flush cache 2>/dev/null
SDSCRIPT
    sed -i "s/__GATEWAY_IP__/$LAN_GATEWAY/g" /usr/local/bin/setup-policy-routing.sh
    chmod +x /usr/local/bin/setup-policy-routing.sh
    
    cat > /etc/systemd/system/policy-routing.service << 'SDSERVICE'
[Unit]
Description=Policy Routing Configuration
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/setup-policy-routing.sh
[Install]
WantedBy=multi-user.target
SDSERVICE
    systemctl daemon-reload
    systemctl enable policy-routing.service
    # 每30秒运行一次策略路由和DNS配置
    cat > /etc/systemd/system/policy-routing.timer << 'TIMER'
[Unit]
Description=Run policy-routing.service every 30 seconds
[Timer]
OnBootSec=30
OnUnitActiveSec=30
Unit=policy-routing.service
[Install]
WantedBy=timers.target
TIMER
    systemctl daemon-reload
    systemctl enable policy-routing.timer
    systemctl start policy-routing.timer
    print_success "policy-routing.timer 已启用"
    print_success "systemd-networkd 配置已创建"
}
persist_routes_interfaces() {
    print_info "使用 /etc/network/interfaces 持久化路由..."
    
    mkdir -p /etc/network/if-up.d
    
    cat > /etc/network/if-up.d/policy-routing << 'IFSCRIPT'
#!/bin/bash
detect_policy_interfaces() {
    if ip link show ens18 &>/dev/null && ip link show ens20 &>/dev/null; then
        IX_IF="ens18"
        LAN_IF="ens20"
    elif ip link show eth0 &>/dev/null && ip link show eth2 &>/dev/null; then
        IX_IF="eth0"
        LAN_IF="eth2"
    else
        logger "policy-routing: no supported interface pair found"
        exit 1
    fi
}
detect_policy_interfaces

if [ "$IFACE" = "$LAN_IF" ] || [ "$IFACE" = "$IX_IF" ]; then
    sleep 2
    
    IX_IP=$(ip addr show "$IX_IF" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
    IX_GATEWAY=$(ip route | grep "dev $IX_IF" | grep via | awk '{print $3}' | head -n1)
    LAN_GATEWAY="__GATEWAY_IP__"
    
    IX_TABLE="ix_return"
    IX_TABLE_ID="100"
    IX_MARK="100"
    
    if ! grep -q "$IX_TABLE" /etc/iproute2/rt_tables; then
        echo "$IX_TABLE_ID $IX_TABLE" >> /etc/iproute2/rt_tables
    fi
    
    ip rule del from "$IX_IP" table "$IX_TABLE" 2>/dev/null
    [ -n "$IX_IP" ] && ip rule add from "$IX_IP" table "$IX_TABLE" priority 100
    
    ip rule del fwmark "$IX_MARK" table "$IX_TABLE" 2>/dev/null
    ip rule add fwmark "$IX_MARK" table "$IX_TABLE" priority 99
    
    ip route flush table "$IX_TABLE"
    
    [ -n "$IX_GATEWAY" ] && ip route add default via "$IX_GATEWAY" dev "$IX_IF" table "$IX_TABLE"
    
    for iface in "$IX_IF" "$LAN_IF" ens19; do
        if ip link show $iface &>/dev/null; then
            NETWORK=$(ip addr show $iface 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -n1)
            SRC_IP=$(ip addr show $iface 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
            [ -n "$NETWORK" ] && [ -n "$SRC_IP" ] && ip route add "$NETWORK" dev "$iface" src "$SRC_IP" table "$IX_TABLE"
        fi
    done
    
    ip route del default 2>/dev/null
    ip route add default via "$LAN_GATEWAY" dev "$LAN_IF"
    ip route flush cache 2>/dev/null
    
    # 确保 DNS 配置
    /usr/local/bin/setup-dns.sh 2>/dev/null
fi
IFSCRIPT
    sed -i "s/__GATEWAY_IP__/$LAN_GATEWAY/g" /etc/network/if-up.d/policy-routing
    chmod +x /etc/network/if-up.d/policy-routing
    print_success "/etc/network/if-up.d 脚本已创建"
}
persist_routes_network_scripts() {
    print_info "使用 network-scripts 持久化路由..."
    persist_routes_generic
}
persist_routes_generic() {
    print_info "使用 rc.local 持久化路由..."
    
    cat > /usr/local/bin/setup-policy-routing.sh << 'RCSCRIPT'
#!/bin/bash
sleep 3
detect_policy_interfaces() {
    if ip link show ens18 &>/dev/null && ip link show ens20 &>/dev/null; then
        IX_IF="ens18"
        LAN_IF="ens20"
    elif ip link show eth0 &>/dev/null && ip link show eth2 &>/dev/null; then
        IX_IF="eth0"
        LAN_IF="eth2"
    else
        logger "policy-routing: no supported interface pair found"
        exit 1
    fi
}
detect_policy_interfaces
IX_IP=$(ip addr show "$IX_IF" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
IX_GATEWAY=$(ip route | grep "dev $IX_IF" | grep via | awk '{print $3}' | head -n1)
LAN_GATEWAY="__GATEWAY_IP__"
IX_TABLE="ix_return"
IX_TABLE_ID="100"
IX_MARK="100"
if ! grep -q "$IX_TABLE" /etc/iproute2/rt_tables; then
    echo "$IX_TABLE_ID $IX_TABLE" >> /etc/iproute2/rt_tables
fi
ip rule del from "$IX_IP" table "$IX_TABLE" 2>/dev/null
[ -n "$IX_IP" ] && ip rule add from "$IX_IP" table "$IX_TABLE" priority 100
ip rule del fwmark "$IX_MARK" table "$IX_TABLE" 2>/dev/null
ip rule add fwmark "$IX_MARK" table "$IX_TABLE" priority 99
ip route flush table "$IX_TABLE"
[ -n "$IX_GATEWAY" ] && ip route add default via "$IX_GATEWAY" dev "$IX_IF" table "$IX_TABLE"
for iface in "$IX_IF" "$LAN_IF" ens19; do
    if ip link show $iface &>/dev/null; then
        NETWORK=$(ip addr show $iface 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -n1)
        SRC_IP=$(ip addr show $iface 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
        [ -n "$NETWORK" ] && [ -n "$SRC_IP" ] && ip route add "$NETWORK" dev "$iface" src "$SRC_IP" table "$IX_TABLE"
    fi
done
ip route del default 2>/dev/null
ip route add default via "$LAN_GATEWAY" dev "$LAN_IF"
ip route flush cache 2>/dev/null
logger "策略路由配置已应用"
RCSCRIPT
    sed -i "s/__GATEWAY_IP__/$LAN_GATEWAY/g" /usr/local/bin/setup-policy-routing.sh
    chmod +x /usr/local/bin/setup-policy-routing.sh
    
    if [ -f /etc/rc.local ]; then
        if ! grep -q "setup-policy-routing.sh" /etc/rc.local; then
            sed -i '/^exit 0/d' /etc/rc.local
            echo "/usr/local/bin/setup-policy-routing.sh &" >> /etc/rc.local
            echo "/usr/local/bin/setup-dns.sh &" >> /etc/rc.local
            echo "exit 0" >> /etc/rc.local
        fi
        chmod +x /etc/rc.local
    else
        cat > /etc/rc.local << 'RCLOCALFILE'
#!/bin/bash
/usr/local/bin/setup-policy-routing.sh &
/usr/local/bin/setup-dns.sh &
exit 0
RCLOCALFILE
        chmod +x /etc/rc.local
    fi
    
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/rc-local.service << 'RCLOCALSERVICE'
[Unit]
Description=/etc/rc.local Compatibility
ConditionPathExists=/etc/rc.local
After=network-online.target
Wants=network-online.target
[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
StandardOutput=tty
RemainAfterExit=yes
SysVStartPriority=99
[Install]
WantedBy=multi-user.target
RCLOCALSERVICE
        
        systemctl daemon-reload
        systemctl enable rc-local.service 2>/dev/null
    fi
    
    print_success "rc.local 配置已创建"
}
persist_iptables() {
    print_info "持久化 iptables 规则..."
    
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    
    if command -v systemctl &>/dev/null; then
        if ! systemctl list-unit-files | grep -q "iptables-persistent\|netfilter-persistent"; then
            cat > /etc/systemd/system/iptables-restore.service << 'IPTSERVICE'
[Unit]
Description=Restore iptables rules
Before=network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
[Install]
WantedBy=multi-user.target
IPTSERVICE
            
            systemctl daemon-reload
            systemctl enable iptables-restore.service 2>/dev/null
        fi
    fi
    
    print_success "iptables 规则已持久化"
}
persist_sysctl() {
    print_info "持久化 sysctl 配置..."
    
    cat > /etc/sysctl.d/99-policy-routing.conf << SYSCTLCONF
net.ipv4.conf.${IX_IF}.rp_filter=2
net.ipv4.conf.${LAN_IF}.rp_filter=2
net.ipv4.conf.all.rp_filter=2
net.ipv4.ip_forward=1
SYSCTLCONF
    
    sysctl -p /etc/sysctl.d/99-policy-routing.conf > /dev/null 2>&1
    print_success "sysctl 配置已持久化"
}
configure_policy_routing() {
    print_header "开始配置策略路由"
    
    if [ "$EUID" -ne 0 ]; then 
        print_error "需要 root 权限"
    fi
    
    detect_system
    
    echo ""
    echo "【步骤1】检查网卡..."
    detect_ix_interfaces
    check_interface "$IX_IF"
    print_success "$IX_IF 存在（IX/公网）"
    check_interface "$LAN_IF"
    print_success "$LAN_IF 存在（内网）"
    
    HAS_ENS19=false
    if ip link show ens19 &>/dev/null; then
        HAS_ENS19=true
        print_success "ens19 存在"
    else
        print_info "ens19 不存在（跳过）"
    fi
    
    echo ""
    echo "【步骤2】读取 $IX_IF (IX/公网) 配置..."
    IX_IP=$(get_ip "$IX_IF")
    [ -z "$IX_IP" ] && print_error "无法读取 $IX_IF 的 IP 地址！"
    print_success "IX IP: $IX_IP"
    
    IX_GATEWAY=$(get_gateway "$IX_IF")
    if [ -z "$IX_GATEWAY" ]; then
        IX_NETWORK=$(ip addr show "$IX_IF" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -n1)
        IX_GATEWAY=$(echo $IX_NETWORK | awk -F'.' '{print $1"."$2"."$3".1"}')
        print_info "自动推算网关: $IX_GATEWAY"
    else
        print_success "检测到网关: $IX_GATEWAY"
    fi
    
    IX_NETWORK=$(get_network "$IX_IF")
    print_success "IX 网段: $IX_NETWORK"
    
    echo ""
    echo "【步骤3】读取 $LAN_IF 配置..."
    LAN_IP=$(get_ip "$LAN_IF")
    LAN_NETWORK=$(get_network "$LAN_IF")
    print_success "$LAN_IF IP: $LAN_IP"
    print_success "$LAN_IF 网段: $LAN_NETWORK"
    
    LAN_GATEWAY="__GATEWAY_IP__"
    print_success "$LAN_IF Gateway: $LAN_GATEWAY (SNAT 服务器)"
    
    if [ "$HAS_ENS19" = true ]; then
        echo ""
        echo "【步骤4】读取 ens19 配置..."
        ENS19_IP=$(get_ip "ens19")
        ENS19_NETWORK=$(get_network "ens19")
        print_success "ens19 IP: $ENS19_IP"
        print_success "ens19 网段: $ENS19_NETWORK"
    fi
    
    echo ""
    echo "【步骤5】配置 DNS..."
    configure_dns
    
    IX_TABLE="ix_return"
    IX_TABLE_ID="100"
    IX_MARK="100"
    
    echo ""
    echo "【步骤6】创建路由表..."
    if ! grep -q "$IX_TABLE" /etc/iproute2/rt_tables; then
        echo "$IX_TABLE_ID $IX_TABLE" >> /etc/iproute2/rt_tables
        print_success "路由表 $IX_TABLE 已创建"
    else
        print_info "路由表 $IX_TABLE 已存在"
    fi
    
    echo ""
    echo "【步骤7】清理现有路由配置..."
    ip route del default via "$IX_GATEWAY" dev "$IX_IF" 2>/dev/null
    while ip rule del from $IX_IP table $IX_TABLE 2>/dev/null; do :; done
    while ip rule del fwmark $IX_MARK table $IX_TABLE 2>/dev/null; do :; done
    ip route flush table $IX_TABLE
    print_success "旧配置已清理"
    
    echo ""
    echo "【步骤8】配置新路由..."
    ip route del default 2>/dev/null
    ip route add default via "$LAN_GATEWAY" dev "$LAN_IF"
    print_success "默认路由: $LAN_IF -> $LAN_GATEWAY"
    
    ip route add default via "$IX_GATEWAY" dev "$IX_IF" table "$IX_TABLE"
    print_success "IX 回程默认路由: $IX_IF -> $IX_GATEWAY"
    
    ip route add "$IX_NETWORK" dev "$IX_IF" src "$IX_IP" table "$IX_TABLE"
    print_success "添加路由: $IX_NETWORK via $IX_IF"
    
    ip route add "$LAN_NETWORK" dev "$LAN_IF" src "$LAN_IP" table "$IX_TABLE"
    print_success "添加路由: $LAN_NETWORK via $LAN_IF"
    
    if [ "$HAS_ENS19" = true ] && [ -n "$ENS19_IP" ]; then
        ip route add $ENS19_NETWORK dev ens19 src $ENS19_IP table $IX_TABLE
        print_success "添加路由: $ENS19_NETWORK via ens19"
    fi
    
    echo ""
    echo "【步骤9】添加策略路由规则..."
    ip rule add from $IX_IP table $IX_TABLE priority 100
    print_success "规则: from $IX_IP use table $IX_TABLE (priority 100)"
    
    ip rule add fwmark $IX_MARK table $IX_TABLE priority 99
    print_success "规则: fwmark $IX_MARK use table $IX_TABLE (priority 99)"
    
    echo ""
    echo "【步骤10】配置 iptables 连接跟踪..."
    iptables -t mangle -D PREROUTING -i "$IX_IF" -j CONNMARK --set-mark $IX_MARK 2>/dev/null
    iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null
    iptables -t mangle -A PREROUTING -i "$IX_IF" -j CONNMARK --set-mark $IX_MARK
    iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark
    print_success "连接跟踪已配置"
    
    echo ""
    echo "【步骤11】调整系统参数..."
    sysctl -w "net.ipv4.conf.${IX_IF}.rp_filter=2" > /dev/null
    sysctl -w "net.ipv4.conf.${LAN_IF}.rp_filter=2" > /dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=2 > /dev/null
    print_success "rp_filter 已设置为宽松模式(2)"
    
    ip route flush cache 2>/dev/null
    print_success "路由缓存已刷新"
    
    echo ""
    echo "【步骤12】持久化配置..."
    persist_sysctl
    persist_iptables
    persist_routes
    print_success "所有配置已持久化"
    
    echo ""
    print_header "策略路由配置完成！"
    echo ""
    echo "📌 网卡配置："
    echo "   • $IX_IF (IX/公网): $IX_IP / $IX_NETWORK -> $IX_GATEWAY"
    echo "   • $LAN_IF: $LAN_IP / $LAN_NETWORK -> $LAN_GATEWAY (SNAT服务器)"
    [ "$HAS_ENS19" = true ] && echo "   • ens19: $ENS19_IP / $ENS19_NETWORK"
    echo ""
    echo "📌 DNS 配置："
    echo "   • 主 DNS: 1.1.1.1 (Cloudflare)"
    echo "   • 备 DNS: 8.8.8.8 (Google)"
    echo ""
    echo "📌 路由策略："
    echo "   • 默认出站: $LAN_IF -> $LAN_GATEWAY (通过SNAT服务器)"
    echo "   • IX 回程: $IX_IF -> $IX_GATEWAY"
    echo ""
    echo "📌 持久化方式："
    echo "   • 系统: $OS"
    echo "   • 网络管理: $NETWORK_MANAGER"
    echo "   • 配置已在系统重启后自动生效"
    echo ""
    echo "📌 验证 DNS："
    echo "   • 运行: nslookup google.com"
    echo "   • 运行: dig google.com"
    echo ""
}
configure_policy_routing
reboot
EOF
    # 替换网关占位符
    sed -i "s/__GATEWAY_IP__/$gateway_ip/g" "$temp_script"
    
    # 执行远程配置
    log_step "执行远程策略路由配置..."
    echo ""
    
    if sshpass -p "$remote_password" ssh -o StrictHostKeyChecking=no -p $ssh_port ${ssh_user}@${remote_ip} "bash -s" < "$temp_script" 2>&1; then
        echo ""
        log_info "✅ 远程策略路由配置成功！"
        rm -f "$temp_script"
        return 0
    else
        echo ""
        log_error "远程配置失败！"
        rm -f "$temp_script"
        return 1
    fi
}
###########################################
# 交互式配置主流程
###########################################
interactive_setup() {
    check_root
    
    print_header "Halocloud IX SNAT + 策略路由 一体化配置向导 v3.2"
    
    # 首先自动检测本机接口并获取内网 IP
    detect_interfaces
    check_interface "$INTERNAL_IF"
    LOCAL_eth2_IP=$(get_internal_ip)
    
    log_info "本机内网接口: $INTERNAL_IF ($LOCAL_eth2_IP)"
    log_info "本机 IX/公网接口: $EXTERNAL_IF ($(get_external_ip 2>/dev/null || echo '待检测'))"
    log_info "此 IP 将作为 IX 端内网接口的网关"
    
    # 步骤1: 获取 IX IP 信息
    echo ""
    log_step "步骤 1/3: 配置远程 IX 服务器"
    echo ""
    
    read -p "请输入 IX 服务器的 IP 地址: " IX_SERVER_IP
    if [ -z "$IX_SERVER_IP" ]; then
        log_error "IP 地址不能为空！"
        exit 1
    fi
    
    if ! validate_ip "$IX_SERVER_IP"; then
        log_error "无效的 IP 地址格式！"
        exit 1
    fi
    
    read -s -p "请输入 IX 服务器的 SSH 密码: " IX_SERVER_PASSWORD
    echo ""
    
    if [ -z "$IX_SERVER_PASSWORD" ]; then
        log_error "密码不能为空！"
        exit 1
    fi
    
    # 自动将 IX IP 添加到允许列表
    ALLOWED_IPS+=("$IX_SERVER_IP")
    log_info "✅ IX IP $IX_SERVER_IP 已自动添加到允许列表"
    
    # 步骤2: 添加其他允许的IP
    echo ""
    log_step "步骤 2/3: 配置允许转发的 IP 地址"
    echo ""
    log_info "IX IP ($IX_SERVER_IP) 已自动添加"
    echo ""
    
    
    # 步骤3: 确认配置
    echo ""
    log_step "步骤 3/3: 确认配置"
    echo ""
    echo -e "${CYAN}配置摘要:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${YELLOW}本机 (SNAT 服务器):${NC}"
    echo "    $INTERNAL_IF IP: $LOCAL_eth2_IP"
    echo "    $EXTERNAL_IF (IX/公网出口): $(get_external_ip 2>/dev/null || echo '待检测')"
    echo ""
    echo -e "  ${YELLOW}远程 IX 服务器:${NC}"
    echo "    IP: $IX_SERVER_IP"
    echo "    内网网关将设置为: ${GREEN}$LOCAL_eth2_IP${NC} (本机 $INTERNAL_IF)"
    echo "    DNS: 1.1.1.1, 8.8.8.8"
    echo "    将配置策略路由并持久化"
    echo ""
    echo -e "  ${YELLOW}允许转发的 IP 列表:${NC}"
    for ip in "${ALLOWED_IPS[@]}"; do
        if [ "$ip" == "$IX_SERVER_IP" ]; then
            echo "    • $ip ${GREEN}(IX Server)${NC}"
        else
            echo "    • $ip"
        fi
    done
    echo ""
    echo -e "  ${YELLOW}网络拓扑:${NC}"
    echo "    IX Server (内网接口) -> $LOCAL_eth2_IP (本机 $INTERNAL_IF) -> 公网 ($EXTERNAL_IF)"
    echo ""
    echo -e "  ${YELLOW}持久化配置:${NC}"
    echo "    • IX 端路由规则将在重启后自动恢复"
    echo "    • IX 端 DNS 配置将在重启后自动恢复"
    echo "    • 本地 SNAT 规则将在重启后自动恢复"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    read -p "确认开始配置？(yes/no) [yes]: " confirm
    confirm=${confirm:-yes}
    
    if [ "$confirm" != "yes" ]; then
        log_warn "配置已取消"
        exit 0
    fi
    
    # 执行配置
    echo ""
    print_header "开始执行配置"
    
    # 1. 配置本地 SNAT
    echo ""
    log_step "【阶段 1/2】配置本地 SNAT..."
    echo ""
    init_snat
    save_iptables
    
    # 显示 SNAT 配置结果
    show_snat_summary
    
    # 2. 配置远程策略路由（传入本机内网 IP 作为网关）
    echo ""
    log_step "【阶段 2/2】配置远程策略路由、DNS 并持久化..."
    echo ""
    
    if configure_remote_policy_routing "$IX_SERVER_IP" "$IX_SERVER_PASSWORD" "$LOCAL_eth2_IP"; then
        print_header "🎉 全部配置完成！"
        echo ""
        echo -e "${GREEN}✅ 本地 SNAT 配置成功${NC}"
        echo -e "${GREEN}✅ 远程策略路由配置成功${NC}"
        echo -e "${GREEN}✅ 远程 DNS 配置成功${NC}"
        echo -e "${GREEN}✅ 所有配置已持久化${NC}"
        echo ""
        echo -e "${CYAN}配置详情:${NC}"
        echo "  • 本机内网接口: $INTERNAL_IF ($LOCAL_eth2_IP)"
        echo "  • 本机 IX/公网接口: $EXTERNAL_IF"
        echo "  • 允许转发的 IP 数量: ${#ALLOWED_IPS[@]}"
        echo "  • 远程 IX 服务器: $IX_SERVER_IP"
        echo "  • IX 内网网关: $LOCAL_eth2_IP (指向本机 $INTERNAL_IF)"
        echo "  • IX DNS: 1.1.1.1, 8.8.8.8"
        echo ""
        echo -e "${CYAN}流量路径:${NC}"
        echo "  ${YELLOW}主动出站:${NC} IX Server -> 本机 $INTERNAL_IF ($LOCAL_eth2_IP) -> SNAT -> 公网 ($EXTERNAL_IF)"
        echo "  ${YELLOW}IX 回程:${NC} 公网 -> IX Server IX/公网接口 -> 原路返回"
        echo ""
        echo -e "${CYAN}持久化状态:${NC}"
        echo "  ${GREEN}✓${NC} 本地 iptables 规则已保存"
        echo "  ${GREEN}✓${NC} 远程路由规则已配置开机自启"
        echo "  ${GREEN}✓${NC} 远程 DNS 已配置开机自启"
        echo "  ${GREEN}✓${NC} 系统重启后自动恢复配置"
        echo ""
        echo -e "${YELLOW}验证命令 (在 IX 端运行):${NC}"
        echo "  • 测试 DNS: nslookup google.com"
        echo "  • 测试网关: ping $LOCAL_eth2_IP"
        echo "  • 查看路由: ip route"
        echo "  • 查看 DNS: cat /etc/resolv.conf"
        echo ""
        echo -e "${YELLOW}注意事项:${NC}"
        echo "  • 所有配置已自动保存并持久化"
        echo "  • DNS 配置已锁定，防止被覆盖"
        echo "  • 如需添加更多 IP，请使用: $0 add <IP>"
        echo ""
    else
        echo ""
        log_warn "本地 SNAT 配置成功，但远程策略路由配置失败"
        log_info "您可以稍后手动配置远程服务器"
        log_info "IX 端内网网关应设置为: $LOCAL_eth2_IP"
        log_info "IX 端 DNS 应设置为: 1.1.1.1, 8.8.8.8"
    fi
}
###########################################
# 单独命令处理函数
###########################################
handle_add_ip() {
    check_root
    local ip="$1"
    
    if [ -z "$ip" ]; then
        log_error "请指定 IP 地址"
        echo "用法: $0 add <IP地址>"
        exit 1
    fi
    
    detect_interfaces
    check_interface "$INTERNAL_IF"
    check_interface "$EXTERNAL_IF"
    
    add_allowed_ip "$ip"
    save_iptables
}
handle_del_ip() {
    check_root
    local ip="$1"
    
    if [ -z "$ip" ]; then
        log_error "请指定 IP 地址"
        echo "用法: $0 del <IP地址>"
        exit 1
    fi
    
    detect_interfaces
    check_interface "$INTERNAL_IF"
    check_interface "$EXTERNAL_IF"
    
    # 删除规则
    if iptables -C FORWARD -s "$ip" -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j ACCEPT 2>/dev/null; then
        iptables -D FORWARD -s "$ip" -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -j ACCEPT
        log_info "✅ 已从允许列表删除 $ip"
        save_iptables
    else
        log_warn "IP $ip 不在允许列表中"
    fi
}
handle_list() {
    detect_interfaces
    check_interface "$INTERNAL_IF"
    check_interface "$EXTERNAL_IF"
    
    print_header "允许转发的 IP 列表"
    
    INTERNAL_NETWORK=$(get_internal_network)
    EXTERNAL_IP=$(get_external_ip)
    LOCAL_eth2_IP=$(get_internal_ip)
    
    echo -e "${BLUE}本机配置:${NC}"
    echo -e "  • 内网接口: $INTERNAL_IF ($LOCAL_eth2_IP)"
    echo -e "  • IX/公网接口: $EXTERNAL_IF ($EXTERNAL_IP)"
    echo -e "  • 网段: $INTERNAL_NETWORK"
    echo ""
    
    local rules=$(iptables -L FORWARD -n -v --line-numbers | grep "$EXTERNAL_IF" | grep ACCEPT | grep -v "state RELATED,ESTABLISHED")
    
    if [ -z "$rules" ]; then
        log_warn "当前没有配置允许转发的 IP"
    else
        echo -e "${GREEN}序号  数据包  字节数    源地址${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "$rules" | awk '{printf "%-6s%-8s%-10s%s\n", $1, $2, $3, $8}'
    fi
    
    echo ""
}
show_help() {
    cat << EOF
${GREEN}SNAT + 策略路由 一体化配置脚本 (带持久化 + DNS)${NC}
${YELLOW}用法:${NC}
    $0                    # 运行交互式配置向导
    $0 <command> [args]   # 执行单独命令
${YELLOW}可用命令:${NC}
    ${BLUE}setup${NC}               运行完整配置向导（推荐首次使用）
    ${BLUE}add${NC} <IP>           添加允许转发的 IP 地址
    ${BLUE}del${NC} <IP>           删除允许转发的 IP 地址
    ${BLUE}list${NC}                列出所有允许转发的 IP
    ${BLUE}help${NC}                显示此帮助信息
${YELLOW}配置向导包含:${NC}
    1. 输入 IX 服务器 IP 和密码
    2. 自动将 IX IP 添加到 SNAT 允许列表
    3. 可选添加其他允许转发的 IP
    4. 自动配置本地 SNAT
    5. 自动配置远程策略路由
    6. IX 端内网网关自动设置为本机内网 IP
    ${GREEN}7. IX 端 DNS 设置为 1.1.1.1 和 8.8.8.8${NC}
    ${GREEN}8. 所有配置自动持久化（重启后自动恢复）${NC}
${YELLOW}DNS 配置:${NC}
    • 主 DNS: 1.1.1.1 (Cloudflare)
    • 备 DNS: 8.8.8.8 (Google)
    • 自动锁定，防止被覆盖
    • 重启后自动恢复
${YELLOW}持久化支持:${NC}
    • NetworkManager (Ubuntu 18+, CentOS 8+)
    • systemd-networkd (现代 Linux)
    • /etc/network/interfaces (Debian/Ubuntu)
    • network-scripts (CentOS/RHEL 7)
    • rc.local (通用兜底方案)
${YELLOW}网络拓扑:${NC}
    IX Server (内网接口) -> 本机内网 IP -> SNAT -> IX/公网接口
${YELLOW}示例:${NC}
    # 首次使用 - 运行完整配置向导
    $0
    
    # 添加更多允许的 IP
    $0 add 192.168.1.105
    
    # 查看允许列表
    $0 list
${YELLOW}前置要求:${NC}
    • 必须使用 root 权限运行
    • 需要安装 sshpass: apt install sshpass
${YELLOW}验证 DNS (在 IX 端):${NC}
    nslookup google.com
    cat /etc/resolv.conf
EOF
}
###########################################
# 主函数
###########################################
main() {
    case "${1:-setup}" in
        setup|init|config|configure)
            interactive_setup
            ;;
        add)
            handle_add_ip "$2"
            ;;
        del|delete|remove)
            handle_del_ip "$2"
            ;;
        list|ls|show)
            handle_list
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            if [ -z "$1" ]; then
                interactive_setup
            else
                log_error "未知命令: $1"
                echo ""
                show_help
                exit 1
            fi
            ;;
    esac
}
# 执行主函数
main "$@"
