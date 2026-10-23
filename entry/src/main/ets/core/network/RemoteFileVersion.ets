/** Shared by sequential and ranged downloads; no extra metadata requests. */
export class RemoteFileVersion {
  static changed(oldSize: number, oldEtag: string, oldChecksum: string,
    size: number, etag: string, checksum: string): boolean {
    return (oldSize > 0 && size > 0 && oldSize !== size) ||
      (oldEtag.length > 0 && etag.length > 0 && oldEtag !== etag) ||
      (oldChecksum.length > 0 && checksum.length > 0 && oldChecksum !== checksum)
  }

  static strongEtag(etag: string): string {
    return etag.startsWith('W/') ? '' : etag
  }

  // HTTP dates can validate Range when no ETag exists. Keep a conservative
  // clock margin; a fresh/future/invalid date must never authorize an append.
  static fromHeaders(headers: Record<string, string>): string {
    const etag = RemoteFileVersion.header(headers, 'etag')
    if (etag.length > 0) { return RemoteFileVersion.strongEtag(etag) }
    const modified = RemoteFileVersion.header(headers, 'last-modified')
    const date = RemoteFileVersion.header(headers, 'date')
    const modifiedAt = Date.parse(modified)
    const responseAt = Date.parse(date)
    return /^[A-Za-z]{3}, \d{2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/.test(modified) && Number.isFinite(modifiedAt) && Number.isFinite(responseAt) &&
      responseAt - modifiedAt >= 60000 ? modified : ''
  }

  static matches(validator: string, headers: Record<string, string>): boolean {
    if (validator.length === 0) { return false }
    const field = /^[A-Za-z]{3}, /.test(validator) ? 'last-modified' : 'etag'
    return RemoteFileVersion.header(headers, field) === validator
  }

  private static header(headers: Record<string, string>, name: string): string {
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() === name) { return headers[key] }
    }
    return ''
  }
}
