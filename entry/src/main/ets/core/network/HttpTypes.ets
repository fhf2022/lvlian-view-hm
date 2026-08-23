export type JsonObject = Record<string, Object>

export class HttpResult<T> {
  status: number = 0
  body: T
  headers: Record<string, string> = {}

  constructor(body: T, status: number, headers: Record<string, string>) {
    this.body = body
    this.status = status
    this.headers = headers
  }
}
