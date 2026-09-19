# rivers-laptop niri 桌面

从 rivers-host 已验证的桌面外观与快捷键迁入，保留笔记本自身的 Nixpkgs 锁定版本、内核、网络、登录方式和合盖电源策略。

- 内屏 eDP-1：1920×1200 @ 60.003 Hz、缩放 1.0。外接显示器自动选模式，不使用台式机 DP-1 / DP-3 的位置和 4K 配置。
- Noctalia 玻璃顶栏、浅色面板、Alt+Space 中文启动器、原生 niri 总览。总览背景读取每日壁纸并模糊，工作区保持清晰。Intel 核显使用两轮窗口背景模糊。
- 顶栏显示电池百分比与充电状态；保留亮度键、麦克风静音键，触控板轻触、自然滚动及打字时禁用触控板。
- Win+W 总览；Win+Page Up/Down 换工作区；Win+Ctrl+方向键上下切屏；Win+Shift+方向键移动窗口；Win+F 最大列、Win+Shift+F 全屏、Win+Shift+V 浮动。
- Win+C/V 复制粘贴，终端自动使用 Ctrl+Shift+C/V；Win+Space 切输入法；CapsLock/Esc 交换。焦点跟随鼠标，不触发横向滚动。
- Win+L 锁屏；Win+Q 正常关闭窗口；Win+Shift+Q 强制结束当前窗口所属进程（同进程其他窗口和未保存内容也会丢失）；Win+Shift+E 退出 niri。
- 每日 09:00 选择 Wallhaven 高排名二次元风景壁纸，启动时补选，失败保留上一张。4K 16:9 图以填充方式适配 16:10 屏，少量裁切两侧。单张图同时用于外接屏，总览和锁屏有默认图回退。运行 `niri-daily next` 或在启动器搜索“换一张壁纸”可立即更换。
- 原有合盖策略保留：电池供电时挂起，接电时锁屏并熄屏。Fcitx 继续由原 fcitx5-daemon.service 单独管理；不启动第二个输入法进程。Mako 通知、壁纸和 Noctalia 由 niri-desktop.target 管理。

配置源在 home/niri.nix、home/niri/、home/xremap.nix。Noctalia 设置预设变动才重新写入可编辑设置；普通 rebuild 保留界面调整。每日壁纸和生成样式位于 ~/.local/state/niri-daily，旧 Bing 图片缓存保留，但旧定时器已由新每日服务替代。

## 验证

已在当前笔记本会话热加载，niri PID 保持 1745，未退出登录。内屏模式与缩放读回正确；总览、启动器及电池托盘已截图检查。UPower、电源授权、Mako、壁纸、Noctalia、Fcitx、xremap、swayidle 均运行，系统和用户 failed units 均为空。亮度用原值写回验证权限，未改变亮度；强退助手用独立测试进程验证。

Wallhaven 在这台机器上使用 curl 下载以避免 Python TLS 连接失败，仍限制下载大小、时间并验证图片。已成功选取当日壁纸并生成样式，下一次定时为 09:00。Noctalia 使用 Breeze 图标主题，避免未找到图标时出现紫黑占位块。UPower 和 brightnessctl 的 udev 规则已声明并应用。物理触控板手势、拔电和合盖动作未做远程触发测试。
