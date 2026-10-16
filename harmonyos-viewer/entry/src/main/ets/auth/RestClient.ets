/**
 * Signed REST client for api.nrd.nie.163.com, ported from uu-remote-linux
 * src/auth.rs. Request signing: HMAC-SHA256 over
 * METHOD + path + "k=v&k=v" (sorted x-param-* headers, excluding x-param-sign) + body.
 *
 * Privacy: tokens are held in memory / Preferences only; never logged.
 */

import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { Credentials } from './Credentials';

export const BASE_URL: string = 'https://api.nrd.nie.163.com';
export const TOKEN_INVALID: number = 1120;

/** Built into the official UU PC client; same for every user. */
export const DEFAULT_SIGN_KEY: string = 'alWiSzXZTLu3WfFnw13uBru3';

export class ApiResponse {
  status: number = 0;
  code: number = -1;
  msg: string = '';
  data: Record<string, Object> | null = null;
}

export class RoomData {
  signalingServer: string = '';
  token: string = '';
}

const HEX_CHARS: string[] = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];

function toHex(bytes: Uint8Array): string {
  let hex = '';
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    hex += HEX_CHARS[Math.floor(b / 16)] + HEX_CHARS[b % 16];
  }
  return hex;
}

export class RestClient {
  private creds: Credentials;

  constructor(creds: Credentials) {
    this.creds = creds;
  }

  private async hmacSha256(key: Uint8Array, message: Uint8Array): Promise<string> {
    const symKeyGenerator = cryptoFramework.createSymKeyGenerator('HMAC');
    const keyBlob: cryptoFramework.DataBlob = { data: key };
    const symKey = await symKeyGenerator.convertKey(keyBlob);
    const mac = cryptoFramework.createMac('SHA256');
    await mac.init(symKey);
    await mac.update({ data: message });
    const result = await mac.doFinal();
    return toHex(result.data);
  }

  /**
   * x-param-* headers (sorted by key, excluding x-param-sign) joined as
   * "k=v&k=v", prefixed by METHOD+path, suffixed by the raw body.
   */
  private async signRequest(method: string, path: string, params: Map<string, string>, body: string): Promise<string> {
    const sortedKeys = Array.from(params.keys()).sort();
    const pairs: string[] = [];
    for (const k of sortedKeys) {
      pairs.push(`${k}=${params.get(k) as string}`);
    }
    const paramsStr = pairs.join('&');
    const stringToSign = `${method.toUpperCase()}${path}${paramsStr}${body}`;
    const encoder = new util.TextEncoder();
    const key = encoder.encodeInto(this.creds.signKey);
    const message = encoder.encodeInto(stringToSign);
    return this.hmacSha256(key, message);
  }

  private buildParams(): Map<string, string> {
    const params = new Map<string, string>();
    params.set('x-param-plat', '1');
    params.set('x-param-vn', '4.42.0.2770');
    params.set('x-param-vc', '2770');
    params.set('x-param-pkgn', 'com.netease.gameviewer');
    params.set('x-param-chn', 'gwqd');
    params.set('x-param-lang', 'zh-CN');
    params.set('x-param-cnt', 'CN');
    if (this.creds.clientId.length > 0) {
      params.set('x-param-client-id', this.creds.clientId);
    }
    if (this.creds.deviceId.length > 0) {
      params.set('x-param-device-id', this.creds.deviceId);
    }
    if (this.creds.systemId.length > 0) {
      params.set('x-param-system-id', this.creds.systemId);
    }
    if (this.creds.userId.length > 0) {
      params.set('x-param-user-id', this.creds.userId);
    }
    const ts = Math.floor(Date.now() / 1000).toString();
    params.set('x-param-ts', ts);
    return params;
  }

  async postJson(path: string, body: Record<string, Object>): Promise<ApiResponse> {
    const bodyStr = JSON.stringify(body);
    const params = this.buildParams();
    const sign = await this.signRequest('POST', path, params, bodyStr);

    const client = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': 'UURemote/4.42.0 (Windows NT 10.0; Win64; x64)'
      };
      if (this.creds.token.length > 0) {
        header['Authorization'] = `Bearer ${this.creds.token}`;
        header['Cookie'] = `nrd_access_token=${this.creds.token}; nrd_csrf_access_token=${this.creds.csrf}`;
        header['X-CSRF-TOKEN'] = this.creds.csrf;
      }
      const keys = Array.from(params.keys()).sort();
      for (const k of keys) {
        header[k] = params.get(k) as string;
      }
      header['x-param-sign'] = sign;

      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: bodyStr,
        expectDataType: http.HttpDataType.OBJECT,
        connectTimeout: 12000,
        readTimeout: 12000
      };
      const response = await client.request(`${BASE_URL}${path}`, options);
      const result = new ApiResponse();
      result.status = response.responseCode;
      const obj = response.result as Record<string, Object>;
      if (obj !== undefined && obj !== null) {
        const code = obj['code'];
        if (typeof code === 'number') {
          result.code = code;
        }
        const msg = obj['msg'];
        if (typeof msg === 'string') {
          result.msg = msg;
        }
        const data = obj['data'];
        if (data !== undefined && data !== null) {
          result.data = data as Record<string, Object>;
        }
      }
      return result;
    } finally {
      client.destroy();
    }
  }

  async getJson(path: string): Promise<ApiResponse> {
    const params = this.buildParams();
    const sign = await this.signRequest('GET', path, params, '');

    const client = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Accept': 'application/json',
        'User-Agent': 'UURemote/4.42.0 (Windows NT 10.0; Win64; x64)'
      };
      if (this.creds.token.length > 0) {
        header['Authorization'] = `Bearer ${this.creds.token}`;
        header['Cookie'] = `nrd_access_token=${this.creds.token}; nrd_csrf_access_token=${this.creds.csrf}`;
        header['X-CSRF-TOKEN'] = this.creds.csrf;
      }
      const keys = Array.from(params.keys()).sort();
      for (const k of keys) {
        header[k] = params.get(k) as string;
      }
      header['x-param-sign'] = sign;

      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.OBJECT,
        connectTimeout: 12000,
        readTimeout: 12000
      };
      const response = await client.request(`${BASE_URL}${path}`, options);
      const result = new ApiResponse();
      result.status = response.responseCode;
      const obj = response.result as Record<string, Object>;
      if (obj !== undefined && obj !== null) {
        const code = obj['code'];
        if (typeof code === 'number') {
          result.code = code;
        }
        const msg = obj['msg'];
        if (typeof msg === 'string') {
          result.msg = msg;
        }
        const data = obj['data'];
        if (data !== undefined && data !== null) {
          result.data = data as Record<string, Object>;
        }
      }
      return result;
    } finally {
      client.destroy();
    }
  }

  /**
   * ⚠️ HOST endpoint, kept for reference only. The HOST creates its own room
   * via /api/v1/room/create (verified from src/auth.rs); the VIEWER connects
   * to the host's room with coordinates obtained from the unverified session
   * API. The viewer does not create rooms. Do not call this in viewer flows.
   */
  async createRoom(): Promise<RoomData | undefined> {
    const body: Record<string, Object> = {};
    const response = await this.postJson('/api/v1/room/create', body);
    if (response.status === 200 && response.code === 0 && response.data !== null) {
      const data = response.data;
      const room = new RoomData();
      const server = data['signaling_server'];
      if (typeof server === 'string') {
        room.signalingServer = server;
      }
      const token = data['token'];
      if (typeof token === 'string') {
        room.token = token;
      }
      if (room.signalingServer.length > 0 && room.token.length > 0) {
        return room;
      }
    }
    return undefined;
  }
}
