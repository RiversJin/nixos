# Router container + dae 运行手册

状态：已实施，按 2026-07-12 运行态整理
适用主机：`rivers-gateway`、`rivers-router` container、`rivers-host`、`rivers-laptop`

## 1. 当前架构

```text
Internet / PPPoE
       |
       v
rivers-router (NixOS container / network namespace)
  wan0 -> ppp0
  lan0 -> 192.168.50.1/24
  - PPPoE / NAT / IPv6 PD
  - dnsmasq / DHCP
  - dae 1.1.0: LAN 透明接管、国内/国外分流与 QUIC 黑洞
  - sing-box: 境外 TCP 代理出口与 DNS 策略，无 TUN
       |
       v
br-lan on rivers-gateway (192.168.50.2/24)
       |
       +-- rivers-host   192.168.50.10
       +-- rivers-laptop 192.168.50.11
       +-- other LAN clients: 默认直连
```

Router 已不再使用 libvirt/QEMU VM。NixOS container 通过 `br-wan`、`br-lan` 上的 veth 获得 `wan0`、`lan0`，并共享宿主机 `/sys/fs/bpf/rivers-router` 作为独立 bpffs。

## 2. 配置所有权

### 2.1 NixOS

运行配置仓库：

```text
/home/rivers/nixos
```

关键文件：

```text
configuration.nix                  # gateway 与监控屏
modules/router-host.nix            # br-wan / br-lan 与宿主网络
modules/router-container-host.nix  # container、veth、capability、bind mount
modules/router-container.nix       # container 入口
modules/router-system.nix          # PPPoE、NAT、DHCP、DNS、Router 基础系统
modules/router-dae.nix             # 纯 dae 服务与配置更新
modules/router-sing-box.nix        # sing-box TCP 代理适配器、DNS 入口与显式入口
modules/router-sing-box-sync.nix   # 原子发布配置到 Router
```

永久变更必须修改 Nix 配置并执行：

```bash
cd /home/rivers/nixos
sudo nixos-rebuild build --flake path:/home/rivers/nixos#rivers-gateway
sudo nixos-rebuild switch --flake path:/home/rivers/nixos#rivers-gateway
```

### 2.2 订阅与规则生成器

生成器是单独的 Git 仓库：

```text
/home/rivers/projects/sing-box-static-sub
```

gateway 上同路径保存部署副本。唯一生成入口：

```bash
./scripts/generate-and-sync.sh
```

每一轮原子生成：

```text
sing-box.json
policy.json
outbounds.json
config.dae
manifest.json
rulesets/*.srs
dae-assets/geoip.dat
dae-assets/geosite.dat
```

`config.dae` 与 sing-box 文件来自同一批订阅和规则，不允许在 Router 内手工维护另一套节点或路由。

gateway 的 `sing-box-static-sub.timer` 每天新加坡时间 04:00 触发，并加入最多 15 分钟随机延迟。订阅、SRS 与 dae Geo 数据统一生成；错过时间后由 `Persistent=true` 补跑。

## 3. 发布链路

```text
上游订阅
  -> sing-box-static-sub/dist/public
  -> router-sing-box-sync.service
  -> /home/rivers/.local/share/router-container-source/releases/<generation>
  -> current 原子 symlink
  -> container 内只读 bind mount:
     /home/rivers/.local/share/router-sing-box-source/current
```

发布器会检查 manifest、文件大小、rule-set 完整性、dae Geo SHA-256 及节点/VPS 链信息，并将 Router 快照权限收紧为仅 owner 可读。宿主 publication 和 Router sing-box 私有 release 都保留当前代加最近两代历史版本，成功切换后自动回收更旧目录。

`router-dae-update.timer` 每 2 分钟检查一次：

1. `dae validate -c config.dae`
2. 计算配置、`geoip.dat` 与 `geosite.dat` 的联合 SHA256
3. generation 未变化则不操作
4. generation 变化才重启 `dae.service`

因此订阅更新会同时更新节点和规则；失败时继续使用最后一份已验证配置。

## 4. dae 数据面

- 包：nixpkgs-unstable `dae 1.1.0`
- 配置：生成的 `config.dae`
- Geo 数据：生成器每日从 Loyalsoldier 刷新，GitHub 失败时尝试 jsDelivr，两者均失败时复用校验过的 last-good 发布
- LAN：`lan0`
- tproxy：`12345`，启用端口保护
- dial mode：`domain+`
- 探活间隔：1 分钟
- Web UI：无
- daed/GraphQL/`wing.db`：已移除

正常内核挂载应包含：

```text
lan0 clsact/ingress dae_lan_ingress_l2
lan0 clsact/egress  dae_lan_egress_l2
dae0 clsact/ingress dae_dae0_ingress
```

查看：

```bash
sudo systemctl -M rivers-router status dae.service
sudo journalctl -M rivers-router -u dae.service -f
sudo systemctl -M rivers-router status router-dae-update.timer
```

日志会给出来源 IP/MAC、目标域名、命中 outbound、实际 dialer 和 policy，可作为连接观测入口。

## 5. 当前策略

只有以下 MAC 被透明代理策略接管：

```text
04:7c:16:7c:32:e8  rivers-host
da:1a:db:85:ff:67  rivers-gateway
4c:49:6c:32:63:ab  rivers-laptop
74:38:22:95:34:e7  Xiaomi-15-Pro
ce:fa:b4:27:e9:8b  iPhone 13 Pro (private MAC)
2e:80:81:e5:6c:b6  iPad (private MAC)
```

其他设备命中 `fallback: must_direct`。

### 5.1 节点组

`proxy_adapter`：

- 固定 `vps_adapter`
- 通过无加密的本机 Shadowsocks 适配器 `127.0.0.1:7892` 将境外 TCP 交给 sing-box
- dae 只决定直连、黑洞或交给 sing-box；节点选择、VPS 链路和故障切换由 sing-box 执行
- 本机适配器流量的 `sport(7892)` 必须 `must_direct`，避免回环

### 5.2 直连规则

生成器会从每次订阅结果中提取所有节点及 VPS 的服务器域名/IP 和端口，为已纳管设备生成精确的 `must_direct` 规则。这些规则位于普通代理规则之前，避免本机或 laptop 的显式 sing-box 上游连接被 dae 再次代理；节点变化时该列表随订阅一起更新。

以下流量保持直连：

- 私网及组播
- DHCP/DHCPv6
- Steam 下载、游戏 UDP 端口及中国区内容
- `geoip:cn`、`geosite:cn`
- `riversjins.cc`

UDP/443 在 dae 层直接 `block`，故意黑洞 QUIC；客户端应回退到 TCP/HTTPS。这类 UDP/443 超时是预期策略，不是节点 UDP 故障。

代理目标失败时不自动降级为 direct，避免策略静默泄漏。

### 5.3 DNS

- LAN DNS 入口仍为 dnsmasq `192.168.50.1:53`
- dnsmasq 严格按顺序首先请求 sing-box `127.0.0.1:1053`，失败后回退 `223.5.5.5`
- sing-box 对国内域名使用阿里 DoH `dns-direct-ali`，境外域名使用 Cloudflare `dns-proxy-cf`
- dae 不再承担 DNS 上游分流，客户端的 53 端口流量 `must_direct`
- sing-box 完全停止时，dnsmasq 约等待 5 秒才切到 `223.5.5.5`；国内网站仍可直连，但首个未缓存 DNS 查询会变慢

## 6. sing-box 转发层

sing-box 不承担透明接管，也没有 TUN；dae 失效时不会因 sing-box TUN 留下整网黑洞。sing-box 负责 dae 交入的境外 TCP、DNS 策略和节点选择。

Router 内监听：

```text
127.0.0.1:9090  Clash API
127.0.0.1:7892  dae -> sing-box Shadowsocks none adapter
127.0.0.1:1053  dnsmasq -> sing-box DNS ingress
```

Clash API 只监听 Router loopback。Router nginx 在 `192.168.50.1:9090` 提供 LAN 入口，仅允许 gateway `192.168.50.2`、host `192.168.50.10` 和 laptop `192.168.50.11`，并反向代理 WebUI/API。

从 rivers-laptop 验证：

```bash
read -rs -p "Controller secret: " SECRET; echo
curl -H "Authorization: Bearer $SECRET" \
  http://192.168.50.1:9090/version
```

## 7. 网络与服务验证

Router 服务：

```bash
sudo systemctl -M rivers-router is-active \
  pppd-wan.service dnsmasq.service dae.service sing-box.service
```

从受管客户端验证透明 TCP：

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  curl -4 https://www.google.com/generate_204 -o /dev/null -w '%{http_code}\n'
```

预期 Google 为 `204`，未认证 OpenAI API 为 `401`。

QUIC 是故意黑洞的，可以用 `curl --http3-only` 验证连接超时；不要再把“公共 DNS UDP 可达”当成代理 UDP 健康指标。

## 8. 监控屏

gateway 本地无键鼠监控屏运行：

```text
cage -> foot -> tmux -> btop
```

顶部状态栏显示：

```text
Uptime / WAN / DNS latency / CPU / NVMe / HDD / Probe / FAN / Router / SMB / Tailscale
```

相关服务：

```bash
systemctl status cage-tty1.service
systemctl status router-health-check.timer
systemctl status monitor-disk-temperatures.timer
```

`router-health-check.timer` 每 30 秒检查 container、PPPoE、dnsmasq、dae eBPF hook 和 sing-box 本地入口，并原子写入：

```text
/run/router-health-status
```

状态为 `OK`、`DEGRADED` 或 `DOWN`。本地组件连续失败 3 次后只重启对应的 `pppd-wan`、`dnsmasq`、`dae` 或 `sing-box`，同一组件至少间隔 5 分钟才再次自愈。外部 DNS 失败只标记 `DEGRADED`，不触发重启；健康检查也不会自动重启整个 container。

手动验收：

```bash
router-smoke-test
```

该命令只读检查 container、本地 DNS、国内直连、OpenAI 代理和 WebUI，不执行自愈。

主板传感器依赖外部 `it87` 模块，必须先加载 `hwmon-vid`。正常应出现 `it8613-isa-0a30`、`fan2`、`fan3` 与 `temp1`。

## 9. 故障恢复

### 9.1 dae 异常

```bash
sudo systemctl -M rivers-router restart dae.service
sudo journalctl -M rivers-router -u dae.service -n 200 --no-pager
```

停止 dae 会撤除透明代理 eBPF，LAN 回到原生直连路径；PPPoE、NAT、DHCP 和 DNS 仍由 Router 提供。

### 9.2 sing-box 异常

```bash
sudo systemctl -M rivers-router restart sing-box.service
sudo journalctl -M rivers-router -u sing-box.service -n 200 --no-pager
```

sing-box 停止时，国内 `geosite:cn` / `geoip:cn` 流量仍由 dae 直连，DNS 约 5 秒后回退阿里 UDP；境外代理 TCP 会失败。这是预期的局部降级，不是整网中断。

### 9.3 新订阅异常

不要手工覆盖 `current`。检查：

```bash
systemctl status sing-box-static-sub.timer
systemctl status router-sing-box-sync.service
sudo systemctl -M rivers-router status router-dae-update.service
```

修复生成器后重新生成并发布。发布和激活均为 generation 原子切换。

### 9.4 Router container 异常

```bash
sudo systemctl status container@rivers-router.service
sudo systemctl restart container@rivers-router.service
```

container 重启会短暂中断 LAN 路由。远程操作前应确保操作者有独立网络路径。

## 10. 已移除的旧路径

以下内容不再是当前架构，排障时不要照旧文档恢复：

- libvirt/QEMU Router VM
- gateway 到 Router `7890/9090` 的 SSH local forward
- sing-box 旧 `7890` mixed 和 `7891` SOCKS 入口
- dae 直接管理远程节点和 `min_moving_avg` 选择
- daed Web UI、GraphQL、`wing.db`
- Grafana/Prometheus 监控栈
- sing-box TUN

当前边界：生成器拥有节点与规则；dae 拥有透明接管和粗粒度分流；sing-box 拥有境外 TCP 代理、DNS 策略和节点选择。
