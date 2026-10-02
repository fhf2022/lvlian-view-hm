export interface ContextPreviewRect {
  x: number
  y: number
  width: number
  height: number
}

export class ContextMenuPreviewLayout {
  x: number = 26
  y: number = 0
  width: number = 324
  height: number = 58
  scale: number = 1
  menuHeight: number = 540

  /** All coordinates are vp relative to the persistent menu anchor's page. */
  static fit(tile: boolean, rect: ContextPreviewRect | null, fallback: ContextPreviewRect,
    viewportWidth: number, viewportHeight: number, safeTop: number, safeBottom: number,
    naturalMenuHeight: number): ContextMenuPreviewLayout {
    const result = new ContextMenuPreviewLayout()
    const pageWidth = Number.isFinite(viewportWidth) && viewportWidth > 0 ? viewportWidth : 360
    const pageHeight = Number.isFinite(viewportHeight) && viewportHeight > 0 ? viewportHeight : 800
    const margin = Math.min(12, pageWidth / 8, pageHeight / 8)
    const top = Math.min(pageHeight - margin, Math.max(margin,
      Number.isFinite(safeTop) ? safeTop + 8 : margin))
    const bottom = Math.max(top + 1, pageHeight - Math.max(margin,
      Number.isFinite(safeBottom) ? safeBottom + 8 : margin))
    const availableHeight = bottom - top
    result.scale = tile ? 1.05 : 1
    const validRect = rect !== null && Number.isFinite(rect.x) && Number.isFinite(rect.y) &&
      Number.isFinite(rect.width) && Number.isFinite(rect.height) && rect.width > 0 && rect.height > 0 &&
      rect.x < pageWidth && rect.x + rect.width > 0 && rect.y < bottom && rect.y + rect.height > top
    const source = validRect ? rect as ContextPreviewRect : fallback
    const sourceWidth = tile ? Math.max(1, source.width) : Math.min(324, Math.max(1, pageWidth - 52))
    const sourceHeight = tile ? Math.max(1, source.height) : 58
    // Fit the whole tile; never crop a tall WaterFlow card into a square.
    // Reserve room for a scrollable menu, including the final native scale.
    const maxWidth = Math.max(1, pageWidth - 2 * margin) / result.scale
    const maxHeight = tile ? Math.min(320, availableHeight * 0.34) / result.scale
      : availableHeight / result.scale
    const sizeScale = Math.min(1, maxWidth / sourceWidth, maxHeight / sourceHeight)
    result.width = sourceWidth * sizeScale
    result.height = sourceHeight * sizeScale
    const halfWidth = result.width * result.scale / 2
    const halfHeight = result.height * result.scale / 2
    const centerX = tile ? source.x + source.width / 2 : 26 + result.width / 2
    // A partially visible long card should lift from its visible portion.
    const visibleTop = Math.max(top, source.y)
    const visibleBottom = Math.min(bottom, source.y + source.height)
    const centerY = tile ? (visibleTop + visibleBottom) / 2 : fallback.y + 29
    result.x = Math.max(margin + halfWidth, Math.min(pageWidth - margin - halfWidth, centerX)) -
      result.width / 2
    result.y = Math.max(top + halfHeight, Math.min(bottom - halfHeight, centerY)) - result.height / 2
    result.menuHeight = Math.min(Math.max(1, naturalMenuHeight),
      Math.max(1, availableHeight - result.height * result.scale - 24))
    return result
  }
}
