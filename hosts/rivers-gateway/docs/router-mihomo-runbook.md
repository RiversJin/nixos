# Router container mihomo 巡检手册

状态：已实施，按 2026-09-16 巡检结果整理
适用主机：`rivers-gateway`（宿主）、`rivers-router`（NixOS container，systemd-nspawn）

## 1. 架构

```text
rivers-router container (192.168.50.1, 10.222.72.100)
  mihomo.service
    - 运行用户 mihomo，配置 /var/lib/mihomo-router/current/config.yaml
    - external-controller 127.0.0.1:9090，secret 见 mihomo.yaml
    - 与 sing-box.service 互斥（conflicts）
  nginx vhost "mihomo-admin"
    - 监听 192.168.50.1:9090 -> 127.0.0.1:9090
    - allow 192.168.50.2 / .10 / .11，其余 deny
```

发布链路（宿主侧，均为用户 rivers 的 systemd unit）：

```text
sing-box-static-sub.timer (每日 04:00)
  -> ~/projects/sing-box-static-sub 生成 dist/public/{mihomo.yaml, ...}
router-proxy-sync.timer (每 2min)
  -> 校验 manifest + sha256，发布到 ~/.local/share/router-container-source/current
router-mihomo-update.timer (容器内, 每 2min)
  -> router-mihomo-install-publication --restart：mihomo -t 验证后切换 generation 并重启
```

相关 nix 模块：`modules/router-mihomo.nix`、`modules/router-proxy-sync.nix`、`modules/router-health.nix`。

## 2. 巡检流程（在 rivers-gateway 上执行）

宿主访问 API 无需 nginx allowlist（直连容器地址）：

```bash
read -rs -p "Controller secret: " SECRET; echo   # 见 ~/.local/share/router-container-source/current/mihomo.yaml
API=http://192.168.50.1:9090
AUTH="Authorization: Bearer $SECRET"

# 1. 存活与版本
curl -s -H "$AUTH" $API/version

# 2. 关键组当前选择
for g in "VPS" "VPS%20Dialer" "VPS%20Dialer%20Auto" "Proxy"; do
  curl -s -H "$AUTH" "$API/proxies/$g" | jq -c '{type, now}'
done

# 3. VPS 出口链路端到端延迟（穿过当前前置跳板）
curl -s -H "$AUTH" "$API/proxies/VPS/delay?timeout=8000&url=http://www.gstatic.com/generate_204"

# 4. 全部前置候选延迟（56 个，需 ~6s）
curl -s -H "$AUTH" "$API/group/VPS%20Dialer%20Auto/delay?timeout=5000&url=http://www.gstatic.com/generate_204" \
  | jq -r 'to_entries | sort_by(.value) | .[] | "\(.value)\t\(.key)"'

# 5. 连接与流量
curl -s -H "$AUTH" "$API/connections" \
  | jq -c '{n: (.connections | length), up: .uploadTotal, down: .downloadTotal}'
```

容器内 service 状态需要 root（`systemctl -M rivers-router status mihomo` 非 root 不可用）；
用 API 巡检即可覆盖大部分健康信号。

## 3. VPS 前置跳板结构

```text
VPS 节点（出口）: ss 2022-blake3-aes-128-gcm, relay-us1.virvm.com:38745
  dialer-proxy: VPS Dialer          <- 前置跳板选择器
VPS Dialer (select)
  -> VPS Dialer Auto (url-test, 56 候选, tolerance 50ms, lazy)   <- 默认
  -> 香港 / 新加坡 / 日本 / 台湾 / 韩国 / 澳门 区域组 (select)
```

- 前置是机场落地节点，VPS 是出口；链路为 本地 -> 前置 -> VPS -> 目标。
- `lazy: true`：url-test 仅在被使用时测速；`tolerance: 50`：新节点比当前快 >50ms 才切换。
- 手动切换前置（不需要改配置）：

```bash
# 切到香港区域组（组内再自选），或切回 Auto
curl -s -X PUT -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"name":"🇭🇰 香港"}' "$API/proxies/VPS%20Dialer"
```

注意：region 组名含 emoji/空格，需 URL 编码或原样放在 JSON body 里。

## 4. 判断基准（2026-09-16 实测）

- VPS 链路端到端：194–197ms（香港前置 -> 美西 VPS），稳定即正常。
- 香港前置正常水平：35–45ms（ssone lite/pro 香港）；neofeed 香港中转 84–88ms，仅作备选。
- 前置候选存活率：42/56 存活属正常（超时多为远端区域节点）。
- 偶发 280ms 尖刺或单次 Timeout 属瞬时抖动；url-test tolerance 会自愈，无需手动换。
- 需要换前置的信号：当前节点一天内多次 Timeout、或 e2e 持续 >300ms。
