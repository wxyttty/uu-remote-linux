/*
 * UU Remote viewer session engine (web layer).
 * Ported from uu-remote-linux host implementation (webrtc.rs viewer side,
 * control_protocol.rs, initialization.rs, input_mapping.rs) with the
 * direction reversed: the viewer is the offerer and the host answers.
 *
 * Architecture: the signaling WebSocket lives in the ArkTS shell
 * (browser WebSocket cannot set the X-NRD-AUTH room header; the native
 * @ohos.net.websocket can). This layer owns the RTCPeerConnection, the
 * data channels, video rendering and touch input. soac messages cross
 * the bridge through window.uuNative (ArkTS-injected proxy):
 *   uuNative.emitSoacOffer(sdp)          web -> ArkTS (binary event + gzip)
 *   uuNative.emitSoacCandidate(json)     web -> ArkTS (text event)
 *   window.__uuSoac(msg)            ArkTS -> web  (answer / candidate)
 *   window.__uuSignalState(state)   ArkTS -> web  (connected / disconnected)
 *
 * Session parameters arrive via window.uuStartSession(params). The params
 * carry the room coordinates AND the cloud-assigned session identifiers
 * (ice_id / client_id / app_control_id) plus the cloud ICE configuration.
 * Account credentials never enter this layer.
 */
'use strict';

/* ------------------------------------------------------------------ */
/* Minimal protobuf wire codec (port of src/protocol.rs)               */
/* ------------------------------------------------------------------ */

const WireKind = { VARINT: 0, FIXED64: 1, BYTES: 2, FIXED32: 5 };

function decodeWire(input) {
  const fields = [];
  let offset = 0;
  function varint() {
    let result = 0, shift = 0;
    for (;;) {
      if (offset >= input.length) throw new Error('truncated');
      const byte = input[offset++];
      if (shift === 63 && byte > 1) throw new Error('varint overflow');
      result += (byte & 0x7f) * Math.pow(2, shift);
      if ((byte & 0x80) === 0) return result;
      shift += 7;
      if (shift > 63) throw new Error('varint overflow');
    }
  }
  function take(length) {
    if (offset + length > input.length) throw new Error('truncated');
    const value = input.slice(offset, offset + length);
    offset += length;
    return value;
  }
  while (offset < input.length) {
    const key = varint();
    const number = Math.floor(key / 8);
    if (number === 0 || number > 0x1fffffff) throw new Error('invalid field');
    const wire = key % 8;
    if (wire === WireKind.VARINT) {
      fields.push({ number: number, kind: WireKind.VARINT, varint: varint() });
    } else if (wire === WireKind.FIXED64) {
      fields.push({ number: number, kind: WireKind.FIXED64, bytes: take(8) });
    } else if (wire === WireKind.BYTES) {
      const length = varint();
      fields.push({ number: number, kind: WireKind.BYTES, bytes: take(length) });
    } else if (wire === WireKind.FIXED32) {
      fields.push({ number: number, kind: WireKind.FIXED32, bytes: take(4) });
    } else {
      throw new Error('unsupported wire type ' + wire);
    }
  }
  return fields;
}

function putVarint(out, value) {
  let v = value;
  while (v >= 128) {
    out.push((v & 0x7f) | 0x80);
    v = Math.floor(v / 128);
  }
  out.push(v);
}

function putInteger(out, number, value) {
  if (value !== 0) {
    putVarint(out, (number << 3));
    if (value < 0) {
      // Negative int32: protobuf sign-extends to 64 bits -> 10-byte varint.
      // BigInt keeps the 2^64 + value arithmetic exact.
      let v = BigInt.asUintN(64, BigInt(value));
      for (let i = 0; i < 9; i++) {
        out.push(Number(v & 0x7fn) | 0x80);
        v >>= 7n;
      }
      out.push(Number(v & 0x01n)); // 10th byte: bit 63
      return;
    }
    putVarint(out, value);
  }
}

function putBytes(out, number, value) {
  putVarint(out, (number << 3) | 2);
  putVarint(out, value.length);
  for (let i = 0; i < value.length; i++) out.push(value[i]);
}

/** Message envelope {1 seq, 2 timestamp, <which> payload}. */
function envelope(seq, timestamp, which, payload) {
  const out = [];
  if (seq !== 0) { putVarint(out, 8); putVarint(out, seq); }
  if (timestamp !== 0) { putVarint(out, 16); putVarint(out, timestamp); }
  putBytes(out, which, Array.from(payload));
  return new Uint8Array(out);
}

function findVarint(fields, number) {
  for (const f of fields) if (f.number === number && f.kind === WireKind.VARINT) return f.varint;
  return undefined;
}

function findBytes(fields, number) {
  for (const f of fields) if (f.number === number && f.kind === WireKind.BYTES) return f.bytes;
  return undefined;
}

/* ------------------------------------------------------------------ */
/* CONTROL protocol (viewer side)                                      */
/* ------------------------------------------------------------------ */

const encoder = new TextEncoder();

let controlSeq = 1;
function nextSeq() { return controlSeq++; }
function nowSec() { return Math.floor(Date.now() / 1000); }

/**
 * SimpleAction 0 echo request. The FeatureFlag declares only what THIS
 * client implements (the host enables features the viewer declares):
 *   ff_capture_setting = 4 (CUSTOM_BITRATE: fps/quality/bitrate RPCs).
 * File transfer, simple actions and system metrics are NOT implemented
 * in this client; do not declare them.
 */
function encodeEchoRequest(seq, timestamp) {
  const flags = [];
  putInteger(flags, 1, 4);  // ff_capture_setting = CUSTOM_BITRATE
  const args = encoder.encode(JSON.stringify({ seq: seq }));
  const action = [];
  putInteger(action, 1, 0);        // action = echo_request (0 omitted by default-value rules)
  putBytes(action, 2, args);       // args {"seq":...}
  putBytes(action, 4, flags);       // FeatureFlag
  return envelope(seq, timestamp, 3, new Uint8Array(action));
}

/** CaptureSettingRequest RPC (Message 21, case 2). */
function encodeCaptureSettingRequest(requestId, quality, fpsIndex, fpsCount) {
  const header = [];
  putInteger(header, 1, requestId);
  const body = [];
  putInteger(body, 1, fpsIndex);   // fps option index (1=30, 2=60, 3=90)
  putInteger(body, 2, quality);    // 1 Fast, 2 General, 3 HD, 4 Bluray, 5 Auto
  putInteger(body, 18, fpsCount);  // fpsCount
  const request = [];
  putBytes(request, 1, header);
  putBytes(request, 2, body);
  return envelope(nextSeq(), nowSec(), 21, new Uint8Array(request));
}

/* Input events (JSON on CONTROL, verified shapes from control_protocol.rs).
 * Mouse buttons are BITMASKS, not ordinals (src/input_mapping.rs):
 *   1 = left, 2 = right, 4 = middle. */
const MOUSE_LEFT = 1, MOUSE_RIGHT = 2, MOUSE_MIDDLE = 4;

const Input = {
  keyboard: (key, pressed) => encoder.encode(JSON.stringify({ action: pressed ? 'kbd_press' : 'kbd_release', key: key })),
  keyboardClick: (key) => encoder.encode(JSON.stringify({ action: 'kbd_click', key: key })),
  mouseButton: (button, pressed) => encoder.encode(JSON.stringify({ action: pressed ? 'mouse_press' : 'mouse_release', button: button })),
  mouseMoveAbsolute: (x, y) => encoder.encode(JSON.stringify({ action: 'mouse_move_absolute', abs_x: x, abs_y: y })),
  mouseScroll: (dx, dy) => encoder.encode(JSON.stringify({ action: 'mouse_scroll', delta_x: dx, delta_y: dy })),
  heartbeat: () => encoder.encode('{"heartbeat":"kbd_heartbeat"}')
};

/* ------------------------------------------------------------------ */
/* Session engine                                                      */
/* ------------------------------------------------------------------ */

class Session {
  constructor(params, ui) {
    this.params = params; // { captureType, iceId, clientId, appControlId, iceServers, forceRelay }
    this.ui = ui;         // { overlay, onExit }
    this.pc = null;
    this.control = null;
    // Session identifiers keep their original wire types (string or number):
    // pass through whatever the cloud supplied, never coerce.
    this.iceId = params.iceId !== undefined && params.iceId !== '' ? params.iceId : null;
    this.clientId = params.clientId !== undefined && params.clientId !== '' ? params.clientId : null;
    this.appControlId = params.appControlId !== undefined && params.appControlId !== '' ? params.appControlId : null;
    this.remoteScreen = { width: 1920, height: 1080 };
    this.pendingCandidates = [];
    this.remoteAnswerApplied = false;
    this.heldKeys = new Set();
    this.heldButtons = 0;      // bitmask of currently-pressed mouse buttons
    this.heartbeatTimer = null;
    this.statsTimer = null;
    this.closed = false;
    this.quality = 3; // HD default
    this.video = document.getElementById('video');
    this.receiveStream = null;   // local receive MediaStream (audio+video)
  }

  log(text) {
    console.info('[uu] ' + text);
    if (this.ui.overlay && !this.closed) {
      this.ui.overlay.textContent = text;
    }
  }

  /* Called by the ArkTS shell once the signaling socket is connected. */
  start() {
    this.log('创建连接请求…');
    this.createOffer();
  }

  /* soac from the host, bridged from ArkTS. */
  onSoac(target) {
    if (this.closed) return;
    if (target.type === 'answer' && target.sdp) {
      this.onAnswer(target);
    } else if (target.type === 'candidate' && target.candidate) {
      this.onRemoteCandidate(target);
    }
  }

  onSignalState(state) {
    if (state === 'disconnected' && !this.closed) {
      this.onDisconnected('信令连接断开');
    }
  }

  iceConfiguration() {
    // Cloud-supplied ICE (from the session ticket); the ArkTS bridge may
    // deliver it as a JSON string (Record values must be objects) — accept
    // both. Fall back to STUN only when the cloud provided nothing.
    let cloud = this.params.iceServers;
    if (typeof cloud === 'string') {
      try { cloud = JSON.parse(cloud); } catch (e) { cloud = null; }
    }
    const servers = [];
    if (Array.isArray(cloud)) {
      for (const server of cloud) {
        const urls = typeof server.urls === 'string' ? [server.urls]
          : (Array.isArray(server.urls) ? server.urls.slice() : []);
        const filtered = urls.filter(u => /^(stun|stuns|turn|turns):/.test(u));
        if (filtered.length === 0) continue;
        const entry = { urls: filtered };
        if (server.username) entry.username = server.username;
        if (server.credential) entry.credential = server.credential;
        servers.push(entry);
      }
    }
    if (servers.length === 0) {
      servers.push({ urls: 'stun:stun.l.google.com:19302' });
    }
    const config = { iceServers: servers };
    if (this.params.forceRelay === true) {
      config.iceTransportPolicy = 'relay';
    }
    return config;
  }

  async createOffer() {
    this.pc = new RTCPeerConnection(this.iceConfiguration());

    this.pc.onicecandidate = (ev) => {
      if (ev.candidate && window.uuNative) {
        window.uuNative.emitSoacCandidate(JSON.stringify({
          candidate: ev.candidate.candidate,
          sdpMid: ev.candidate.sdpMid,
          sdpMLineIndex: ev.candidate.sdpMLineIndex,
          usernameFragment: ev.candidate.usernameFragment
        }));
      }
    };

    this.pc.onconnectionstatechange = () => {
      const state = this.pc ? this.pc.connectionState : 'closed';
      if (state === 'connected') {
        this.ui.overlay.style.display = 'none';
        this.startHeartbeat();
        this.startStats();
        // Notify the native layer: reconnects must send X-NRD-CONTROLLING: 1.
        if (window.uuNative && window.uuNative.onPeerConnected) {
          window.uuNative.onPeerConnected(true);
        }
      } else if (state === 'failed') {
        this.onDisconnected('连接失败');
      } else if (state === 'disconnected') {
        this.onDisconnected('连接中断');
      }
    };

    this.pc.ontrack = (ev) => {
      // The host's audio and video tracks may use DIFFERENT stream ids (the
      // uu-remote-linux host adds them as separate tracks). Build one local
      // receive MediaStream, add every incoming track explicitly, and cover
      // the no-ev.streams[0] case.
      if (!this.receiveStream) {
        this.receiveStream = new MediaStream();
        this.video.srcObject = this.receiveStream;
      }
      try {
        this.receiveStream.addTrack(ev.track);
      } catch (e) {
        // track already present
      }
      if (ev.track.kind === 'video') {
        this.video.play().catch(() => { /* retried on first touch */ });
      }
      // Audio tracks join the same stream; the video element plays them
      // once unmuted (see the first-touch handler).
    };

    this.pc.ondatachannel = (ev) => this.onDataChannel(ev.channel);

    // The viewer offers recvonly video + audio and creates the data channels
    // with the verified wire labels the host attaches to.
    this.pc.addTransceiver('video', { direction: 'recvonly' });
    this.pc.addTransceiver('audio', { direction: 'recvonly' });
    this.createChannel('CONTROL_DATA_CHANNEL');
    this.createChannel('TEXT_DATA_CHANNEL');
    this.createChannel('FILE_DATA_CHANNEL');
    this.createChannel('BINARY_DATA_CHANNEL');

    const offer = await this.pc.createOffer();
    await this.pc.setLocalDescription(offer);

    // The offer travels as a gzip binary attachment (farwing negotiate);
    // the native layer builds the envelope with the control-ACK ids.
    if (window.uuNative) {
      window.uuNative.emitSoacOffer(this.pc.localDescription.sdp);
    }
    this.log('已发送连接请求，等待对方应答…');
  }

  createChannel(label) {
    const channel = this.pc.createDataChannel(label, { ordered: true });
    this.onDataChannel(channel);
    return channel;
  }

  onDataChannel(channel) {
    if (channel.label === 'CONTROL_DATA_CHANNEL') {
      this.control = channel;
      channel.binaryType = 'arraybuffer';
      channel.onopen = () => this.onControlOpen();
      channel.onmessage = (ev) => this.onControlMessage(ev.data);
      channel.onclose = () => { /* host closed control */ };
    } else if (channel.label === 'TEXT_DATA_CHANNEL') {
      channel.binaryType = 'arraybuffer';
      // Clipboard bridge: not implemented in v0.1.
    } else if (channel.label === 'BINARY_DATA_CHANNEL') {
      channel.binaryType = 'arraybuffer';
      // Terminal: not implemented in v0.1.
    } else if (channel.label === 'FILE_DATA_CHANNEL') {
      channel.binaryType = 'arraybuffer';
      // File transfer: not implemented in v0.1.
    }
  }

  async onAnswer(target) {
    if (!this.pc || this.remoteAnswerApplied) return;
    if (target.client_id !== undefined && target.client_id !== null) {
      this.clientId = target.client_id;
    }
    if (target.ice_id !== undefined && target.ice_id !== null) {
      this.iceId = target.ice_id;
    }
    if (target.app_control_id !== undefined && target.app_control_id !== null) {
      this.appControlId = target.app_control_id;
    }
    try {
      await this.pc.setRemoteDescription({ type: 'answer', sdp: target.sdp });
      this.remoteAnswerApplied = true;
      for (const cand of this.pendingCandidates) {
        await this.pc.addIceCandidate(cand).catch(() => { /* stale */ });
      }
      this.pendingCandidates = [];
      this.log('对方已应答，建立连接…');
    } catch (e) {
      this.onDisconnected('应答无效: ' + e.message);
    }
  }

  async onRemoteCandidate(target) {
    if (!this.pc) return;
    const cand = target.candidate;
    const init = {
      candidate: typeof cand === 'string' ? cand : cand.candidate,
      sdpMid: target.sdp_mid || (typeof cand === 'object' ? cand.sdpMid : undefined) || '0',
      sdpMLineIndex: target.sdp_mline_index || (typeof cand === 'object' ? cand.sdpMLineIndex : undefined) || 0
    };
    if (!init.candidate) return;
    if (!this.remoteAnswerApplied) {
      this.pendingCandidates.push(init);
      return;
    }
    try {
      await this.pc.addIceCandidate(init);
    } catch (e) { /* stale or duplicate */ }
  }

  /* ---------------- CONTROL channel ---------------- */

  onControlOpen() {
    // Echo request with our FeatureFlag; the host answers with its own.
    this.control.send(encodeEchoRequest(nextSeq(), nowSec()));
    // Default quality: HD (3), 60fps.
    this.control.send(encodeCaptureSettingRequest(1, this.quality, 2, 60));
    this.attachInput();
  }

  onControlMessage(data) {
    const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data);
    try {
      const fields = decodeWire(bytes);
      // Message 3 SimpleAction: echo_response carries the host FeatureFlag.
      const action = findBytes(fields, 3);
      if (action) {
        const actionFields = decodeWire(action);
        // action=1 (echo_response); action=0 (echo_request) is omitted by
        // the default-value rules, so field 1 present means 1.
        const act = findVarint(actionFields, 1);
        if (act === 1) {
          const flag = findBytes(actionFields, 4);
          if (flag) {
            const features = {};
            for (const f of decodeWire(flag)) {
              if (f.kind === WireKind.VARINT) features[f.number] = f.varint;
            }
            console.info('[uu] host features: ' + JSON.stringify(features));
          }
        }
      }
      // Message 7 ScreenSources: screen geometry for input scaling.
      const sources = findBytes(fields, 7);
      if (sources) this.onScreenSources(sources);
    } catch (e) {
      // Not protobuf (should not happen on CONTROL); ignore.
    }
  }

  onScreenSources(payload) {
    try {
      const fields = decodeWire(payload);
      const screen = findBytes(fields, 1);
      if (screen) {
        const s = decodeWire(screen);
        const rect = findBytes(s, 4) || findBytes(s, 3); // current_resolution, then native
        if (rect) {
          const r = decodeWire(rect);
          const width = findVarint(r, 3);
          const height = findVarint(r, 4);
          if (width && height) {
            this.remoteScreen.width = width;
            this.remoteScreen.height = height;
            console.info('[uu] remote screen ' + width + 'x' + height);
          }
        }
      }
    } catch (e) { /* malformed */ }
  }

  sendInput(bytes) {
    if (this.control && this.control.readyState === 'open') {
      this.control.send(bytes);
    }
  }

  startHeartbeat() {
    // Held-key keepalive, matching the Mac client's kbd_heartbeat.
    this.heartbeatTimer = setInterval(() => {
      if (this.heldKeys.size > 0 || this.heldButtons !== 0) {
        this.sendInput(Input.heartbeat());
      }
    }, 2000);
  }

  startStats() {
    const el = document.getElementById('stats');
    this.statsTimer = setInterval(async () => {
      if (!this.pc) return;
      try {
        const stats = await this.pc.getStats();
        stats.forEach((report) => {
          if (report.type === 'inbound-rtp' && report.kind === 'video') {
            el.textContent = (report.framesPerSecond || 0) + ' fps · ' +
              Math.round((report.bytesReceived || 0) / 1024) + ' KB · 丢包 ' + (report.packetsLost || 0);
          }
        });
      } catch (e) { /* stats unavailable */ }
    }, 2000);
  }

  /* ---------------- Input state hygiene ---------------- */

  releaseAllInput() {
    // Touch cancel / page hide / session end: release everything held.
    for (const vk of this.heldKeys) {
      this.sendInput(Input.keyboard(vk, false));
    }
    this.heldKeys.clear();
    let mask = this.heldButtons;
    while (mask !== 0) {
      // Isolate the lowest set bit (mask & -mask); mask & (mask-1) would
      // CLEAR it and yield button 0 on the first iteration (infinite loop).
      const bit = mask & -mask;
      this.sendInput(Input.mouseButton(bit, false));
      mask &= ~bit;
    }
    this.heldButtons = 0;
  }

  pressButton(button, pressed) {
    if (pressed) {
      this.heldButtons |= button;
    } else {
      this.heldButtons &= ~button;
    }
    this.sendInput(Input.mouseButton(button, pressed));
  }

  /* ---------------- Touch input ---------------- */

  attachInput() {
    const video = this.video;
    const session = this;
    let pointerDown = false;
    let dragButton = 0;          // bitmask while a drag is active
    let downTime = 0;
    let downX = 0, downY = 0;
    let moved = false;

    const toRemote = (touch) => {
      const rect = video.getBoundingClientRect();
      // object-fit: contain — map the displayed video area to 0..1.
      const scale = Math.min(rect.width / this.remoteScreen.width, rect.height / this.remoteScreen.height);
      const dispW = this.remoteScreen.width * scale;
      const dispH = this.remoteScreen.height * scale;
      const offX = rect.left + (rect.width - dispW) / 2;
      const offY = rect.top + (rect.height - dispH) / 2;
      const x = Math.min(Math.max((touch.clientX - offX) / dispW, 0), 1);
      const y = Math.min(Math.max((touch.clientY - offY) / dispH, 0), 1);
      return { x: x, y: y };
    };

    video.addEventListener('touchstart', (ev) => {
      // First user gesture: unmute (autoplay policy) and confirm playback.
      if (video.muted) video.muted = false;
      video.play().catch(() => { /* already playing */ });
      if (ev.touches.length === 1) {
        pointerDown = true;
        moved = false;
        downTime = Date.now();
        downX = ev.touches[0].clientX;
        downY = ev.touches[0].clientY;
        const p = toRemote(ev.touches[0]);
        this.sendInput(Input.mouseMoveAbsolute(p.x, p.y));
      } else {
        // Second finger lands: cancel any pending single-pointer state.
        if (pointerDown && dragButton !== 0) {
          this.pressButton(dragButton, false);
          dragButton = 0;
        }
        pointerDown = false;
      }
    }, { passive: true });

    video.addEventListener('touchmove', (ev) => {
      if (pointerDown && ev.touches.length === 1) {
        const dx = ev.touches[0].clientX - downX;
        const dy = ev.touches[0].clientY - downY;
        if (!moved && Math.hypot(dx, dy) > 12) {
          moved = true;
          // Movement beyond the tap threshold starts a LEFT-button drag:
          // press once, keep moving, release on touchend.
          dragButton = MOUSE_LEFT;
          this.pressButton(MOUSE_LEFT, true);
        }
        if (moved) {
          const p = toRemote(ev.touches[0]);
          this.sendInput(Input.mouseMoveAbsolute(p.x, p.y));
        }
      }
    }, { passive: true });

    video.addEventListener('touchend', (ev) => {
      if (!pointerDown) return;
      pointerDown = false;
      if (dragButton !== 0) {
        // Drag: release the held button at the last position.
        this.pressButton(dragButton, false);
        dragButton = 0;
        return;
      }
      if (moved) return;
      const now = Date.now();
      const holdMs = now - downTime;
      if (holdMs >= 550) {
        // Long press without movement: right click.
        this.pressButton(MOUSE_RIGHT, true);
        this.pressButton(MOUSE_RIGHT, false);
      } else {
        // Tap: left click.
        this.pressButton(MOUSE_LEFT, true);
        this.pressButton(MOUSE_LEFT, false);
      }
    }, { passive: true });

    video.addEventListener('touchcancel', () => {
      // Interrupted (system gesture, incoming call): release everything.
      pointerDown = false;
      if (dragButton !== 0) {
        this.pressButton(dragButton, false);
        dragButton = 0;
      }
      this.releaseAllInput();
    }, { passive: true });

    // Two-finger scroll.
    let scrollBase = null;
    video.addEventListener('touchstart', (ev) => {
      if (ev.touches.length === 2) {
        scrollBase = { y: (ev.touches[0].clientY + ev.touches[1].clientY) / 2 };
      }
    }, { passive: true });
    video.addEventListener('touchmove', (ev) => {
      if (ev.touches.length === 2 && scrollBase) {
        const y = (ev.touches[0].clientY + ev.touches[1].clientY) / 2;
        const dy = Math.round(scrollBase.y - y);
        if (dy !== 0) {
          this.sendInput(Input.mouseScroll(0, dy));
          scrollBase.y = y;
        }
      }
    }, { passive: true });
    video.addEventListener('touchend', () => { scrollBase = null; }, { passive: true });
    video.addEventListener('touchcancel', () => { scrollBase = null; }, { passive: true });

    // Keyboard events (hardware keyboards and the system IME's physical
    // key events). Mobile IME composition text is NOT translated: this
    // client has no text-injection channel yet.
    document.addEventListener('keydown', (ev) => {
      const vk = this.keyToWindowsVK(ev.code);
      if (vk !== undefined) {
        ev.preventDefault();
        this.sendInput(Input.keyboard(vk, true));
        this.heldKeys.add(vk);
      }
    });
    document.addEventListener('keyup', (ev) => {
      const vk = this.keyToWindowsVK(ev.code);
      if (vk !== undefined) {
        ev.preventDefault();
        this.sendInput(Input.keyboard(vk, false));
        this.heldKeys.delete(vk);
      }
    });
    // Focus loss (page hidden, IME dismissed mid-combination): release.
    window.addEventListener('blur', () => this.releaseAllInput());
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) this.releaseAllInput();
    });
  }

  keyToWindowsVK(code) {
    const map = {
      'Backquote': 0xC0, 'Digit1': 0x31, 'Digit2': 0x32, 'Digit3': 0x33, 'Digit4': 0x34, 'Digit5': 0x35,
      'Digit6': 0x36, 'Digit7': 0x37, 'Digit8': 0x38, 'Digit9': 0x39, 'Digit0': 0x30,
      'Minus': 0xBD, 'Equal': 0xBB, 'Backspace': 0x08, 'Tab': 0x09,
      'KeyQ': 0x51, 'KeyW': 0x57, 'KeyE': 0x45, 'KeyR': 0x52, 'KeyT': 0x54, 'KeyY': 0x59, 'KeyU': 0x55,
      'KeyI': 0x49, 'KeyO': 0x4F, 'KeyP': 0x50, 'BracketLeft': 0xDB, 'BracketRight': 0xDD, 'Backslash': 0xDC,
      'CapsLock': 0x14, 'KeyA': 0x41, 'KeyS': 0x53, 'KeyD': 0x44, 'KeyF': 0x46, 'KeyG': 0x47, 'KeyH': 0x48,
      'KeyJ': 0x4A, 'KeyK': 0x4B, 'KeyL': 0x4C, 'Semicolon': 0xBA, 'Quote': 0xDE, 'Enter': 0x0D,
      'ShiftLeft': 0x10, 'ShiftRight': 0xA1, 'KeyZ': 0x5A, 'KeyX': 0x58, 'KeyC': 0x43, 'KeyV': 0x56,
      'KeyB': 0x42, 'KeyN': 0x4E, 'KeyM': 0x4D, 'Comma': 0xBC, 'Period': 0xBE, 'Slash': 0xBF,
      'ControlLeft': 0xA2, 'ControlRight': 0xA3, 'MetaLeft': 0x5B, 'MetaRight': 0x5C,
      'AltLeft': 0xA4, 'AltRight': 0xA5, 'Space': 0x20,
      'ArrowLeft': 0x25, 'ArrowUp': 0x26, 'ArrowRight': 0x27, 'ArrowDown': 0x28,
      'Escape': 0x1B, 'Delete': 0x2E, 'End': 0x23, 'Home': 0x24,
      'Insert': 0x2D, 'PageUp': 0x21, 'PageDown': 0x22, 'F1': 0x70, 'F2': 0x71, 'F3': 0x72,
      'F4': 0x73, 'F5': 0x74, 'F6': 0x75, 'F7': 0x76, 'F8': 0x77, 'F9': 0x78, 'F10': 0x79,
      'F11': 0x7A, 'F12': 0x7B
    };
    return map[code];
  }

  /* ---------------- Lifecycle ---------------- */

  onDisconnected(reason) {
    if (this.closed) return;
    this.closed = true;
    this.releaseAllInput();
    this.log(reason);
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    if (this.statsTimer) clearInterval(this.statsTimer);
    if (this.pc) { try { this.pc.close(); } catch (e) { /* */ } }
    // Release media references: detach the stream so tracks stop.
    if (this.receiveStream) {
      try {
        this.receiveStream.getTracks().forEach((track) => track.stop());
      } catch (e) { /* */ }
      this.receiveStream = null;
    }
    this.video.srcObject = null;
    if (this.ui.onExit) setTimeout(() => this.ui.onExit(reason), 1200);
  }

  close() {
    this.onDisconnected('已断开');
  }
}

/* ------------------------------------------------------------------ */
/* Bootstrap + ArkTS bridge entry points                               */
/* ------------------------------------------------------------------ */

let session = null;

window.uuStartSession = function (params) {
  if (session) session.close();
  session = new Session(params, {
    overlay: document.getElementById('overlay'),
    onExit: (reason) => {
      if (window.uuNative && window.uuNative.onSessionEnd) {
        window.uuNative.onSessionEnd(reason);
      }
    }
  });
  session.start();
  return true;
};

window.uuEndSession = function () {
  if (session) session.close();
  return true;
};

window.__uuSoac = function (msgJson) {
  if (!session) return false;
  try {
    const target = typeof msgJson === 'string' ? JSON.parse(msgJson) : msgJson;
    session.onSoac(target);
    return true;
  } catch (e) {
    return false;
  }
};

window.__uuSignalState = function (state) {
  if (!session) return false;
  session.onSignalState(state);
  return true;
};

/* Toolbar interactions. */
(function () {
  function ready(fn) {
    if (document.readyState !== 'loading') fn();
    else document.addEventListener('DOMContentLoaded', fn);
  }
  ready(function () {
    const toolbar = document.getElementById('toolbar');

    document.getElementById('video').addEventListener('touchstart', (ev) => {
      if (ev.touches.length === 1 && ev.touches[0].clientY < 64) {
        toolbar.classList.toggle('hidden');
      }
    }, { passive: true });

    document.getElementById('btn-disconnect').addEventListener('click', () => {
      if (session) session.close();
    });

    document.getElementById('btn-quality').addEventListener('click', () => {
      if (session && session.control && session.control.readyState === 'open') {
        // Cycle quality 2 (高清) -> 3 (超清) -> 4 (原画) -> 2.
        session.quality = (session.quality % 3) + 2;
        session.control.send(encodeCaptureSettingRequest(Date.now() % 100000, session.quality, 2, 60));
      }
    });

    document.getElementById('btn-keyboard').addEventListener('click', () => {
      // Focus a hidden input to summon the system IME. Only physical-key
      // events are translated; IME composition text is not injected.
      const hidden = document.getElementById('kbd-input');
      if (hidden) hidden.focus();
    });
  });
})();
