/**
 * Index page: account login (QR), device list (ViewerCloudApi, third-party
 * source evidence), and manual/mock session entry.
 *
 * Device connection flow (docs/CONTROLLER-CHAIN.md):
 *   listDevices -> joinDevice(device_id) -> RoomSession -> RemotePage.
 * The viewer's own device registration is disabled until the HarmonyOS
 * registration contract is confirmed (see QrLogin.ets).
 */

import { CredentialStore, Credentials } from '../auth/Credentials';
import { QrLogin, QrLoginSession, LoginResult } from '../auth/QrLogin';
import { ViewerCloudApi, RemoteDevice, SessionTicket } from '../cloud/ViewerCloudApi';
import { SessionParams } from '../session/SessionParams';
import { router } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';

function deviceSummary(): string[] {
  // Real HarmonyOS values, like the host sends real Linux values through
  // the windows/init endpoint (Windows masquerade).
  const name = deviceInfo.productModel.length > 0 ? deviceInfo.productModel : 'HarmonyOS Viewer';
  const os = `HarmonyOS ${deviceInfo.osFullName}`;
  let screen = '1920x1080';
  try {
    const d = display.getDefaultDisplaySync();
    if (d.width > 0 && d.height > 0) {
      screen = `${d.width}x${d.height}`;
    }
  } catch (e) {
    // display unavailable: keep the fallback
  }
  return [name, os, screen];
}

@Entry
@Component
struct Index {
  @State loginState: string = '';
  @State qrPayload: string = '';
  @State loggedIn: boolean = false;
  @State accountName: string = '';
  @State devices: RemoteDevice[] = [];
  @State devicesMessage: string = '';
  @State connecting: boolean = false;
  @State manualServer: string = '';
  @State manualToken: string = '';
  private qrSession: QrLoginSession | undefined = undefined;
  private pollTimer: number = -1;
  private pollStatus: number = 1;
  private login: QrLogin | undefined = undefined;
  private creds: Credentials | undefined = undefined;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext();
    if (context !== undefined) {
      CredentialStore.init(context).then(() => {
        this.checkCredentials();
      });
    }
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  private checkCredentials(): void {
    CredentialStore.load().then((creds: Credentials) => {
      this.creds = creds;
      this.loggedIn = creds.isComplete();
      if (this.loggedIn) {
        this.accountName = creds.accountName.length > 0 ? creds.accountName : creds.userId;
      }
    });
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private startQrLogin(): void {
    this.stopPolling();
    CredentialStore.load().then(async (creds: Credentials) => {
      if (creds.signKey.length === 0) {
        creds.signKey = 'alWiSzXZTLu3WfFnw13uBru3';
      }
      const login = new QrLogin(creds);
      this.login = login;
      const summary = deviceSummary();
      this.loginState = '注册设备…';
      const registered = await login.prepareDevice(summary[0], summary[1], summary[2]);
      if (!registered) {
        this.loginState = '设备注册失败（网络/签名问题）';
        return;
      }
      await CredentialStore.save(creds);
      this.loginState = '获取二维码…';
      const session = await login.generateQr();
      if (session === undefined) {
        this.loginState = '获取二维码失败';
        return;
      }
      this.qrSession = session;
      this.qrPayload = session.qrUrl;
      this.pollStatus = 1;
      this.loginState = '请用另一台设备上的网易UU远程App扫码';
      this.pollTimer = setInterval(() => {
        this.pollLoginStatus();
      }, 2000);
    });
  }

  private pollLoginStatus(): void {
    const session = this.qrSession;
    const login = this.login;
    if (session === undefined || login === undefined) {
      return;
    }
    login.pollStatus(session, this.pollStatus).then((status: number) => {
      if (status === 0) {
        this.loginState = '二维码已过期，请重新获取';
        this.stopPolling();
        return;
      }
      if (status === 2) {
        this.loginState = '已扫码，请在手机上确认';
      }
      if (status === 3 || status === 4) {
        this.stopPolling();
        this.loginState = '确认登录中…';
        login.finishLogin(session).then(async (result: LoginResult) => {
          if (result.ok && result.creds !== undefined) {
            await CredentialStore.save(result.creds);
            this.qrPayload = '';
            this.loginState = '';
            this.checkCredentials();
          } else {
            this.loginState = `登录失败: ${result.message}`;
          }
        });
      }
      this.pollStatus = status;
    });
  }

  private logout(): void {
    CredentialStore.clear().then(() => {
      this.loggedIn = false;
      this.accountName = '';
      this.devices = [];
      this.creds = undefined;
    });
  }

  private refreshDevices(): void {
    const creds = this.creds;
    if (creds === undefined) {
      this.devicesMessage = '凭据未加载';
      return;
    }
    this.devicesMessage = '正在获取设备列表…';
    const api = new ViewerCloudApi(creds);
    api.listDevices().then((devices: RemoteDevice[]) => {
      this.devices = devices;
      this.devicesMessage = devices.length === 0 ? '账号下没有其他设备' : '';
    }).catch((error: Error) => {
      this.devices = [];
      this.devicesMessage = `设备列表失败: ${error.message}`;
    });
  }

  private connectDevice(device: RemoteDevice): void {
    const creds = this.creds;
    if (creds === undefined || this.connecting) {
      return;
    }
    if (!device.isOnline()) {
      this.devicesMessage = `${device.alias} 不在线`;
      return;
    }
    this.connecting = true;
    this.devicesMessage = `正在连接 ${device.alias}…`;
    const api = new ViewerCloudApi(creds);
    api.joinDevice(device.deviceId, false).then((ticket: SessionTicket) => {
      this.connecting = false;
      this.devicesMessage = '';
      router.pushUrl({
        url: 'pages/RemotePage',
        params: {
          signalingServer: ticket.signalingServer,
          roomToken: ticket.roomToken,
          captureType: 1,
          displayName: device.alias,
          controllerDeviceId: creds.deviceId
        }
      });
    }).catch((error: Error) => {
      this.connecting = false;
      this.devicesMessage = `连接失败: ${error.message}`;
    });
  }

  private connectManual(): void {
    if (this.manualServer.length === 0 || this.manualToken.length === 0) {
      return;
    }
    const controllerDeviceId = this.creds !== undefined ? this.creds.deviceId : '';
    router.pushUrl({
      url: 'pages/RemotePage',
      params: {
        signalingServer: this.manualServer,
        roomToken: this.manualToken,
        captureType: 1,
        displayName: '手动连接',
        controllerDeviceId: controllerDeviceId
      }
    });
  }

  build(): void {
    Column({ space: 12 }) {
      Text('UU远程 · 主控端')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 32 })
      if (this.loggedIn) {
        Text(`已登录: ${this.accountName}`)
          .fontSize(14)
          .fontColor('#666')
        Button('刷新设备列表')
          .width('60%')
          .onClick(() => this.refreshDevices())
        if (this.devicesMessage.length > 0) {
          Text(this.devicesMessage)
            .fontSize(12)
            .fontColor('#B00')
            .padding(8)
        }
        if (this.devices.length > 0) {
          List({ space: 8 }) {
            ForEach(this.devices, (device: RemoteDevice) => {
              ListItem() {
                Column({ space: 4 }) {
                  Text(device.alias.length > 0 ? device.alias : device.deviceId).fontSize(16)
                  Text(device.isOnline() ? '在线' : '离线').fontSize(12)
                    .fontColor(device.isOnline() ? '#080' : '#888')
                }
                .width('100%')
                .padding(12)
                .borderRadius(8)
                .backgroundColor('#F5F5F5')
                .onClick(() => this.connectDevice(device))
              }
            }, (device: RemoteDevice) => device.deviceId)
          }
          .width('90%')
          .layoutWeight(1)
        }
        Divider().margin({ top: 8, bottom: 8 })
        Text('调试: 手动会话（仅限本地 mock 信令联调，勿用于真实凭据）')
          .fontSize(13)
          .fontColor('#666')
        TextInput({ placeholder: 'wss://signaling-server' })
          .width('80%')
          .onChange((value: string) => {
            this.manualServer = value;
          })
        TextInput({ placeholder: '房间令牌 (X-NRD-AUTH)' })
          .width('80%')
          .type(InputType.Password)
          .onChange((value: string) => {
            this.manualToken = value;
          })
        Button('连接')
          .width('40%')
          .enabled(this.manualServer.length > 0 && this.manualToken.length > 0)
          .onClick(() => this.connectManual())
        Button('退出登录')
          .width('40%')
          .backgroundColor('#C00')
          .onClick(() => this.logout())
      } else {
        if (this.qrPayload.length > 0) {
          // The QR is a login credential: rendered for the owner only.
          QRCode(this.qrPayload)
            .width(220)
            .height(220)
            .backgroundColor('#FFF')
          Text(this.loginState)
            .fontSize(13)
            .fontColor('#666')
            .textAlign(TextAlign.Center)
        } else {
          Text(this.loginState)
            .fontSize(13)
            .fontColor('#666')
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
          Button('扫码登录')
            .width('60%')
            .margin({ top: 16 })
            .onClick(() => this.startQrLogin())
        }
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
