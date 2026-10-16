/**
 * QR account login, ported from uu-remote-linux src/login.rs (verified endpoints):
 *   1. POST /api/v1/device/windows/init (hardware summary) -> device_id
 *   2. POST /api/v1/qrcode/gen/login -> qrcode_jump_url + login ticket token
 *   3. POST /api/v1/qrcode/login/status {token, qrcode_jump_url, login_status}: long poll 1..4
 *   4. POST /api/v1/login/by_qrcode -> user_id, token (JWT carries csrf)
 *
 * UX note: the QR must be scanned by an official UU Remote app on ANOTHER
 * device (the account owner's phone). The HarmonyOS viewer acts like the PC
 * side of the official QR login.
 *
 * The QR content is a login credential: it is rendered on screen for the
 * owner only and never logged or exported.
 */

import { RestClient, TOKEN_INVALID } from './RestClient';
import { Credentials } from './Credentials';
import { util } from '@kit.ArkTS';

const QR_EXPIRED: number = 1190;

export class QrLoginSession {
  qrUrl: string = '';
  ticket: string = '';
}

export class LoginResult {
  ok: boolean = false;
  message: string = '';
  creds: Credentials | undefined = undefined;
}

export function randomUuid(): string {
  return util.generateRandomUUID(false);
}

const B64_CHARS: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** Standard/URL-safe base64 decode (no padding required). */
function base64Decode(input: string): Uint8Array {
  const clean = input.replace(/-/g, '+').replace(/_/g, '/').replace(/=+$/, '');
  let bitBuffer = 0;
  let bitCount = 0;
  const out: number[] = [];
  for (let i = 0; i < clean.length; i++) {
    const value = B64_CHARS.indexOf(clean.charAt(i));
    if (value < 0) {
      continue;
    }
    bitBuffer = (bitBuffer << 6) | value;
    bitCount += 6;
    if (bitCount >= 8) {
      bitCount -= 8;
      out.push((bitBuffer >> bitCount) & 0xff);
    }
  }
  return new Uint8Array(out);
}

function utf8ToStr(bytes: Uint8Array): string {
  const decoder = new util.TextDecoder();
  return decoder.decodeToString(bytes);
}

/** csrf claim inside the JWT access token (verified shape from login.rs). */
export function csrfFromToken(token: string): string {
  const parts = token.split('.');
  if (parts.length !== 3) {
    return '';
  }
  try {
    const bytes = base64Decode(parts[1]);
    const text = utf8ToStr(bytes);
    const claims = JSON.parse(text) as Record<string, Object>;
    const csrf = claims['csrf'];
    if (typeof csrf === 'string') {
      return csrf;
    }
  } catch (e) {
    // malformed token: leave empty
  }
  return '';
}

export class QrLogin {
  private client: RestClient;
  private creds: Credentials;

  constructor(creds: Credentials) {
    this.creds = creds;
    this.client = new RestClient(creds);
  }

  /** Ensure a stable local identity (client_id/system_id) exists. */
  ensureIdentity(): void {
    if (this.creds.clientId.length === 0) {
      this.creds.clientId = randomUuid();
    }
    if (this.creds.systemId.length === 0) {
      this.creds.systemId = randomUuid().toUpperCase();
    }
  }

  /**
   * Register the viewer device identity via /api/v1/device/windows/init
   * with platform=1 — the same Windows-masquerade the uu-remote-linux HOST
   * uses (src/login.rs sends real Linux hardware through this endpoint;
   * the cloud accepts it). There is no official HarmonyOS client to imitate;
   * the viewer appears in the account list as a Windows device that never
   * hosts sessions (controllable=false).
   *
   * Hardware summary: real HarmonyOS values where the system exposes them
   * (productModel, osVersion, display size), like the host sends real Linux
   * values — not fabricated data.
   */
  async prepareDevice(deviceName: string, osName: string, screen: string): Promise<boolean> {
    this.ensureIdentity();
    if (this.creds.deviceId.length > 0) {
      return true;
    }
    const videoList: string[] = ['Unknown'];
    const body: Record<string, Object> = {
      'name': deviceName,
      'client_id': this.creds.clientId,
      'system_id': this.creds.systemId,
      'machine_guid': randomUuid(),
      'os': osName,
      'base_board': 'Unknown',
      'cpu': 'Unknown',
      'video': videoList,
      'mac': '',
      'memory': 0,
      'screen': screen,
      'platform': 1,
      'controllable': false
    };
    const response = await this.client.postJson('/api/v1/device/windows/init', body);
    if (response.status === 200 && response.code === 0 && response.data !== null) {
      const id = response.data['device_id'];
      if (typeof id === 'string' && (id as string).length > 0) {
        this.creds.deviceId = id;
        return true;
      }
    }
    return false;
  }

  /** Generate a fresh QR (step 2). Returns the QR content URL for rendering. */
  async generateQr(): Promise<QrLoginSession | undefined> {
    const body: Record<string, Object> = {};
    const response = await this.client.postJson('/api/v1/qrcode/gen/login', body);
    if (response.status === 200 && response.code === 0 && response.data !== null) {
      const url = response.data['qrcode_jump_url'];
      const ticket = response.data['token'];
      if (typeof url === 'string' && typeof ticket === 'string') {
        const session = new QrLoginSession();
        session.qrUrl = url;
        session.ticket = ticket;
        return session;
      }
    }
    return undefined;
  }

  /**
   * Poll the login status (step 3). Returns:
   *   1 = waiting, 2 = scanned, 3/4 = confirmed (call finishLogin), 0 = expired.
   */
  async pollStatus(session: QrLoginSession, currentStatus: number): Promise<number> {
    const body: Record<string, Object> = {
      'token': session.ticket,
      'qrcode_jump_url': session.qrUrl,
      'login_status': currentStatus
    };
    const response = await this.client.postJson('/api/v1/qrcode/login/status', body);
    if (response.code === QR_EXPIRED) {
      return 0;
    }
    if (response.status === 200 && response.code === 0 && response.data !== null) {
      const status = response.data['status'];
      if (typeof status === 'number') {
        return status;
      }
    }
    return currentStatus;
  }

  /** Complete the login (step 4). */
  async finishLogin(session: QrLoginSession): Promise<LoginResult> {
    const body: Record<string, Object> = {
      'token': session.ticket,
      'qrcode_jump_url': session.qrUrl
    };
    const response = await this.client.postJson('/api/v1/login/by_qrcode', body);
    const result = new LoginResult();
    if (response.status === 200 && response.code === 0 && response.data !== null) {
      const token = response.data['token'];
      const userId = response.data['user_id'];
      if (typeof token === 'string' && typeof userId === 'string') {
        this.creds.token = token;
        this.creds.userId = userId;
        const csrf = csrfFromToken(token);
        if (csrf.length === 0) {
          result.message = 'token carries no csrf claim';
          return result;
        }
        this.creds.csrf = csrf;
        const nickname = response.data['nickname'];
        if (typeof nickname === 'string') {
          this.creds.accountName = nickname;
        }
        result.ok = true;
        result.creds = this.creds;
        return result;
      }
    }
    if (response.code === TOKEN_INVALID) {
      result.message = 'login token invalid or expired';
    } else {
      result.message = `login failed: http ${response.status} code ${response.code} ${response.msg}`;
    }
    return result;
  }
}
