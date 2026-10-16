/**
 * Remote session page: hosts the ArkWeb session engine (rawfile/remote/)
 * and the native signaling WebSocket. The web layer owns the
 * RTCPeerConnection, data channels, video and touch input; soac messages
 * cross the bridge:
 *   web -> ArkTS: uuNative.emitSoac / onSessionEnd / onPeerConnected
 *   ArkTS -> web: window.__uuSoac / window.__uuSignalState / uuStartSession
 *
 * Controller chain (docs/CONTROLLER-CHAIN.md):
 *   WS connect -> room_info ACK -> control binary event -> control ACK
 *   (client_id / ice_id / ICE servers) -> web session start -> soac offer
 *   -> answer/candidates -> Connected -> leave/close.
 *
 * The JavaScript proxy is registered in onControllerAttached (the SDK
 * lifecycle hook where the controller is guaranteed to be attached, before
 * the page loads); onPageEnd only marks readiness.
 */

import { webview } from '@kit.ArkWeb';
import { router } from '@kit.ArkUI';
import { window } from '@kit.ArkUI';
import { SignalingClient, SoacMessage, ControlAck, SignalingCallbacks } from '../session/SignalingClient';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0003;
const TAG: string = 'UUViewer.Remote';

class RouterParams {
  signalingServer: string = '';
  roomToken: string = '';
  captureType: number = 1;
  displayName: string = '';
  /** The CONTROLLER's own device id (for ConnectOptions field 9). */
  controllerDeviceId: string = '';
}

class NativeBridge {
  private signaling: SignalingClient | undefined = undefined;
  private page: RemotePage | undefined = undefined;

  setSignaling(signaling: SignalingClient): void {
    this.signaling = signaling;
  }

  setPage(page: RemotePage): void {
    this.page = page;
  }

  /** Web-layer soac offer: the SDP travels as a gzip binary attachment. */
  emitSoacOffer(sdp: string): void {
    if (this.signaling) {
      this.signaling.sendSoacOffer(sdp);
    }
  }

  /** Web-layer ICE candidate: text soac event with the routing envelope. */
  emitSoacCandidate(candidateJson: string): void {
    if (this.signaling) {
      this.signaling.sendSoacCandidate(candidateJson);
    }
  }

  /** WebRTC peer reached Connected: reconnects send X-NRD-CONTROLLING: 1. */
  onPeerConnected(connected: boolean): void {
    if (this.signaling) {
      this.signaling.setPeerConnected(connected);
    }
  }

  onSessionEnd(reason: string): void {
    hilog.info(DOMAIN, TAG, 'session ended');
    if (this.signaling) {
      this.signaling.close();
    }
    if (this.page !== undefined) {
      this.page.onSessionEnded();
    }
  }
}

class RemoteCallbacks implements SignalingCallbacks {
  private page: RemotePage;

  constructor(page: RemotePage) {
    this.page = page;
  }

  onRoomJoined(): void {
    this.page.onRoomJoined();
  }

  onControlAck(ack: ControlAck): void {
    this.page.onControlAck(ack);
  }

  onSoac(msg: SoacMessage): void {
    this.page.onHostSoac(msg);
  }

  onDisconnected(reason: string): void {
    this.page.onSignalDisconnected(reason);
  }
}

@Entry
@Component
struct RemotePage {
  @State statusText: string = '初始化…';
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: NativeBridge = new NativeBridge();
  private signaling: SignalingClient | undefined = undefined;
  private params: RouterParams = new RouterParams();
  private webReady: boolean = false;
  private controlAck: ControlAck | undefined = undefined;
  private sessionStarted: boolean = false;
  /** One-shot navigation guard: a remote-initiated end navigates once. */
  private exiting: boolean = false;
  /** Local destroy marker: stale onSessionEnd callbacks are swallowed. */
  private pageGone: boolean = false;

  aboutToAppear(): void {
    const record = router.getParams() as Record<string, Object>;
    if (record !== undefined && record !== null) {
      const server = record['signalingServer'];
      if (typeof server === 'string') {
        this.params.signalingServer = server;
      }
      const token = record['roomToken'];
      if (typeof token === 'string') {
        this.params.roomToken = token;
      }
      const captureType = record['captureType'];
      if (typeof captureType === 'number') {
        this.params.captureType = captureType;
      }
      const displayName = record['displayName'];
      if (typeof displayName === 'string') {
        this.params.displayName = displayName;
      }
      const controllerDeviceId = record['controllerDeviceId'];
      if (typeof controllerDeviceId === 'string') {
        this.params.controllerDeviceId = controllerDeviceId;
      }
    }
    this.bridge.setPage(this);
    this.startSignaling();
  }

  aboutToDisappear(): void {
    // Local destroy: mark the page gone so the web layer's delayed
    // onSessionEnd callback cannot trigger a SECOND router.back().
    this.pageGone = true;
    // Close the web-layer PeerConnection explicitly, then the signaling.
    if (this.webReady) {
      this.controller.runJavaScript('window.uuEndSession && window.uuEndSession();');
    }
    if (this.signaling) {
      this.signaling.close();
    }
  }

  /**
   * One-shot exit: a remote-initiated session end navigates back once.
   * A stale callback after local destroy (pageGone) is swallowed — the
   * user already left the page.
   */
  onSessionEnded(): void {
    if (this.exiting || this.pageGone) {
      return;
    }
    this.exiting = true;
    setTimeout(() => {
      router.back();
    }, 100);
  }

  onPageShow(): void {
    const context = this.getUIContext().getHostContext();
    if (context !== undefined) {
      window.getLastWindow(context).then((win: window.Window) => {
        win.setWindowKeepScreenOn(true);
      }).catch(() => {
        // window not available
      });
    }
  }

  onPageHide(): void {
    const context = this.getUIContext().getHostContext();
    if (context !== undefined) {
      window.getLastWindow(context).then((win: window.Window) => {
        win.setWindowKeepScreenOn(false);
      }).catch(() => {
        // window not available
      });
    }
  }

  onRoomJoined(): void {
    this.statusText = '房间已加入，发起控制请求…';
    if (this.signaling) {
      this.signaling.sendControlEvent();
    }
  }

  onControlAck(ack: ControlAck): void {
    this.statusText = '控制请求已接受';
    this.controlAck = ack;
    this.maybeStartSession();
  }

  onHostSoac(msg: SoacMessage): void {
    this.forwardSoac(msg);
  }

  onSignalDisconnected(reason: string): void {
    this.statusText = `连接断开: ${reason}`;
    if (this.webReady) {
      this.controller.runJavaScript(`window.__uuSignalState && window.__uuSignalState('disconnected');`);
    }
  }

  private maybeStartSession(): void {
    const ack = this.controlAck;
    if (this.webReady && ack !== undefined && !this.sessionStarted) {
      this.sessionStarted = true;
      this.statusText = '会话进行中';
      // Session contract from the control ACK: client_id / ice_id /
      // iceServers / force_relay (docs/CONTROLLER-CHAIN.md). JSON.stringify
      // output is a valid JS object literal: embed it directly.
      const params: Record<string, Object> = {
        'captureType': this.params.captureType,
        'clientId': ack.clientId,
        'iceId': ack.iceId,
        'appControlId': this.signaling !== undefined ? this.signaling.getAppControlId() : '',
        'iceServers': ack.iceServersJson,
        'forceRelay': ack.forceRelay
      };
      const json = JSON.stringify(params);
      this.controller.runJavaScript(`window.uuStartSession && window.uuStartSession(${json});`);
    }
  }

  build(): void {
    Column() {
      Web({ src: $rawfile('remote/remote.html'), controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .onControllerAttached(() => {
          // SDK lifecycle: the controller is attached here, before the page
          // loads. Register the proxy once; no refresh needed afterwards.
          this.controller.registerJavaScriptProxy(this.bridge, 'uuNative',
            ['emitSoacOffer', 'emitSoacCandidate', 'onPeerConnected', 'onSessionEnd']);
        })
        .onPageEnd(() => {
          // Readiness only: the proxy was registered in onControllerAttached.
          this.webReady = true;
          this.maybeStartSession();
        })
        .onConsole((event) => {
          const message = event.message.getMessage();
          if (message.startsWith('[uu]')) {
            hilog.info(DOMAIN, TAG, '%{public}s', message);
          }
          return false;
        })
        .onErrorReceive((event) => {
          if (event && !event.request) {
            this.statusText = '页面加载错误';
          }
        })
        .onDisAppear(() => {
          if (this.webReady) {
            this.controller.runJavaScript('window.uuEndSession && window.uuEndSession();');
          }
        })
    }
    .width('100%')
    .height('100%')
  }

  private startSignaling(): void {
    if (this.signaling !== undefined) {
      return;
    }
    this.statusText = '连接信令服务器…';
    // Local display geometry: POLICY VALUE 1920x1080@60 (farwing's
    // LocalDisplayInfo::FALLBACK), not a measurement. Real detection via
    // display.getDefaultDisplaySync() is wired in Index.ets for registration;
    // wiring the session's local-resolution field to it is a device-verification TODO.
    this.signaling = new SignalingClient(this.params.signalingServer, this.params.roomToken,
      this.params.controllerDeviceId, 1920, 1080, 60, new RemoteCallbacks(this));
    this.bridge.setSignaling(this.signaling);
  }

  private forwardSoac(msg: SoacMessage): void {
    if (!this.webReady) {
      return;
    }
    // Re-serialize as the web layer's soac shape.
    const parts: string[] = [];
    parts.push(`"type":"${msg.type}"`);
    if (msg.sdp.length > 0) {
      parts.push(`"sdp":${JSON.stringify(msg.sdp)}`);
    }
    if (msg.candidate.length > 0) {
      parts.push(`"candidate":${msg.candidate}`);
    }
    if (msg.iceId.length > 0) {
      parts.push(`"ice_id":${JSON.stringify(msg.iceId)}`);
    }
    if (msg.clientId.length > 0) {
      parts.push(`"client_id":${JSON.stringify(msg.clientId)}`);
    }
    if (msg.appControlId.length > 0) {
      parts.push(`"app_control_id":${JSON.stringify(msg.appControlId)}`);
    }
    const json = `{${parts.join(',')}}`;
    const escaped = JSON.stringify(json);
    this.controller.runJavaScript(`window.__uuSoac && window.__uuSoac(${escaped});`);
  }
}
