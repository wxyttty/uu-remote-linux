# uu-remote-viewer (HarmonyOS)

网易 UU 远程的**非官方 HarmonyOS NEXT 主控客户端**，配套 [uu-remote-linux](../README.md) 被控端使用。与网易无关，GPL-3.0。

> **状态：开发基础（未签名 HAP，编译通过）。**
> 已新增第三方源码研究（OpenUUYC，docs/CONTROLLER-CHAIN.md）与部分主控握手实现
> （入房/control 握手/soac gzip/关闭序列，经 mock 传输状态机测试）；**握手正确性、
> 身份入口和端到端连接均未完成验证**：尚未与真实云服务联调，鸿蒙端设备注册未验证
> （登录流程因此禁用）。

## 架构

```
┌────────────────────────── ArkTS 壳（原生层）──────────────────────────┐
│  登录页 (QR)      设备列表 (API 未验证)      会话页                     │
│  RestClient ──── HMAC-SHA256 签名            SignalingClient            │
│  CredentialStore (Preferences, 应用沙箱)     (Engine.IO/Socket.IO WS,  │
│                                               X-NRD-AUTH 头只能原生设置) │
└──────────────────────────────┬───────────────────────────────────────┘
                    JS 桥 (registerJavaScriptProxy / runJavaScript)
                    只传房间坐标 + 会话标识 + 云端 ICE 配置；账号凭据不进 Web 层
┌──────────────────────────────┴───────────────────────────────────────┐
│  Web 会话引擎 (ArkWeb / Chromium, rawfile/remote/)                    │
│  RTCPeerConnection (offerer) ── recvonly 视频 + 音频 m-line           │
│  CONTROL_DATA_CHANNEL ── protobuf 信封 + JSON 输入事件                │
│  触摸→鼠标（位掩码 1/2/4，object-fit:contain 坐标归一化）、双指滚动    │
└──────────────────────────────────────────────────────────────────────┘
```

设计依据与边界：
- **ArkWeb 的 WebRTC API 检测通过**（WebView-CG BCD 自动化数据：RTCPeerConnection/RTCDataChannel API 存在）。
  这只证明 API 可用，**不证明**目标商业 HarmonyOS 设备上 H.264/Opus 实连、硬解与延迟满足要求——需真机实测。
- **信令 WS 在原生层**：浏览器 WebSocket 无法设置 `X-NRD-AUTH` 头（被控端验证的鉴权方式）。
- **会话状态集中在 Web 层**（PeerConnection/通道/输入），原生层只持有信令传输与凭据。

## 模块

| 路径 | 角色 |
|---|---|
| `entry/src/main/ets/auth/RestClient.ets` | 签名 REST 客户端（移植 src/auth.rs；createRoom 是 host 端点，仅参考） |
| `entry/src/main/ets/auth/QrLogin.ets` | QR 登录流（端点已验证；**设备注册已禁用**待云接入取证） |
| `entry/src/main/ets/auth/Credentials.ets` | 凭据持久化（Preferences 沙箱） |
| `entry/src/main/ets/cloud/ViewerCloudApi.ets` | 设备列表/发起控制接口 —— **未验证占位** |
| `entry/src/main/ets/session/SignalingClient.ets` | Engine.IO v4/Socket.IO 客户端（移植 src/signaling.rs） |
| `entry/src/main/ets/protocol/Wire.ets` | protobuf wire 编解码（移植 src/protocol.rs） |
| `entry/src/main/ets/protocol/ControlMessages.ets` | echo 请求/输入事件/画质 RPC 编码 |
| `entry/src/main/resources/rawfile/remote/` | Web 会话引擎（WebRTC + CONTROL + 触控） |
| `tools/wire_test.mjs` | 协议一致性测试（生产编码器，host 测试向量） |
| `tools/connect_options_test.mjs` | ConnectOptions 生产编码器字段映射测试 |
| `tools/signaling_test.mjs` | 信令状态机测试（生产代码 + mock 传输） |
| `tools/gzip_test.mjs` | gzip 编码器与 zlib 往返验证 |
| `docs/CONTROLLER-CHAIN.md` | 主控连接链路完整记录（ID 生命周期 + farwing 源码索引） |
| `docs/PROTOCOL.md` | 协议证据清单（已验证/未验证边界）+ 逆向取证计划 |

## 构建与测试

DevEco Studio 6.1（HarmonyOS SDK API 24）验证：

```sh
cd harmonyos-viewer
export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
hvigorw --mode module -p module=entry@default assembleHap --no-daemon
# 产物: entry/build/default/outputs/default/entry-default-unsigned.hap（装机需 DevEco 签名）

node tools/wire_test.mjs   # 协议一致性测试（生产编码器 + host 测试向量）
```

## 当前能力与限制（诚实清单）

**已实现且经静态验证：**
- HMAC 签名 REST、Engine.IO/Socket.IO 信令客户端（X-NRD-AUTH）
- WebRTC offerer：recvonly 视频+音频 m-line、四条数据通道（CONTROL/TEXT/FILE/BINARY）
- CONTROL 协议：echo（只声明已实现的 ff_capture_setting=4）、画质/帧率 RPC
- 输入：触摸→鼠标（**位掩码** 1=左 2=右 4=中，对照 src/input_mapping.rs）、拖动按住、长按右键、双指滚动、硬件键盘→Windows VK、触摸取消/失焦时释放全部按键
- protobuf codec：25 项断言用 host 测试向量在生产编码器上全部通过（tools/wire_test.mjs）

**已实现但未经真机验证：**
- 视频渲染（ArkWeb 的 H.264/H.265 实际解码能力取决于设备，未测）
- 音频（m-line 已协商，首次触摸解除静音；未验证播放）
- 触控延迟、键盘心跳

**已按第三方证据实现（mock 传输测试通过，待真实联调）：**
- 设备列表（GET device/list）、入房（POST room/join/by_device/{id}）
- control 二进制事件握手（ConnectOptions 附件 + ACK 成功/拒绝/超时/迟到四条路径）
- soac offer（gzip 二进制附件 + {client_id, data{…}} 信封）、candidate（文本事件信封）
- 串行发送队列（header/附件同一任务、心跳不插队、close 等待队列排空后再 leave/41/close）
- ConnectOptions 编码器（生产代码转译测试：tools/connect_options_test.mjs）
- 信令状态机（tools/signaling_test.mjs，驱动生产代码 + 异步完成控制 mock）
- gzip 编码器（stored-block，与 zlib 往返验证：tools/gzip_test.mjs）
- FeatureFlag 单一来源（protocol/FeatureFlag.ets，仅声明已实现的 ff_capture_setting=4）
- 音频轨道路径（本地接收 MediaStream 显式挂接音/视频轨，清理时停止全部轨）

**注册策略（Windows 伪装，与被控端一致）：**
- `/api/v1/device/windows/init`，platform=1，controllable=false（主控永不作为被控端）
- 硬件摘要用真实鸿蒙值（productModel/osFullName/屏幕尺寸）——被控端同样发送真实
  Linux 硬件通过该端点，云端接受（src/login.rs 已验证）

**策略值（非实测，待真机核对后调整）：**
- 解码能力声明：H264 1920x1080@60、4:2:0、8bit、codec_impl=37（farwing 软件路径上限）
- 本地显示几何：1920x1080@60（farwing fallback）

**未验证（待真机联调）：**
- 真实云服务的完整链路（注册 → 登录 → 连接 → 视频/触控）
- ArkWeb H.264 解码、触控延迟、音频播放
- 剪贴板、文件传输、终端、端口映射（通道已建立，业务协议未移植）
- 软键盘 IME 组合文本注入（只翻译物理键事件）
- 真机端到端（需签名 + 云端取证完成后进行）

**已知待修项（编译/静态测试不覆盖）：**
- `registerJavaScriptProxy` 的 onControllerAttached 注册方式需真机验证（SDK 文档生命周期，未实测）
- 触控/键盘/会话清理路径（releaseAllInput 等）需真机验证
- ArkWeb H.264/H.265 实际解码能力未知（API 检测通过 ≠ 设备实测）

## 隐私红线（与被控端一致）

- 账号 token / 房间 token / TURN 凭据：不进日志、不进 URL
- 房间令牌与会话标识会进入 Web 层（会话必需），但仅限本地 rawfile 页面；**账号凭据留在原生层**
- 凭据存储在应用沙箱内的 Preferences（受 HarmonyOS 沙箱隔离保护，无 POSIX 权限位可设置）
- QR 内容是登录凭据：只在屏幕上呈现给机主
- 手动会话入口仅用于本地 mock 信令联调；不从 host 日志导出凭据
