# Claude Code 专用网络

共享模块位于 `modules/claude-vps`。目前仅 `rivers-gateway` 启用；host 和 laptop
已经导入模块，但默认关闭。此模块不安装 Claude Code，也不改变 DSH 的启动方式。

## 网络路径

```text
claude-net / claude-vps
  -> 本机 claude-vps network namespace
  -> cvps-peer / cvps-host（路由转发，不做 NAT）
  -> 固定下一跳 192.168.50.1
  -> Router dae：来源 10.203.0.0/24
  -> 127.0.0.1:7893 的 Mihomo 专用 SOCKS listener
  -> VPS
```

VPS 节点为 TCP-only。namespace 内的 Unbound 在 `127.0.0.1:53` 接受 DNS，
上游使用经 VPS 转发的 DNS-over-TLS。外部 UDP、IPv6 和私网目标不放行。
这也意味着局域网 MCP、宿主机 localhost、QUIC 等不会自动绕过隔离。

`fleet.nix` 集中登记地址和 Router 回程路由：

| 主机 | LAN 地址 | namespace 地址 | veth 网段 |
|---|---|---|---|
| rivers-gateway | 192.168.50.2 | 10.203.0.2 | 10.203.0.0/30 |
| rivers-host | 192.168.50.10 | 10.203.0.6 | 10.203.0.4/30 |
| rivers-laptop | 192.168.50.11 | 10.203.0.10 | 10.203.0.8/30 |

Router 的 `claude_vps_guard` 独立于 dae，丢弃这些来源未经代理接管的转发流量，
并阻止访问 Router 普通本地服务。主机策略路由表 20300 固定下一跳；保留
`unreachable default` 和第二条不可达策略规则，避免接口或路由表消失后退回主机
其他默认路由。主机防火墙还会核对实际下一跳必须是 Router。

代理生成器的持久修改在
`/home/rivers/projects/sing-box-static-sub/src/config/{claude-network,template-dae,template-mihomo}.js`。
地址池必须与 `fleet.nix` 一致。专用 listener 直接选择 `VPS`，不经过通用规则组。
移动端生成结果不添加此 listener。

本机生成器目录是没有 `.git` 的部署副本。对应源码差异保存在
`hosts/rivers-gateway/patches/claude-vps-generator.patch`，部署新副本时须一并保留。

## 使用

```sh
claude-net curl --fail https://api.ipify.org
claude-net bash
claude-vps
```

`claude-vps` 查找已安装的 `claude` 并通过同一个入口启动。没有安装时返回错误，
不会自动下载或恢复先前清除的数据。直接在普通终端运行原始 `claude` 不属于此隔离范围。

命令保留工作目录，以配置的普通用户运行。启动器清除代理环境变量，使用专用 DNS，
不继承普通 Shell 的自定义环境；应用凭据可由应用自己的配置文件加载。
会话退出时，其 systemd 单元内剩余子进程一并停止。
登录流程中单独打开的外部浏览器不自动进入 namespace；需要相同出口时，应给该浏览器
另行配置同一 VPS 路径。

严格入口禁止提权、切换 namespace、访问宿主机 Unix socket，以及跨进程调试等
常见绕过途径。依赖宿主机 Docker/Nix daemon/SSH agent 的工具需要单独设计受限接入，
不能直接开放宿主机管理 socket。普通文件访问权限仍属于原用户，不能将本模块视为
对恶意代码的完整文件系统沙盒。

## 启用其他机器

确认该机器访问 Router 时使用登记的稳定 LAN 地址，然后在其配置中设置：

```nix
services.claude-vps.enable = true;
```

模块会在启动时核对到 Router 的直连路由和本机 LAN 地址。不符合时启动失败，
不允许借用其他网关。使用 NetworkManager 的机器不需要建立 Wi-Fi 网桥。
新增主机时先登记 `fleet.nix` 并部署 Router 回程路由，再启用客户端。

## 验证和运维

- `systemctl status claude-vps-netns claude-vps-dns` 检查本机服务。
- `ip rule`、`ip route show table 20300` 检查固定路由和不可达后备路由。
- `claude-net curl ...` 的出口应与专用 VPS listener 的出口一致。
- 专用代理入口故障时，请求应失败；直接转发保护必须独立验证。
- IPv6、外部 UDP、宿主机服务和提权尝试应被阻止。

Router 配置切换使用容器内重载，保留 PPPoE 连接。变更容器边界（veth、挂载、
capabilities）时仍需显式重启容器。

禁用客户端使用 `services.claude-vps.enable = false` 后重新切换系统。
停止 namespace 服务会先断开 veth，随后移除本机路由及规则；Router 的保护规则
可以继续保留。不要仅删除防火墙规则而保留运行中的会话。

## 首次部署的依赖版本

2026-10-17 部署时，仓库现有 `flake.lock` 的 USTC Nixpkgs tarball 已无法按锁定
哈希下载。本次没有更新锁文件或升级其他软件，使用当前运行系统保留的完整锁文件，
配合本次修改后的源码构建。构建快照保留在
`/home/rivers/.local/state/claude-vps-setup/20261017-092331/build-source`。
该快照的 toplevel 与已激活系统一致。后续常规仓库构建前需单独解决原有输入哈希失配，
不要把依赖更新混入网络隔离变更。
