/**
 * The ONE FeatureFlag declaration for this client, used by both the
 * ConnectOptions field 11 (control handshake) and the CONTROL echo request.
 *
 * Declares ONLY what this client actually implements:
 *   field 1 ff_capture_setting = 4 (CUSTOM_BITRATE: fps/quality/bitrate RPCs).
 * File transfer, simple actions, system metrics, clipboard, QoS stats are
 * NOT implemented — do not declare them (the host enables features the
 * viewer declares; farwing's full flag set is its own capability set).
 */

import { WireWriter } from './Wire';

export const FF_CAPTURE_SETTING: number = 4;

/** FeatureFlag protobuf bytes for ConnectOptions field 11. */
export function encodeViewerFeatureFlag(): Uint8Array {
  const flags = new WireWriter();
  flags.integer(1, FF_CAPTURE_SETTING);
  return flags.finish();
}
