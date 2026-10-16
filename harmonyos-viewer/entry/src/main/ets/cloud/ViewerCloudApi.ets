/**
 * Viewer-side cloud API. Endpoint evidence: OpenUUYC (farwing) source
 * (third-party reverse-engineering of the official 4.41.2 client); see
 * docs/CONTROLLER-CHAIN.md for the full chain and source index. Not yet
 * validated against the live cloud from this client.
 *
 *   GET  /api/v1/device/list -> {current_device, my_binded_devices[]}
 *   POST /api/v1/room/join/by_device/{device_id} {force_join} -> RoomSession
 *
 * The viewer's own device registration remains DISABLED (see QrLogin.ets):
 * farwing registers via windows/init with platform:1 and real Windows
 * hardware, which proves the Windows flow only. Until the HarmonyOS
 * registration contract is confirmed, this module requires a device_id
 * already present in the credential store.
 */

import { RestClient } from '../auth/RestClient';
import { Credentials } from '../auth/Credentials';

export class RemoteDevice {
  deviceId: string = '';
  alias: string = '';
  status: string = '';        // "CONNECTED" = online (farwing DeviceInfo.is_connected)
  platform: number = 0;       // 1 Windows, 2 Android, 3 iOS, 4 macOS, 5 TV
  controllable: boolean = false;
  versionName: string = '';

  isOnline(): boolean {
    return this.status === 'CONNECTED';
  }
}

export class IceServer {
  urls: string = '';
  username: string = '';
  credential: string = '';
}

/** From the control ACK (not the REST join response). */
export class ControlSessionInfo {
  code: number = -1;
  clientId: string = '';
  iceId: string = '';
  iceServers: IceServer[] = [];
  forceRelay: boolean = false;
}

export class SessionTicket {
  signalingServer: string = '';
  roomToken: string = '';
  captureType: number = 1;
  deviceId: string = '';
}

export class ViewerCloudApi {
  private client: RestClient;

  constructor(creds: Credentials) {
    this.client = new RestClient(creds);
  }

  /** GET device/list. Requires a registered device_id in credentials. */
  async listDevices(): Promise<RemoteDevice[]> {
    const response = await this.client.getJson('/api/v1/device/list');
    if (response.status !== 200 || response.code !== 0 || response.data === null) {
      throw new Error(`device list failed: http ${response.status} code ${response.code} ${response.msg}`);
    }
    const data = response.data;
    const list = data['my_binded_devices'];
    const devices: RemoteDevice[] = [];
    if (list !== undefined && list !== null) {
      const entries = list as Object[];
      for (const entry of entries) {
        const record = entry as Record<string, Object>;
        const device = new RemoteDevice();
        const id = record['device_id'];
        if (typeof id === 'string') {
          device.deviceId = id;
        }
        const alias = record['alias'];
        if (typeof alias === 'string') {
          device.alias = alias;
        }
        const status = record['status'];
        if (typeof status === 'string') {
          device.status = status;
        }
        const platform = record['platform'];
        if (typeof platform === 'number') {
          device.platform = platform;
        }
        const controllable = record['controllable'];
        if (typeof controllable === 'boolean') {
          device.controllable = controllable;
        }
        const version = record['version_name'];
        if (typeof version === 'string') {
          device.versionName = version;
        }
        if (device.deviceId.length > 0) {
          devices.push(device);
        }
      }
    }
    return devices;
  }

  /**
   * POST room/join/by_device/{device_id} {force_join:false} -> room session
   * (token + signaling endpoints). The control handshake (client_id/ice_id/
   * ICE config) happens later on the signaling socket, not here.
   */
  async joinDevice(deviceId: string, forceJoin: boolean): Promise<SessionTicket> {
    if (deviceId.length === 0) {
      throw new Error('device id is empty');
    }
    const body: Record<string, Object> = { 'force_join': forceJoin };
    const response = await this.client.postJson(`/api/v1/room/join/by_device/${deviceId}`, body);
    if (response.status !== 200 || response.code !== 0 || response.data === null) {
      throw new Error(`join device failed: http ${response.status} code ${response.code} ${response.msg}`);
    }
    const data = response.data;
    const token = data['token'];
    if (typeof token !== 'string' || (token as string).length === 0) {
      throw new Error('join response did not contain a room token');
    }
    // signaling_list takes priority; fall back to signaling_server.
    let server = '';
    const list = data['signaling_list'];
    if (list !== undefined && list !== null) {
      const entries = list as Object[];
      for (const entry of entries) {
        if (typeof entry === 'string' && (entry as string).length > 0) {
          server = entry as string;
          break;
        }
      }
    }
    if (server.length === 0) {
      const fallback = data['signaling_server'];
      if (typeof fallback === 'string') {
        server = fallback;
      }
    }
    if (server.length === 0) {
      throw new Error('join response did not contain a signaling server');
    }
    const ticket = new SessionTicket();
    ticket.signalingServer = server;
    ticket.roomToken = token;
    ticket.deviceId = deviceId;
    return ticket;
  }
}
