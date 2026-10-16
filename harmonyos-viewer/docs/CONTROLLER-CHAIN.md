# 主控端连接链路（来源：OpenUUYC/farwing 源码证据）

> 证据等级：**第三方源码证据**（OpenUUYC 1.0.2-beta.3，逆向自官方 4.41.2 客户端）。
> 尚未与本项目被控端或官方服务联调；落地实现后需在 PROTOCOL.md §1 中标注"待联调确认"。

## 完整链路与 ID 生命周期

```
设备身份(client_id/system_id 本地生成)
  → 登录(QR 或短信: security/mobile/code + login/by_mobile) → token/user_id
  → device/windows/init(platform:1, controllable) → device_id        [注册一次]
  → GET device/list → {current_device, my_binded_devices[]}          [选目标]
  → POST room/join/by_device/{device_id} {force_join:false} → RoomSession
      {token, signaling_list[], signaling_server, ws_connect_timeout_ms}
  → WS 连接 signaling_list[0] (wss, 头见下) → "40" → room_info(ack_id=1) → ACK
  → emit "control" 二进制事件 (ack_id=2):
      文本帧: 451-2["control",{app_control_id, app_data:{_placeholder,num:0}, streamer_data}]
      二进制帧: 0x04 + ConnectOptions protobuf
      · app_control_id = 本地 UUID v4（主控端自己生成！）
      · streamer_data = JSON 字符串 {control_id, device_capability{...}}
  → ACK(2) → ControlSessionInfo:
      {code, client_id, ice_id, iceServers[{urls,username,credential}], force_relay, ...}
      · client_id / ice_id / ICE 配置全部来自 control ACK，不是 REST 入房响应！
  → soac offer（二进制事件，SDP gzip 附件）:
      451-<no-id>["soac",[{client_id, data:{app_control_id, gzip_sdp:{_placeholder,num:0},
        ice_id, ice_network_type:3, sdp:"", type:"offer"}}]] + 0x04 + gzip(SDP)
  → host 应答 soac answer（sdp 明文）+ candidates 双向交换
  → WebRTC Connected → set_controlling(true)（此后重连才发 X-NRD-CONTROLLING:1）
  → 断开: emit "leave" → "41" → WS Close(1000)
```

## 已确认的 ACK 形状与消息信封（farwing 源码）

| 消息 | 形状 | 源码 |
|---|---|---|
| room_info ACK | `43 1 [args]`，args[0] 必须是**非空对象**（无 "success" 前缀） | signal/mod.rs:259 login_room |
| control ACK | `43 2 ["success", {code, client_id, ice_id, iceServers[], force_relay}]`；code==0 且 client_id/ice_id/iceServers 非空才可用 | signal/mod.rs:615 wait_control_ack |
| soac offer | **二进制事件** `451-["soac",[{client_id, data:{app_control_id, gzip_sdp:{_placeholder,num:0}, ice_id, ice_network_type:3, sdp:"", type:"offer"}}]]` + `0x04 + gzip(SDP)` | signal/mod.rs:332 negotiate |
| soac candidate | **文本事件** `42["soac",{client_id, data:{app_control_id, candidate:{candidate, sdpMid, sdpMLineIndex, usernameFragment}, ice_id, ice_network_type:0, type:"candidate"}}]` | signal/mod.rs:442 send_soac_candidate |
| ConnectOptions field 12 | **CLIENT 版本号**（"4.41.2.2602"），不是 SDK "V4.7.3"（两个独立常量） | api/mod.rs:23, official_version.rs |
| 软件解码上限 | H264 1920x1080, chroma 4:2:0, 8bit, codec_impl=37（streamer 958290） | media/decoder/mod.rs:509 |
| FeatureFlag（ConnectOptions field 11） | read_only_viewer: capture_setting=6, file_transfer_ftp=2, file_transfer_ftp2=2, clipboard=3, qos_stat=1, 其余 0 | stream_control/wire.rs:235 |

## 本项目实现状态（相对上表）

已实现并经 mock 传输测试（tools/signaling_test.mjs，异步完成控制 mock）：入房、
control 握手（ACK 成功/拒绝/超时/迟到四条路径）、soac offer（gzip 二进制附件）、
candidate（文本信封）、串行发送队列（头/附件同任务、心跳不插队）、
leave 关闭序列（等待队列排空后发送）、错误路径资源释放。
**未完成**：真实云服务联调（注册/登录/握手/视频/输入闭环均未验证）。

### soac offer 序列化结构（与 farwing encode_binary_event 核对一致）

```
451-["soac",{"client_id":"…","data":{"app_control_id":"…","gzip_sdp":{"_placeholder":true,"num":0},"ice_id":"…","ice_network_type":3,"sdp":"","type":"offer"}}]
```
外层是 `["soac", payload]`（payload 为单个对象，无额外数组嵌套），
`encode_binary_event("soac", &[payload], None, 1)` → `45{1}-{无 id}{json}`。

## ConnectOptions protobuf（主控→云，control 事件附件）

```
field 1  kind: 1=桌面 5=文件 9=端口映射
field 2  screen_id: -1（跟随远端；非 connect_type！）
field 3  CaptureParams {1 fps档(1=30,2=60,3=90,4=120), 2 quality(1流畅..5自动), 4 resolution_type=3(跟随远端),
         5 local_resolution{1 w,2 h}, 7 chroma(1=420,3=444), 8 bitrate, 9 hdr, 10 auto_quality, 11 fps_count}
field 4  DecoderCapability[] {1 fps上限, 2 codec(1=H264,2=H265), 3 w, 4 h, 5 chroma}
field 6  VirtualMode[] {1 w, 2 h, 3 vsync}（仅桌面连接）
field 8  client_type: 3（desktop controller ABI）
field 9  device_id: 主控端 device_id（字符串）
field 10 connect_type: 1=普通 2=协助
field 11 FeatureFlag {1 capture_setting, 8 clipboard, 3 system_metrics, 6 file_transfer_ftp, ...}
field 12 协议版本字符串
```

## streamer_data（control 事件文本帧内）

```json
{"control_id":"<app_control_id>","device_capability":{"display_info":[...],"video_codec_capability":[...],"ice_id":""}}
```
（OpenUUYC 扩展字段 openuuyc_* 不发送；ice_id 留空——此时还没有 ice_id）

## 信令 WS 请求

```
wss://<endpoint>/socket.io/?EIO=4&transport=websocket&t=<ms 时间戳>
X-NRD-AUTH: <room token>
X-NRD-CONTROLLING: 0            （首次）
streamer_version: V4.7.3
streamer_flag: {"sdp_flags":{"gzip_sdp":true}}
```
端点选择：RoomSession.signaling_list 优先，空则 signaling_server。

## 心跳与重连

- Engine.IO ping/pong 按 open 包的 pingInterval/pingTimeout（默认 25s/60s）
- refresh_reconnect_key：30s 检查间隔，成功后 300s 内不再刷；ACK `["success",{reconnect_key}]` → 存入 X-NRD-RECONN-KEY（重连时带）

## 源码位置索引（farwing）

| 事实 | 位置 |
|---|---|
| join_by_device | src/account/api/mod.rs:977 |
| control 事件构造 | src/session/negotiation.rs:41 build_control_frames |
| ConnectOptions 编码 | src/session/negotiation.rs:117 encode_connect_options |
| ConnectOptions 结构 | src/features/stream_control/publisher.rs:152 |
| control ACK 解析 | src/transport/signal/mod.rs:615 wait_control_ack |
| ControlSessionInfo | src/transport/signal/negotiation.rs:119 |
| soac offer（gzip 附件） | src/transport/signal/mod.rs:332 negotiate |
| soac 解析（answer/candidate） | src/transport/signal/negotiation.rs:200 parse_remote_soac |
| set_controlling 时机 | src/transport/signal/mod.rs:501,598,964（Connected 后） |
| leave/关闭序列 | src/transport/signal/transport.rs:592 close_socket |
| 信令请求头 | src/transport/signal/negotiation.rs:245 signaling_request |
| 短信登录 | src/account/api/mod.rs:847 request_sms_code, :863 login_by_mobile |
| 设备注册（Windows） | src/account/auth/mod.rs:208 device_init_request |
| refresh_reconnect_key | src/transport/signal/mod.rs:735-760 |
