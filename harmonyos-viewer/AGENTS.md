# AGENTS.md — harmonyos-viewer (HarmonyOS 主控端)

非官方网易 UU 远程主控客户端（viewer/controller），配套本仓库的 Linux 被控端。
用 DevEco Studio / ArkTS / ArkWeb 开发。**GPL-3.0，与网易无关。**

## 事实边界（必读）

1. **协议证据以被控端 + OpenUUYC 源码为准**：被控端事实来自 `src/`（与官方客户端联调）；
   主控端事实来自 farwing 逆向实现（docs/CONTROLLER-CHAIN.md，待真实联调确认）。
   **不存在官方鸿蒙客户端**——设备注册沿用被控端的 Windows 伪装策略
   （windows/init + platform=1 + 真实设备信息，被控端已验证该端点接受非 Windows 硬件）。
   不得猜测无证据的端点。
2. **隐私红线**：账号 token / 房间 token / TURN 凭据 / QR 内容不进日志、不进 URL、不进 Web 层。
   Web 层（ArkWeb）只接收房间坐标 + 会话标识 + ICE 配置。日志只记尺寸/计数/布尔。
   手动会话入口仅用于本地 mock 联调，文档不得引导用户从 host 日志导出凭据。
3. **架构约束**：信令 WebSocket 必须在 ArkTS 层（浏览器 WebSocket 无法设 X-NRD-AUTH 头）；
   RTCPeerConnection/数据通道/触控输入集中在 Web 层（rawfile/remote/remote.js）。
   会话状态不要分散到两层。JS proxy 在 aboutToAppear 注册一次，onPageEnd 只更新就绪状态，
   不得调用 controller.refresh()（会形成刷新循环销毁会话）。
4. **能力声明纪律**：echo 的 FeatureFlag 只声明已实现的功能（当前仅 ff_capture_setting=4）；
   host 支持的功能不等于 viewer 可以声明。文档中的能力清单区分"已静态验证/已实现未实测/未实现"。
5. **ArkTS 严格模式**：无 any/unknown、无结构化类型、对象字面量必须对应声明的 class/interface、
   回调接口用 `class X implements Iface` 而非内联字面量。负数 int32 的 protobuf 编码用 BigInt。
6. **输入映射**：鼠标按钮是位掩码（1=左 2=右 4=中，见 src/input_mapping.rs `mouse_button_to_x11`），
   不是序数。触摸取消/页面失焦/会话结束必须释放全部按住的键和按钮（`releaseAllInput`）。

## 构建与验证

```sh
export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"   # DevEco 6.1, API 24
cd harmonyos-viewer
node tools/wire_test.mjs              # protobuf codec + CONTROL 编码
node tools/connect_options_test.mjs    # ConnectOptions 生产编码器
node tools/signaling_test.mjs          # 信令状态机（mock 传输）
node tools/gzip_test.mjs               # gzip 编码器
hvigorw --mode module -p module=entry@default assembleHap --no-daemon
# 产物: entry/build/default/outputs/default/entry-default-unsigned.hap
```

- 所有测试直接加载/转译**生产**代码（remote.js 编码段、ConnectOptions.ets、
  SignalingClient.ets、Gzip.ets），不测手写副本。修改任何被测源后必须重跑全部测试。
- 信令状态机纪律：所有发送经串行 Promise 队列（二进制头+附件是同一任务，
  完成回调门控）；close() 停止接受新任务、等待队列排空、再发 leave/"41"、最后关 socket；
  ACK 校验按 farwing 形状（room_info: 非空对象；control: "success"+code==0+非空 id），
  超时/拒绝/迟到 ACK 都有终止清理。
- 能力声明纪律：FeatureFlag 单一来源 protocol/FeatureFlag.ets（仅 ff_capture_setting=4），
  ConnectOptions field 11 与 CONTROL echo 共用；解码上限/显示几何是策略值（标注于
  SignalingClient.ets），真机核对后才能改称实测。
- 装机需 DevEco Studio 自动签名；真机端到端（视频+触控）需云端取证完成后进行。
- 当前可用本地 mock 信令（socket.io 中继）验证 WebRTC + CONTROL 全链路，见 docs/PROTOCOL.md §6。

## 代码地图

| 路径 | 角色 |
|---|---|
| `entry/src/main/ets/auth/` | 签名 REST（RestClient；createRoom 是 host 端点仅参考）、QR 登录（QrLogin；设备注册已禁用）、凭据存储（Credentials） |
| `entry/src/main/ets/cloud/ViewerCloudApi.ets` | 设备列表/发起控制 —— 接口 + 未验证占位（UnverifiedCloudApi 抛错而非猜测） |
| `entry/src/main/ets/session/SignalingClient.ets` | Engine.IO v4/Socket.IO WS（X-NRD-AUTH 头） |
| `entry/src/main/ets/session/SessionParams.ets` | 完整会话契约（房间坐标 + ice_id/app_control_id/client_id + ICE 配置 + force_relay） |
| `entry/src/main/ets/protocol/` | Wire（protobuf 编解码）、ControlMessages（echo/输入/画质 RPC） |
| `entry/src/main/ets/pages/` | Index（登录/设备/手动会话-mock用）、RemotePage（Web 会话 + JS 桥） |
| `entry/src/main/resources/rawfile/remote/` | Web 会话引擎：RTCPeerConnection offerer、CONTROL 协议、触控→鼠标、键盘→VK |
| `docs/PROTOCOL.md` | 已验证/未验证协议清单 + 逆向取证计划 |

## 未实现（通道已建立，协议未移植）

剪贴板（TEXT_DATA_CHANNEL）、文件传输（FILE_DATA_CHANNEL）、终端（BINARY_DATA_CHANNEL）、
端口映射（FILE_DATA_CHANNEL Message 27）、软键盘 IME 组合文本注入。移植时以
`src/clipboard*.rs`、`src/file_trans.rs`、`src/terminal.rs`、`src/port_mapping.rs` 为准，
并在 `docs/PROTOCOL.md` 标注证据来源。
