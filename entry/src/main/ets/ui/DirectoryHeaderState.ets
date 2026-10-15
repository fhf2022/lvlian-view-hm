/** The title and leading control describe one directory, including during a staged transition. */
export class DirectoryHeaderState {
  path: string
  title: string
  hasBack: boolean

  constructor(path: string, personal: boolean) {
    this.path = path
    this.title = path.length > 0 ? path : (personal ? '个人空间' : '共享空间')
    this.hasBack = path.length > 0
  }
}
