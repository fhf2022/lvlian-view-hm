import { FileEntry } from './FileEntry'

export interface FileOperationState {
  id: string
  complete: boolean
  failed: boolean
}

export class PendingFileOperation {
  id: string = ''
  scope: string = ''
  entries: FileEntry[] = []
  target: string = ''
  move: boolean = false
  rootType: number = 3
  existingTargets: Set<string> = new Set<string>()
  startedAt: number = Date.now()
  missingChecks: number = 0
  affectedPaths: Set<string> = new Set<string>()
}
