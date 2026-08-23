export enum UgreenErrorKind {
  NETWORK = 'NETWORK',
  AUTH_EXPIRED = 'AUTH_EXPIRED',
  LOGIN_FAILED = 'LOGIN_FAILED',
  OTP_REQUIRED = 'OTP_REQUIRED',
  PERMISSION_DENIED = 'PERMISSION_DENIED',
  NOT_FOUND = 'NOT_FOUND',
  API_CHANGED = 'API_CHANGED',
  UNKNOWN = 'UNKNOWN'
}

export class UgreenError extends Error {
  kind: UgreenErrorKind
  status: number
  apiCode: number

  constructor(kind: UgreenErrorKind, message: string, status: number = 0, apiCode: number = 0) {
    super(message)
    this.name = 'UgreenError'
    this.kind = kind
    this.status = status
    this.apiCode = apiCode
  }
}

export function readableUgreenError(error: Object): string {
  if (error instanceof UgreenError) {
    return error.message
  }
  return '操作失败，请稍后重试'
}
