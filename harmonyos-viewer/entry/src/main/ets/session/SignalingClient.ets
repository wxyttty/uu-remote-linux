/**
 * Engine.IO v4 / Socket.IO signaling client for the CONTROLLER role.
 * Host-side port: src/signaling.rs. Controller chain: OpenUUYC source
 * evidence (docs/CONTROLLER-CHAIN.md); not yet live-validated.
 *
 * Chain: WS connect (headers below) -> "40" -> room_info(ack 1) -> ACK
 *   (args[0] must be a non-empty object) -> control binary event (ack 2,
 *   ConnectOptions attachment) -> ACK (args[0]=="success", args[1] carries
 *   client_id/ice_id/iceServers) -> soac offer (BINARY event, gzip SDP
 *   attachment) / soac candidate (TEXT event) -> leave -> "41" -> close.
 *
 * State machine notes (fixed per review):
 *   - `closing` vs `closed`: leave/"41" are sent BEFORE marking closed;
 *     the error path also closes the socket.
 *   - room_info/control ACKs are validated against the farwing shapes and
 *     time out (10s); duplicate ACKs and post-close ACKs are ignored.
 *   - All sends go through one queue so binary headers/attachments stay
 *     adjacent and never interleave with heartbeat frames.
 */

import { webSocket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { ConnectOptionsBuilder, DecoderCap } from '../protocol/ConnectOptions';
import { gzipStored } from '../protocol/Gzip';
import { strToUtf8 } from '../protocol/Wire';
import { encodeViewerFeatureFlag } from '../protocol/FeatureFlag';

const DOMAIN: number = 0x0002;
const TAG: string = 'UUViewer.Signaling';

const ROOM_INFO_ACK_ID: number = 1;
const CONTROL_ACK_ID: number = 2;
const ROOM_INFO_TIMEOUT_MS: number = 10000;
const CONTROL_TIMEOUT_MS: number = 10000;

/** Signaling handshake version header (farwing STREAMER_VERSION). */
export const STREAMER_VERSION: string = 'V4.7.3';
/**
 * ConnectOptions field 12 protocol version. farwing uses its CLIENT
 * version string ("4.41.2.2602"), NOT the SDK "V4.7.3" — the two are
 * distinct constants in the source (api/mod.rs:23, official_version.rs).
 */
export const PROTOCOL_VERSION: string = '4.41.2.2602';

export class SoacMessage {
  type: string = '';
  sdp: string = '';
  candidate: string = '';        // JSON string when present
  iceId: string = '';
  clientId: string = '';
  appControlId: string = '';
}

export class ControlAck {
  code: number = -1;
  clientId: string = '';
  iceId: string = '';
  iceServersJson: string = '[]';
  forceRelay: boolean = false;
}

export interface SignalingCallbacks {
  onRoomJoined(): void;
  onControlAck(ack: ControlAck): void;
  onSoac(msg: SoacMessage): void;
  onDisconnected(reason: string): void;
}

export class SignalingClient {
  private ws: webSocket.WebSocket | undefined = undefined;
  private callbacks: SignalingCallbacks;
  /** closing: leave/"41" being sent; closed: fully done. */
  private closing: boolean = false;
  private closed: boolean = false;
  private connected: boolean = false;
  private roomInfoDone: boolean = false;
  private controlSent: boolean = false;
  private controlling: boolean = false;
  private appControlId: string = '';
  private controllerDeviceId: string = '';
  private roomInfoTimer: number = -1;
  private controlTimer: number = -1;
  /** Local display geometry: POLICY VALUE (1920x1080@60 fallback) until
   * real display measurement is wired through the session path. */
  private localWidth: number = 1920;
  private localHeight: number = 1080;
  private localFps: number = 60;

  constructor(signalingServer: string, roomToken: string, controllerDeviceId: string,
    localWidth: number, localHeight: number, localFps: number, callbacks: SignalingCallbacks) {
    this.callbacks = callbacks;
    this.controllerDeviceId = controllerDeviceId;
    this.localWidth = localWidth > 0 ? localWidth : 1920;
    this.localHeight = localHeight > 0 ? localHeight : 1080;
    this.localFps = localFps > 0 ? localFps : 60;
    // app_control_id is generated LOCALLY by the controller (UUID v4) and
    // echoed inside the control event and every soac message.
    this.appControlId = util.generateRandomUUID(false);

    const base = signalingServer.replace(/\/+$/, '');
    const path = base.includes('://') ? base : `wss://${base}`;
    const wsUrl = `${path}${path.endsWith('/socket.io/') ? '' : '/socket.io/'}?EIO=4&transport=websocket&t=${Date.now()}`;
    this.ws = webSocket.createWebSocket();
    this.ws.on('open', () => {
      hilog.info(DOMAIN, TAG, 'signaling websocket open');
    });
    this.ws.on('message', (err, value) => {
      if (err) {
        return;
      }
      if (typeof value === 'string') {
        this.onText(value);
      } else {
        this.onBinary(value);
      }
    });
    this.ws.on('close', () => {
      this.finish('socket closed');
    });
    this.ws.on('error', () => {
      this.finish('socket error');
    });
    this.ws.connect(wsUrl, {
      header: {
        'X-NRD-AUTH': roomToken,
        // First connect sends "0"; "1" only after the WebRTC peer reached
        // Connected (farwing set_controlling timing).
        'X-NRD-CONTROLLING': this.controlling ? '1' : '0',
        'streamer_version': STREAMER_VERSION,
        'streamer_flag': '{"sdp_flags":{"gzip_sdp":true}}'
      }
    }, (err) => {
      if (err) {
        hilog.error(DOMAIN, TAG, 'signaling connect failed: %{public}d', err.code);
        this.finish('connect failed');
      }
    });
  }

  /** WebRTC peer connected: subsequent reconnects send X-NRD-CONTROLLING: 1. */
  setPeerConnected(connected: boolean): void {
    this.controlling = connected;
  }

  /** The locally generated app_control_id (echoed in soac messages). */
  getAppControlId(): string {
    return this.appControlId;
  }

  /** Session ids from the control ACK; used to route every soac message. */
  private sessionClientId: string = '';
  private sessionIceId: string = '';

  setSessionIds(clientId: string, iceId: string): void {
    this.sessionClientId = clientId;
    this.sessionIceId = iceId;
  }

  /**
   * Serial send queue: each task is one logical message (a text frame, or a
   * binary event's header+attachment pair). Tasks chain on the previous
   * task's completion callback so the attachment never starts before the
   * header finishes, and heartbeat pongs cannot interleave between them.
   *
   * Each task CAPTURES the socket reference at enqueue time, so a local
   * close() (which nulls this.ws before draining) cannot silently drop
   * already-queued messages: they still send on the captured socket.
   */
  private sendQueue: Promise<void> = Promise.resolve();

  private enqueueSend(task: (socket: webSocket.WebSocket) => Promise<void>): void {
    if (this.closing || this.closed) {
      return; // local close stops accepting new tasks
    }
    const socket = this.ws;
    if (!socket) {
      return;
    }
    this.sendQueue = this.sendQueue.then(() => {
      if (this.closed) {
        return Promise.resolve(); // terminal state: drop the task
      }
      return task(socket);
    }).catch(() => {
      // a failed send surfaces via the socket error/close handler
    });
  }

  private sendTextFrame(socket: webSocket.WebSocket, text: string): Promise<void> {
    return new Promise<void>((resolve) => {
      socket.send(text, () => {
        resolve();
      });
    });
  }

  private send(text: string): void {
    this.enqueueSend((socket) => this.sendTextFrame(socket, text));
  }

  private sendBinary(header: string, attachment: Uint8Array): void {
    this.enqueueSend((socket) => {
      const packet = new Uint8Array(attachment.length + 1);
      packet[0] = 0x04;
      packet.set(attachment, 1);
      // Header and attachment are ONE task: the attachment send starts only
      // after the header's completion callback fired.
      return this.sendTextFrame(socket, header).then(() => this.sendBinaryFrame(socket, packet));
    });
  }

  private sendBinaryFrame(socket: webSocket.WebSocket, packet: Uint8Array): Promise<void> {
    return new Promise<void>((resolve) => {
      socket.send(packet.buffer, () => {
        resolve();
      });
    });
  }

  /** Terminal cleanup: stop timers, notify, close the socket if needed. */
  private finish(reason: string): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.closing = true;
    if (this.roomInfoTimer >= 0) {
      clearTimeout(this.roomInfoTimer);
      this.roomInfoTimer = -1;
    }
    if (this.controlTimer >= 0) {
      clearTimeout(this.controlTimer);
      this.controlTimer = -1;
    }
    const socket = this.ws;
    this.ws = undefined;
    if (socket) {
      try {
        socket.close().catch(() => {
          // already closed
        });
      } catch (e) {
        // already closed
      }
    }
    this.callbacks.onDisconnected(reason);
  }

  private onText(text: string): void {
    if (this.closed) {
      return;
    }
    if (text.startsWith('0')) {
      // Engine.IO open -> Socket.IO connect.
      this.send('40');
    } else if (text === '2') {
      this.send('3'); // ping -> pong
    } else if (text.startsWith('40')) {
      this.connected = true;
      // room_info with ack id 1; the ACK must carry a non-empty object.
      this.send('421["room_info"]');
      this.roomInfoTimer = setTimeout(() => {
        if (!this.roomInfoDone) {
          this.finish('room_info ACK timed out');
        }
      }, ROOM_INFO_TIMEOUT_MS);
    } else if (text.startsWith('43')) {
      this.onAck(text);
    } else if (text.startsWith('42')) {
      try {
        const arr = JSON.parse(text.substring(2)) as Record<string, Object>[];
        if (arr.length >= 2) {
          const name = arr[0];
          if (typeof name === 'string') {
            this.onEvent(name, arr[1]);
          }
        }
      } catch (e) {
        // malformed event
      }
    }
  }

  private onAck(text: string): void {
    if (this.closed) {
      return;
    }
    // "43<id>[...]"
    const rest = text.substring(2);
    const bracket = rest.indexOf('[');
    if (bracket < 0) {
      return;
    }
    const id = Number(rest.substring(0, bracket));
    const payload = rest.substring(bracket);
    try {
      const args = JSON.parse(payload) as Object[];
      if (id === ROOM_INFO_ACK_ID) {
        this.onRoomInfoAck(args);
      } else if (id === CONTROL_ACK_ID) {
        this.onControlAck(args);
      }
    } catch (e) {
      // malformed ack
    }
  }

  /**
   * room_info ACK: args[0] must be a non-empty object (farwing login_room:
   * no "success" prefix here, unlike the control ACK).
   */
  private onRoomInfoAck(args: Object[]): void {
    if (this.roomInfoDone || this.closed) {
      return; // duplicate or late ACK
    }
    if (args.length < 1 || args[0] === null || args[0] === undefined) {
      this.finish('room_info ACK is empty or invalid');
      return;
    }
    const info = args[0] as Record<string, Object>;
    if (info === undefined || Object.keys(info).length === 0) {
      this.finish('room_info ACK is empty or invalid');
      return;
    }
    this.roomInfoDone = true;
    if (this.roomInfoTimer >= 0) {
      clearTimeout(this.roomInfoTimer);
      this.roomInfoTimer = -1;
    }
    this.callbacks.onRoomJoined();
  }

  /**
   * control ACK: args[0]=="success" and args[1] = {code, client_id, ice_id,
   * iceServers[]} with code==0 and non-empty ids/servers (farwing
   * wait_control_ack). Anything else is a rejection.
   */
  private onControlAck(args: Object[]): void {
    if (this.closed || this.controlTimer < 0) {
      return; // late or duplicate ACK
    }
    clearTimeout(this.controlTimer);
    this.controlTimer = -1;
    if (args.length < 2) {
      this.finish('control handshake rejected');
      return;
    }
    const status = args[0];
    if (typeof status !== 'string' || status !== 'success') {
      this.finish('control handshake rejected');
      return;
    }
    const record = args[1] as Record<string, Object>;
    if (record === undefined || record === null) {
      this.finish('control ACK has an unexpected payload');
      return;
    }
    const ack = new ControlAck();
    const code = record['code'];
    if (typeof code === 'number') {
      ack.code = code;
    }
    const clientId = record['client_id'];
    if (typeof clientId === 'string') {
      ack.clientId = clientId;
    }
    const iceId = record['ice_id'];
    if (typeof iceId === 'string') {
      ack.iceId = iceId;
    }
    const forceRelay = record['force_relay'];
    if (typeof forceRelay === 'boolean') {
      ack.forceRelay = forceRelay;
    }
    const servers = record['iceServers'];
    if (servers !== undefined && servers !== null) {
      ack.iceServersJson = JSON.stringify(servers);
    }
    if (ack.code !== 0 || ack.clientId.length === 0 || ack.iceId.length === 0) {
      this.finish(`control ACK invalid: code ${ack.code}`);
      return;
    }
    this.sessionClientId = ack.clientId;
    this.sessionIceId = ack.iceId;
    this.callbacks.onControlAck(ack);
  }

  private onBinary(data: ArrayBuffer): void {
    // Binary attachments from the server (e.g. soac gzip SDP from official
    // hosts). Our uu-remote-linux host sends plain sdp in the text event;
    // gzip answers are not yet handled (v0.1 limitation, logged only).
    hilog.info(DOMAIN, TAG, 'binary attachment: bytes=%{public}d', data.byteLength);
  }

  private onEvent(name: string, data: Object): void {
    if (name === 'soac') {
      const record = data as Record<string, Object>;
      const target = (record !== undefined && record['data'] !== undefined)
        ? record['data'] as Record<string, Object> : record;
      if (target === undefined || target === null) {
        return;
      }
      const msg = new SoacMessage();
      const type = target['type'];
      if (typeof type === 'string') {
        msg.type = type;
      }
      const sdp = target['sdp'];
      if (typeof sdp === 'string') {
        msg.sdp = sdp;
      }
      const candidate = target['candidate'];
      if (candidate !== undefined) {
        msg.candidate = JSON.stringify(candidate);
      }
      const iceId = target['ice_id'];
      if (typeof iceId === 'string') {
        msg.iceId = iceId;
      }
      const clientId = target['client_id'];
      if (typeof clientId === 'string') {
        msg.clientId = clientId;
      }
      const appControlId = target['app_control_id'];
      if (typeof appControlId === 'string') {
        msg.appControlId = appControlId;
      }
      this.callbacks.onSoac(msg);
    } else if (name === 'released' || name === 'left' || name === 'leave') {
      this.finish('peer released');
    }
  }

  /**
   * The `control` binary event: text frame
   * 451-2["control",{app_control_id, app_data:{_placeholder,num:0},
   * streamer_data}] followed by the ConnectOptions attachment.
   *
   * Decoder capability: POLICY VALUES, not measurements. ArkWeb's actual
   * H.264 RTP capability is unverified on any HarmonyOS device; we declare
   * a conservative H.264 4:2:0 8-bit 1920x1080@60 ceiling (the farwing
   * software path's advertised ceiling, streamer 958290) with codec_impl=37
   * (its software-decoder enum). If real ArkWeb probing shows more or less,
   * adjust here and in the ConnectOptions DecoderCap.
   */
  sendControlEvent(): void {
    if (this.controlSent || this.closed) {
      return;
    }
    this.controlSent = true;
    const codecCap: Record<string, Object> = {
      'video_codec': 1,
      'chroma_sampling': 1,
      'codec_impl': 37,
      'bit_depth': 8
    };
    const capability: Record<string, Object> = {
      'display_info': [] as Object[],
      'video_codec_capability': [codecCap] as Object[],
      'ice_id': ''
    };
    const streamerDataObj: Record<string, Object> = {
      'control_id': this.appControlId,
      'device_capability': capability
    };
    const streamerData = JSON.stringify(streamerDataObj);
    const appData: Record<string, Object> = {
      '_placeholder': true,
      'num': 0
    };
    const controlPayload: Record<string, Object> = {
      'app_control_id': this.appControlId,
      'app_data': appData,
      'streamer_data': streamerData
    };
    const event = JSON.stringify(['control', controlPayload] as Object[]);
    const header = `451-${CONTROL_ACK_ID}${event}`;

    // DecoderCap mirrors the streamer_data capability (H264 software ceiling).
    const decoder = new DecoderCap();
    decoder.fps = 60;
    decoder.codec = 1;
    decoder.width = 1920;
    decoder.height = 1080;
    decoder.chroma = 1;
    const options = new ConnectOptionsBuilder()
      .setKind(1)
      .setLocalDisplay(this.localWidth, this.localHeight, this.localFps)
      .setDecoders([decoder])
      .setControllerDeviceId(this.controllerDeviceId)
      .setFeatureFlag(encodeViewerFeatureFlag())
      .setProtocolVersion(PROTOCOL_VERSION)
      .build();
    this.sendBinary(header, options);
    this.controlTimer = setTimeout(() => {
      if (this.controlTimer >= 0) {
        this.controlTimer = -1;
        this.finish('control ACK timed out');
      }
    }, CONTROL_TIMEOUT_MS);
  }

  /**
   * soac offer as a BINARY event with a gzip SDP attachment (farwing
   * negotiate): 451-["soac",[{client_id, data:{app_control_id,
   * gzip_sdp:{_placeholder,num:0}, ice_id, ice_network_type:3, sdp:"",
   * type:"offer"}}]] + 0x04 + gzip(SDP).
   */
  sendSoacOffer(sdp: string): void {
    const placeholder: Record<string, Object> = {
      '_placeholder': true,
      'num': 0
    };
    const data: Record<string, Object> = {
      'app_control_id': this.appControlId,
      'gzip_sdp': placeholder,
      'ice_id': this.sessionIceId,
      'ice_network_type': 3,
      'sdp': '',
      'type': 'offer'
    };
    const payload: Record<string, Object> = {
      'client_id': this.sessionClientId,
      'data': data
    };
    const event = JSON.stringify(['soac', payload] as Object[]);
    const header = `451-${event}`;
    this.sendBinary(header, gzipStored(strToUtf8(sdp)));
  }

  /**
   * soac candidate as a TEXT event (farwing send_soac_candidate):
   * 42["soac",{client_id, data:{app_control_id, candidate:{candidate,
   * sdpMid, sdpMLineIndex, usernameFragment}, ice_id, ice_network_type:0,
   * type:"candidate"}}].
   */
  sendSoacCandidate(candidateJson: string): void {
    let candidate: Record<string, Object>;
    try {
      candidate = JSON.parse(candidateJson) as Record<string, Object>;
    } catch (e) {
      return;
    }
    const data: Record<string, Object> = {
      'app_control_id': this.appControlId,
      'candidate': candidate,
      'ice_id': this.sessionIceId,
      'ice_network_type': 0,
      'type': 'candidate'
    };
    const payload: Record<string, Object> = {
      'client_id': this.sessionClientId,
      'data': data
    };
    this.send(`42["soac",${JSON.stringify(payload)}]`);
  }

  /**
   * Controller close sequence (farwing close_socket): stop accepting new
   * tasks, wait for the queue to drain, then send leave -> "41" as queued
   * tasks, then close the socket. Local close does not fire onDisconnected.
   */
  close(): void {
    if (this.closed || this.closing) {
      return;
    }
    this.closing = true; // enqueueSend now rejects new tasks
    const socket = this.ws;
    this.ws = undefined;
    if (this.roomInfoTimer >= 0) {
      clearTimeout(this.roomInfoTimer);
      this.roomInfoTimer = -1;
    }
    if (this.controlTimer >= 0) {
      clearTimeout(this.controlTimer);
      this.controlTimer = -1;
    }
    if (!socket) {
      this.closed = true;
      return;
    }
    // leave/"41" bypass the closing gate: enqueue directly on the queue.
    const goodbye = this.sendQueue.then(() => {
      if (this.connected) {
        return wsSendAwait(socket, '42["leave"]').then(() => wsSendAwait(socket, '41'));
      }
      return Promise.resolve();
    }).catch(() => {
      // send failure: still close below
    }).then(() => {
      try {
        socket.close().catch(() => {
          // already closed
        });
      } catch (e) {
        // already closed
      }
      this.closed = true;
    });
  }
}

/** ws.send with completion callback as a Promise. */
function wsSendAwait(ws: webSocket.WebSocket, text: string): Promise<void> {
  return new Promise<void>((resolve) => {
    try {
      ws.send(text, () => {
        resolve();
      });
    } catch (e) {
      resolve(); // socket already broken: the close below handles it
    }
  });
}
