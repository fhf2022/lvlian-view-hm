import { FileGridRow } from '../model/FileGridRows'
import { FileEntry } from '../model/FileEntry'
import { FileGridLayout } from '../ui/FileGridLayout'

@Builder
function EmptyRowCell(_entry: FileEntry, _index: number): void { Blank() }

/** Observe row membership so filling a partial final row retains its old cells. */
@Component
export struct FileGridRowView {
  @ObjectLink row: FileGridRow
  @BuilderParam cell: (entry: FileEntry, index: number) => void = EmptyRowCell
  build() {
    Row({ space: FileGridLayout.gap }) {
      ForEach(this.row.entries, (entry: FileEntry, column: number) => {
        this.cell(entry, this.row.start + column)
      }, (entry: FileEntry): string => entry.path)
    }.width('100%').alignItems(VerticalAlign.Top)
  }
}
