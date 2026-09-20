# niri 试用

保留 KDE，登录界面选择 **Niri**。外观采用每日风景壁纸、随壁纸生成的深色配色和毛玻璃：窗口／启动器 8px 小圆角，工作区按钮 4px。顶栏与通知侧栏外边距全部为零；通知面板贴右边、紧接顶栏，宽 320px，高度随内容收缩，贴边外框仅左下角使用 10px 圆角。勿扰与清空通知合并为一行。状态栏不透明度至少 60%，启动器至少 65%，通知面板至少 48%，弹出卡片至少 58%；遇到明亮壁纸自动提高至最高 82%，面板内卡片保持 30%；终端沿用原有 76% 背景不透明度，文字保持清晰。niri 对终端、启动器、状态栏与通知背景启用模糊，使用默认 xray 方式，避免对底下窗口反复重算。通知中心关闭全屏 layer surface，以限定模糊范围。

## 常用操作

| 按键 | 操作 |
|---|---|
| Alt+Space | 启动器 |
| Win+Space | Fcitx5 输入法切换（保留现有配置） |
| Win+L | 锁屏 |
| Win+Enter | Kitty 终端 |
| Win+方向键 | 切换窗口／列 |
| Win+Shift+方向键 | 移动窗口／列 |
| Win+PageUp / PageDown | 切换工作区 |
| Win+Ctrl+上 / 下 | 切换到上／下屏 |
| Win+Ctrl+Shift+上 / 下 | 把窗口移到上／下屏 |
| Win+W | 桌面总览 |
| Win+R | 切换列宽 |
| Win+F / Win+Shift+F | 最大化列／全屏 |
| Win+Shift+V | 浮动／平铺 |
| Alt+F4 | 关闭窗口 |
| PrintScreen | 区域截图 |
| Win+Shift+E | 注销（有确认） |
| Win+Shift+/ | 快捷键帮助 |

Win+C/V 和 Caps/Esc 由现有 xremap 规则处理，按当前桌面选择 KDE 或 niri 后端。

## 会话与显示

- DP-3 在上，DP-1 在下；两屏 3840×2160@120Hz，缩放 1.5。
- 10 分钟空闲锁屏，15 分钟熄屏；睡眠前锁屏。
- niri-desktop.target 随 niri.service 结束，管理状态栏、壁纸、输入法、通知、认证代理和空闲处理。
- X11 应用由 xwayland-satellite 提供；共享屏幕使用 GNOME portal，文件选择器使用 GTK portal。
- 省电／高刷、熄屏与注销入口会按当前桌面选择实现。KDE 分支沿用原设置。

## 实际会话验收

构建和嵌套预览不能代替以下独立会话检查：

1. Alt+Space 启动 Kitty、浏览器、VS Code、QQ 和微信。
2. Win+Space 切换中文，检查候选框位置、跨窗口输入及 Win+C/V。
3. Win+L 锁屏并解锁，然后检查睡眠唤醒。
4. QQ／微信的托盘、通知、截图、图片粘贴和文件拖放。
5. 浏览器屏幕共享、双屏缩放、刷新率与跨屏弹窗。

## 返回 KDE

Win+Shift+E 注销，在登录界面选择 Plasma (Wayland)。不必回滚系统。

完整移除：删除 configuration.nix 与 home.nix 中两个 niri 模块导入，移除 system/display-power.nix 新增的 niri 分支，再 rebuild switch。尚未提交时只回退这些改动，保留其他工作。

## 配置入口

- `system/niri.nix`：登录会话、portal 与 PAM。
- `home/niri.nix`：组件、外观和 xremap 会话选择。
- `home/niri/config.kdl`：显示器、窗口规则和快捷键。
- `home/niri/wallpaper.svg`：首次启动或尚无缓存时的备用壁纸，构建时转换为 PNG。
- `home/niri/daily-theme.py`：每日下载、配色生成、缓存和热加载。

参考：[niri 配置](https://niri-wm.github.io/niri/Configuration:-Introduction.html)、[Xwayland](https://niri-wm.github.io/niri/Xwayland.html)、[屏幕共享](https://niri-wm.github.io/niri/Screencasting.html)。

## 本次验证（2026-09-05）

完整系统已构建并 switch；niri validate 与 systemd 用户服务依赖验证通过。KDE 显示管理器、Home Manager 与 xremap 保持运行，niri 专属组件在 KDE 下未启动。嵌套 niri 中实际检查了壁纸、Waybar 与 Fuzzel 的渲染；临时预览已退出。独立会话的输入、解锁和应用兼容性仍待实测。

同时移除了 xremap-device-watch.path 对 graphical-session.target 的 After 依赖，消除其通过 paths.target/basic.target 与 niri.service 形成的启动环；WantedBy 和 PartOf 保留。

鼠标：对齐 KDE 的 MCHOSE A7 设置，niri `mouse.accel-profile = flat`、`accel-speed = -0.2`；触控板设置独立保留。

通知焦点：关闭 SwayNC 的 keyboard-shortcuts，使通知中心使用 KeyboardMode.NONE；普通弹窗及打开的通知中心均不独占键盘。面板用鼠标操作，通过铃铛开关；面板内键盘导航／Escape 关闭不再启用。

通知样式：入口使用小铃铛，去除竖分隔线；卡片 10px 圆角，贴边面板仅左下角圆润，外侧 margin 仍为零。


## 每日壁纸与配色

每天本地时间 09:00 从 Alpha Coders 的 Landscape、WallpaperCG 的 Dolomite Mountains / Tropical / Anime Scenery 公开页面随机选图，无需 API Key；混合实景与插画，下载后验证至少 3840×2160、接近 16:9。DP-1（下屏）和 DP-3（上屏）各一张且不重复；进入 niri 时补选当天壁纸，同一天自动触发不会重复更换。优先避开最近 28 张，候选不足时复用较早图片，但不选当前双屏图片。单个来源失败仍尝试其余来源；无法完成双屏选图则保留整组旧图，下次登录或手动操作时可以重试。下载缓存继续保留。定时器仅跟随 niri 会话运行。

Matugen 从 DP-1 下屏壁纸提取统一配色，更新窗口边框、状态栏、启动器和锁屏；Mako 保持奶白玻璃。锁屏也使用各屏自己的壁纸。底色仍采用深色方案，背景透明度随图片亮度调整；应用自身的明暗主题不在此范围内。

- Alt+Space 输入 **bz**、**bizhi** 或 **wallpaper** 定位“换一张壁纸”（Rofi 支持中文输入，关键词也可直接检索），或运行 `niri-daily next`：立即给两屏重新随机。
- `niri-daily status`：查看当前来源、日期和调色板。
- `niri-daily update`：检查并补选当天壁纸。
- 状态位于 `~/.local/state/niri-daily/`，保留最近 28 张图片和最近两套生成配置；`current` 原子切换，生成前先验证 niri 配置。

2026-09-05 已构建并 switch，实际在线下载和桌面热加载成功，相关组件保持 active，下一次定时触发为 2026-09-06 09:00 +08。隔离状态目录验证了同日跳过网络，以及断网失败后保留旧配置；日历触发本身尚未等待到次日实测。


## Rofi 启动器

Alt+Space 使用 Rofi，顶栏不再放启动器入口。固定上游提交 `a8569d524cf999c14134b00e7870f9ce88f210de` 及源哈希；Nixpkgs 的 Rofi 2.0.0 尚无 Wayland text-input-v3 支持。此固定版本已在当前 niri/Fcitx5 会话由用户确认中文输入可用。

外观：620px 宽、9 行、8px 外圆角、4px 选中项圆角、22px 图标；透明背景由 niri 的 rofi layer rule 模糊。颜色与背景不透明度通过每日主题生成器更新。关闭 global-kb，避免禁止桌面快捷键。Fuzzel 保留为备用，可在终端运行 `fuzzel`。

Rofi 关闭 `click-to-exit`，避免为接收外部点击创建全屏透明层、使 niri 的 xray 模糊遮住其他窗口；用 Esc 关闭。主题先清空默认样式，防止继承浅色列表行。

Rofi 单独设置 `background-effect { blur true; xray false; }`，模糊弹窗下方的实际窗口，避免透过应用直接显示壁纸形成“挖洞”效果。其他组件仍沿用原设置。

通知面板和弹出通知均使用非 xray 模糊，宽度统一为 320px，图标缩到 32px，动画缩短到 120ms；面板仍随内容收缩。Rofi 底色改用较浅的 surface_container_high，透明度范围为 68–78%。

通知中心样式覆盖默认分组折叠与焦点背景，清除方形底框和不透明黑卡片；字体改用 Noto Sans CJK SC，正文 13px、标题 14px，时间 11px，卡片仅保留一层半透明背景。


## Mako 奶白玻璃通知

通知服务改用 Mako：320px 单层卡片、10px 圆角、72% 奶白底、深灰文字，模糊下方窗口。固定奶白色避免每日深色调色板改变这一外观。普通通知 6 秒消失，紧急通知保留，内存历史保留 50 条，服务重启后不保留。

铃铛左键打开 Rofi 通知历史列表，可检索，回车阅读全文；右键切换勿扰。它不再打开 SwayNC 侧栏。旧 SwayNC 样式暂留为回退参考，但服务已替换。奶白通知不沿用旧的分组卡片嵌套。

状态栏移除最左侧启动器，Rime 英文托盘图标用不依赖字体的矢量 A 覆盖。

双屏升级保留旧的 `current/wallpaper` 作为主屏兼容入口；新增 `wallpaper-DP-1` 与 `wallpaper-DP-3`。`init` 会保留各屏选图，只重新生成样式。风景标签是筛选依据，不能保证每张完全无人像。

## 顶栏声音卡片

左键顶栏音量打开浅灰白磨砂小卡片，包含输出音量、静音、播放设备选择和默认麦克风音量／静音。选择播放设备会设置默认输出，并迁移已有播放流。右键仍打开 pwvucontrol 完整设置。

卡片按需启动，关闭后进程退出；点击卡片外任意位置、再次点击音量、卡片右上角 ×，或卡片获得焦点后按 Esc 关闭。使用 GTK layer-shell 的 on-demand 键盘模式；每屏使用独立的透明点击层来接收外部点击并关闭卡片，首次点击用于收起；点击层不应用模糊、不挤占平铺窗口。卡片试用 macOS 风格透明玻璃：66% 烟灰底色配白字，叠加轻微顶部高光、18px 圆角、细亮边及半透明选中项，niri 模糊其下方窗口。此效果没有 macOS 的折射实现。设备列表和音量在显示时自动刷新。

顶栏移除最右侧电源形状的锁屏入口；Win+L 锁屏保留。


## Noctalia 正式接入

Alt+Space 改为 Noctalia 应用启动器，niri-bar.service 改为运行 Noctalia 4.7.7，替代 Waybar。固定当前 Nixpkgs 包版本，启动器列表和网格应用名使用 Medium 字重。面板使用 42% 浅色玻璃、炭灰正文、中灰说明，顶栏高度 default（31px）；保留原每日壁纸、Mako、Fcitx5、锁屏和 idle 服务。

设置和调色板预设存放在 home/niri/noctalia/，激活时写入可编辑的 ~/.config/noctalia/。只有仓库预设发生变化时才重新覆盖；普通 rebuild 保留 Noctalia 界面中的调整。Rofi 暂时保留供通知历史脚本使用，不再绑定应用启动快捷键。旧 Waybar 和音量卡片文件留作回退参考。

## 总览背景与 Noctalia 输入法图标

总览缩放设为 0.42，工作区使用柔和阴影。Noctalia 的 Overview 渲染器独立于其壁纸管理开关运行，读取每日壁纸的 `wallpaper-DP-1` / `wallpaper-DP-3`；niri 将 `noctalia-overview-*` 放入 backdrop，保留 swaybg 在工作区内显示清晰壁纸。模糊强度 0.85、色调遮罩 0.3。每日换图原有的 Noctalia 服务重启会刷新背景图片。

Fcitx 英文状态的 `input-keyboard-symbolic` / `fcitx_rime_latin` 在 Noctalia 托盘中直接使用本地矢量 A，避免 Qt 图标查找失败显示紫黑占位块；中文图标仍由 Fcitx 提供。已重建应用并截图验证总览、英文 A 和中文状态恢复，niri 配置校验通过。

启用 `focus-follows-mouse max-scroll-amount="0%"`：鼠标移入屏幕或窗口即转移焦点，Win+Page Up/Down 因而切换鼠标所在屏幕的工作区，无需先点击。该设置也影响普通窗口的键盘焦点，但不会为聚焦部分可见列而横向滚动画面。

Win+Q 正常请求关闭当前窗口，与 Alt+F4 一致；它不保证退出仍有其他窗口或托盘驻留的整个应用。Win+Shift+Q 直接 SIGKILL 当前窗口所属 PID，同一进程的其他窗口也会关闭，未保存内容无法挽回。强退助手只操作当前用户进程，使用 pidfd 避免 PID 重用，并在发送信号前核对窗口焦点；无窗口、无 PID 或焦点已变时不执行。Win+Shift+E 仍用于退出 niri 会话。

### 统一锁屏

锁屏统一使用 swaylock：Win+L、空闲锁屏和休眠前锁屏由现有 niri/swayidle 配置处理。Noctalia 的 `general.lockOnSuspend` 关闭，会话菜单的 lock 命令设为 `swaylock -f`；包覆盖将内置 LockScreen 组件替换为 swaylock 转接入口，覆盖启动器等直接激活组件的路径，避免重新出现另一套锁屏 UI。Noctalia 的 idle 管理保持关闭。
