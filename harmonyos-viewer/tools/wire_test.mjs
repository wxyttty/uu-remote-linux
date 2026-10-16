/*
 * Protocol conformance test for the web-layer protobuf codec and CONTROL
 * encoders, run against the PRODUCTION functions extracted from
 * rawfile/remote/remote.js (never a copy). Test vectors come from the host
 * implementation: src/protocol.rs, src/initialization.rs,
 * src/control_protocol.rs.
 *
 * Usage: node tools/wire_test.mjs
 */
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '../entry/src/main/resources/rawfile/remote/remote.js'), 'utf8');
// Evaluate the codec + CONTROL encoder section (up to the Input events).
const section = src.slice(0, src.indexOf('/* Input events')).replace("'use strict';", '');
const mod = { exports: {} };
new Function('module', 'exports', section + `
module.exports = { decodeWire, putVarint, putInteger, putBytes, envelope, WireKind,
  encodeEchoRequest, encodeCaptureSettingRequest };
`)(mod, mod.exports);
const { decodeWire, putInteger, envelope, WireKind, encodeEchoRequest, encodeCaptureSettingRequest } = mod.exports;

let failures = 0;
function check(cond, label) {
  if (!cond) { console.error('FAIL ' + label); failures++; }
  else console.log('ok   ' + label);
}
function rejects(arr, label) {
  try { decodeWire(new Uint8Array(arr)); console.error('FAIL ' + label + ' NOT rejected'); failures++; }
  catch (e) { console.log('ok   ' + label + ' rejected'); }
}

// protocol.rs vectors
const fields = decodeWire(new Uint8Array([8, 150, 1, 18, 2, 8, 3, 29, 1, 2, 3, 4]));
check(fields.length === 3, 'field count');
check(fields[0].number === 1 && fields[0].kind === WireKind.VARINT && fields[0].varint === 150, 'f1 varint 150');
check(fields[1].number === 2 && fields[1].kind === WireKind.BYTES && Array.from(fields[1].bytes).join() === '8,3', 'f2 nested bytes');
check(fields[2].number === 3 && fields[2].kind === WireKind.FIXED32 && Array.from(fields[2].bytes).join() === '1,2,3,4', 'f3 fixed32');
rejects([18, 4, 1], 'bytes truncation');
rejects([9, 1, 2, 3], 'fixed64 truncation');
rejects([8, 128], 'truncated varint');
rejects([8, 255,255,255,255,255,255,255,255,255,2], 'varint overflow (10th byte > 1)');
rejects([0], 'field number 0');
rejects([11], 'group wire type 3');

// envelope round-trip (production encoder)
const parsed = decodeWire(envelope(7, 9, 3, new Uint8Array([8, 1, 16, 2])));
check(parsed.length === 3, 'envelope: 3 fields');
check(parsed[0].number === 1 && parsed[0].varint === 7, 'envelope seq=7');
check(parsed[1].number === 2 && parsed[1].varint === 9, 'envelope ts=9');
check(parsed[2].number === 3 && Array.from(parsed[2].bytes).join() === '8,1,16,2', 'envelope payload round-trip');
const parsedDefaults = decodeWire(envelope(0, 0, 8, new Uint8Array(0)));
check(parsedDefaults.length === 1 && parsedDefaults[0].number === 8, 'envelope omits default seq/ts');

// negative int32 (initialization.rs encode_report_error -5)
const out = [];
putInteger(out, 2, -5);
check(out.length === 11 && out[0] === 0x10, 'negative: tag + 10-byte varint');
let v = 0n;
for (let i = 1; i < out.length; i++) v |= BigInt(out[i] & 0x7f) << BigInt(7 * (i - 1));
check(v === (1n << 64n) - 5n, 'negative int32 = 2^64-5 exact');

// production encodeEchoRequest (control_protocol.rs shape)
const outer = decodeWire(encodeEchoRequest(1, 2));
check(outer[0].varint === 1 && outer[1].varint === 2, 'echo seq=1 ts=2');
const action = decodeWire(outer.find(f => f.number === 3).bytes);
check(action.find(f => f.number === 1) === undefined, 'echo action field omitted (default 0)');
const args = JSON.parse(new TextDecoder().decode(action.find(f => f.number === 2).bytes));
check(args.seq === 1, 'echo args {seq:1}');
const flag = decodeWire(action.find(f => f.number === 4).bytes);
const features = {};
for (const f of flag) if (f.kind === WireKind.VARINT) features[f.number] = f.varint;
check(JSON.stringify(features) === '{"1":4}', 'echo declares only implemented ff_capture_setting=4');

// production encodeCaptureSettingRequest
const rpcReq = decodeWire(decodeWire(encodeCaptureSettingRequest(1, 3, 2, 60)).find(f => f.number === 21).bytes);
const rpcHeader = decodeWire(rpcReq.find(f => f.number === 1).bytes);
check(rpcHeader.find(f => f.number === 1).varint === 1, 'rpc request_id=1');
const rpcBody = decodeWire(rpcReq.find(f => f.number === 2).bytes);
check(rpcBody.find(f => f.number === 1).varint === 2, 'rpc fps index=2');
check(rpcBody.find(f => f.number === 2).varint === 3, 'rpc quality=3');
check(rpcBody.find(f => f.number === 18).varint === 60, 'rpc fpsCount=60');

console.log(failures === 0 ? 'ALL PASS' : failures + ' FAILURES');
process.exit(failures === 0 ? 0 : 1);
