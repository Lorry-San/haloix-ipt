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

话又说回来了，新脚本写好了，于是事情就简单了

```
wget -O ixsnat https://raw.githubusercontent.com/Lorry-San/haloix-ipt/refs/heads/main/ixsnat && chmod +x ixsnat && ./ixsnat
```


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
nano ixroute
<自己粘贴命令，去route.sh里面复制>
^O
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
