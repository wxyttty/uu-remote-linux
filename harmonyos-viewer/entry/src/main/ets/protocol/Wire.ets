/**
 * Dependency-free protobuf wire codec, ported from uu-remote-linux src/protocol.rs.
 * The CONTROL data channel carries protobuf `Message {1 seq, 2 timestamp, <which> payload}`
 * envelopes; this module decodes/encodes fields without assigning semantics.
 *
 * ArkTS notes: Uint8Array slices are used instead of Rust &[u8]; wire values are
 * represented as a tagged union via a class hierarchy (no structural typing).
 */

import { util } from '@kit.ArkTS';

export enum WireKind {
  VARINT = 0,
  FIXED64 = 1,
  BYTES = 2,
  FIXED32 = 5
}

export class WireField {
  readonly number: number;
  readonly kind: WireKind;
  readonly varint: number = 0;      // valid when kind == VARINT
  readonly bytes: Uint8Array = new Uint8Array(0); // valid when kind == BYTES
  readonly fixed64: Uint8Array = new Uint8Array(0); // valid when kind == FIXED64 (8 bytes LE order as read)
  readonly fixed32: Uint8Array = new Uint8Array(0); // valid when kind == FIXED32

  constructor(number: number, kind: WireKind, varint: number, bytes: Uint8Array) {
    this.number = number;
    this.kind = kind;
    this.varint = varint;
    this.bytes = bytes;
    if (kind === WireKind.FIXED64) {
      this.fixed64 = bytes;
    } else if (kind === WireKind.FIXED32) {
      this.fixed32 = bytes;
    }
  }
}

export class WireError extends Error {
  constructor(message: string) {
    super(message);
  }
}

class Reader {
  private data: Uint8Array;
  private offset: number = 0;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  varint(): number {
    let result = 0;
    for (let shift = 0; shift < 64; shift += 7) {
      if (this.offset >= this.data.length) {
        throw new WireError('truncated');
      }
      const byte = this.data[this.offset];
      this.offset += 1;
      if (shift === 63 && byte > 1) {
        throw new WireError('varint overflow');
      }
      result += (byte & 0x7f) * Math.pow(2, shift);
      if ((byte & 0x80) === 0) {
        return result;
      }
    }
    throw new WireError('varint overflow');
  }

  take(length: number): Uint8Array {
    const end = this.offset + length;
    if (end > this.data.length) {
      throw new WireError('truncated');
    }
    const value = this.data.slice(this.offset, end);
    this.offset = end;
    return value;
  }

  atEnd(): boolean {
    return this.offset >= this.data.length;
  }
}

/** Decode a complete protobuf message; deprecated groups are rejected. */
export function decodeWire(input: Uint8Array): WireField[] {
  const reader = new Reader(input);
  const fields: WireField[] = [];
  while (!reader.atEnd()) {
    const key = reader.varint();
    const number = Math.floor(key / 8);
    if (number === 0 || number > 0x1fffffff) {
      throw new WireError('invalid field');
    }
    const wire = key % 8;
    if (wire === WireKind.VARINT) {
      fields.push(new WireField(number, WireKind.VARINT, reader.varint(), new Uint8Array(0)));
    } else if (wire === WireKind.FIXED64) {
      fields.push(new WireField(number, WireKind.FIXED64, 0, reader.take(8)));
    } else if (wire === WireKind.BYTES) {
      const length = reader.varint();
      fields.push(new WireField(number, WireKind.BYTES, 0, reader.take(length)));
    } else if (wire === WireKind.FIXED32) {
      fields.push(new WireField(number, WireKind.FIXED32, 0, reader.take(4)));
    } else {
      throw new WireError(`unsupported wire type ${wire}`);
    }
  }
  return fields;
}

/** Encoder helpers matching src/initialization.rs (varint/integer/boolean/bytes/text). */
export class WireWriter {
  private out: number[] = [];

  private varint(value: number): void {
    let v = value;
    while (v >= 128) {
      this.out.push((v & 0x7f) | 0x80);
      v = Math.floor(v / 128);
    }
    this.out.push(v);
  }

  integer(number: number, value: number): void {
    if (value !== 0) {
      this.varint((number << 3));
      if (value < 0) {
        // Negative int32: protobuf sign-extends to 64 bits -> 10-byte varint.
        // BigInt keeps the 2^64 + value arithmetic exact.
        let v = BigInt.asUintN(64, BigInt(value));
        for (let i = 0; i < 9; i++) {
          this.out.push(Number(v & BigInt(0x7f)) | 0x80);
          v >>= BigInt(7);
        }
        this.out.push(Number(v & BigInt(1))); // 10th byte: bit 63
        return;
      }
      this.varint(value);
    }
  }

  boolean(number: number, value: boolean): void {
    if (value) {
      this.integer(number, 1);
    }
  }

  bytes(number: number, value: Uint8Array): void {
    this.varint((number << 3) | 2);
    this.varint(value.length);
    for (let i = 0; i < value.length; i++) {
      this.out.push(value[i]);
    }
  }

  text(number: number, value: string): void {
    if (value.length > 0) {
      const encoded = strToUtf8(value);
      this.bytes(number, encoded);
    }
  }

  /** CONTROL Message envelope: {1 seq, 2 timestamp, <which> payload}. */
  envelope(seq: number, timestamp: number, which: number, payload: Uint8Array): Uint8Array {
    const inner = new WireWriter();
    if (seq !== 0) {
      inner.varint(8); // field 1, varint
      inner.varint(seq);
    }
    if (timestamp !== 0) {
      inner.varint(16); // field 2, varint
      inner.varint(timestamp);
    }
    inner.bytes(which, payload);
    return inner.finish();
  }

  finish(): Uint8Array {
    return new Uint8Array(this.out);
  }
}

export function strToUtf8(value: string): Uint8Array {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(value);
}

export function utf8ToStr(value: Uint8Array): string {
  const decoder = new util.TextDecoder();
  return decoder.decodeToString(value);
}

/** Find the first varint field with the given number, or undefined. */
export function findVarint(fields: WireField[], number: number): number | undefined {
  for (const f of fields) {
    if (f.number === number && f.kind === WireKind.VARINT) {
      return f.varint;
    }
  }
  return undefined;
}

/** Find the first bytes field with the given number, or undefined. */
export function findBytes(fields: WireField[], number: number): Uint8Array | undefined {
  for (const f of fields) {
    if (f.number === number && f.kind === WireKind.BYTES) {
      return f.bytes;
    }
  }
  return undefined;
}
