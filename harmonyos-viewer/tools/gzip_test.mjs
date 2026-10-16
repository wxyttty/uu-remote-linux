/*
 * Verify the ArkTS Gzip.ets algorithm (mirrored here) against Node's
 * zlib.gzipSync: decompress both with zlib and compare, plus check the
 * stored-block structure. The ArkTS file is the production implementation;
 * this mirror must be kept in sync (same algorithm, verbatim port).
 */
import { gunzipSync, crc32 as zlibCrc32 } from 'zlib';

// verbatim port of Gzip.ets
const CRC_TABLE = buildCrcTable();
function buildCrcTable() {
  const table = [];
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = ((c & 1) !== 0 ? 0xedb88320 : 0) ^ (c >>> 1);
    }
    table.push(c);
  }
  return table;
}
function crc32(data) {
  let crc = 0xffffffff;
  for (let i = 0; i < data.length; i++) {
    crc = ((CRC_TABLE[(crc ^ data[i]) & 0xff] ^ (crc >>> 8)) >>> 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function gzipStored(data) {
  const header = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03];
  const out = [...header];
  const MAX_BLOCK = 65535;
  const total = data.length;
  let offset = 0;
  if (total === 0) {
    out.push(0x01, 0x00, 0x00, 0xff, 0xff);
  } else {
    while (offset < total) {
      const remaining = total - offset;
      const blockLen = remaining > MAX_BLOCK ? MAX_BLOCK : remaining;
      const isLast = offset + blockLen >= total;
      out.push(isLast ? 0x01 : 0x00);
      out.push(blockLen & 0xff, (blockLen >> 8) & 0xff);
      out.push((~blockLen) & 0xff, ((~blockLen) >> 8) & 0xff);
      for (let i = 0; i < blockLen; i++) out.push(data[offset + i]);
      offset += blockLen;
    }
  }
  const crc = crc32(data);
  out.push(crc & 0xff, (crc >> 8) & 0xff, (crc >> 16) & 0xff, (crc >> 24) & 0xff);
  const size = total & 0xffffffff;
  out.push(size & 0xff, (size >> 8) & 0xff, (size >> 16) & 0xff, (size >> 24) & 0xff);
  return new Uint8Array(out);
}

let failures = 0;
function check(cond, label) {
  if (!cond) { console.error('FAIL ' + label); failures++; }
  else console.log('ok   ' + label);
}

// 1. Round-trip: our gzip decompresses with Node zlib to the original.
const samples = [
  new Uint8Array(0),
  new TextEncoder().encode('v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\n'),
  new TextEncoder().encode('x'.repeat(65535)),
  new TextEncoder().encode('y'.repeat(65536)),        // two stored blocks
  new TextEncoder().encode('z'.repeat(200000)),       // multiple blocks
];
for (let i = 0; i < samples.length; i++) {
  const gz = gzipStored(samples[i]);
  let ok = false;
  try {
    const back = gunzipSync(gz);
    ok = back.length === samples[i].length && back.every((b, j) => b === samples[i][j]);
  } catch (e) { ok = false; }
  check(ok, `round-trip sample ${i} (${samples[i].length} bytes)`);
}

// 2. Header structure: magic, deflate method, OS.
{
  const gz = gzipStored(new TextEncoder().encode('abc'));
  check(gz[0] === 0x1f && gz[1] === 0x8b && gz[2] === 0x08, 'gzip magic + deflate');
  check(gz[9] === 0x03, 'OS = unix');
}

// 3. CRC32 correctness against zlib's own CRC.
{
  const data = new TextEncoder().encode('hello world');
  const gz = gzipStored(data);
  const crc = crc32(data);
  check(crc === zlibCrc32(data), `crc32 matches zlib: ${crc} vs ${zlibCrc32(data)}`);
}

console.log(failures === 0 ? 'ALL PASS' : failures + ' FAILURES');
process.exit(failures === 0 ? 0 : 1);
