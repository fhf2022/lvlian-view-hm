export class UgreenSession {
  baseUrl: string
  tokenId: string
  token: string
  uid: string
  publicKey: string

  constructor(baseUrl: string, tokenId: string, token: string, uid: string, publicKey: string) {
    this.baseUrl = baseUrl
    this.tokenId = tokenId
    this.token = token
    this.uid = uid
    this.publicKey = publicKey
  }
}
