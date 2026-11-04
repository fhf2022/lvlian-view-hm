import { FileEntry } from './FileEntry'

/** Confirmed direct-child changes; shared by live rows and saved navigation snapshots. */
export class DirectoryChange {
  path: string
  additions: FileEntry[] = []
  removals: string[] = []
  constructor(path: string) { this.path = path }

  static apply(entries: FileEntry[], change: DirectoryChange): FileEntry[] {
    const removed = new Set<string>(change.removals)
    const paths = new Set<string>()
    const next: FileEntry[] = []
    for (const entry of entries) {
      if (removed.has(entry.path)) { continue }
      paths.add(entry.path)
      next.push(entry)
    }
    for (const entry of change.additions) {
      if (entry.path.length === 0 || paths.has(entry.path)) { continue }
      paths.add(entry.path)
      next.push(entry)
    }
    return next
  }
}
