# UU Remote 协议证据清单（主控端视角）

本文档记录 HarmonyOS 主控客户端所依赖的协议事实，标注每一条的证据来源。
**已验证** = 来自 uu-remote-linux 被控端的实测实现（与官方客户端联调验证）；
**未验证** = 需要抓取官方主控端流量后确认。

## 1. REST 云端 API（api.nrd.nie.163.com）

### 已验证

| 项 | 内容 | 证据 |
|---|---|---|
| 请求签名 | HMAC-SHA256(sign_key, METHOD + path + "k=v&…" 排序后的 x-param-*（不含 x-param-sign） + body)，hex 小写 | src/auth.rs `sign_request` |
| 签名密钥 | `alWiSzXZTLu3WfFnw13uBru3`（官方 PC 客户端内置，全用户相同） | src/auth.rs `DEFAULT_SIGN_KEY` |
| 公共参数 | x-param-plat=1, vn=4.42.0.2770, vc=2770, pkgn=com.netease.gameviewer, chn=gwqd, lang=zh-CN, cnt=CN, ts=秒级时间戳 | src/auth.rs `build_headers` |
| 身份参数 | x-param-client-id / device-id / system-id / user-id（登录前缺省不发） | 同上 |
| 鉴权头 | `Authorization: Bearer <token>`；Cookie `nrd_access_token=<token>; nrd_csrf_access_token=<csrf>`；`X-CSRF-TOKEN: <csrf>` | 同上 |
| token 失效 | API code 1120 (HTTP 422) → 需重新登录 | src/auth.rs `TOKEN_INVALID` |
| 设备注册 | POST `/api/v1/device/windows/init`（硬件摘要）→ device_id | src/login.rs |
| QR 登录 | POST `/api/v1/qrcode/gen/login` → qrcode_jump_url + ticket；POST `/api/v1/qrcode/login/status`（长轮询，1 等待/2 已扫/3,4 确认）；POST `/api/v1/login/by_qrcode` → user_id + token（JWT 内含 csrf claim） | src/login.rs `flow` |
| QR 过期 | code 1190 (HTTP 400)，重新生成即可 | 同上 |
| 建房 | POST `/api/v1/room/create` → {signaling_server, token} | src/auth.rs `create_room` |

### 第三方源码证据（OpenUUYC/farwing，待联调确认）

以下端点来自 OpenUUYC 逆向实现（详见 [CONTROLLER-CHAIN.md](CONTROLLER-CHAIN.md) 与源码位置索引），
已在 harmonyos-viewer 中实现，但**尚未与真实云服务联调**：

| 项 | 内容 | 证据 |
|---|---|---|
| 设备列表 | GET `/api/v1/device/list` → {current_device, my_binded_devices[]}（DeviceInfo: device_id/alias/status("CONNECTED")/platform/controllable/version_name） | farwing api/mod.rs:148,905 |
| 入房 | POST `/api/v1/room/join/by_device/{device_id}` body {force_join} → RoomSession{token, signaling_list[], signaling_server} | farwing api/mod.rs:977 |
| control 握手 | 入房后 emit `control` 二进制事件（ConnectOptions 附件）→ ACK 携带 client_id/ice_id/iceServers/force_relay | farwing negotiation.rs:41, signal/mod.rs:615 |
| 短信登录 | POST `/api/v1/security/mobile/code` {country_code, mobile, type:"login"} + POST `/api/v1/login/by_mobile` | farwing api/mod.rs:847,863 |
| 信令请求头 | X-NRD-AUTH + X-NRD-CONTROLLING（首次 "0"，WebRTC Connected 后才 "1"）+ streamer_version: V4.7.3 + streamer_flag | farwing negotiation.rs:245 |
| 释放 | emit `leave` → Socket.IO "41" → WS Close(1000) | farwing transport.rs:592 |

### 仍未验证

| 项 | 说明 |
|---|---|
| gzip_sdp | farwing 发 gzip SDP 附件，本项目已同样实现（Gzip.ets + 二进制附件）；与官方被控端的实际互通待实测 | 连接官方被控端时验证 |

### 注册策略（Windows 伪装）

不存在官方鸿蒙客户端（官方只有 Win/macOS/Android/iOS/TV）。本项目沿用被控端的
核心策略：**伪装 Windows 设备**注册。`/api/v1/device/windows/init` + platform=1 +
真实鸿蒙设备信息（productModel/osFullName/屏幕尺寸）——被控端 src/login.rs 已验证
该端点接受非 Windows 硬件摘要（发送的是真实 Linux 值）。主控端注册为
controllable=false 的 Windows 设备，永不作为被控端。

> 注意区分：上表"已验证"一节中的端点（device/windows/init、room/create 等）都是**被控端流程**
> 的验证结果。主控端的登录/注册/入房契约在取证完成前全部未验证。

## 2. 信令（Engine.IO v4 / Socket.IO）

### 已验证

| 项 | 内容 | 证据 |
|---|---|---|
| 传输 | WebSocket `<server>/socket.io/?transport=websocket&EIO=4`，头 `X-NRD-AUTH: <room token>` | src/signaling.rs |
| 握手 | 收 `0{...}` → 发 `40`；收 `2` → 发 `3`（心跳） | 同上 |
| soac 事件 | `42["soac", {...}]`；type=offer/answer/candidate；sdp 或 gzip_sdp(base64)；ice_id/client_id/app_control_id 回传 | src/signaling.rs `SoacMessage` |
| 房间事件 | `be-controlled`（二进制附件 = ConnectOptions protobuf：field 1 capture_type）、`released`、`left`/`leave`、`bmsg_push` | src/signaling.rs |
| capture_type | 1 桌面，5 文件传输，8 终端，9 端口映射（桌面连接 capture_type ≤ 2 才发视频） | AGENTS.md §7 |
| ICE 配置 | be-controlled 头部 iceServers[]（stun/turn + 用户名/凭据）、force_relay | src/session_ice.rs |

### 未验证 / 待实测

| 项 | 说明 |
|---|---|
| 主控端入房方式 | 官方主控端连上信令服务器后如何声明目标（是否 emit join / 直接 soac）。本项目当前直接 emit `soac` offer，需实测 |
| be-controlled 触发 | 由云端推送（REST 发起控制时触发）还是主控端 emit；二进制 ConnectOptions 附件的完整字段 |
| token 查询参数 | 浏览器 WebSocket 无法设自定义头；本项目信令在 ArkTS 层（可设头），不受影响 |

## 3. WebRTC 媒体与数据通道

### 平台能力边界（ArkWeb）

WebView-CG BCD 自动化测试数据确认 ArkWeb 的 **WebRTC API 存在**
（RTCPeerConnection/RTCDataChannel 的 API 检测通过）。这只证明 API 可用；
**不证明**目标商业 HarmonyOS 设备上 H.264/H.265/Opus 的实际解码、硬解路径与延迟满足
远程桌面要求。真机实测是唯一判据，取证完成后的验收清单见 §5。

### 已验证（协议层，来自被控端）

| 项 | 内容 | 证据 |
|---|---|---|
| 角色分配 | **主控端是 offerer**，被控端应答 | src/main.rs soac offer 处理 |
| 视频 | H.264 / H.265（被控端选择，双方支持时 H.265）；RTP | AGENTS.md §7 |
| 音频 | 被控端在主控端的 Opus m-line 上发送桌面声音；主控端始终提供 Opus m-line | src/webrtc.rs |
| 数据通道 | CONTROL_DATA_CHANNEL（protobuf + JSON 输入）、TEXT_DATA_CHANNEL（剪贴板）、FILE_DATA_CHANNEL（文件/端口映射）、BINARY_DATA_CHANNEL（终端） | src/webrtc.rs |
| SCTP 消息上限 | 被控端应答 SDP 加 `a=max-message-size:262144`；主控端按 64KB 假设 | AGENTS.md §7 |

### 待实测

| 项 | 说明 |
|---|---|
| 通道创建方向 | 本项目由主控端（offerer）createDataChannel 创建全部四条通道；官方主控端的通道创建顺序/方向需实测（被控端 ondatachannel 按标签挂接，两种方向都能工作，但 SDP 中 sctp 声明需匹配） |
| H.265 协商 | ArkWeb (Chromium) 对 H.265 RTP 的解码支持取决于设备（硬件解码器）；失败时需强制 H.264（被控端尊重 m-line 绑定顺序） |

## 4. CONTROL 通道协议

### 已验证

| 项 | 内容 | 证据 |
|---|---|---|
| 信封 | protobuf `Message {1 seq, 2 timestamp, <which> payload}` | src/protocol.rs |
| Echo | 主控端发 SimpleAction action=0（带 FeatureFlag）→ 被控端应答 action=1，args `{"seq":<请求seq>}`，带被控端自己的 FeatureFlag；主控端只能使用被控端声明的特性版本 | AGENTS.md §7 |
| FeatureFlag（host 实现） | 1 ff_capture_setting=4, 2 ff_simple_action=2, 3 ff_system_metrics=2, 6 ff_file_transfer_ftp=2, 8 ff_clipboard=3。**主控端 echo 只声明自己已实现的功能**（当前仅 ff_capture_setting=4） | src/control_protocol.rs |
| 输入 JSON | kbd_press/kbd_release/kbd_click(key=Windows VK)、mouse_press/mouse_release/mouse_click(**button 为位掩码：1=左 2=右 4=中**)、mouse_move_absolute(abs_x,abs_y 归一化 0..1)、mouse_move_relative、mouse_scroll(delta_x,delta_y) | src/control_protocol.rs、src/input_mapping.rs |
| 键盘心跳 | `{"heartbeat":"kbd_heartbeat"}`（长按键保活） | 同上 |
| 初始化序列 | 被控端在 CONTROL 打开后发：ScreenSources(7)、CaptureChange(8)、SystemMetrics(13)、remote_download_path(26)、CodecNegotiation(18) | src/webrtc.rs |
| 画质 RPC | Message 21 RpcRequest case 2 CaptureSettingRequest：field 1 = fps 选项索引(1=30,2=60,3=90)，field 18 = fpsCount；field 2 质量：1 流畅 2 高清 3 超清 4 原画 5 自动 6 自定义 | AGENTS.md §7 |
| 屏幕几何 | ScreenSources field 1 Screen{4 current_resolution WinRect{3 width, 4 height}}（用于输入坐标换算） | src/initialization.rs |

## 5. 逆向取证计划（补齐未验证项）

1. **环境**：官方 Mac 主控端（UURemote）+ mitmproxy（HTTPS 解密需安装根证书）；同一账号下运行 uu-remote-linux 被控端。
2. **抓 REST**：登录 → 设备列表 → 点击连接 → 断开，记录全部 api.nrd.nie.163.com 请求/响应（注意脱敏 token）。
3. **抓信令**：mitmproxy 的 WebSocket 面板记录 socket.io 帧（事件名、soac 载荷结构、be-controlled 触发时机）。
4. **落地**：把确认的端点写进 `cloud/ViewerCloudApi.ets` 的实现类，删除 UnverifiedCloudApi 的报错占位。
5. **验证闭环**：真机完成 授权 → 连接 Linux 被控端 → H.264 视频 → 触控移动/点击 → 断开释放。

## 6. 本地联调（无云端）

在无网易账号的前提下验证会话引擎（这是手动会话入口的唯一用途）：
- 本地 mock：`node` 起一个 socket.io 服务端，转发 soac，即可验证 WebRTC + CONTROL 全链路。
- 被控端可指向 mock 信令（需临时改造，或直接用两个 mock 端点对连）。
- **不要**从被控端日志导出房间令牌填入手动会话：host 日志只输出非敏感诊断，
  room token 是凭据，真实令牌必须来自（未验证的）主控端会话 API。
