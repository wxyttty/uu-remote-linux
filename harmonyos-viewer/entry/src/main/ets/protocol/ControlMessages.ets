/**
 * Viewer→host CONTROL channel messages, ported from uu-remote-linux
 * src/control_protocol.rs (Mac client JSON shapes) and src/initialization.rs.
 *
 * The viewer is the offerer; after the CONTROL data channel opens it:
 *   1. sends SimpleAction 0 (echo_request) with its FeatureFlag,
 *   2. receives the host's echo_response with the host's FeatureFlag,
 *   3. sends input events as JSON, capture-setting RPCs as protobuf.
 *
 * FeatureFlag versions declared here mirror what the uu-remote-linux host
 * implements (see its control_protocol.rs): ff_capture_setting=4,
 * ff_simple_action=2, ff_system_metrics=2, ff_file_transfer_ftp=2.
 * Do not declare versions the client does not implement.
 */

import { WireWriter, decodeWire, WireKind, findVarint, findBytes } from '../protocol/Wire';

/** Host FeatureFlag field numbers (from host echo_response evidence). */
export enum HostFeature {
  FF_CAPTURE_SETTING = 1,
  FF_SIMPLE_ACTION = 2,
  FF_SYSTEM_METRICS = 3,
  FF_FILE_TRANSFER_FTP = 6,
  FF_CLIPBOARD = 8
}

export class HostCapabilities {
  captureSetting: number = 0;
  simpleAction: number = 0;
  systemMetrics: number = 0;
  fileTransferFtp: number = 0;
  clipboard: number = 0;

  static fromEchoResponse(payload: Uint8Array): HostCapabilities | undefined {
    // Message {3: SimpleAction{1: action, 4: FeatureFlag{1..: versions}}}
    const outer = decodeWire(payload);
    const action = findBytes(outer, 3);
    if (action === undefined) {
      return undefined;
    }
    const actionFields = decodeWire(action);
    const flag = findBytes(actionFields, 4);
    if (flag === undefined) {
      return undefined;
    }
    const result = new HostCapabilities();
    for (const f of decodeWire(flag)) {
      if (f.kind !== WireKind.VARINT) {
        continue;
      }
      if (f.number === HostFeature.FF_CAPTURE_SETTING) {
        result.captureSetting = f.varint;
      } else if (f.number === HostFeature.FF_SIMPLE_ACTION) {
        result.simpleAction = f.varint;
      } else if (f.number === HostFeature.FF_SYSTEM_METRICS) {
        result.systemMetrics = f.varint;
      } else if (f.number === HostFeature.FF_FILE_TRANSFER_FTP) {
        result.fileTransferFtp = f.varint;
      } else if (f.number === HostFeature.FF_CLIPBOARD) {
        result.clipboard = f.varint;
      }
    }
    return result;
  }
}

/**
 * SimpleAction 0 echo request. The host answers action 1 with args
 * {"seq":<request seq>} and its own FeatureFlag. The FeatureFlag declares
 * ONLY what this client implements — the host enables features the viewer
 * declares, so declaring an unimplemented feature breaks that feature's UI.
 *
 * NOTE: the live implementation used by sessions is the encoder in
 * rawfile/remote/remote.js (web layer). This ArkTS module is the reference
 * port for future native use and must stay in sync with it: currently both
 * declare only ff_capture_setting = 4 (CUSTOM_BITRATE: fps/quality RPCs).
 */
export function encodeEchoRequest(seq: number, timestamp: number): Uint8Array {
  const w = new WireWriter();
  // FeatureFlag: 1 ff_capture_setting=4 only. File transfer, simple actions
  // and system metrics are NOT implemented in this client; do not declare.
  const flags = new WireWriter();
  flags.integer(1, 4);
  const args = strToUtf8(`{"seq":${seq}}`);
  const action = new WireWriter();
  action.integer(1, 0); // action = echo_request
  action.bytes(2, args);
  action.bytes(4, flags.finish());
  return w.envelope(seq, timestamp, 3, action.finish());
}

/** Input event JSON shapes (viewer→host, CONTROL channel, UTF-8 JSON in binary frames). */
export class InputEvent {
  static keyboard(key: number, pressed: boolean): Uint8Array {
    const action = pressed ? 'kbd_press' : 'kbd_release';
    return strToUtf8(`{"action":"${action}","key":${key}}`);
  }

  static keyboardClick(key: number): Uint8Array {
    return strToUtf8(`{"action":"kbd_click","key":${key}}`);
  }

  static mouseButton(button: number, pressed: boolean): Uint8Array {
    const action = pressed ? 'mouse_press' : 'mouse_release';
    return strToUtf8(`{"action":"${action}","button":${button}}`);
  }

  static mouseClick(button: number): Uint8Array {
    return strToUtf8(`{"action":"mouse_click","button":${button}}`);
  }

  /** Normalized 0..1 absolute coordinates (host multiplies by screen size). */
  static mouseMoveAbsolute(x: number, y: number): Uint8Array {
    return strToUtf8(`{"action":"mouse_move_absolute","abs_x":${x},"abs_y":${y}}`);
  }

  static mouseMoveRelative(dx: number, dy: number): Uint8Array {
    return strToUtf8(`{"action":"mouse_move_relative","delta_x":${dx},"delta_y":${dy}}`);
  }

  static mouseScroll(dx: number, dy: number): Uint8Array {
    return strToUtf8(`{"action":"mouse_scroll","delta_x":${dx},"delta_y":${dy}}`);
  }

  /** Keyboard heartbeat the Mac client sends to keep held-key state alive. */
  static keyboardHeartbeat(): Uint8Array {
    return strToUtf8('{"heartbeat":"kbd_heartbeat"}');
  }
}

function strToUtf8(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

/**
 * CaptureSettingRequest RPC (Message 21 RpcRequest, case 2). Field 1 is an
 * fps option index (1=30, 2=60, 3=90); the real frame rate is field 18
 * fpsCount. Quality: 1 Fast, 2 General, 3 HD, 4 Bluray, 5 Auto, 6 Custom.
 * This minimal form sets quality+fps; resolution/chroma come later.
 */
export function encodeCaptureSettingRequest(requestId: number, seq: number, timestamp: number,
  quality: number, fpsIndex: number, fpsCount: number): Uint8Array {
  const request = new WireWriter();
  const header = new WireWriter();
  header.integer(1, requestId);
  request.bytes(1, header.finish()); // RpcRequest.header {1 request_id}
  const body = new WireWriter();
  body.integer(1, fpsIndex); // fps option index
  body.integer(2, quality);
  body.integer(18, fpsCount); // fpsCount
  request.bytes(2, body.finish()); // case 2 capture_setting
  return request.envelope(seq, timestamp, 21, request.finish());
}
