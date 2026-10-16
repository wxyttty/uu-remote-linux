/**
 * Account credentials storage. Tokens are persisted with Preferences
 * (application sandbox); never logged, never passed through URLs.
 */

import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';

export class Credentials {
  userId: string = '';
  deviceId: string = '';
  clientId: string = '';
  systemId: string = '';
  token: string = '';
  csrf: string = '';
  signKey: string = '';
  accountName: string = '';

  isComplete(): boolean {
    return this.userId.length > 0 && this.token.length > 0 && this.csrf.length > 0
      && this.clientId.length > 0 && this.systemId.length > 0;
  }
}

const STORE_NAME = 'uu_viewer_credentials';

export class CredentialStore {
  private static store: preferences.Preferences | undefined = undefined;

  static async init(context: Context): Promise<void> {
    if (CredentialStore.store === undefined) {
      try {
        CredentialStore.store = await preferences.getPreferences(context, STORE_NAME);
      } catch (e) {
        // preferences unavailable: credentials stay in memory
      }
    }
  }

  static async load(): Promise<Credentials> {
    const store = CredentialStore.store;
    const creds = new Credentials();
    if (store === undefined) {
      return creds;
    }
    const get = (key: string): string => {
      try {
        const v = store.getSync(key, '');
        return typeof v === 'string' ? v : '';
      } catch (e) {
        return '';
      }
    };
    creds.userId = get('user_id');
    creds.deviceId = get('device_id');
    creds.clientId = get('client_id');
    creds.systemId = get('system_id');
    creds.token = get('token');
    creds.csrf = get('csrf');
    creds.signKey = get('sign_key');
    creds.accountName = get('account_name');
    return creds;
  }

  static async save(creds: Credentials): Promise<void> {
    const store = CredentialStore.store;
    if (store === undefined) {
      return;
    }
    try {
      await store.put('user_id', creds.userId);
      await store.put('device_id', creds.deviceId);
      await store.put('client_id', creds.clientId);
      await store.put('system_id', creds.systemId);
      await store.put('token', creds.token);
      await store.put('csrf', creds.csrf);
      await store.put('sign_key', creds.signKey);
      await store.put('account_name', creds.accountName);
      await store.flush();
    } catch (e) {
      // persistence failed: credentials stay in memory for this session
    }
  }

  static async clear(): Promise<void> {
    const store = CredentialStore.store;
    if (store === undefined) {
      return;
    }
    try {
      await store.clear();
      await store.flush();
    } catch (e) {
      // persistence failed
    }
  }
}
