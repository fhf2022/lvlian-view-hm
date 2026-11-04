// Image.onComplete geometry shared by thumbnail cells and Viewer.
export interface ImageLoadCompleteEvent {
  width: number
  height: number
  componentWidth: number
  componentHeight: number
  loadingStatus: number
  contentWidth: number
  contentHeight: number
  contentOffsetX: number
  contentOffsetY: number
}
