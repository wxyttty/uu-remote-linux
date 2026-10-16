/*
 * Conformance test for the PRODUCTION ConnectOptions encoder.
 *
 * The ArkTS source (entry/src/main/ets/protocol/ConnectOptions.ets) is
 * parsed and its build() logic is executed directly in Node via a small
 * ArkTS->JS transpile (types stripped, WireWriter replaced by the JS
 * production codec from remote.js). This tests the actual production
 * code path — not a hand-written copy.
 *
 * Field map asserted against farwing evidence (docs/CONTROLLER-CHAIN.md).
 */
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const here = dirname(fileURLToPath(import.meta.url));

// 1. Load the JS production wire codec from remote.js.
const src = readFileSync(join(here, '../entry/src/main/resources/rawfile/remote/remote.js'), 'utf8');
const section = src.slice(0, src.indexOf('/* CONTROL protocol')).replace("'use strict';", '');
const wireMod = { exports: {} };
new Function('module', 'exports', section + `
module.exports = { decodeWire, putVarint, putInteger, putBytes, WireKind };
`)(wireMod, wireMod.exports);
const { decodeWire, putInteger, putBytes, WireKind } = wireMod.exports;

// 2. Transpile the production ConnectOptions.ets: strip ArkTS types and
//    replace the WireWriter dependency with the JS codec above.
const ets = readFileSync(join(here, '../entry/src/main/ets/protocol/ConnectOptions.ets'), 'utf8');
// Extract the class body of ConnectOptionsBuilder and DecoderCap.
function extractClass(name) {
  const start = ets.indexOf(`export class ${name}`);
  if (start < 0) throw new Error(`class ${name} not found`);
  let depth = 0, i = ets.indexOf('{', start);
  const bodyStart = i;
  for (; i < ets.length; i++) {
    if (ets[i] === '{') depth++;
    else if (ets[i] === '}') { depth--; if (depth === 0) break; }
  }
  return ets.slice(start, i + 1);
}
const builderClass = extractClass('ConnectOptionsBuilder');

// Strip ArkTS annotations: types in field decls, return types, param types.
function stripArkts(code) {
  return code
    .replace(/export class /g, 'class ')
    .replace(/\):\s*(?:ConnectOptionsBuilder|Uint8Array|number|string|boolean|void)\s*\{/g, ') {')
    .replace(/(\w+):\s*(?:ConnectOptionsBuilder|Uint8Array|number|string|boolean|DecoderCap\[\]|string\[\]|number\[\])\s*(?=[,)=;=])/g, '$1 ')
    .replace(/private /g, '');
}

const js = stripArkts(builderClass);

// WireWriter shim over the production JS codec.
class WireWriter {
  constructor() { this.out = []; }
  integer(n, v) { putInteger(this.out, n, v); }
  bytes(n, v) { putBytes(this.out, n, Array.from(v)); }
  finish() { return new Uint8Array(this.out); }
}

// DecoderCap shim (plain object).
class DecoderCap {
  constructor() { this.fps = 60; this.codec = 1; this.width = 1920; this.height = 1080; this.chroma = 1; }
}

// Evaluate the class with the shims in scope.
const factory = new Function('WireWriter', 'DecoderCap', 'strToUtf8', `
${js}
return ConnectOptionsBuilder;
`);
const Builder = factory(WireWriter, DecoderCap, (s) => new TextEncoder().encode(s));

let failures = 0;
function check(cond, label) {
  if (!cond) { console.error('FAIL ' + label); failures++; }
  else console.log('ok   ' + label);
}
function varintOf(fields, n) {
  const f = fields.find(f => f.number === n && f.kind === WireKind.VARINT);
  return f ? f.varint : undefined;
}
function bytesOf(fields, n) {
  const f = fields.find(f => f.number === n && f.kind === WireKind.BYTES);
  return f ? f.bytes : undefined;
}

// 3. Build with the SAME call path as SignalingClient.sendControlEvent().
const decoder = new DecoderCap();
decoder.fps = 60; decoder.codec = 1; decoder.width = 1920; decoder.height = 1080; decoder.chroma = 1;
const opts = new Builder()
  .setKind(1)
  .setLocalDisplay(1920, 1080, 60)
  .setDecoders([decoder])
  .setControllerDeviceId('abcdef0123456789')
  .setProtocolVersion('4.41.2.2602')
  .build();

const fields = decodeWire(opts);
check(varintOf(fields, 1) === 1, 'field 1 kind=1 (desktop)');
// screen_id=-1 sign-extends to a 10-byte varint; assert raw bytes.
{
  const raw = Array.from(opts);
  const tagIndex = raw.indexOf(0x10);
  const ok = tagIndex === 2 &&
    raw.slice(tagIndex + 1, tagIndex + 10).every(b => b === 0xff) && raw[tagIndex + 10] === 0x01;
  check(ok, 'field 2 screen_id=-1 (10-byte sign-extended varint)');
}
check(varintOf(fields, 8) === 3, 'field 8 client_type=3');
check(varintOf(fields, 10) === 1, 'field 10 connect_type=1 (normal)');
check(new TextDecoder().decode(bytesOf(fields, 9)) === 'abcdef0123456789', 'field 9 controller device_id');
check(new TextDecoder().decode(bytesOf(fields, 12)) === '4.41.2.2602', 'field 12 protocol version (CLIENT, not SDK)');

const capture = decodeWire(bytesOf(fields, 3));
check(varintOf(capture, 1) === 2, 'CaptureParams field 1 fps tier=2 (60)');
check(varintOf(capture, 2) === 5, 'CaptureParams field 2 quality=5 (Auto)');
check(varintOf(capture, 4) === 3, 'CaptureParams field 4 resolution_type=3 (follow remote)');
check(varintOf(capture, 7) === 1, 'CaptureParams field 7 chroma=1 (4:2:0)');
check(varintOf(capture, 10) === 2, 'CaptureParams field 10 auto_quality=2');
check(varintOf(capture, 11) === 60, 'CaptureParams field 11 fps_count=60');
const localRes = decodeWire(bytesOf(capture, 5));
check(varintOf(localRes, 1) === 1920 && varintOf(localRes, 2) === 1080, 'CaptureParams field 5 local_resolution 1920x1080');

const decoderFields = decodeWire(bytesOf(fields, 4));
check(varintOf(decoderFields, 1) === 60 && varintOf(decoderFields, 2) === 1, 'DecoderCap fps=60 codec=H264');
check(varintOf(decoderFields, 3) === 1920 && varintOf(decoderFields, 4) === 1080 && varintOf(decoderFields, 5) === 1, 'DecoderCap 1920x1080 chroma 4:2:0');

// 4. The production call path must set decoders (advisor issue 3): assert
//    that SignalingClient.ets actually calls setDecoders.
const signalingSrc = readFileSync(join(here, '../entry/src/main/ets/session/SignalingClient.ets'), 'utf8');
check(signalingSrc.includes('.setDecoders(['), 'SignalingClient call path sets decoders');
check(signalingSrc.includes('.setProtocolVersion(PROTOCOL_VERSION)'), 'SignalingClient call path sets protocol version');
check(!signalingSrc.includes('setProtocolVersion(STREAMER_VERSION)'), 'protocol version is not the SDK version');

console.log(failures === 0 ? 'ALL PASS' : failures + ' FAILURES');
process.exit(failures === 0 ? 0 : 1);
