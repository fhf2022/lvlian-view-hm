import { NetworkClass } from '../core/network/NetworkPolicy'
import { NasConnection } from '../core/network/NasConnection'
import { TransferBackgroundManager } from './TransferBackgroundManager'
import { DownloadTaskStatus } from '../model/FileEntry'

/** One admission rule for ordinary and ranged user downloads. */
export class TransferRunPolicy {
  static waiting(ready: boolean, network: NetworkClass, mobileAllowed: boolean,
    needsNetwork: boolean = true): DownloadTaskStatus | '' {
    if (!ready) { return 'paused' }
    if (!TransferBackgroundManager.shared().canRun()) { return 'queued' }
    if (!needsNetwork) { return '' }
    if (!NasConnection.shared().canRequest()) { return 'waiting_server' }
    if (network === 'offline' || (network !== 'unmetered' && !mobileAllowed)) { return 'waiting_wifi' }
    return ''
  }
}
