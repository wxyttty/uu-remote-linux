/**
 * Viewer→cloud `control` event attachment: ConnectOptions protobuf,
 * ported from OpenUUYC src/session/negotiation.rs encode_connect_options
 * and src/features/stream_control/publisher.rs ConnectOptions struct
 * (third-party source evidence; see docs/CONTROLLER-CHAIN.md).
 *
 * Field map (verified against the farwing encoder):
 *   1  kind: 1 desktop, 5 file, 9 port mapping
 *   2  screen_id: -1 (follow remote; NOT connect_type)
 *   3  CaptureParams {1 fps tier, 2 quality, 4 resolution_type=3,
 *      5 local_resolution{1 w, 2 h}, 7 chroma, 8 bitrate, 10 auto_quality, 11 fps_count}
 *   4  DecoderCapability[] {1 fps cap, 2 codec, 3 w, 4 h, 5 chroma}
 *   6  VirtualMode[] {1 w, 2 h, 3 vsync} (desktop only)
 *   8  client_type: 3 (desktop controller ABI)
 *   9  device_id: the CONTROLLER's device id (string)
 *   10 connect_type: 1 normal, 2 assistance
 *   11 FeatureFlag
 *   12 protocol version string
 */

import { WireWriter, strToUtf8 } from '../protocol/Wire';

export class DecoderCap {
  fps: number = 60;
  codec: number = 1;   // 1 H264, 2 H265
  width: number = 1920;
  height: number = 1080;
  chroma: number = 1;  // 1 = 4:2:0
}

export class ConnectOptionsBuilder {
  private kind: number = 1;
  private screenId: number = -1;
  private fpsTier: number = 2;          // 1=30, 2=60, 3=90, 4=120
  private quality: number = 5;          // Auto (initial; corrected via RPC)
  private autoQuality: number = 2;
  private localWidth: number = 1920;
  private localHeight: number = 1080;
  private localFps: number = 60;
  private chroma: number = 1;
  private decoders: DecoderCap[] = [];
  private controllerDeviceId: string = '';
  private connectType: number = 1;      // 1 normal, 2 assistance
  private featureFlag: Uint8Array = new Uint8Array(0);
  private protocolVersion: string = '';

  setKind(kind: number): ConnectOptionsBuilder {
    this.kind = kind;
    return this;
  }

  setLocalDisplay(width: number, height: number, fps: number): ConnectOptionsBuilder {
    this.localWidth = width;
    this.localHeight = height;
    this.localFps = fps;
    return this;
  }

  setDecoders(decoders: DecoderCap[]): ConnectOptionsBuilder {
    this.decoders = decoders;
    return this;
  }

  setControllerDeviceId(deviceId: string): ConnectOptionsBuilder {
    this.controllerDeviceId = deviceId;
    return this;
  }

  /** FeatureFlag bytes (only implemented features; see ControlMessages). */
  setFeatureFlag(flag: Uint8Array): ConnectOptionsBuilder {
    this.featureFlag = flag;
    return this;
  }

  setProtocolVersion(version: string): ConnectOptionsBuilder {
    this.protocolVersion = version;
    return this;
  }

  build(): Uint8Array {
    // CaptureParams (field 3)
    const capture = new WireWriter();
    capture.integer(1, this.fpsTier);
    capture.integer(2, this.quality);
    capture.integer(4, 3); // resolution_type: follow remote
    const localRes = new WireWriter();
    localRes.integer(1, this.localWidth);
    localRes.integer(2, this.localHeight);
    capture.bytes(5, localRes.finish());
    capture.integer(7, this.chroma);
    capture.integer(10, this.autoQuality);
    capture.integer(11, this.localFps);

    const options = new WireWriter();
    options.integer(1, this.kind);
    options.integer(2, this.screenId);
    options.bytes(3, capture.finish());

    // DecoderCapability[] (field 4): one per unique (codec, chroma) pair.
    const seen: string[] = [];
    for (const cap of this.decoders) {
      const key = `${cap.codec}:${cap.chroma}`;
      if (seen.indexOf(key) >= 0) {
        continue;
      }
      seen.push(key);
      const decoder = new WireWriter();
      decoder.integer(1, cap.fps);
      decoder.integer(2, cap.codec);
      decoder.integer(3, cap.width);
      decoder.integer(4, cap.height);
      decoder.integer(5, cap.chroma);
      options.bytes(4, decoder.finish());
    }

    // field 6 VirtualMode omitted: no virtual display support in v0.1.

    options.integer(8, 3); // client_type: desktop controller ABI
    if (this.controllerDeviceId.length > 0) {
      options.bytes(9, strToUtf8(this.controllerDeviceId));
    }
    options.integer(10, this.connectType);
    if (this.featureFlag.length > 0) {
      options.bytes(11, this.featureFlag);
    }
    if (this.protocolVersion.length > 0) {
      options.bytes(12, strToUtf8(this.protocolVersion));
    }
    return options.finish();
  }
}
