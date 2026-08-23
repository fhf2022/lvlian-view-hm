import { UgreenSession } from '../../model/Session'

export class SessionStore {
  private session: UgreenSession | null = null

  set(value: UgreenSession): void {
    this.session = value
  }

  get(): UgreenSession | null {
    return this.session
  }

  clear(): void {
    this.session = null
  }
}
