## Halocloud-QianhaiIX(KKIX) 路由配置脚本

> [!Note]
> · 你需要让kk给你开sd-wan，让iepl接入才行。不然一切都是白搭（当然现在根本买不到）

---

### 0.网络架构介绍

kk网络架构现在是这样的:

- 一台IX单端，包括两个网卡: ens18和ens20.ens18是IX的出入口，ens20是IEPL的内网端口
- 一台香港Akari，也有两个网卡，ens18是Akari出口，ens20也是IEPL内网端口
- 我们现在要做的就是在Akari上开启SNAT，并限制仅你自己那台IX单端的ens20对应的IP可以走Akari转发，防止被别人偷路由。同时要在IX单端配置策略路由，在能访问公网的同时保证IX单端可以被公有云访问，不会直接变成一辈子连不上的失踪机器。
- 所以分为两个脚本，一个route.sh配置策略路由，一个snat.sh配置SNAT

### 1.快速开始

#### 模拟环境

##### IX
ens18 IP:163.223.125.86
ens20 IP:192.168.80.36

##### Akari
ens18 IP:163.53.18.154
ens20 IP:192.168.80.38

---

先在香港Akari配置SNAT

```
wget -O snat https://raw.githubusercontent.com/Lorry-San/haloix-ipt/refs/heads/main/snat.sh && chmod +x snat && ./snat init
```

接着我们添加IX的ens20 IP

```
./snat add 192.168.80.36
```

随后我们回到IX单端上

然后开始配置路由:

```
cat >/root/ixroute<<EOF
#!/bin/bash
# ========== 策略路由配置脚本 ==========
# 功能：自动配置多网卡策略路由

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ========== 工具函数 ==========
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
}

# 获取网卡IP地址
get_ip() {
    local interface=$1
    ip addr show $interface 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1
}

# 获取网卡网段
get_network() {
    local interface=$1
    ip addr show $interface 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -n1
}

# 获取网关（从路由表）
get_gateway() {
    local interface=$1
    ip route | grep "dev $interface" | grep via | awk '{print $3}' | head -n1
}

# 检查网卡是否存在
check_interface() {
    local interface=$1
    if ! ip link show $interface &>/dev/null; then
        print_error "网卡 $interface 不存在！"
        exit 1
    fi
}

# ========== 策略路由配置 ==========
configure_policy_routing() {
    print_header "策略路由配置工具"
    
    # 检查是否为root
    if [ "$EUID" -ne 0 ]; then 
        print_error "请使用 root 权限运行此脚本"
        exit 1
    fi
    
    # 检查网卡
    echo ""
    echo "【步骤1】检查网卡..."
    check_interface "ens18"
    print_success "ens18 存在"
    check_interface "ens20"
    print_success "ens20 存在"
    
    # 检查 ens19（可选）
    HAS_ENS19=false
    if ip link show ens19 &>/dev/null; then
        HAS_ENS19=true
        print_success "ens19 存在"
    else
        print_info "ens19 不存在（跳过）"
    fi
    
    # 自动读取 ens18 配置
    echo ""
    echo "【步骤2】读取 ens18 (IX) 配置..."
    IX_IP=$(get_ip "ens18")
    if [ -z "$IX_IP" ]; then
        print_error "无法读取 ens18 的 IP 地址！"
        exit 1
    fi
    print_success "IX IP: $IX_IP"
    
    # 尝试自动获取网关
    IX_GATEWAY=$(get_gateway "ens18")
    if [ -z "$IX_GATEWAY" ]; then
        # 从IP地址推算网关（假设是网段的.1）
        IX_NETWORK=$(ip addr show ens18 | grep 'inet ' | awk '{print $2}' | head -n1)
        IX_GATEWAY=$(echo $IX_NETWORK | awk -F'.' '{print $1"."$2"."$3".1"}')
        print_info "自动推算网关: $IX_GATEWAY"
    else
        print_success "检测到网关: $IX_GATEWAY"
    fi
    
    # 读取 ens18 网段
    ENS18_NETWORK=$(get_network "ens18")
    print_success "IX 网段: $ENS18_NETWORK"
    
    # 读取 ens20 配置
    echo ""
    echo "【步骤3】读取 ens20 配置..."
    ENS20_IP=$(get_ip "ens20")
    ENS20_NETWORK=$(get_network "ens20")
    print_success "ens20 IP: $ENS20_IP"
    print_success "ens20 网段: $ENS20_NETWORK"
    
    # 提供默认网关建议
    SUGGESTED_GW=$(echo $ENS20_NETWORK | awk -F'.' '{print $1"."$2"."$3".1"}')
    echo ""
    read -p "请输入 ens20 网关 [默认: $SUGGESTED_GW]: " ENS20_GATEWAY
    ENS20_GATEWAY=${ENS20_GATEWAY:-$SUGGESTED_GW}
    print_success "ens20 Gateway: $ENS20_GATEWAY"
    
    # 读取 ens19 配置（如果存在）
    if [ "$HAS_ENS19" = true ]; then
        echo ""
        echo "【步骤4】读取 ens19 配置..."
        ENS19_IP=$(get_ip "ens19")
        ENS19_NETWORK=$(get_network "ens19")
        print_success "ens19 IP: $ENS19_IP"
        print_success "ens19 网段: $ENS19_NETWORK"
    fi
    
    # 路由表配置
    IX_TABLE="ix_return"
    IX_TABLE_ID="100"
    IX_MARK="100"
    
    echo ""
    echo "【步骤5】创建路由表..."
    if ! grep -q "$IX_TABLE" /etc/iproute2/rt_tables; then
        echo "$IX_TABLE_ID $IX_TABLE" >> /etc/iproute2/rt_tables
        print_success "路由表 $IX_TABLE 已创建"
    else
        print_info "路由表 $IX_TABLE 已存在"
    fi
    
    echo ""
    echo "【步骤6】清理现有路由配置..."
    # 删除可能存在的默认路由
    ip route del default via $IX_GATEWAY dev ens18 2>/dev/null
    # 清理策略路由规则
    while ip rule del from $IX_IP table $IX_TABLE 2>/dev/null; do :; done
    while ip rule del fwmark $IX_MARK table $IX_TABLE 2>/dev/null; do :; done
    # 清空路由表
    ip route flush table $IX_TABLE
    print_success "旧配置已清理"
    
    echo ""
    echo "【步骤7】配置新路由..."
    
    # 设置默认路由走 ens20（主动出站流量）
    ip route del default 2>/dev/null
    ip route add default via $ENS20_GATEWAY dev ens20
    print_success "默认路由: ens20 -> $ENS20_GATEWAY"
    
    # 配置 IX 回程路由表
    ip route add default via $IX_GATEWAY dev ens18 table $IX_TABLE
    print_success "IX 回程默认路由: ens18 -> $IX_GATEWAY"
    
    ip route add $ENS18_NETWORK dev ens18 src $IX_IP table $IX_TABLE
    print_success "添加路由: $ENS18_NETWORK via ens18"
    
    ip route add $ENS20_NETWORK dev ens20 src $ENS20_IP table $IX_TABLE
    print_success "添加路由: $ENS20_NETWORK via ens20"
    
    if [ "$HAS_ENS19" = true ] && [ -n "$ENS19_IP" ]; then
        ip route add $ENS19_NETWORK dev ens19 src $ENS19_IP table $IX_TABLE
        print_success "添加路由: $ENS19_NETWORK via ens19"
    fi
    
    echo ""
    echo "【步骤8】添加策略路由规则..."
    # 源IP为IX地址的流量使用 ix_return 表
    ip rule add from $IX_IP table $IX_TABLE priority 100
    print_success "规则: from $IX_IP use table $IX_TABLE (priority 100)"
    
    # 基于连接标记的策略路由
    ip rule add fwmark $IX_MARK table $IX_TABLE priority 99
    print_success "规则: fwmark $IX_MARK use table $IX_TABLE (priority 99)"
    
    echo ""
    echo "【步骤9】配置 iptables 连接跟踪..."
    # 清理旧规则
    iptables -t mangle -D PREROUTING -i ens18 -j CONNMARK --set-mark $IX_MARK 2>/dev/null
    iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null
    
    # 添加新规则
    iptables -t mangle -A PREROUTING -i ens18 -j CONNMARK --set-mark $IX_MARK
    iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark
    print_success "连接跟踪已配置"
    
    echo ""
    echo "【步骤10】调整系统参数..."
    # 调整反向路径过滤
    sysctl -w net.ipv4.conf.ens18.rp_filter=2 > /dev/null
    sysctl -w net.ipv4.conf.ens20.rp_filter=2 > /dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=2 > /dev/null
    print_success "rp_filter 已设置为宽松模式(2)"
    
    # 刷新路由缓存
    ip route flush cache 2>/dev/null
    print_success "路由缓存已刷新"
    
    echo ""
    echo "【步骤11】保存配置..."
    # 保存 iptables 规则
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    print_success "iptables 规则已保存到 /etc/iptables/rules.v4"
    
    # 显示配置总结
    echo ""
    print_header "配置完成总结"
    echo ""
    echo "📌 网卡配置："
    echo "   • ens18 (IX):"
    echo "     - IP: $IX_IP"
    echo "     - 网段: $ENS18_NETWORK"
    echo "     - 网关: $IX_GATEWAY"
    echo ""
    echo "   • ens20:"
    echo "     - IP: $ENS20_IP"
    echo "     - 网段: $ENS20_NETWORK"
    echo "     - 网关: $ENS20_GATEWAY"
    echo ""
    if [ "$HAS_ENS19" = true ]; then
        echo "   • ens19:"
        echo "     - IP: $ENS19_IP"
        echo "     - 网段: $ENS19_NETWORK"
        echo ""
    fi
    echo "📌 路由策略："
    echo "   • 默认出站: ens20 -> $ENS20_GATEWAY"
    echo "   • IX 回程: ens18 -> $IX_GATEWAY"
    echo "   • 策略路由表: $IX_TABLE (ID: $IX_TABLE_ID)"
    echo "   • 连接标记: $IX_MARK"
    echo ""
    echo "📌 工作原理："
    echo "   ✓ 主动发起的连接通过 ens20 出去"
    echo "   ✓ 从 ens18 进来的连接回复从 ens18 出去"
    echo "   ✓ 使用连接跟踪确保会话一致性"
    echo ""
    print_header "所有配置已成功完成！"
    echo ""
    
    # 显示当前路由规则
    echo "当前策略路由规则："
    ip rule list | grep -E "(from $IX_IP|fwmark $IX_MARK)" | sed 's/^/   /'
    echo ""
    
    echo "当前路由表 $IX_TABLE 内容："
    ip route show table $IX_TABLE | sed 's/^/   /'
    echo ""
}

# ========== 主程序 ==========
main() {
    configure_policy_routing
}

# 运行主程序
main
EOF

chmod +x ixroute
./ixroute
```

随后脚本提示我们输入ens20的网关，我们输入'192.168.80.38'

接着就会自动配置好

最后推荐跑一句
```
cat >/etc/resolv.conf<<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
```

---

#### 连通性测试

```
ping 1.1.1.1 -c 3
```

如果能正常ping通那么说明你成功配置好了
