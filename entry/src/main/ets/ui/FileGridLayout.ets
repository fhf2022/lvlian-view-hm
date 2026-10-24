/** Window sizes and results are in vp; no device-type or fold-service queries. */
export class FileGridLayout {
  static readonly gap: number = 1
  static readonly cellPadding: number = 1
  private static readonly maxColumns: number = 10
  private static readonly largeWindowShortEdge: number = 600
  private static readonly largeThumbnailMinimum: number = 140

  private static compactColumns(width: number): number {
    return Math.max(2, Math.min(FileGridLayout.maxColumns, Math.floor(width / 80)))
  }

  static thumbnailWidth(width: number, columns: number): number {
    return (width - (columns - 1) * FileGridLayout.gap) / columns - 2 * FileGridLayout.cellPadding
  }

  static columns(width: number, height: number): number {
    if (!Number.isFinite(width) || width <= 0) { return 2 }
    const compact = FileGridLayout.compactColumns(width)
    // Preserve phone, outer-screen and narrow split-window behaviour,
    // including a phone's wide but short landscape window.
    if (!Number.isFinite(height) || Math.min(width, height) < FileGridLayout.largeWindowShortEdge) {
      return compact
    }
    const longEdge = Math.max(width, height)
    const landscapeReference = FileGridLayout.thumbnailWidth(longEdge,
      FileGridLayout.compactColumns(longEdge))
    // A near-square unfolded screen has no meaningful landscape reference:
    // the vp floor prevents it from falling back to ten tiny columns.
    const minimum = Math.max(FileGridLayout.largeThumbnailMinimum, landscapeReference)
    const fitting = Math.floor((width + FileGridLayout.gap) /
      (minimum + 2 * FileGridLayout.cellPadding + FileGridLayout.gap) + 1e-9)
    return Math.max(2, Math.min(compact, fitting))
  }
}
