/** Window sizes and results are in vp; no device-type or fold-service queries. */
export class FileGridLayout {
  static readonly gap: number = 1
  static readonly cellPadding: number = 1
  private static readonly maxColumns: number = 7
  private static readonly targetVisibleImages: number = 36
  private static readonly minimumThumbnailWidth: number = 80

  static cellWidth(width: number, columns: number): number {
    return (width - (columns - 1) * FileGridLayout.gap) / columns
  }

  static thumbnailWidth(width: number, columns: number): number {
    return FileGridLayout.cellWidth(width, columns) - 2 * FileGridLayout.cellPadding
  }

  // File cards share the photo grid's square geometry, but use bounded icon
  // and label sizes rather than stretching artwork or tiny fixed labels.
  static fileIconSize(cellWidth: number): number {
    return Math.max(36, Math.min(88, (cellWidth - 2 * FileGridLayout.cellPadding) * 0.4))
  }

  static fileLabelFontSize(cellWidth: number): number {
    return Math.max(12, Math.min(14, cellWidth * 0.07))
  }

  static columns(width: number, height: number): number {
    if (!Number.isFinite(width) || width <= 0) { return 2 }
    // The minimum is a narrow-window safeguard, not a fixed size for tablets.
    const fitting = Math.floor((width + FileGridLayout.gap) /
      (FileGridLayout.minimumThumbnailWidth + 2 * FileGridLayout.cellPadding + FileGridLayout.gap) + 1e-9)
    const limit = Math.max(2, Math.min(FileGridLayout.maxColumns, fitting))
    if (!Number.isFinite(height) || height <= 0) { return limit }
    // For square thumbnails, columns² × height / width estimates the number
    // on screen. One window-based rule serves rotation, folding and multiwindow;
    // no device type, display orientation or remembered layout is needed.
    const target = Math.round(Math.sqrt(FileGridLayout.targetVisibleImages * width / height))
    return Math.max(2, Math.min(limit, target))
  }
}
