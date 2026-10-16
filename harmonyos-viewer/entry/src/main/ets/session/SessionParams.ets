/**
 * Parameters handed from the ArkTS shell to the web session engine.
 * The full session contract: room coordinates, cloud-assigned session
 * identifiers (original wire types preserved) and the cloud ICE
 * configuration. Never account credentials.
 */

export class SessionParams {
  captureType: number = 1; // 1 desktop, 5 file transfer, 8 terminal, 9 port mapping
  signalingServer: string = '';
  roomToken: string = '';
  displayName: string = '';
  /** Cloud-assigned ids echoed inside every soac message (may stay empty in mock setups). */
  iceId: string = '';
  appControlId: string = '';
  clientId: string = '';
  /** JSON array of {urls, username?, credential?} from the session ticket. */
  iceServers: string = '[]';
  forceRelay: boolean = false;

  static fromTicket(signalingServer: string, roomToken: string, captureType: number, displayName: string): SessionParams {
    const params = new SessionParams();
    params.signalingServer = signalingServer;
    params.roomToken = roomToken;
    params.captureType = captureType;
    params.displayName = displayName;
    return params;
  }
}
