@Observed
export class FileSelectionState {
  selected: boolean = false
}

/** Selection belongs to the file page, separately from thumbnail state. */
export class FileSelectionModel {
  private selected: Set<string> = new Set<string>()
  private states: Map<string, FileSelectionState> = new Map<string, FileSelectionState>()
  private snapshot: Set<string> = new Set<string>()
  private rangePaths: string[] = []
  private anchor: number = -1
  private endpoint: number = -1

  stateFor(path: string): FileSelectionState {
    let state = this.states.get(path)
    if (state === undefined) {
      state = new FileSelectionState()
      state.selected = this.selected.has(path)
      this.states.set(path, state)
    }
    return state
  }

  has(path: string): boolean {
    return this.selected.has(path)
  }

  paths(): string[] {
    return Array.from(this.selected)
  }

  count(): number {
    return this.selected.size
  }

  replace(paths: string[]): void {
    this.endRange()
    const next = new Set<string>(paths)
    for (const path of this.selected) {
      if (!next.has(path)) {
        this.setSelected(path, false)
      }
    }
    for (const path of next) {
      this.setSelected(path, true)
    }
  }

  toggle(path: string): void {
    this.setSelected(path, !this.selected.has(path))
  }

  beginRange(anchor: number, orderedPaths: string[]): void {
    this.endRange()
    if (anchor < 0 || anchor >= orderedPaths.length) {
      return
    }
    this.anchor = anchor
    this.rangePaths = orderedPaths.slice()
    this.snapshot = new Set<string>(this.selected)
  }

  /** XOR the inclusive interval with the state before this gesture. */
  extendRange(target: number): boolean {
    if (this.anchor < 0 || target < 0 || target >= this.rangePaths.length || target === this.endpoint) {
      return false
    }
    const from = Math.min(this.anchor, target)
    const to = Math.max(this.anchor, target)
    if (this.endpoint < 0) {
      this.updateInterval(from, to, from, to)
    } else {
      const oldFrom = Math.min(this.anchor, this.endpoint)
      const oldTo = Math.max(this.anchor, this.endpoint)
      // Only the two moving edges change. Retracing restores the snapshot;
      // staying on a cell never toggles it repeatedly.
      this.updateInterval(Math.min(from, oldFrom), Math.max(from, oldFrom) - 1, from, to)
      this.updateInterval(Math.min(to, oldTo) + 1, Math.max(to, oldTo), from, to)
    }
    this.endpoint = target
    return true
  }

  endRange(): void {
    this.anchor = -1
    this.endpoint = -1
    this.rangePaths = []
    this.snapshot.clear()
  }

  private updateInterval(start: number, end: number, from: number, to: number): void {
    for (let index = start; index <= end; index++) {
      const path = this.rangePaths[index]
      const inRange = index >= from && index <= to
      this.setSelected(path, this.snapshot.has(path) !== inRange)
    }
  }

  private setSelected(path: string, value: boolean): void {
    if (this.selected.has(path) === value) {
      return
    }
    if (value) {
      this.selected.add(path)
    } else {
      this.selected.delete(path)
    }
    const state = this.states.get(path)
    if (state !== undefined) {
      state.selected = value
    }
  }
}
