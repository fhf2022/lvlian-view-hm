import { connection } from '@kit.NetworkKit'

export type NetworkClass = 'unmetered' | 'metered' | 'offline' | 'unknown'

export type NetworkStateListener = (state: NetworkClass) => void

/**
 * Centralizes the network classification used by automatic media loading.
 * A network is considered safe for background/original loading only when the
 * system explicitly reports that it is not metered. Unknown is deliberately
 * conservative and is treated as metered by callers.
 */
export class NetworkPolicy {
  private static instance: NetworkPolicy | null = null
  private monitor: connection.NetConnection | null = null
  private listeners: NetworkStateListener[] = []
  private initializePromise: Promise<void> | null = null
  private state: NetworkClass = 'unknown'

  static shared(): NetworkPolicy {
    if (NetworkPolicy.instance === null) {
      NetworkPolicy.instance = new NetworkPolicy()
    }
    return NetworkPolicy.instance
  }

  current(): NetworkClass {
    return this.state
  }

  isMetered(): boolean {
    return this.state === 'metered' || this.state === 'unknown'
  }

  isUnmetered(): boolean {
    return this.state === 'unmetered'
  }

  displayName(): string {
    switch (this.state) {
      case 'unmetered':
        return 'WiFi'
      case 'metered':
        return '移动网络'
      case 'offline':
        return '无网络'
      default:
        return '网络状态未知'
    }
  }

  async initialize(): Promise<void> {
    if (this.initializePromise === null) {
      this.initializePromise = this.openMonitor()
    }
    await this.initializePromise
  }

  onChange(listener: NetworkStateListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener)
    }
  }

  private async openMonitor(): Promise<void> {
    try {
      this.monitor = connection.createNetConnection()
      this.monitor.on('netAvailable', () => {
        this.refresh()
      })
      this.monitor.on('netLost', () => {
        this.updateState('offline')
      })
      this.monitor.on('netCapabilitiesChange', () => {
        this.refresh()
      })
      this.monitor.on('netBlockStatusChange', () => {
        this.refresh()
      })
      this.monitor.register((): void => {})
    } catch (error) {
      console.warn('[NetworkPolicy] monitor unavailable: ' + JSON.stringify(error))
    }
    await this.refresh()
  }

  async refresh(): Promise<NetworkClass> {
    try {
      const netHandle = await connection.getDefaultNet()
      if (netHandle.netId === 0) {
        this.updateState('offline')
        return this.state
      }
      const metered = await connection.isDefaultNetMetered()
      let notMetered = false
      let bearerTypes: connection.NetBearType[] = []
      try {
        const capabilities = await connection.getNetCapabilities(netHandle)
        const networkCaps = capabilities.networkCap === undefined ? [] : capabilities.networkCap
        notMetered = networkCaps.indexOf(connection.NetCap.NET_CAPABILITY_NOT_METERED) >= 0
        bearerTypes = capabilities.bearerTypes === undefined ? [] : capabilities.bearerTypes
      } catch (error) {
        console.warn('[NetworkPolicy] capabilities unavailable: ' + JSON.stringify(error))
      }

      // "Metered" describes billing policy, not the physical transport.
      // A Wi-Fi network can be marked as metered by the system, so using only
      // isDefaultNetMetered() incorrectly displayed Wi-Fi as mobile data.
      const isWifi = bearerTypes.indexOf(connection.NetBearType.BEARER_WIFI) >= 0
      const isEthernet = bearerTypes.indexOf(connection.NetBearType.BEARER_ETHERNET) >= 0
      const isCellular = bearerTypes.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0
      if (isWifi || isEthernet) {
        this.updateState('unmetered')
      } else if (isCellular) {
        this.updateState('metered')
      } else {
        this.updateState(metered === false || notMetered ? 'unmetered' : 'metered')
      }
    } catch (error) {
      this.updateState('unknown')
      console.warn('[NetworkPolicy] refresh failed: ' + JSON.stringify(error))
    }
    return this.state
  }

  private updateState(next: NetworkClass): void {
    if (next === this.state) {
      return
    }
    this.state = next
    for (const listener of this.listeners.slice()) {
      try {
        listener(next)
      } catch (error) {
        console.warn('[NetworkPolicy] listener failed: ' + JSON.stringify(error))
      }
    }
  }
}
