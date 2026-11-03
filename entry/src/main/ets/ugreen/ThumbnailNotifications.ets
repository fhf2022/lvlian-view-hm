import { webSocket } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { BusinessError } from '@kit.BasicServicesKit'
import { JsonObject } from '../core/network/HttpTypes'

/** One authenticated UGOS notification channel per session, not per image. */
export class ThumbnailNotifications {
  private socket: webSocket.WebSocket | null = null
  private connecting: Promise<boolean> | null = null
  private settle: ((ready: boolean) => void) | null = null
  private connectTimer: number = 0
  private heartbeatTimer: number = 0
  private connected: boolean = false
  private foreground: boolean = true
  private retryAfter: number = 0
  private sequence: number = 0
  private clientId: string = util.generateRandomUUID(true)
  private ids: Map<string, string> = new Map()
  private paths: Map<string, string> = new Map()
  private listener: ((path: string) => void) | null = null

  setListener(listener: ((path: string) => void) | null): void { this.listener = listener }
  isConnected(): boolean { return this.connected }

  setForeground(value: boolean): void {
    this.foreground = value
    if (!value) { this.stop() }
  }

  forgetPending(): void { this.ids.clear(); this.paths.clear() }

  complete(path: string, expectedId: string = ''): void {
    const id = this.ids.get(path)
    if (expectedId.length > 0 && id !== expectedId) { return }
    if (id !== undefined) { this.paths.delete(id); this.ids.delete(path) }
  }

  requestHeaders(path: string): Record<string, string> {
    let id = this.ids.get(path)
    if (id === undefined) {
      if (this.ids.size >= 256) {
        const oldest = Array.from(this.ids.keys())[0]
        this.complete(oldest)
      }
      id = this.clientId + ':' + (++this.sequence).toString()
      this.ids.set(path, id)
      this.paths.set(id, path)
    }
    return { 'Thumb-ID': id, 'App-ID': 'com.ugreen.filemgr', 'Client-ID': this.clientId }
  }

  async ensure(baseUrl: string, headers: Record<string, string>): Promise<boolean> {
    if (!this.foreground) { return false }
    if (this.connected) { return true }
    if (this.connecting !== null) { return await this.connecting }
    if (Date.now() < this.retryAfter) { return false }
    const socket = webSocket.createWebSocket()
    this.socket = socket
    const pending = new Promise<boolean>((resolve): void => {
      this.settle = (ready: boolean): void => {
        if (this.connectTimer > 0) { clearTimeout(this.connectTimer); this.connectTimer = 0 }
        this.settle = null
        resolve(ready)
      }
      socket.on('open', (): void => {
        if (this.socket !== socket) { return }
        this.connected = true
        if (this.settle !== null) { this.settle(true) }
        // UGOS keeps its desktop channel alive with subscription snapshots.
        this.sendHeartbeat(socket)
        this.heartbeatTimer = setInterval((): void => this.sendHeartbeat(socket), 30000)
        console.info('[UgreenThumbnailWS] connected')
      })
      socket.on('message', (_error: BusinessError, value: string | ArrayBuffer): void => {
        if (this.socket === socket && typeof value === 'string') { this.receive(value) }
      })
      socket.on('close', (): void => { if (this.socket === socket) { this.stop(); this.retryAfter = Date.now() + 5000 } })
      socket.on('error', (): void => { if (this.socket === socket) { this.stop(); this.retryAfter = Date.now() + 5000 } })
      this.connectTimer = setTimeout((): void => {
        if (this.socket === socket && !this.connected) { this.stop(); this.retryAfter = Date.now() + 5000 }
      }, 2000)
      const url = baseUrl.replace(/^http/, 'ws') + '/ugreen/v1/desktop/ws?client_id=' +
        encodeURIComponent(this.clientId) + '&lang=zh-CN'
      socket.connect(url, { header: headers }).catch((): void => {
        if (this.socket === socket) { this.stop(); this.retryAfter = Date.now() + 5000 }
      })
    })
    this.connecting = pending
    try { return await pending }
    finally { if (this.connecting === pending) { this.connecting = null } }
  }

  private sendHeartbeat(socket: webSocket.WebSocket): void {
    if (this.socket !== socket || !this.connected) { return }
    socket.send('{"type":"subscribe","msg":""}').catch((): void => {})
  }

  private receive(text: string): void {
    // Ignore system resource/heartbeat traffic before JSON parsing.
    if (text.length > 262144 || text.indexOf('thumbnail-done') < 0) { return }
    try {
      const frame = JSON.parse(text) as JsonObject
      const data = frame['data'] as JsonObject
      if (!data || data['event'] !== 'thumbnail-done') { return }
      const body = data['body'] as JsonObject
      if (!body || !Array.isArray(body['list'])) { return }
      const items = body['list'] as JsonObject[]
      let matched = 0
      for (const item of items.slice(0, 256)) {
        const id = item['thumb_id']
        if (typeof id !== 'string') { continue }
        const path = this.paths.get(id)
        if (path !== undefined && this.listener !== null) { this.listener(path); matched++ }
      }
      if (matched > 0) { console.info('[UgreenThumbnailWS] ready=' + matched.toString()) }
    } catch (_) { /* Unrelated/malformed notifications never fail file browsing. */ }
  }

  stop(): void {
    const socket = this.socket
    this.socket = null
    this.connected = false
    this.connecting = null
    if (this.settle !== null) { this.settle(false) }
    if (this.heartbeatTimer > 0) { clearInterval(this.heartbeatTimer); this.heartbeatTimer = 0 }
    this.forgetPending()
    if (socket !== null) {
      socket.off('open'); socket.off('message'); socket.off('close'); socket.off('error')
      socket.close().catch((): void => {})
    }
  }

  reset(): void {
    this.stop()
    this.clientId = util.generateRandomUUID(true)
    this.retryAfter = 0
  }
}
