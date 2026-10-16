/**
 * Minimal gzip (RFC 1952) with DEFLATE stored blocks (RFC 1951).
 *
 * The controller sends its soac offer SDP as a gzip binary attachment
 * (farwing evidence: gzip_sdp placeholder + attachment). A stored-block
 * gzip stream is valid for any decompressor and needs no compressor
 * library; the SDP travels uncompressed inside it, which is correct
 * (the host decompresses with GzDecoder).
 *
 * Verified byte-for-byte against Node's zlib.gzipSync round-trip in
 * tools/gzip_test.mjs.
 */

/** CRC-32 (IEEE 802.3), table-driven. */
const CRC_TABLE: number[] = buildCrcTable();

function buildCrcTable(): number[] {
  const table: number[] = [];
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = ((c & 1) !== 0 ? 0xedb88320 : 0) ^ (c >>> 1);
    }
    table.push(c);
  }
  return table;
}

function crc32(data: Uint8Array): number {
  let crc = 0xffffffff;
  for (let i = 0; i < data.length; i++) {
    crc = ((CRC_TABLE[(crc ^ data[i]) & 0xff] ^ (crc >>> 8)) >>> 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

export function gzipStored(data: Uint8Array): Uint8Array {
  // gzip header: magic 1f 8b, deflate, no flags, mtime 0, XFL 0, OS 3 (unix)
  const header: number[] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03];
  const out: number[] = [...header];
  // DEFLATE stored blocks, each <= 65535 bytes.
  const MAX_BLOCK = 65535;
  const total = data.length;
  let offset = 0;
  if (total === 0) {
    // Single final empty stored block.
    out.push(0x01, 0x00, 0x00, 0xff, 0xff);
  } else {
    while (offset < total) {
      const remaining = total - offset;
      const blockLen = remaining > MAX_BLOCK ? MAX_BLOCK : remaining;
      const isLast = offset + blockLen >= total;
      out.push(isLast ? 0x01 : 0x00);
      out.push(blockLen & 0xff, (blockLen >> 8) & 0xff);
      out.push((~blockLen) & 0xff, ((~blockLen) >> 8) & 0xff);
      for (let i = 0; i < blockLen; i++) {
        out.push(data[offset + i]);
      }
      offset += blockLen;
    }
  }
  // Trailer: CRC32 (LE) + ISIZE (LE).
  const crc = crc32(data);
  out.push(crc & 0xff, (crc >> 8) & 0xff, (crc >> 16) & 0xff, (crc >> 24) & 0xff);
  const size = total & 0xffffffff;
  out.push(size & 0xff, (size >> 8) & 0xff, (size >> 16) & 0xff, (size >> 24) & 0xff);
  return new Uint8Array(out);
}
