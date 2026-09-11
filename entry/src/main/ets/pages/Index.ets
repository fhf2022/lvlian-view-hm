import { StorageBudget } from '../download/StorageBudget'
import { DownloadDestination } from '../download/DownloadDestination'
import { promptAction, uiMaterial, curves, window, LengthMetrics, FrameCallback, PiPWindow } from '@kit.ArkUI'
import { systemShare, harmonyShare } from '@kit.ShareKit'
import { Context, Want, common, wantConstant } from '@kit.AbilityKit'
import { fileIo, fileUri, picker } from '@kit.CoreFileKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { FloatingImportControl } from '../components/FloatingImportControl'
import { ProximityLightReceiver } from '../components/ProximityLightReceiver'
import { UploadQueueManager, UploadTaskRecord } from '../upload/UploadQueueManager'
import { preferences, uniformTypeDescriptor as utd } from '@kit.ArkData'
import { image } from '@kit.ImageKit'
import { media } from '@kit.MediaKit'
import { AVCastPicker, AVCastPickerState, avSession } from '@kit.AVSessionKit'
import { visionImageAnalyzer } from '@kit.VisionKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { DownloadTaskRecord, FileEntry } from '../model/FileEntry'
import { CacheManager } from '../download/CacheManager'
import { DownloadQueueManager } from '../download/DownloadQueueManager'
import { UserFileManager } from '../download/UserFileManager'
import { AudioPlaybackManager } from '../media/AudioPlaybackManager'
import { VideoPlaybackManager } from '../media/VideoPlaybackManager'
import {
  VideoCastPlaybackSnapshot,
  VideoMediaPlaybackSnapshot,
  VideoMediaSessionManager
} from '../media/VideoMediaSessionManager'
import { VideoBackgroundTaskManager } from '../media/VideoBackgroundTaskManager'
import { VideoSourceHandle, VideoTransferManager, VideoTransferState } from '../media/VideoTransferManager'
import { MediaPreviewManager } from '../media/MediaPreviewManager'
import { ImageRotationRecord, ImageRotationStore } from '../media/ImageRotationStore'
import { RemoteSearchScope, UgreenRemoteRepository } from '../repository/UgreenRemoteRepository'
import { BinaryDownloadProgress, BinaryProgressListener } from '../core/network/HttpTransport'
import { UgreenError, readableUgreenError } from '../ugreen/UgreenErrors'
import { FileEntryDataSource } from '../model/FileEntryDataSource'
import { PreviewLoadQueue } from '../media/PreviewLoadQueue'
import { ThumbnailPolicy, ThumbnailSize } from '../media/ThumbnailPolicy'
import { ThumbnailCacheStore } from '../media/ThumbnailCacheStore'
import { ViewerBitmapRecord, ViewerBitmapStore } from '../media/ViewerBitmapStore'
import { NetworkClass, NetworkPolicy } from '../core/network/NetworkPolicy'

type RemoteScreen = 'login' | 'otp' | 'files' | 'downloads' | 'settings'
type RootKind = 'personal' | 'shared'
type BottomTab = 'home' | 'shared' | 'downloads' | 'settings'
type PageTransitionDirection = 'push' | 'pop'
type FileViewMode = 'list' | 'grid' | 'waterfall'
type FileSortKey = 'name' | 'type' | 'time' | 'size'
type SearchReturnMode = 'none' | 'directory' | 'image' | 'audio' | 'video' | 'download'
type FileAction = 'share' | 'openWith' | 'quickView' | 'multiSelect' | 'download' |
  'saveGallery' | 'releaseCache' | 'rename' | 'details' | 'delete' | 'copy' | 'move'
type DestinationOperation = 'copy' | 'move'

// Shared-element transitions are deliberately separate from the 180 ms
// Swiper animation.  The image should have enough time to travel from its
// file-row frame to the viewer without delaying network/decode work.
const IMAGE_GEOMETRY_TRANSITION_DURATION: number = 420
const IMAGE_FALLBACK_TRANSITION_DURATION: number = 160
const IMAGE_RETURN_MOUNT_FRAME_LIMIT: number = 8
const IMAGE_VIEWER_DIAGNOSTICS: boolean = true
const IMAGE_VIEWER_HILOG_DOMAIN: number = 0xD003
const IMAGE_VIEWER_HILOG_TAG: string = 'ImageViewerDiag'
// Pull-to-dismiss is deliberately a short, proportional gesture. The
// threshold is calculated from the viewer height so it remains usable on
// portrait and landscape windows without changing the image layout.
const IMAGE_DISMISS_TRIGGER_RATIO: number = 0.20
const IMAGE_DISMISS_FAST_TRIGGER_VELOCITY: number = 900
const IMAGE_DISMISS_FAST_TRIGGER_DISTANCE: number = 42
const IMAGE_DISMISS_MAX_SCALE_REDUCTION: number = 0.28
// HarmonyOS bottom-tab examples use a 56vp bar on phone-sized breakpoints.
// Keep the custom glass capsules on the same 8vp grid and only adapt their
// distance from the navigation-indicator avoid area across window heights.
const FLOATING_BAR_HEIGHT_VP: number = 56
/** Room above the visible bar for native material shadow and deformation. */
const FLOATING_BAR_EFFECT_TOP_INSET_VP: number = 20
const FLOATING_BAR_MIN_GAP_VP: number = 8
const FLOATING_BAR_MAX_GAP_VP: number = 16
const FLOATING_BAR_CONTENT_EXTRA_VP: number = 32
const FILE_TOOL_HEIGHT_VP: number = 40
// 底栏胶囊宽度随按钮数量自适应：每个页签 82vp，4 项 = 328vp（对齐示例里
// "按钮少就收窄"的做法）。文件详情页中间的排序胶囊沿用原来的 140vp。
const BOTTOM_BAR_ITEM_WIDTH_VP: number = 82
const BOTTOM_BAR_MAX_ITEMS: number = 4
const FILE_TOOL_SORT_WIDTH_VP: number = 140

interface ViewerReturnScrollOffset {
  xOffset: number
  yOffset: number
}

class DestinationEntry {
  name: string = ''
  path: string = ''
  modifiedTime: number = 0
  childCount: number = -1
}

class DestinationTreeRow {
  entry: DestinationEntry = new DestinationEntry()
  depth: number = 0
  expanded: boolean = false
  loading: boolean = false
}

interface PopupStateChange {
  isVisible: boolean
}

interface ViewerImageCompleteEvent {
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

type ViewerImageLayer = 'thumbnail' | 'original'
type ViewerDecodeState = 'idle' | 'loading' | 'decoded' | 'displayed' | 'failed'
type ViewerTransitionKind = 'none' | 'entry' | 'exit'
type ThumbnailSurfaceKind = 'none' | 'list' | 'grid' | 'waterfall' | 'search'

class ImageVisualState {
  thumbnailUri: string = ''
  thumbnailSignature: string = ''
  transitionThumbnailUri: string = ''
  originalUri: string = ''
  thumbnailOrientation: ImageRotateOrientation = ImageRotateOrientation.AUTO
  originalOrientation: ImageRotateOrientation = ImageRotateOrientation.AUTO
  userRotation: number = 0
  rotationResolved: boolean = false
  physicalWidth: number = 0
  physicalHeight: number = 0
  exifDisplayWidth: number = 0
  exifDisplayHeight: number = 0
  displayWidth: number = 0
  displayHeight: number = 0
  thumbnailDisplayWidth: number = 0
  thumbnailDisplayHeight: number = 0
  frameWidth: number = 0
  frameHeight: number = 0
  frameLocked: boolean = false
  decodeState: ViewerDecodeState = 'idle'
  visibleLayer: ViewerImageLayer = 'thumbnail'
  progress: number = 0
  progressKnown: boolean = false
  thumbnailIndex: number = -1
  thumbnailSurface: ThumbnailSurfaceKind = 'none'
  thumbnailVisibleRatio: number = 0
  thumbnailX: number = 0
  thumbnailY: number = 0
  thumbnailWidth: number = 0
  thumbnailHeight: number = 0
  // The URI that completed decoding on the currently mounted file-page Image.
  // Keeping this separate from transitionThumbnailUri prevents a recycled
  // WaterFlow item from being accepted merely because its old area survived.
  thumbnailDecodedUri: string = ''
}

class ViewerImageGeometry {
  physicalWidth: number = 0
  physicalHeight: number = 0
  exifDisplayWidth: number = 0
  exifDisplayHeight: number = 0
  displayWidth: number = 0
  displayHeight: number = 0
  orientation: ImageRotateOrientation = ImageRotateOrientation.AUTO
}

class ViewerFrameCallback extends FrameCallback {
  private action: () => void

  constructor(action: () => void) {
    super()
    this.action = action
  }

  onFrame(_frameTimeInNano: number): void {
    this.action()
  }

  onIdle(_timeLeftInNano: number): void {
  }
}

interface SearchSession {
  query: string
  scope: RemoteSearchScope
  results: FileEntry[]
  loading: boolean
  historyExpanded: boolean
  scrollOffset: number
  originPath: string
  originRootType: number
  originEntries: FileEntry[]
  originNavigationStack: string[]
  originNavigationEntryStack: FileEntry[][]
  originNavigationRootTypeStack: number[]
  originNavigationViewStateStack: DirectoryViewState[]
  originViewState: DirectoryViewState
  originPageIndex: number
  originPageHasMore: boolean
  originPageIndexStack: number[]
  originPageHasMoreStack: boolean[]
  targetParentPath: string
  targetNavigationDepth: number
  returnMode: SearchReturnMode
}

interface SearchResultSnapshot {
  query: string
  scope: RemoteSearchScope
  results: FileEntry[]
  loading: boolean
  scrollOffset: number
}

interface VisibleDirectoryPageSet {
  entries: FileEntry[]
  pageIndex: number
  hasMore: boolean
  totalCount: number
}

interface FileViewAnchor {
  path: string
  y: number
}

interface DirectoryViewState {
  mode: FileViewMode
  offset: ViewerReturnScrollOffset | null
  anchor: FileViewAnchor | null
}

// The file surface underneath a video is kept as the PiP restore destination.
// A user may browse other tabs/directories while PiP is active; restoring must
// therefore put the player back over the directory that launched it, rather
// than whatever page happened to be visible when the system restore button was
// pressed.
interface VideoPipOrigin {
  screen: RemoteScreen
  selectedBottomTab: BottomTab
  rootKind: RootKind
  currentPath: string
  currentRootType: number
  entries: FileEntry[]
  navigationStack: string[]
  navigationEntryStack: FileEntry[][]
  navigationRootTypeStack: number[]
  navigationViewStateStack: DirectoryViewState[]
  navigationPageIndexStack: number[]
  navigationPageHasMoreStack: boolean[]
  currentPageIndex: number
  currentPageHasMore: boolean
  viewState: DirectoryViewState
  topTitle: string
  topTitleOpacity: number
}

interface GestureTransferSelection {
  entries: FileEntry[]
  skippedCount: number
}

interface GestureTransferCacheResult {
  entries: FileEntry[]
  localPaths: Record<string, string>
  failedCount: number
}

class ImageDisplayState {
  rotations: Record<string, number> = {}
  previewOrientations: Record<string, ImageRotateOrientation> = {}
}

@Entry
@Component
struct Index {
  @State screen: RemoteScreen = 'login'
  @State linkId: string = 'dxp4800-0a6c'
  @State username: string = ''
  @State password: string = ''
  @State otpCode: string = ''
  @State baseUrl: string = ''
  @State statusText: string = ''
  @State errorText: string = ''
  @State isBusy: boolean = false
  @State trustDevice: boolean = false
  @State autoLogin: boolean = false
  @State rememberPassword: boolean = false
  @State silentAutoLogin: boolean = false
  @State rootKind: RootKind = 'personal'
  @State selectedBottomTab: BottomTab = 'home'
  @State currentPath: string = ''
  @State topTitle: string = '个人空间'
  @State topTitleOpacity: number = 1
  @State currentRootType: number = 4
  @State entries: FileEntry[] = []
  @State personalRoots: FileEntry[] = []
  @State sharedRoots: FileEntry[] = []
  @State navigationStack: string[] = []
  @State cacheLimitBytes: number = CacheManager.DEFAULT_LIMIT_BYTES
  @State cacheUsageBytes: number = 0
  @State persistentUsageBytes: number = 0
  @State networkClass: NetworkClass = 'unknown'
  @State meteredAutoOriginal: boolean = false
  @State meteredBackgroundRefresh: boolean = false
  @State meteredDownloadContinue: boolean = false
  @State downloadTasks: DownloadTaskRecord[] = []
  @State downloadSpeedBytesPerSecond: number = 0
  @State contextMenuVisible: boolean = false
  @State contextMenuEntry: FileEntry | null = null
  @State contextMenuSourceY: number = 0
  @State showDestinationPicker: boolean = false
  @State destinationOperation: DestinationOperation = 'copy'
  @State destinationPath: string = ''
  @State destinationEntries: DestinationEntry[] = []
  @State destinationTreeRows: DestinationTreeRow[] = []
  @State destinationExpandedPaths: string[] = []
  @State destinationTreeLoadingPath: string = ''
  @State destinationRootExpanded: boolean = true
  @State destinationLoading: boolean = false
  @State destinationPickerClosing: boolean = false
  @State destinationSelectedEntries: FileEntry[] = []
  @State destinationFolderDialog: boolean = false
  @State destinationFolderText: string = ''
  @State selectionMode: boolean = false
  @State selectedPaths: string[] = []
  @State selectedEntryCount: number = 0
  @State showSelectionMoreMenu: boolean = false
  @State renameEntry: FileEntry | null = null
  @State renameText: string = ''
  @State showRenameDialog: boolean = false
  @State showStorageSettings: boolean = false
  @State showNetworkSettings: boolean = false
  @State showPlaybackSettings: boolean = false
  @State showImageViewer: boolean = false
  @State viewerImageEntry: FileEntry | null = null
  @State viewerHeaderTitle: string = ''
  @State viewerImages: FileEntry[] = []
  @State viewerImageIndex: number = 0
  // More/details keep an explicit snapshot of the committed image. The
  // overlay must never silently switch to another file underneath the user.
  @State viewerOverlayEntry: FileEntry | null = null
  @State showImageMoreMenu: boolean = false
  @State showImageDetails: boolean = false
  @State viewerLastNavigationDirection: number = 1
  @State imageVisualStates: Record<string, ImageVisualState> = {}
  @State imageAnalyzerTypes: ImageAnalyzerType[] = []
  @State imageAnalyzerSupported: boolean = false
  @State imageScale: number = 1
  @State imageSavedScale: number = 1
  @State imageOffsetX: number = 0
  @State imageOffsetY: number = 0
  @State imageSavedOffsetX: number = 0
  @State imageSavedOffsetY: number = 0
  @State imageChromeVisible: boolean = true
  @State imageChromeOpacity: number = 1
  @State imageTopChromeOffsetY: number = 0
  @State imageBottomChromeOffsetY: number = 0
  @State imageViewportWidthVp: number = 360
  @State imageViewportHeightVp: number = 600
  // These are render transforms for the unzoomed pull-to-dismiss gesture.
  // They are kept separate from imageScale/imageOffset so pinch-zoom and
  // horizontal Swiper navigation keep their existing state machine.
  @State imageDismissScale: number = 1
  @State imageDismissOffsetY: number = 0
  @State imageDismissBackdropOpacity: number = 1
  @State viewerSurfaceOpacity: number = 1
  // The entry animation is limited to the image that was tapped. The normal
  // viewer swiper animation uses viewerTransitionActive and remains separate.
  @State viewerEntryTransitionActive: boolean = false
  @State viewerEntryTransitionPath: string = ''
  @State viewerTransitionKind: ViewerTransitionKind = 'none'
  @State viewerTransitionLayer: ViewerImageLayer = 'thumbnail'
  @State viewerGeometryBound: boolean = false
  @State viewerFallbackEntryActive: boolean = false
  // Keep the viewer capsule size stable across device rotation. Only its
  // bottom-safe-area position should be recalculated by the new layout.
  @State viewerBottomBarWidthVp: number = 0
  @State viewerTransitionActive: boolean = false
  @State showAudioPlayer: boolean = false
  @State audioEntry: FileEntry | null = null
  @State audioLocalPath: string = ''
  @State audioPlaying: boolean = false
  @State audioCurrentMs: number = 0
  @State audioDurationMs: number = 0
  // Playback preferences are kept separate from cache/network settings so
  // each settings page has one responsibility.
  @State backgroundVideoPlayback: boolean = true
  @State backgroundAudioPlayback: boolean = true
  @State videoBackgroundAutoPip: boolean = false
  @State autoPlayOnOpen: boolean = true
  @State showVideoPlayer: boolean = false
  @State videoEntry: FileEntry | null = null
  @State videoSourceKey: string = ''
  @State videoLocalPath: string = ''
  @State videoDurationMs: number = 0
  @State videoCurrentMs: number = 0
  @State videoPlaying: boolean = false
  @State videoMuted: boolean = false
  @State videoPrepared: boolean = false
  @State videoFirstFrame: boolean = false
  @State videoSurfaceReady: boolean = false
  @State videoOrientationChanging: boolean = false
  @State videoLandscape: boolean = false
  @State videoControlPending: boolean = false
  @State videoWidthPx: number = 0
  @State videoHeightPx: number = 0
  @State videoBufferingPercent: number = 0
  @State videoPipActive: boolean = false
  @State videoPipBackgrounded: boolean = false
  @State videoPipCreating: boolean = false
  @State videoCasting: boolean = false
  @State videoTransferStates: Record<string, VideoTransferState> = {}
  @State previewCanonicalPaths: Record<string, boolean> = {}
  @State waterfallOriginalUris: Record<string, string> = {}
  // PixelMap source changes are committed on a render frame.  The epoch is
  // intentionally the only reactive value; native PixelMap objects stay in
  // the private store and are never copied through @State records.
  @State viewerBitmapEpoch: number = 0
  @State waterfallAspectRatios: Record<string, number> = {}
  @State waterfallVisiblePaths: Record<string, boolean> = {}
  @State waterfallColumnWidthVp: number = 0
  @State directoryCounts: Record<string, number> = {}
  @State pageOffsetX: number = 0
  @State outgoingPageOffsetX: number = 0
  @State pageWidthVp: number = 360
  @State pageHeightVp: number = 800
  @State transferDirection: string = 'download'
  @State uploadTasks: UploadTaskRecord[] = []
  @State importExpanded: boolean = false
  @State importSelecting: boolean = false
  private uploadQueue: UploadQueueManager = new UploadQueueManager()
  @State showPageTransition: boolean = false
  @State outgoingEntries: FileEntry[] = []
  @State showSearch: boolean = false
  @State searchQuery: string = ''
  @State searchScope: RemoteSearchScope = 'current'
  @State searchResults: FileEntry[] = []
  @State searchLoading: boolean = false
  @State searchHistory: string[] = []
  @State searchHistoryExpanded: boolean = false
  @State fileViewMode: FileViewMode = 'list'
  // This is derived from the metadata already loaded for the current
  // directory. It deliberately does not trigger a second directory scan.
  @State currentDirectoryHasImages: boolean = false
  @State fileSortKey: FileSortKey = 'time'
  @State fileSortAscending: boolean = false
  @State showFileSortMenu: boolean = false
  @State showCreateFolderDialog: boolean = false
  @State newFolderText: string = ''
  @State bottomBarOffsetY: number = 0
  @State bottomBarOpacity: number = 1
  @StorageProp('statusBarHeightPx') statusBarHeightPx: number = 0
  @StorageProp('navigationBarHeightPx') navigationBarHeightPx: number = 0
  @StorageProp('isDarkTheme') isDarkTheme: boolean = false
  @StorageProp('abilityInBackground') @Watch('onAbilityBackgroundChanged')
  abilityInBackground: boolean = false
  private repository: UgreenRemoteRepository = new UgreenRemoteRepository()
  private networkPolicy: NetworkPolicy = NetworkPolicy.shared()
  private downloadQueue: DownloadQueueManager = new DownloadQueueManager()
  private audioManager: AudioPlaybackManager = new AudioPlaybackManager()
  private videoPlaybackManager: VideoPlaybackManager = new VideoPlaybackManager()
  private videoMediaSession: VideoMediaSessionManager = new VideoMediaSessionManager()
  private videoBackgroundTask: VideoBackgroundTaskManager = new VideoBackgroundTaskManager()
  private videoTransferManager: VideoTransferManager = new VideoTransferManager()
  private videoSurfaceController: XComponentController = new XComponentController()
  private videoSourceHandle: VideoSourceHandle | null = null
  private videoOpenToken: number = 0
  private videoPositionPersistAt: number = 0
  private videoWasPlayingBeforeHide: boolean = false
  private playbackBackgroundActive: boolean = false
  // XComponent surface dimensions are physical pixels. Keep the last layout
  // area in vp so a window rotation can recompute a centered, aspect-preserved
  // surface without stretching the decoded video frame.
  private videoViewportWidthVp: number = 0
  private videoViewportHeightVp: number = 0
  private videoSurfaceWidthPx: number = 0
  private videoSurfaceHeightPx: number = 0
  private videoPipController: PiPWindow.PiPController | null = null
  private videoPipOrigin: VideoPipOrigin | null = null
  private videoPipHideOnStart: boolean = false
  // startPiP/stopPiP resolve asynchronously and the platform can deliver the
  // state callback on a later turn. Keep explicit in-flight guards so a fast
  // second tap cannot issue a second command against the same controller.
  private videoPipStarting: boolean = false
  private videoPipStopping: boolean = false
  private videoPipRestorePending: boolean = false
  private videoPipRestoreScheduled: boolean = false
  private videoPipRestoring: boolean = false
  private videoPipStateChange = (state: PiPWindow.PiPState, reason: string): void => {
    this.handleVideoPipStateChange(state, reason)
  }
  private videoPipControlEvent = (event: PiPWindow.PiPActionEventType,
    status?: number): void => {
    this.handleVideoPipControlEvent(event, status)
  }
  private videoCastPreparing: boolean = false
  private videoWasPlayingBeforeCast: boolean = false
  private videoPlayerWindow: window.Window | null = null
  private videoPlayerPreviousOrientation: window.Orientation | null = null
  private videoOrientationToken: number = 0
  // System-bar changes are asynchronous. Serialize them so a sensor callback
  // cannot finish after a close/portrait request and hide the bars again.
  private videoSystemBarsLandscape: boolean | null = null
  private videoSystemBarsQueue: Promise<void> = Promise.resolve()
  private videoSystemBarsToken: number = 0
  private videoWindowSizeChange = (size: window.Size): void => {
    if (!this.showVideoPlayer || size.width <= 0 || size.height <= 0) {
      return
    }
    // Window.Size is reported in physical pixels. The XComponent area callback
    // remains the source of the exact vp dimensions used by the surface, but
    // this event lets the controls switch orientation as soon as the window
    // has committed a sensor rotation.
    this.videoLandscape = size.width > size.height
    const win = this.videoPlayerWindow
    if (win !== null) {
      this.setVideoSystemBars(win, this.videoLandscape).catch((error: Error): void => {
        console.warn('[UgreenVideo] sync system bars after window rotation failed: ' +
          JSON.stringify(error))
      })
    }
    this.updateVideoSurfaceRect()
  }
  private videoMediaSessionPositionAt: number = 0
  private mediaPreviewManager: MediaPreviewManager = new MediaPreviewManager()
  private viewerBitmapStore: ViewerBitmapStore = new ViewerBitmapStore()
  private viewerPreviewBitmaps: Record<string, ViewerBitmapRecord> = {}
  private viewerPreviewBitmapAliases: Record<string, boolean> = {}
  private viewerOriginalBitmaps: Record<string, ViewerBitmapRecord> = {}
  private viewerOriginalLocalPaths: Record<string, string> = {}
  private fileThumbnailBitmaps: Record<string, ViewerBitmapRecord> = {}
  private fileThumbnailDecodeKeys: Record<string, string> = {}
  private waterfallBitmaps: Record<string, ViewerBitmapRecord> = {}
  private imageRotationStore: ImageRotationStore = new ImageRotationStore()
  private imageAnalyzerController: visionImageAnalyzer.VisionImageAnalyzerController =
    new visionImageAnalyzer.VisionImageAnalyzerController()
  // Keep the already rendered parent pages so system/back navigation does not
  // need to round-trip to the NAS again.
  private navigationEntryStack: FileEntry[][] = []
  private navigationRootTypeStack: number[] = []
  private navigationViewStateStack: DirectoryViewState[] = []
  private navigationPageIndexStack: number[] = []
  private navigationPageHasMoreStack: boolean[] = []
  private destinationPathStack: string[] = []
  private destinationChildrenByPath: Map<string, DestinationEntry[]> = new Map<string, DestinationEntry[]>()
  private destinationLoadToken: number = 0
  private destinationTreeRequestToken: number = 0
  private destinationPickerCloseToken: number = 0
  private pendingContextAction: (() => void) | null = null
  private fileEntryDataSource: FileEntryDataSource = new FileEntryDataSource()
  private waterfallDataSource: FileEntryDataSource = new FileEntryDataSource()
  private viewerImageDataSource: FileEntryDataSource = new FileEntryDataSource()
  private fileListScroller: Scroller = new Scroller()
  private waterfallScroller: Scroller = new Scroller()
  // Keep the exact offset of the file surface below ImageViewer so returning
  // from a preview does not recreate list/grid/waterfall at position zero.
  private viewerReturnScrollOffset: ViewerReturnScrollOffset | null = null
  private viewerReturnScrollPath: string = ''
  private viewerReturnScrollMode: FileViewMode = 'list'
  // WaterFlow's sliding window can rebuild item coordinates when its root is
  // temporarily removed by the viewer. Keep the first visible image as a
  // stable return anchor in addition to the raw offset.
  private viewerReturnScrollAnchor: FileViewAnchor | null = null
  private searchResultScroller: Scroller = new Scroller()
  private searchSession: SearchSession | null = null
  private searchScrollOffset: number = 0
  private searchResultCache: Record<string, SearchResultSnapshot> = {}
  private transitionScroller: Scroller = new Scroller()
  private previewRequests: Record<string, boolean> = {}
  private previewLocalPaths: Record<string, string> = {}
  private previewQueue: PreviewLoadQueue = new PreviewLoadQueue(
    ThumbnailPolicy.LIST_MAX_CONCURRENT, ThumbnailPolicy.MAX_PENDING_TASKS)
  private previewUriOrder: string[] = []
  private currentPageIndex: number = 1
  private currentPageHasMore: boolean = false
  private loadingNextPage: boolean = false
  private directoryCountRequests: Record<string, boolean> = {}
  private directoryCountTimers: Record<string, number> = {}
  private previewGeneration: number = 0
  private waterfallGeneration: number = 0
  private waterfallEntries: FileEntry[] = []
  private waterfallDownloadQueue: FileEntry[] = []
  private waterfallDecodeQueue: FileEntry[] = []
  private waterfallLocalPaths: Record<string, string> = {}
  private waterfallDownloadRequests: Record<string, boolean> = {}
  private waterfallActiveDownloadPaths: Record<string, boolean> = {}
  private waterfallActiveDecodePaths: Record<string, boolean> = {}
  private waterfallDecodedPaths: Record<string, boolean> = {}
  private waterfallActiveDownloads: number = 0
  private waterfallActiveDecodes: number = 0
  private waterfallAnchor: FileViewAnchor | null = null
  private waterfallAnchorRestoreToken: number = 0
  private fileVisibleStartIndex: number = 0
  private fileVisibleEndIndex: number = 0
  private waterfallVisibleStartIndex: number = 0
  private waterfallVisibleEndIndex: number = 0
  private fileListRotationGeneration: number = 0
  private navigationRequestId: number = 0
  private isNavigating: boolean = false
  private titleAnimationToken: number = 0
  private pageTransitionToken: number = 0
  private pageTransitionTimer: number = 0
  private bottomBarAnimationToken: number = 0
  private imageChromeAnimationToken: number = 0
  private viewerEntryTransitionToken: number = 0
  private viewerClosePending: boolean = false
  private viewerCloseRequested: boolean = false
  private viewerReturnReadyPath: string = ''
  private viewerRevealTokens: Record<string, number> = {}
  private viewerPendingBitmapReveals: Record<string, boolean> = {}
  private viewerPendingRotationPath: string = ''
  private viewerDiagnosticSequence: number = 0
  private lastImageDoubleTapAt: number = 0
  private imageTouchActive: boolean = false
  private imageTouchMoved: boolean = false
  private imageTouchStartX: number = 0
  private imageTouchStartY: number = 0
  private imageDismissDragging: boolean = false
  private imageDismissChromeWasVisible: boolean = true
  private viewerSwiperController: SwiperController = new SwiperController()
  private viewerLoadQueue: FileEntry[] = []
  private viewerLoadRequests: Record<string, boolean> = {}
  private viewerGeneration: number = 0
  private viewerActiveLoads: number = 0
  private viewerMaxConcurrentLoads: number = 1
  private viewerActiveLoadPaths: Record<string, boolean> = {}
  private viewerManualLoadPaths: Record<string, boolean> = {}
  private viewerPrimaryPath: string = ''
  private viewerPendingIndex: number = -1
  private viewerProgressLastUpdateAt: Record<string, number> = {}
  private imageViewerWindow: window.Window | null = null
  private imageViewerPreviousOrientation: window.Orientation | null = null
  private imageViewerRotationToken: number = 0
  private imageViewerWindowSizeChange = (_size: window.Size): void => {
    if (!this.showImageViewer) {
      return
    }
    // The Image/Swiper area reports the final vp size through onAreaChange.
    // Clamp the current zoom after that layout pass so a portrait-to-landscape
    // change cannot leave the image outside the new viewport.
    setTimeout((): void => {
      if (this.showImageViewer) {
        this.normalizeImageTransform()
      }
    }, 0)
  }
  private cachePreferences: preferences.Preferences | null = null
  private networkPreferences: preferences.Preferences | null = null
  private playbackPreferences: preferences.Preferences | null = null
  private loginPreferences: preferences.Preferences | null = null
  private searchPreferences: preferences.Preferences | null = null
  private cacheDirectory: string = ''
  private thumbnailDirectory: string = ''
  private thumbnailCacheLimitBytes: number = ThumbnailCacheStore.DEFAULT_LIMIT_BYTES
  private cacheStatePromise: Promise<void> | null = null
  private networkStatePromise: Promise<void> | null = null
  private loginStatePromise: Promise<void> | null = null
  private searchStatePromise: Promise<void> | null = null
  private playbackStatePromise: Promise<void> | null = null
  private imageRotationStatePromise: Promise<void> | null = null
  private downloadStatePromise: Promise<void> | null = null
  private videoStatePromise: Promise<void> | null = null
  private searchTimer: number = 0
  private searchGeneration: number = 0
  private errorDialogShowing: boolean = false
  private networkStateListener = (state: NetworkClass): void => {
    this.networkClass = state
    if ((state === 'metered' || state === 'unknown') && !this.meteredAutoOriginal) {
      this.stopQueuedViewerAutoLoads()
    }
    if (state === 'unmetered' && this.showImageViewer) {
      this.prefetchViewerImages(this.viewerImageIndex)
    }
  }
  private downloadStateListener = (tasks: DownloadTaskRecord[], speed: number): void => {
    this.downloadTasks = tasks.concat(this.videoTransferManager.snapshotTasks())
    this.downloadSpeedBytesPerSecond = speed
  }
  private videoTransferStateListener = (states: VideoTransferState[]): void => {
    const next: Record<string, VideoTransferState> = {}
    for (const state of states) {
      next[state.sourceKey] = state
    }
    this.videoTransferStates = next
    this.downloadTasks = this.downloadQueue.snapshot().concat(this.videoTransferManager.snapshotTasks())
  }
  private gestureShareRegistered: boolean = false
  private gestureShareRegistering: boolean = false
  private gestureShareLifecycleToken: number = 0
  private gestureShareCapability: harmonyShare.SendCapabilityRegistry | null = null
  private gestureShareCallback = (target: harmonyShare.SharableTarget): void => {
    this.handleGestureShare(target)
  }
  private bottomCapsuleMaterial: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    colorInvert: true,
    applyShadow: true,
    interactive: true,
    lightEffect: { color: '#66FFFFFF' }
  })
  aboutToAppear(): void {
    this.statusText = ''
    this.configureImageAnalyzer()
    this.ensureCacheState()
    this.ensureNetworkState()
    this.ensureDownloadState()
    this.ensurePlaybackState()
    this.ensureVideoState()
    this.loginStatePromise = this.loadLoginPreferences()
    this.searchStatePromise = this.loadSearchPreferences()
    this.ensureImageRotationState()
    this.enableGestureShare()
  }

  aboutToDisappear(): void {
    this.closeVideoPlayer()
    this.releaseImageAnalyzer()
    this.disableGestureShare()
  }

  private configureImageAnalyzer(): void {
    try {
      const supportTypes = this.imageAnalyzerController.getImageAnalyzerSupportTypes()
      const enabledTypes: ImageAnalyzerType[] = []
      for (const type of supportTypes) {
        if ((type === ImageAnalyzerType.TEXT ||
          type === ImageAnalyzerType.SUBJECT ||
          type === ImageAnalyzerType.OBJECT_LOOKUP) && enabledTypes.indexOf(type) < 0) {
          enabledTypes.push(type)
        }
      }
      this.imageAnalyzerTypes = enabledTypes
      this.imageAnalyzerSupported = enabledTypes.length > 0
      console.info('[UgreenImageAnalyzer] supportTypes=' + JSON.stringify(enabledTypes))
    } catch (error) {
      this.imageAnalyzerTypes = []
      this.imageAnalyzerSupported = false
      console.warn('[UgreenImageAnalyzer] capability check failed: ' + JSON.stringify(error))
    }
  }

  private releaseImageAnalyzer(): void {
    try {
      this.imageAnalyzerController.setImageAnalyzerVisibility(
        visionImageAnalyzer.ImageAnalyzerVisibility.HIDDEN)
    } catch (error) {
      console.warn('[UgreenImageAnalyzer] hide failed: ' + JSON.stringify(error))
    }
  }

  onPageHide(): void {
    this.handlePlaybackBackgroundState(true)
    this.updateVideoMediaSession(true)
  }

  onPageShow(): void {
    this.handlePlaybackBackgroundState(false)
    this.scheduleVideoPipRestore()
    if (this.showVideoPlayer) {
      // Refresh the system card when the page is visible again without issuing
      // a duplicate play command.
      this.updateVideoMediaSession(true)
    }
  }

  onAbilityBackgroundChanged(): void {
    this.handlePlaybackBackgroundState(this.abilityInBackground)
    if (!this.abilityInBackground) {
      this.scheduleVideoPipRestore()
    }
  }

  private scheduleVideoPipRestore(): void {
    if (!this.videoPipRestorePending || this.abilityInBackground ||
      this.videoPipRestoreScheduled) {
      return
    }
    this.videoPipRestoreScheduled = true
    this.postRenderFrame((): void => {
      this.videoPipRestoreScheduled = false
      if (!this.videoPipRestorePending || this.abilityInBackground ||
        !this.showVideoPlayer) {
        return
      }
      this.videoPipRestorePending = false
      this.videoPipRestoring = false
      this.restoreVideoPipOrigin()
      this.videoPipBackgrounded = false
      this.updateBottomBarVisibility(true)
      this.updateVideoMediaSession(true)
    })
  }

  private handlePlaybackBackgroundState(isBackground: boolean): void {
    if (this.playbackBackgroundActive === isBackground) {
      return
    }
    this.playbackBackgroundActive = isBackground
    if (!isBackground) {
      this.videoWasPlayingBeforeHide = false
      return
    }

    this.videoWasPlayingBeforeHide = this.showVideoPlayer && this.videoPlaying
    // Explicit PiP is already a background playback mode. Do not let the
    // page-hide callback immediately pause the same player while the system
    // is transferring its surface into the PiP window.
    if (this.showVideoPlayer && this.videoPlaying && !this.backgroundVideoPlayback &&
      !this.videoPipActive && !this.videoPipBackgrounded) {
      // A forced background pause is still routed through the same local/cast
      // control path as the system media-session pause command.
      this.pauseVideoFromMediaSession(true)
    } else if (this.showVideoPlayer && this.videoWasPlayingBeforeHide &&
      this.backgroundVideoPlayback && this.videoBackgroundAutoPip && !this.videoCasting &&
      !this.videoPipActive && !this.videoPipBackgrounded) {
      this.toggleVideoPip().catch((error: Object): void => {
        console.warn('[UgreenVideo] automatic background PiP failed: ' + JSON.stringify(error))
      })
    }

    if (this.showAudioPlayer && this.audioPlaying && !this.backgroundAudioPlayback) {
      this.audioManager.pause().then((): void => {
        if (this.playbackBackgroundActive) {
          this.audioPlaying = false
        }
      }).catch((error: Object): void => {
        console.warn('[UgreenAudio] background pause failed: ' + JSON.stringify(error))
      })
    }
  }

  /**
   * Register the official HarmonyOS one-grab-one-release sender callback.
   * The callback is kept for the lifetime of this page, but it only accepts
   * content while an image viewer or a file multi-selection is active.
   * HarmonyOS owns the gesture affordance and transfer animation; the app
   * supplies only a local SharedData payload.
   */
  private enableGestureShare(): void {
    if (this.gestureShareRegistered || this.gestureShareRegistering ||
      !canIUse('SystemCapability.Collaboration.HarmonyShare')) {
      return
    }
    this.gestureShareRegistering = true
    const token = this.gestureShareLifecycleToken + 1
    this.gestureShareLifecycleToken = token
    const context = getContext(this) as common.UIAbilityContext
    window.getLastWindow(context).then((win: window.Window): void => {
      if (token !== this.gestureShareLifecycleToken) {
        this.gestureShareRegistering = false
        return
      }
      try {
        const capability: harmonyShare.SendCapabilityRegistry = {
          windowId: win.getWindowProperties().id,
          sendOnly: true
        }
        harmonyShare.on('gesturesShare', capability, this.gestureShareCallback)
        this.gestureShareCapability = capability
        this.gestureShareRegistered = true
      } catch (error) {
        console.warn('[UgreenShare] register gesturesShare failed: ' + JSON.stringify(error))
      }
      this.gestureShareRegistering = false
    }).catch((error: Error): void => {
      this.gestureShareRegistering = false
      console.warn('[UgreenShare] get share window failed: ' + JSON.stringify(error))
    })
  }

  private disableGestureShare(): void {
    this.gestureShareLifecycleToken += 1
    this.gestureShareRegistering = false
    if (!this.gestureShareRegistered) {
      return
    }
    try {
      if (this.gestureShareCapability !== null) {
        harmonyShare.off('gesturesShare', this.gestureShareCapability, this.gestureShareCallback)
      } else {
        harmonyShare.off('gesturesShare', this.gestureShareCallback)
      }
    } catch (error) {
      console.warn('[UgreenShare] unregister gesturesShare failed: ' + JSON.stringify(error))
    }
    this.gestureShareCapability = null
    this.gestureShareRegistered = false
  }

  private gestureShareCandidates(): FileEntry[] {
    if (this.showImageViewer && this.viewerImageEntry !== null) {
      return [this.viewerImageEntry]
    }
    if (this.selectionMode) {
      return this.selectedEntriesInCurrentDirectory()
    }
    return []
  }

  private async rejectGestureShare(target: harmonyShare.SharableTarget,
    code: harmonyShare.SharableErrorCode): Promise<void> {
    try {
      await target.reject(code)
    } catch (error) {
      console.warn('[UgreenShare] reject failed: ' + JSON.stringify(error))
    }
  }

  private async filterGestureTransferEntries(entries: FileEntry[]): Promise<GestureTransferSelection> {
    await this.ensureNetworkState()
    await this.ensureCacheState()
    const allowed: FileEntry[] = []
    let skippedCount = 0
    for (const entry of entries) {
      // The gesture API transfers records, not remote directory trees.
      if (entry.isDirectory) {
        skippedCount += 1
        continue
      }
      let cachedPath = CacheManager.findExisting(this.cacheDirectory, entry.name,
        this.originalCacheKey(entry))
      if (this.isVideo(entry)) {
        try {
          await this.refreshVideoManager()
          cachedPath = await this.videoTransferManager.resolveLocal(entry)
        } catch (_) {
          cachedPath = ''
        }
      }
      if (cachedPath.length > 0 || this.networkClass === 'unmetered') {
        allowed.push(entry)
        continue
      }
      if (this.networkClass === 'offline') {
        skippedCount += 1
        continue
      }
      // Unknown and cellular networks are controlled by the existing settings:
      // original images use the image switch, all other files use the download
      // continuation switch. Cached files above remain available offline.
      const canDownload = this.isImage(entry)
        ? this.meteredAutoOriginal : this.meteredDownloadContinue
      if (canDownload) {
        allowed.push(entry)
      } else {
        skippedCount += 1
      }
    }
    return { entries: allowed, skippedCount: skippedCount }
  }

  private async cacheGestureEntries(entries: FileEntry[]): Promise<GestureTransferCacheResult> {
    const localPaths: Record<string, string> = {}
    let failedCount = 0
    let nextIndex = 0
    const worker = async (): Promise<void> => {
      while (true) {
        const index = nextIndex
        nextIndex += 1
        if (index >= entries.length) {
          return
        }
        const entry = entries[index]
        try {
          const localPath = await this.ensureCachedFile(entry)
          if (CacheManager.exists(localPath)) {
            localPaths[entry.path] = localPath
          } else {
            failedCount += 1
          }
        } catch (error) {
          failedCount += 1
          console.warn('[UgreenShare] cache file failed: ' + entry.name + ' ' + JSON.stringify(error))
        }
      }
    }
    const workerCount = Math.min(2, entries.length)
    const workers: Promise<void>[] = []
    for (let index = 0; index < workerCount; index += 1) {
      workers.push(worker())
    }
    await Promise.all(workers)
    const cachedEntries = entries.filter((entry: FileEntry): boolean => {
      return typeof localPaths[entry.path] === 'string' && localPaths[entry.path].length > 0
    })
    return { entries: cachedEntries, localPaths: localPaths, failedCount: failedCount }
  }

  private gestureShareThumbnailUri(entry: FileEntry): string {
    const previewPath = this.previewLocalPaths[entry.path]
    if (typeof previewPath !== 'string' || previewPath.length === 0 ||
      !CacheManager.exists(previewPath)) {
      return ''
    }
    return fileUri.getUriFromPath(previewPath)
  }

  private async handleGestureShare(target: harmonyShare.SharableTarget): Promise<void> {
    let shareRequested = false
    try {
      const candidates = this.gestureShareCandidates()
      if (this.isBusy || candidates.length === 0) {
        await this.rejectGestureShare(target, harmonyShare.SharableErrorCode.NO_CONTENT_ERROR)
        return
      }
      const selection = await this.filterGestureTransferEntries(candidates)
      if (selection.entries.length === 0) {
        await this.rejectGestureShare(target, harmonyShare.SharableErrorCode.NO_CONTENT_ERROR)
        return
      }

      // SharedData supports at most 500 records. This is the platform limit,
      // not an app-defined size/count threshold.
      const transferEntries = selection.entries.length > 500
        ? selection.entries.slice(0, 500) : selection.entries
      const thumbnailUri = this.gestureShareThumbnailUri(transferEntries[0])
      if (thumbnailUri.length > 0) {
        try {
          await target.updateShareData({ thumbnailUri: thumbnailUri })
        } catch (error) {
          console.warn('[UgreenShare] update preview failed: ' + JSON.stringify(error))
        }
      }

      this.isBusy = true
      this.errorText = ''
      this.statusText = '正在准备隔空传送…'
      const cached = await this.cacheGestureEntries(transferEntries)
      if (cached.entries.length === 0) {
        await this.rejectGestureShare(target, harmonyShare.SharableErrorCode.DOWNLOAD_ERROR)
        this.reportError(new Error('没有可传输的本地文件'), '隔空传送失败')
        return
      }

      const sharedData = new systemShare.SharedData(this.shareRecord(
        cached.entries[0], cached.localPaths[cached.entries[0].path]))
      for (let index = 1; index < cached.entries.length; index += 1) {
        const entry = cached.entries[index]
        sharedData.addRecord(this.shareRecord(entry, cached.localPaths[entry.path]))
      }
      shareRequested = true
      await target.share(sharedData)
      this.statusText = ''
      if (selection.skippedCount > 0 || cached.failedCount > 0 ||
        cached.entries.length < transferEntries.length) {
        console.info('[UgreenShare] skipped files: ' +
          (selection.skippedCount + cached.failedCount).toString())
      }
    } catch (error) {
      console.warn('[UgreenShare] gesturesShare failed: ' + JSON.stringify(error))
      if (!shareRequested) {
        await this.rejectGestureShare(target, harmonyShare.SharableErrorCode.DOWNLOAD_ERROR)
      }
      this.reportError(error as Object, '隔空传送失败')
      this.statusText = '隔空传送失败'
    } finally {
      this.isBusy = false
    }
  }

  private enableImageViewerAutoRotation(): void {
    const token = this.imageViewerRotationToken + 1
    this.imageViewerRotationToken = token
    const context = getContext(this) as common.UIAbilityContext
    window.getLastWindow(context).then((win: window.Window): void => {
      if (token !== this.imageViewerRotationToken || !this.showImageViewer) {
        return
      }
      try {
        this.imageViewerWindow = win
        if (this.imageViewerPreviousOrientation === null) {
          this.imageViewerPreviousOrientation = win.getPreferredOrientation()
          win.on('windowSizeChange', this.imageViewerWindowSizeChange)
        }
        // Official restricted auto-rotation follows the motion sensor only
        // when the system rotation lock allows it.
        win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED)
          .catch((error: Error) => {
            console.warn('[UgreenImage] enable auto rotation failed: ' + JSON.stringify(error))
          })
      } catch (error) {
        console.warn('[UgreenImage] prepare auto rotation failed: ' + JSON.stringify(error))
      }
    }).catch((error: Error) => {
      console.warn('[UgreenImage] get image viewer window failed: ' + JSON.stringify(error))
    })
  }

  private restoreImageViewerOrientation(): void {
    const token = this.imageViewerRotationToken + 1
    this.imageViewerRotationToken = token
    const win = this.imageViewerWindow
    const previous = this.imageViewerPreviousOrientation
    this.imageViewerWindow = null
    this.imageViewerPreviousOrientation = null
    if (win === null) {
      return
    }
    try {
      win.off('windowSizeChange', this.imageViewerWindowSizeChange)
      if (previous !== null) {
        win.setPreferredOrientation(previous).catch((error: Error) => {
          console.warn('[UgreenImage] restore orientation failed: ' + JSON.stringify(error))
        })
      }
    } catch (error) {
      console.warn('[UgreenImage] release auto rotation failed: ' + JSON.stringify(error))
    }
  }

  private topSafeInset(): number {
    return this.getUIContext().px2vp(this.statusBarHeightPx)
  }

  // The video surface is already laid out edge-to-edge. Once landscape video
  // hides the status bar, retaining the portrait avoid-area inset would leave
  // a visible empty strip above the controls while the window is rotating.
  private videoTopInset(): number {
    return this.videoLandscape ? 0 : this.topSafeInset()
  }

  private videoBottomInset(): number {
    return this.videoLandscape ? 0 : this.bottomSafeInset()
  }

  // All file view modes share the same content origin below the common
  // TopFileOverlay. Keeping this in one helper prevents WaterFlow from
  // drifting away from the list/grid header geometry.
  private fileContentTopInset(): number {
    return this.topSafeInset() + 76
  }

  private bottomSafeInset(): number {
    return this.getUIContext().px2vp(this.navigationBarHeightPx)
  }

  // 底栏底边到屏幕底边的距离。对齐系统「智慧生活」的悬浮底栏：直接贴导航条
  // 安全区，不再额外留浮动间距（本机实测两者都是 28vp，底栏高同为 56vp）。
  private floatingBarBottomMargin(): number {
    return this.bottomSafeInset()
  }

  private floatingBarContentInset(extra: number = FLOATING_BAR_CONTENT_EXTRA_VP): number {
    return this.floatingBarBottomMargin() + FLOATING_BAR_HEIGHT_VP + extra
  }

  private shouldShowBottomBar(): boolean {
    if (this.showSearch) {
      return false
    }
    if (this.screen === 'downloads') {
      return true
    }
    if (this.screen === 'settings') {
      return !this.showStorageSettings && !this.showPlaybackSettings && !this.showNetworkSettings
    }
    if (this.screen !== 'files') {
      return false
    }
    if (this.currentPath.length === 0) {
      return true
    }
    const accountName = this.username.trim().replace(/^\/+|\/+$/g, '')
    if (accountName.length === 0) {
      return false
    }
    const normalizedPath = this.currentPath.replace(/\/+$/, '').toLowerCase()
    return normalizedPath === ('/home/' + accountName).toLowerCase()
  }

  // 底栏只有三种形态，共用一个常驻外壳：
  //   home      = 导航胶囊（主页/共享/下载/设置）
  //   selection = 多选操作胶囊（分享/复制/删除/更多）
  //   tools     = 文件详情页（左圆钮 + 中间排序胶囊 + 右圆钮）
  // 三层内容全部常驻、只改 opacity/translate，材质胶囊不会重建，因此切换不闪。
  private bottomBarMode(): string {
    if (this.selectionMode) {
      return 'selection'
    }
    if (this.shouldShowFileToolsBar()) {
      return 'tools'
    }
    return 'home'
  }

  // 任一形态需要显示时，外壳就应该在位（隐藏靠 updateBottomBarVisibility 位移）。
  private shouldShowAnyBottomBar(): boolean {
    return this.shouldShowBottomBar() || this.selectionMode || this.shouldShowFileToolsBar()
  }

  // The whole parent page stays mounted behind the viewer so a pull-down only
  // reveals already rendered content. Keep that page inert until the viewer
  // has fully handed control back after its exit transition.
  private viewerOwnsParentInteraction(): boolean {
    return this.showImageViewer || this.viewerEntryTransitionActive ||
      this.viewerFallbackEntryActive || this.viewerClosePending
  }

  // 胶囊宽度按按钮数量算：4 项 = 328vp；详情页的排序胶囊固定 140vp。
  private wideBottomBarCapsuleWidth(): number {
    return Math.min(BOTTOM_BAR_ITEM_WIDTH_VP * BOTTOM_BAR_MAX_ITEMS,
      this.effectivePageWidth() - 32)
  }

  private bottomBarCapsuleWidth(): number {
    const available = this.effectivePageWidth() - 32
    if (this.bottomBarMode() === 'tools') {
      return Math.min(FILE_TOOL_SORT_WIDTH_VP, available)
    }
    return this.wideBottomBarCapsuleWidth()
  }

  private shouldShowFileToolsBar(): boolean {
    return this.screen === 'files' && !this.showSearch &&
      !this.shouldShowBottomBar() && this.contextMenuEntry === null &&
      !this.showRenameDialog &&
      !this.showAudioPlayer && !this.videoPlaybackUiVisible() && !this.selectionMode
  }

  private videoPlaybackUiVisible(): boolean {
    return this.showVideoPlayer && !this.videoPipBackgrounded
  }

  private updateBottomBarVisibility(animated: boolean = true): void {
    const shouldShow = this.shouldShowAnyBottomBar()
    const targetOffset = shouldShow ? 0 : 140
    const targetOpacity = shouldShow ? 1 : 0
    this.bottomBarAnimationToken += 1
    const token = this.bottomBarAnimationToken
    if (!animated) {
      this.bottomBarOffsetY = targetOffset
      this.bottomBarOpacity = targetOpacity
      return
    }
    this.getUIContext().animateTo({
      duration: 180,
      curve: shouldShow ? Curve.EaseOut : Curve.EaseIn
    }, () => {
      if (token === this.bottomBarAnimationToken) {
        this.bottomBarOffsetY = targetOffset
        this.bottomBarOpacity = targetOpacity
      }
    })
  }

  private fileTitle(path: string, kind: RootKind = this.rootKind): string {
    if (path.length > 0) {
      return path
    }
    return kind === 'personal' ? '个人空间' : '共享空间'
  }

  private updateTopTitle(title: string, animated: boolean = true): void {
    const nextTitle = title.length > 0 ? title : '我的云盘'
    this.titleAnimationToken += 1
    const token = this.titleAnimationToken
    if (!animated || this.topTitle === nextTitle) {
      this.topTitle = nextTitle
      this.topTitleOpacity = 1
      return
    }

    this.getUIContext().animateTo({ duration: 45, curve: Curve.EaseIn }, () => {
      if (token === this.titleAnimationToken) {
        this.topTitleOpacity = 0
      }
    })
    setTimeout((): void => {
      if (token !== this.titleAnimationToken) {
        return
      }
      this.topTitle = nextTitle
      this.getUIContext().animateTo({ duration: 80, curve: Curve.EaseOut }, () => {
        if (token === this.titleAnimationToken) {
          this.topTitleOpacity = 1
        }
      })
    }, 45)
  }

  private effectivePageWidth(): number {
    return this.pageWidthVp > 0 ? this.pageWidthVp : 360
  }

  private cancelFileTransition(): void {
    this.pageTransitionToken += 1
    if (this.pageTransitionTimer > 0) {
      clearTimeout(this.pageTransitionTimer)
      this.pageTransitionTimer = 0
    }
    this.showPageTransition = false
    this.pageOffsetX = 0
    this.outgoingPageOffsetX = 0
    this.outgoingEntries = []
  }

  private startFileTransition(outgoingEntries: FileEntry[], direction: PageTransitionDirection): void {
    this.cancelFileTransition()
    const token = this.pageTransitionToken
    const width = this.effectivePageWidth()
    this.outgoingEntries = outgoingEntries.slice()
    this.outgoingPageOffsetX = 0
    this.pageOffsetX = direction === 'push' ? width : -width
    this.showPageTransition = true

    // The incoming page travels one full screen width while the outgoing
    // page travels half a screen width in the same duration. Linear motion
    // keeps the 1:1/2 speed ratio visible instead of hiding it in easing.
    setTimeout((): void => {
      if (token !== this.pageTransitionToken || !this.showPageTransition) {
        return
      }
      const outgoingTarget = direction === 'push' ? -width * 0.5 : width * 0.5
      this.getUIContext().animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
        if (token !== this.pageTransitionToken) {
          return
        }
        this.pageOffsetX = 0
        this.outgoingPageOffsetX = outgoingTarget
      })
    }, 0)

    this.pageTransitionTimer = setTimeout((): void => {
      if (token !== this.pageTransitionToken) {
        return
      }
      this.pageTransitionTimer = 0
      this.showPageTransition = false
      this.pageOffsetX = 0
      this.outgoingPageOffsetX = 0
      this.outgoingEntries = []
      this.isBusy = false
    }, 210)
  }

  onBackPress(): boolean {
    if (this.importExpanded) {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => { this.importExpanded = false })
      return true
    }
    if (this.destinationFolderDialog) {
      this.closeDestinationFolderDialog()
      return true
    }
    if (this.showDestinationPicker) {
      if (this.destinationExpandedPaths.length > 0) {
        this.goDestinationBack()
      } else {
        this.closeDestinationPicker()
      }
      return true
    }
    if (this.showSearch) {
      this.closeSearch()
      return true
    }
    if (this.showFileSortMenu) {
      this.closeFileSortMenu()
      return true
    }
    if (this.showCreateFolderDialog) {
      this.closeCreateFolder()
      return true
    }
    if (this.showImageViewer) {
      if (this.showImageDetails) {
        this.closeImageDetails()
        return true
      }
      if (this.showImageMoreMenu) {
        this.closeImageMoreMenu()
        return true
      }
      if (this.showRenameDialog) {
        this.closeRename()
        return true
      }
      this.closeImageViewer()
      return true
    }
    if (this.showAudioPlayer) {
      this.closeAudioPlayer()
      return true
    }
    if (this.videoPlaybackUiVisible()) {
      this.closeVideoPlayer()
      return true
    }
    if (this.showRenameDialog) {
      this.closeRename()
      return true
    }
    if (this.contextMenuEntry !== null) {
      this.closeActionMenu()
      return true
    }
    if (this.selectionMode) {
      if (this.showSelectionMoreMenu) {
        this.closeSelectionMoreMenu()
        return true
      }
      this.exitSelectionMode()
      return true
    }
    if (this.screen === 'otp') {
      this.screen = 'login'
      return true
    }
    if (this.screen === 'downloads') {
      this.openHome()
      return true
    }
    if (this.screen === 'settings') {
      if (this.showStorageSettings) {
        this.closeStorageSettings()
        return true
      }
      if (this.showPlaybackSettings) {
        this.closePlaybackSettings()
        return true
      }
      if (this.showNetworkSettings) {
        this.closeNetworkSettings()
        return true
      }
      this.openHome()
      return true
    }
    if (this.screen === 'files' && this.currentPath.length > 0) {
      this.goBack()
      return true
    }
    return false
  }

  build() {
    Stack() {
      if (this.screen === 'files' && !this.showSearch && this.showPageTransition) {
        Stack() {
          this.FileContentSnapshot(this.outgoingEntries)
        }
        .width('100%')
        .height('100%')
        .translate({ x: this.outgoingPageOffsetX, y: 0, z: 0 })
      }

      Column() {
        if (this.screen === 'login') {
          this.LoginContent()
        } else if (this.screen === 'otp') {
          this.OtpContent()
        } else if (this.screen === 'settings') {
          this.SettingsContent()
        } else if (this.screen === 'downloads') {
          this.DownloadContent()
        } else {
          // Keep the file/search surface mounted while the image viewer is
          // presented above it. Replacing this subtree with Blank() used to
          // destroy WaterFlow/List/Grid, so returning from the viewer caused
          // a fresh layout pass, a downward jump, and a reload-like effect.
          // The viewer is rendered later in this Stack and covers this
          // surface without changing its scroll/layout state.
          if (this.showSearch) {
            this.SearchContent()
          } else {
            this.FileContent()
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      .translate({ x: this.pageOffsetX, y: 0, z: 0 })
      .hitTestBehavior(this.viewerOwnsParentInteraction()
        ? HitTestMode.BLOCK_DESCENDANTS : HitTestMode.Default)
      .onAreaChange((_, area) => {
        if (typeof area.width === 'number' && area.width > 0) {
          this.pageWidthVp = area.width
        }
        if (typeof area.height === 'number' && area.height > 0) {
          this.pageHeightVp = area.height
        }
      })

      if ((this.screen === 'files' || this.screen === 'downloads' || this.screen === 'settings') &&
        this.contextMenuEntry === null && !this.showRenameDialog &&
        !this.showDestinationPicker &&
        !this.showAudioPlayer && !this.videoPlaybackUiVisible()) {
        // 三种底栏形态共用这一个常驻外壳，内部按 bottomBarMode() 交叉淡化；
        // 显隐仍由 bottomBarOffsetY/bottomBarOpacity 控制。
        Stack({ alignContent: Alignment.Bottom }) {
          this.BottomBar()
        }
        .width('100%')
        .height('100%')
        .translate({ x: 0, y: this.bottomBarOffsetY, z: 0 })
        .opacity(this.bottomBarOpacity)
        .zIndex(20)
        // The host is transparent and contains only the capsule. Its empty
        // area must pass through to the file surface below.
        .hitTestBehavior(this.viewerOwnsParentInteraction()
          ? HitTestMode.BLOCK_DESCENDANTS : HitTestMode.None)
      }

      if (this.screen === 'downloads' && this.transferDirection === 'download' && this.hasActiveDownload()) {
        this.DownloadSpeedBall()
      }

      if (this.screen === 'downloads') {
        this.TransferDirectionControl()
      }

      if (this.screen === 'files' && this.currentPath.length > 0 && !this.showSearch &&
        !this.selectionMode && !this.importSelecting && this.contextMenuEntry === null &&
        !this.showRenameDialog && !this.showCreateFolderDialog && !this.showDestinationPicker &&
        !this.showAudioPlayer && !this.videoPlaybackUiVisible()) {
        if (this.importExpanded) {
          Row().width('100%').height('100%').backgroundColor(Color.Transparent).zIndex(24)
            .onClick(() => {
              this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
                this.importExpanded = false
              })
            })
        }
        FloatingImportControl({ viewportWidth: this.pageWidthVp, viewportHeight: this.pageHeightVp,
          // The title controls end at topSafeInset + 56vp. Keep only an 8vp
          // clearance instead of treating the 30vp gradient tail as a blocker.
          safeTop: this.topSafeInset() + 64, safeBottom: this.floatingBarContentInset(8),
          expanded: $importExpanded, onSelect: (source: string): void => { this.selectImportSource(source) } })
          .position({ x: 0, y: 0 })
          .zIndex(this.viewerClosePending ? 8 : 25)
          // The overlay is a full page sized host whose only interactive part is
          // the ball itself. Keeping the host out of the touch test lets taps
          // reach the file list under it.
          .hitTestBehavior(this.viewerOwnsParentInteraction()
            ? HitTestMode.BLOCK_DESCENDANTS : HitTestMode.None)
      }

      if ((this.screen === 'files' || this.screen === 'downloads' || this.screen === 'settings') &&
        !this.showDestinationPicker &&
        !this.showAudioPlayer && !this.videoPlaybackUiVisible()) {
        Stack({ alignContent: Alignment.TopStart }) {
          this.NativeFileHeader()
        }
        .width('100%')
        .height('100%')
        .zIndex(10)
        .hitTestBehavior(this.viewerOwnsParentInteraction()
          ? HitTestMode.BLOCK_DESCENDANTS : HitTestMode.None)
      }

      this.ActionMenuOverlay()

      if (this.showDestinationPicker) {
        this.DestinationPickerOverlay()
      }
      if ((this.showImageViewer || this.viewerEntryTransitionActive ||
        this.viewerFallbackEntryActive || this.viewerClosePending) &&
        this.committedViewerEntry() !== null) {
        Stack() {
          if (this.showImageViewer) {
            this.ImageViewer()
          }
          this.ImageViewerChrome()
        }
        .width('100%')
        .height('100%')
        .zIndex(30)
        .hitTestBehavior(this.showImageViewer ? HitTestMode.Transparent : HitTestMode.None)
      }
      if (this.showAudioPlayer && this.audioEntry !== null) {
        this.AudioPlayerOverlay(this.audioEntry as FileEntry)
      }
      if (this.showVideoPlayer && this.videoEntry !== null) {
        this.VideoPlayerOverlay(this.videoEntry as FileEntry)
      }
      // Keep native sheet anchors mounted for both opening and dismissal.
      this.RenameOverlay()
      this.CreateFolderOverlay()
      this.DestinationFolderOverlay()
      this.ImageViewerDetailsOverlay()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  Header(): void {
    Row() {
      Column() {
          Text('我的云盘')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('云端文件 · 安全访问')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.screen === 'files') {
        Row({ space: 8 }) {
          Button('设置')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor(Color.Transparent)
            .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
            .onClick(() => this.openSettings())
          Button('退出')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor(Color.Transparent)
            .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
            .onClick(() => this.logout())
        }
      } else if (this.screen === 'settings') {
        Button('返回')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
          .onClick(() => {
            if (this.showStorageSettings) {
              this.closeStorageSettings()
            } else if (this.showPlaybackSettings) {
              this.closePlaybackSettings()
            } else if (this.showNetworkSettings) {
              this.closeNetworkSettings()
            } else {
              this.openHome()
            }
          })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 14 })
  }

  @Builder
  LoginContent(): void {
    Column() {
      Column({ space: 18 }) {
        Column({ space: 6 }) {
          Text('我的云盘')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('登录')
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Column({ space: 10 }) {
          TextInput({ placeholder: '云盘 ID', text: this.linkId })
            .height(52)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor(Color.Transparent)
            .borderRadius(14)
            .padding({ left: 16, right: 16 })
            .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true))
            .onChange((value: string) => this.linkId = value)
          TextInput({ placeholder: '云盘账号', text: this.username })
            .height(52)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor(Color.Transparent)
            .borderRadius(14)
            .padding({ left: 16, right: 16 })
            .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true))
            .onChange((value: string) => this.username = value)
          TextInput({ placeholder: '云盘密码', text: this.password })
            .type(InputType.Password)
            .height(52)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor(Color.Transparent)
            .borderRadius(14)
            .padding({ left: 16, right: 16 })
            .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true))
            .onChange((value: string) => this.password = value)
        }
        .width('100%')

        Row({ space: 10 }) {
          this.LoginOptionButton('自动登录', this.autoLogin, () => this.toggleAutoLogin())
          this.LoginOptionButton('记住密码', this.rememberPassword, () => this.toggleRememberPassword())
        }
        .width('100%')

        Row({ space: 10 }) {
          Button('登录')
            .layoutWeight(1)
            .height(50)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor(Color.Transparent)
            .borderRadius(16)
            .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.REGULAR, true, '#552E6BFF'))
            .enabled(!this.isBusy)
            .onClick(() => this.handleLogin())
          Button('解析')
            .layoutWeight(1)
            .height(50)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.control_text'))
            .backgroundColor(Color.Transparent)
            .borderRadius(16)
            .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.REGULAR, true))
            .enabled(!this.isBusy)
            .onClick(() => this.handleResolve())
        }
        .width('100%')

        if (this.statusText.length > 0) {
          Text(this.statusText)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
        }
      }
      .width('92%')
      .padding(24)
      .borderRadius(28)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.REGULAR, false))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  LoginOptionButton(title: string, active: boolean, action: () => void): void {
    Button(title)
      .layoutWeight(1)
      .height(44)
      .fontSize(14)
      .fontColor(active ? Color.White : $r('app.color.text_secondary'))
      .backgroundColor(Color.Transparent)
      .borderRadius(15)
      .systemMaterial(active
        ? this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true, '#552E6BFF')
        : this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN, true))
      .onClick(action)
  }

  @Builder
  OtpContent(): void {
    Column({ space: 18 }) {
      Column() {
        Text('需要安全验证')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('登录接口要求输入一次性验证码，请填写 6 位数字。')
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 8 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      TextInput({ placeholder: '6 位验证码', text: this.otpCode })
        .height(56)
        .fontSize(24)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.surface_input'))
        .borderRadius(14)
        .padding({ left: 16, right: 16 })
        .onChange((value: string) => this.otpCode = value)
      Row() {
        Text('信任此设备')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.trustDevice })
          .selectedColor('#2E6BFF')
          .onChange((value: boolean) => this.trustDevice = value)
      }
      .width('100%')
      Button(this.isBusy ? '验证中…' : '验证并登录')
        .width('100%')
        .height(52)
        .fontSize(16)
        .fontColor(Color.White)
        .backgroundColor(Color.Transparent)
        .borderRadius(14)
        .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.REGULAR, true, '#552E6BFF'))
        .enabled(!this.isBusy)
        .onClick(() => this.handleOtp())
      Button('返回登录')
        .width('100%')
        .height(44)
        .fontColor($r('app.color.text_secondary'))
        .backgroundColor(Color.Transparent)
        .borderRadius(14)
        .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN))
        .enabled(!this.isBusy)
        .onClick(() => this.screen = 'login')
      Text(this.statusText)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 20, right: 20, top: 24 })
    .layoutWeight(1)
  }

  @Builder
  FileLeadingVisual(entry: FileEntry, index: number = -1,
    surface: ThumbnailSurfaceKind = 'none'): void {
    Stack() {
      if (this.shouldReplaceViewerTransitionSource(entry)) {
        Blank()
          .width(40)
          .height(34)
      } else if (this.fileImageSourceAvailable(entry, surface)) {
        Image(this.fileImageSource(entry, surface))
            .width(40)
            .height(34)
            .orientation(this.fileImageSourceOrientation(entry, surface))
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
            .geometryTransition(this.fileImageTransitionId(entry, surface))
            .syncLoad(this.fileImageShouldSyncLoad(entry))
            .onComplete((event?: ViewerImageCompleteEvent): void =>
              this.recordThumbnailComplete(entry, this.previewUri(entry), index, surface, event))
        if (this.isVideo(entry)) {
          SymbolGlyph($r('sys.symbol.play'))
            .fontSize(13)
            .fontColor([Color.White])
            .backgroundColor('#88000000')
            .borderRadius(10)
            .width(22)
            .height(22)
        }
      } else if (entry.isDirectory) {
        this.FolderIcon(32)
      } else {
        Image(this.fileIcon(entry))
          .width(32)
          .height(32)
          .objectFit(ImageFit.Contain)
      }
    }
    .width(40)
    .height(34)
    .borderRadius(6)
    .clip(true)
    .onAreaChange((_, area) => this.recordThumbnailArea(entry, index, surface, area))
    .onVisibleAreaChange([0.0, 0.999], (_isExpanding: boolean, ratio: number): void =>
      this.recordThumbnailVisibility(entry, index, surface, ratio))
  }

  @Builder
  VideoTransferIndicator(entry: FileEntry): void {
    if (!this.isVideo(entry)) {
      Blank()
        .width(0)
        .height(0)
    } else {
      if (this.videoStateForEntry(entry).status === 'failed') {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
          .fontSize(18)
          .fontColor([$r('app.color.icon_muted')])
          .margin({ left: 8, right: 4 })
      } else if (this.videoStateForEntry(entry).status === 'completed') {
        SymbolGlyph($r('sys.symbol.checkmark_circle'))
          .fontSize(20)
          .fontColor(['#2E6BFF'])
          .margin({ left: 8, right: 4 })
      } else if (this.videoStateForEntry(entry).status !== 'idle') {
        // Network playback is buffered inside AVPlayer rather than written to
        // our durable cache.  Until a native CACHED_DURATION value is
        // available, a zero-byte Progress ring would render as a permanently
        // grey circle; use the same active indicator as the file manager for
        // this indeterminate phase.
        if (this.videoTransferIsIndeterminate(entry)) {
          // A gateway that omits Content-Range cannot provide a truthful
          // percentage yet.  Keep that state visibly active instead of
          // rendering a permanently grey zero-value Progress ring.
          LoadingProgress()
            .width(25)
            .height(25)
            .color('#2E6BFF')
            .margin({ left: 8, right: 4 })
        } else {
          Progress({ value: this.videoStateForEntry(entry).progress(), total: 100, type: ProgressType.Ring })
            .width(25)
            .height(25)
            .backgroundColor('#AAB3C1')
            .color('#2E6BFF')
            .style({
              strokeWidth: 3,
              enableSmoothEffect: false,
              status: ProgressStatus.PROGRESSING
            })
            .margin({ left: 8, right: 4 })
        }
      }
    }
  }

  private videoTransferIsIndeterminate(entry: FileEntry): boolean {
    const state = this.videoStateForEntry(entry)
    return state.totalBytes <= 0 || (state.status === 'streaming' && state.receivedBytes <= 0)
  }

  @Builder
  SelectionCheckbox(entry: FileEntry): void {
    Checkbox()
      .select(this.isSelected(entry))
      .shape(CheckBoxShape.CIRCLE)
      .selectedColor('#2E6BFF')
      .unselectedColor(this.isDarkTheme ? '#99FFFFFF' : '#89919B')
      .width(28)
      .height(28)
      // The whole row is the selection target. Let the row own the gesture so
      // a checkbox tap cannot bubble and toggle the same entry twice.
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  FolderIcon(size: number): void {
    Image($r('sys.media.ohos_ic_normal_white_grid_folder'))
      .width(size)
      .height(size * 0.85)
      .objectFit(ImageFit.Contain)
  }

  @Builder
  FileRowChevron(): void {
    SymbolGlyph($r('sys.symbol.chevron_forward'))
      .fontSize(18)
      .fontColor([$r('app.color.icon_muted')])
  }

  @Builder
  SearchScopeButton(title: string, scope: RemoteSearchScope): void {
    Button(title)
      .height(36)
      .fontSize(14)
      .fontColor(this.searchScope === scope ? Color.White : $r('app.color.text_secondary'))
      .backgroundColor(Color.Transparent)
      .borderRadius(18)
      .systemMaterial(this.searchScope === scope
        ? this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true, '#552E6BFF')
        : this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN, true))
      .monopolizeEvents(true)
      .onClick(() => this.setSearchScope(scope))
  }

  @Builder
  SearchHistoryChip(keyword: string): void {
    Button(keyword)
      .height(34)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .backgroundColor(Color.Transparent)
      .borderRadius(17)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN, true))
      .onClick(() => this.submitSearch(keyword))
  }

  @Builder
  SearchContent(): void {
    Column() {
      if (this.searchQuery.trim().length === 0) {
        Column({ space: 14 }) {
          Row() {
            Text('搜索历史')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            if (this.searchHistory.length > 0) {
              Button() {
                SymbolGlyph($r('sys.symbol.trash'))
                  .fontSize(18)
                  .fontColor([$r('app.color.icon_primary')])
              }
              .type(ButtonType.Normal)
              .width(34)
              .height(34)
              .backgroundColor(Color.Transparent)
              .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN, true))
              .onClick(() => this.clearSearchHistory())
              Button() {
                SymbolGlyph(this.searchHistoryExpanded
                  ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                  .fontSize(17)
                  .fontColor([$r('app.color.icon_primary')])
              }
              .type(ButtonType.Normal)
              .width(34)
              .height(34)
              .backgroundColor(Color.Transparent)
              .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN, true))
              .onClick(() => this.searchHistoryExpanded = !this.searchHistoryExpanded)
            }
          }
          .width('100%')

          if (this.searchHistory.length === 0) {
            Text('暂无搜索记录')
              .fontSize(14)
              .fontColor($r('app.color.text_muted'))
              .width('100%')
          } else {
            Row({ space: 8 }) {
              ForEach(this.searchHistoryItems(), (keyword: string) => {
                this.SearchHistoryChip(keyword)
              }, (keyword: string) => keyword)
            }
            .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({
          left: 16,
          right: 16,
          top: this.topSafeInset() + 84,
          bottom: this.bottomSafeInset() + 20
        })
      } else {
        List({ space: 0, scroller: this.searchResultScroller }) {
          // Match FileContent: the viewport begins at the top of the page and
          // this spacer keeps the initial result below the floating controls.
          // When scrolled, results can pass behind the fixed gradient overlay
          // and receive the same blur treatment as the normal file list.
          ListItem() {
            Row()
              .width('100%')
              .height(this.topSafeInset() + 124)
          }
          .width('100%')

          if (this.searchLoading && this.searchResults.length === 0) {
            ListItem() {
              Text('正在搜索…')
                .fontSize(14)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 24, bottom: 24 })
            }
          } else if (!this.searchLoading && this.searchResults.length === 0) {
            ListItem() {
              Text('没有找到匹配的文件或文件夹')
                .fontSize(14)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 24, bottom: 24 })
            }
          }

          ForEach(this.searchResults, (entry: FileEntry, index: number) => {
            ListItem() {
              Row() {
                this.FileLeadingVisual(entry, index, 'search')
                Column() {
                  Text(entry.name)
                    .fontSize(16)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.searchResultLocation(entry))
                    .fontSize(12)
                    .fontColor($r('app.color.text_muted'))
                    .margin({ top: 4 })
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .margin({ left: 10 })
                this.VideoTransferIndicator(entry)
                if (entry.isDirectory) {
                  SymbolGlyph($r('sys.symbol.chevron_forward'))
                    .fontSize(18)
                    .fontColor([$r('app.color.icon_muted')])
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            }
            .onClick(() => this.openSearchResult(entry))
          }, (entry: FileEntry) => entry.path)

          ListItem() {
            Row()
              .width('100%')
              .height(this.bottomSafeInset() + 20)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(Color.Transparent)
        .linearGradientBlur(9, {
          fractionStops: [
            [1.0, 0.0],
            [1.0, 0.025],
            [0.28, 0.065],
            [0.0, 0.10],
            [0.0, 1.0]
          ],
          direction: GradientDirection.Bottom
        })
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .onDidScroll((scrollOffset: number, _state: ScrollState): void => {
          this.searchScrollOffset = Math.max(0, scrollOffset)
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  @Builder
  FileContent(): void {
    Column({ space: 12 }) {
      if (this.fileViewMode === 'grid') {
        this.GridFileList()
      } else if (this.fileViewMode === 'waterfall' && this.currentDirectoryHasImages) {
        this.WaterfallFileList()
      } else {
      List({ space: 0, scroller: this.fileListScroller }) {
        // Match the reference chat page: the top breathing space belongs to
        // the scroll content, so it scrolls away and rows can pass behind the
        // fixed gradient header instead of being clipped below it.
        ListItem() {
          Row()
            .width('100%')
            .height(this.fileContentTopInset())
        }
        .width('100%')

        LazyForEach(this.fileEntryDataSource, (entry: FileEntry, index: number) => {
          ListItem() {
            Column() {
              Row() {
                Row() {
                  this.FileLeadingVisual(entry, index, 'list')
                }
                .margin({ right: 8 })
                Column() {
                  Text(entry.name)
                    .fontSize(16)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.entryInfo(entry).length > 0) {
                    Text(this.entryInfo(entry))
                      .fontSize(12)
                      .fontColor($r('app.color.text_muted'))
                      .margin({ top: 4 })
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                this.VideoTransferIndicator(entry)
                if (this.selectionMode) {
                  this.SelectionCheckbox(entry)
                } else if (entry.isDirectory) {
                  this.FileRowChevron()
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ left: 8, right: 8, top: 12, bottom: 12 })

              if (index < this.entries.length - 1) {
                Divider()
                  .width('calc(100% - 16vp)')
                  .strokeWidth(0.5)
                  .color($r('app.color.divider'))
              }
            }
            .width('100%')
            .onClick(() => this.handleFileEntryClick(entry))
            .priorityGesture(
              LongPressGesture({ repeat: false })
                .onAction((event: GestureEvent): void => {
                  this.showActionMenu(entry, event)
                })
            )
          }
          .onAppear(() => {
            this.loadEntryPreview(entry, 0)
            this.recordThumbnailMountedSource(entry, this.previewUri(entry), index, 'list')
            this.scheduleCachedDirectoryCount(entry)
          })
          .onDisAppear(() => this.recordThumbnailVisibility(entry, index, 'list', 0))
        }, (entry: FileEntry) => entry.path)

      }
      .width('100%')
      .layoutWeight(1)
      .cachedCount(4)
      .onScrollIndex((start: number, end: number, _center: number): void => {
        this.fileVisibleStartIndex = Math.max(0, start)
        this.fileVisibleEndIndex = Math.max(this.fileVisibleStartIndex, end)
      })
      .onReachEnd(() => this.loadNextDirectoryPage())
      .padding({ left: 0, right: 0 })
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      }
      if (!this.isBusy && ((this.fileViewMode === 'waterfall'
        && this.waterfallEntries.length === 0) || (this.fileViewMode !== 'waterfall'
        && this.entries.length === 0))) {
        Text(this.fileViewMode === 'waterfall'
          ? '当前目录没有图片' : '当前目录为空或没有可显示的文件')
          .fontSize(13)
          .fontColor($r('app.color.text_muted'))
          .margin({ top: 10 })
      }
    }
    .width('100%')
    .height('100%')
    .layoutWeight(1)
  }

  @Builder
  DownloadContent(): void {
    Column() {
      List({ space: 0 }) {
        ListItem() {
          Row()
            .width('100%')
            .height(this.topSafeInset() + 120)
        }
        .width('100%')

        if (this.visibleTransferTasks().length === 0) {
          ListItem() {
            Text(this.transferDirection === 'upload' ? '暂无上传任务' : '暂无下载任务')
              .fontSize(14)
              .fontColor($r('app.color.text_muted'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 36, bottom: 36 })
          }
          .width('100%')
        } else {
          ForEach(this.visibleTransferTasks(), (task: DownloadTaskRecord) => {
            ListItem() {
              this.DownloadTaskRow(task)
            }
            .width('100%')
            .onClick(() => this.toggleDownloadTask(task))
            .priorityGesture(
              LongPressGesture({ repeat: false })
                .onAction(() => this.confirmRemoveDownloadTask(task))
            )
          }, (task: DownloadTaskRecord): string => task.id)

          ListItem() {
            Row()
              .width('100%')
              .height(this.floatingBarContentInset())
          }
          .width('100%')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .linearGradientBlur(9, {
        fractionStops: [
          [1.0, 0.0],
          [1.0, 0.025],
          [0.28, 0.065],
          [0.0, 0.10],
          [0.0, 1.0]
        ],
        direction: GradientDirection.Bottom
      })
    }
    .width('100%')
    .layoutWeight(1)
  }

  private visibleTransferTasks(): DownloadTaskRecord[] {
    return this.transferDirection === 'upload' ? this.uploadTasks : this.downloadTasks
  }

  @Builder
  TransferDirectionSurface(): void {
    Row({ space: 8 }) {
      Button('下载', { type: ButtonType.Capsule })
        .width(88).height(36).fontSize(15)
        .fontColor(this.transferDirection === 'download' ? '#2E6BFF' : $r('app.color.text_primary'))
        .fontWeight(this.transferDirection === 'download' ? FontWeight.Medium : FontWeight.Normal)
        .backgroundColor(Color.Transparent)
        .systemMaterial(this.transferControlMaterial())
        .accessibilitySelected(this.transferDirection === 'download')
        .onClick(() => { this.transferDirection = 'download' })
      Button('上传', { type: ButtonType.Capsule })
        .width(88).height(36).fontSize(15)
        .fontColor(this.transferDirection === 'upload' ? '#2E6BFF' : $r('app.color.text_primary'))
        .fontWeight(this.transferDirection === 'upload' ? FontWeight.Medium : FontWeight.Normal)
        .backgroundColor(Color.Transparent)
        .systemMaterial(this.transferControlMaterial())
        .accessibilitySelected(this.transferDirection === 'upload')
        .onClick(() => { this.transferDirection = 'upload' })
    }.width(184).height(36)
  }

  private transferControlMaterial(): uiMaterial.ImmersiveMaterial {
    // A compact title host clips native material shadows at its rectangular bounds.
    return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN,
      applyShadow: false, colorInvert: true, interactive: true, lightEffect: { color: '#66FFFFFF' } })
  }

  @Builder
  TransferDirectionControl(): void {
    Navigation() {}
      .mode(NavigationMode.Stack).hideBackButton(true).hideToolBar(true)
      .title({ builder: this.TransferDirectionSurface, height: 36 }, {
        barStyle: BarStyle.STACK, paddingStart: LengthMetrics.vp(0), paddingEnd: LengthMetrics.vp(0),
        backgroundColor: Color.Transparent
      })
      .width(184).height(36).backgroundColor(Color.Transparent).clip(false)
      .position({ x: (this.pageWidthVp - 184) / 2, y: this.topSafeInset() + 72 })
      .zIndex(15)
  }

  private async selectImportSource(source: string): Promise<void> {
    this.importExpanded = false
    if (source === 'folder') { this.openCreateFolder(); return }
    if (this.currentPath.length === 0 || this.importSelecting || this.isBusy) { return }
    const target = this.currentPath
    const scope = this.repository.cacheScopeHash()
    this.importSelecting = true
    try {
      await this.ensureDownloadState()
      let uris: string[] = []
      if (source === 'gallery') {
        const options = new photoAccessHelper.PhotoSelectOptions()
        options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE
        options.maxSelectNumber = 100
        const result = await new photoAccessHelper.PhotoViewPicker().select(options)
        uris = result.photoUris
      } else {
        const options = new picker.DocumentSelectOptions()
        options.maxSelectNumber = 100
        options.selectMode = picker.DocumentSelectMode.FILE
        uris = await new picker.DocumentViewPicker(getContext(this)).select(options)
      }
      if (uris.length === 0) { return }
      // Reading starts after the system picker has returned and the user confirms the destination.
      const confirmation = await promptAction.showDialog({ title: '上传 ' + uris.length + ' 个文件',
        message: '上传到：' + target + '\n保留原文件，同名文件跳过。',
        buttons: [{ text: '取消', color: '#536174' }, { text: '上传', color: '#2E6BFF' }],
        systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false) })
      if (confirmation.index !== 1) { return }
      this.transferDirection = 'upload'
      this.openDownloads()
      for (const uri of uris) { await this.uploadQueue.enqueue(uri, target, scope) }
    } catch (error) { this.reportError(error as Object, '文件导入失败') }
    finally { this.importSelecting = false }
  }

  @Builder
  DownloadTaskRow(task: DownloadTaskRecord): void {
    Row() {
      Row() {
        this.FileLeadingVisual(this.downloadTaskEntry(task))
      }
      .margin({ right: 8 })
      Column() {
        Text(task.name)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.downloadTaskInfo(task))
          .fontSize(12)
          .fontColor($r('app.color.text_muted'))
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Progress({ value: this.downloadTaskProgress(task), total: 100, type: ProgressType.Ring })
        .width(30)
        .height(30)
        .backgroundColor('#AAB3C1')
        .color('#2E6BFF')
        .style({
          strokeWidth: 3,
          enableSmoothEffect: false,
          status: task.status === 'downloading' && task.size <= 0
            ? ProgressStatus.LOADING : ProgressStatus.PROGRESSING
        })
        .margin({ left: 10, right: 8 })
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 12, bottom: 12 })
    .border({
      width: { bottom: 0.5 },
      color: $r('app.color.divider'),
      style: BorderStyle.Solid
    })
  }

  @Builder
  DownloadSpeedBall(): void {
    Column() {
      Blank()
        .layoutWeight(1)
        .hitTestBehavior(HitTestMode.None)
      Stack() {
        Column({ space: 1 }) {
          SymbolGlyph($r('sys.symbol.arrow_down'))
            .fontSize(16)
            .fontColor([$r('app.color.icon_primary')])
          Text(this.formatSpeed(this.downloadSpeedBytesPerSecond))
            .fontSize(10)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
        }
        .justifyContent(FlexAlign.Center)
      }
      .width(64)
      .height(64)
      .borderRadius(32)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true, '#442E6BFF'))
      .hitTestBehavior(HitTestMode.Default)
      .monopolizeEvents(true)
      .onClick(() => this.openDownloads())
      .margin({ right: 18,
        bottom: this.floatingBarBottomMargin() + FLOATING_BAR_HEIGHT_VP + 16 })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.End)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  GridFileList(): void {
    Grid(this.fileListScroller) {
      LazyForEach(this.fileEntryDataSource, (entry: FileEntry, index: number) => {
        GridItem() {
          Stack({ alignContent: Alignment.TopEnd }) {
            Column({ space: 6 }) {
              Stack({ alignContent: Alignment.Center }) {
                if (this.shouldReplaceViewerTransitionSource(entry)) {
                  Blank()
                    .width('100%')
                    .height(82)
                } else if (this.fileImageSourceAvailable(entry, 'grid')) {
                  Image(this.fileImageSource(entry, 'grid'))
                      .width('100%')
                      .height(82)
                      .orientation(this.fileImageSourceOrientation(entry, 'grid'))
                      .objectFit(ImageFit.Cover)
                      .borderRadius(10)
                      .geometryTransition(this.fileImageTransitionId(entry, 'grid'))
                      .syncLoad(this.fileImageShouldSyncLoad(entry))
                      .onComplete((event?: ViewerImageCompleteEvent): void =>
                        this.recordThumbnailComplete(entry, this.previewUri(entry), index,
                          'grid', event))
                } else if (entry.isDirectory) {
                  this.FolderIcon(44)
                } else {
                  Image(this.fileIcon(entry))
                    .width(48)
                    .height(48)
                    .objectFit(ImageFit.Contain)
                }
              }
              .width('100%')
              .height(82)
              .borderRadius(10)
              .clip(true)
              .onAreaChange((_, area) => this.recordThumbnailArea(entry, index, 'grid', area))
              .onVisibleAreaChange([0.0, 0.999],
                (_isExpanding: boolean, ratio: number): void =>
                  this.recordThumbnailVisibility(entry, index, 'grid', ratio))

              Text(entry.name)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .textAlign(TextAlign.Center)
              if (entry.isDirectory && this.entryInfo(entry).length > 0) {
                Text(this.entryInfo(entry))
                  .fontSize(11)
                  .fontColor($r('app.color.text_muted'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .width('100%')
            .padding({ left: 6, right: 6, top: 8, bottom: 8 })
            this.VideoTransferIndicator(entry)
            if (this.selectionMode) {
              Row() {
                this.SelectionCheckbox(entry)
              }
                .margin({ top: 8, right: 8 })
            }
          }
          .onClick(() => this.handleFileEntryClick(entry))
          .priorityGesture(
            LongPressGesture({ repeat: false })
              .onAction((event: GestureEvent): void => {
                this.showActionMenu(entry, event)
              })
          )
        }
        .onAppear(() => {
          this.loadEntryPreview(entry, index)
          this.recordThumbnailMountedSource(entry, this.previewUri(entry), index, 'grid')
          this.scheduleCachedDirectoryCount(entry)
        })
        .onDisAppear(() => this.recordThumbnailVisibility(entry, index, 'grid', 0))
      }, (entry: FileEntry) => entry.path)
    }
    .columnsTemplate('1fr 1fr')
    .columnsGap(8)
    .rowsGap(8)
    .cachedCount(8)
    .onScrollIndex((first: number, last: number): void => {
      this.fileVisibleStartIndex = Math.max(0, first)
      this.fileVisibleEndIndex = Math.max(this.fileVisibleStartIndex, last)
    })
    .onReachEnd(() => this.loadNextDirectoryPage())
    .width('100%')
    .layoutWeight(1)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .padding({ left: 10, right: 10, top: this.fileContentTopInset(),
      bottom: 0 })
  }

  @Builder
  WaterfallFileList(): void {
    WaterFlow({
      scroller: this.waterfallScroller,
      layoutMode: WaterFlowLayoutMode.SLIDING_WINDOW
    }) {
      LazyForEach(this.waterfallDataSource, (entry: FileEntry, index: number) => {
        FlowItem() {
          Stack({ alignContent: Alignment.TopEnd }) {
            if (this.shouldReplaceViewerTransitionSource(entry)) {
              Blank()
                .width('100%')
                .height('100%')
            } else {
              Stack() {
                Stack({ alignContent: Alignment.Center }) {
                  if (this.fileImageSourceAvailable(entry, 'waterfall')) {
                    Image(this.fileImageSource(entry, 'waterfall'))
                      .width('100%')
                      .height('100%')
                      .sourceSize(this.waterfallSourceSize(entry))
                      .orientation(this.fileImageSourceOrientation(entry, 'waterfall'))
                      .objectFit(ImageFit.Contain)
                      .geometryTransition(this.fileImageTransitionId(entry, 'waterfall'))
                      .syncLoad(this.fileImageShouldSyncLoad(entry))
                      .onComplete((event?: ViewerImageCompleteEvent): void => {
                        this.recordThumbnailComplete(entry, this.waterfallUri(entry), index,
                          'waterfall', event)
                        this.completeWaterfallDecode(entry)
                      })
                      .onError(() => this.failWaterfallDecode(entry))
                  } else {
                    LoadingProgress()
                      .width(24)
                      .height(24)
                      .color('#2E6BFF')
                  }
                }
                .width('100%')
                .height('100%')
                .borderRadius(10)
                .clip(true)
              }
              .width('100%')
              .height('100%')
            }
            this.VideoTransferIndicator(entry)
          }
          .width('100%')
          .aspectRatio(this.waterfallAspectRatio(entry))
          .backgroundColor('#12000000')
          .borderRadius(10)
          // Outline does not participate in WaterFlow measurement, so the
          // selection state cannot change the card size or column positions.
          .outline({
            width: this.selectionMode && this.isSelected(entry) ? 2 : 0,
            color: '#2E6BFF',
            radius: 10
          })
          .onAreaChange((_, area) => this.recordThumbnailArea(entry, index, 'waterfall', area))
          .onVisibleAreaChange([0.0, 0.999],
            (_isExpanding: boolean, ratio: number): void =>
              this.recordThumbnailVisibility(entry, index, 'waterfall', ratio))
          .onClick(() => this.handleFileEntryClick(entry))
          .priorityGesture(
            LongPressGesture({ repeat: false })
              .onAction((event: GestureEvent): void => {
                this.showActionMenu(entry, event)
            })
          )
        }
        // WaterFlow does not use the top padding here as the scroll-content
        // origin on this device. Put the breathing room on the first row's
        // FlowItems instead; later rows remain unchanged and can still scroll
        // naturally under the common TopFileOverlay, just like list/grid.
        .margin({ top: index < 2 ? this.fileContentTopInset() : 0 })
        .onAppear(() => {
          this.markWaterfallVisible(entry, true)
          this.recordThumbnailMountedSource(entry, this.waterfallUri(entry), index, 'waterfall')
          this.enqueueWaterfallOriginal(entry, index)
        })
        .onDisAppear(() => {
          this.markWaterfallVisible(entry, false)
          this.recordThumbnailVisibility(entry, index, 'waterfall', 0)
        })
      }, (entry: FileEntry) => entry.path)
    }
    .columnsTemplate('1fr 1fr')
    .columnsGap(8)
    .rowsGap(8)
    // Only visible FlowItems are mounted. Original-file downloads are
    // prefetched separately and are limited by waterfallDownloadQueue.
    .cachedCount(0)
    .onScrollIndex((first: number, last: number): void => {
      this.waterfallVisibleStartIndex = Math.max(0, first)
      this.waterfallVisibleEndIndex = Math.max(this.waterfallVisibleStartIndex, last)
      this.prefetchWaterfallRange(first, last)
    })
    .onReachEnd(() => this.loadNextDirectoryPage())
    .onAreaChange((_, area) => {
      if (typeof area.width === 'number' && area.width > 0) {
        this.waterfallColumnWidthVp = Math.max(1, (area.width - 28) / 2)
      }
    })
    .width('100%')
    .height('100%')
    .layoutWeight(1)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // Match list/grid content origin: this is layout breathing room, not a
    // second mask. The existing TopFileOverlay remains the only top visual
    // gradient, while the first waterfall row starts below it instead of
    // being covered by the gradient.
    .padding({ left: 10, right: 10, top: 0, bottom: 0 })
  }

  @Builder
  FileContentSnapshot(snapshotEntries: FileEntry[]): void {
    Column() {
      List({ space: 0, scroller: this.transitionScroller }) {
        ListItem() {
          Row()
            .width('100%')
            .height(this.topSafeInset() + 76)
        }
        .width('100%')

        ForEach(snapshotEntries, (entry: FileEntry, index: number) => {
          ListItem() {
            Column() {
              Row() {
                Row() {
                  this.FileLeadingVisual(entry)
                }
                .margin({ right: 8 })
                Column() {
                  Text(entry.name)
                    .fontSize(16)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.entryInfo(entry).length > 0) {
                    Text(this.entryInfo(entry))
                      .fontSize(12)
                      .fontColor($r('app.color.text_muted'))
                      .margin({ top: 4 })
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (entry.isDirectory) {
                  this.FileRowChevron()
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ left: 8, right: 8, top: 12, bottom: 12 })

              if (index < snapshotEntries.length - 1) {
                Divider()
                  .width('calc(100% - 16vp)')
                  .strokeWidth(0.5)
                  .color($r('app.color.divider'))
              }
            }
            .width('100%')
          }
        }, (entry: FileEntry) => entry.path)

      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  NativeFileHeader(): void {
    Navigation() {}
      .mode(NavigationMode.Stack)
      .hideBackButton(true)
      .hideToolBar(true)
      .title({ builder: this.TopFileOverlay, height: this.topSafeInset() + 94 }, {
        barStyle: BarStyle.STACK,
        paddingStart: LengthMetrics.vp(0),
        paddingEnd: LengthMetrics.vp(0),
        backgroundColor: Color.Transparent
      })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .width('100%')
      .height(this.topSafeInset() + 94)
      .backgroundColor(Color.Transparent)
      .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  TopFileOverlay(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      Row()
        .width('100%')
        .height(this.topSafeInset() + 94)
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [
            [$r('app.color.nav_bar_blur_bg'), 0.0],
            [$r('app.color.nav_bar_blur_bg'), 0.32],
            [$r('app.color.nav_bar_gradient_mid'), 0.68],
            [$r('app.color.nav_mask'), 1.0]
          ]
        })
        .linearGradientBlur(20, {
          fractionStops: [
            [1.0, 0.0],
            [0.88, 0.28],
            [0.38, 0.70],
            [0.0, 1.0]
          ],
          direction: GradientDirection.Bottom
        })
        .hitTestBehavior(HitTestMode.None)
        .zIndex(1)

      if (this.showSearch) {
        Row({ space: 8 }) {
          this.OfficialBackButton(() => this.closeSearch())
          Search({ value: this.searchQuery, placeholder: '搜索文件' })
            .layoutWeight(1)
            .height(40)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor(Color.Transparent)
            .borderRadius(20)
            .cancelButton({ style: CancelButtonStyle.INPUT })
            .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true))
            .monopolizeEvents(true)
            .onChange((value: string) => this.scheduleSearch(value))
            .onSubmit((value: string) => this.submitSearch(value))
        }
        .width('100%')
        // Keep the search header in exactly the same layout box as the normal
        // file header. A shorter Row is centered by the parent Stack, which
        // makes the back button visibly drop when Search is opened.
        .height(this.topSafeInset() + 94)
        .padding({ left: 12, right: 12, top: this.topSafeInset() + 8, bottom: 30 })
        .zIndex(2)
        .hitTestBehavior(HitTestMode.Default)
      } else {
        Row() {
          if (this.screen === 'files') {
            // Keep one stable button node while entering/leaving selection.
            // The symbol and action change inside the node; the container is
            // never removed and recreated.
            if (this.rootKind === 'shared' && this.currentPath.length === 0 &&
              !this.selectionMode) {
              // The shared-space root has no parent to return to. Keep the
              // leading slot so the title remains centered, but remove the
              // disabled glass circle that used to appear at the top-left.
              Blank()
                .width(86)
                .height(40)
            } else {
              this.FileHeaderLeadingControl()
            }
          } else if ((this.screen === 'settings' &&
            (this.showStorageSettings || this.showPlaybackSettings || this.showNetworkSettings))) {
            this.OfficialBackButton(() => {
              if (this.showStorageSettings) {
                this.closeStorageSettings()
              } else if (this.showPlaybackSettings) {
                this.closePlaybackSettings()
              } else if (this.showNetworkSettings) {
                this.closeNetworkSettings()
              } else {
                this.openHome()
              }
            })
          } else {
            // 下载页/设置页没有返回按钮，保留同样的侧边占位让标题保持居中，
            // 与文件页顶栏的标题位置一致。
            Blank().width(this.screen === 'downloads' ? 86 : 40)
          }

          // 设置页的标题和共享/下载页完全一致：17vp 居中显示在顶栏渐变区上；
          // 页面说明文字留在内容区，内容区不再重复标题。
          Text(this.selectionMode ? this.selectionTitle() :
            (this.screen === 'settings' && this.showStorageSettings ? '缓存与存储' :
            (this.screen === 'settings' && this.showPlaybackSettings ? '播放与控制' :
            (this.screen === 'settings' && this.showNetworkSettings ? '网络与流量' :
            (this.screen === 'settings' ? '设置' :
              (this.screen === 'downloads' ? '传输' : this.topTitle))))))
            .fontSize(this.selectionMode ? 22 : 17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .opacity(this.selectionMode ? 1 : this.topTitleOpacity)
            .layoutWeight(1)
            .textAlign(this.selectionMode ? TextAlign.Start :
              (this.screen === 'files' && this.currentPath.length > 0
                ? TextAlign.Start : TextAlign.Center))
            .margin({ left: this.selectionMode ? 12 :
              (this.screen === 'files' && this.currentPath.length > 0 ? 8 : 0) })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.screen === 'files') {
            this.FileTopActionCluster()
          } else {
            Blank().width(this.screen === 'downloads' ? 86 : 40)
          }
        }
        .width('100%')
        .height(this.topSafeInset() + 94)
        .padding({ left: 12, right: 12, top: this.topSafeInset() + 8, bottom: 30 })
        .zIndex(2)
        .hitTestBehavior(HitTestMode.Default)
      }

      if (this.showSearch && this.searchQuery.trim().length > 0) {
        Row({ space: 8 }) {
          this.SearchScopeButton('本级', 'current')
          this.SearchScopeButton('跨级', 'descendants')
        }
        .width('100%')
        .height(36)
        .padding({ left: 16, right: 16 })
        .position({ x: 0, y: this.topSafeInset() + 76 })
        .backgroundColor(Color.Transparent)
        .zIndex(3)
        .hitTestBehavior(HitTestMode.Default)
      }
    }
    .width('100%')
    // The blur/gradient child always keeps the file-page height (94vp).
    // Search controls may extend the overlay's transparent hit-test area,
    // but must never stretch the gradient background itself.
    .height(this.topSafeInset() +
      (this.showSearch && this.searchQuery.trim().length > 0 ? 124 : 94))
    .backgroundColor(Color.Transparent)
    .clip(false)
    // The gradient is visual only. The root must not pass a touch started on
    // a floating control into the List below; its child controls remain in
    // the hit-test chain.
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  FileTopActionCluster(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      // This is one persistent material button. In normal mode it is the
      // 62vp "多选" button; in selection mode it moves to the right slot and
      // its label changes in-place to "全选"/"取消全选".
      Button() {
        Stack({ alignContent: Alignment.Center }) {
          Text('多选')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center)
            .width(104)
            .opacity(this.selectionMode ? 0 : 1)
          Text('全选')
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center)
            .width(104)
            .opacity(this.selectionMode && !this.allEntriesSelected() ? 1 : 0)
          Text('取消全选')
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center)
            .width(104)
            .opacity(this.selectionMode && this.allEntriesSelected() ? 1 : 0)
        }
        .width('100%')
        .height('100%')
      }
      .fontSize(16)
      .fontColor($r('app.color.text_primary'))
      .backgroundColor(Color.Transparent)
      .borderRadius(20)
      .width(this.topActionButtonWidth())
      .height(40)
      .padding({ left: 0, right: 0, top: 0, bottom: 0 })
      .position({ x: this.topActionButtonX(), y: 0 })
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true))
      .overlay(this.ImportLightOverlay, { align: Alignment.Center })
      .enabled(this.selectionMode ? this.entries.length > 0 : !this.isBusy)
      .monopolizeEvents(true)
      .onClick(() => {
        if (this.selectionMode) {
          this.toggleSelectAll()
        } else {
          this.enterSelectionMode()
        }
      })
      .animation({ duration: 180, curve: Curve.FastOutSlowIn })

      // The search container also remains in the tree. It fades and disables
      // hit testing while the persistent multi-select button moves over it.
      Button() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(20)
          .fontColor([$r('app.color.icon_primary')])
      }
      .type(ButtonType.Normal)
      .width(40)
      .height(40)
      .borderRadius(20)
      .backgroundColor(Color.Transparent)
      .position({ x: 68, y: 0 })
      .opacity(this.selectionMode ? 0 : 1)
      .enabled(!this.selectionMode)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true))
      .overlay(this.ImportLightOverlay, { align: Alignment.Center })
      .monopolizeEvents(true)
      .onClick(() => this.openSearch())
      .animation({ duration: 180, curve: Curve.FastOutSlowIn })
    }
    .width(110)
    .height(40)
  }

  @Builder
  SettingsContent(): void {
    if (this.showStorageSettings) {
      this.StorageSettingsContent()
    } else if (this.showPlaybackSettings) {
      this.PlaybackSettingsContent()
    } else if (this.showNetworkSettings) {
      this.NetworkSettingsContent()
    } else {
      Scroll() {
        Column({ space: 16 }) {
          Text('管理缓存、播放与网络策略')
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')

          Column() {
            this.SettingsEntryRow($r('sys.symbol.folder'), '#2E6BFF', '缓存与存储',
              '查看占用、调整上限和清理缓存', () => this.openStorageSettings(), false)
            this.SettingsGroupDivider()
            this.SettingsEntryRow($r('sys.symbol.play'), '#7A5AF8', '播放与控制',
              '管理自动播放、后台播放和视频小窗', () => this.openPlaybackSettings(), false)
            this.SettingsGroupDivider()
            this.SettingsEntryRow($r('sys.symbol.wifi'), '#0FA47F', '网络与流量',
              '管理移动网络下的加载、刷新和下载策略', () => this.openNetworkSettings(), false)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .borderRadius(20)
          .clip(true)
          .backgroundColor($r('app.color.surface_card'))

          Column() {
            this.SettingsEntryRow($r('sys.symbol.person_badge_nosign'), '#D34D5C', '退出账号', '',
              () => {
                if (!this.isBusy) {
                  this.confirmLogout()
                }
              }, true)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .borderRadius(20)
          .clip(true)
          .backgroundColor($r('app.color.surface_card'))
          .opacity(this.isBusy ? 0.5 : 1)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 20, right: 20, top: this.topSafeInset() + 76,
          bottom: this.floatingBarContentInset(40) })
      }
      .width('100%')
      .height('100%')
      // align 的默认值是 Alignment.Center：当子内容比视口矮时，Scroll 会把内容
      // 垂直居中。这里显式置顶，避免设置页内容浮在页面中间。
      .align(Alignment.TopStart)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .scrollBar(BarState.Auto)
    }
  }

  // 设置页行项：40vp 圆角色块 + 白色符号 + 标题/说明 + 右侧 chevron，
  // 对齐官方 UI Design Kit《设置列表卡片样式》的列表卡片设计语言。
  // 底色统一使用实体色：官方文档明确沉浸光感对普通容器只在 Navigation
  // 标题栏或底部 TabBar 区域内生效，放在页面内容区不会渲染，因此卡片
  // 不能再依赖 systemMaterial 提供背景。
  @Builder
  SettingsEntryRow(icon: Resource, chipColor: string, title: string, description: string,
    onTap: () => void, destructive: boolean) {
    Row() {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(21)
          .fontColor([Color.White])
      }
      .width(40)
      .height(40)
      .borderRadius(13)
      .backgroundColor(chipColor)

      Column({ space: 3 }) {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(destructive ? chipColor : $r('app.color.text_primary'))
        if (description.length > 0) {
          Text(description)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })

      // 只有会进入二级页面的行才显示 chevron；退出账号是直接动作，不显示。
      if (!destructive) {
        SymbolGlyph($r('sys.symbol.chevron_forward'))
          .fontSize(16)
          .fontColor([$r('app.color.icon_muted')])
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .onClick(onTap)
  }

  @Builder
  SettingsGroupDivider(): void {
    Divider()
      .width('calc(100% - 84vp)')
      .strokeWidth(0.5)
      .color($r('app.color.divider'))
      .margin({ left: 68 })
  }

  @Builder
  StorageSettingsContent(): void {
    Scroll() {
      Column({ space: 16 }) {
        Text('持久化缓存保留缩略图、目录和显示设置。临时缓存包括原文件及断点数据，空间不足时按最近访问时间替换；已完成的下载文件保存在系统下载目录，不计入缓存。')
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
          .lineHeight(22)
          .width('100%')

        Column({ space: 10 }) {
          Text('持久化缓存').fontSize(15).width('100%')
          Text(this.formatStorageSize(this.persistentUsageBytes) + ' / 512 MB（保护上限）')
            .fontSize(16).width('100%')
          Text('自动优先淘汰旧缩略图，保留旋转方向等设置。')
            .fontSize(12).fontColor($r('app.color.text_tertiary')).width('100%')
        }
        .width('100%').padding(16).backgroundColor($r('app.color.surface_card')).borderRadius(14)

        Column({ space: 10 }) {
          Row() {
            Text('临时缓存占用')
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
            Text(this.formatStorageSize(this.cacheUsageBytes))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
          }
          .width('100%')
          Row() {
            Text('缓存上限')
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
            Text(this.formatStorageSize(this.cacheLimitBytes))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#2E6BFF')
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface_card'))
        .borderRadius(14)

        Text('选择缓存上限')
          .fontSize(15)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Row({ space: 8 }) {
          this.CacheLimitButton(CacheManager.LIMIT_100_MB)
          this.CacheLimitButton(CacheManager.LIMIT_500_MB)
          this.CacheLimitButton(CacheManager.LIMIT_1_GB)
        }
        .width('100%')
        Row({ space: 8 }) {
          this.CacheLimitButton(CacheManager.LIMIT_2_GB)
          this.CacheLimitButton(CacheManager.LIMIT_5_GB)
        }
        .width('100%')

        Button(this.isBusy ? '处理中…' : '清理临时缓存')
          .width('100%')
          .height(48)
          .fontSize(15)
          .fontColor('#D34D5C')
          .backgroundColor('#33D34D5C')
          .borderRadius(14)
          .enabled(!this.isBusy)
          .onClick(() => this.clearCache())

        if (this.statusText.length > 0) {
          Text(this.statusText)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .lineHeight(20)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start)
      .padding({ left: 20, right: 20, top: this.topSafeInset() + 76, bottom: this.bottomSafeInset() + 112 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .scrollBar(BarState.Auto)
  }

  @Builder
  PlaybackSettingsContent(): void {
    Scroll() {
      Column({ space: 16 }) {
        Text('设置进入播放器和切换到后台时的播放行为。')
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
          .lineHeight(22)
          .width('100%')

        Column({ space: 12 }) {
          Row() {
            Column({ space: 4 }) {
              Text('进入后自动播放')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text('打开视频或音频后立即开始播放；关闭后先停在暂停状态')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.autoPlayOnOpen })
              .selectedColor('#2E6BFF')
              .enabled(!this.isBusy)
              .onChange((value: boolean) => this.setAutoPlayOnOpen(value))
          }
          .width('100%')

          Row() {
            Column({ space: 4 }) {
              Text('视频后台播放')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text('切换到其他应用后继续播放视频；关闭后进入后台自动暂停')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.backgroundVideoPlayback })
              .selectedColor('#2E6BFF')
              .enabled(!this.isBusy)
              .onChange((value: boolean) => this.setBackgroundVideoPlayback(value))
          }
          .width('100%')

          Row() {
            Column({ space: 4 }) {
              Text('音频后台播放')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text('切换到其他应用后继续播放音频；关闭后进入后台自动暂停')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.backgroundAudioPlayback })
              .selectedColor('#2E6BFF')
              .enabled(!this.isBusy)
              .onChange((value: boolean) => this.setBackgroundAudioPlayback(value))
          }
          .width('100%')

          Row() {
            Column({ space: 4 }) {
              Text('视频后台自动进入小窗')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text(this.backgroundVideoPlayback
                ? '播放中的视频进入后台时自动切换到小窗'
                : '请先开启视频后台播放')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.videoBackgroundAutoPip })
              .selectedColor('#2E6BFF')
              .enabled(!this.isBusy && this.backgroundVideoPlayback)
              .onChange((value: boolean) => this.setVideoBackgroundAutoPip(value))
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .borderRadius(14)
        .backgroundColor($r('app.color.surface_card'))

        if (this.statusText.length > 0) {
          Text(this.statusText)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .lineHeight(20)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start)
      .padding({ left: 20, right: 20, top: this.topSafeInset() + 76,
        bottom: this.bottomSafeInset() + 112 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .scrollBar(BarState.Auto)
  }

  @Builder
  NetworkSettingsContent(): void {
    Scroll() {
      Column({ space: 16 }) {
        Text('管理移动网络下的原图加载、目录刷新和下载策略。WiFi 下不受这些开关限制。')
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
          .lineHeight(22)
          .width('100%')

        Column({ space: 12 }) {
          Row() {
            Column({ space: 4 }) {
              Text('当前网络')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text('未知网络按移动网络策略处理')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text(this.networkClass === 'unmetered' ? 'WiFi' :
              (this.networkClass === 'metered' ? '移动网络' :
                (this.networkClass === 'offline' ? '无网络' : '网络状态未知')))
              .fontSize(14)
              .fontColor(this.networkClass === 'unmetered'
                ? '#2E6BFF' : $r('app.color.text_secondary'))
          }
          .width('100%')

          Row() {
            Column({ space: 4 }) {
              Text('移动网络自动加载原图')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text('开启后自动加载当前图片，并预加载相邻图片')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.meteredAutoOriginal })
              .selectedColor('#2E6BFF')
              .onChange((value: boolean) => this.setMeteredAutoOriginal(value))
          }
          .width('100%')

          Row() {
            Column({ space: 4 }) {
              Text('移动网络后台刷新')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text('允许缓存目录在后台自动更新，可能消耗少量流量')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.meteredBackgroundRefresh })
              .selectedColor('#2E6BFF')
              .onChange((value: boolean) => this.setMeteredBackgroundRefresh(value))
          }
          .width('100%')

          Row() {
            Column({ space: 4 }) {
              Text('移动网络继续下载')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text('关闭时从 WiFi 切换到移动网络会自动暂停；点击下载任务仍可手动继续')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.meteredDownloadContinue })
              .selectedColor('#2E6BFF')
              .onChange((value: boolean) => this.setMeteredDownloadContinue(value))
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .borderRadius(14)
        .backgroundColor($r('app.color.surface_card'))

        if (this.statusText.length > 0) {
          Text(this.statusText)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .lineHeight(20)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start)
      .padding({ left: 20, right: 20, top: this.topSafeInset() + 76, bottom: this.bottomSafeInset() + 112 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .scrollBar(BarState.Auto)
  }

  @Builder
  BottomBar(): void {
    // 三态共用一个常驻外壳。外壳是 Tabs 的底部页签区，沉浸式材质才在生效
    // 范围内；内部三层内容全部常驻，只改 opacity/translate，节点不重建。
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() {}.tabBar(this.BottomBarContent)
    }
    .vertical(false)
    .scrollable(false)
    .barOverlap(true)
    // 原来的悬浮底栏靠 barFloatingStyle 的 barBottomMargin=40 把胶囊抬高 40vp；
    // 这里改成普通内容后，用 barHeight 预留出同样的 40vp，位置完全还原。
    .barHeight(FLOATING_BAR_HEIGHT_VP + FLOATING_BAR_EFFECT_TOP_INSET_VP + 40)
    // This Tabs instance only supplies the supported bottom-TabBar material
    // scope. Its own rectangular bar must stay visually transparent.
    .barBackgroundColor(Color.Transparent)
    .barBackgroundBlurStyle(BlurStyle.NONE)
    .width('100%')
    .height(FLOATING_BAR_HEIGHT_VP + FLOATING_BAR_EFFECT_TOP_INSET_VP + 80)
    .margin({ bottom: this.floatingBarBottomMargin() - 40 })
    .clip(false)
    .hitTestBehavior(HitTestMode.Default)
  }

  @Builder
  BottomBarContent(): void {
    Stack({ alignContent: Alignment.Bottom }) {
      // 首页 / 共享 / 下载 / 设置
      Stack() {
        this.HomeBarContent()
      }
      .width('100%')
      .height(FLOATING_BAR_HEIGHT_VP)
      .opacity(this.bottomBarMode() === 'home' ? 1 : 0)
      .translate({ x: 0, y: this.bottomBarMode() === 'home' ? 0 : 12, z: 0 })
      .hitTestBehavior(this.bottomBarMode() === 'home' ? HitTestMode.Default : HitTestMode.None)
      .animation({ duration: 200, curve: Curve.FastOutSlowIn })

      // 多选操作
      Stack() {
        this.SelectionBarContent()
      }
      .width('100%')
      .height(FLOATING_BAR_HEIGHT_VP)
      .opacity(this.bottomBarMode() === 'selection' ? 1 : 0)
      .translate({ x: 0, y: this.bottomBarMode() === 'selection' ? 0 : 12, z: 0 })
      .hitTestBehavior(this.bottomBarMode() === 'selection' ? HitTestMode.Default : HitTestMode.None)
      .animation({ duration: 200, curve: Curve.FastOutSlowIn })

      // 文件详情页：左圆钮 + 中间排序胶囊 + 右圆钮
      Stack() {
        this.FileToolsBarContent()
      }
      .width('100%')
      .height(FLOATING_BAR_HEIGHT_VP)
      .opacity(this.bottomBarMode() === 'tools' ? 1 : 0)
      .translate({ x: 0, y: this.bottomBarMode() === 'tools' ? 0 : 12, z: 0 })
      .hitTestBehavior(this.bottomBarMode() === 'tools' ? HitTestMode.Default : HitTestMode.None)
      .animation({ duration: 200, curve: Curve.FastOutSlowIn })
    }
    .width('100%')
    .height(FLOATING_BAR_HEIGHT_VP + FLOATING_BAR_EFFECT_TOP_INSET_VP)
    // The visible 56vp controls stay bottom-aligned at their previous screen
    // position. The extra top area only carries native shadow/deformation.
    .margin({ bottom: 40 })
    .hitTestBehavior(HitTestMode.Default)
  }

  @Builder
  HomeBarContent(): void {
    Stack({ alignContent: Alignment.Center }) {
      Row() {
        this.BottomNavItem($r('sys.symbol.house'), '主页', 'home', () => this.openHome())
        this.BottomNavItem($r('sys.symbol.folder'), '共享', 'shared', () => this.openShared())
        this.BottomNavItem($r('sys.symbol.arrow_2_circlepath'), '传输', 'downloads',
          () => this.openDownloads())
        this.BottomNavItem($r('sys.symbol.gearshape'), '设置', 'settings', () => this.openSettings())
      }
      .width('100%')
      .height('100%')
      .padding({ left: 8, right: 8, top: 0, bottom: 0 })

      ProximityLightReceiver()
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
    }
    .width(this.bottomBarCapsuleWidth())
    .height(FLOATING_BAR_HEIGHT_VP)
    .borderRadius(FLOATING_BAR_HEIGHT_VP / 2)
    .systemMaterial(this.bottomCapsuleMaterial)
    // The capsule is above the scrolling page. Keep a drag that starts here
    // inside the capsule instead of letting the underlying List receive it.
    .hitTestBehavior(this.bottomBarMode() === 'home' ? HitTestMode.Default : HitTestMode.None)
  }

  @Builder
  FileToolsBarContent(): void {
    Stack() {
      Row() {
        this.FileToolCircleButton($r('sys.symbol.folder_badge_plus'), () => this.openCreateFolder())

        Button() {
          Row({ space: 6 }) {
            Text(this.fileSortTitle())
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
            SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
              .fontSize(10)
              .fontColor([$r('app.color.icon_primary')])
              .rotate({ angle: this.showFileSortMenu ? 180 : 0 })
          }
          .justifyContent(FlexAlign.Center)
        }
        .type(ButtonType.Normal)
        .width(FILE_TOOL_SORT_WIDTH_VP)
        .height(FLOATING_BAR_HEIGHT_VP)
        .borderRadius(FLOATING_BAR_HEIGHT_VP / 2)
        .backgroundColor(Color.Transparent)
        .systemMaterial(this.bottomCapsuleMaterial)
        .hitTestBehavior(this.bottomBarMode() === 'tools' ? HitTestMode.Default : HitTestMode.None)
        .monopolizeEvents(this.bottomBarMode() === 'tools')
        .onClick(() => this.toggleFileSortMenu())
        .bindPopup(this.showFileSortMenu, {
          builder: this.FileSortPopup,
          placement: Placement.Top,
          maskColor: Color.Transparent,
          enableArrow: false,
          autoCancel: true,
          // CustomPopupOptions exposes the official transition hook. The SDK does
          // not provide a HarmonyOS 7-only sort-popup animation name; keep the
          // popup on ArkUI's supported transition path instead of faking one.
          transition: this.fileSortPopupTransition(),
          systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.THICK, false),
          onStateChange: (state: PopupStateChange): void => {
            if (!state.isVisible) {
              this.showFileSortMenu = false
            }
          }
        })

        this.FileToolCircleButton(this.fileViewModeIcon(), () => this.toggleFileViewMode())
      }
      .width('100%')
      .height(FLOATING_BAR_HEIGHT_VP)
      .padding({ left: 16, right: 16 })
      .justifyContent(FlexAlign.SpaceBetween)
      // 原来的 40vp 圆钮/排序胶囊在 120vp 栏里居中，底边距栏底 40vp；
      // 这里靠底对齐还原同一个位置。
      .alignItems(VerticalAlign.Bottom)

      // One canvas draws the three real material outlines. This keeps the
      // moving light continuous without introducing a full-width outline.
      ProximityLightReceiver({ mode: 'fileTools' })
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height(FLOATING_BAR_HEIGHT_VP)
    .hitTestBehavior(this.bottomBarMode() === 'tools' ? HitTestMode.Default : HitTestMode.None)
  }

  @Builder
  SelectionBarContent(): void {
    Row() {
      this.SelectionActionButton($r('sys.symbol.share'), '分享',
        () => this.shareSelectedEntries())
      this.SelectionActionButton($r('sys.symbol.doc'), '复制',
        () => this.beginSelectionDestinationPicker('copy'))
      this.SelectionActionButton($r('sys.symbol.trash'), '删除',
        () => this.deleteSelectedEntries())
      this.SelectionMoreButton()
    }
    .id('selection_bottom_bar_' + this.selectedEntryCount.toString())
    .width(this.bottomBarCapsuleWidth())
    .height(FLOATING_BAR_HEIGHT_VP)
    .padding({ left: 8, right: 8, top: 0, bottom: 0 })
    .borderRadius(FLOATING_BAR_HEIGHT_VP / 2)
    .systemMaterial(this.bottomCapsuleMaterial)
    .hitTestBehavior(this.bottomBarMode() === 'selection' ? HitTestMode.Default : HitTestMode.None)
  }

  @Builder
  SelectionActionButton(icon: Resource, title: string, action: () => void): void {
    Button() {
      Column({ space: 2 }) {
        SymbolGlyph(icon)
          .fontSize(24)
          .fontColor([this.selectionActionEnabled(title)
            ? $r('app.color.icon_primary') : $r('app.color.icon_muted')])
        Text(title)
          .fontSize(12)
          .fontColor(this.selectionActionEnabled(title)
            ? $r('app.color.text_primary') : $r('app.color.text_muted'))
      }
      .justifyContent(FlexAlign.Center)
    }
    .type(ButtonType.Normal)
    .layoutWeight(1)
    .height(FLOATING_BAR_HEIGHT_VP)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .stateEffect(false)
    .enabled(this.selectionActionEnabled(title))
    .hitTestBehavior(this.bottomBarMode() === 'selection' ? HitTestMode.Default : HitTestMode.None)
    .monopolizeEvents(this.bottomBarMode() === 'selection')
    .onClick(() => action())
  }

  @Builder
  SelectionMoreButton(): void {
    Button() {
      Column({ space: 2 }) {
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .fontSize(24)
          .fontColor([this.selectedEntryCount > 0
            ? $r('app.color.icon_primary') : $r('app.color.icon_muted')])
        Text('更多')
          .fontSize(12)
          .fontColor(this.selectedEntryCount > 0
            ? $r('app.color.text_primary') : $r('app.color.text_muted'))
      }
      .justifyContent(FlexAlign.Center)
    }
    .type(ButtonType.Normal)
    .layoutWeight(1)
    .height(FLOATING_BAR_HEIGHT_VP)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .stateEffect(false)
    .enabled(this.selectedEntryCount > 0)
    .hitTestBehavior(this.bottomBarMode() === 'selection' ? HitTestMode.Default : HitTestMode.None)
    .monopolizeEvents(this.bottomBarMode() === 'selection')
    .onClick(() => this.toggleSelectionMoreMenu())
    .bindPopup(this.showSelectionMoreMenu, {
      builder: this.SelectionMorePopup,
      placement: Placement.Top,
      maskColor: Color.Transparent,
      enableArrow: false,
      autoCancel: true,
      transition: this.fileSortPopupTransition(),
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.THICK, false),
      onStateChange: (state: PopupStateChange): void => {
        if (!state.isVisible) {
          this.showSelectionMoreMenu = false
        }
      }
    })
  }

  @Builder
  SelectionMorePopup(): void {
    Column() {
      this.SelectionMoreRow($r('sys.symbol.folder'), '移动',
        () => this.beginSelectionDestinationPicker('move'))
      this.SelectionMoreRow($r('sys.symbol.square_and_arrow_down'), '下载',
        () => this.downloadSelectedEntries())

      if (this.selectedPaths.length === 1) {
        if (this.selectedSingleEntry() !== null &&
          this.actionSupportsOpenWith(this.selectedSingleEntry() as FileEntry)) {
          this.SelectionMoreRow($r('sys.symbol.square_and_arrow_down'), '其他应用打开',
            () => this.openWithSelectedEntry(this.selectedSingleEntry() as FileEntry))
        }
        if (this.selectedSingleEntry() !== null &&
          this.actionSupportsQuickView(this.selectedSingleEntry() as FileEntry)) {
          this.SelectionMoreRow($r('sys.symbol.play'), '快速查看',
            () => this.quickViewSelectedEntry(this.selectedSingleEntry() as FileEntry))
        }
        if (this.selectedSingleEntry() !== null &&
          !(this.selectedSingleEntry() as FileEntry).isDirectory &&
          this.isMedia(this.selectedSingleEntry() as FileEntry)) {
          this.SelectionMoreRow($r('sys.symbol.doc'), '保存图库',
            () => this.saveSelectedGallery(this.selectedSingleEntry() as FileEntry))
        }
        if (this.selectedSingleEntry() !== null &&
          this.actionHasLocalCache(this.selectedSingleEntry() as FileEntry)) {
          this.SelectionMoreRow($r('sys.symbol.arrow_down'), '释放缓存',
            () => this.releaseSelectedCaches())
        }
        if (this.selectedSingleEntry() !== null) {
          this.SelectionMoreRow($r('sys.symbol.doc_text'), '重命名',
            () => this.renameSelectedEntry(this.selectedSingleEntry() as FileEntry))
          this.SelectionMoreRow($r('sys.symbol.doc'), '详情',
            () => this.showEntryDetailsSelected(this.selectedSingleEntry() as FileEntry))
        }
      } else if (this.selectedCachedEntries().length > 0) {
        this.SelectionMoreRow($r('sys.symbol.arrow_down'), '释放缓存',
          () => this.releaseSelectedCaches())
      }
    }
    .width(228)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(22)
    .hitTestBehavior(HitTestMode.Default)
  }

  @Builder
  SelectionMoreRow(icon: Resource, title: string, action: () => void): void {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      SymbolGlyph(icon)
        .fontSize(21)
        .fontColor([$r('app.color.icon_primary')])
        .width(30)
    }
    .width('100%')
    .height(48)
    .padding({ left: 10, right: 8 })
    .borderRadius(14)
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      this.showSelectionMoreMenu = false
      action()
    })
  }

  @Builder
  ImportLightOverlay(): void {
    ProximityLightReceiver()
      .width('100%').height('100%')
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  FileToolCircleButton(icon: Resource, action: () => void): void {
    Button() {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([$r('app.color.icon_primary')])
    }
    .type(ButtonType.Normal)
    .width(FLOATING_BAR_HEIGHT_VP)
    .height(FLOATING_BAR_HEIGHT_VP)
    .borderRadius(FLOATING_BAR_HEIGHT_VP / 2)
    .backgroundColor(Color.Transparent)
    .systemMaterial(this.bottomCapsuleMaterial)
    .hitTestBehavior(this.bottomBarMode() === 'tools' ? HitTestMode.Default : HitTestMode.None)
    .monopolizeEvents(this.bottomBarMode() === 'tools')
    .onClick(action)
  }

  @Builder
  FileSortPopup(): void {
    Column() {
      this.FileSortOption('名称', 'name')
      this.FileSortOption('类型', 'type')
      this.FileSortOption('时间', 'time')
      this.FileSortOption('大小', 'size')
    }
    .width(226)
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(24)
    .hitTestBehavior(HitTestMode.Default)
  }

  private fileSortPopupTransition(): TransitionEffect {
    const appear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.scale({ x: 0.94, y: 0.94, z: 1 }))
      .animation({
        duration: 260,
        curve: curves.interpolatingSpring(0, 1, 320, 30)
      })
    const disappear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.scale({ x: 0.98, y: 0.98, z: 1 }))
      .animation({ duration: 180, curve: Curve.EaseOut })
    return TransitionEffect.asymmetric(appear, disappear)
  }

  /**
   * Official ArkUI transition used by the centered create-folder dialog.
   * The SDK exposes no separate HarmonyOS 7-only animation name; the
   * interpolating spring is the documented ArkUI curve for this kind of
   * modal appearance and dismissal.
   */
  private createFolderDialogTransition(): TransitionEffect {
    const appear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.scale({ x: 0.92, y: 0.92, z: 1 }))
      .animation({
        duration: 280,
        curve: curves.interpolatingSpring(0, 1, 320, 30)
      })
    const disappear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.scale({ x: 0.98, y: 0.98, z: 1 }))
      .animation({
        duration: 180,
        curve: Curve.EaseOut
      })
    return TransitionEffect.asymmetric(appear, disappear)
  }

  /**
   * Official ArkUI transition for the copy/move destination sheet.
   * The sheet is a bottom card: it enters from the bottom edge and returns
   * to that same edge when dismissed. The safe-area layer and the underlying
   * file-management page stay in place while the card moves above them.
   */
  private destinationPickerSurfaceTransition(): TransitionEffect {
    const appear = TransitionEffect.move(TransitionEdge.BOTTOM)
      .combine(TransitionEffect.opacity(0))
      .animation({
        duration: 340,
        curve: curves.interpolatingSpring(0, 1, 320, 30)
      })
    const disappear = TransitionEffect.move(TransitionEdge.BOTTOM)
      .combine(TransitionEffect.opacity(0))
      .animation({
        duration: 240,
        curve: Curve.EaseIn
      })
    return TransitionEffect.asymmetric(appear, disappear)
  }

  /**
   * Short, interruptible transition for the destination folder list. The
   * list layout itself is animated by animateTo when the root is expanded or
   * collapsed; this transition handles the list entering and leaving the
   * Scroll content without a hard visual pop.
   */
  private destinationFolderListTransition(): TransitionEffect {
    const appear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.scale({ x: 0.985, y: 0.985, z: 1 }))
      .animation({
        duration: 220,
        curve: curves.interpolatingSpring(0, 1, 320, 30)
      })
    const disappear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.scale({ x: 1, y: 1, z: 1 }))
      .animation({
        duration: 150,
        curve: Curve.EaseOut
      })
    return TransitionEffect.asymmetric(appear, disappear)
  }

  @Builder
  FileSortOption(title: string, key: FileSortKey): void {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      if (this.fileSortKey === key) {
        SymbolGlyph(this.fileSortAscending
          ? $r('sys.symbol.arrow_up')
          : $r('sys.symbol.arrow_down'))
          .fontSize(20)
          .fontColor([$r('app.color.icon_primary')])
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 10, right: 8 })
    .borderRadius(14)
    .backgroundColor(Color.Transparent)
    .onClick(() => this.selectFileSort(key))
    if (key !== 'size') {
      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color($r('app.color.divider'))
    }
  }

  @Builder
  BottomNavItem(icon: Resource, title: string, tab: BottomTab, action: () => void): void {
    Column({ space: 2 }) {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(24)
          .fontColor([this.selectedBottomTab === tab ? '#2E6BFF' : $r('app.color.icon_primary')])
      }
      .width('100%')
      .height(24)

      Text(title)
        .fontSize(12)
        .fontWeight(this.selectedBottomTab === tab ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.selectedBottomTab === tab ? '#2E6BFF' : $r('app.color.text_primary'))
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    // 非当前形态的层仍挂在树上（材质不重建），但子按钮必须退出命中测试，
    // 否则 monopolizeEvents 会越过父级 HitTestMode.None 挡住可见层。
    .hitTestBehavior(this.bottomBarMode() === 'home' ? HitTestMode.Default : HitTestMode.None)
    .monopolizeEvents(this.bottomBarMode() === 'home')
    .onClick(action)
  }

  @Builder
  OfficialBackButton(action: () => void): void {
    Button() {
      SymbolGlyph($r('sys.symbol.chevron_backward'))
        .fontSize(21)
        .fontColor([$r('app.color.icon_primary')])
    }
    .type(ButtonType.Normal)
    .width(40)
    .height(40)
    .borderRadius(20)
    .backgroundColor(Color.Transparent)
    .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN))
    .overlay(this.ImportLightOverlay, { align: Alignment.Center })
    .hitTestBehavior(HitTestMode.Default)
    .monopolizeEvents(true)
    .onClick(action)
  }

  @Builder
  FileHeaderLeadingControl(): void {
    Stack({ alignContent: Alignment.Center }) {
      Button() {
        Stack({ alignContent: Alignment.Center }) {
          // Both symbols are mounted once. Selection only cross-fades the
          // glyphs, so the material circle does not blink or get recreated.
          SymbolGlyph($r('sys.symbol.chevron_backward'))
            .fontSize(21)
            .fontColor([$r('app.color.icon_primary')])
            .opacity(this.selectionMode ? 0 : (this.currentPath.length > 0 ? 1 : 0))
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(21)
            .fontColor([$r('app.color.icon_primary')])
            .opacity(this.selectionMode ? 1 : 0)
        }
        .width('100%')
        .height('100%')
      }
      .type(ButtonType.Normal)
      .width(40)
      .height(40)
      .borderRadius(20)
      .backgroundColor(Color.Transparent)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN))
      .enabled(this.fileHeaderLeadingVisible())
      .overlay(this.ImportLightOverlay, { align: Alignment.Center })
      .hitTestBehavior(this.fileHeaderLeadingVisible() ? HitTestMode.Default : HitTestMode.None)
      .monopolizeEvents(true)
      .onClick(() => {
        if (this.selectionMode) {
          this.exitSelectionMode()
        } else if (this.currentPath.length > 0) {
          this.goBack()
        }
      })
      .animation({ duration: 180, curve: Curve.FastOutSlowIn })
    }
    .width(this.fileHeaderLeadingWidth())
    .height(40)
    .animation({ duration: 180, curve: Curve.FastOutSlowIn })
  }

  @Builder
  SelectionCloseButton(action: () => void): void {
    Button() {
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(21)
        .fontColor([$r('app.color.icon_primary')])
    }
    .type(ButtonType.Normal)
    .width(40)
    .height(40)
    .borderRadius(20)
    .backgroundColor(Color.Transparent)
    .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN))
    .hitTestBehavior(HitTestMode.Default)
    .monopolizeEvents(true)
    .onClick(action)
  }

  @Builder
  CacheLimitButton(value: number): void {
    Button(this.formatStorageSize(value))
      .layoutWeight(1)
      .height(44)
      .fontSize(14)
      .fontColor(this.cacheLimitBytes === value ? Color.White : $r('app.color.text_secondary'))
      .backgroundColor(this.cacheLimitBytes === value ? '#2E6BFF' : $r('app.color.surface_card'))
      .borderRadius(12)
      .enabled(!this.isBusy)
      .onClick(() => this.setCacheLimit(value))
  }

  /**
   * Native ContextMenu preview.  The preview and the action list are two
   * separate builders so ArkUI owns their preview movement and dismissal.
   */
  @Builder
  ActionContextPreview(entry: FileEntry): void {
    Navigation() {}
      .mode(NavigationMode.Stack)
      .hideBackButton(true)
      .hideToolBar(true)
      .title({ builder: this.ActionContextPreviewCard.bind(this, entry), height: 58 }, {
        barStyle: BarStyle.STACK,
        paddingStart: LengthMetrics.vp(0),
        paddingEnd: LengthMetrics.vp(0),
        backgroundColor: Color.Transparent
      })
      .width(Math.min(324, this.effectivePageWidth() - 52))
      .height(58)
      .backgroundColor(Color.Transparent)
      .clip(false)
  }

  @Builder
  ActionMenuOverlay(): void {
    Column() {}
      .width(Math.min(324, this.effectivePageWidth() - 52))
      .height(58)
      .position({ x: 26, y: this.contextMenuSourceY })
      .hitTestBehavior(HitTestMode.None)
      .bindContextMenu(this.contextMenuVisible, this.NativeActionMenuContent, {
        preview: this.NativeActionMenuPreview,
        previewAnimationOptions: { scale: [1, 1] },
        placement: Placement.BottomLeft,
        borderRadius: 22,
        transition: this.actionMenuSurfaceTransition(),
        systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.THICK, false),
        onWillDisappear: () => { this.contextMenuVisible = false },
        onDidDisappear: () => this.finishActionMenuDismiss()
      })
  }

  @Builder
  NativeActionMenuPreview(): void {
    if (this.contextMenuEntry !== null) {
      this.ActionContextPreview(this.contextMenuEntry as FileEntry)
    }
  }

  @Builder
  NativeActionMenuContent(): void {
    if (this.contextMenuEntry !== null) {
      this.ActionContextMenu(this.contextMenuEntry as FileEntry)
    }
  }

  @Builder
  ActionContextPreviewCard(entry: FileEntry): void {
    Row() {
      this.FileLeadingVisual(entry)
      Column({ space: 2 }) {
        Text(entry.name)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.entryInfo(entry).length > 0) {
          Text(this.entryInfo(entry))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
    }
    .width('100%')
    .height(58)
    .padding({ left: 12, right: 12 })
    .borderRadius(20)
    .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, false))
  }

  /**
   * Native ContextMenu content.  Widths and section rhythm follow the Files
   * reference: a compact menu (224vp) below a wider selected-item card,
   * with quick actions in the first group and destructive actions at the end.
   */
  @Builder
  ActionContextMenu(entry: FileEntry): void {
    Menu() {
      MenuItem() {
        Scroll() {
          Column() {
            Row() {
              if (entry.isDirectory) {
                this.ActionQuickButton($r('sys.symbol.doc'), '复制',
                  () => this.beginDestinationPicker('copy', entry))
                this.ActionQuickButton($r('sys.symbol.folder'), '移动',
                  () => this.beginDestinationPicker('move', entry))
              } else {
                if (this.actionSupportsShare(entry)) {
                  this.ActionQuickButton($r('sys.symbol.share'), '分享',
                    () => this.shareViewerImage(entry))
                }
                this.ActionQuickButton($r('sys.symbol.doc'), '复制',
                  () => this.beginDestinationPicker('copy', entry))
                this.ActionQuickButton($r('sys.symbol.folder'), '移动',
                  () => this.beginDestinationPicker('move', entry))
              }
            }
            .width('100%')
            .height(58)

            this.ActionSectionGap()

            if (!entry.isDirectory && this.actionSupportsOpenWith(entry)) {
              this.ActionMenuRow($r('sys.symbol.square_and_arrow_down'), '其他应用打开',
                () => this.openWithOtherApp(entry), false, true)
              this.ActionSectionGap()
            }

            if (!entry.isDirectory && this.actionSupportsQuickView(entry)) {
              this.ActionMenuRow($r('sys.symbol.play'), '快速查看',
                () => this.quickView(entry), false, false)
            }
            this.ActionMenuRow($r('sys.symbol.list_bullet_square'), '多选',
              () => this.enterSelection(entry), false, false)
            this.ActionMenuRow($r('sys.symbol.square_and_arrow_down'), '下载',
              () => this.downloadEntryFromMenu(entry), false, false)
            if (!entry.isDirectory && this.isMedia(entry)) {
              this.ActionMenuRow($r('sys.symbol.doc'), '保存图库',
                () => this.saveToGallery(entry), false, !this.actionHasLocalCache(entry))
            }
            if (!entry.isDirectory && this.actionHasLocalCache(entry)) {
              this.ActionMenuRow($r('sys.symbol.arrow_down'), '释放缓存',
                () => this.releaseCache(entry), false, false)
            }
            this.ActionMenuRow($r('sys.symbol.doc_text'), '重命名',
              () => this.openRename(entry), false, true)

            this.ActionSectionGap()

            this.ActionMenuRow($r('sys.symbol.doc'), '详情',
              () => this.showEntryDetails(entry), false, false)
            this.ActionMenuRow($r('sys.symbol.trash'), '删除',
              () => this.deleteEntry(entry), true, true)
          }
          .width('100%')
        }
        .width(Math.min(224, this.effectivePageWidth() - 52))
        .height(this.actionMenuHeight(entry))
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .borderRadius(22)
        .clip(true)
      }
      .padding(0)
    }
    .width(Math.min(224, this.effectivePageWidth() - 52))
    .padding(0)
  }

  @Builder
  ActionSectionGap(): void {
    Row()
      .width('100%')
      .height(8)
      .backgroundColor(this.isDarkTheme ? '#18FFFFFF' : '#12000000')
  }

  @Builder
  ActionQuickButton(icon: Resource, title: string, action: () => void): void {
    Column({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(23)
        .fontColor([$r('app.color.icon_primary')])
      Text(title)
        .fontSize(12)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .height(58)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Color.Transparent)
    .borderRadius(14)
    .onClick(() => this.runContextAction(action))
  }

  @Builder
  ActionMenuRow(icon: Resource, title: string, action: () => void, danger: boolean = false,
    last: boolean = false): void {
    Column() {
      Row() {
        Text(title)
          .fontSize(16)
          .fontColor(danger ? '#D34D5C' : $r('app.color.text_primary'))
          .layoutWeight(1)
        SymbolGlyph(icon)
          .fontSize(21)
          .fontColor([danger ? '#D34D5C' : $r('app.color.icon_primary')])
          .width(30)
      }
      .width('100%')
      .height(50)
      .padding({ left: 16, right: 10 })
      if (!last) {
        Divider()
          .width('calc(100% - 24vp)')
          .strokeWidth(0.5)
          .color($r('app.color.divider'))
      }
    }
    .width('100%')
    .backgroundColor(Color.Transparent)
    .onClick(() => this.runContextAction(action))
  }

  @Builder
  DestinationPickerOverlay(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      // Restore the original sheet backdrop. The status-bar area remains
      // dimmed/blurred while the file-management surface starts below the
      // top safe area with rounded top corners.
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.isDarkTheme ? '#42000000' : '#26000000')
        .backgroundBlurStyle(BlurStyle.Thick, {
          colorMode: ThemeColorMode.SYSTEM,
          adaptiveColor: AdaptiveColor.DEFAULT
        })
        .hitTestBehavior(HitTestMode.None)

      Button() {
        Row()
          .width(1)
          .height(1)
      }
      .type(ButtonType.Normal)
      .width('100%')
      .height('100%')
      .padding(0)
      .borderRadius(0)
      .backgroundColor(Color.Transparent)
      .stateEffect(false)
      .hitTestBehavior(HitTestMode.Block)
      .onClick(() => this.closeDestinationPicker())

      Column() {
        Blank()
          .height(this.topSafeInset())
          .hitTestBehavior(HitTestMode.None)

        if (!this.destinationPickerClosing) {
          Stack({ alignContent: Alignment.TopStart }) {
          // Keep the material on a sibling background layer. Applying it to
          // the content Column blurs the destination rows together with the sheet.
          Column()
            .width('100%')
            .height('100%')
            // The destination list is the hard file-management surface. Only
            // the controls and the bottom operation capsule use glass.
            .backgroundColor($r('app.color.surface_card'))
            .hitTestBehavior(HitTestMode.None)

          Column() {
            Row() {
              this.DestinationCloseButton(() => this.closeDestinationPicker())
              Text('选择路径')
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
                .margin({ left: 8 })
              Row({ space: 8 }) {
                this.DestinationCircleButton($r('sys.symbol.folder_badge_plus'),
                  () => this.openDestinationFolderDialog())
                this.DestinationCircleButton($r('sys.symbol.checkmark'),
                  () => this.confirmDestinationOperation(), true)
              }
            }
            .width('100%')
            .height(60)
            .padding({ left: 16, right: 16 })

            Stack({ alignContent: Alignment.TopStart }) {
              if (this.destinationLoading) {
                Row() {
                  LoadingProgress()
                    .width(24)
                    .height(24)
                    .color('#2E6BFF')
                  Text('正在读取目录…')
                    .fontSize(14)
                    .fontColor($r('app.color.text_secondary'))
                    .margin({ left: 8 })
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
              } else {
                Scroll() {
                  Column() {
                    this.DestinationCloudRootRow()
                    if (this.destinationRootExpanded) {
                      Column() {
                        ForEach(this.destinationTreeRows, (row: DestinationTreeRow) => {
                          this.DestinationTreeRowView(row)
                        }, (row: DestinationTreeRow): string => row.entry.path)
                        if (this.destinationTreeRows.length === 0) {
                          Text('当前目录没有可选文件夹')
                            .fontSize(14)
                            .fontColor($r('app.color.text_muted'))
                            .width('100%')
                            .textAlign(TextAlign.Center)
                            .padding({ top: 30, bottom: 30 })
                        }
                      }
                      .width('100%')
                      .id('destinationFolderList_' + this.destinationUserRootPath())
                      .transition(this.destinationFolderListTransition())
                    }
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                  .justifyContent(FlexAlign.Start)
                  // A short Scroll child is otherwise centered by ArkUI.
                  // Keep the file rows at the top while allowing large
                  // directories to grow beyond the viewport and scroll.
                  .constraintSize({ minHeight: '100%' })
                }
                .width('100%')
                .height('100%')
                .padding({ bottom: this.bottomSafeInset() + 124 })
                .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
                .scrollBar(BarState.Auto)
              }

              Column() {
                Row() {
                  this.DestinationToastVisual()
                  Text((this.destinationOperation === 'copy' ? '复制 ' : '移动 ') +
                    this.destinationSelectedEntries.length.toString() + ' 项到 ' +
                    this.destinationDisplayName())
                    .fontSize(18)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ left: 16 })
                }
                .width('calc(100% - 32vp)')
                .height(64)
                .padding({ left: 20, right: 20 })
                .borderRadius(32)
                .systemMaterial(this.bottomCapsuleMaterial)
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.End)
              .alignItems(HorizontalAlign.Center)
              .padding({ bottom: this.bottomSafeInset() + 32 })
              .hitTestBehavior(HitTestMode.None)
            }
            .width('100%')
            .layoutWeight(1)
          }
          .width('100%')
          .height('100%')
          .padding({ top: 8 })
          .hitTestBehavior(HitTestMode.Default)
        }
        .width('100%')
        // The panel occupies the remaining area after the top safe inset.
        // Using height('100%') here together with the Blank above makes the
        // children exceed the parent and causes ArkUI to recenter the content.
        .layoutWeight(1)
        .backgroundColor($r('app.color.surface_card'))
        .borderRadius({ topLeft: 30, topRight: 30 })
        .id('destinationPickerSurface')
        .transition(this.destinationPickerSurfaceTransition())
          .clip(true)
        }
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Default)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Default)
  }

  @Builder
  DestinationCloseButton(action: () => void): void {
    Button() {
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(21)
        .fontColor([$r('app.color.icon_primary')])
    }
    .type(ButtonType.Normal)
    .width(40)
    .height(40)
    .borderRadius(20)
    .backgroundColor(Color.Transparent)
    .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN))
    .hitTestBehavior(HitTestMode.Default)
    .monopolizeEvents(true)
    .stateEffect(true)
    .onClick(action)
  }

  @Builder
  DestinationCircleButton(icon: Resource, action: () => void, enabled: boolean = true): void {
    Button() {
      SymbolGlyph(icon)
        .fontSize(21)
        .fontColor([$r('app.color.icon_primary')])
    }
    .type(ButtonType.Normal)
    .width(40)
    .height(40)
    .borderRadius(20)
    .backgroundColor(Color.Transparent)
    .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN))
    .hitTestBehavior(HitTestMode.Default)
    .monopolizeEvents(true)
    .stateEffect(true)
    .enabled(enabled)
    .onClick(action)
  }

  @Builder
  DestinationStorageVisual(): void {
    Image($r('app.media.ugreen_cloud'))
      .width(38)
      .height(38)
      .objectFit(ImageFit.Contain)
  }

  @Builder
  DestinationCloudRootRow(): void {
    Column() {
      Row() {
        Blank()
          .width('7.4%')
        this.DestinationStorageVisual()
        Text('我的绿联')
          .fontSize(20)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .margin({ left: 16 })
        SymbolGlyph(this.destinationRootExpanded
          ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_forward'))
          .fontSize(18)
          .fontColor([$r('app.color.icon_muted')])
        Blank()
          .width('7.2%')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 12, bottom: 12 })
      .onClick(() => this.toggleDestinationRoot())
      Row() {
        Blank()
          .width('17.6%')
        Divider()
          .layoutWeight(1)
          .strokeWidth(0.5)
          .color($r('app.color.divider'))
        Blank()
          .width('7.2%')
      }
      .width('100%')
      .height(1)
      .hitTestBehavior(HitTestMode.None)
    }
      .width('100%')
  }

  @Builder
  DestinationTreeRowView(row: DestinationTreeRow): void {
    Column() {
      Row() {
        Blank()
          .width(40 + row.depth * 28)
        this.DestinationFolderVisual(row.entry)
        Column() {
          Text(row.entry.name)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.destinationEntryInfo(row.entry).length > 0) {
            Text(this.destinationEntryInfo(row.entry))
              .fontSize(12)
              .fontColor($r('app.color.text_muted'))
              .margin({ top: 4 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 16 })
        SymbolGlyph(row.expanded
          ? $r('sys.symbol.chevron_down')
          : $r('sys.symbol.chevron_forward'))
          .fontSize(18)
          .fontColor([$r('app.color.icon_muted')])
        Blank()
          .width('7.2%')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 12, bottom: 12 })
      .onClick(() => this.toggleDestinationFolder(row.entry))

      if (row.loading) {
        Row() {
          LoadingProgress()
            .width(18)
            .height(18)
            .color('#2E6BFF')
          Text('正在读取目录…')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .margin({ left: 8 })
        }
        .width('100%')
        .padding({
          left: 40 + row.depth * 28 + 48,
          top: 0,
          bottom: 8
        })
      }

      Row() {
        Blank()
          .width(76 + row.depth * 28)
        Divider()
          .layoutWeight(1)
          .strokeWidth(0.5)
          .color($r('app.color.divider'))
        Blank()
          .width('7.2%')
      }
      .width('100%')
      .height(1)
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .id('destinationTreeRow_' + row.entry.path)
    .transition(this.destinationFolderListTransition())
  }

  @Builder
  DestinationFolderVisual(entry: DestinationEntry): void {
    Stack() {
      this.FolderIcon(32)
    }
    .width('6.2%')
    .height(34)
    .alignContent(Alignment.Center)
  }

  @Builder
  DestinationToastVisual(): void {
    Stack() {
      if (this.destinationSelectedEntries.length > 0 &&
        this.destinationSelectedEntries[0].isDirectory) {
        this.FolderIcon(52)
      } else if (this.destinationSelectedEntries.length > 0 &&
        this.previewUri(this.destinationSelectedEntries[0]).length > 0) {
        Image(this.previewUri(this.destinationSelectedEntries[0]))
          .width(52)
          .height(44)
          .orientation(ImageRotateOrientation.AUTO)
          .objectFit(ImageFit.Contain)
          .borderRadius(6)
      } else if (this.destinationSelectedEntries.length > 0) {
        Image(this.fileIcon(this.destinationSelectedEntries[0]))
          .width(44)
          .height(44)
          .objectFit(ImageFit.Contain)
      }
    }
    .width(52)
    .height(44)
  }

  @Builder
  DestinationFolderOverlay(): void {
    Column() {}
      .width(0)
      .height(0)
      .bindSheet($$this.destinationFolderDialog, this.DestinationFolderOverlayContent, {
        preferType: SheetType.CENTER,
        height: SheetSize.FIT_CONTENT,
        width: '84%',
        dragBar: false,
        showClose: false,
        systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.THICK, false),
        onWillDismiss: () => {
          if (!this.destinationLoading) {
            this.closeDestinationFolderDialog()
          }
        }
      })
  }

  @Builder
  DestinationFolderOverlayContent(): void {
    Column({ space: 14 }) {
      Text('新建文件夹')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Column({ space: 2 }) {
        TextInput({ placeholder: '输入文件夹名称', text: this.destinationFolderText })
          .height(40)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor(Color.Transparent)
          .border({ width: 0, color: Color.Transparent, radius: 0 })
          .padding({ left: 14, right: 14 })
          .onChange((value: string) => this.destinationFolderText = value)
        Divider()
          .width('100%')
          .strokeWidth(0.5)
          .color($r('app.color.divider'))
          .margin({ left: 14, right: 14 })
      }
      Row({ space: 8 }) {
        Button('取消')
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .stateEffect(false)
          .onClick(() => this.closeDestinationFolderDialog())
        Button(this.destinationLoading ? '处理中…' : '确定')
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .fontColor('#2E6BFF')
          .backgroundColor(Color.Transparent)
          .stateEffect(false)
          .enabled(!this.destinationLoading)
          .onClick(() => this.confirmDestinationFolder())
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 18, bottom: 12 })
    .borderRadius(24)
    .backgroundColor(Color.Transparent)
    .onClick(() => {})
  }

  @Builder
  RenameOverlay(): void {
    Column() {}
      .width(0)
      .height(0)
      .bindSheet($$this.showRenameDialog, this.RenameOverlayContent, {
        preferType: SheetType.CENTER,
        height: SheetSize.FIT_CONTENT,
        width: '88%',
        dragBar: false,
        showClose: false,
        systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.THICK, false),
        onWillDismiss: () => {
          if (!this.isBusy) {
            this.closeRename()
          }
        }
      })
  }

  @Builder
  RenameOverlayContent(): void {
    Column({ space: 16 }) {
      Text('重命名')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      TextInput({ placeholder: '输入新名称', text: this.renameText })
        .height(50)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor(Color.Transparent)
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .onChange((value: string) => this.renameText = value)
      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(46)
          .fontSize(15)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .onClick(() => this.closeRename())
        Button(this.isBusy ? '处理中…' : '确定')
          .layoutWeight(1)
          .height(46)
          .fontSize(15)
          .fontColor('#2E6BFF')
          .backgroundColor(Color.Transparent)
          .enabled(!this.isBusy)
          .onClick(() => this.confirmRename())
      }
      .width('100%')
    }
    .width('100%')
    .borderRadius(20)
    .padding(20)
    .onClick(() => {})
  }

  @Builder
  CreateFolderOverlay(): void {
    Column() {}
      .width(0)
      .height(0)
      .bindSheet($$this.showCreateFolderDialog, this.CreateFolderOverlayContent, {
        preferType: SheetType.CENTER,
        height: SheetSize.FIT_CONTENT,
        width: '84%',
        dragBar: false,
        showClose: false,
        systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.THICK, false),
        onWillDismiss: () => {
          if (!this.isBusy) {
            this.closeCreateFolder()
          }
        }
      })
  }

  @Builder
  CreateFolderOverlayContent(): void {
    Column({ space: 14 }) {
      Text('新建文件夹')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Column({ space: 2 }) {
        TextInput({ placeholder: '输入文件夹名称', text: this.newFolderText })
          .height(40)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          // Keep the input as the transparent text area above the divider.
          // An explicit background/border becomes an unintended rectangular
          // frame in dark mode and does not match the reference dialog.
          .backgroundColor(Color.Transparent)
          .border({ width: 0, color: Color.Transparent, radius: 0 })
          .padding({ left: 14, right: 14 })
          .onChange((value: string) => this.newFolderText = value)
        Divider()
          .width('100%')
          .strokeWidth(0.5)
          .color($r('app.color.divider'))
          .margin({ left: 14, right: 14 })
      }
      Row({ space: 8 }) {
        Button('取消')
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .stateEffect(false)
          .onClick(() => this.closeCreateFolder())
        Button(this.isBusy ? '处理中…' : '确定')
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .fontColor('#2E6BFF')
          .backgroundColor(Color.Transparent)
          .stateEffect(false)
          .enabled(!this.isBusy)
          .onClick(() => this.confirmCreateFolder())
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 18, bottom: 12 })
    .borderRadius(24)
    .backgroundColor(Color.Transparent)
    .onClick(() => {})
  }

  private copyImageVisualState(source?: ImageVisualState): ImageVisualState {
    const next = new ImageVisualState()
    if (source === undefined) {
      return next
    }
    next.thumbnailUri = source.thumbnailUri
    next.thumbnailSignature = source.thumbnailSignature
    next.transitionThumbnailUri = source.transitionThumbnailUri
    next.originalUri = source.originalUri
    next.thumbnailOrientation = source.thumbnailOrientation
    next.originalOrientation = source.originalOrientation
    next.userRotation = source.userRotation
    next.rotationResolved = source.rotationResolved
    next.physicalWidth = source.physicalWidth
    next.physicalHeight = source.physicalHeight
    next.exifDisplayWidth = source.exifDisplayWidth
    next.exifDisplayHeight = source.exifDisplayHeight
    next.displayWidth = source.displayWidth
    next.displayHeight = source.displayHeight
    next.thumbnailDisplayWidth = source.thumbnailDisplayWidth
    next.thumbnailDisplayHeight = source.thumbnailDisplayHeight
    next.frameWidth = source.frameWidth
    next.frameHeight = source.frameHeight
    next.frameLocked = source.frameLocked
    next.decodeState = source.decodeState
    next.visibleLayer = source.visibleLayer
    next.progress = source.progress
    next.progressKnown = source.progressKnown
    next.thumbnailIndex = source.thumbnailIndex
    next.thumbnailSurface = source.thumbnailSurface
    next.thumbnailVisibleRatio = source.thumbnailVisibleRatio
    next.thumbnailX = source.thumbnailX
    next.thumbnailY = source.thumbnailY
    next.thumbnailWidth = source.thumbnailWidth
    next.thumbnailHeight = source.thumbnailHeight
    next.thumbnailDecodedUri = source.thumbnailDecodedUri
    return next
  }

  private imageVisualState(path: string): ImageVisualState {
    const state = this.imageVisualStates[path]
    return state === undefined ? new ImageVisualState() : state
  }

  private updateImageVisualState(path: string, update: (state: ImageVisualState) => void): void {
    if (path.length === 0) {
      return
    }
    const nextStates: Record<string, ImageVisualState> = {}
    for (const key of Object.keys(this.imageVisualStates)) {
      nextStates[key] = this.imageVisualStates[key]
    }
    const next = this.copyImageVisualState(this.imageVisualStates[path])
    update(next)
    nextStates[path] = next
    this.imageVisualStates = nextStates
  }

  private nextRenderFrame(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      this.getUIContext().postFrameCallback(new ViewerFrameCallback(resolve))
    })
  }

  private postRenderFrame(action: () => void): void {
    this.getUIContext().postFrameCallback(new ViewerFrameCallback(action))
  }

  private viewerOriginalUri(entry: FileEntry): string {
    return this.imageVisualState(entry.path).originalUri
  }

  /**
   * PixelMaps are kept outside @State because they are native resources.  A
   * monotonically increasing epoch is read here so a source swap still
   * invalidates the ArkUI builder after the private map is changed.
   */
  private viewerBitmap(entry: FileEntry, originalOnly: boolean = false): ViewerBitmapRecord | null {
    const epoch = this.viewerBitmapEpoch
    if (epoch < 0) {
      return null
    }
    const original = this.viewerOriginalBitmaps[entry.path]
    if (original !== undefined && (originalOnly ||
      this.imageVisualState(entry.path).visibleLayer === 'original')) {
      return original
    }
    if (originalOnly) {
      return null
    }
    const preview = this.viewerPreviewBitmaps[entry.path]
    return preview === undefined ? null : preview
  }

  private viewerImageSource(entry: FileEntry): image.PixelMap | string {
    const bitmap = this.viewerBitmap(entry)
    if (bitmap !== null) {
      return bitmap.pixelMap
    }
    const state = this.imageVisualState(entry.path)
    if (state.visibleLayer === 'original' && state.originalUri.length > 0) {
      return state.originalUri
    }
    return this.viewerThumbnailUri(entry)
  }

  private fileImageSource(entry: FileEntry, surface: ThumbnailSurfaceKind): image.PixelMap | string {
    // The maps contain native resources and intentionally are not @State.
    // Reading the epoch makes every file-surface Image react to an atomic map
    // replacement without copying PixelMaps through observable state.
    const epoch = this.viewerBitmapEpoch
    if (epoch < 0) {
      return ''
    }
    if (this.viewerEntryTransitionActive && this.viewerEntryTransitionPath === entry.path) {
      const transitionBitmap = this.viewerTransitionKind === 'exit' &&
        this.viewerTransitionLayer === 'original'
        ? this.viewerOriginalBitmaps[entry.path] : this.viewerPreviewBitmaps[entry.path]
      if (transitionBitmap !== undefined) {
        return transitionBitmap.pixelMap
      }
    }
    if (surface === 'waterfall') {
      const waterfallBitmap = this.waterfallBitmaps[entry.path]
      if (waterfallBitmap !== undefined) {
        return waterfallBitmap.pixelMap
      }
      // 瀑布流只显示原图：图片要等原图解码完成，避免退回 256px 服务端缩略图
      // 让人误以为瀑布流是压缩图；非图片条目（视频等）直接用本地原文件 URI。
      return this.isImage(entry) ? '' : this.waterfallUri(entry)
    }
    if (this.isImage(entry)) {
      const thumbnailBitmap = this.fileThumbnailBitmaps[entry.path]
      if (thumbnailBitmap !== undefined) {
        return thumbnailBitmap.pixelMap
      }
      // Image URIs are transport/cache inputs only. Persisted rotation must be
      // baked by Image Kit before ArkUI is allowed to render the thumbnail.
      return ''
    }
    return this.previewUri(entry)
  }

  private fileImageSourceAvailable(entry: FileEntry, surface: ThumbnailSurfaceKind): boolean {
    if (this.isImage(entry) && !this.imageVisualState(entry.path).rotationResolved) {
      return false
    }
    const source = this.fileImageSource(entry, surface)
    return typeof source === 'string' ? source.length > 0 : true
  }

  private fileImageSourceOrientation(entry: FileEntry,
    surface: ThumbnailSurfaceKind): ImageRotateOrientation {
    return typeof this.fileImageSource(entry, surface) === 'string'
      ? this.fileListImageBaseOrientation(entry) : ImageRotateOrientation.UP
  }

  private viewerImageSourceOrientation(entry: FileEntry): ImageRotateOrientation {
    if (this.viewerBitmap(entry) !== null) {
      return ImageRotateOrientation.UP
    }
    const state = this.imageVisualState(entry.path)
    return state.visibleLayer === 'original'
      ? state.originalOrientation : this.viewerPreviewImageOrientation(entry)
  }

  private async ensureViewerPreviewBitmap(entry: FileEntry): Promise<ViewerBitmapRecord | null> {
    const existing = this.viewerPreviewBitmaps[entry.path]
    const rotation = this.imageVisualState(entry.path).userRotation
    if (existing !== undefined && existing.userRotation === rotation) {
      return existing
    }
    if (existing !== undefined) {
      const alias = this.viewerPreviewBitmapAliases[entry.path] === true
      this.removeViewerBitmap(this.viewerPreviewBitmaps, entry.path)
      this.viewerPreviewBitmapAliases[entry.path] = false
      if (!alias) {
        await this.viewerBitmapStore.release(existing)
      }
    }
    const waterfallBitmap = this.waterfallBitmaps[entry.path]
    if (waterfallBitmap !== undefined && waterfallBitmap.userRotation === rotation) {
      const next: Record<string, ViewerBitmapRecord> = {}
      for (const key of Object.keys(this.viewerPreviewBitmaps)) {
        next[key] = this.viewerPreviewBitmaps[key]
      }
      next[entry.path] = waterfallBitmap
      this.viewerPreviewBitmaps = next
      this.viewerPreviewBitmapAliases[entry.path] = true
      this.bumpViewerBitmapEpoch()
      this.applyDecodedBitmapGeometry(entry.path, waterfallBitmap, false)
      return waterfallBitmap
    }
    let localPath = this.previewLocalPaths[entry.path]
    if (typeof localPath !== 'string' || localPath.length === 0 || !CacheManager.exists(localPath)) {
      localPath = this.waterfallLocalPaths[entry.path]
    }
    if (typeof localPath !== 'string' || localPath.length === 0 || !CacheManager.exists(localPath)) {
      return null
    }
    const record = await this.viewerBitmapStore.decode(localPath, 'viewerPreview', rotation)
    if (record === null) {
      return null
    }
    if (this.imageVisualState(entry.path).userRotation !== rotation) {
      await this.viewerBitmapStore.release(record)
      return null
    }
    const raced = this.viewerPreviewBitmaps[entry.path]
    if (raced !== undefined) {
      await this.viewerBitmapStore.release(record)
      return raced
    }
    this.installViewerBitmap(this.viewerPreviewBitmaps, entry.path, record)
    this.viewerPreviewBitmapAliases[entry.path] = false
    this.updateImageVisualState(entry.path, (state: ImageVisualState): void => {
      if (state.physicalWidth <= 0 || state.physicalHeight <= 0) {
        state.physicalWidth = record.physicalWidth
        state.physicalHeight = record.physicalHeight
      }
      state.exifDisplayWidth = record.exifDisplayWidth
      state.exifDisplayHeight = record.exifDisplayHeight
      if (state.displayWidth <= 0 || state.displayHeight <= 0) {
        state.displayWidth = record.displayWidth
        state.displayHeight = record.displayHeight
      }
      if (state.thumbnailDisplayWidth <= 0 || state.thumbnailDisplayHeight <= 0) {
        state.thumbnailDisplayWidth = record.displayWidth
        state.thumbnailDisplayHeight = record.displayHeight
      }
      if (!state.frameLocked) {
        state.frameWidth = record.displayWidth
        state.frameHeight = record.displayHeight
      }
    })
    return record
  }

  private async decodeViewerOriginalBitmap(entry: FileEntry,
    localPath: string): Promise<ViewerBitmapRecord | null> {
    const existing = this.viewerOriginalBitmaps[entry.path]
    const rotation = this.imageVisualState(entry.path).userRotation
    if (existing !== undefined && existing.userRotation === rotation) {
      return existing
    }
    if (existing !== undefined) {
      this.removeViewerBitmap(this.viewerOriginalBitmaps, entry.path)
      await this.viewerBitmapStore.release(existing)
    }
    const record = await this.viewerBitmapStore.decode(localPath, 'viewerZoom', rotation)
    if (record === null) {
      return null
    }
    if (this.imageVisualState(entry.path).userRotation !== rotation) {
      await this.viewerBitmapStore.release(record)
      return null
    }
    const raced = this.viewerOriginalBitmaps[entry.path]
    if (raced !== undefined) {
      await this.viewerBitmapStore.release(record)
      return raced
    }
    this.installViewerBitmap(this.viewerOriginalBitmaps, entry.path, record)
    return record
  }

  private applyDecodedBitmapGeometry(path: string, record: ViewerBitmapRecord,
    original: boolean): void {
    this.updateImageVisualState(path, (state: ImageVisualState): void => {
      if (original) {
        state.originalOrientation = ImageRotateOrientation.UP
      }
      state.physicalWidth = record.physicalWidth
      state.physicalHeight = record.physicalHeight
      state.exifDisplayWidth = record.exifDisplayWidth
      state.exifDisplayHeight = record.exifDisplayHeight
      state.displayWidth = record.displayWidth
      state.displayHeight = record.displayHeight
      if (!state.frameLocked) {
        state.frameWidth = record.displayWidth
        state.frameHeight = record.displayHeight
        state.frameLocked = true
      }
    })
  }

  private bumpViewerBitmapEpoch(): void {
    this.viewerBitmapEpoch += 1
  }

  private installViewerBitmap(target: Record<string, ViewerBitmapRecord>,
    path: string, record: ViewerBitmapRecord): void {
    const next: Record<string, ViewerBitmapRecord> = {}
    for (const key of Object.keys(target)) {
      next[key] = target[key]
    }
    next[path] = record
    if (target === this.viewerPreviewBitmaps) {
      this.viewerPreviewBitmaps = next
      this.viewerPreviewBitmapAliases[path] = false
    } else if (target === this.viewerOriginalBitmaps) {
      this.viewerOriginalBitmaps = next
    } else {
      this.waterfallBitmaps = next
    }
    this.bumpViewerBitmapEpoch()
  }

  private async installFileThumbnailBitmap(entry: FileEntry,
    localPath: string): Promise<ViewerBitmapRecord | null> {
    if (!this.isImage(entry) || !this.imageVisualState(entry.path).rotationResolved ||
      localPath.length === 0 || !CacheManager.exists(localPath)) {
      return null
    }
    const rotation = this.imageVisualState(entry.path).userRotation
    const requestKey = localPath + '|' + this.previewSignature(entry) +
      '|rotation=' + rotation.toString()
    const existing = this.fileThumbnailBitmaps[entry.path]
    if (existing !== undefined && existing.path === localPath && existing.userRotation === rotation &&
      this.fileThumbnailDecodeKeys[entry.path] === requestKey) {
      return existing
    }
    this.fileThumbnailDecodeKeys[entry.path] = requestKey
    const record = await this.viewerBitmapStore.decode(localPath, 'list', rotation)
    if (record === null) {
      return null
    }
    if (this.fileThumbnailDecodeKeys[entry.path] !== requestKey ||
      this.imageVisualState(entry.path).userRotation !== rotation) {
      await this.viewerBitmapStore.release(record)
      return null
    }
    const previous = this.fileThumbnailBitmaps[entry.path]
    const next: Record<string, ViewerBitmapRecord> = {}
    for (const key of Object.keys(this.fileThumbnailBitmaps)) {
      if (key !== entry.path) {
        next[key] = this.fileThumbnailBitmaps[key]
      }
    }
    next[entry.path] = record
    this.fileThumbnailBitmaps = next
    this.bumpViewerBitmapEpoch()
    this.updateImageVisualState(entry.path, (state: ImageVisualState): void => {
      state.physicalWidth = record.physicalWidth
      state.physicalHeight = record.physicalHeight
      state.exifDisplayWidth = record.exifDisplayWidth
      state.exifDisplayHeight = record.exifDisplayHeight
      state.displayWidth = record.displayWidth
      state.displayHeight = record.displayHeight
      state.thumbnailDisplayWidth = record.displayWidth
      state.thumbnailDisplayHeight = record.displayHeight
      if (!state.frameLocked) {
        state.frameWidth = record.displayWidth
        state.frameHeight = record.displayHeight
      }
    })
    if (previous !== undefined && previous !== record) {
      this.postRenderFrame((): void => {
        this.viewerBitmapStore.release(previous).catch((): void => {})
      })
    }
    return record
  }

  private async publishImagePreview(entry: FileEntry, localPath: string,
    canonical: boolean, generation: number): Promise<void> {
    if (generation !== this.previewGeneration || localPath.length === 0) {
      return
    }
    await this.primeViewerPreviewGeometryAtPath(entry, localPath, canonical)
    const record = await this.installFileThumbnailBitmap(entry, localPath)
    if (record === null || generation !== this.previewGeneration) {
      return
    }
    this.setPreviewUri(entry, fileUri.getUriFromPath(localPath), localPath, canonical)
  }

  /**
   * Images need the Image Kit decode/rotation pipeline before their URI can
   * be exposed. Video and audio thumbnails are already raster previews from
   * the server, so publishing the URI directly avoids sending them through
   * the image-only rotation store while still allowing the file row and the
   * video poster to render the same cached asset.
   */
  private async publishThumbnailPreview(entry: FileEntry, localPath: string,
    canonical: boolean, generation: number): Promise<void> {
    if (this.isImage(entry)) {
      await this.publishImagePreview(entry, localPath, canonical, generation)
      return
    }
    if (generation !== this.previewGeneration || localPath.length === 0) {
      return
    }
    this.setPreviewUri(entry, fileUri.getUriFromPath(localPath), localPath, canonical)
  }

  private releaseFileThumbnailBitmap(path: string): void {
    const record = this.fileThumbnailBitmaps[path]
    if (record === undefined) {
      return
    }
    const next: Record<string, ViewerBitmapRecord> = {}
    for (const key of Object.keys(this.fileThumbnailBitmaps)) {
      if (key !== path) {
        next[key] = this.fileThumbnailBitmaps[key]
      }
    }
    this.fileThumbnailBitmaps = next
    this.fileThumbnailDecodeKeys[path] = ''
    this.bumpViewerBitmapEpoch()
    this.postRenderFrame((): void => {
      this.viewerBitmapStore.release(record).catch((): void => {})
    })
  }

  private removeViewerBitmap(target: Record<string, ViewerBitmapRecord>, path: string): ViewerBitmapRecord | null {
    const existing = target[path]
    if (existing === undefined) {
      return null
    }
    const next: Record<string, ViewerBitmapRecord> = {}
    for (const key of Object.keys(target)) {
      if (key !== path) {
        next[key] = target[key]
      }
    }
    if (target === this.viewerPreviewBitmaps) {
      this.viewerPreviewBitmaps = next
    } else if (target === this.viewerOriginalBitmaps) {
      this.viewerOriginalBitmaps = next
    } else {
      this.waterfallBitmaps = next
    }
    this.bumpViewerBitmapEpoch()
    return existing
  }

  private async releaseViewerBitmap(target: Record<string, ViewerBitmapRecord>,
    path: string): Promise<void> {
    const record = this.removeViewerBitmap(target, path)
    if (record !== null) {
      await this.viewerBitmapStore.release(record)
    }
  }

  private async releaseViewerSessionBitmaps(entries: FileEntry[]): Promise<void> {
    const previews = this.viewerPreviewBitmaps
    const originals = this.viewerOriginalBitmaps
    this.viewerPreviewBitmaps = {}
    this.viewerOriginalBitmaps = {}
    this.viewerOriginalLocalPaths = {}
    const previewAliases = this.viewerPreviewBitmapAliases
    this.viewerPreviewBitmapAliases = {}
    this.bumpViewerBitmapEpoch()
    for (const entry of entries) {
      const preview = previews[entry.path]
      if (preview !== undefined && previewAliases[entry.path] !== true) {
        await this.viewerBitmapStore.release(preview)
      }
      const original = originals[entry.path]
      if (original !== undefined) {
        await this.viewerBitmapStore.release(original)
              }
            }
          }

  private viewerThumbnailUri(entry: FileEntry): string {
    const state = this.imageVisualState(entry.path)
    if (state.transitionThumbnailUri.length > 0) {
      return state.transitionThumbnailUri
    }
    return this.previewUri(entry)
  }

  private logViewerDiagnostic(stage: string, path: string = ''): void {
    if (!IMAGE_VIEWER_DIAGNOSTICS) {
      return
    }
    const resolvedPath = path.length > 0 ? path :
      (this.viewerImageEntry === null ? '' : this.viewerImageEntry.path)
    const state = this.imageVisualState(resolvedPath)
    const entry = this.viewerImages.find((item: FileEntry): boolean => item.path === resolvedPath)
    const currentThumbnailUri = entry === undefined ? '' :
      this.thumbnailSurfaceUri(entry, state.thumbnailSurface)
    this.viewerDiagnosticSequence += 1
    const message = 'seq=' + this.viewerDiagnosticSequence.toString() +
      ' stage=' + stage +
      ' path=' + resolvedPath +
      ' index=' + this.viewerImageIndex.toString() +
      ' committed=' + (this.committedViewerEntry() === null
        ? '' : (this.committedViewerEntry() as FileEntry).path) +
      ' pending=' + this.viewerPendingIndex.toString() +
      ' surface=' + state.thumbnailSurface +
      ' thumb=' + state.thumbnailDisplayWidth.toString() + 'x' +
      state.thumbnailDisplayHeight.toString() +
      ' frame=' + state.frameWidth.toString() + 'x' + state.frameHeight.toString() +
      ' physical=' + state.physicalWidth.toString() + 'x' + state.physicalHeight.toString() +
      ' exifDisplay=' + state.exifDisplayWidth.toString() + 'x' + state.exifDisplayHeight.toString() +
      ' display=' + state.displayWidth.toString() + 'x' + state.displayHeight.toString() +
      ' rotation=' + state.userRotation.toString() +
      ' decode=' + state.decodeState +
      ' layer=' + state.visibleLayer +
      ' bitmap=' + (this.viewerOriginalBitmaps[resolvedPath] !== undefined
        ? 'original' : (this.viewerPreviewBitmaps[resolvedPath] !== undefined ? 'preview' : 'uri')) +
      ' epoch=' + this.viewerBitmapEpoch.toString() +
      ' transition=' + this.viewerTransitionKind +
      ' geometry=' + this.viewerGeometryBound.toString() +
      ' uriReady=' + (currentThumbnailUri.length > 0 &&
        state.thumbnailDecodedUri === currentThumbnailUri).toString()
    hilog.info(IMAGE_VIEWER_HILOG_DOMAIN, IMAGE_VIEWER_HILOG_TAG, '%{public}s', message)
  }

  /**
   * ArkUI exposes both the decoded source dimensions and the component source
   * dimensions in Image.onComplete. Keep this diagnostic at the render edge:
   * it distinguishes a changed source aspect ratio from a changed viewer
   * frame without changing the image or its layout.
   */
  private logViewerRenderGeometry(path: string, layer: string,
    event?: ViewerImageCompleteEvent): void {
    if (event === undefined) {
      return
    }
    console.info('[UgreenViewerGeometry] layer=' + layer + ' path=' + path +
      ' source=' + event.width.toString() + 'x' + event.height.toString() +
      ' component=' + event.componentWidth.toString() + 'x' +
      event.componentHeight.toString() + ' content=' + event.contentWidth.toString() +
      'x' + event.contentHeight.toString() + ' offset=' + event.contentOffsetX.toString() +
      ',' + event.contentOffsetY.toString() + ' status=' + event.loadingStatus.toString())
    if (IMAGE_VIEWER_DIAGNOSTICS) {
      hilog.info(IMAGE_VIEWER_HILOG_DOMAIN, IMAGE_VIEWER_HILOG_TAG, '%{public}s',
        'render layer=' + layer + ' path=' + path +
          ' source=' + event.width.toString() + 'x' + event.height.toString() +
          ' component=' + event.componentWidth.toString() + 'x' + event.componentHeight.toString() +
          ' content=' + event.contentWidth.toString() + 'x' + event.contentHeight.toString() +
          ' offset=' + event.contentOffsetX.toString() + ',' + event.contentOffsetY.toString())
    }
  }

  private viewerImageDecoded(entry: FileEntry): boolean {
    const state = this.imageVisualState(entry.path)
    return state.decodeState === 'decoded' || state.decodeState === 'displayed'
  }

  private viewerPageScale(index: number): number {
    return index === this.viewerImageIndex ? this.imageScale : 1
  }

  private viewerPageDismissScale(index: number): number {
    return index === this.viewerImageIndex ? this.imageDismissScale : 1
  }

  private viewerPageVisualScale(entry: FileEntry, index: number): number {
    return this.viewerPageScale(index) * this.viewerPageDismissScale(index)
  }

  /**
   * The preview and original must be measured inside one stable frame.  The
   * Image component's Contain fit preserves the source ratio, but it does not
   * preserve the visible content rectangle when the source is replaced.
   * Prefer original metadata before entry; otherwise correct the provisional
   * frame atomically when the original pixels are revealed.
   */
  private viewerImageFrameAspectRatio(entry: FileEntry): number {
    const state = this.imageVisualState(entry.path)
    if (state.frameWidth > 0 && state.frameHeight > 0) {
      return Math.max(0.05, Math.min(20, state.frameWidth / state.frameHeight))
    }
    const viewportWidth = Math.max(1, this.imageViewportWidthVp)
    const viewportHeight = Math.max(1, this.imageViewportHeightVp)
    return viewportWidth / viewportHeight
  }

  private viewerImageFrameUsesWidth(entry: FileEntry): boolean {
    const frameRatio = this.viewerImageFrameAspectRatio(entry)
    const viewportRatio = Math.max(0.05,
      Math.min(20, Math.max(1, this.imageViewportWidthVp) / Math.max(1, this.imageViewportHeightVp)))
    return frameRatio >= viewportRatio
  }

  /**
   * A viewer frame is stable throughout entry and exit animations. If the NAS
   * thumbnail cannot expose metadata, reserve a provisional viewport frame;
   * original geometry is committed only with the original pixels afterwards.
   */
  private viewerImageFrameCandidate(entry: FileEntry): ThumbnailSize | null {
    const state = this.imageVisualState(entry.path)
    if (state.thumbnailDisplayWidth > 0 && state.thumbnailDisplayHeight > 0) {
      return { width: state.thumbnailDisplayWidth, height: state.thumbnailDisplayHeight }
    }
    if (state.displayWidth > 0 && state.displayHeight > 0) {
      return { width: state.displayWidth, height: state.displayHeight }
    }
    const waterfallRatio = this.waterfallAspectRatios[entry.path]
    if (typeof waterfallRatio === 'number' && waterfallRatio > 0) {
      return { width: waterfallRatio, height: 1 }
    }
    return null
  }

  private ensureViewerImageFrame(entry: FileEntry,
    allowViewportFallback: boolean = true): void {
    const state = this.imageVisualState(entry.path)
    if (state.frameLocked) {
      return
    }
    const candidate = this.viewerImageFrameCandidate(entry)
    if (candidate === null && !allowViewportFallback) {
      return
    }
    const width = candidate === null
      ? Math.max(1, this.imageViewportWidthVp) : candidate.width
    const height = candidate === null
      ? Math.max(1, this.imageViewportHeightVp) : candidate.height
    this.updateImageVisualState(entry.path, (next: ImageVisualState): void => {
      next.frameWidth = width
      next.frameHeight = height
      next.frameLocked = true
    })
    console.info('[UgreenViewerGeometry] frame-locked path=' + entry.path +
      ' size=' + width.toString() + 'x' + height.toString() +
      ' source=' + (candidate === null ? 'viewport-fallback' : 'image-metadata'))
  }

  private viewerPageOffsetX(index: number): number {
    return index === this.viewerImageIndex ? this.imageOffsetX : 0
  }

  private viewerPageOffsetY(index: number): number {
    return index === this.viewerImageIndex ? this.imageOffsetY + this.imageDismissOffsetY : 0
  }

  private viewerCurrentImageReady(): boolean {
    if (this.viewerImageEntry === null) {
      return false
    }
    return this.viewerImageDecoded(this.viewerImageEntry as FileEntry)
  }

  private committedViewerPath(): string {
    const entry = this.committedViewerEntry()
    return entry === null ? '' : entry.path
  }

  private viewerProgress(): number {
    return this.imageVisualState(this.committedViewerPath()).progress
  }

  private viewerProgressIdentity(): string {
    return 'viewer_progress_' + this.committedViewerPath().replace(/[^A-Za-z0-9_]/g, '_')
  }

  private markViewerOriginalLoading(path: string, value: number = 0,
    known: boolean = false): void {
    if (!this.showImageViewer || path.length === 0 || !this.isViewerPathNearCurrent(path)) {
      return
    }
    this.updateImageVisualState(path, (next: ImageVisualState): void => {
      if (next.decodeState !== 'decoded' && next.decodeState !== 'displayed') {
        next.decodeState = 'loading'
        next.progress = Math.min(95, Math.max(0, value))
        next.progressKnown = known
      }
    })
    this.viewerProgressLastUpdateAt[path] = Date.now()
  }

  private finishViewerOriginalLoading(path: string, failed: boolean): void {
    if (!this.showImageViewer || path.length === 0 || !this.isViewerPathNearCurrent(path)) {
      return
    }
    this.updateImageVisualState(path, (next: ImageVisualState): void => {
      if (next.decodeState === 'loading') {
        next.decodeState = failed ? 'failed' : 'idle'
        next.progress = 0
        next.progressKnown = false
      }
    })
  }

  private updateViewerDownloadProgress(path: string, progress: BinaryDownloadProgress): void {
    // ensureCachedFile uses (1, 1) as the cache-hit marker. The file bytes are
    // available, but ArkUI still needs to decode and present the Image, so the
    // ring remains at 95% until the viewer reveal is committed on a frame.
    if (progress.receiveSize === 1 && progress.totalSize === 1) {
      this.setViewerDownloadProgress(path, 95, true, true)
      return
    }
    if (progress.totalSize > 0) {
      const received = Math.max(0, progress.receiveSize)
      const fraction = Math.min(1, received / progress.totalSize)
      this.setViewerDownloadProgress(path, fraction * 95, true, false)
      return
    }
    // Chunked responses may not expose a total size. Keep the ring in the
    // official indeterminate state instead of inventing a percentage.
    this.setViewerDownloadProgress(path, 0, false, false)
  }

  private setViewerDownloadProgress(path: string, value: number, known: boolean,
    force: boolean): void {
    if (!this.showImageViewer || path.length === 0 || !this.isViewerPathNearCurrent(path)) {
      return
    }
    const nextValue = Math.min(100, Math.max(0, value))
    const state = this.imageVisualState(path)
    const previousValue = state.progress
    const previousKnown = state.progressKnown
    const now = Date.now()
    const lastUpdate = this.viewerProgressLastUpdateAt[path]
    if (!force && typeof lastUpdate === 'number' && now - lastUpdate < 80) {
      return
    }
    if (previousValue === nextValue && previousKnown === known) {
      return
    }
    this.updateImageVisualState(path, (next: ImageVisualState): void => {
      if (next.decodeState !== 'decoded' && next.decodeState !== 'displayed' &&
        next.decodeState !== 'failed' &&
        this.viewerLoadRequests[path] === true) {
        next.decodeState = 'loading'
      }
      next.progress = nextValue
      next.progressKnown = known
    })
    this.viewerProgressLastUpdateAt[path] = now
  }

  private thumbnailSurfaceIsCurrent(surface: ThumbnailSurfaceKind): boolean {
    if (surface === 'search') {
      return this.screen === 'files' && this.showSearch
    }
    if (this.screen !== 'files' || this.showSearch) {
      return false
    }
    return surface === this.fileViewMode
  }

  private thumbnailSurfaceUri(entry: FileEntry, surface: ThumbnailSurfaceKind): string {
    if (surface === 'waterfall') {
      const uri = this.waterfallOriginalUris[entry.path]
      return typeof uri === 'string' ? uri : ''
    }
    return this.previewUri(entry)
  }

  private recordThumbnailMountedSource(entry: FileEntry, uri: string, index: number,
    surface: ThumbnailSurfaceKind): void {
    if (!this.isImage(entry) || !this.thumbnailSurfaceIsCurrent(surface)) {
      return
    }
    const resolvedUri = uri.length > 0 ? uri : this.thumbnailSurfaceUri(entry, surface)
    this.updateImageVisualState(entry.path, (state: ImageVisualState): void => {
      state.thumbnailIndex = index
      state.thumbnailSurface = surface
      if (resolvedUri.length > 0) {
        state.thumbnailDecodedUri = ''
        state.transitionThumbnailUri = resolvedUri
      }
    })
  }

  private recordThumbnailComplete(entry: FileEntry, uri: string, index: number,
    surface: ThumbnailSurfaceKind, event?: ViewerImageCompleteEvent): void {
    if (event === undefined || !this.isImage(entry) ||
      !this.thumbnailSurfaceIsCurrent(surface)) {
      return
    }
    // contentWidth/contentHeight are the fitted rectangle inside the current
    // component (Cover can make them equal to the card), not source metadata.
    // Keep the decoder dimensions here; frame locking is performed only from
    // Image Kit metadata before a viewer transition.
    const displayWidth = event.width
    const displayHeight = event.height
    if (displayWidth <= 0 || displayHeight <= 0) {
      return
    }
    this.updateImageVisualState(entry.path, (state: ImageVisualState): void => {
      state.thumbnailIndex = index
      state.thumbnailSurface = surface
      state.transitionThumbnailUri = uri
      state.thumbnailDecodedUri = uri
      state.thumbnailDisplayWidth = displayWidth
      state.thumbnailDisplayHeight = displayHeight
    })
    if (surface === 'waterfall' &&
      (this.waterfallAspectRatios[entry.path] === undefined ||
        this.waterfallAspectRatios[entry.path] <= 0)) {
      const ratioWidth = displayWidth > 0 ? displayWidth : event.width
      const ratioHeight = displayHeight > 0 ? displayHeight : event.height
      if (ratioWidth > 0 && ratioHeight > 0) {
        this.setWaterfallAspectRatio(entry.path, ratioWidth, ratioHeight)
      }
    }
    if (this.showImageViewer && this.viewerImageEntry !== null &&
      this.viewerImageEntry.path === entry.path) {
      this.logViewerDiagnostic('file-source-decoded', entry.path)
    }
  }

  private recordViewerThumbnailComplete(path: string,
    event?: ViewerImageCompleteEvent): void {
    if (event === undefined || path.length === 0) {
      return
    }
    const displayWidth = event.width
    const displayHeight = event.height
    if (displayWidth <= 0 || displayHeight <= 0) {
      return
    }
    this.updateImageVisualState(path, (state: ImageVisualState): void => {
      if (state.thumbnailDisplayWidth <= 0 || state.thumbnailDisplayHeight <= 0) {
        state.thumbnailDisplayWidth = displayWidth
        state.thumbnailDisplayHeight = displayHeight
      }
    })
  }

  private recordThumbnailArea(entry: FileEntry, index: number,
    surface: ThumbnailSurfaceKind, area: Area): void {
    if (!this.isImage(entry) || !this.thumbnailSurfaceIsCurrent(surface) ||
      typeof area.width !== 'number' || typeof area.height !== 'number' ||
      typeof area.globalPosition.x !== 'number' || typeof area.globalPosition.y !== 'number') {
      return
    }
    const uri = this.thumbnailSurfaceUri(entry, surface)
    this.updateImageVisualState(entry.path, (state: ImageVisualState): void => {
      state.thumbnailIndex = index
      state.thumbnailSurface = surface
      state.thumbnailX = area.globalPosition.x as number
      state.thumbnailY = area.globalPosition.y as number
      state.thumbnailWidth = area.width as number
      state.thumbnailHeight = area.height as number
      if (uri.length > 0) {
        state.transitionThumbnailUri = uri
      }
    })
  }

  private recordThumbnailVisibility(entry: FileEntry, index: number,
    surface: ThumbnailSurfaceKind, ratio: number): void {
    if (!this.isImage(entry) || !this.thumbnailSurfaceIsCurrent(surface)) {
      return
    }
    const uri = this.thumbnailSurfaceUri(entry, surface)
    this.updateImageVisualState(entry.path, (state: ImageVisualState): void => {
      state.thumbnailIndex = index
      state.thumbnailSurface = surface
      state.thumbnailVisibleRatio = Math.min(1, Math.max(0, ratio))
      if (uri.length > 0) {
        state.transitionThumbnailUri = uri
      }
    })
  }

  /**
   * One-shot source/target id for the image that opened the viewer. ArkUI's
   * geometryTransition requires the same id on both components during the
   * hierarchy change. Returning an empty id for every other item keeps the
   * normal list/grid/waterfall rendering and loading path unchanged.
   */
  private imageTransitionId(path: string): string {
    // The path is the identity of the file, not the current list/index
    // position.  The same path-derived id must survive the source/target
    // hierarchy swap and a viewer swipe must not reuse it.
    return path.length > 0 ? 'ugreen-image-geometry-' + path : ''
  }

  private shouldReplaceViewerTransitionSource(entry: FileEntry): boolean {
    if (!this.showImageViewer) {
      return false
    }
    if (this.viewerFallbackEntryActive) {
      return false
    }
    // The Swiper target is not committed until onAnimationEnd. Keep hiding
    // the previously committed source while pages are moving; otherwise a
    // fast swipe exposes the incoming thumbnail below the wrong detail page.
    const viewerEntry = this.viewerImageEntry
    return viewerEntry !== null && viewerEntry.path === entry.path && this.isImage(entry)
  }

  private fileImageShouldSyncLoad(entry: FileEntry): boolean {
    return this.viewerEntryTransitionActive &&
      this.viewerEntryTransitionPath === entry.path && this.isImage(entry)
  }

  private viewerImageShouldSyncLoad(entry: FileEntry,
    layer: ViewerImageLayer): boolean {
    return this.viewerEntryTransitionActive &&
      this.viewerEntryTransitionPath === entry.path &&
      this.viewerTransitionLayer === layer
  }

  private fileImageTransitionId(entry: FileEntry,
    surface: ThumbnailSurfaceKind): string {
    if (this.showImageViewer || !this.viewerGeometryBound) {
      return ''
    }
    if (!this.thumbnailSurfaceIsCurrent(surface)) {
      return ''
    }
    if (!this.viewerEntryTransitionActive ||
      this.viewerEntryTransitionPath !== entry.path || !this.isImage(entry)) {
      return ''
    }
    return this.imageTransitionId(entry.path)
  }

  private viewerImageTransitionId(entry: FileEntry, layer: ViewerImageLayer): string {
    if (!this.viewerEntryTransitionActive ||
      this.viewerEntryTransitionPath !== entry.path ||
      !this.viewerGeometryBound || this.viewerTransitionLayer !== layer) {
      return ''
    }
    return this.imageTransitionId(entry.path)
  }

  private clearViewerEntryTransition(): void {
    this.viewerEntryTransitionToken += 1
    this.viewerEntryTransitionActive = false
    this.viewerEntryTransitionPath = ''
    this.viewerTransitionKind = 'none'
    this.viewerTransitionLayer = 'thumbnail'
    this.viewerGeometryBound = false
  }

  private startViewerEntryTransition(entry: FileEntry): void {
    this.clearViewerEntryTransition()
    if (!this.hasViewerTransitionSource(entry, false)) {
      return
    }
    this.viewerEntryTransitionPath = entry.path
    this.viewerTransitionKind = 'entry'
    this.viewerTransitionLayer = 'thumbnail'
    this.viewerGeometryBound = true
    this.viewerEntryTransitionActive = true
  }

  private hasViewerTransitionSource(entry: FileEntry | null,
    requireFullyVisible: boolean): boolean {
    if (entry === null || !this.isImage(entry)) {
      return false
    }
    const state = this.imageVisualState(entry.path)
    const currentThumbnailUri = this.thumbnailSurfaceUri(entry, state.thumbnailSurface)
    const requiredRatio = requireFullyVisible ? 0.999 : 0.001
    const topBoundary = state.thumbnailSurface === 'search'
      ? this.topSafeInset() + 124 : this.fileContentTopInset()
    const bottomBoundary = Math.max(topBoundary,
      this.pageHeightVp - this.bottomSafeInset() - 8)
    const fitsReturnViewport = !requireFullyVisible ||
      (state.thumbnailY >= topBoundary &&
        state.thumbnailY + state.thumbnailHeight <= bottomBoundary)
    const transitionBitmapReady = this.viewerPreviewBitmaps[entry.path] !== undefined
    return transitionBitmapReady && currentThumbnailUri.length > 0 &&
      state.transitionThumbnailUri === currentThumbnailUri &&
      state.displayWidth > 0 && state.displayHeight > 0 &&
      state.thumbnailWidth > 0 && state.thumbnailHeight > 0 &&
      state.thumbnailVisibleRatio >= requiredRatio &&
      fitsReturnViewport && this.thumbnailSurfaceIsCurrent(state.thumbnailSurface)
  }

  private startViewerExitTransition(entry: FileEntry | null,
    layer: ViewerImageLayer): boolean {
    this.clearViewerEntryTransition()
    if (!this.hasViewerTransitionSource(entry, true)) {
      return false
    }
    const targetEntry = entry as FileEntry
    this.viewerEntryTransitionPath = targetEntry.path
    this.viewerTransitionKind = 'exit'
    this.viewerTransitionLayer = layer
    this.viewerGeometryBound = false
    this.viewerEntryTransitionActive = true
    return true
  }

  /**
   * The committed index is the only source for title, actions and progress.
   * viewerPendingIndex is intentionally excluded: a drag or spring-back must
   * leave all chrome bound to the page that is still stable on screen.
   */
  private committedViewerEntry(): FileEntry | null {
    if (this.viewerImageIndex >= 0 && this.viewerImageIndex < this.viewerImages.length) {
      return this.viewerImages[this.viewerImageIndex]
    }
    return this.viewerImageEntry
  }

  @Builder
  ImageViewer(): void {
    Stack() {
      // Keep the file surface mounted underneath the viewer. During a
      // downward pull this is the only layer that fades, so the unchanged
      // list/grid/waterfall page is revealed progressively behind the image.
      // The image itself remains the same fixed preview+original frame.
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.page_background'))
        .opacity(this.imageDismissBackdropOpacity)
        .hitTestBehavior(HitTestMode.None)

      Swiper(this.viewerSwiperController) {
        LazyForEach(this.viewerImageDataSource, (item: FileEntry, index: number) => {
          this.ViewerImagePage(item, index)
        }, (item: FileEntry) => item.path)
      }
      .index(this.viewerImageIndex)
      .width('100%')
      .height('100%')
      .indicator(false)
      .loop(false)
      .autoPlay(false)
      .itemSpace(0)
      .cachedCount(2)
      .duration(180)
      .curve(Curve.FastOutSlowIn)
      .effectMode(EdgeEffect.Spring)
      .disableSwipe(this.imageScale > 1.001 || this.viewerTransitionActive ||
        this.viewerEntryTransitionActive || this.imageDismissDragging ||
        this.isBusy || this.showImageMoreMenu ||
        this.showImageDetails || this.showRenameDialog)
      .width('100%')
      .height('100%')
      .onAreaChange((_, area) => {
        if (typeof area.width === 'number' && area.width > 0) {
          this.imageViewportWidthVp = area.width
        }
        if (typeof area.height === 'number' && area.height > 0) {
          this.imageViewportHeightVp = area.height
        }
      })
      .onAnimationStart((index: number, targetIndex: number) => {
        if (index !== targetIndex) {
          this.viewerTransitionActive = true
          this.viewerPendingIndex = targetIndex
          // Keep title, actions and progress on the committed page. The
          // pending index is only a transition/preload hint until end.
          if (targetIndex >= 0 && targetIndex < this.viewerImages.length) {
            this.logViewerDiagnostic('swiper-start', this.viewerImages[targetIndex].path)
          }
        }
      })
      // onChange can arrive while the page is still moving. Keep the
      // externally bound index stable during that animation and commit the
      // new page only from the documented animation-end callback.
      .onAnimationEnd((index: number) => {
        // Commit every externally visible binding before unlocking the
        // transition. There is no frame in which actions are enabled for the
        // old entry while the new page is considered stable.
        this.onViewerImageChanged(index)
        this.viewerPendingIndex = -1
        this.viewerTransitionActive = false
        this.logViewerDiagnostic('swiper-end')
        this.flushDeferredViewerVisualCommits()
        if (this.viewerCloseRequested) {
          this.viewerCloseRequested = false
          this.closeImageViewer()
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .opacity(this.viewerSurfaceOpacity)
  }

  @Builder
  ImageViewerChrome(): void {
    Stack() {
      Column() {
        this.ImageViewerNativeHeader()
        Blank()
          .layoutWeight(1)
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .opacity(this.imageChromeOpacity)
      .translate({ x: 0, y: this.imageTopChromeOffsetY, z: 0 })
      .hitTestBehavior(HitTestMode.None)

      Column() {
        Blank()
          .layoutWeight(1)
          .hitTestBehavior(HitTestMode.None)
        this.ImageViewerBottomBar()
      }
      .width('100%')
      .height('100%')
      .opacity(this.imageChromeOpacity)
      .translate({ x: 0, y: this.imageBottomChromeOffsetY, z: 0 })
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(this.showImageViewer ? HitTestMode.Transparent : HitTestMode.None)
  }

  @Builder
  ViewerImageLayers(entry: FileEntry): void {
    // There is deliberately one visible Image node per viewer page.  The
    // original is decoded into a PixelMap off the render path and replaces
    // the source of this same node on a frame callback; a second Image/Stack
    // is never kept around to produce an opacity ghost.
    this.ViewerImage(entry)
  }

  private viewerImageFit(entry: FileEntry): ImageFit {
    if (this.viewerActiveLayer(entry) === 'original') {
      return ImageFit.Contain
    }
    const preview = this.viewerBitmap(entry)
    const state = this.imageVisualState(entry.path)
    const width = preview === null ? state.thumbnailDisplayWidth : preview.displayWidth
    const height = preview === null ? state.thumbnailDisplayHeight : preview.displayHeight
    if (width <= 0 || height <= 0) {
      return ImageFit.Contain
    }
    const ratioDifference = (width / height) / this.viewerImageFrameAspectRatio(entry)
    // Limit preview cropping to small metadata/rounding discrepancies. An
    // unknown viewport frame or a differently cropped NAS thumbnail must not
    // cause substantial content loss. Neither fit mode stretches the image.
    return ratioDifference >= 0.98 && ratioDifference <= 1.02
      ? ImageFit.Cover : ImageFit.Contain
  }

  private viewerImageAnalyzerEnabled(entry: FileEntry): boolean {
    const current = this.committedViewerEntry()
    return this.imageAnalyzerSupported && this.imageAnalyzerTypes.length > 0 &&
      current !== null && current.path === entry.path &&
      this.viewerBitmap(entry) !== null && this.showImageViewer &&
      !this.viewerClosePending && !this.viewerEntryTransitionActive
  }

  @Builder
  ViewerImage(entry: FileEntry): void {
    Image(this.viewerImageSource(entry), {
      types: this.imageAnalyzerTypes,
      aiController: this.imageAnalyzerController
    })
      .width('100%')
      .height('100%')
      .orientation(this.viewerImageSourceOrientation(entry))
      // Cover crops only the preview's edges; both modes preserve source ratio.
      .objectFit(this.viewerImageFit(entry))
      .enableAnalyzer(this.viewerImageAnalyzerEnabled(entry))
      .geometryTransition(this.viewerImageTransitionId(entry, this.viewerTransitionLayer))
      .syncLoad(this.viewerImageShouldSyncLoad(entry, this.viewerTransitionLayer))
      .onComplete((event?: ViewerImageCompleteEvent): void => {
        const original = this.viewerBitmap(entry, true)
        this.logViewerRenderGeometry(entry.path,
          original === null ? 'preview-pixelmap' : 'original-pixelmap', event)
        if (original === null || this.imageVisualState(entry.path).visibleLayer !== 'original') {
          this.recordViewerThumbnailComplete(entry.path, event)
        }
      })
      .onError(() => this.markViewerImageFailed(entry.path))
  }

  @Builder
  ViewerImagePage(entry: FileEntry, index: number): void {
    Stack() {
      if (this.viewerImageFrameUsesWidth(entry)) {
        Stack() {
          this.ViewerImageLayers(entry)
        }
        .width('100%')
        .aspectRatio(this.viewerImageFrameAspectRatio(entry))
        .scale({
          x: this.viewerPageVisualScale(entry, index),
          y: this.viewerPageVisualScale(entry, index),
          z: 1
        })
        .translate({
          x: this.viewerPageOffsetX(index),
          y: this.viewerPageOffsetY(index),
          z: 0
        })
      } else {
        Stack() {
          this.ViewerImageLayers(entry)
        }
        .height('100%')
        .aspectRatio(this.viewerImageFrameAspectRatio(entry))
        .scale({
          x: this.viewerPageVisualScale(entry, index),
          y: this.viewerPageVisualScale(entry, index),
          z: 1
        })
        .translate({
          x: this.viewerPageOffsetX(index),
          y: this.viewerPageOffsetY(index),
          z: 0
        })
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
    .clip(true)
    // VisionImageAnalyzer installs its long-press interaction on the child
    // Image. Bind the viewer gestures in parallel so a normal moving finger
    // can reach the vertical pan recognizer while a stationary long press is
    // still available to text/subject recognition.
    .parallelGesture(
        GestureGroup(
          GestureMode.Parallel,
          // A double tap must win over a single tap. Parallel tap
          // recognizers dispatch the first tap to both recognizers, which is
          // why the chrome used to toggle before zooming. Exclusive keeps the
          // single-tap recognizer pending until the double-tap decision is
          // complete; the double-tap recognizer is deliberately first.
          GestureGroup(
            GestureMode.Exclusive,
            TapGesture({ count: 2, distanceThreshold: 8 })
              .onAction(() => {
                if (index === this.viewerImageIndex) {
                  this.handleImageDoubleTap()
                }
              }),
            TapGesture({ count: 1, distanceThreshold: 8 })
              .onAction(() => {
                if (index === this.viewerImageIndex && !this.imageTouchMoved) {
                  this.scheduleImageSingleTap()
                }
              })
          ),
          GestureGroup(
            GestureMode.Parallel,
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                if (index === this.viewerImageIndex) {
                  this.imageSavedScale = this.imageScale
                }
              })
              .onActionUpdate((event) => {
                if (index === this.viewerImageIndex) {
                  this.imageScale = Math.min(5, Math.max(1, this.imageSavedScale * event.scale))
                }
              })
              .onActionEnd(() => {
                if (index === this.viewerImageIndex) {
                  this.normalizeImageTransform()
                }
              }),
            PanGesture({
              fingers: 1,
              direction: PanDirection.All,
              distance: this.imageScale > 1.001 && index === this.viewerImageIndex ? 1 : 100000
            })
              .onActionStart(() => {
                if (index === this.viewerImageIndex && this.imageScale > 1.001) {
                  this.imageSavedOffsetX = this.imageOffsetX
                  this.imageSavedOffsetY = this.imageOffsetY
                }
              })
              .onActionUpdate((event) => {
                if (index === this.viewerImageIndex && this.imageScale > 1.001) {
                  this.imageOffsetX = this.imageSavedOffsetX + event.offsetX
                  this.imageOffsetY = this.imageSavedOffsetY + event.offsetY
                }
              })
              .onActionEnd((event) => this.handleImagePanEnd(event))
              .onActionCancel(() => this.handleImagePanCancel())
            ,
            // At the base zoom level, vertical dragging belongs to the
            // pull-to-dismiss interaction. Horizontal dragging remains owned
            // by Swiper, and zoomed images continue to use the PanGesture
            // above, so the three interactions do not steal one another.
            PanGesture({
              fingers: 1,
              direction: PanDirection.Vertical,
              distance: this.imageDismissGestureEnabled(index) ? 5 : 100000
            })
              .onActionStart(() => this.handleImageDismissStart(index))
              .onActionUpdate((event: GestureEvent) =>
                this.handleImageDismissUpdate(index, event))
              .onActionEnd((event: GestureEvent) =>
                this.handleImageDismissEnd(index, event))
              .onActionCancel(() => this.handleImageDismissCancel())
          )
        ),
        GestureMask.Normal
      )
    .onTouch((event: TouchEvent) => this.handleImageTouch(event, index))
  }

  @Builder
  ImageViewerNativeHeader(): void {
    Navigation() {}
      .mode(NavigationMode.Stack)
      .hideBackButton(true)
      .hideToolBar(true)
      .title({ builder: this.ImageViewerTopOverlay, height: this.topSafeInset() + 94 }, {
        barStyle: BarStyle.STACK,
        paddingStart: LengthMetrics.vp(0),
        paddingEnd: LengthMetrics.vp(0),
        backgroundColor: Color.Transparent
      })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],
        [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .width('100%')
      .height(this.topSafeInset() + 94)
      .backgroundColor(Color.Transparent)
      .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  ImageViewerTopOverlay(): void {
    Stack() {
      Row()
        .width('100%')
        .height(this.topSafeInset() + 94)
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [
            [$r('app.color.nav_bar_blur_bg'), 0.0],
            [$r('app.color.nav_bar_blur_bg'), 0.32],
            [$r('app.color.nav_bar_gradient_mid'), 0.68],
            [$r('app.color.nav_mask'), 1.0]
          ]
        })
        .linearGradientBlur(20, {
          fractionStops: [
            [1.0, 0.0],
            [0.88, 0.28],
            [0.38, 0.70],
            [0.0, 1.0]
          ],
          direction: GradientDirection.Bottom
        })
        .hitTestBehavior(HitTestMode.None)

      Row() {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_backward'))
            .fontSize(21)
            .fontColor([$r('sys.color.font_primary')])
        }
          .type(ButtonType.Normal)
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundColor(Color.Transparent)
          .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN))
          .hitTestBehavior(HitTestMode.Default)
          .monopolizeEvents(true)
          .onClick(() => this.closeImageViewer())
        Text(this.viewerHeaderTitle)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank().width(40)
      }
      .width('100%')
      .height(this.topSafeInset() + 94)
      .padding({ left: 12, right: 12, top: this.topSafeInset() + 8, bottom: 30 })
      .hitTestBehavior(HitTestMode.Default)
    }
    .width('100%')
    .height(this.topSafeInset() + 94)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  ImageViewerBottomBar(): void {
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() {}.tabBar(this.ImageViewerBarContent)
    }
    .vertical(false)
    .scrollable(false)
    .barOverlap(true)
    .barHeight(FLOATING_BAR_HEIGHT_VP)
    // 和首页/多选底栏统一宽度：5 项时每项约 61vp，与系统「智慧生活」底栏一致。
    // Do not derive this from the parent file bar mode: that bar remains
    // mounted behind the viewer and is normally in the 140vp tools mode.
    .barWidth(this.wideBottomBarCapsuleWidth())
    .barFloatingStyle({ barBottomMargin: 40, maskColor: Color.Transparent,
      systemMaterial: this.bottomCapsuleMaterial })
    .width('100%')
    .height(FLOATING_BAR_HEIGHT_VP + 80)
    .margin({ bottom: this.floatingBarBottomMargin() - 40 })
    .clip(false)
    .hitTestBehavior(HitTestMode.Default)
  }

  @Builder
  ImageViewerBarContent(): void {
    Row() {
      this.ImageViewerActionItem($r('sys.symbol.square_and_arrow_down'), '保存',
        () => this.saveCommittedViewerImage())
      this.ImageViewerActionItem($r('sys.symbol.share'), '分享',
        () => this.shareCommittedViewerImage())
      // 进度环保持原尺寸，只在槽位内绝对居中。
      Stack() {
        Progress({ value: this.viewerProgress(), total: 100, type: ProgressType.Ring })
          .width(27)
          .height(27)
          // This identity and all values come from the committed index. They
          // switch together only after Swiper reports animation end.
          .id(this.viewerProgressIdentity())
          .backgroundColor('#AAB3C1')
          .color('#2E6BFF')
          .style({
            strokeWidth: 3,
            enableSmoothEffect: false,
            // This ring always represents actual byte/decode/display
            // progress. Unknown-length work remains static instead of using
            // the unrelated infinite LOADING animation.
            status: ProgressStatus.PROGRESSING
          })
      }
      .layoutWeight(1)
      .height('100%')
      .hitTestBehavior(HitTestMode.Default)
      .monopolizeEvents(true)
      .onClick(() => this.loadCommittedViewerOriginalManually())
      this.ImageViewerActionItem($r('sys.symbol.trash'), '删除',
        () => this.deleteCommittedViewerImage())
      this.ImageViewerMoreButton()
    }
    .width('100%')
    // TabBar 上下各保留 4vp，可见内容高度是 48vp；这里必须按 48 排版，
    // 否则内容按 56vp 居中、视觉上会整体下沉约 14px（和系统底栏对不齐）。
    .height(FLOATING_BAR_HEIGHT_VP - 8)
    .padding({ left: 8, right: 8, top: 0, bottom: 0 })
    .borderRadius(FLOATING_BAR_HEIGHT_VP / 2)
    .onAreaChange((_, area) => {
      if (this.viewerBottomBarWidthVp <= 0 &&
        typeof area.width === 'number' && area.width > 0) {
        this.viewerBottomBarWidthVp = area.width
      }
    })
    // Do not allow a drag on the floating action capsule to become a
    // Swiper gesture underneath it.
    // The action items are children of this capsule. Block would stop their
    // hit test; Default keeps child clicks and blocks the Swiper underneath.
    .hitTestBehavior(HitTestMode.Default)
  }

  @Builder
  ImageViewerActionItem(icon: Resource, title: string, action: () => void): void {
    Column({ space: 2 }) {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(24)
          .fontColor([$r('app.color.icon_primary')])
      }
      .width('100%')
      .height(24)

      Text(title)
        .fontSize(12)
        .fontColor($r('app.color.text_primary'))
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Default)
    .monopolizeEvents(true)
    .onClick(action)
  }

  @Builder
  ImageViewerMoreButton(): void {
    Row() {
      this.ImageViewerActionItem($r('sys.symbol.ellipsis_circle'), '更多',
        () => this.openImageMoreMenu())
    }
    .layoutWeight(1)
    .height('100%')
    .bindPopup(this.showImageMoreMenu, {
      builder: this.ImageViewerMoreContent,
      placement: Placement.Top,
      enableArrow: false,
      autoCancel: true,
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.THICK, false),
      onStateChange: (state: PopupStateChange) => {
        if (!state.isVisible && this.showImageMoreMenu) {
          this.closeImageMoreMenu()
        }
      }
    })
  }

  @Builder
  ImageViewerMoreContent(): void {
    Column() {
      this.ImageViewerMoreRow($r('sys.symbol.arrow_2_circlepath'), '旋转',
        () => this.rotateViewerOverlayImage(), true)
      this.ImageViewerMoreRow($r('sys.symbol.rectangle_and_arrowshape_turn_up_right'), '其他应用打开',
        () => this.openViewerOverlayWithOtherApp(), true)
      this.ImageViewerMoreRow($r('sys.symbol.rectangle_on_rectangle'), '重命名',
        () => this.openRenameFromViewerOverlay(), true)
      this.ImageViewerMoreRow($r('sys.symbol.doc'), '详情',
        () => this.openImageDetails(), false)
    }
    .width(Math.min(340, this.effectivePageWidth() - 40))
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
  }

  /**
   * Fade only the scrim. The underlying image and the bottom capsule remain
   * fixed while the menu itself performs the anchored expansion.
   */
  private imageMoreOverlayTransition(): TransitionEffect {
    const appear = TransitionEffect.opacity(0).animation({
      duration: 170,
      curve: Curve.EaseOut
    })
    const disappear = TransitionEffect.opacity(0).animation({
      duration: 140,
      curve: Curve.EaseIn
    })
    return TransitionEffect.asymmetric(appear, disappear)
  }

  /**
   * HarmonyOS ArkUI anchored menu motion: the lower edge is the transform
   * origin, so the glass card unfolds upward from the More button. The small
   * initial translation keeps the first frame visually attached to the
   * button, while the spring settles the card without a hard pop.
   */
  private imageMoreMenuTransition(): TransitionEffect {
    const appear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.scale({
        // The More action is the right-most item in the five-slot capsule.
        // Use the corresponding lower-right point as the transform origin;
        // scaling both axes from near zero makes the card grow from a point,
        // rather than unfolding from a horizontal edge.
        x: 0.08,
        y: 0.08,
        z: 1,
        centerX: '94%',
        centerY: '100%'
      }))
      .combine(TransitionEffect.translate({ y: 14 }))
      .animation({
        duration: 300,
        curve: curves.interpolatingSpring(0, 1, 320, 30)
      })
    const disappear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.scale({
        x: 0.08,
        y: 0.08,
        z: 1,
        centerX: '94%',
        centerY: '100%'
      }))
      .combine(TransitionEffect.translate({ y: 14 }))
      .animation({
        duration: 180,
        curve: Curve.EaseIn
      })
    return TransitionEffect.asymmetric(appear, disappear)
  }

  @Builder
  ImageViewerMoreRow(icon: Resource, title: string, action: () => void, showDivider: boolean): void {
    Row() {
      SymbolGlyph(icon)
        .fontSize(21)
        .fontColor([$r('app.color.icon_primary')])
        .width(38)
      Text(title)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .height(52)
    .padding({ left: 12, right: 12 })
    .borderRadius(14)
    .backgroundColor(Color.Transparent)
    .border({
      width: { bottom: showDivider ? 0.5 : 0 },
      color: '#229AA5B5',
      style: BorderStyle.Solid
    })
    .onClick(action)
  }

  @Builder
  ImageViewerDetailsOverlay(): void {
    Column() {}
      .width(0)
      .height(0)
      .bindSheet($$this.showImageDetails, this.ImageViewerDetailsContent, {
        height: SheetSize.FIT_CONTENT,
        dragBar: false,
        showClose: false,
        systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.THICK, false),
        onWillDismiss: () => this.closeImageDetails()
      })
  }

  @Builder
  ImageViewerDetailsContent(): void {
    if (this.viewerOverlayEntry !== null) {
    Column({ space: 12 }) {
      Row() {
        Text('详情')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text('×')
          .fontSize(28)
          .fontColor($r('app.color.text_tertiary'))
          .onClick(() => this.closeImageDetails())
      }
      .width('100%')

      this.ImageDetailsLine('文件名', (this.viewerOverlayEntry as FileEntry).name)
      this.ImageDetailsLine('路径', this.entryDisplayPath(this.viewerOverlayEntry as FileEntry))
      this.ImageDetailsLine('大小', this.formatSize((this.viewerOverlayEntry as FileEntry).size))
      this.ImageDetailsLine('修改时间',
        this.formatTime((this.viewerOverlayEntry as FileEntry).modifiedTime))
      this.ImageDetailsLine('文件类型',
        this.fileType(this.viewerOverlayEntry as FileEntry).length > 0
          ? this.fileType(this.viewerOverlayEntry as FileEntry) : '图片')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 20 })
    .borderRadius(22)
    .onClick(() => {})
    }
  }

  @Builder
  ImageDetailsLine(label: string, value: string): void {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .width(68)
      Text(value)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  AudioPlayerOverlay(entry: FileEntry): void {
    Column() {
      Row() {
        Text('音频播放')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .layoutWeight(1)
        Text('×')
          .fontSize(30)
          .fontColor($r('app.color.text_secondary'))
          .onClick(() => this.closeAudioPlayer())
      }
      .width('100%')
      .width('92%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .borderRadius(24)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, false, '#66101828'))
      .margin({ top: 12 })

      Column({ space: 14 }) {
        if (this.previewUri(entry).length > 0) {
          Image(this.previewUri(entry))
            .width(190)
            .height(190)
            .orientation(ImageRotateOrientation.AUTO)
            .objectFit(ImageFit.Cover)
            .borderRadius(26)
        } else {
          SymbolGlyph($r('sys.symbol.doc_text'))
            .fontSize(78)
            .fontColor([$r('app.color.icon_muted')])
        }
        Text(entry.name)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
        Text('来自云盘的音频 · 已准备播放')
          .fontSize(13)
          .fontColor($r('app.color.text_faint'))
      }
      .width('88%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)

      Column({ space: 10 }) {
        Row() {
          Text(this.formatPlaybackTime(this.audioCurrentMs))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          Text(this.formatPlaybackTime(this.audioDurationMs))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        Slider({
          value: Math.min(this.audioCurrentMs, Math.max(1, this.audioDurationMs)),
          min: 0,
          max: Math.max(1, this.audioDurationMs)
        })
          .width('100%')
          .onChange((value: number) => this.seekAudio(value))
        Row({ space: 10 }) {
          Button('重置')
            .layoutWeight(1)
            .height(44)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor(Color.Transparent)
            .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
            .enabled(!this.isBusy)
            .onClick(() => this.rewindAudio())
          Button(this.audioPlaying ? '暂停' : '播放')
            .layoutWeight(1)
            .height(44)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor(Color.Transparent)
            .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN, true, '#552E6BFF'))
            .enabled(!this.isBusy)
            .onClick(() => this.toggleAudio())
          Button('保存 Download')
            .layoutWeight(1)
            .height(44)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor(Color.Transparent)
            .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
            .enabled(!this.isBusy)
            .onClick(() => this.cacheToLocal(entry))
        }
        .width('100%')
      }
      .width('92%')
      .padding(16)
      .borderRadius(28)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.REGULAR, false))
      .margin({ bottom: 22 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#101828')
  }

  @Builder
  VideoPlayerOverlay(entry: FileEntry): void {
    // Stack defaults to centered child alignment.  The media/control layers
    // occupy the whole window, but the compact header does not; explicitly
    // pin the overlay stack to the top-left so the header cannot be centered
    // in the video viewport.
    Stack({ alignContent: Alignment.TopStart }) {
      // The media surface owns the complete window. The player scale mode
      // supplies the aspect-preserving letterbox; the UI never resizes the
      // surface to the source video's raw width/height.
      Stack({ alignContent: Alignment.Center }) {
        XComponent({
          id: 'ugreen-video-surface',
          type: XComponentType.SURFACE,
          controller: this.videoSurfaceController
        })
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Black)
          .opacity(this.videoFirstFrame ? 1 : 0)
          .onLoad(() => this.handleVideoSurfaceLoad())

        if (!this.videoFirstFrame) {
          if (this.previewUri(entry).length > 0) {
            Image(this.previewUri(entry))
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
          } else {
            SymbolGlyph($r('sys.symbol.play'))
              .fontSize(72)
              .fontColor([$r('app.color.icon_muted')])
          }
          if (!this.videoPrepared || this.videoBufferingPercent < 100) {
            LoadingProgress()
              .width(32)
              .height(32)
              .color('#2E6BFF')
          }
        }

        // XComponent can consume touch events itself.  A transparent sibling
        // with an official ArkUI TapGesture keeps double-tap recognition
        // reliable while HitTestMode.Transparent lets the surface continue
        // receiving its normal input.
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.Transparent)
          .gesture(
            TapGesture({ count: 2, distanceThreshold: 8 })
              .onAction(() => this.handleVideoDoubleTap())
          )
      }
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Black)
        .onAreaChange((_, area) => {
          if (typeof area.width === 'number' && typeof area.height === 'number' &&
            area.width > 0 && area.height > 0) {
            this.handleVideoViewportArea(area.width, area.height)
          }
        })

      if (!this.videoPipBackgrounded) {
        Stack({ alignContent: Alignment.Bottom }) {
          this.VideoPlayerGlassBar(entry)
        }
          .width('100%')
          .height('100%')
          .zIndex(2)
          .hitTestBehavior(HitTestMode.None)

        this.VideoPlayerNativeHeader()
      }
    }
    // Keep the original XComponent mounted while PiP is active so the system
    // controller keeps its surface. Shrinking only this host reveals the file
    // page underneath without creating a second video node or stopping AVPlayer.
    .width(this.videoPipBackgrounded ? 1 : '100%')
    .height(this.videoPipBackgrounded ? 1 : '100%')
    .backgroundColor(this.videoPipBackgrounded ? Color.Transparent : Color.Black)
    .hitTestBehavior(this.videoPipBackgrounded ? HitTestMode.None : HitTestMode.Default)
  }

  @Builder
  VideoPlayerNativeHeader(): void {
    Navigation() {}
      .mode(NavigationMode.Stack)
      .hideBackButton(true)
      .hideToolBar(true)
      // Keep the title builder and its height stable during window rotation.
      // Move the safe-area inset outside Navigation so AVCastPicker keeps its
      // native node instead of rebuilding with the title configuration.
      .title({ builder: this.VideoPlayerHeaderContent, height: 76 }, {
        barStyle: BarStyle.STACK,
        paddingStart: LengthMetrics.vp(0),
        paddingEnd: LengthMetrics.vp(0),
        backgroundColor: Color.Transparent
      })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],
        [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .width('100%')
      .height(76)
      .margin({ top: this.videoTopInset() })
      .backgroundColor(Color.Transparent)
      .hitTestBehavior(HitTestMode.Transparent)
      .zIndex(3)
  }

  @Builder
  VideoPlayerHeaderContent(): void {
    Row({ space: 8 }) {
    Button() {
      SymbolGlyph($r('sys.symbol.chevron_backward'))
        .fontSize(24)
        .fontColor([Color.White])
    }
      .type(ButtonType.Normal)
      .width(40)
      .height(40)
      .borderRadius(20)
      .backgroundColor(Color.Transparent)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true, '#44202020'))
      .onClick(() => this.closeVideoPlayer())
    Text(this.videoEntry === null ? '' : (this.videoEntry as FileEntry).name)
      .fontSize(17)
      .fontWeight(FontWeight.Bold)
      .fontColor(Color.White)
      .layoutWeight(1)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
    Button() {
      // Keep the supplied PiP artwork as a hand-drawn vector asset.  The
      // SVG has no raster background, so it stays crisp at every density.
      Image($r('app.media.video_pip_icon'))
        .width(24)
        .height(24)
        .objectFit(ImageFit.Contain)
    }
      .type(ButtonType.Normal)
      .width(40)
      .height(40)
      .backgroundColor(Color.Transparent)
      .borderRadius(20)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true, '#44202020'))
      .enabled(this.videoSurfaceReady && this.videoPrepared &&
        !this.videoPipCreating && !this.isBusy)
      .onClick(() => this.toggleVideoPip())
    // Use the official picker with a synchronously loaded local glyph. Its
    // default symbol initializes asynchronously when Navigation relayouts.
    Stack({ alignContent: Alignment.Center }) {
      AVCastPicker({
        sessionType: 'video',
        normalColor: Color.White,
        activeColor: '#2E6BFF',
        customPicker: this.VideoCastIcon,
        onStateChange: (state: AVCastPickerState): void => this.handleVideoCastPickerState(state)
      })
        .width(24)
        .height(24)
        .backgroundColor(Color.Transparent)
    }
      .width(40)
      .height(40)
      .borderRadius(20)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true, '#44202020'))
    }
      .width('100%')
      .height(76)
      .padding({ left: 12, right: 12, top: 8, bottom: 28 })
      .zIndex(3)
  }

  @Builder
  VideoCastIcon(): void {
    Image($r('app.media.video_cast_icon'))
      .width(24)
      .height(24)
      .objectFit(ImageFit.Contain)
      .fillColor(this.videoCasting ? '#2E6BFF' : '#FFFFFF')
      .syncLoad(true)
  }

  @Builder
  VideoPlayerGlassBar(entry: FileEntry): void {
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() {}.tabBar(this.VideoPlayerTabBar)
    }
      .vertical(false)
      .scrollable(false)
      .barOverlap(true)
      .barHeight(this.videoTransferError(entry).length > 0 ? 80 : 56)
      .barWidth(Math.max(240, this.pageWidthVp - 24))
      .barFloatingStyle({ barBottomMargin: 40, maskColor: Color.Transparent,
        systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, false, '#66202020') })
      .width('100%')
      .height((this.videoTransferError(entry).length > 0 ? 80 : 56) + 80)
      .margin({ bottom: this.videoBottomInset() + 8 - 40 })
      .clip(false)
      .hitTestBehavior(HitTestMode.Default)
  }

  @Builder
  VideoPlayerTabBar(): void {
    if (this.videoEntry !== null) {
      this.VideoPlayerBarContent(this.videoEntry as FileEntry)
    }
  }

  @Builder
  VideoPlayerBarContent(entry: FileEntry): void {
    Column({ space: 4 }) {
      Row({ space: 4 }) {
        // Keep playback controls at the leading edge, as in the official
        // video controller.  A previous-video action is intentionally not
        // exposed; only the next item is available when the window is
        // landscape.
        Button() {
          SymbolGlyph(this.videoPlaying
            ? $r('sys.symbol.pause') : $r('sys.symbol.play'))
            .fontSize(24)
            .fontColor([Color.White])
        }
          .type(ButtonType.Normal)
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .enabled(this.videoPrepared && !this.isBusy && !this.videoControlPending)
          .onClick(() => this.toggleVideo())

        if (this.videoLandscape) {
          Button() {
            SymbolGlyph($r('sys.symbol.chevron_forward'))
              .fontSize(20)
              .fontColor([Color.White])
          }
            .type(ButtonType.Normal)
            .width(36)
            .height(40)
            .backgroundColor(Color.Transparent)
            .enabled(this.videoSibling(1) !== null && !this.isBusy)
            .onClick(() => this.switchVideo(1))
        }

        Text(this.formatPlaybackTime(this.videoCurrentMs))
          .fontSize(11)
          .fontColor(Color.White)
          .width(40)
        // Keep the native AVPlayer buffer visible behind the playback
        // thumb, following the official network-video example.  The
        // buffering callback reports an estimated duration ahead of the
        // playhead, which VideoPlaybackManager converts to this absolute
        // timeline percentage.
        Stack({ alignContent: Alignment.Center }) {
          Slider({
            value: this.videoBufferedTimelineMs(),
            min: 0,
            max: Math.max(1, this.videoDurationMs),
            direction: Axis.Horizontal,
            // Keep the buffer and seek layers on the same track geometry.
            // SliderStyle.NONE removes the thumb's layout inset, so a
            // stacked NONE/OutSet pair leaves a visible extra segment at
            // the leading edge.
            style: SliderStyle.OutSet
          })
            .trackColor('#55FFFFFF')
            .selectedColor('#66FFFFFF')
            .blockColor(Color.Transparent)
            .blockBorderColor(Color.Transparent)
            .trackThickness(4)
            .enabled(false)

          Slider({
            value: Math.min(this.videoCurrentMs, Math.max(1, this.videoDurationMs)),
            min: 0,
            max: Math.max(1, this.videoDurationMs),
            direction: Axis.Horizontal,
            style: SliderStyle.OutSet
          })
            .trackColor(Color.Transparent)
            .selectedColor('#2E6BFF')
            .trackThickness(4)
            .enabled(this.videoDurationMs > 0)
            .onChange((value: number) => this.seekVideo(value))
        }
          .layoutWeight(1)
          Text(this.formatPlaybackTime(this.videoDurationMs))
          .fontSize(11)
          .fontColor(Color.White)
          .width(40)
          .textAlign(TextAlign.End)

        Button() {
          SymbolGlyph($r('sys.symbol.rotate_left'))
            .fontSize(22)
            .fontColor([Color.White])
        }
          .type(ButtonType.Normal)
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .enabled(!this.isBusy && !this.videoOrientationChanging)
          .onClick(() => this.rotateVideoInterface())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.videoTransferError(entry).length > 0) {
        Text(this.videoStatusText(entry))
          .fontSize(12)
          .fontColor('#FFFF8A8A')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
  }

  private immersiveMaterial(style: uiMaterial.ImmersiveStyle, interactive: boolean = true,
    materialColor: string = ''): uiMaterial.Material {
    const options: uiMaterial.ImmersiveOptions = {
      style: style,
      interactive: interactive,
      applyShadow: true,
      lightEffect: { color: '#FFFFFFFF' }
    }
    if (materialColor.length > 0) {
      options.materialColor = materialColor
    }
    return new uiMaterial.ImmersiveMaterial(options)
  }

  private showImmersiveToast(message: string): void {
    promptAction.showToast({
      message: message,
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN)
    })
  }

  private reportError(error: Object, title: string = '操作失败'): void {
    this.presentErrorMessage(readableUgreenError(error), title)
  }

  private presentErrorMessage(message: string, title: string = '操作失败'): void {
    const normalized = message.trim().length > 0 ? message.trim() : '操作失败，请稍后重试'
    this.errorText = normalized
    if (this.errorDialogShowing) {
      return
    }
    this.errorDialogShowing = true
    this.showErrorDialog(normalized, title)
  }

  private async showErrorDialog(message: string, title: string): Promise<void> {
    try {
      await promptAction.showDialog({
        title: title,
        message: message,
        buttons: [
          { text: '知道了', color: this.isDarkTheme ? '#FFFFFFFF' : '#536174' }
        ],
        systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false)
      })
    } catch (_) {
      this.showImmersiveToast(message)
    } finally {
      this.errorDialogShowing = false
    }
  }

  private ensureCacheState(): Promise<void> {
    if (this.cacheStatePromise === null) {
      this.cacheStatePromise = this.loadCacheState()
    }
    return this.cacheStatePromise
  }

  private ensureImageRotationState(): Promise<void> {
    if (this.imageRotationStatePromise === null) {
      const context = getContext(this) as Context
      this.imageRotationStatePromise = this.imageRotationStore.initialize(context)
    }
    return this.imageRotationStatePromise
  }

  private async loadCacheState(): Promise<void> {
    const context = getContext(this) as Context
    this.cacheDirectory = context.cacheDir
    DownloadDestination.initialize(context)
    StorageBudget.initialize(context, this.cacheLimitBytes)
    StorageBudget.protect((): string[] => {
      const paths: string[] = [this.audioLocalPath, this.videoLocalPath]
      if (this.showImageViewer) {
        for (const key of Object.keys(this.viewerOriginalLocalPaths)) { paths.push(this.viewerOriginalLocalPaths[key]) }
      }
      return paths
    })
    await this.repository.initializeThumbnailCache(context)
    this.thumbnailDirectory = this.repository.thumbnailCacheDirectory()
    this.repository.initializeMetadata(context)
    try {
      this.cachePreferences = await preferences.getPreferences(context, 'ugreen-cache-settings')
      const storedLimit = await this.cachePreferences.get('cache_limit_bytes', CacheManager.DEFAULT_LIMIT_BYTES)
      if (typeof storedLimit === 'number' && storedLimit > 0) {
        this.cacheLimitBytes = storedLimit
        StorageBudget.initialize(context, storedLimit)
      }
      const thumbnailGeneration = await this.cachePreferences.get('thumbnail_cache_generation', 0)
      if (typeof thumbnailGeneration !== 'number' || thumbnailGeneration < 2) {
        const removedBytes = await CacheManager.clearLegacyPreviews(this.cacheDirectory)
        await this.cachePreferences.put('thumbnail_cache_generation', 2)
        await this.cachePreferences.flush()
        console.info('[UgreenPreview] cleared legacy thumbnails: ' + removedBytes.toString())
      }
      const originalGeneration = await this.cachePreferences.get('original_cache_generation', 0)
      if (typeof originalGeneration !== 'number' || originalGeneration < 3) {
        // Old original files were not account- or version-scoped. They are
        // private disposable cache files, so invalidate them once rather than
        // risk showing another account's file after the cache-key migration.
        const removedBytes = await CacheManager.clear(this.cacheDirectory)
        await this.cachePreferences.put('original_cache_generation', 3)
        await this.cachePreferences.flush()
        console.info('[UgreenCache] cleared legacy originals: ' + removedBytes.toString())
      }
    } catch (_) {
      // The app can still use the default limit if preferences are unavailable.
    }
    await this.refreshCacheUsage()
  }

  private ensureNetworkState(): Promise<void> {
    if (this.networkStatePromise === null) {
      this.networkStatePromise = this.loadNetworkState()
    }
    return this.networkStatePromise
  }

  private ensurePlaybackState(): Promise<void> {
    if (this.playbackStatePromise === null) {
      this.playbackStatePromise = this.loadPlaybackState()
    }
    return this.playbackStatePromise
  }

  private ensureDownloadState(): Promise<void> {
    if (this.downloadStatePromise === null) {
      this.downloadStatePromise = this.loadDownloadState()
    }
    return this.downloadStatePromise
  }

  private ensureVideoState(): Promise<void> {
    if (this.videoStatePromise === null) {
      this.videoStatePromise = this.loadVideoState()
    }
    return this.videoStatePromise
  }

  private async loadDownloadState(): Promise<void> {
    await this.ensureCacheState()
    await this.ensureNetworkState()
    try {
      const context = getContext(this) as Context
      await this.downloadQueue.initialize(context, this.repository, this.networkPolicy)
      await this.uploadQueue.initialize(context, this.repository, this.networkPolicy,
        (tasks: UploadTaskRecord[]): void => { this.uploadTasks = tasks.slice() })
      this.downloadQueue.onChange(this.downloadStateListener)
      this.downloadTasks = this.downloadQueue.snapshot().concat(this.videoTransferManager.snapshotTasks())
      this.downloadSpeedBytesPerSecond = this.downloadQueue.speed()
      await this.downloadQueue.setMeteredDownloadContinue(this.meteredDownloadContinue)
    } catch (error) {
      console.warn('[UgreenDownload] initialize failed: ' + JSON.stringify(error))
    }
  }

  private async loadNetworkState(): Promise<void> {
    this.networkPolicy.onChange(this.networkStateListener)
    try {
      const context = getContext(this) as Context
      this.networkPreferences = await preferences.getPreferences(context, 'ugreen-network-settings')
      const storedAuto = await this.networkPreferences.get('metered_auto_original', false)
      const storedRefresh = await this.networkPreferences.get('metered_background_refresh', false)
      const storedDownloadContinue = await this.networkPreferences.get('metered_download_continue', false)
      if (typeof storedAuto === 'boolean') {
        this.meteredAutoOriginal = storedAuto
      }
      if (typeof storedRefresh === 'boolean') {
        this.meteredBackgroundRefresh = storedRefresh
      }
      if (typeof storedDownloadContinue === 'boolean') {
        this.meteredDownloadContinue = storedDownloadContinue
      }
    } catch (_) {
      // Safe defaults remain: no automatic original or background refresh on
      // a metered/unknown network.
    }
    await this.networkPolicy.initialize()
    this.networkClass = this.networkPolicy.current()
    this.repository.setMeteredBackgroundRefreshAllowed(this.meteredBackgroundRefresh)
  }

  private async loadPlaybackState(): Promise<void> {
    try {
      const context = getContext(this) as Context
      this.playbackPreferences = await preferences.getPreferences(context, 'ugreen-playback-settings')
      const storedVideoBackground = await this.playbackPreferences.get(
        'background_video_playback', true)
      const storedAudioBackground = await this.playbackPreferences.get(
        'background_audio_playback', true)
      const storedVideoPip = await this.playbackPreferences.get(
        'video_background_auto_pip', false)
      const storedAutoPlay = await this.playbackPreferences.get(
        'auto_play_on_open', true)
      if (typeof storedVideoBackground === 'boolean') {
        this.backgroundVideoPlayback = storedVideoBackground
      }
      if (typeof storedAudioBackground === 'boolean') {
        this.backgroundAudioPlayback = storedAudioBackground
      }
      if (typeof storedVideoPip === 'boolean') {
        this.videoBackgroundAutoPip = storedVideoPip
      }
      if (typeof storedAutoPlay === 'boolean') {
        this.autoPlayOnOpen = storedAutoPlay
      }
    } catch (error) {
      // Playback defaults preserve the behavior from before this settings
      // page existed, so an unavailable preference store is non-fatal.
      console.warn('[UgreenPlayback] load preferences failed: ' + JSON.stringify(error))
    }
  }

  private async persistNetworkPreferences(): Promise<void> {
    try {
      if (this.networkPreferences === null) {
        await this.ensureNetworkState()
      }
      if (this.networkPreferences === null) {
        return
      }
      await this.networkPreferences.put('metered_auto_original', this.meteredAutoOriginal)
      await this.networkPreferences.put('metered_background_refresh', this.meteredBackgroundRefresh)
      await this.networkPreferences.put('metered_download_continue', this.meteredDownloadContinue)
      await this.networkPreferences.flush()
    } catch (_) {
      // Settings should not block file browsing when preferences are unavailable.
    }
  }

  private async setMeteredAutoOriginal(value: boolean): Promise<void> {
    this.meteredAutoOriginal = value
    await this.persistNetworkPreferences()
    if (this.showImageViewer && value && this.networkPolicy.isMetered()) {
      this.prefetchViewerImages(this.viewerImageIndex)
    }
    if (!value && this.networkPolicy.isMetered()) {
      this.stopQueuedViewerAutoLoads()
    }
  }

  private async setMeteredBackgroundRefresh(value: boolean): Promise<void> {
    this.meteredBackgroundRefresh = value
    this.repository.setMeteredBackgroundRefreshAllowed(value)
    await this.persistNetworkPreferences()
  }

  private async setMeteredDownloadContinue(value: boolean): Promise<void> {
    this.meteredDownloadContinue = value
    await this.persistNetworkPreferences()
    await this.ensureDownloadState()
    await this.downloadQueue.setMeteredDownloadContinue(value)
  }

  private networkDisplayName(): string {
    return this.networkPolicy.displayName()
  }

  private async refreshCacheUsage(): Promise<void> {
    if (this.cacheDirectory.length === 0) {
      return
    }
    this.cacheUsageBytes = StorageBudget.scan()
    await this.repository.enforceThumbnailCacheLimit(StorageBudget.thumbnailAllowance())
    this.persistentUsageBytes = StorageBudget.persistentUsage()
  }

  private ensureLoginState(): Promise<void> {
    if (this.loginStatePromise === null) {
      this.loginStatePromise = this.loadLoginPreferences()
    }
    return this.loginStatePromise
  }

  private async loadLoginPreferences(): Promise<void> {
    try {
      const context = getContext(this) as Context
      this.loginPreferences = await preferences.getPreferences(context, 'ugreen-login-settings')
      const storedLinkId = await this.loginPreferences.get('cloud_link_id', this.linkId)
      const storedUsername = await this.loginPreferences.get('cloud_username', '')
      const storedPassword = await this.loginPreferences.get('cloud_password', '')
      const storedRemember = await this.loginPreferences.get('remember_password', false)
      const storedAuto = await this.loginPreferences.get('auto_login', false)
      if (typeof storedLinkId === 'string' && storedLinkId.length > 0) {
        this.linkId = storedLinkId
      }
      if (typeof storedUsername === 'string') {
        this.username = storedUsername
      }
      if (typeof storedRemember === 'boolean') {
        this.rememberPassword = storedRemember
      }
      if (typeof storedAuto === 'boolean') {
        this.autoLogin = storedAuto
      }
      if (this.rememberPassword && typeof storedPassword === 'string') {
        this.password = storedPassword
      }
      if (this.rememberPassword && this.username.length > 0 && this.password.length > 0) {
        // Rehydrate the in-memory re-login path even when the current token
        // has expired after a long idle period or the UI object was rebuilt.
        this.repository.setReconnectCredentials(this.username, this.password)
      }
      if (this.autoLogin && this.rememberPassword && this.linkId.length > 0 &&
        this.username.length > 0 && this.password.length > 0) {
        this.silentAutoLogin = true
        // Do not render the login card during startup recovery. Show the
        // normal file-page shell while the session is restored in background.
        this.screen = 'files'
        this.selectedBottomTab = 'home'
        this.currentPath = ''
        this.replaceEntries([])
        this.updateTopTitle('个人空间', false)
        this.updateBottomBarVisibility(false)
        try {
          await this.handleLogin(true)
        } finally {
          this.silentAutoLogin = false
        }
      }
    } catch (_) {
      // Login remains available with empty fields if local preferences are unavailable.
    }
  }

  private async persistLoginPreferences(): Promise<void> {
    try {
      if (this.loginPreferences === null) {
        await this.ensureLoginState()
      }
      if (this.loginPreferences === null) {
        return
      }
      await this.loginPreferences.put('cloud_link_id', this.linkId)
      await this.loginPreferences.put('cloud_username', this.username)
      await this.loginPreferences.put('cloud_password', this.rememberPassword ? this.password : '')
      await this.loginPreferences.put('remember_password', this.rememberPassword)
      await this.loginPreferences.put('auto_login', this.autoLogin)
      await this.loginPreferences.flush()
    } catch (_) {
      // The login flow must not fail only because preferences cannot be written.
    }
  }

  private async loadSearchPreferences(): Promise<void> {
    try {
      const context = getContext(this) as Context
      this.searchPreferences = await preferences.getPreferences(context, 'ugreen-search-settings')
      const storedHistory = await this.searchPreferences.get('search_history', [])
      const history: string[] = []
      if (storedHistory instanceof Array) {
        for (const item of storedHistory) {
          if (typeof item === 'string' && item.trim().length > 0 && history.indexOf(item) < 0) {
            history.push(item)
          }
        }
      }
      this.searchHistory = history.slice(0, 8)
    } catch (_) {
      // Search history is optional; search remains available without it.
    }
  }

  private ensureSearchState(): Promise<void> {
    if (this.searchStatePromise === null) {
      this.searchStatePromise = this.loadSearchPreferences()
    }
    return this.searchStatePromise
  }

  private searchHistoryItems(): string[] {
    if (this.searchHistoryExpanded) {
      return this.searchHistory.slice()
    }
    return this.searchHistory.slice(0, 4)
  }

  private searchResultLocation(entry: FileEntry): string {
    const path = entry.path.trim().replace(/\/+$/, '')
    const separator = path.lastIndexOf('/')
    if (separator <= 0) {
      return '当前目录'
    }
    return path.substring(0, separator)
  }

  private cloneNavigationEntryStack(source: FileEntry[][]): FileEntry[][] {
    const result: FileEntry[][] = []
    for (const entries of source) {
      result.push(entries.slice())
    }
    return result
  }

  private cloneDirectoryViewState(state: DirectoryViewState): DirectoryViewState {
    return {
      mode: state.mode,
      offset: state.offset === null ? null : {
        xOffset: state.offset.xOffset,
        yOffset: state.offset.yOffset
      },
      anchor: state.anchor === null ? null : {
        path: state.anchor.path,
        y: state.anchor.y
      }
    }
  }

  private cloneNavigationViewStateStack(source: DirectoryViewState[]): DirectoryViewState[] {
    const result: DirectoryViewState[] = []
    for (const state of source) {
      result.push(this.cloneDirectoryViewState(state))
    }
    return result
  }

  private createSearchSession(): SearchSession {
    const originViewState = this.captureDirectoryViewState()
    return {
      query: '',
      scope: 'current',
      results: [],
      loading: false,
      historyExpanded: false,
      scrollOffset: 0,
      originPath: this.currentPath,
      originRootType: this.currentRootType,
      originEntries: this.entries.slice(),
      originNavigationStack: this.navigationStack.slice(),
      originNavigationEntryStack: this.cloneNavigationEntryStack(this.navigationEntryStack),
      originNavigationRootTypeStack: this.navigationRootTypeStack.slice(),
      originNavigationViewStateStack: this.cloneNavigationViewStateStack(
        this.navigationViewStateStack),
      originViewState: this.cloneDirectoryViewState(originViewState),
      originPageIndex: this.currentPageIndex,
      originPageHasMore: this.currentPageHasMore,
      originPageIndexStack: this.navigationPageIndexStack.slice(),
      originPageHasMoreStack: this.navigationPageHasMoreStack.slice(),
      targetParentPath: '',
      targetNavigationDepth: this.navigationStack.length,
      returnMode: 'none'
    }
  }

  private captureSearchSession(): void {
    if (this.searchSession === null) {
      return
    }
    this.searchSession.query = this.searchQuery
    this.searchSession.scope = this.searchScope
    this.searchSession.results = this.searchResults.slice()
    this.searchSession.loading = this.searchLoading
    this.searchSession.historyExpanded = this.searchHistoryExpanded
    this.searchSession.scrollOffset = Math.max(0, this.searchScrollOffset)
  }

  private searchResultCacheKey(query: string, scope: RemoteSearchScope): string {
    return scope + '|' + query.trim().toLowerCase()
  }

  private cacheSearchResults(query: string, scope: RemoteSearchScope,
    results: FileEntry[], loading: boolean, scrollOffset: number): void {
    const normalized = query.trim()
    if (normalized.length === 0) {
      return
    }
    const key = this.searchResultCacheKey(normalized, scope)
    const next: Record<string, SearchResultSnapshot> = {}
    for (const currentKey of Object.keys(this.searchResultCache)) {
      next[currentKey] = this.searchResultCache[currentKey]
    }
    next[key] = {
      query: normalized,
      scope: scope,
      results: results.slice(),
      loading: loading,
      scrollOffset: Math.max(0, scrollOffset)
    }
    this.searchResultCache = next
  }

  private saveCurrentSearchResultSnapshot(): void {
    if (!this.showSearch || this.searchQuery.trim().length === 0) {
      return
    }
    this.cacheSearchResults(this.searchQuery, this.searchScope, this.searchResults,
      this.searchLoading, this.searchScrollOffset)
  }

  private restoreCachedSearchResults(query: string, scope: RemoteSearchScope): boolean {
    const normalized = query.trim()
    if (normalized.length === 0) {
      return false
    }
    const cached = this.searchResultCache[this.searchResultCacheKey(normalized, scope)]
    if (cached === undefined || cached.loading) {
      return false
    }
    this.searchResults = cached.results.slice()
    this.refreshFileListImageRotations(this.searchResults)
    this.searchLoading = false
    this.searchScrollOffset = Math.max(0, cached.scrollOffset)
    this.errorText = ''
    const offset = this.searchScrollOffset
    setTimeout((): void => {
      if (this.showSearch && this.searchQuery.trim().length > 0 &&
        this.searchScope === scope) {
        this.searchResultScroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false })
      }
    }, 0)
    return true
  }

  private discardSearchSession(): void {
    this.searchGeneration += 1
    if (this.searchTimer > 0) {
      clearTimeout(this.searchTimer)
      this.searchTimer = 0
    }
    this.searchSession = null
    this.searchResultCache = {}
    this.searchScrollOffset = 0
    this.showSearch = false
    this.searchQuery = ''
    this.searchResults = []
    this.searchLoading = false
    this.searchHistoryExpanded = false
    this.resetSearchResultScroll()
    this.updateBottomBarVisibility(true)
  }

  private clearSearchIfPresent(): void {
    if (this.showSearch || this.searchSession !== null) {
      this.discardSearchSession()
    }
  }

  private beginSearchResultReturn(entry: FileEntry, targetParent: string): SearchReturnMode {
    if (this.searchSession === null) {
      this.searchSession = this.createSearchSession()
    }
    this.captureSearchSession()
    const mode: SearchReturnMode = entry.isDirectory
      ? 'directory'
      : (this.isImage(entry) ? 'image' :
        (this.isAudio(entry) ? 'audio' : (this.isVideo(entry) ? 'video' : 'download')))
    this.searchSession.returnMode = mode
    this.searchSession.targetParentPath = targetParent
    this.searchSession.targetNavigationDepth = this.navigationStack.length

    // Invalidate callbacks from the suspended search. The visible result
    // snapshot remains in the session and is restored without a new request.
    this.searchGeneration += 1
    if (this.searchTimer > 0) {
      clearTimeout(this.searchTimer)
      this.searchTimer = 0
    }
    this.searchSession.loading = false
    this.searchLoading = false
    this.showSearch = false
    this.updateBottomBarVisibility(true)
    return mode
  }

  private setSearchReturnDepth(depth: number): void {
    if (this.searchSession !== null) {
      this.searchSession.targetNavigationDepth = depth
    }
  }

  private shouldRestoreSearch(previousPath: string, nextNavigationDepth: number): boolean {
    if (this.searchSession === null || this.searchSession.returnMode !== 'directory') {
      return false
    }
    return this.searchSession.targetParentPath === previousPath &&
      this.searchSession.targetNavigationDepth === nextNavigationDepth
  }

  private restoreSearchSession(): void {
    const session = this.searchSession
    if (session === null) {
      return
    }
    this.navigationStack = session.originNavigationStack.slice()
    this.navigationEntryStack = this.cloneNavigationEntryStack(session.originNavigationEntryStack)
    this.navigationRootTypeStack = session.originNavigationRootTypeStack.slice()
    this.navigationViewStateStack = this.cloneNavigationViewStateStack(
      session.originNavigationViewStateStack)
    this.navigationPageIndexStack = session.originPageIndexStack.slice()
    this.navigationPageHasMoreStack = session.originPageHasMoreStack.slice()
    this.currentPath = session.originPath
    this.currentRootType = session.originRootType
    this.currentPageIndex = session.originPageIndex
    this.currentPageHasMore = session.originPageHasMore
    this.fileViewMode = session.originViewState.mode
    this.replaceEntries(session.originEntries.slice())
    this.resetPreviewState(false)
    this.restoreDirectoryViewState(session.originViewState)
    this.searchQuery = session.query
    this.searchScope = session.scope
    this.searchResults = session.results.slice()
    this.refreshFileListImageRotations(this.searchResults)
    this.searchLoading = session.loading
    this.searchHistoryExpanded = session.historyExpanded
    this.searchScrollOffset = Math.max(0, session.scrollOffset)
    session.returnMode = 'none'
    session.targetParentPath = ''
    session.targetNavigationDepth = this.navigationStack.length
    this.showImageViewer = false
    this.showAudioPlayer = false
    this.isBusy = false
    this.isNavigating = false
    this.errorText = ''
    this.statusText = ''
    this.updateTopTitle(this.fileTitle(this.currentPath), false)
    this.updateBottomBarVisibility(true)
    const offset = this.searchScrollOffset
    setTimeout((): void => {
      if (this.showSearch && this.searchSession !== null) {
        this.searchResultScroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false })
      }
    }, 0)
  }

  private openSearch(): void {
    if (this.screen !== 'files' || this.isBusy || this.showSearch) {
      return
    }
    this.ensureSearchState()
    this.searchGeneration += 1
    if (this.searchTimer > 0) {
      clearTimeout(this.searchTimer)
      this.searchTimer = 0
    }
    this.searchSession = this.createSearchSession()
    this.searchResultCache = {}
    this.searchScrollOffset = 0
    this.showSearch = true
    this.searchQuery = ''
    this.searchScope = 'current'
    this.searchResults = []
    this.resetSearchResultScroll()
    this.searchLoading = false
    this.searchHistoryExpanded = false
    this.errorText = ''
    this.updateBottomBarVisibility(true)
  }

  private closeSearch(): void {
    if (!this.showSearch) {
      return
    }
    this.discardSearchSession()
  }

  private captureDirectoryViewState(): DirectoryViewState {
    return {
      mode: this.fileViewMode,
      offset: this.captureFileViewOffset(this.fileViewMode),
      anchor: this.fileViewMode === 'waterfall' ? this.captureFileViewAnchor() : null
    }
  }

  private restoreDirectoryViewState(state: DirectoryViewState | null): void {
    if (state === null || this.screen !== 'files' || this.showSearch) {
      return
    }
    // A directory can change while its snapshot is suspended. Do not force an
    // invalid WaterFlow mode on a directory that no longer contains images.
    if (state.mode === 'waterfall' && !this.currentDirectoryHasImages) {
      this.fileViewMode = 'list'
      return
    }
    this.fileViewMode = state.mode
    this.waterfallAnchorRestoreToken += 1
    const token = this.waterfallAnchorRestoreToken
    setTimeout((): void => {
      this.restoreFileViewModePosition(state.mode, state.anchor, state.offset, token, 0)
    }, 0)
  }

  private toggleFileViewMode(): void {
    if (this.isBusy || this.showSearch) {
      return
    }
    const sourceMode = this.fileViewMode
    const anchor = this.captureFileViewAnchor()
    const sourceOffset = this.captureFileViewOffset(sourceMode)
    // Ordinary folders still keep the existing list/grid switch. The
    // waterfall mode is only a valid target after an image has appeared in
    // the already-loaded metadata for this directory.
    const nextMode: FileViewMode = this.currentDirectoryHasImages
      ? (this.fileViewMode === 'list'
        ? 'grid' : (this.fileViewMode === 'grid' ? 'waterfall' : 'list'))
      : (this.fileViewMode === 'list' ? 'grid' : 'list')
    if (this.fileViewMode === 'waterfall') {
      this.stopWaterfallPipeline()
    }
    if (nextMode === 'waterfall') {
      this.prepareWaterfallPipeline()
    }
    this.fileViewMode = nextMode
    this.waterfallAnchor = anchor
    this.waterfallAnchorRestoreToken += 1
    const token = this.waterfallAnchorRestoreToken
    setTimeout((): void => {
      this.restoreFileViewModePosition(sourceMode, anchor, sourceOffset, token, 0)
    }, 0)
  }

  private captureFileViewOffset(mode: FileViewMode): ViewerReturnScrollOffset | null {
    try {
      const scroller = mode === 'waterfall' ? this.waterfallScroller : this.fileListScroller
      const offset = scroller.currentOffset()
      if (offset !== undefined && typeof offset.yOffset === 'number') {
        return {
          xOffset: typeof offset.xOffset === 'number' ? offset.xOffset : 0,
          yOffset: offset.yOffset
        }
      }
    } catch (error) {
      console.warn('[UgreenFileView] capture mode offset failed: ' + JSON.stringify(error))
    }
    return null
  }

  private restoreFileViewModePosition(sourceMode: FileViewMode,
    anchor: FileViewAnchor | null, sourceOffset: ViewerReturnScrollOffset | null,
    token: number, attempt: number): void {
    if (token !== this.waterfallAnchorRestoreToken || this.screen !== 'files' ||
      this.showSearch) {
      return
    }

    // WaterFlow has a different item geometry from List/Grid. Use the stable
    // image identity whenever either side of the switch is WaterFlow; the
    // existing WaterFlow retry path handles the first-layout race when it is
    // the target container.
    const needsAnchor = this.fileViewMode === 'waterfall' || sourceMode === 'waterfall'
    if (needsAnchor && anchor !== null) {
      this.restoreFileViewAnchor(anchor, token, 0)
      if (this.fileViewMode === 'waterfall') {
        return
      }
    } else if (sourceOffset !== null) {
      try {
        const scroller = this.fileViewMode === 'waterfall'
          ? this.waterfallScroller : this.fileListScroller
        scroller.scrollTo({
          xOffset: sourceOffset.xOffset,
          yOffset: sourceOffset.yOffset,
          animation: false
        })
      } catch (error) {
        console.warn('[UgreenFileView] restore mode offset failed: ' + JSON.stringify(error))
      }
    }

    // The new List/Grid node can be created one or more frames after the
    // state change. Retry without animation so it settles at the captured
    // position rather than briefly showing the top of the directory.
    if (attempt < 8 && token === this.waterfallAnchorRestoreToken) {
      setTimeout((): void => {
        this.restoreFileViewModePosition(sourceMode, anchor, sourceOffset,
          token, attempt + 1)
      }, 48)
    }
  }

  private captureFileViewAnchor(): FileViewAnchor | null {
    let items: FileEntry[] = this.entries
    let first = this.fileVisibleStartIndex
    let last = this.fileVisibleEndIndex
    let childIndexOffset = this.fileViewMode === 'list' ? 1 : 0
    let scroller = this.fileListScroller
    if (this.fileViewMode === 'waterfall') {
      items = this.waterfallEntries
      first = this.waterfallVisibleStartIndex
      last = this.waterfallVisibleEndIndex
      childIndexOffset = 0
      scroller = this.waterfallScroller
    } else if (this.fileViewMode === 'list') {
      // The list has a leading safe-area spacer as child 0. Its scroll
      // callback reports the container child index, while entries is indexed
      // from the first real file. Normalize both ends before finding the
      // first visible image so list -> waterfall never falls back to index 0.
      first = Math.max(0, first - 1)
      last = Math.max(0, last - 1)
    }
    if (items.length === 0) {
      return null
    }
    first = Math.max(0, Math.min(first, items.length - 1))
    last = Math.max(first, Math.min(last, items.length - 1))
    let anchorIndex = -1
    for (let index = first; index <= last; index++) {
      if (this.isImage(items[index])) {
        anchorIndex = index
        break
      }
    }
    if (anchorIndex < 0) {
      for (let index = first; index < items.length; index++) {
        if (this.isImage(items[index])) {
          anchorIndex = index
          break
        }
      }
    }
    if (anchorIndex < 0) {
      return null
    }
    const entry = items[anchorIndex]
    let y = 0
    try {
      const rect = scroller.getItemRect(anchorIndex + childIndexOffset)
      if (rect !== undefined && typeof rect.y === 'number') {
        y = rect.y
      }
    } catch (_) {
      // The item may not be mounted during a mode change. Index anchoring is
      // still sufficient and is handled by restoreFileViewAnchor.
    }
    return { path: entry.path, y: y }
  }

  private restoreFileViewAnchor(anchor: FileViewAnchor | null, token: number,
    attempt: number = 0): void {
    if (token !== this.waterfallAnchorRestoreToken || anchor === null ||
      this.screen !== 'files' || this.showSearch) {
      return
    }
    let items: FileEntry[] = this.entries
    let scroller = this.fileListScroller
    let childIndexOffset = this.fileViewMode === 'list' ? 1 : 0
    if (this.fileViewMode === 'waterfall') {
      items = this.waterfallEntries
      scroller = this.waterfallScroller
      childIndexOffset = 0
    }
    const targetIndex = items.findIndex((entry: FileEntry): boolean => entry.path === anchor.path)
    if (targetIndex < 0) {
      return
    }
    // WaterFlow with SLIDING_WINDOW may not have completed its first layout
    // pass when the mode state changes. Retry the same indexed jump for a
    // short bounded window; without this, the early scrollToIndex is ignored
    // and the container stays at its first image.
    const isWaterfall = this.fileViewMode === 'waterfall'
    const maxRestoreAttempts = isWaterfall ? 8 : 0
    try {
      scroller.scrollToIndex(targetIndex + childIndexOffset, false, ScrollAlign.START, {
        extraOffset: LengthMetrics.vp(Math.max(-120, Math.min(160, anchor.y)))
      })
    } catch (error) {
      console.warn('[UgreenFileView] anchor restore failed: ' + JSON.stringify(error))
      try {
        scroller.scrollToIndex(targetIndex + childIndexOffset, false, ScrollAlign.START)
      } catch (_) {
        // The target container may not have completed its first layout pass.
      }
    }
    if (isWaterfall && attempt < maxRestoreAttempts &&
      token === this.waterfallAnchorRestoreToken) {
      setTimeout((): void => {
        this.restoreFileViewAnchor(anchor, token, attempt + 1)
      }, 48)
    }
    this.waterfallAnchor = null
  }

  private prepareWaterfallPipeline(): void {
    this.waterfallGeneration += 1
    this.waterfallDownloadQueue = []
    this.waterfallDecodeQueue = []
    this.waterfallDownloadRequests = {}
    this.waterfallActiveDownloadPaths = {}
    this.waterfallActiveDecodePaths = {}
    this.waterfallDecodedPaths = {}
    this.waterfallActiveDownloads = 0
    this.waterfallActiveDecodes = 0
    this.waterfallOriginalUris = {}
    this.waterfallVisiblePaths = {}
  }

  private stopWaterfallPipeline(): void {
    // A generation change makes in-flight HTTP work self-cancel through its
    // continuation callback. Completed originals remain in the normal cache.
    this.waterfallGeneration += 1
    this.waterfallDownloadQueue = []
    this.waterfallDecodeQueue = []
    this.waterfallDownloadRequests = {}
    this.waterfallActiveDownloadPaths = {}
    this.waterfallActiveDecodePaths = {}
    this.waterfallDecodedPaths = {}
    this.waterfallActiveDownloads = 0
    this.waterfallActiveDecodes = 0
    this.waterfallOriginalUris = {}
    this.waterfallVisiblePaths = {}
    const bitmaps = this.waterfallBitmaps
    this.waterfallBitmaps = {}
    this.bumpViewerBitmapEpoch()
    for (const key of Object.keys(bitmaps)) {
      if (this.viewerPreviewBitmapAliases[key] === true &&
        this.viewerPreviewBitmaps[key] === bitmaps[key]) {
        this.viewerPreviewBitmapAliases[key] = false
        continue
      }
      this.viewerBitmapStore.release(bitmaps[key]).catch((): void => {})
    }
  }

  private waterfallUri(entry: FileEntry): string {
    if (this.waterfallVisiblePaths[entry.path] !== true) {
      return ''
    }
    const uri = this.waterfallOriginalUris[entry.path]
    return typeof uri === 'string' ? uri : ''
  }

  private waterfallAspectRatio(entry: FileEntry): number {
    const value = this.waterfallAspectRatios[entry.path]
    // This cache contains the final Image Kit raster ratio after EXIF and the
    // persisted user rotation. WaterFlow must measure the same axes that the
    // Image node renders.
    if (typeof value === 'number' && value > 0) {
      return value
    }
    const state = this.imageVisualState(entry.path)
    if (state.displayWidth > 0 && state.displayHeight > 0) {
      return state.displayWidth / state.displayHeight
    }
    return 1
  }

  private waterfallSourceSize(entry: FileEntry): ThumbnailSize {
    const columnVp = this.waterfallColumnWidthVp > 0 ? this.waterfallColumnWidthVp : 160
    const ratio = this.waterfallAspectRatio(entry)
    let width = Math.max(1, Math.round(vp2px(columnVp)))
    let height = Math.max(1, Math.round(width / ratio))
    // 只按列宽缩放，不要再用最长边 1024 截断：竖图会被压到比列宽还小，
    // 显示时再被放大，看起来就是压缩图（ThumbnailPolicy 里 viewerZoom 的
    // 注释记录过同一个坑）。改用像素预算兜底极端长图。
    const pixels = width * height
    if (pixels > ThumbnailPolicy.WATERFALL_MAX_PIXELS) {
      const scale = Math.sqrt(ThumbnailPolicy.WATERFALL_MAX_PIXELS / pixels)
      width = Math.max(1, Math.round(width * scale))
      height = Math.max(1, Math.round(height * scale))
    }
    return { width: width, height: height }
  }

  private markWaterfallVisible(entry: FileEntry, visible: boolean): void {
    // Opening the viewer temporarily removes the WaterFlow subtree. Keep an
    // already-rendered local source alive while that subtree is away so the
    // file surface can return exactly as it was. Keep the visibility marker
    // even when this particular item had not finished decoding; otherwise the
    // next onAppear starts a fresh waterfall request and causes a visible
    // reload after returning from the viewer.
    const retainedForViewer = !visible &&
      (this.showImageViewer || this.viewerEntryTransitionActive || this.viewerClosePending)
    const nextVisible: Record<string, boolean> = {}
    for (const key of Object.keys(this.waterfallVisiblePaths)) {
      nextVisible[key] = this.waterfallVisiblePaths[key]
    }
    nextVisible[entry.path] = retainedForViewer ? true : visible
    this.waterfallVisiblePaths = nextVisible
    if (retainedForViewer) {
      // Do not enqueue a new decode while WaterFlow is hidden. Existing
      // downloads continue under the same generation; onAppear will only
      // decode a local source that still needs a render pass.
      return
    }
    if (!visible && !retainedForViewer) {
      this.releaseViewerBitmap(this.waterfallBitmaps, entry.path).catch((): void => {})
      const nextUris: Record<string, string> = {}
      for (const key of Object.keys(this.waterfallOriginalUris)) {
        if (key !== entry.path) {
          nextUris[key] = this.waterfallOriginalUris[key]
        }
      }
      this.waterfallOriginalUris = nextUris
      this.waterfallDecodedPaths[entry.path] = false
      if (this.waterfallActiveDecodePaths[entry.path] === true) {
        this.waterfallActiveDecodePaths[entry.path] = false
        this.waterfallActiveDecodes = Math.max(0, this.waterfallActiveDecodes - 1)
      }
      this.waterfallDecodeQueue = this.waterfallDecodeQueue.filter(
        (item: FileEntry): boolean => item.path !== entry.path)
      this.drainWaterfallDecodes()
      return
    }
    this.enqueueWaterfallDecode(entry)
  }

  private setWaterfallOriginalUri(path: string, uri: string): void {
    const next: Record<string, string> = {}
    for (const key of Object.keys(this.waterfallOriginalUris)) {
      if (key !== path) {
        next[key] = this.waterfallOriginalUris[key]
      }
    }
    if (uri.length > 0) {
      next[path] = uri
    }
    this.waterfallOriginalUris = next
    this.updateImageVisualState(path, (state: ImageVisualState): void => {
      state.thumbnailDecodedUri = ''
      if (uri.length > 0) {
        state.transitionThumbnailUri = uri
      }
    })
  }

  private setWaterfallAspectRatio(path: string, width: number, height: number): void {
    if (path.length === 0 || width <= 0 || height <= 0) {
      return
    }
    const next: Record<string, number> = {}
    for (const key of Object.keys(this.waterfallAspectRatios)) {
      next[key] = this.waterfallAspectRatios[key]
    }
    next[path] = width / height
    this.waterfallAspectRatios = next
  }

  private enqueueWaterfallOriginal(entry: FileEntry, _index: number = 0,
    priority: boolean = true): void {
    if (this.fileViewMode !== 'waterfall' || !this.isImage(entry)) {
      return
    }
    const localPath = this.waterfallLocalPaths[entry.path]
    if (typeof localPath === 'string' && localPath.length > 0) {
      this.enqueueWaterfallDecode(entry)
      return
    }
    if (this.waterfallDownloadRequests[entry.path] === true) {
      return
    }
    this.waterfallDownloadRequests[entry.path] = true
    if (priority) {
      this.waterfallDownloadQueue.unshift(entry)
    } else {
      this.waterfallDownloadQueue.push(entry)
    }
    this.drainWaterfallDownloads()
  }

  private prefetchWaterfallRange(first: number, last: number): void {
    if (this.fileViewMode !== 'waterfall' || this.waterfallEntries.length === 0) {
      return
    }
    const start = Math.max(0, first)
    const end = Math.min(this.waterfallEntries.length - 1, Math.max(start, last) + 4)
    for (let index = start; index <= end; index++) {
      this.enqueueWaterfallOriginal(this.waterfallEntries[index], index, index <= last)
    }
  }

  private drainWaterfallDownloads(): void {
    while (this.fileViewMode === 'waterfall' && this.waterfallActiveDownloads < 4 &&
      this.waterfallDownloadQueue.length > 0) {
      const entry = this.waterfallDownloadQueue.shift() as FileEntry
      if (this.waterfallDownloadRequests[entry.path] !== true) {
        continue
      }
      const generation = this.waterfallGeneration
      this.waterfallActiveDownloads += 1
      this.waterfallActiveDownloadPaths[entry.path] = true
      this.loadWaterfallOriginal(entry, generation)
    }
  }

  private enqueueWaterfallDecode(entry: FileEntry): void {
    if (this.fileViewMode !== 'waterfall' || this.waterfallVisiblePaths[entry.path] !== true ||
      this.waterfallDecodedPaths[entry.path] === true ||
      this.waterfallActiveDecodePaths[entry.path] === true) {
      return
    }
    if (this.waterfallDecodeQueue.some((item: FileEntry): boolean => item.path === entry.path)) {
      return
    }
    this.waterfallDecodeQueue.push(entry)
    this.drainWaterfallDecodes()
  }

  private drainWaterfallDecodes(): void {
    while (this.fileViewMode === 'waterfall' && this.waterfallActiveDecodes < 2 &&
      this.waterfallDecodeQueue.length > 0) {
      const entry = this.waterfallDecodeQueue.shift() as FileEntry
      if (this.waterfallVisiblePaths[entry.path] !== true ||
        this.waterfallLocalPaths[entry.path] === undefined ||
        this.waterfallDecodedPaths[entry.path] === true) {
        continue
      }
      const localPath = this.waterfallLocalPaths[entry.path]
      this.waterfallActiveDecodes += 1
      this.waterfallActiveDecodePaths[entry.path] = true
      this.decodeWaterfallBitmap(entry, localPath, this.waterfallGeneration)
    }
  }

  private async decodeWaterfallBitmap(entry: FileEntry, localPath: string,
    generation: number): Promise<void> {
    try {
      const rotation = this.imageVisualState(entry.path).userRotation
      const record = await this.viewerBitmapStore.decode(localPath, 'viewerPreview', rotation,
        this.waterfallSourceSize(entry))
      if (record === null || generation !== this.waterfallGeneration ||
        this.fileViewMode !== 'waterfall' || this.waterfallVisiblePaths[entry.path] !== true ||
        this.imageVisualState(entry.path).userRotation !== rotation) {
        if (record !== null) {
          await this.viewerBitmapStore.release(record)
        }
        return
      }
      this.installViewerBitmap(this.waterfallBitmaps, entry.path, record)
      this.applyDecodedBitmapGeometry(entry.path, record, false)
      this.setWaterfallAspectRatio(entry.path, record.displayWidth, record.displayHeight)
      this.setWaterfallOriginalUri(entry.path, fileUri.getUriFromPath(localPath))
      this.waterfallDecodedPaths[entry.path] = true
    } catch (error) {
      console.warn('[UgreenWaterfall] PixelMap decode failed: ' + entry.path + ': ' +
        JSON.stringify(error))
      this.waterfallDecodedPaths[entry.path] = false
      this.setWaterfallOriginalUri(entry.path, '')
    } finally {
      if (generation === this.waterfallGeneration) {
        this.waterfallActiveDecodePaths[entry.path] = false
        this.waterfallActiveDecodes = Math.max(0, this.waterfallActiveDecodes - 1)
        this.drainWaterfallDecodes()
      }
    }
  }

  private completeWaterfallDecode(entry: FileEntry): void {
    if (this.waterfallActiveDecodePaths[entry.path] !== true) {
      return
    }
    this.waterfallActiveDecodePaths[entry.path] = false
    this.waterfallDecodedPaths[entry.path] = true
    this.waterfallActiveDecodes = Math.max(0, this.waterfallActiveDecodes - 1)
    this.drainWaterfallDecodes()
  }

  private failWaterfallDecode(entry: FileEntry): void {
    if (this.waterfallActiveDecodePaths[entry.path] === true) {
      this.waterfallActiveDecodePaths[entry.path] = false
      this.waterfallActiveDecodes = Math.max(0, this.waterfallActiveDecodes - 1)
    }
    this.waterfallDecodedPaths[entry.path] = false
    this.releaseViewerBitmap(this.waterfallBitmaps, entry.path).catch((): void => {})
    this.setWaterfallOriginalUri(entry.path, '')
    this.drainWaterfallDecodes()
  }

  private async loadWaterfallOriginal(entry: FileEntry, generation: number): Promise<void> {
    try {
      await this.ensureCacheState()
      if (generation !== this.waterfallGeneration || this.fileViewMode !== 'waterfall') {
        return
      }
      const existingPath = CacheManager.findExisting(this.cacheDirectory, entry.name,
        this.originalCacheKey(entry))
      let localPath = existingPath
      if (localPath.length === 0) {
        if (!this.shouldAutoLoadViewerOriginal()) {
          return
        }
        const continueDownload = (): boolean => generation === this.waterfallGeneration &&
          this.fileViewMode === 'waterfall' && this.shouldAutoLoadViewerOriginal()
        localPath = await this.ensureCachedFile(entry, undefined, continueDownload)
      }
      if (localPath.length === 0 || generation !== this.waterfallGeneration ||
        this.fileViewMode !== 'waterfall') {
        return
      }
      this.waterfallLocalPaths[entry.path] = localPath
      const geometry = await this.readViewerImageGeometry(localPath, entry.path)
      if (geometry !== null && generation === this.waterfallGeneration) {
        this.setWaterfallAspectRatio(entry.path, geometry.displayWidth, geometry.displayHeight)
      }
      if (this.waterfallVisiblePaths[entry.path] === true) {
        this.enqueueWaterfallDecode(entry)
      }
    } catch (error) {
      if (generation === this.waterfallGeneration && this.fileViewMode === 'waterfall') {
        console.warn('[UgreenWaterfall] original load failed: ' + entry.path + ': ' +
          JSON.stringify(error))
      }
    } finally {
      if (generation === this.waterfallGeneration) {
        this.waterfallActiveDownloads = Math.max(0, this.waterfallActiveDownloads - 1)
        this.waterfallActiveDownloadPaths[entry.path] = false
        this.waterfallDownloadRequests[entry.path] = false
        this.drainWaterfallDownloads()
      }
    }
  }

  private setSearchScope(scope: RemoteSearchScope): void {
    if (this.searchScope === scope) {
      return
    }
    this.saveCurrentSearchResultSnapshot()
    this.searchGeneration += 1
    if (this.searchTimer > 0) {
      clearTimeout(this.searchTimer)
      this.searchTimer = 0
    }
    this.searchScope = scope
    if (this.searchQuery.trim().length > 0) {
      if (!this.restoreCachedSearchResults(this.searchQuery, scope)) {
        this.performSearch(this.searchQuery, false)
      }
    }
  }

  private scheduleSearch(value: string): void {
    this.saveCurrentSearchResultSnapshot()
    this.searchGeneration += 1
    this.searchQuery = value
    if (this.searchTimer > 0) {
      clearTimeout(this.searchTimer)
      this.searchTimer = 0
    }
    const normalized = value.trim()
    if (normalized.length === 0) {
      this.searchResults = []
      this.resetSearchResultScroll()
      this.searchLoading = false
      return
    }
    if (!this.restoreCachedSearchResults(normalized, this.searchScope)) {
      this.searchResults = []
      this.resetSearchResultScroll()
      this.searchLoading = true
    }
    this.searchTimer = setTimeout((): void => {
      this.searchTimer = 0
      this.performSearch(normalized, false)
    }, 280)
  }

  private submitSearch(value: string): void {
    this.saveCurrentSearchResultSnapshot()
    this.searchGeneration += 1
    if (this.searchTimer > 0) {
      clearTimeout(this.searchTimer)
      this.searchTimer = 0
    }
    const normalized = value.trim()
    this.searchQuery = value
    if (normalized.length === 0) {
      return
    }
    this.addSearchHistory(normalized)
    if (!this.restoreCachedSearchResults(normalized, this.searchScope)) {
      this.performSearch(normalized, false)
    }
  }

  private async performSearch(value: string, recordHistory: boolean): Promise<void> {
    const normalized = value.trim()
    if (normalized.length === 0 || !this.showSearch) {
      return
    }
    if (recordHistory) {
      this.addSearchHistory(normalized)
    }
    this.searchGeneration += 1
    const generation = this.searchGeneration
    const searchPath = this.currentPath
    const searchRootType = this.currentRootType
    const searchScope = this.searchScope
    if (this.restoreCachedSearchResults(normalized, searchScope)) {
      return
    }
    this.searchLoading = true
    this.searchResults = []
    this.resetSearchResultScroll()
    this.cacheSearchResults(normalized, searchScope, [], true, 0)
    this.errorText = ''
    try {
      const results = await this.repository.search(searchPath, searchRootType, normalized, searchScope,
        (batch: FileEntry[]): void => {
          if (generation !== this.searchGeneration || !this.showSearch) {
            return
          }
          this.appendSearchResults(batch)
        })
      if (generation === this.searchGeneration && this.showSearch) {
        this.searchResults = results
        this.refreshFileListImageRotations(this.searchResults)
        this.cacheSearchResults(normalized, searchScope, results, false, this.searchScrollOffset)
      }
    } catch (error) {
      if (generation === this.searchGeneration && this.showSearch) {
        this.reportError(error as Object, '搜索失败')
      }
    } finally {
      if (generation === this.searchGeneration && this.showSearch) {
        this.searchLoading = false
        this.cacheSearchResults(normalized, searchScope, this.searchResults, false, this.searchScrollOffset)
      }
    }
  }

  private appendSearchResults(batch: FileEntry[]): void {
    const next = this.searchResults.slice()
    for (const entry of batch) {
      let exists = false
      for (const current of next) {
        if (current.path === entry.path) {
          exists = true
          break
        }
      }
      if (!exists) {
        next.push(entry)
      }
    }
    this.searchResults = next
    this.refreshFileListImageRotations(next)
    this.cacheSearchResults(this.searchQuery, this.searchScope, next, this.searchLoading, this.searchScrollOffset)
  }

  private resetSearchResultScroll(): void {
    // ArkUI reuses the result List while the query/scope changes. Reset its
    // retained offset so the first result always begins below the transparent
    // scope controls instead of being clipped at the List viewport boundary.
    this.searchScrollOffset = 0
    setTimeout((): void => {
      this.searchResultScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false })
    }, 0)
  }

  private async addSearchHistory(keyword: string): Promise<void> {
    const normalized = keyword.trim()
    if (normalized.length === 0) {
      return
    }
    await this.ensureSearchState()
    const next: string[] = [normalized]
    for (const item of this.searchHistory) {
      if (item.toLowerCase() !== normalized.toLowerCase() && next.length < 8) {
        next.push(item)
      }
    }
    this.searchHistory = next
    try {
      if (this.searchPreferences !== null) {
        await this.searchPreferences.put('search_history', next)
        await this.searchPreferences.flush()
      }
    } catch (_) {
      // The in-memory history remains usable if persistence is unavailable.
    }
  }

  private async clearSearchHistory(): Promise<void> {
    this.searchHistory = []
    try {
      await this.ensureSearchState()
      if (this.searchPreferences !== null) {
        await this.searchPreferences.put('search_history', [])
        await this.searchPreferences.flush()
      }
    } catch (_) {
      // Clearing the visible history is still successful when persistence fails.
    }
  }

  private parentPath(path: string): string {
    const normalized = path.trim().replace(/\/+$/, '')
    const separator = normalized.lastIndexOf('/')
    if (separator <= 0) {
      return ''
    }
    return normalized.substring(0, separator)
  }

  private async openSearchResult(entry: FileEntry): Promise<void> {
    if (this.isBusy) {
      return
    }
    const targetParent = this.parentPath(entry.path)
    const returnMode = this.beginSearchResultReturn(entry, targetParent)
    if (targetParent === this.currentPath) {
      await this.openEntry(entry)
      if (returnMode === 'download' ||
        (returnMode === 'image' && !this.showImageViewer) ||
        (returnMode === 'audio' && !this.showAudioPlayer) ||
        (returnMode === 'video' && !this.showVideoPlayer)) {
        this.restoreSearchSession()
      }
      return
    }

    const outgoingEntries = this.entries.slice()
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在定位文件…'
    try {
      const targetRootType = targetParent.length > 0 ? 3 :
        (this.rootKind === 'personal' ? 4 : 3)
      const targetEntries = await this.repository.list(targetParent, targetRootType)
      this.navigationStack = []
      this.navigationEntryStack = []
      this.navigationRootTypeStack = []
      this.navigationViewStateStack = []
      this.navigationPageIndexStack = []
      this.navigationPageHasMoreStack = []
      this.setSearchReturnDepth(0)
      this.currentPath = targetParent
      this.currentRootType = targetRootType
      this.setCurrentPageState(1, false)
      this.replaceEntries(targetEntries)
      this.updateTopTitle(this.fileTitle(targetParent), true)
      this.updateBottomBarVisibility(true)
      this.updateDirectoryCount(targetParent, targetEntries.length)
      this.resetPreviewState()
      this.startFileTransition(outgoingEntries, 'push')
      const located = targetEntries.find((item: FileEntry) => item.path === entry.path)
      this.isBusy = false
      if (located !== undefined) {
        await this.openEntry(located)
        if (returnMode === 'download' ||
          (returnMode === 'image' && !this.showImageViewer) ||
          (returnMode === 'audio' && !this.showAudioPlayer) ||
          (returnMode === 'video' && !this.showVideoPlayer)) {
          this.restoreSearchSession()
        }
      } else {
        this.restoreSearchSession()
      }
    } catch (error) {
      this.reportError(error as Object, '定位失败')
      this.statusText = '定位失败'
      this.isBusy = false
      this.restoreSearchSession()
    }
  }

  private async toggleAutoLogin(): Promise<void> {
    if (this.isBusy) {
      return
    }
    this.autoLogin = !this.autoLogin
    if (this.autoLogin) {
      this.rememberPassword = true
    }
    await this.persistLoginPreferences()
  }

  private async toggleRememberPassword(): Promise<void> {
    if (this.isBusy) {
      return
    }
    this.rememberPassword = !this.rememberPassword
    if (!this.rememberPassword) {
      this.autoLogin = false
    }
    await this.persistLoginPreferences()
  }

  private openSettings(): void {
    if (this.isBusy) {
      return
    }
    this.clearSearchIfPresent()
    this.showStorageSettings = false
    this.showNetworkSettings = false
    this.showPlaybackSettings = false
    this.errorText = ''
    // statusText 是全局的操作状态文案：文件页浏览时会写入“个人目录”“正在读取目录…”
    // 等消息，而设置页的二级页面底部也渲染它。进入设置页时先清空，避免这些
    // 文件页文案串到设置页里。
    this.statusText = ''
    this.selectedBottomTab = 'settings'
    this.screen = 'settings'
    this.updateTopTitle('设置', true)
    this.updateBottomBarVisibility(true)
  }

  private openStorageSettings(): void {
    if (this.isBusy || this.screen !== 'settings') {
      return
    }
    this.showStorageSettings = true
    this.showNetworkSettings = false
    this.showPlaybackSettings = false
    this.ensureCacheState()
    this.errorText = ''
    this.updateTopTitle('缓存与存储', true)
    this.updateBottomBarVisibility(true)
  }

  private openPlaybackSettings(): void {
    if (this.isBusy || this.screen !== 'settings') {
      return
    }
    this.showStorageSettings = false
    this.showPlaybackSettings = true
    this.showNetworkSettings = false
    this.ensurePlaybackState()
    this.errorText = ''
    this.updateTopTitle('播放与控制', true)
    this.updateBottomBarVisibility(true)
  }

  private closeStorageSettings(): void {
    if (this.screen !== 'settings' || !this.showStorageSettings) {
      return
    }
    this.showStorageSettings = false
    this.showNetworkSettings = false
    this.showPlaybackSettings = false
    this.errorText = ''
    this.updateTopTitle('设置', true)
    this.updateBottomBarVisibility(true)
  }

  private closePlaybackSettings(): void {
    if (this.screen !== 'settings' || !this.showPlaybackSettings) {
      return
    }
    this.showPlaybackSettings = false
    this.showStorageSettings = false
    this.showNetworkSettings = false
    this.errorText = ''
    this.updateTopTitle('设置', true)
    this.updateBottomBarVisibility(true)
  }

  private openNetworkSettings(): void {
    if (this.isBusy || this.screen !== 'settings') {
      return
    }
    this.showStorageSettings = false
    this.showNetworkSettings = true
    this.showPlaybackSettings = false
    this.ensureNetworkState()
    this.errorText = ''
    this.updateTopTitle('网络与流量', true)
    this.updateBottomBarVisibility(true)
  }

  private closeNetworkSettings(): void {
    if (this.screen !== 'settings' || !this.showNetworkSettings) {
      return
    }
    this.showNetworkSettings = false
    this.showStorageSettings = false
    this.showPlaybackSettings = false
    this.errorText = ''
    this.updateTopTitle('设置', true)
    this.updateBottomBarVisibility(true)
  }

  private openHome(): void {
    // Directory reads and the short page transition are safe to cancel when
    // the user explicitly taps Home. Keep destructive/storage operations
    // protected by isBusy.
    if (this.isBusy && !this.isNavigating && !this.showPageTransition) {
      return
    }
    this.navigationRequestId += 1
    this.isNavigating = false
    this.cancelFileTransition()
    this.isBusy = false
    this.clearSearchIfPresent()
    this.closeActionMenu()
    this.showStorageSettings = false
    this.showPlaybackSettings = false
    this.showNetworkSettings = false
    this.selectedBottomTab = 'home'
    this.screen = 'files'
    this.showRoot('personal')
    // The Home tab is the user's personal landing directory, matching the
    // post-login default (/home/<username>), not the intermediate /home list.
    this.openDefaultPersonalDirectory()
  }

  private openShared(): void {
    if (this.isBusy) {
      return
    }
    this.clearSearchIfPresent()
    this.closeActionMenu()
    this.showStorageSettings = false
    this.showPlaybackSettings = false
    this.showNetworkSettings = false
    this.selectedBottomTab = 'shared'
    this.screen = 'files'
    this.showRoot('shared')
  }

  private openDownloads(): void {
    if (this.isBusy && !this.isNavigating && !this.showPageTransition) {
      return
    }
    this.navigationRequestId += 1
    this.isNavigating = false
    this.cancelFileTransition()
    this.isBusy = false
    this.clearSearchIfPresent()
    this.closeActionMenu()
    this.showStorageSettings = false
    this.showPlaybackSettings = false
    this.showNetworkSettings = false
    this.selectionMode = false
    this.selectedPaths = []
    this.selectedEntryCount = 0
    this.selectedBottomTab = 'downloads'
    this.screen = 'downloads'
    this.importExpanded = false
    this.updateTopTitle('传输', false)
    this.updateBottomBarVisibility(true)
    this.ensureDownloadState()
    this.ensureVideoState()
  }

  private async setCacheLimit(value: number): Promise<void> {
    if (this.isBusy) {
      return
    }
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在调整缓存…'
    try {
      await this.ensureCacheState()
      StorageBudget.setLimit(value)
      this.cacheLimitBytes = value
      if (this.cachePreferences !== null) {
        await this.cachePreferences.put('cache_limit_bytes', value)
        await this.cachePreferences.flush()
      }
      await this.repository.enforceThumbnailCacheLimit(this.thumbnailCacheLimitBytes)
      await this.ensureVideoState()
      const videoContext = getContext(this) as Context
      await this.videoTransferManager.initialize(videoContext, this.repository,
        this.cacheDirectory, value)
      await this.refreshCacheUsage()
      this.statusText = '缓存上限已设置为 ' + this.formatStorageSize(value)
    } catch (error) {
      this.reportError(error as Object, '缓存设置失败')
      this.statusText = '缓存设置失败'
    } finally {
      this.isBusy = false
    }
  }

  private async clearCache(): Promise<void> {
    if (this.isBusy) {
      return
    }
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在清理缓存…'
    try {
      await this.ensureCacheState()
      StorageBudget.clearDisposable()
      await this.refreshCacheUsage()
      this.statusText = '缓存已清理'
      this.showImmersiveToast('缓存已清理')
    } catch (error) {
      this.reportError(error as Object, '缓存清理失败')
      this.statusText = '缓存清理失败'
    } finally {
      this.isBusy = false
    }
  }

  private async handleResolve(): Promise<void> {
    if (this.isBusy) {
      return
    }
    this.errorText = ''
    this.isBusy = true
    this.statusText = '正在解析云盘地址…'
    try {
      this.baseUrl = await this.repository.resolve(this.linkId)
      this.statusText = '解析成功，可以继续登录'
    } catch (error) {
      this.reportError(error as Object, '解析失败')
      this.statusText = '解析失败'
    } finally {
      this.isBusy = false
    }
  }

  private async handleLogin(silent: boolean = false): Promise<void> {
    if (this.isBusy) {
      return
    }
    this.errorText = ''
    this.isBusy = true
    if (!silent) {
      this.statusText = '正在解析云盘地址…'
    }
    await this.persistLoginPreferences()
    try {
      this.baseUrl = await this.repository.resolve(this.linkId)
      if (!silent) {
        this.statusText = '解析成功，正在登录…'
      }
      const result = await this.repository.login(this.username, this.password)
      if (result.requiresOtp) {
        this.screen = 'otp'
        this.statusText = silent ? '' : result.message
        if (silent) {
          this.presentErrorMessage(result.message, '需要安全验证')
        }
        return
      }
      await this.loadRoot()
      await this.refreshVideoManager()
      await this.ensureDownloadState()
      await this.downloadQueue.setReady(true)
      await this.uploadQueue.setReady(true)
      this.screen = 'files'
      this.updateBottomBarVisibility(false)
      this.statusText = silent ? '' : '登录成功'
    } catch (error) {
      if (silent) {
        this.screen = 'login'
      }
      this.reportError(error as Object, silent ? '自动登录失败' : '登录失败')
      this.statusText = ''
    } finally {
      this.isBusy = false
    }
  }

  private async handleOtp(): Promise<void> {
    if (this.isBusy) {
      return
    }
    this.errorText = ''
    this.isBusy = true
    this.statusText = '正在验证验证码…'
    try {
      const result = await this.repository.verifyOtp(this.otpCode, this.trustDevice)
      await this.loadRoot()
      await this.refreshVideoManager()
      await this.ensureDownloadState()
      await this.downloadQueue.setReady(true)
      await this.uploadQueue.setReady(true)
      this.screen = 'files'
      this.updateBottomBarVisibility(false)
      this.statusText = result.message
    } catch (error) {
      this.reportError(error as Object, '验证码验证失败')
      this.statusText = '验证码验证失败'
    } finally {
      this.isBusy = false
    }
  }

  private setCurrentPageState(pageIndex: number, hasMore: boolean): void {
    this.currentPageIndex = Math.max(1, pageIndex)
    this.currentPageHasMore = hasMore
    this.loadingNextPage = false
  }

  private async loadNextDirectoryPage(): Promise<void> {
    if (this.loadingNextPage || !this.currentPageHasMore || this.currentPath.length === 0 ||
      this.isBusy || this.isNavigating || this.showSearch ||
      this.showAudioPlayer || this.screen !== 'files') {
      return
    }
    const path = this.currentPath
    const rootType = this.currentRootType
    const nextPageIndex = this.currentPageIndex + 1
    const requestId = this.navigationRequestId
    this.loadingNextPage = true
    try {
      const page = await this.repository.listPage(path, rootType, nextPageIndex)
      if (requestId !== this.navigationRequestId || path !== this.currentPath ||
        rootType !== this.currentRootType) {
        return
      }
      this.appendEntries(page.entries)
      if (this.showImageViewer) {
        this.appendViewerImages(this.imageEntriesInCurrentDirectory())
      }
      this.currentPageIndex = page.pageIndex
      this.currentPageHasMore = page.hasMore && page.entries.length > 0
      if (page.totalCount >= 0) {
        this.updateDirectoryCount(path, page.totalCount)
      } else {
        this.updateDirectoryCount(path, this.entries.length)
      }
    } catch (_) {
      // Paging is incremental. Keep the already visible page usable when the
      // next request fails; a later reach-end event can retry it.
    } finally {
      this.loadingNextPage = false
    }
  }

  private async loadRoot(): Promise<void> {
    this.navigationRequestId += 1
    this.isNavigating = false
    const root = await this.repository.getRoot()
    this.directoryCounts = {}
    this.directoryCountRequests = {}
    this.personalRoots = root.personal
    this.sharedRoots = root.shared
    this.rootKind = 'personal'
    this.selectedBottomTab = 'home'
    this.currentRootType = 4
    this.currentPath = ''
    this.updateTopTitle('个人空间', false)
    this.navigationStack = []
    this.navigationEntryStack = []
    this.navigationRootTypeStack = []
    this.navigationViewStateStack = []
    this.navigationPageIndexStack = []
    this.navigationPageHasMoreStack = []
    this.setCurrentPageState(1, false)
    this.replaceEntries(this.personalRoots)
    this.resetPreviewState()

    // 管理员/用户自己的目录作为登录后的默认落点；找不到匹配目录时保留根目录。
    const defaultDirectory = this.findDefaultPersonalDirectory()
    if (defaultDirectory !== null) {
      const personalPath = defaultDirectory.path.length > 0
        ? defaultDirectory.path
        : '/' + defaultDirectory.name
      try {
        const personalPage = await this.repository.listPage(personalPath, 3, 1)
        this.navigationStack = ['']
        this.navigationEntryStack = []
        this.navigationRootTypeStack = []
        this.navigationViewStateStack = []
        this.navigationPageIndexStack = []
        this.navigationPageHasMoreStack = []
        this.currentPath = personalPath
        this.currentRootType = 3
        this.setCurrentPageState(personalPage.pageIndex, personalPage.hasMore)
        this.replaceEntries(personalPage.entries)
        this.updateTopTitle(this.fileTitle(personalPath), false)
        this.updateDirectoryCount(personalPath, personalPage.totalCount >= 0
          ? personalPage.totalCount : personalPage.entries.length)
        this.resetPreviewState()
        this.statusText = '个人目录'
      } catch (_) {
        // 个人目录暂时不可读时仍停留在可用的个人根目录。
      }
    }
  }

  private findDefaultPersonalDirectory(): FileEntry | null {
    const accountName = this.username.trim().toLowerCase()
    if (accountName.length > 0) {
      for (const entry of this.personalRoots) {
        if (entry.isDirectory && entry.name.trim().toLowerCase() === accountName) {
          return entry
        }
      }
    }
    if (this.personalRoots.length === 1 && this.personalRoots[0].isDirectory) {
      return this.personalRoots[0]
    }
    return null
  }

  private async openDefaultPersonalDirectory(): Promise<void> {
    const defaultDirectory = this.findDefaultPersonalDirectory()
    if (defaultDirectory === null) {
      return
    }
    const personalPath = defaultDirectory.path.length > 0
      ? defaultDirectory.path
      : '/' + defaultDirectory.name
    const requestId = this.navigationRequestId
    this.isBusy = true
    this.isNavigating = true
    try {
      const personalPage = await this.repository.listPage(personalPath, 3, 1)
      if (requestId !== this.navigationRequestId) {
        return
      }
      this.navigationStack = ['']
      this.navigationEntryStack = []
      this.navigationRootTypeStack = []
      this.navigationViewStateStack = []
      this.navigationPageIndexStack = []
      this.navigationPageHasMoreStack = []
      this.currentPath = personalPath
      this.currentRootType = 3
      this.setCurrentPageState(personalPage.pageIndex, personalPage.hasMore)
      this.replaceEntries(personalPage.entries)
      this.updateTopTitle(this.fileTitle(personalPath), false)
      this.updateBottomBarVisibility(true)
      this.updateDirectoryCount(personalPath, personalPage.totalCount >= 0
        ? personalPage.totalCount : personalPage.entries.length)
      this.resetPreviewState()
      this.statusText = '个人目录'
    } catch (_) {
      // Keep the /home root visible when the personal directory is unavailable.
    } finally {
      if (requestId === this.navigationRequestId) {
        this.isNavigating = false
        this.isBusy = false
      }
    }
  }

  private showRoot(kind: RootKind): void {
    this.clearSearchIfPresent()
    this.rootKind = kind
    this.selectedBottomTab = kind === 'personal' ? 'home' : 'shared'
    this.currentRootType = kind === 'personal' ? 4 : 3
    this.currentPath = ''
    this.navigationStack = []
    this.navigationEntryStack = []
    this.navigationRootTypeStack = []
    this.navigationViewStateStack = []
    this.navigationPageIndexStack = []
    this.navigationPageHasMoreStack = []
    this.setCurrentPageState(1, false)
    this.replaceEntries(kind === 'personal' ? this.personalRoots : this.sharedRoots)
    this.updateTopTitle(this.fileTitle('', kind), true)
    this.updateBottomBarVisibility(true)
    this.resetPreviewState()
    this.statusText = kind === 'personal' ? '个人空间' : '共享空间'
  }

  private async openEntry(entry: FileEntry): Promise<void> {
    if (this.isBusy) {
      return
    }
    if (!entry.isDirectory) {
      if (this.isImage(entry)) {
        await this.openImageViewer(entry)
        return
      }
      if (this.isAudio(entry)) {
        await this.openAudioPlayer(entry)
        return
      }
      if (this.isVideo(entry)) {
        await this.openVideoPlayer(entry)
        return
      }
      await this.downloadEntry(entry)
      return
    }
    const outgoingEntries = this.entries.slice()
    const outgoingViewState = this.captureDirectoryViewState()
    this.isBusy = true
    this.isNavigating = true
    const requestId = this.navigationRequestId + 1
    this.navigationRequestId = requestId
    this.errorText = ''
    this.statusText = '正在读取目录…'
    const nextPath = this.resolveEntryPath(entry)
    const nextRootType = nextPath.length > 0 ? 3 :
      (entry.rootType > 0 ? entry.rootType : this.currentRootType)
    try {
      const nextPage = await this.repository.listPage(nextPath, nextRootType, 1)
      if (requestId !== this.navigationRequestId) {
        return
      }
      this.navigationStack = this.navigationStack.concat([this.currentPath])
      this.navigationEntryStack = this.navigationEntryStack.concat([this.entries.slice()])
      this.navigationRootTypeStack = this.navigationRootTypeStack.concat([this.currentRootType])
      this.navigationViewStateStack = this.navigationViewStateStack.concat([
        this.cloneDirectoryViewState(outgoingViewState)])
      this.navigationPageIndexStack = this.navigationPageIndexStack.concat([this.currentPageIndex])
      this.navigationPageHasMoreStack = this.navigationPageHasMoreStack.concat([this.currentPageHasMore])
      this.currentPath = nextPath
      this.currentRootType = nextRootType
      this.setCurrentPageState(nextPage.pageIndex, nextPage.hasMore)
      this.replaceEntries(nextPage.entries)
      this.updateTopTitle(this.fileTitle(nextPath), true)
      this.updateBottomBarVisibility(true)
      this.updateDirectoryCount(nextPath, nextPage.totalCount >= 0
        ? nextPage.totalCount : nextPage.entries.length)
      this.resetPreviewState()
      this.isNavigating = false
      this.startFileTransition(outgoingEntries, 'push')
      this.statusText = nextPage.entries.length === 0 ? '目录读取成功（空目录）' : '目录读取成功'
    } catch (error) {
      if (requestId === this.navigationRequestId) {
        this.presentErrorMessage(readableUgreenError(error as Object) + '（路径：' + nextPath + '）', '目录读取失败')
        this.statusText = '目录读取失败'
      }
    } finally {
      if (requestId === this.navigationRequestId) {
        this.isNavigating = false
        if (!this.showPageTransition) {
          this.isBusy = false
        }
      }
    }
  }

  private async goBack(): Promise<void> {
    if (this.isNavigating) {
      // The current page is still visible while a child directory is loading.
      // Cancel the pending commit so Back remains responsive; the underlying
      // request may finish and populate the repository cache for later use.
      this.navigationRequestId += 1
      this.isNavigating = false
      this.isBusy = false
      this.statusText = ''
      return
    }
    if (this.isBusy) {
      return
    }
    if (this.navigationStack.length === 0) {
      if (this.shouldRestoreSearch(this.currentPath, 0)) {
        this.restoreSearchSession()
        return
      }
      this.showRoot(this.rootKind)
      return
    }
    const stack = this.navigationStack.slice()
    const previousPath = stack.pop() as string
    const entryStack = this.navigationEntryStack.slice()
    const rootTypeStack = this.navigationRootTypeStack.slice()
    const viewStateStack = this.navigationViewStateStack.slice()
    const pageIndexStack = this.navigationPageIndexStack.slice()
    const pageHasMoreStack = this.navigationPageHasMoreStack.slice()
    const previousEntries = entryStack.length > 0 ? entryStack.pop() as FileEntry[] : null
    const previousRootType = rootTypeStack.length > 0 ? rootTypeStack.pop() as number : this.currentRootType
    const previousViewState = viewStateStack.length > 0
      ? viewStateStack.pop() as DirectoryViewState : null
    const previousPageIndex = pageIndexStack.length > 0 ? pageIndexStack.pop() as number : 1
    const previousPageHasMore = pageHasMoreStack.length > 0 ? pageHasMoreStack.pop() as boolean : false
    const outgoingEntries = this.entries.slice()
    if (this.shouldRestoreSearch(previousPath, stack.length)) {
      this.restoreSearchSession()
      return
    }
    if (previousPath.length === 0) {
      this.navigationStack = stack
      this.navigationEntryStack = entryStack
      this.navigationRootTypeStack = rootTypeStack
      this.navigationViewStateStack = viewStateStack
      this.navigationPageIndexStack = pageIndexStack
      this.navigationPageHasMoreStack = pageHasMoreStack
      this.currentPath = previousPath
      this.currentRootType = this.rootKind === 'personal' ? 4 : 3
      this.setCurrentPageState(1, false)
      if (previousViewState !== null) {
        this.fileViewMode = previousViewState.mode
      }
      this.replaceEntries(this.rootKind === 'personal' ? this.personalRoots : this.sharedRoots)
      this.updateTopTitle(this.fileTitle('', this.rootKind), true)
      this.updateBottomBarVisibility(true)
      this.resetPreviewState(false)
      this.restoreDirectoryViewState(previousViewState)
      this.isBusy = true
      this.startFileTransition(outgoingEntries, 'pop')
      return
    }

    // The parent page was already visible before entering the child. Restore
    // that snapshot immediately; the repository cache remains available for
    // a later explicit refresh.
    if (previousEntries !== null) {
      this.navigationStack = stack
      this.navigationEntryStack = entryStack
      this.navigationRootTypeStack = rootTypeStack
      this.navigationViewStateStack = viewStateStack
      this.navigationPageIndexStack = pageIndexStack
      this.navigationPageHasMoreStack = pageHasMoreStack
      this.currentPath = previousPath
      this.currentRootType = previousRootType
      this.setCurrentPageState(previousPageIndex, previousPageHasMore)
      if (previousViewState !== null) {
        this.fileViewMode = previousViewState.mode
      }
      this.replaceEntries(previousEntries)
      this.updateTopTitle(this.fileTitle(previousPath), true)
      this.updateBottomBarVisibility(true)
      this.resetPreviewState(false)
      this.restoreDirectoryViewState(previousViewState)
      this.isBusy = true
      this.startFileTransition(outgoingEntries, 'pop')
      return
    }

    this.isBusy = true
    try {
      const loadedPage = await this.repository.listPage(previousPath, previousRootType, 1)
      this.navigationStack = stack
      this.navigationEntryStack = entryStack
      this.navigationRootTypeStack = rootTypeStack
      this.navigationViewStateStack = viewStateStack
      this.navigationPageIndexStack = pageIndexStack
      this.navigationPageHasMoreStack = pageHasMoreStack
      this.currentPath = previousPath
      this.currentRootType = previousRootType
      this.setCurrentPageState(loadedPage.pageIndex, loadedPage.hasMore)
      if (previousViewState !== null) {
        this.fileViewMode = previousViewState.mode
      }
      this.replaceEntries(loadedPage.entries)
      this.updateTopTitle(this.fileTitle(previousPath), true)
      this.updateBottomBarVisibility(true)
      this.updateDirectoryCount(previousPath, loadedPage.totalCount >= 0
        ? loadedPage.totalCount : loadedPage.entries.length)
      this.resetPreviewState(false)
      this.restoreDirectoryViewState(previousViewState)
      this.startFileTransition(outgoingEntries, 'pop')
    } catch (error) {
      this.reportError(error as Object, '返回目录失败')
    } finally {
      if (!this.showPageTransition) {
        this.isBusy = false
      }
    }
  }

  private async downloadEntry(entry: FileEntry): Promise<void> {
    if (entry.isDirectory) {
      return
    }
    this.errorText = ''
    try {
      await this.ensureDownloadState()
      await this.downloadQueue.enqueue(entry)
      this.statusText = '已加入下载队列'
      this.showImmersiveToast('已加入下载：' + entry.name)
    } catch (error) {
      this.reportError(error as Object, '加入下载失败')
      this.statusText = '加入下载失败'
    }
  }

  private handleFileEntryClick(entry: FileEntry): void {
    // A long press can otherwise emit a trailing click from ListItem after
    // the gesture recognizer finishes. Keep navigation disabled while the
    // explicitly controlled context menu owns the interaction.
    if (this.contextMenuVisible || this.contextMenuEntry !== null) {
      return
    }
    if (this.selectionMode) {
      this.toggleSelection(entry)
      return
    }
    this.openEntry(entry)
  }

  private showActionMenu(entry: FileEntry, event: GestureEvent): void {
    if (this.screen !== 'files' || this.showSearch || this.selectionMode ||
      this.showDestinationPicker || this.showRenameDialog || this.showCreateFolderDialog ||
      this.showImageViewer || this.showAudioPlayer || this.videoPlaybackUiVisible() ||
      this.showPageTransition || this.contextMenuEntry !== null) {
      return
    }

    this.pendingContextAction = null
    this.contextMenuSourceY = Math.max(this.topSafeInset(),
      (event.fingerList.length > 0 ? event.fingerList[0].globalY -
        this.getUIContext().px2vp(this.statusBarHeightPx) : this.pageHeightVp / 2) - 29)
    this.contextMenuEntry = entry
    // The anchor follows the long-press position. ArkUI moves the preview only
    // as far as necessary to fit the preview and the measured action menu.
    this.contextMenuVisible = true
  }

  private actionMenuSurfaceTransition(): TransitionEffect {
    const appear = TransitionEffect.opacity(0)
      .animation({
        duration: 220,
        curve: curves.interpolatingSpring(0, 1, 320, 30)
      })
    const disappear = TransitionEffect.opacity(0)
      .animation({ duration: 150, curve: Curve.EaseOut })
    return TransitionEffect.asymmetric(appear, disappear)
  }

  private runContextAction(action: () => void): void {
    this.pendingContextAction = action
    this.dismissActionMenu()
  }

  private runPendingContextAction(): void {
    const action = this.pendingContextAction
    this.pendingContextAction = null
    if (action !== null) {
      action()
    }
  }

  private closeActionMenu(): void {
    this.pendingContextAction = null
    this.dismissActionMenu()
  }

  private dismissActionMenu(): void {
    this.contextMenuVisible = false
  }

  private finishActionMenuDismiss(): void {
    if (this.contextMenuEntry === null) {
      return
    }
    // Keep the preview data and the bottom bar's visibility stable until the
    // native menu AND preview have completed their exit animation.
    this.contextMenuVisible = false
    this.contextMenuEntry = null
    this.runPendingContextAction()
  }

  private actionMenuHeight(entry: FileEntry): number {
    // Match the compact Files menu while retaining enough room for the
    // longest media menu. Scroll takes over if a future action is added.
    let height = 58 + 8 // quick actions + section gap
    if (!entry.isDirectory && this.actionSupportsOpenWith(entry)) {
      height += 51 + 8
    }
    let middleRows = 3 // multi-select, download, rename
    if (!entry.isDirectory && this.actionSupportsQuickView(entry)) {
      middleRows += 1
    }
    if (!entry.isDirectory && this.isMedia(entry)) {
      middleRows += 1
    }
    if (!entry.isDirectory && this.actionHasLocalCache(entry)) {
      middleRows += 1
    }
    height += middleRows * 51
    height += 8 // details/delete section gap
    height += 101
    return Math.min(540, height,
      Math.max(120, this.pageHeightVp - this.topSafeInset() - this.bottomSafeInset() - 114))
  }

  private actionSupportsShare(entry: FileEntry): boolean {
    return !entry.isDirectory && (this.isImage(entry) || this.isVideo(entry) || this.isAudio(entry) ||
      this.fileType(entry).length > 0)
  }

  private actionSupportsOpenWith(entry: FileEntry): boolean {
    return !entry.isDirectory
  }

  private actionSupportsQuickView(entry: FileEntry): boolean {
    return this.isImage(entry) || this.isVideo(entry) || this.isAudio(entry)
  }

  private actionHasLocalCache(entry: FileEntry): boolean {
    if (entry.isDirectory) {
      return false
    }
    if (this.isVideo(entry)) {
      const state = this.videoTransferManager.stateFor(entry)
      return state.durablePath.length === 0 && state.localPath.length > 0 &&
        CacheManager.exists(state.localPath)
    }
    if (this.cacheDirectory.length === 0) {
      return false
    }
    return CacheManager.findExisting(this.cacheDirectory, entry.name, this.originalCacheKey(entry)).length > 0
  }

  private videoStateForEntry(entry: FileEntry): VideoTransferState {
    const sourceKey = this.repository.signatureForFile(entry).key()
    const state = this.videoTransferStates[sourceKey]
    return state === undefined ? this.videoTransferManager.stateFor(entry) : state
  }

  private async downloadEntryFromMenu(entry: FileEntry): Promise<void> {
    if (this.isBusy) {
      return
    }
    if (!entry.isDirectory) {
      await this.cacheToLocal(entry)
      return
    }
    this.closeActionMenu()
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在准备文件夹下载…'
    try {
      await this.ensureDownloadState()
      const destinationRoot = await DownloadDestination.directory()
      const count = await this.enqueueRemoteTree(entry, destinationRoot, entry.name)
      this.statusText = count > 0 ? '已加入下载队列' : '文件夹为空'
      if (count > 0) {
        this.showImmersiveToast('已加入下载：' + entry.name)
      }
    } catch (error) {
      this.reportError(error as Object, '加入下载失败')
      this.statusText = '加入下载失败'
    } finally {
      this.isBusy = false
    }
  }

  private async enqueueRemoteTree(entry: FileEntry, destinationRoot: string,
    relativePath: string): Promise<number> {
    if (!entry.isDirectory) {
      if (this.isVideo(entry)) {
        // Video transfers use the MediaKit range/cache coordinator so an
        // earlier stream is promoted instead of starting a second full-file
        // download. The route remains the same UGREENlink directory.
        await this.refreshVideoManager()
        this.videoTransferManager.requestDownload(entry, destinationRoot, relativePath).catch((): void => {})
      } else {
        await this.downloadQueue.enqueue(entry, destinationRoot, relativePath)
      }
      return 1
    }
    this.ensureLocalDirectory(destinationRoot + '/' + this.safeLocalPath(relativePath))
    const childRootType = entry.path.length > 0 ? 3 : entry.rootType
    const children = await this.repository.list(entry.path, childRootType)
    let count = 0
    for (const child of children) {
      const childRelativePath = relativePath + '/' + child.name
      count += await this.enqueueRemoteTree(child, destinationRoot, childRelativePath)
    }
    return count
  }

  private ensureLocalDirectory(path: string): void {
    try {
      fileIo.mkdirSync(path, true)
    } catch (_) {
      // The queue will report a real write failure when the directory is not
      // writable. Keeping this best-effort avoids blocking the directory scan.
    }
  }

  private safeLocalPath(path: string): string {
    const parts = path.split(/[\\/]+/)
    const safe: string[] = []
    for (const part of parts) {
      const value = part.trim()
      if (value.length === 0 || value === '.' || value === '..') {
        continue
      }
      safe.push(value.replace(/[\\/:*?"<>|]/g, '_'))
    }
    return safe.join('/')
  }

  private async releaseCache(entry: FileEntry): Promise<void> {
    if (this.isBusy) {
      return
    }
    this.closeActionMenu()
    if (this.isVideo(entry)) {
      this.isBusy = true
      try {
        await this.refreshVideoManager()
        await this.videoTransferManager.clearCache(entry)
        await this.refreshCacheUsage()
        this.statusText = '已释放缓存'
        this.showImmersiveToast('已释放缓存')
      } catch (error) {
        this.reportError(error as Object, '释放缓存失败')
      } finally {
        this.isBusy = false
      }
      return
    }
    await this.ensureCacheState()
    const path = CacheManager.findExisting(this.cacheDirectory, entry.name, this.originalCacheKey(entry))
    if (path.length === 0) {
      return
    }
    this.isBusy = true
    try {
      await CacheManager.remove(path)
      await this.refreshCacheUsage()
      this.statusText = '已释放缓存'
      this.showImmersiveToast('已释放缓存')
    } catch (error) {
      this.reportError(error as Object, '释放缓存失败')
    } finally {
      this.isBusy = false
    }
  }

  private async showEntryDetails(entry: FileEntry): Promise<void> {
    this.closeActionMenu()
    const type = entry.isDirectory ? '文件夹' : (this.fileType(entry).length > 0 ? this.fileType(entry) : '文件')
    const lines: string[] = [
      '类型：' + type,
      '大小：' + (entry.isDirectory ? '—' : this.formatSize(entry.size)),
      '修改时间：' + this.formatTime(entry.modifiedTime),
      '位置：' + (entry.path.length > 0 ? entry.path : '/')
    ]
    if (entry.isDirectory && entry.childCount >= 0) {
      lines.splice(1, 0, '项目：' + entry.childCount.toString() + ' 项')
    }
    await promptAction.showDialog({
      title: entry.name,
      message: lines.join('\n'),
      buttons: [{ text: '知道了', color: this.isDarkTheme ? '#FFFFFFFF' : '#536174' }],
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false)
    })
  }

  private beginDestinationPicker(operation: DestinationOperation, entry: FileEntry): void {
    this.beginDestinationPickerForEntries(operation, [entry])
  }

  private beginDestinationPickerForEntries(operation: DestinationOperation,
    entries: FileEntry[]): void {
    if (this.isBusy) {
      return
    }
    this.destinationPickerCloseToken += 1
    this.destinationOperation = operation
    this.destinationSelectedEntries = entries.slice()
    // Copy and move both target the current cloud provider. Keeping one
    // destination model also prevents a local-public-directory capability
    // from being touched by the path picker.
    this.destinationPathStack = []
    this.destinationPath = this.destinationUserRootPath()
    this.destinationChildrenByPath.clear()
    this.destinationTreeRows = []
    this.destinationExpandedPaths = []
    this.destinationTreeLoadingPath = ''
    this.destinationRootExpanded = true
    this.destinationPickerClosing = false
    this.showDestinationPicker = true
    this.closeActionMenu()
    this.loadDestinationEntries()
  }

  private closeDestinationPicker(): void {
    if (this.destinationLoading || this.destinationPickerClosing) {
      return
    }
    this.destinationPickerClosing = true
    const closeToken = ++this.destinationPickerCloseToken
    this.destinationLoadToken += 1
    this.destinationTreeRequestToken += 1
    this.destinationTreeLoadingPath = ''
    setTimeout(() => {
      if (closeToken !== this.destinationPickerCloseToken) {
        return
      }
      this.showDestinationPicker = false
      this.destinationPickerClosing = false
      this.destinationPathStack = []
      this.destinationPath = ''
      this.destinationEntries = []
      this.destinationTreeRows = []
      this.destinationExpandedPaths = []
      this.destinationChildrenByPath.clear()
      this.destinationRootExpanded = true
      this.destinationSelectedEntries = []
      this.destinationFolderText = ''
    }, 260)
  }


  private async loadDestinationEntries(): Promise<void> {
    const token = ++this.destinationLoadToken
    this.destinationLoading = true
    this.destinationEntries = []
    this.destinationTreeRows = []
    const rootPath = this.destinationUserRootPath()
    try {
      const result = await this.fetchDestinationFolders(rootPath)
      if (token === this.destinationLoadToken) {
        this.destinationPath = rootPath
        this.destinationEntries = result
        this.destinationChildrenByPath.clear()
        this.destinationExpandedPaths = []
        this.rebuildDestinationTreeRows()
      }
    } catch (error) {
      if (token === this.destinationLoadToken) {
        this.destinationEntries = []
        this.destinationTreeRows = []
        this.reportError(error as Object, '读取目标目录失败')
      }
    } finally {
      if (token === this.destinationLoadToken) {
        this.destinationLoading = false
      }
    }
  }

  private async fetchDestinationFolders(path: string): Promise<DestinationEntry[]> {
    const result: DestinationEntry[] = []
    const rootType = path.length > 0 ? 3 : this.currentRootType
    const entries = await this.repository.list(path, rootType)
    for (const entry of entries) {
      if (!entry.isDirectory) {
        continue
      }
      const item = new DestinationEntry()
      item.name = entry.name
      item.path = entry.path
      item.modifiedTime = entry.modifiedTime
      item.childCount = entry.childCount
      result.push(item)
    }
    result.sort((left: DestinationEntry, right: DestinationEntry): number => {
      return left.name.localeCompare(right.name)
    })
    return result
  }

  private rebuildDestinationTreeRows(): void {
    const rows: DestinationTreeRow[] = []
    const appendRows = (entries: DestinationEntry[], depth: number): void => {
      for (const entry of entries) {
        const row = new DestinationTreeRow()
        row.entry = entry
        row.depth = depth
        row.expanded = this.destinationExpandedPaths.indexOf(entry.path) >= 0
        row.loading = this.destinationTreeLoadingPath === entry.path
        rows.push(row)
        if (row.expanded) {
          const children = this.destinationChildrenByPath.get(entry.path)
          if (children !== undefined) {
            appendRows(children, depth + 1)
          }
        }
      }
    }
    appendRows(this.destinationEntries, 0)
    this.destinationTreeRows = rows
  }

  private async toggleDestinationFolder(entry: DestinationEntry): Promise<void> {
    if (this.destinationLoading || this.destinationTreeLoadingPath.length > 0) {
      return
    }
    const path = entry.path
    this.destinationPath = path
    const isExpanded = this.destinationExpandedPaths.indexOf(path) >= 0
    if (isExpanded) {
      const prefix = path.replace(/[\\/]$/, '') + '/'
      this.getUIContext().animateTo({
        duration: 220,
        curve: curves.interpolatingSpring(0, 1, 320, 30)
      }, () => {
        this.destinationExpandedPaths = this.destinationExpandedPaths.filter((item: string): boolean => {
          return item !== path && !item.startsWith(prefix)
        })
        this.rebuildDestinationTreeRows()
      })
      return
    }

    const cachedChildren = this.destinationChildrenByPath.get(path)
    if (cachedChildren !== undefined) {
      this.getUIContext().animateTo({
        duration: 220,
        curve: curves.interpolatingSpring(0, 1, 320, 30)
      }, () => {
        this.destinationExpandedPaths = this.destinationExpandedPaths.concat([path])
        this.rebuildDestinationTreeRows()
      })
      return
    }

    const requestToken = ++this.destinationTreeRequestToken
    const closeToken = this.destinationPickerCloseToken
    this.destinationTreeLoadingPath = path
    this.rebuildDestinationTreeRows()
    try {
      const children = await this.fetchDestinationFolders(path)
      if (requestToken !== this.destinationTreeRequestToken ||
        closeToken !== this.destinationPickerCloseToken) {
        return
      }
      this.destinationChildrenByPath.set(path, children)
      this.getUIContext().animateTo({
        duration: 220,
        curve: curves.interpolatingSpring(0, 1, 320, 30)
      }, () => {
        this.destinationExpandedPaths = this.destinationExpandedPaths.concat([path])
        this.rebuildDestinationTreeRows()
      })
    } catch (error) {
      if (requestToken === this.destinationTreeRequestToken &&
        closeToken === this.destinationPickerCloseToken) {
        this.reportError(error as Object, '读取目标目录失败')
      }
    } finally {
      if (requestToken === this.destinationTreeRequestToken) {
        this.destinationTreeLoadingPath = ''
        this.rebuildDestinationTreeRows()
      }
    }
  }

  private destinationUserRootPath(): string {
    const account = this.username.trim().replace(/^\/+|\/+$/g, '')
    return account.length > 0 ? '/home/' + account : '/home'
  }

  private toggleDestinationRoot(): void {
    const rootPath = this.destinationUserRootPath()
    this.destinationPathStack = []
    this.destinationPath = rootPath
    const nextExpanded = !this.destinationRootExpanded
    this.getUIContext().animateTo({
      duration: 220,
      curve: curves.interpolatingSpring(0, 1, 320, 30)
    }, () => {
      this.destinationRootExpanded = nextExpanded
    })
  }

  private goDestinationBack(): void {
    if (this.destinationTreeLoadingPath.length > 0) {
      return
    }
    if (this.destinationExpandedPaths.length === 0) {
      this.destinationLoading = false
      this.closeDestinationPicker()
      return
    }
    const expandedPath = this.destinationExpandedPaths[this.destinationExpandedPaths.length - 1]
    const rootPath = this.destinationUserRootPath()
    const parent = this.parentPath(expandedPath)
    this.destinationPath = parent.indexOf(rootPath) === 0 ? parent : rootPath
    const prefix = expandedPath.replace(/[\\/]$/, '') + '/'
    this.getUIContext().animateTo({
      duration: 220,
      curve: curves.interpolatingSpring(0, 1, 320, 30)
    }, () => {
      this.destinationExpandedPaths = this.destinationExpandedPaths.filter((item: string): boolean => {
        return item !== expandedPath && !item.startsWith(prefix)
      })
      this.rebuildDestinationTreeRows()
    })
  }

  private openDestinationFolderDialog(): void {
    if (this.destinationLoading || this.destinationPath.length === 0 && this.currentRootType === 0) {
      return
    }
    this.destinationFolderText = ''
    this.destinationFolderDialog = true
  }

  private closeDestinationFolderDialog(): void {
    if (this.destinationLoading) {
      return
    }
    this.destinationFolderDialog = false
    this.destinationFolderText = ''
  }

  private async confirmDestinationFolder(): Promise<void> {
    if (this.destinationLoading) {
      return
    }
    const name = this.destinationFolderText.trim()
    if (name.length === 0 || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0) {
      this.presentErrorMessage('文件夹名称不能为空，且不能包含路径分隔符', '新建文件夹失败')
      return
    }
    const parent = this.destinationPath.replace(/[\\/]$/, '')
    const path = parent.length > 0 ? parent + '/' + name : '/' + name
    this.destinationLoading = true
    try {
      await this.repository.createFolder(path)
      this.destinationFolderDialog = false
      this.destinationFolderText = ''
      const refreshedPath = this.destinationPath
      const refreshedEntries = await this.fetchDestinationFolders(refreshedPath)
      if (refreshedPath === this.destinationUserRootPath()) {
        this.destinationEntries = refreshedEntries
      } else {
        this.destinationChildrenByPath.set(refreshedPath, refreshedEntries)
      }
      this.rebuildDestinationTreeRows()
    } catch (error) {
      this.reportError(error as Object, '新建文件夹失败')
    } finally {
      this.destinationLoading = false
    }
  }

  private destinationEntryInfo(entry: DestinationEntry): string {
    const parts: string[] = []
    if (entry.modifiedTime > 0) {
      parts.push(this.formatTime(entry.modifiedTime))
    }
    if (entry.childCount >= 0) {
      parts.push(entry.childCount.toString() + ' 项')
    }
    return parts.join(' - ')
  }

  private destinationDisplayName(): string {
    if (this.destinationPath.length === 0 || this.destinationPath === this.destinationUserRootPath()) {
      return '我的绿联'
    }
    const normalized = this.destinationPath.replace(/[\\/]$/, '')
    const separator = normalized.lastIndexOf('/')
    return separator >= 0 ? normalized.substring(separator + 1) : normalized
  }

  private async loadPersistedImageDisplayState(entries: FileEntry[]): Promise<ImageDisplayState> {
    const state = new ImageDisplayState()
    if (entries.length === 0) {
      return state
    }
    const scope = this.repository.cacheScopeHash()
    if (scope.length === 0) {
      return state
    }
    try {
      await this.ensureImageRotationState()
      const parents: Record<string, boolean> = {}
      for (const entry of entries) {
        parents[this.parentPath(entry.path)] = true
      }
      const records: ImageRotationRecord[] = []
      for (const parent of Object.keys(parents)) {
        const directoryRecords = await this.imageRotationStore.readDirectory(scope, parent)
        records.push(...directoryRecords)
      }
      const entriesByPath: Map<string, FileEntry> = new Map<string, FileEntry>()
      for (const entry of entries) {
        entriesByPath.set(entry.path, entry)
      }
      for (const record of records) {
        const entry = entriesByPath.get(record.path)
        if (entry === undefined) {
          continue
        }
        if (entry.size !== record.size || entry.modifiedTime !== record.modifiedTime) {
          this.imageRotationStore.remove(scope, record.path).catch((error: Error): void => {
            console.warn('[UgreenImage] remove stale rotation metadata failed: ' + JSON.stringify(error))
          })
          continue
        }
        if (record.angle !== 0) {
          state.rotations[entry.path] = record.angle
        }
        if (record.previewOrientation !== 0) {
          state.previewOrientations[entry.path] =
            record.previewOrientation as ImageRotateOrientation
        }
      }
    } catch (error) {
      console.warn('[UgreenImage] load persisted display metadata failed: ' + JSON.stringify(error))
    }
    return state
  }

  private refreshFileListImageRotations(entries: FileEntry[]): void {
    const generation = this.fileListRotationGeneration + 1
    this.fileListRotationGeneration = generation
    if (entries.length === 0) {
      return
    }
    const snapshot = entries.slice()
    const pendingStates: Record<string, ImageVisualState> = {}
    for (const key of Object.keys(this.imageVisualStates)) {
      pendingStates[key] = this.imageVisualStates[key]
    }
    for (const entry of snapshot) {
      if (!this.isImage(entry)) {
        continue
      }
      const pending = this.copyImageVisualState(this.imageVisualStates[entry.path])
      pending.rotationResolved = false
      pendingStates[entry.path] = pending
    }
    this.imageVisualStates = pendingStates
    this.loadPersistedImageDisplayState(snapshot).then((state: ImageDisplayState): void => {
      if (generation !== this.fileListRotationGeneration) {
        return
      }
      const nextStates: Record<string, ImageVisualState> = {}
      for (const key of Object.keys(this.imageVisualStates)) {
        nextStates[key] = this.imageVisualStates[key]
      }
      for (const entry of snapshot) {
        const next = this.copyImageVisualState(this.imageVisualStates[entry.path])
        const rotation = state.rotations[entry.path]
        const orientation = state.previewOrientations[entry.path]
        next.userRotation = rotation === undefined ? 0 : rotation
        next.rotationResolved = true
        next.thumbnailOrientation = orientation === undefined
          ? (this.previewCanonicalPaths[entry.path] === true
            ? ImageRotateOrientation.UP : ImageRotateOrientation.AUTO) : orientation
        nextStates[entry.path] = next
      }
      this.imageVisualStates = nextStates
      for (const entry of snapshot) {
        if (!this.isImage(entry)) {
          continue
        }
        const rotation = this.imageVisualState(entry.path).userRotation
        const thumbnail = this.fileThumbnailBitmaps[entry.path]
        if (thumbnail !== undefined && thumbnail.userRotation !== rotation) {
          this.releaseFileThumbnailBitmap(entry.path)
        }
        const waterfall = this.waterfallBitmaps[entry.path]
        if (waterfall !== undefined && waterfall.userRotation !== rotation) {
          this.releaseViewerBitmap(this.waterfallBitmaps, entry.path).catch((): void => {})
          this.waterfallDecodedPaths[entry.path] = false
        }
        this.loadEntryPreview(entry)
        if (this.fileViewMode === 'waterfall' && this.waterfallVisiblePaths[entry.path] === true) {
          this.enqueueWaterfallDecode(entry)
        }
      }
    }).catch((error: Error): void => {
      console.warn('[UgreenImage] refresh file-list display metadata failed: ' + JSON.stringify(error))
    })
  }

  private fileListImageBaseOrientation(entry: FileEntry): ImageRotateOrientation {
    if (this.previewUri(entry).indexOf('.image.preview.') >= 0) {
      return ImageRotateOrientation.UP
    }
    // NAS thumbnails are an external source: the server may have already
    // applied EXIF, or it may have retained the EXIF tag. AUTO is the only
    // safe client-side rule for both cases. Older persisted inverse values
    // are deliberately ignored so a cache/database migration cannot rotate
    // the same thumbnail a second time.
    return this.imageVisualState(entry.path).thumbnailOrientation
  }

  private setFileListImageBaseOrientation(path: string,
    orientation: ImageRotateOrientation): void {
    if (path.length === 0) {
      return
    }
    this.updateImageVisualState(path, (state: ImageVisualState): void => {
      state.thumbnailOrientation = orientation
    })
  }

  private persistPreviewOrientation(entry: FileEntry,
    orientation: ImageRotateOrientation): void {
    const scope = this.repository.cacheScopeHash()
    if (scope.length === 0) {
      return
    }
    this.ensureImageRotationState().then((): Promise<void> => {
      return this.imageRotationStore.savePreviewOrientation(scope, entry, orientation as number)
    }).catch((error: Error): void => {
      console.warn('[UgreenImage] persist preview orientation failed: ' + JSON.stringify(error))
    })
  }

  private persistViewerRotation(entry: FileEntry, angle: number): void {
    const scope = this.repository.cacheScopeHash()
    if (scope.length === 0) {
      return
    }
    this.ensureImageRotationState().then((): Promise<void> => {
      return this.imageRotationStore.save(scope, entry, angle)
    }).catch((error: Error): void => {
      console.warn('[UgreenImage] persist rotation failed: ' + JSON.stringify(error))
    })
  }

  private async removePersistedViewerRotation(entry: FileEntry): Promise<void> {
    const scope = this.repository.cacheScopeHash()
    if (scope.length === 0) {
      return
    }
    try {
      await this.ensureImageRotationState()
      await this.imageRotationStore.remove(scope, entry.path)
    } catch (error) {
      console.warn('[UgreenImage] remove rotation metadata failed: ' + JSON.stringify(error))
    }
  }

  private async confirmDestinationOperation(): Promise<void> {
    if (this.destinationLoading || this.destinationSelectedEntries.length === 0) {
      return
    }
    const entries = this.destinationSelectedEntries.slice()
    const targetPath = this.destinationPath
    if (this.destinationOperation === 'move') {
      for (const entry of entries) {
        const sourceParent = this.parentPath(entry.path)
        if (targetPath === sourceParent || targetPath === entry.path ||
          (entry.isDirectory && targetPath.indexOf(entry.path.replace(/[\\/]$/, '') + '/') === 0)) {
          this.presentErrorMessage('不能移动到当前目录或源目录内部', '移动失败')
          return
        }
      }
    }
    this.destinationLoading = true
    this.errorText = ''
    try {
      const paths = entries.map((entry: FileEntry): string => entry.path)
      if (this.destinationOperation === 'copy') {
        await this.repository.copy(paths, targetPath)
      } else {
        await this.repository.move(paths, targetPath)
      }
      await this.refreshCurrentDirectory()
      this.statusText = this.destinationOperation === 'copy' ? '已复制到云盘' : '已移动到云盘'
      this.showImmersiveToast(this.statusText)
      this.destinationLoading = false
      this.closeDestinationPicker()
    } catch (error) {
      this.reportError(error as Object, this.destinationOperation === 'copy' ? '复制失败' : '移动失败')
    } finally {
      this.destinationLoading = false
    }
  }

  private resetViewerVisualSession(entries: FileEntry[],
    persisted: ImageDisplayState): void {
    const nextStates: Record<string, ImageVisualState> = {}
    for (const key of Object.keys(this.imageVisualStates)) {
      nextStates[key] = this.imageVisualStates[key]
    }
    for (const item of entries) {
      const next = this.copyImageVisualState(this.imageVisualStates[item.path])
      const rotation = persisted.rotations[item.path]
      const orientation = persisted.previewOrientations[item.path]
      next.userRotation = rotation === undefined ? 0 : rotation
      next.rotationResolved = true
      if (orientation !== undefined) {
        next.thumbnailOrientation = orientation
      }
      next.originalUri = ''
      next.originalOrientation = ImageRotateOrientation.AUTO
      next.physicalWidth = 0
      next.physicalHeight = 0
      next.exifDisplayWidth = 0
      next.exifDisplayHeight = 0
      next.displayWidth = 0
      next.displayHeight = 0
      // Image.onComplete content bounds are render-result dimensions. In a
      // rotated or clipped WaterFlow card they are not source metadata and
      // must not seed a new viewer session.
      next.thumbnailDisplayWidth = 0
      next.thumbnailDisplayHeight = 0
      next.frameWidth = 0
      next.frameHeight = 0
      next.frameLocked = false
      next.decodeState = 'idle'
      next.visibleLayer = 'thumbnail'
      next.progress = 0
      next.progressKnown = false
      nextStates[item.path] = next
    }
    this.imageVisualStates = nextStates
  }

  private async openImageViewer(entry: FileEntry): Promise<void> {
    if (this.isBusy || this.viewerClosePending || entry.isDirectory) {
      return
    }
    this.closeActionMenu()
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在准备图片预览…'
    try {
      const imageEntries = this.imageEntriesInCurrentDirectory()
      const initialIndex = imageEntries.findIndex((item: FileEntry) => item.path === entry.path)
      if (initialIndex < 0) {
        throw new Error('当前目录中未找到图片')
      }
      this.captureViewerReturnScrollPosition()
      const persistedState = await this.loadPersistedImageDisplayState(imageEntries)
      this.viewerGeneration += 1
      const openingGeneration = this.viewerGeneration
      this.viewerLoadQueue = []
      this.viewerLoadRequests = {}
      this.viewerManualLoadPaths = {}
      this.viewerActiveLoads = 0
      this.viewerActiveLoadPaths = {}
      this.viewerPrimaryPath = ''
      this.viewerPendingIndex = -1
      // Start with one visible-image request. After its Image.onComplete,
      // start the bounded adjacent decode window; a swipe may temporarily
      // use one extra slot so the new visible image is not blocked by an old
      // neighbor request.
      this.viewerMaxConcurrentLoads = 1
      this.replaceViewerImages(imageEntries)
      this.viewerImageIndex = initialIndex
      this.viewerImageEntry = entry
      this.viewerHeaderTitle = entry.name
      this.resetViewerVisualSession(imageEntries, persistedState)
      // The original may have been released while its thumbnail remains.
      // Prefer cached original metadata, falling back to the thumbnail before
      // mounting, including the persisted base-orientation swap.
      await this.primeViewerFrameWindow(imageEntries, initialIndex, 2)
      this.ensureViewerImageFrame(entry)
      this.logViewerDiagnostic('open-frame-ready', entry.path)
      this.viewerProgressLastUpdateAt = {}
      this.viewerRevealTokens = {}
      this.viewerPendingBitmapReveals = {}
      this.viewerPendingRotationPath = ''
      this.viewerCloseRequested = false
      this.viewerReturnReadyPath = entry.path
      this.viewerBottomBarWidthVp = 0
      this.showImageMoreMenu = false
      this.showImageDetails = false
      this.viewerOverlayEntry = null
      this.viewerLastNavigationDirection = 1
      this.resetImageTransform()
      this.viewerTransitionActive = false
      this.viewerSurfaceOpacity = 1
      this.viewerFallbackEntryActive = false
      this.setImageChromeVisible(false, false)
      // The shared-element source and target must consume the same decoded
      // raster. Decode the preview before binding the geometry id; if the
      // local thumbnail is unavailable we intentionally use the ordinary
      // no-geometry transition instead of inventing a frame.
      await this.ensureViewerPreviewBitmap(entry)
      // Commit the source-only frame first. The following hierarchy swap is
      // the sole state change inside animateTo, so one Image leaves the file
      // surface at exactly the moment its viewer counterpart is inserted.
      this.startViewerEntryTransition(entry)
      this.logViewerDiagnostic(this.viewerEntryTransitionActive
        ? 'entry-source-bound' : 'entry-fallback', entry.path)
      if (this.viewerEntryTransitionActive) {
        await this.nextRenderFrame()
        await new Promise<void>((resolve: () => void): void => {
          this.getUIContext().animateTo({
            duration: IMAGE_GEOMETRY_TRANSITION_DURATION,
            curve: Curve.FastOutSlowIn,
            onFinish: resolve
          }, () => {
            this.showImageViewer = true
            this.imageChromeVisible = true
            this.imageChromeOpacity = 1
            this.imageTopChromeOffsetY = 0
            this.imageBottomChromeOffsetY = 0
          })
        })
        await this.nextRenderFrame()
        this.clearViewerEntryTransition()
      } else {
        // Unknown thumbnail geometry deliberately uses a normal surface fade.
        // It never guesses a square source or binds a shared-element id.
        this.viewerSurfaceOpacity = 0
        this.viewerFallbackEntryActive = true
        this.showImageViewer = true
        await this.nextRenderFrame()
        await new Promise<void>((resolve: () => void): void => {
          this.getUIContext().animateTo({
            duration: IMAGE_FALLBACK_TRANSITION_DURATION,
            curve: Curve.EaseOut,
            onFinish: resolve
          }, () => {
            this.viewerSurfaceOpacity = 1
            this.imageChromeVisible = true
            this.imageChromeOpacity = 1
            this.imageTopChromeOffsetY = 0
            this.imageBottomChromeOffsetY = 0
          })
        })
        await this.nextRenderFrame()
        this.viewerFallbackEntryActive = false
      }
      this.logViewerDiagnostic('entry-complete', entry.path)
      if (!this.showImageViewer || openingGeneration !== this.viewerGeneration) {
        return
      }
      if (this.viewerCloseRequested) {
        this.viewerCloseRequested = false
        this.postRenderFrame((): void => this.closeImageViewer())
        return
      }
      this.enableImageViewerAutoRotation()
      // Mount the viewer and its ring before doing any local original work.
      // A cache hit has no HTTP byte progress, so it stays gray during local
      // EXIF/normalization work, reaches 95% when the Image source is bound,
      // and closes only from Image.onComplete.
      this.setViewerDownloadProgress(entry.path, 0, true, true)
      await this.primeCachedViewerOriginal(entry, openingGeneration)
      if (!this.showImageViewer) {
        return
      }
      this.prefetchViewerImages(initialIndex)
      this.statusText = ''
    } catch (error) {
      this.clearViewerEntryTransition()
      this.showImageViewer = false
      this.viewerSurfaceOpacity = 1
      this.viewerFallbackEntryActive = false
      this.reportError(error as Object, '图片预览失败')
      this.statusText = '图片预览失败'
    } finally {
      this.isBusy = false
    }
  }

  private captureViewerReturnScrollPosition(): void {
    this.viewerReturnScrollOffset = null
    this.viewerReturnScrollPath = ''
    this.viewerReturnScrollAnchor = null
    if (this.screen !== 'files' || this.showSearch || this.currentPath.length === 0) {
      return
    }
    try {
      const scroller = this.fileViewMode === 'waterfall'
        ? this.waterfallScroller : this.fileListScroller
      const offset = scroller.currentOffset()
      const anchor = this.fileViewMode === 'waterfall'
        ? this.captureFileViewAnchor() : null
      if (offset !== undefined && typeof offset.yOffset === 'number') {
        this.viewerReturnScrollOffset = {
          xOffset: typeof offset.xOffset === 'number' ? offset.xOffset : 0,
          yOffset: offset.yOffset
        }
        this.viewerReturnScrollPath = this.currentPath
        this.viewerReturnScrollMode = this.fileViewMode
        this.viewerReturnScrollAnchor = anchor
      } else if (anchor !== null) {
        // A WaterFlow layout pass can temporarily omit currentOffset while
        // the visible item rectangles are already available. Keep the anchor
        // usable and use the raw offset only as a fallback.
        this.viewerReturnScrollOffset = { xOffset: 0, yOffset: 0 }
        this.viewerReturnScrollPath = this.currentPath
        this.viewerReturnScrollMode = this.fileViewMode
        this.viewerReturnScrollAnchor = anchor
      }
    } catch (error) {
      console.warn('[UgreenScroll] capture viewer return position failed: ' + JSON.stringify(error))
    }
  }

  private restoreViewerReturnScrollPosition(): void {
    const offset = this.viewerReturnScrollOffset
    const path = this.viewerReturnScrollPath
    const mode = this.viewerReturnScrollMode
    const anchor = this.viewerReturnScrollAnchor
    this.viewerReturnScrollOffset = null
    this.viewerReturnScrollPath = ''
    this.viewerReturnScrollAnchor = null
    if (offset === null || this.screen !== 'files' || this.showSearch ||
      this.currentPath !== path || this.fileViewMode !== mode) {
      return
    }

    if (mode === 'waterfall' && anchor !== null) {
      // Restore by file identity first. WaterFlow may have recalculated the
      // masonry heights while the viewer was mounted, so a raw y offset can
      // land on a different image even when the offset itself is unchanged.
      const token = this.waterfallAnchorRestoreToken + 1
      this.waterfallAnchorRestoreToken = token
      this.postRenderFrame((): void => {
        this.restoreFileViewAnchor(anchor, token, 0)
      })
      return
    }

    const restore = (): void => {
      try {
        const scroller = mode === 'waterfall' ? this.waterfallScroller : this.fileListScroller
        scroller.scrollTo({
          xOffset: offset.xOffset,
          yOffset: offset.yOffset,
          animation: false
        })
      } catch (error) {
        // The content node can need one layout pass after the viewer is
        // removed. The delayed retry below handles that normal lifecycle gap.
        console.warn('[UgreenScroll] restore viewer return position failed: ' +
          JSON.stringify(error))
      }
    }
    this.postRenderFrame((): void => {
      restore()
      this.postRenderFrame(restore)
    })
  }

  private viewerActiveLayer(entry: FileEntry): ViewerImageLayer {
    const state = this.imageVisualState(entry.path)
    return state.visibleLayer === 'original' && state.originalUri.length > 0 &&
      state.decodeState === 'displayed' ? 'original' : 'thumbnail'
  }

  private scrollViewerReturnSourceIntoView(entry: FileEntry): boolean {
    try {
      if (this.showSearch) {
        const searchIndex = this.searchResults.findIndex((item: FileEntry): boolean => {
          return item.path === entry.path
        })
        if (searchIndex < 0) {
          return false
        }
        // AUTO = 滚动最小距离使该项完整可见；已可见则不动。返回时不应把
        // 文件管理界面强行拽到中间。
        this.searchResultScroller.scrollToIndex(searchIndex + 1, false, ScrollAlign.AUTO)
        return true
      }
      if (this.screen !== 'files') {
        return false
      }
      const items = this.fileViewMode === 'waterfall' ? this.waterfallEntries : this.entries
      const index = items.findIndex((item: FileEntry): boolean => item.path === entry.path)
      if (index < 0) {
        return false
      }
      const childIndex = this.fileViewMode === 'list' ? index + 1 : index
      const scroller = this.fileViewMode === 'waterfall'
        ? this.waterfallScroller : this.fileListScroller
      this.scrollItemIntoContentBand(scroller, childIndex)
      return true
    } catch (error) {
      console.warn('[UgreenViewer] position return source failed: ' + JSON.stringify(error))
      return false
    }
  }

  /**
   * 返回查看器来源时用的滚动：目标项已经完整落在「顶栏下沿 ~ 底栏上沿」之间
   * 就完全不动；否则只滚动把它带进这条带子所需的最小距离（贴最近的边）。
   *
   * 不能直接用 ScrollAlign.AUTO：AUTO 只保证项在滚动容器视口里完整可见，而
   * 顶栏和底部悬浮栏是盖在列表上的，落在它们下面的项其实看不见，共享元素
   * 返回动画会飞到一个被遮挡的矩形。
   */
  private scrollItemIntoContentBand(scroller: Scroller, childIndex: number,
    attempt: number = 0): void {
    let itemY = 0
    let itemHeight = 0
    let hasRect = false
    try {
      const rect = scroller.getItemRect(childIndex)
      if (rect !== undefined && typeof rect.y === 'number' && rect.height > 0) {
        itemY = rect.y
        itemHeight = rect.height
        hasRect = true
      }
    } catch (_) {
      hasRect = false
    }
    if (!hasRect) {
      // 目标还没挂载：先滚进视口，下一帧拿到真实矩形后再按可视带校正。
      if (attempt === 0) {
        try {
          scroller.scrollToIndex(childIndex, false, ScrollAlign.AUTO)
        } catch (_) {
        }
        setTimeout((): void => {
          this.scrollItemIntoContentBand(scroller, childIndex, attempt + 1)
        }, 48)
      }
      return
    }
    // 列表视口从状态栏下方开始，所以可视带上沿就是顶栏高度本身（topSafeInset+94
    // 减去视口起点 topSafeInset）。
    const bandTop = 94
    const bandBottom = this.pageHeightVp - this.floatingBarContentInset(0) - this.topSafeInset()
    let delta = 0
    if (itemY < bandTop) {
      delta = itemY - bandTop
    } else if (itemY + itemHeight > bandBottom) {
      delta = itemY + itemHeight - bandBottom
    }
    if (Math.abs(delta) < 0.5) {
      return
    }
    try {
      scroller.scrollBy(0, delta)
    } catch (error) {
      console.warn('[UgreenScroll] content band scroll failed: ' + JSON.stringify(error))
    }
  }

  private async prepareViewerReturnSource(entry: FileEntry): Promise<boolean> {
    if (!this.scrollViewerReturnSourceIntoView(entry)) {
      this.viewerReturnReadyPath = ''
      return false
    }
    // A page reached by Swiper may not have been the opening source.  Decode
    // its local preview before binding the return id so the target Image uses
    // the same PixelMap as the viewer, never a URI-decoded substitute.
    await this.ensureViewerPreviewBitmap(entry)
    for (let frame = 0; frame < IMAGE_RETURN_MOUNT_FRAME_LIMIT; frame += 1) {
      await this.nextRenderFrame()
      if (!this.showImageViewer || this.viewerImageEntry === null ||
        this.viewerImageEntry.path !== entry.path) {
        return false
      }
      if (this.hasViewerTransitionSource(entry, true)) {
        this.viewerReturnReadyPath = entry.path
        return true
      }
    }
    this.viewerReturnReadyPath = ''
    return false
  }

  private releaseViewerVisualSession(entries: FileEntry[]): void {
    const nextStates: Record<string, ImageVisualState> = {}
    for (const key of Object.keys(this.imageVisualStates)) {
      nextStates[key] = this.imageVisualStates[key]
    }
    for (const entry of entries) {
      const next = this.copyImageVisualState(this.imageVisualStates[entry.path])
      next.originalUri = ''
      next.originalOrientation = ImageRotateOrientation.AUTO
      next.physicalWidth = 0
      next.physicalHeight = 0
      next.exifDisplayWidth = 0
      next.exifDisplayHeight = 0
      next.displayWidth = 0
      next.displayHeight = 0
      next.frameLocked = false
      next.frameWidth = next.thumbnailDisplayWidth
      next.frameHeight = next.thumbnailDisplayHeight
      next.decodeState = 'idle'
      next.visibleLayer = 'thumbnail'
      next.progress = 0
      next.progressKnown = false
      nextStates[entry.path] = next
    }
    this.imageVisualStates = nextStates
  }

  private finishCloseImageViewer(shouldRestoreSearch: boolean): void {
    if (!this.viewerClosePending) {
      return
    }
    const closingImages = this.viewerImages.slice()
    const returnedEntry = this.viewerImageEntry
    this.clearViewerEntryTransition()
    this.releaseViewerVisualSession(closingImages)
    this.releaseViewerSessionBitmaps(closingImages).catch((error: Error): void => {
      console.warn('[UgreenBitmap] viewer release failed: ' + JSON.stringify(error))
    })
    this.viewerClosePending = false
    this.viewerCloseRequested = false
    this.viewerReturnReadyPath = ''
    this.isBusy = false
    this.viewerImageEntry = null
    this.viewerHeaderTitle = ''
    this.replaceViewerImages([])
    this.viewerImageIndex = 0
    this.showImageMoreMenu = false
    this.showImageDetails = false
    this.viewerOverlayEntry = null
    this.viewerLastNavigationDirection = 1
    this.viewerProgressLastUpdateAt = {}
    this.viewerRevealTokens = {}
    this.viewerPendingBitmapReveals = {}
    this.viewerPendingRotationPath = ''
    this.viewerBottomBarWidthVp = 0
    this.viewerTransitionActive = false
    this.imageChromeVisible = true
    this.imageChromeOpacity = 1
    this.imageTopChromeOffsetY = 0
    this.imageBottomChromeOffsetY = 0
    this.viewerSurfaceOpacity = 1
    this.viewerFallbackEntryActive = false
    this.resetImageTransform()
    if (shouldRestoreSearch) {
      this.restoreSearchSession()
    }
    this.postRenderFrame((): void => {
      if (returnedEntry !== null) {
        this.loadEntryPreview(returnedEntry, 0)
      }
      this.schedulePreviewWarmup(this.previewGeneration)
    })
  }

  private closeImageViewer(): void {
    if (this.viewerClosePending) {
      return
    }
    if (this.viewerTransitionActive ||
      (this.viewerEntryTransitionActive && this.viewerTransitionKind === 'entry')) {
      this.viewerCloseRequested = true
      this.setImageChromeVisible(false, false)
      return
    }
    this.beginCloseImageViewer()
  }

  private async beginCloseImageViewer(): Promise<void> {
    if (this.viewerClosePending || !this.showImageViewer || this.viewerImageEntry === null) {
      return
    }
    const shouldRestoreSearch = this.searchSession !== null && this.searchSession.returnMode === 'image'
    const returningEntry = this.viewerImageEntry as FileEntry
    const keepFileSurfacePosition = this.screen === 'files' &&
      !this.showSearch && this.currentPath.length > 0
    this.viewerClosePending = true
    this.isBusy = true
    this.setImageChromeVisible(false, false)
    const returnReady = await this.prepareViewerReturnSource(returningEntry)
    if (!this.showImageViewer) {
      return
    }
    this.logViewerDiagnostic(returnReady ? 'return-source-ready' : 'return-fallback',
      returningEntry.path)
    if (!this.showImageViewer || this.viewerImageEntry === null ||
      this.viewerImageEntry.path !== returningEntry.path) {
      return
    }
    const lockedLayer = this.viewerActiveLayer(returningEntry)
    const canUseGeometryTransition = returnReady &&
      this.startViewerExitTransition(returningEntry, lockedLayer)
    this.logViewerDiagnostic(canUseGeometryTransition ? 'exit-source-bound' : 'exit-fallback',
      returningEntry.path)
    this.restoreImageViewerOrientation()
    this.viewerGeneration += 1
    this.viewerLoadQueue = []
    this.viewerLoadRequests = {}
    this.viewerManualLoadPaths = {}
    this.viewerActiveLoads = 0
    this.viewerActiveLoadPaths = {}
    this.viewerPrimaryPath = ''
    this.viewerPendingIndex = -1
    this.lastImageDoubleTapAt = 0

    const closeGeneration = this.viewerGeneration
    if (canUseGeometryTransition) {
      // First frame removes the inactive progressive layer. The second frame
      // commits the id on the one visible Image before the hierarchy swap.
      await this.nextRenderFrame()
      this.viewerGeometryBound = true
      await this.nextRenderFrame()
      await new Promise<void>((resolve: () => void): void => {
        this.getUIContext().animateTo({
          duration: IMAGE_GEOMETRY_TRANSITION_DURATION,
          curve: Curve.FastOutSlowIn,
          onFinish: resolve
        }, () => {
          this.showImageViewer = false
          if (!keepFileSurfacePosition) {
            this.restoreViewerReturnScrollPosition()
          }
        })
      })
    } else {
      // An offscreen/unmounted source gets a single-image shrink and fade;
      // it never flies to a stale rectangle from another Swiper page.
      await new Promise<void>((resolve: () => void): void => {
        this.getUIContext().animateTo({
          duration: IMAGE_FALLBACK_TRANSITION_DURATION,
          curve: Curve.EaseIn,
          onFinish: resolve
        }, () => {
          this.imageDismissScale = Math.min(this.imageDismissScale, 0.94)
          this.viewerSurfaceOpacity = 0
        })
      })
      this.showImageViewer = false
      if (!keepFileSurfacePosition) {
        this.restoreViewerReturnScrollPosition()
      }
    }
    await this.nextRenderFrame()
    if (closeGeneration === this.viewerGeneration) {
      this.finishCloseImageViewer(shouldRestoreSearch)
    }
  }

  private setImageChromeVisible(visible: boolean, animated: boolean = true): void {
    this.imageChromeVisible = visible
    this.imageChromeAnimationToken += 1
    const token = this.imageChromeAnimationToken
    const targetOpacity = visible ? 1 : 0
    const targetTopOffset = visible ? 0 : -(this.topSafeInset() + 110)
    const targetBottomOffset = visible ? 0 : 130
    if (!animated) {
      this.imageChromeOpacity = targetOpacity
      this.imageTopChromeOffsetY = targetTopOffset
      this.imageBottomChromeOffsetY = targetBottomOffset
      return
    }
    this.getUIContext().animateTo({
      duration: 120,
      curve: visible ? Curve.EaseOut : Curve.EaseIn
    }, () => {
      if (token !== this.imageChromeAnimationToken) {
        return
      }
      this.imageChromeOpacity = targetOpacity
      this.imageTopChromeOffsetY = targetTopOffset
      this.imageBottomChromeOffsetY = targetBottomOffset
    })
  }

  private toggleImageChrome(): void {
    if (this.showImageViewer) {
      this.setImageChromeVisible(!this.imageChromeVisible)
    }
  }

  private handleImageTouch(event: TouchEvent, index: number): void {
    if (index !== this.viewerImageIndex) {
      return
    }
    const points = event.touches.length > 0 ? event.touches : event.changedTouches
    const point = points.length > 0 ? points[0] : null
    if (event.type === TouchType.Down) {
      this.imageTouchActive = true
      this.imageTouchMoved = false
      if (point !== null) {
        this.imageTouchStartX = point.x
        this.imageTouchStartY = point.y
      }
      return
    }
    if (event.type === TouchType.Move && this.imageTouchActive && point !== null) {
      const movedX = Math.abs(point.x - this.imageTouchStartX)
      const movedY = Math.abs(point.y - this.imageTouchStartY)
      if (movedX > 8 || movedY > 8) {
        this.imageTouchMoved = true
      }
      return
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.imageTouchActive = false
      this.imageTouchMoved = false
    }
  }

  private scheduleImageSingleTap(): void {
    if (this.imageTouchMoved || Date.now() - this.lastImageDoubleTapAt < 300) {
      return
    }
    // TapGesture has already completed HarmonyOS' built-in double-tap
    // arbitration (about 300 ms). Start the existing chrome animation now;
    // do not add a second application-level delay here.
    this.toggleImageChrome()
  }

  private handleImageDoubleTap(): void {
    this.lastImageDoubleTapAt = Date.now()
    if (this.viewerTransitionActive) {
      return
    }
    if (this.imageScale > 1.001) {
      this.animateImageTransform(1, 0, 0)
      return
    }
    this.animateImageTransform(2, 0, 0)
  }

  private imageDismissGestureEnabled(index: number): boolean {
    return this.showImageViewer && !this.viewerClosePending &&
      index === this.viewerImageIndex && this.imageScale <= 1.001 &&
      !this.viewerTransitionActive && !this.viewerEntryTransitionActive &&
      !this.showImageMoreMenu && !this.showImageDetails && !this.showRenameDialog
  }

  private resetImageDismissTransform(): void {
    this.imageDismissDragging = false
    this.imageDismissScale = 1
    this.imageDismissOffsetY = 0
    this.imageDismissBackdropOpacity = 1
  }

  private imageDismissProgress(offsetY: number): number {
    const dragRange = Math.max(1, this.imageViewportHeightVp * 0.42)
    return Math.min(1, Math.max(0, offsetY) / dragRange)
  }

  private startImageDismissClose(): void {
    if (this.viewerClosePending || !this.showImageViewer) {
      return
    }
    this.imageDismissDragging = false
    this.imageTouchMoved = true
    // Do not calculate a second destination from screen coordinates. The
    // current viewer frame is already the shared-element source; the file
    // surface is restored with the same geometryTransition id in the single
    // state change below. This makes the detail image fly to the real
    // thumbnail, including list/grid/waterfall positions.
    this.closeImageViewer()
  }

  private handleImageDismissStart(index: number): void {
    if (!this.imageDismissGestureEnabled(index)) {
      return
    }
    this.imageDismissChromeWasVisible = this.imageChromeVisible
    this.setImageChromeVisible(false, false)
    this.imageDismissDragging = true
    this.imageTouchMoved = true
  }

  private handleImageDismissUpdate(index: number, event: GestureEvent): void {
    // Eligibility is decided once in handleImageDismissStart. Rechecking the
    // whole predicate here made an already accepted vertical drag stop when
    // Swiper briefly changed viewerTransitionActive for a diagonal movement.
    if (!this.imageDismissDragging || !this.showImageViewer ||
      index !== this.viewerImageIndex || this.imageScale > 1.001) {
      return
    }
    // A downward pull is the dismiss gesture. Keep a small, resisted upward
    // movement so a slight reverse drag does not create a hard edge.
    const rawOffsetY = event.offsetY
    const effectiveOffsetY = rawOffsetY >= 0 ? rawOffsetY : rawOffsetY * 0.18
    const progress = this.imageDismissProgress(effectiveOffsetY)
    this.imageDismissOffsetY = effectiveOffsetY
    this.imageDismissScale = 1 - progress * IMAGE_DISMISS_MAX_SCALE_REDUCTION
    this.imageDismissBackdropOpacity = Math.max(0, 1 - progress * 1.25)
  }

  private animateImageDismissBack(): void {
    this.getUIContext().animateTo({
      curve: curves.interpolatingSpring(0, 1, 320, 30),
      onFinish: (): void => {
        if (this.imageDismissChromeWasVisible) {
          this.setImageChromeVisible(true, false)
        }
        this.flushDeferredViewerVisualCommits()
      }
    }, () => {
      this.imageDismissOffsetY = 0
      this.imageDismissScale = 1
      this.imageDismissBackdropOpacity = 1
    })
  }

  private handleImageDismissEnd(index: number, event: GestureEvent): void {
    if (!this.imageDismissDragging) {
      return
    }
    this.imageDismissDragging = false
    if (!this.showImageViewer || index !== this.viewerImageIndex ||
      this.imageScale > 1.001) {
      this.animateImageDismissBack()
      return
    }

    const offsetY = Math.max(0, this.imageDismissOffsetY)
    const triggerDistance = Math.max(120, this.imageViewportHeightVp * IMAGE_DISMISS_TRIGGER_RATIO)
    const fastEnough = offsetY >= IMAGE_DISMISS_FAST_TRIGGER_DISTANCE &&
      event.velocityY >= IMAGE_DISMISS_FAST_TRIGGER_VELOCITY
    if (offsetY >= triggerDistance || fastEnough) {
      this.startImageDismissClose()
      return
    }
    this.animateImageDismissBack()
  }

  private handleImageDismissCancel(): void {
    if (!this.imageDismissDragging) {
      return
    }
    this.imageDismissDragging = false
    this.animateImageDismissBack()
  }

  private animateImageTransform(targetScale: number, targetOffsetX: number, targetOffsetY: number): void {
    const scale = Math.min(5, Math.max(1, targetScale))
    this.getUIContext().animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
      this.imageScale = scale
      this.imageOffsetX = scale <= 1 ? 0 : targetOffsetX
      this.imageOffsetY = scale <= 1 ? 0 : targetOffsetY
      this.imageSavedScale = this.imageScale
      this.imageSavedOffsetX = this.imageOffsetX
      this.imageSavedOffsetY = this.imageOffsetY
    })
  }

  private handleImagePanEnd(event: GestureEvent): void {
    if (this.imageScale <= 1.001) {
      return
    }

    const maxX = Math.max(0, this.imageViewportWidthVp * (this.imageScale - 1) * 0.5)
    const maxY = Math.max(0, this.imageViewportHeightVp * (this.imageScale - 1) * 0.5)

    // PanGesture reports the release velocity. Project only a short, bounded
    // distance so a normal swipe gets a natural glide without throwing the
    // image across the whole viewport.
    const velocityX = Math.min(1800, Math.max(-1800, event.velocityX))
    const velocityY = Math.min(1800, Math.max(-1800, event.velocityY))
    const projectionTime = 0.10
    const projectedX = this.imageOffsetX + velocityX * projectionTime
    const projectedY = this.imageOffsetY + velocityY * projectionTime
    const targetX = Math.min(maxX, Math.max(-maxX, projectedX))
    const targetY = Math.min(maxY, Math.max(-maxY, projectedY))
    const deltaX = targetX - this.imageOffsetX
    const deltaY = targetY - this.imageOffsetY
    const travel = Math.sqrt(deltaX * deltaX + deltaY * deltaY)

    if (travel < 0.5) {
      this.normalizeImageTransform()
      return
    }

    // interpolatingSpring expects the initial velocity normalized by the
    // animated value change. Use the velocity along the actual travel path,
    // and cap it to keep the spring responsive rather than bouncy.
    const velocityAlongPath = (velocityX * deltaX + velocityY * deltaY) / travel
    const normalizedVelocity = Math.min(6, Math.max(-6, velocityAlongPath / travel))
    const springCurve = curves.interpolatingSpring(normalizedVelocity, 1, 260, 30)

    this.getUIContext().animateTo({ curve: springCurve }, () => {
      this.imageOffsetX = targetX
      this.imageOffsetY = targetY
      this.imageSavedOffsetX = targetX
      this.imageSavedOffsetY = targetY
    })
  }

  private handleImagePanCancel(): void {
    if (this.imageScale > 1) {
      this.normalizeImageTransform()
    }
  }

  private clampImageOffset(): void {
    if (this.imageScale <= 1) {
      this.imageOffsetX = 0
      this.imageOffsetY = 0
      return
    }
    const maxX = Math.max(0, this.imageViewportWidthVp * (this.imageScale - 1) * 0.5)
    const maxY = Math.max(0, this.imageViewportHeightVp * (this.imageScale - 1) * 0.5)
    this.imageOffsetX = Math.min(maxX, Math.max(-maxX, this.imageOffsetX))
    this.imageOffsetY = Math.min(maxY, Math.max(-maxY, this.imageOffsetY))
  }

  private normalizeImageTransform(): void {
    if (this.imageScale <= 1) {
      this.resetImageTransform()
      return
    }
    this.clampImageOffset()
    this.imageSavedScale = this.imageScale
    this.imageSavedOffsetX = this.imageOffsetX
    this.imageSavedOffsetY = this.imageOffsetY
  }

  private resetImageTransform(): void {
    this.imageScale = 1
    this.imageSavedScale = 1
    this.imageOffsetX = 0
    this.imageOffsetY = 0
    this.imageSavedOffsetX = 0
    this.imageSavedOffsetY = 0
    this.resetImageDismissTransform()
  }

  private imageEntriesInCurrentDirectory(): FileEntry[] {
    const imageEntries: FileEntry[] = []
    for (const item of this.entries) {
      if (!item.isDirectory && this.isImage(item)) {
        imageEntries.push(item)
      }
    }
    return imageEntries
  }

  private replaceViewerImages(nextImages: FileEntry[]): void {
    this.viewerImages = nextImages.slice()
    this.viewerImageDataSource.replace(this.viewerImages)
  }

  private appendViewerImages(allImages: FileEntry[]): void {
    const existing: Record<string, boolean> = {}
    for (const item of this.viewerImages) {
      existing[item.path] = true
    }
    const additions: FileEntry[] = []
    for (const item of allImages) {
      if (existing[item.path] === true) {
        continue
      }
      existing[item.path] = true
      additions.push(item)
    }
    if (additions.length === 0) {
      return
    }
    this.viewerImages = this.viewerImages.concat(additions)
    this.viewerImageDataSource.append(additions)
  }

  private onViewerImageChanged(index: number): void {
    if (index < 0 || index >= this.viewerImages.length) {
      return
    }
    const previousIndex = this.viewerImageIndex
    if (index > previousIndex) {
      // The image previously viewed is on the left; after deletion prefer right.
      this.viewerLastNavigationDirection = 1
    } else if (index < previousIndex) {
      // The image previously viewed is on the right; after deletion prefer left.
      this.viewerLastNavigationDirection = -1
    }
    this.viewerImageIndex = index
    this.viewerImageEntry = this.viewerImages[index]
    this.viewerHeaderTitle = this.viewerImages[index].name
    this.ensureViewerImageFrame(this.viewerImages[index])
    this.resetImageTransform()
    this.prefetchViewerImages(index)
    this.primeViewerFrameWindow(this.viewerImages, index, 2).catch((error: Error): void => {
      console.warn('[UgreenViewer] prepare frame window failed: ' + JSON.stringify(error))
    })
    this.viewerReturnReadyPath = ''
    this.prepareViewerReturnSource(this.viewerImages[index]).catch((error: Error): void => {
      console.warn('[UgreenViewer] prepare swiped return source failed: ' + JSON.stringify(error))
    })
  }

  private prefetchViewerImages(index: number): void {
    if (!this.showImageViewer || index < 0 || index >= this.viewerImages.length) {
      return
    }
    this.trimViewerOriginalState()
    this.viewerPrimaryPath = this.viewerImages[index].path
    // A newly selected image is allowed to join at once even if an old
    // adjacent prefetch is still finishing. The primary request is still
    // inserted first; the two neighbors are added only after it completes.
    this.viewerMaxConcurrentLoads = this.networkPolicy.isMetered() ? 1 : 3
    this.prioritizeViewerLoadTarget(index)
    if (index >= this.viewerImages.length - 3 && this.currentPageHasMore && !this.isBusy) {
      this.loadNextDirectoryPage()
    }
    const entry = this.viewerImages[index]
    if (this.viewerOriginalUri(entry).length === 0) {
      this.loadEntryPreview(entry)
    }
    if (this.shouldAutoLoadViewerOriginal()) {
      this.enqueueViewerOriginal(entry, true, false)
    } else {
      // A cached original is still safe to show on a metered network. This
      // path never starts a request when the file is not already local.
      this.loadViewerCachedOnly(entry, this.viewerGeneration)
    }
    if (this.viewerOriginalUri(entry).length > 0 && this.viewerImageDecoded(entry)) {
      this.startAdjacentViewerPrefetch(index, this.viewerGeneration)
    }
  }

  private startAdjacentViewerPrefetch(index: number, generation: number): void {
    if (!this.showImageViewer || generation !== this.viewerGeneration ||
      index < 0 || index >= this.viewerImages.length ||
      this.viewerImages[index].path !== this.viewerPrimaryPath ||
      !this.shouldAutoLoadViewerOriginal()) {
      return
    }
    // The current image has completed. Decode at most the previous and next
    // pages in parallel; this keeps the visible page single-flight while
    // warming exactly the pages a normal swipe is likely to reach.
    this.viewerMaxConcurrentLoads = this.networkPolicy.isMetered() ? 1 : 2
    const adjacentIndexes: number[] = []
    if (index - 1 >= 0) {
      adjacentIndexes.push(index - 1)
    }
    if (index + 1 < this.viewerImages.length) {
      adjacentIndexes.push(index + 1)
    }
    for (const adjacentIndex of adjacentIndexes) {
      const adjacent = this.viewerImages[adjacentIndex]
      this.loadEntryPreview(adjacent)
      this.primeViewerPreviewGeometry(adjacent).then(async (): Promise<void> => {
        await this.primeViewerOriginalFrame(adjacent)
        this.ensureViewerImageFrame(adjacent, false)
      }).catch((): void => {})
      this.enqueueViewerOriginal(adjacent, false, false)
    }
  }

  private shouldAutoLoadViewerOriginal(): boolean {
    if (this.networkClass === 'offline') {
      return false
    }
    return !this.networkPolicy.isMetered() || this.meteredAutoOriginal
  }

  private stopQueuedViewerAutoLoads(): void {
    const retained: FileEntry[] = []
    for (const item of this.viewerLoadQueue) {
      if (this.viewerManualLoadPaths[item.path] === true) {
        retained.push(item)
      } else {
        this.viewerLoadRequests[item.path] = false
        this.finishViewerOriginalLoading(item.path, false)
      }
    }
    this.viewerLoadQueue = retained
  }

  private prioritizeViewerLoadTarget(index: number): void {
    if (index < 0 || index >= this.viewerImages.length) {
      return
    }
    const targetPath = this.viewerImages[index].path
    const nextQueue: FileEntry[] = []
    let targetQueued = false
    for (const item of this.viewerLoadQueue) {
      if (item.path === targetPath && !targetQueued) {
        nextQueue.push(item)
        targetQueued = true
      } else if (item.path !== targetPath) {
        // This task is no longer the visible target. Its request flag is
        // cleared below so a later swipe can enqueue it again.
        this.viewerLoadRequests[item.path] = false
        this.finishViewerOriginalLoading(item.path, false)
      }
    }
    this.viewerLoadQueue = nextQueue
    for (const key of Object.keys(this.viewerLoadRequests)) {
      if (key !== targetPath && this.viewerActiveLoadPaths[key] !== true) {
        this.viewerLoadRequests[key] = false
        this.finishViewerOriginalLoading(key, false)
      }
    }
  }

  private trimViewerOriginalState(): void {
    // Keep only the visible page and its immediate Swiper neighbours.  A
    // PixelMap is a native raster, so retaining every image visited during a
    // long swipe session would defeat the viewer memory budget.
    const keepPaths: Record<string, boolean> = {}
    const centers: number[] = [this.viewerImageIndex, this.viewerPendingIndex]
    for (const center of centers) {
      if (center < 0 || center >= this.viewerImages.length) {
        continue
      }
      for (let index = Math.max(0, center - 2);
        index <= Math.min(this.viewerImages.length - 1, center + 2); index += 1) {
        keepPaths[this.viewerImages[index].path] = true
      }
    }
    for (const key of Object.keys(this.viewerOriginalBitmaps)) {
      if (keepPaths[key] === true || this.viewerActiveLoadPaths[key] === true) {
        continue
      }
      this.releaseViewerBitmap(this.viewerOriginalBitmaps, key).catch((): void => {})
      this.updateImageVisualState(key, (state: ImageVisualState): void => {
        state.originalUri = ''
        state.originalOrientation = ImageRotateOrientation.AUTO
        state.decodeState = 'idle'
        state.visibleLayer = 'thumbnail'
        state.progress = 0
        state.progressKnown = false
      })
    }

    const nextProgressTimes: Record<string, number> = {}
    for (const key of Object.keys(this.viewerProgressLastUpdateAt)) {
      if (keepPaths[key] === true) {
        nextProgressTimes[key] = this.viewerProgressLastUpdateAt[key]
      }
    }
    this.viewerProgressLastUpdateAt = nextProgressTimes

    this.viewerLoadQueue = this.viewerLoadQueue.filter((item: FileEntry): boolean => {
      const keep = keepPaths[item.path] === true
      if (!keep) {
        this.viewerLoadRequests[item.path] = false
        this.finishViewerOriginalLoading(item.path, false)
      }
      return keep
    })

    // A queued request can be removed by the adjacent-page window. Its old
    // boolean must not block a later swipe from enqueuing it again. Keep only
    // the request that is genuinely running; its finally block clears it.
    const nextLoadRequests: Record<string, boolean> = {}
    for (const key of Object.keys(this.viewerLoadRequests)) {
      if (keepPaths[key] === true || this.viewerActiveLoadPaths[key] === true) {
        nextLoadRequests[key] = this.viewerLoadRequests[key]
      }
    }
    this.viewerLoadRequests = nextLoadRequests
  }

  private async loadViewerOriginalManually(entry: FileEntry): Promise<void> {
    if (!this.showImageViewer || entry.isDirectory || this.isBusy ||
      this.viewerOriginalUri(entry).length > 0 || this.viewerLoadRequests[entry.path] === true) {
      return
    }
    await this.ensureNetworkState()
    if (this.networkClass === 'offline') {
      return
    }
    this.viewerPrimaryPath = entry.path
    this.viewerMaxConcurrentLoads = 1
    this.enqueueViewerOriginal(entry, true, true)
  }

  private async loadViewerCachedOnly(entry: FileEntry, generation: number): Promise<void> {
    try {
      await this.ensureCacheState()
      if (!this.showImageViewer || generation !== this.viewerGeneration) {
        return
      }
      const existingPath = CacheManager.findExisting(this.cacheDirectory, entry.name,
        this.originalCacheKey(entry))
      if (existingPath.length === 0) {
        return
      }
      this.markViewerOriginalLoading(entry.path)
      const record = await this.decodeViewerOriginalBitmap(entry, existingPath)
      if (record === null || !this.showImageViewer || generation !== this.viewerGeneration) {
        this.finishViewerOriginalLoading(entry.path, false)
        return
      }
      this.applyDecodedBitmapGeometry(entry.path, record, true)
      this.commitViewerBitmap(entry, existingPath, record)
    } catch (_) {
      this.finishViewerOriginalLoading(entry.path, false)
      // A missing/reclaimed cache entry is normal; the ring remains available.
    }
  }

  private async primeCachedViewerOriginal(entry: FileEntry, generation: number): Promise<void> {
    try {
      await this.ensureCacheState()
      if (generation !== this.viewerGeneration) {
        return
      }
      const existingPath = CacheManager.findExisting(this.cacheDirectory, entry.name,
        this.originalCacheKey(entry))
      if (existingPath.length === 0) {
        return
      }
      this.markViewerOriginalLoading(entry.path)
      const record = await this.decodeViewerOriginalBitmap(entry, existingPath)
      if (record === null || generation !== this.viewerGeneration || !this.showImageViewer) {
        this.finishViewerOriginalLoading(entry.path, false)
        return
      }
      this.applyDecodedBitmapGeometry(entry.path, record, true)
      this.commitViewerBitmap(entry, existingPath, record)
    } catch (error) {
      this.finishViewerOriginalLoading(entry.path, false)
      // A reclaimed cache entry simply falls back to the normal preview and
      // download path; it must not make opening the viewer fail.
      console.warn('[UgreenImage] cached-original fast path failed: ' + JSON.stringify(error))
    }
  }

  private async primeViewerPreviewGeometry(entry: FileEntry): Promise<void> {
    let localPath = this.previewLocalPaths[entry.path]
    let canonical = this.previewCanonicalPaths[entry.path] === true
    if (typeof localPath !== 'string' || localPath.length === 0 || !CacheManager.exists(localPath)) {
      const waterfallPath = this.waterfallLocalPaths[entry.path]
      if (typeof waterfallPath === 'string' && waterfallPath.length > 0) {
        localPath = waterfallPath
        canonical = false
      }
    }
    await this.primeViewerPreviewGeometryAtPath(entry, localPath, canonical)
  }

  private async primeViewerFrameWindow(entries: FileEntry[], center: number,
    radius: number): Promise<void> {
    const start = Math.max(0, center - radius)
    const end = Math.min(entries.length - 1, center + radius)
    for (let index = start; index <= end; index += 1) {
      await this.primeViewerPreviewGeometry(entries[index])
      await this.primeViewerOriginalFrame(entries[index])
      this.ensureViewerImageFrame(entries[index], false)
    }
  }

  private async primeViewerOriginalFrame(entry: FileEntry): Promise<void> {
    if (this.imageVisualState(entry.path).frameLocked || this.cacheDirectory.length === 0) {
      return
    }
    // Read only metadata from an already cached original before mounting the
    // page. The preview then fills this exact frame without stretching.
    const localPath = CacheManager.findExisting(this.cacheDirectory, entry.name,
      this.originalCacheKey(entry))
    if (localPath.length === 0) {
      return
    }
    const geometry = await this.readViewerImageGeometry(localPath, entry.path)
    if (geometry === null || this.imageVisualState(entry.path).frameLocked) {
      return
    }
    this.updateImageVisualState(entry.path, (state: ImageVisualState): void => {
      state.frameWidth = geometry.displayWidth
      state.frameHeight = geometry.displayHeight
      state.frameLocked = true
    })
  }

  private async primeViewerPreviewGeometryAtPath(entry: FileEntry, localPath: string,
    canonical: boolean = false): Promise<void> {
    if (typeof localPath !== 'string' || localPath.length === 0 || !CacheManager.exists(localPath)) {
      return
    }
    if ((this.showImageViewer || this.viewerEntryTransitionActive || this.viewerClosePending) &&
      localPath !== this.previewLocalPaths[entry.path]) {
      return
    }
    const geometry = await this.readViewerImageGeometry(localPath, entry.path)
    if (geometry === null) {
      return
    }
    this.updateImageVisualState(entry.path, (state: ImageVisualState): void => {
      state.physicalWidth = geometry.physicalWidth
      state.physicalHeight = geometry.physicalHeight
      state.exifDisplayWidth = geometry.exifDisplayWidth
      state.exifDisplayHeight = geometry.exifDisplayHeight
      state.displayWidth = geometry.displayWidth
      state.displayHeight = geometry.displayHeight
      if (!state.frameLocked) {
        state.thumbnailDisplayWidth = geometry.displayWidth
        state.thumbnailDisplayHeight = geometry.displayHeight
        state.frameWidth = geometry.displayWidth
        state.frameHeight = geometry.displayHeight
      }
      state.thumbnailOrientation = canonical
        ? ImageRotateOrientation.UP : ImageRotateOrientation.AUTO
    })
  }

  private previewOrientationSwapsAxes(orientation: ImageRotateOrientation): boolean {
    return orientation === ImageRotateOrientation.RIGHT ||
      orientation === ImageRotateOrientation.LEFT ||
      orientation === ImageRotateOrientation.RIGHT_MIRRORED ||
      orientation === ImageRotateOrientation.LEFT_MIRRORED
  }

  private enqueueViewerOriginal(entry: FileEntry, priority: boolean, manual: boolean): void {
    if (this.viewerOriginalUri(entry).length > 0 || this.viewerLoadRequests[entry.path] === true) {
      return
    }
    this.viewerLoadRequests[entry.path] = true
    this.viewerManualLoadPaths[entry.path] = manual
    this.markViewerOriginalLoading(entry.path)
    if (priority) {
      this.viewerLoadQueue.unshift(entry)
    } else {
      this.viewerLoadQueue.push(entry)
    }
    this.drainViewerLoadQueue()
  }

  private drainViewerLoadQueue(): void {
    while (this.showImageViewer && this.viewerActiveLoads < this.viewerMaxConcurrentLoads &&
      this.viewerLoadQueue.length > 0) {
      const entry = this.viewerLoadQueue.shift() as FileEntry
      const generation = this.viewerGeneration
      this.viewerActiveLoads += 1
      this.viewerActiveLoadPaths[entry.path] = true
      this.loadViewerOriginal(entry, generation)
    }
  }

  private async loadViewerOriginal(entry: FileEntry, generation: number): Promise<void> {
    let completed = false
    let failed = false
    try {
      const manual = this.viewerManualLoadPaths[entry.path] === true
      await this.ensureCacheState()
      const existingPath = CacheManager.findExisting(this.cacheDirectory, entry.name,
        this.originalCacheKey(entry))
      if (existingPath.length === 0 && !manual && !this.shouldAutoLoadViewerOriginal()) {
        return
      }
      const progressListener: BinaryProgressListener = (progress: BinaryDownloadProgress): void => {
        if (this.showImageViewer && generation === this.viewerGeneration) {
          this.updateViewerDownloadProgress(entry.path, progress)
        }
      }
      // Wi-Fi is an unrestricted transport for this viewer. Keep its
      // download on the same uninterrupted path as an explicit ring tap.
      // The continuation guard is only needed for automatic loading on a
      // metered network, where the user may turn the mobile-data switch off
      // while a request is already receiving bytes.
      const continueDownload = manual || !this.networkPolicy.isMetered()
        ? undefined
        : (): boolean => this.showImageViewer && this.shouldAutoLoadViewerOriginal()
      const localPath = existingPath.length > 0
        ? existingPath : await this.ensureCachedFile(entry, progressListener, continueDownload)
      if (!this.showImageViewer || generation !== this.viewerGeneration) {
        return
      }
      if (existingPath.length > 0) {
        this.setViewerDownloadProgress(entry.path, 95, true, true)
      }
      const record = await this.decodeViewerOriginalBitmap(entry, localPath)
      if (record === null || !this.showImageViewer || generation !== this.viewerGeneration) {
        return
      }
      this.applyDecodedBitmapGeometry(entry.path, record, true)
      this.commitViewerBitmap(entry, localPath, record)
      completed = true
    } catch (error) {
      if (error instanceof UgreenError && error.status === 499) {
        return
      }
      failed = true
      if (this.showImageViewer && generation === this.viewerGeneration) {
        this.finishViewerOriginalLoading(entry.path, true)
      }
      if (this.showImageViewer && generation === this.viewerGeneration &&
        this.viewerImageEntry !== null &&
        (this.viewerImageEntry as FileEntry).path === entry.path) {
        // Automatic WiFi preloading is best-effort. A failed background
        // request must not interrupt viewing with a download-error dialog;
        // the user can retry explicitly from the progress ring. Only an
        // explicit ring tap is allowed to surface the network error.
        this.setViewerDownloadProgress(entry.path, 0, false, true)
        if (this.viewerManualLoadPaths[entry.path] === true) {
          this.reportError(error as Object, '图片加载失败')
        } else {
          console.warn('[UgreenImage] automatic original preload failed: ' + JSON.stringify(error))
        }
      }
    } finally {
      if (generation === this.viewerGeneration) {
        if (!completed && !failed) {
          this.finishViewerOriginalLoading(entry.path, false)
        }
        this.viewerActiveLoads = Math.max(0, this.viewerActiveLoads - 1)
        this.viewerLoadRequests[entry.path] = false
        this.viewerActiveLoadPaths[entry.path] = false
        this.viewerManualLoadPaths[entry.path] = false
        this.drainViewerLoadQueue()
      }
    }
  }

  private async readViewerImageGeometry(localPath: string,
    entryPath: string = ''): Promise<ViewerImageGeometry | null> {
    let source: image.ImageSource | null = null
    let sourceFd: number = -1
    try {
      const sourceFile = fileIo.openSync(localPath, fileIo.OpenMode.READ_ONLY)
      sourceFd = sourceFile.fd
      source = image.createImageSource(sourceFd)
      const info = source.getImageInfoSync()
      const width = Math.floor(info.size.width)
      const height = Math.floor(info.size.height)
      if (width <= 0 || height <= 0) {
        return null
      }
      let orientation = 'unavailable'
      try {
        orientation = await source.getImageProperty(image.PropertyKey.ORIENTATION)
      } catch (_) {
        // Some image encoders do not expose EXIF. ArkUI still handles the
        // source with ImageRotateOrientation.AUTO when the image is rendered.
      }
      const mapped = this.mapExifOrientation(orientation)
      const exifDisplayWidth = this.previewOrientationSwapsAxes(mapped) ? height : width
      const exifDisplayHeight = this.previewOrientationSwapsAxes(mapped) ? width : height
      const userRotation = ((this.imageVisualState(entryPath).userRotation % 360) + 360) % 360
      const userSwapsAxes = userRotation === 90 || userRotation === 270
      const displayWidth = userSwapsAxes ? exifDisplayHeight : exifDisplayWidth
      const displayHeight = userSwapsAxes ? exifDisplayWidth : exifDisplayHeight
      console.info('[UgreenImage] source-metadata path=' + localPath +
        ' size=' + width.toString() + 'x' + height.toString() +
        ' exifDisplaySize=' + exifDisplayWidth.toString() + 'x' + exifDisplayHeight.toString() +
        ' displaySize=' + displayWidth.toString() + 'x' + displayHeight.toString() +
        ' orientation=' + orientation + ' userRotation=' + userRotation.toString())
      const geometry = new ViewerImageGeometry()
      geometry.physicalWidth = width
      geometry.physicalHeight = height
      geometry.exifDisplayWidth = exifDisplayWidth
      geometry.exifDisplayHeight = exifDisplayHeight
      geometry.displayWidth = displayWidth
      geometry.displayHeight = displayHeight
      geometry.orientation = mapped
      return geometry
    } catch (error) {
      console.warn('[UgreenImage] read source size failed: ' + JSON.stringify(error))
      return null
    } finally {
      if (source !== null) {
        try {
          await source.release()
        } catch (_) {
          // The source is only used for metadata; release failures are harmless.
        }
      }
      if (sourceFd >= 0) {
        try {
          fileIo.closeSync(sourceFd)
        } catch (_) {
          // The descriptor may already have been closed by the decoder.
        }
      }
    }
  }

  private viewerPreviewImageOrientation(entry: FileEntry): ImageRotateOrientation {
    // The file row and viewer preview must always consume one shared base
    // orientation. A cache release may replace the preview bytes, but it must
    // never replace this durable display metadata.
    // A canonical preview was generated from the normalized viewer source and
    // already has upright pixels. It must not receive the NAS correction a
    // second time.
    if (this.previewCanonicalPaths[entry.path] === true) {
      return ImageRotateOrientation.UP
    }
    return this.imageVisualState(entry.path).thumbnailOrientation
  }

  /**
   * Image Kit returns the EXIF labels documented by HarmonyOS. Map them to
   * ArkUI's orientation enum so the preview and original use one transform.
   */
  private mapExifOrientation(value: string): ImageRotateOrientation {
    const normalized = value.trim().toLowerCase()
    if (normalized === 'top-left' || normalized === '1') {
      return ImageRotateOrientation.UP
    }
    if (normalized === 'top-right' || normalized === '2') {
      return ImageRotateOrientation.UP_MIRRORED
    }
    if (normalized === 'bottom-right' || normalized === '3') {
      return ImageRotateOrientation.DOWN
    }
    if (normalized === 'bottom-left' || normalized === '4') {
      return ImageRotateOrientation.DOWN_MIRRORED
    }
    if (normalized === 'left-top' || normalized === '5') {
      return ImageRotateOrientation.LEFT_MIRRORED
    }
    if (normalized === 'right-top' || normalized === '6') {
      return ImageRotateOrientation.RIGHT
    }
    if (normalized === 'right-bottom' || normalized === '7') {
      return ImageRotateOrientation.RIGHT_MIRRORED
    }
    if (normalized === 'left-bottom' || normalized === '8') {
      return ImageRotateOrientation.LEFT
    }
    return ImageRotateOrientation.AUTO
  }

  private viewerVisualCommitBlocked(_path: string): boolean {
    return this.viewerClosePending || this.viewerEntryTransitionActive ||
      this.viewerTransitionActive || this.imageDismissDragging
  }

  private commitViewerBitmap(entry: FileEntry, localPath: string,
    record: ViewerBitmapRecord): void {
    const path = entry.path
    if (path.length === 0 || !this.isViewerPathNearCurrent(path)) {
      return
    }
    if (record.userRotation !== this.imageVisualState(path).userRotation) {
      if (this.viewerOriginalBitmaps[path] === record) {
        this.removeViewerBitmap(this.viewerOriginalBitmaps, path)
      }
      this.viewerBitmapStore.release(record).catch((): void => {})
      return
    }
    this.viewerOriginalLocalPaths[path] = localPath
    this.applyDecodedBitmapGeometry(path, record, true)
    this.updateImageVisualState(path, (state: ImageVisualState): void => {
      state.originalUri = fileUri.getUriFromPath(localPath)
      state.originalOrientation = ImageRotateOrientation.UP
      state.decodeState = 'decoded'
      state.visibleLayer = 'thumbnail'
      state.progress = 95
      state.progressKnown = true
    })
    this.setViewerDownloadProgress(path, 95, true, true)
    this.viewerPendingBitmapReveals[path] = true
    const token = (this.viewerRevealTokens[path] === undefined
      ? 0 : this.viewerRevealTokens[path]) + 1
    this.viewerRevealTokens[path] = token
    this.logViewerDiagnostic('original-pixelmap-decoded', path)
    if (!this.viewerVisualCommitBlocked(path)) {
      this.scheduleViewerBitmapReveal(path, token)
    }
  }

  private commitViewerBitmapReveal(path: string, token: number): void {
    if (this.viewerRevealTokens[path] !== token || !this.showImageViewer ||
      this.viewerVisualCommitBlocked(path)) {
      return
    }
    const record = this.viewerOriginalBitmaps[path]
    if (record === undefined) {
      return
    }
    this.updateImageVisualState(path, (next: ImageVisualState): void => {
      // With no cached original at entry, its true geometry becomes available
      // only now. Publish geometry and pixels together, after shared-element,
      // swipe and dismiss animations have finished (guarded above).
      next.frameWidth = record.displayWidth
      next.frameHeight = record.displayHeight
      next.frameLocked = true
      next.visibleLayer = 'original'
      next.decodeState = 'displayed'
      next.progress = 100
      next.progressKnown = true
    })
    this.viewerPendingBitmapReveals[path] = false
    this.logViewerDiagnostic('original-pixelmap-displayed', path)
    if (path === this.viewerPrimaryPath) {
      const primaryIndex = this.viewerImages.findIndex((item: FileEntry): boolean => item.path === path)
      if (primaryIndex >= 0) {
        this.startAdjacentViewerPrefetch(primaryIndex, this.viewerGeneration)
      }
    }
  }

  private isViewerPathNearCurrent(path: string): boolean {
    const indexes: number[] = []
    const addWindow = (center: number): void => {
      if (center < 0 || center >= this.viewerImages.length) {
        return
      }
      for (let index = Math.max(0, center - 1);
        index <= Math.min(this.viewerImages.length - 1, center + 1); index += 1) {
        if (indexes.indexOf(index) < 0) {
          indexes.push(index)
        }
      }
    }
    addWindow(this.viewerImageIndex)
    addWindow(this.viewerPendingIndex)
    for (const index of indexes) {
      if (this.viewerImages[index].path === path) {
        return true
      }
    }
    return false
  }

  private scheduleViewerBitmapReveal(path: string, token: number): void {
    // Keep the preview in one submitted frame, then swap the source of the
    // same Image node and close the progress ring from the official callback.
    this.postRenderFrame((): void => this.commitViewerBitmapReveal(path, token))
  }

  private markViewerImageFailed(path: string): void {
    if (!this.showImageViewer || this.imageVisualState(path).originalUri.length === 0) {
      return
    }
    this.updateImageVisualState(path, (next: ImageVisualState): void => {
      next.decodeState = 'failed'
      next.visibleLayer = 'thumbnail'
    })
    this.setViewerDownloadProgress(path, 0, false, true)
  }

  private flushDeferredViewerVisualCommits(): void {
    if (!this.showImageViewer || this.viewerClosePending ||
      this.viewerEntryTransitionActive || this.viewerTransitionActive ||
      this.imageDismissDragging) {
      return
    }
    for (const path of Object.keys(this.viewerPendingBitmapReveals)) {
      if (this.viewerPendingBitmapReveals[path] !== true ||
        this.viewerOriginalBitmaps[path] === undefined) {
        continue
      }
      const token = (this.viewerRevealTokens[path] === undefined
        ? 0 : this.viewerRevealTokens[path]) + 1
      this.viewerRevealTokens[path] = token
      this.scheduleViewerBitmapReveal(path, token)
    }
    if (this.viewerPendingRotationPath.length > 0) {
      const rotationEntry = this.viewerImages.find((item: FileEntry): boolean => {
        return item.path === this.viewerPendingRotationPath
      })
      this.viewerPendingRotationPath = ''
      if (rotationEntry !== undefined) {
        this.applyViewerRotation(rotationEntry)
      }
    }
  }

  private async persistPlaybackPreferences(): Promise<void> {
    try {
      if (this.playbackPreferences === null) {
        await this.ensurePlaybackState()
      }
      if (this.playbackPreferences === null) {
        return
      }
      await this.playbackPreferences.put('background_video_playback', this.backgroundVideoPlayback)
      await this.playbackPreferences.put('background_audio_playback', this.backgroundAudioPlayback)
      await this.playbackPreferences.put('video_background_auto_pip', this.videoBackgroundAutoPip)
      await this.playbackPreferences.put('auto_play_on_open', this.autoPlayOnOpen)
      await this.playbackPreferences.flush()
    } catch (error) {
      console.warn('[UgreenPlayback] save preferences failed: ' + JSON.stringify(error))
    }
  }

  private async setBackgroundVideoPlayback(value: boolean): Promise<void> {
    this.backgroundVideoPlayback = value
    if (!value && this.videoBackgroundAutoPip) {
      // Automatic PiP is a form of video background playback. Do not leave a
      // visually contradictory enabled switch after the parent option is off.
      this.videoBackgroundAutoPip = false
    }
    if (!value && this.showVideoPlayer && this.videoPlaying) {
      this.pauseVideoFromMediaSession(true)
    }
    await this.persistPlaybackPreferences()
  }

  private async setBackgroundAudioPlayback(value: boolean): Promise<void> {
    this.backgroundAudioPlayback = value
    if (!value && this.showAudioPlayer && this.audioPlaying) {
      this.audioManager.pause().then((): void => {
        this.audioPlaying = false
      }).catch((error: Object): void => {
        console.warn('[UgreenAudio] setting background playback failed: ' +
          JSON.stringify(error))
      })
    }
    await this.persistPlaybackPreferences()
  }

  private async setVideoBackgroundAutoPip(value: boolean): Promise<void> {
    if (value && !this.backgroundVideoPlayback) {
      this.showImmersiveToast('请先开启视频后台播放')
      this.videoBackgroundAutoPip = false
      return
    }
    this.videoBackgroundAutoPip = value
    await this.persistPlaybackPreferences()
  }

  private async setAutoPlayOnOpen(value: boolean): Promise<void> {
    this.autoPlayOnOpen = value
    await this.persistPlaybackPreferences()
  }

  private async loadVideoState(): Promise<void> {
    try {
      await this.ensureCacheState()
      const context = getContext(this) as Context
      // Register before initialization so restored cache/download records are
      // reflected in the file rows during the first render.
      this.videoTransferManager.onChange(this.videoTransferStateListener)
      await this.videoTransferManager.initialize(context, this.repository,
        this.cacheDirectory, this.cacheLimitBytes)
    } catch (error) {
      console.warn('[UgreenVideo] initialize failed: ' + JSON.stringify(error))
    }
  }

  private async refreshVideoManager(): Promise<void> {
    await this.ensureVideoState()
    await this.ensureCacheState()
    const context = getContext(this) as Context
    await this.videoTransferManager.initialize(context, this.repository,
      this.cacheDirectory, this.cacheLimitBytes)
  }

  private committedViewerActionEntry(action: string): FileEntry | null {
    if (!this.showImageViewer || this.viewerClosePending) {
      return null
    }
    const entry = this.committedViewerEntry()
    if (entry !== null) {
      this.logViewerDiagnostic('action-' + action, entry.path)
    }
    return entry
  }

  private async saveCommittedViewerImage(): Promise<void> {
    const entry = this.committedViewerActionEntry('save')
    if (entry !== null) {
      await this.saveViewerImage(entry)
    }
  }

  private async shareCommittedViewerImage(): Promise<void> {
    const entry = this.committedViewerActionEntry('share')
    if (entry !== null) {
      await this.shareViewerImage(entry)
    }
  }

  private async deleteCommittedViewerImage(): Promise<void> {
    const entry = this.committedViewerActionEntry('delete')
    if (entry !== null) {
      await this.deleteViewerImage(entry)
    }
  }

  private async loadCommittedViewerOriginalManually(): Promise<void> {
    const entry = this.committedViewerActionEntry('load-original')
    if (entry !== null) {
      await this.loadViewerOriginalManually(entry)
    }
  }

  private async saveViewerImage(entry: FileEntry): Promise<void> {
    this.closeImageMoreMenu()
    this.closeImageDetails()
    await this.saveToGallery(entry)
  }

  private openImageMoreMenu(): void {
    if (!this.showImageViewer || this.isBusy) {
      return
    }
    const entry = this.committedViewerActionEntry('more')
    if (entry === null) {
      return
    }
    this.viewerOverlayEntry = entry
    this.showImageDetails = false
    this.showImageMoreMenu = true
  }

  private closeImageMoreMenu(): void {
    this.showImageMoreMenu = false
    this.viewerOverlayEntry = null
  }

  private rotateViewerOverlayImage(): void {
    const entry = this.viewerOverlayEntry
    if (entry !== null) {
      this.rotateViewerImage(entry)
    }
  }

  private openViewerOverlayWithOtherApp(): void {
    const entry = this.viewerOverlayEntry
    if (entry === null) {
      return
    }
    this.closeImageMoreMenu()
    this.openWithOtherApp(entry)
  }

  private openRenameFromViewerOverlay(): void {
    const entry = this.viewerOverlayEntry
    if (entry === null || !this.showImageViewer || this.isBusy) {
      return
    }
    this.showImageMoreMenu = false
    this.showImageDetails = false
    this.viewerOverlayEntry = null
    this.openRename(entry)
  }

  private rotateViewerImage(entry: FileEntry): void {
    if (!this.showImageViewer || this.isBusy) {
      return
    }
    this.closeImageMoreMenu()
    if (this.viewerVisualCommitBlocked(entry.path)) {
      this.viewerPendingRotationPath = entry.path
      return
    }
    this.applyViewerRotation(entry)
  }

  private async applyViewerRotation(entry: FileEntry): Promise<void> {
    const current = this.imageVisualState(entry.path).userRotation
    const nextRotation = (current + 90) % 360
    const path = entry.path
    const state = this.imageVisualState(path)
    let previewPath = this.previewLocalPaths[path]
    if (typeof previewPath !== 'string' || previewPath.length === 0 ||
      !CacheManager.exists(previewPath)) {
      previewPath = this.waterfallLocalPaths[path]
    }
    const originalPath = this.viewerOriginalLocalPaths[path]
    if ((typeof previewPath !== 'string' || previewPath.length === 0 ||
      !CacheManager.exists(previewPath)) && typeof originalPath === 'string' &&
      originalPath.length > 0 && CacheManager.exists(originalPath)) {
      previewPath = originalPath
    }
    if (typeof previewPath !== 'string' || previewPath.length === 0 ||
      !CacheManager.exists(previewPath)) {
      this.showImmersiveToast('图片旋转失败：预览缓存不可用')
      return
    }

    this.viewerTransitionActive = true
    this.isBusy = true
    // Publish the requested angle immediately, but keep the old PixelMaps and
    // frame visible. This invalidates every in-flight decode made for the old
    // transform without exposing a partially rotated visual state.
    this.updateImageVisualState(path, (pending: ImageVisualState): void => {
      pending.userRotation = nextRotation
    })
    const oldPreview = this.viewerPreviewBitmaps[path]
    const oldPreviewAlias = this.viewerPreviewBitmapAliases[path] === true
    const oldOriginal = this.viewerOriginalBitmaps[path]
    const oldFile = this.fileThumbnailBitmaps[path]
    const oldWaterfall = this.waterfallBitmaps[path]
    let nextPreview: ViewerBitmapRecord | null = null
    let nextOriginal: ViewerBitmapRecord | null = null
    let nextFile: ViewerBitmapRecord | null = null
    let nextWaterfall: ViewerBitmapRecord | null = null
    let committed = false
    try {
      nextPreview = await this.viewerBitmapStore.decode(previewPath, 'viewerPreview', nextRotation)
      nextFile = await this.viewerBitmapStore.decode(previewPath, 'list', nextRotation)
      if (typeof originalPath === 'string' && originalPath.length > 0 &&
        CacheManager.exists(originalPath)) {
        nextOriginal = await this.viewerBitmapStore.decode(originalPath, 'viewerZoom', nextRotation)
      }
      const waterfallPath = this.waterfallLocalPaths[path]
      if (typeof waterfallPath === 'string' && waterfallPath.length > 0 &&
        CacheManager.exists(waterfallPath)) {
        nextWaterfall = await this.viewerBitmapStore.decode(waterfallPath,
          'viewerPreview', nextRotation)
      }
      const visibleRecord = state.visibleLayer === 'original' ? nextOriginal : nextPreview
      if (visibleRecord === null || nextPreview === null || nextFile === null ||
        (oldOriginal !== undefined && nextOriginal === null)) {
        throw new Error('rotated PixelMap decode did not produce the active visual layer')
      }
      if (!this.showImageViewer || this.viewerImageEntry === null ||
        this.viewerImageEntry.path !== path || this.viewerClosePending) {
        return
      }
      await this.nextRenderFrame()
      this.installViewerBitmap(this.viewerPreviewBitmaps, path, nextPreview)
      this.viewerPreviewBitmapAliases[path] = false
      if (nextOriginal !== null) {
        this.installViewerBitmap(this.viewerOriginalBitmaps, path, nextOriginal)
      } else if (oldOriginal !== undefined) {
        this.removeViewerBitmap(this.viewerOriginalBitmaps, path)
      }
      const nextFileMaps: Record<string, ViewerBitmapRecord> = {}
      for (const key of Object.keys(this.fileThumbnailBitmaps)) {
        if (key !== path) {
          nextFileMaps[key] = this.fileThumbnailBitmaps[key]
        }
      }
      nextFileMaps[path] = nextFile
      this.fileThumbnailBitmaps = nextFileMaps
      this.fileThumbnailDecodeKeys[path] = previewPath + '|' + this.previewSignature(entry) +
        '|rotation=' + nextRotation.toString()
      if (nextWaterfall !== null) {
        this.installViewerBitmap(this.waterfallBitmaps, path, nextWaterfall)
        this.waterfallDecodedPaths[path] = true
        this.setWaterfallAspectRatio(path, nextWaterfall.displayWidth,
          nextWaterfall.displayHeight)
      } else {
        if (oldWaterfall !== undefined) {
          this.removeViewerBitmap(this.waterfallBitmaps, path)
          this.waterfallDecodedPaths[path] = false
        }
        this.setWaterfallAspectRatio(path, visibleRecord.displayWidth, visibleRecord.displayHeight)
      }
      this.updateImageVisualState(path, (next: ImageVisualState): void => {
        next.userRotation = nextRotation
        next.rotationResolved = true
        next.physicalWidth = visibleRecord.physicalWidth
        next.physicalHeight = visibleRecord.physicalHeight
        next.exifDisplayWidth = visibleRecord.exifDisplayWidth
        next.exifDisplayHeight = visibleRecord.exifDisplayHeight
        next.displayWidth = visibleRecord.displayWidth
        next.displayHeight = visibleRecord.displayHeight
        next.thumbnailDisplayWidth = nextFile!.displayWidth
        next.thumbnailDisplayHeight = nextFile!.displayHeight
        next.frameWidth = visibleRecord.displayWidth
        next.frameHeight = visibleRecord.displayHeight
        next.frameLocked = true
      })
      this.fileListRotationGeneration += 1
      this.bumpViewerBitmapEpoch()
      this.resetImageTransform()
      this.persistViewerRotation(entry, nextRotation)
      committed = true
      await this.nextRenderFrame()
      if (oldPreview !== undefined && !oldPreviewAlias && oldPreview !== nextPreview) {
        await this.viewerBitmapStore.release(oldPreview)
      }
      if (oldOriginal !== undefined && oldOriginal !== nextOriginal) {
        await this.viewerBitmapStore.release(oldOriginal)
      }
      if (oldFile !== undefined && oldFile !== nextFile) {
        await this.viewerBitmapStore.release(oldFile)
      }
      if (oldWaterfall !== undefined && oldWaterfall !== nextWaterfall) {
        await this.viewerBitmapStore.release(oldWaterfall)
      }
    } catch (error) {
      console.warn('[UgreenImage] rotate PixelMap failed: ' + JSON.stringify(error))
      this.showImmersiveToast('图片旋转失败')
    } finally {
      if (!committed) {
        this.updateImageVisualState(path, (rollback: ImageVisualState): void => {
          rollback.userRotation = current
        })
        await this.viewerBitmapStore.release(nextPreview)
        await this.viewerBitmapStore.release(nextOriginal)
        await this.viewerBitmapStore.release(nextFile)
        await this.viewerBitmapStore.release(nextWaterfall)
      }
      this.viewerTransitionActive = false
      this.isBusy = false
      this.flushDeferredViewerVisualCommits()
      if (this.viewerCloseRequested && this.showImageViewer) {
        this.viewerCloseRequested = false
        this.postRenderFrame((): void => this.closeImageViewer())
      }
    }
  }

  private openImageDetails(): void {
    if (!this.showImageViewer || this.isBusy || this.viewerOverlayEntry === null) {
      return
    }
    this.showImageMoreMenu = false
    this.showImageDetails = true
  }

  private closeImageDetails(): void {
    this.showImageDetails = false
    this.viewerOverlayEntry = null
  }

  private async shareViewerImage(entry: FileEntry): Promise<void> {
    if (this.isBusy || entry.isDirectory) {
      return
    }
    this.closeImageMoreMenu()
    this.closeImageDetails()
    if (!await this.confirmMeteredDownload(entry)) {
      return
    }
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在准备分享…'
    try {
      const localPath = await this.ensureCachedFile(entry)
      const context = getContext(this) as common.UIAbilityContext
      const sharedData = new systemShare.SharedData(this.shareRecord(entry, localPath))
      const shareController = new systemShare.ShareController(sharedData)
      await shareController.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DEFAULT
      })
      this.statusText = '已打开系统分享'
    } catch (error) {
      this.reportError(error as Object, '分享失败')
      this.statusText = '分享失败'
    } finally {
      this.isBusy = false
    }
  }

  private async deleteViewerImage(entry: FileEntry): Promise<void> {
    if (this.isBusy || !this.showImageViewer) {
      return
    }
    const deletedIndex = this.viewerImages.findIndex((item: FileEntry): boolean => {
      return item.path === entry.path
    })
    if (deletedIndex < 0) {
      return
    }
    const preferredDirection = this.viewerLastNavigationDirection >= 0 ? 1 : -1
    this.closeImageMoreMenu()
    this.closeImageDetails()
    const response = await promptAction.showDialog({
      title: '删除图片？',
      message: '图片会移入云盘回收站，可在云盘中恢复。',
      buttons: [
        { text: '取消', color: this.isDarkTheme ? '#FFFFFFFF' : '#536174' },
        { text: '删除', color: '#D34D5C' }
      ],
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false)
    })
    if (response.index !== 1) {
      return
    }

    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在移入云盘回收站…'
    try {
      await this.repository.trash(entry)
      await this.removePersistedViewerRotation(entry)
      await this.refreshCurrentDirectory()
      const remainingImages = this.imageEntriesInCurrentDirectory()
      if (remainingImages.length === 0) {
        this.closeImageViewer()
        this.statusText = '已移入回收站'
        this.showImmersiveToast('已移入云盘回收站')
        return
      }

      const targetIndex = preferredDirection > 0
        ? (deletedIndex < remainingImages.length ? deletedIndex : remainingImages.length - 1)
        : (deletedIndex > 0 ? deletedIndex - 1 : 0)
      const boundedIndex = Math.min(remainingImages.length - 1, Math.max(0, targetIndex))
      this.replaceViewerImages(remainingImages)
      this.viewerImageIndex = boundedIndex
      this.viewerImageEntry = remainingImages[boundedIndex]
      this.viewerHeaderTitle = remainingImages[boundedIndex].name
      this.viewerOverlayEntry = null
      const nextStates: Record<string, ImageVisualState> = {}
      for (const key of Object.keys(this.imageVisualStates)) {
        if (key !== entry.path) {
          nextStates[key] = this.imageVisualStates[key]
        }
      }
      this.imageVisualStates = nextStates
      this.viewerLoadQueue = this.viewerLoadQueue.filter((item: FileEntry) => item.path !== entry.path)
      this.viewerLoadRequests[entry.path] = false
      this.resetImageTransform()
      if (boundedIndex > deletedIndex) {
        this.viewerLastNavigationDirection = 1
      } else if (boundedIndex < deletedIndex) {
        this.viewerLastNavigationDirection = -1
      }
      this.ensureViewerImageFrame(remainingImages[boundedIndex])
      this.prefetchViewerImages(boundedIndex)
      this.prepareViewerReturnSource(remainingImages[boundedIndex]).catch((): void => {})
      this.statusText = '已移入回收站'
      this.showImmersiveToast('已移入云盘回收站')
    } catch (error) {
      this.reportError(error as Object, '删除失败')
      this.statusText = '删除失败'
    } finally {
      this.isBusy = false
    }
  }

  private async openAudioPlayer(entry: FileEntry): Promise<void> {
    if (this.isBusy || entry.isDirectory) {
      return
    }
    this.closeActionMenu()
    if (!await this.confirmMeteredDownload(entry)) {
      return
    }
    await this.ensurePlaybackState()
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在准备音频…'
    try {
      const localPath = await this.ensureCachedFile(entry)
      const coverPath = await this.mediaPreviewManager.fromLocal(entry, localPath,
        this.thumbnailDirectory, this.thumbnailCacheLimitBytes)
      if (coverPath.length > 0) {
        this.setPreviewUri(entry, fileUri.getUriFromPath(coverPath), coverPath)
      }
      this.audioEntry = entry
      this.audioLocalPath = localPath
      this.audioCurrentMs = 0
      this.audioDurationMs = 0
      this.audioPlaying = false
      this.showAudioPlayer = true
      await this.audioManager.open(
        localPath,
        (timeMs: number) => this.audioCurrentMs = Math.max(0, timeMs),
        (durationMs: number) => this.audioDurationMs = Math.max(0, durationMs),
        (state: string) => {
          this.audioPlaying = state === 'playing'
          if (state === 'completed') {
            this.audioCurrentMs = this.audioDurationMs
          }
        },
        (error: Object) => {
          this.reportError(error, '音频播放错误')
          this.statusText = '音频播放错误'
          this.audioPlaying = false
        }
      )
      if (this.autoPlayOnOpen) {
        await this.audioManager.play()
        this.statusText = '正在播放：' + entry.name
      } else {
        this.statusText = '已准备：' + entry.name
      }
    } catch (error) {
      await this.audioManager.release()
      this.showAudioPlayer = false
      this.audioEntry = null
      this.audioLocalPath = ''
      this.audioPlaying = false
      this.reportError(error as Object, '音频播放失败')
      this.statusText = '音频播放失败'
    } finally {
      this.isBusy = false
    }
  }

  /**
   * Opens one AVPlayer surface for a video.  The transfer manager owns the
   * source selection, cache/download hand-off, and the playback manager owns
   * the MediaKit player and its native network buffer; the page only
   * coordinates their lifetime and renders a poster until the first real
   * video frame arrives.
   */
  private async openVideoPlayer(entry: FileEntry): Promise<void> {
    if (this.isBusy || entry.isDirectory) {
      return
    }
    if (this.videoPipBackgrounded) {
      await this.stopVideoPipForReplacement()
    }
    this.closeActionMenu()
    this.closeImageMoreMenu()
    this.closeImageDetails()
    if (!await this.confirmMeteredDownload(entry)) {
      return
    }
    await this.ensurePlaybackState()

    const token = this.videoOpenToken + 1
    this.videoOpenToken = token
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在准备视频…'
    try {
      await this.refreshVideoManager()
      if (token !== this.videoOpenToken) {
        return
      }
      await this.videoPlaybackManager.release()
      const previousEntry = this.videoEntry
      if (previousEntry !== null && previousEntry.path !== entry.path) {
        await this.videoTransferManager.releaseSource(previousEntry)
      }
      const handle = await this.videoTransferManager.openSource(entry)
      if (token !== this.videoOpenToken) {
        await this.videoTransferManager.releaseSource(entry)
        return
      }
      const position = await this.videoTransferManager.playbackPosition(entry)
      this.videoSourceHandle = handle
      this.videoSourceKey = handle.sourceKey
      this.videoLocalPath = handle.localPath
      this.videoEntry = entry
      this.videoDurationMs = 0
      this.videoCurrentMs = position
      this.videoPlaying = false
      this.videoMuted = false
      this.videoPrepared = false
      this.videoLandscape = this.pageWidthVp > this.pageHeightVp
      this.videoControlPending = false
      this.videoCasting = false
      this.videoCastPreparing = false
      this.videoWasPlayingBeforeCast = false
      this.videoFirstFrame = false
      this.videoSurfaceReady = false
      this.videoWidthPx = 0
      this.videoHeightPx = 0
      this.videoBufferingPercent = 0
      this.videoPositionPersistAt = 0
      this.videoMediaSessionPositionAt = 0
      this.videoSurfaceWidthPx = 0
      this.videoSurfaceHeightPx = 0
      this.videoViewportWidthVp = this.pageWidthVp
      this.videoViewportHeightVp = this.pageHeightVp

      await this.videoPlaybackManager.open(handle, position, {
        onTime: (timeMs: number): void => {
          if (token !== this.videoOpenToken || this.videoEntry === null ||
            this.videoEntry.path !== entry.path) {
            return
          }
          this.videoCurrentMs = Math.max(0, timeMs)
          const now = Date.now()
          if (now - this.videoPositionPersistAt >= 500) {
            this.videoPositionPersistAt = now
            this.videoTransferManager.savePlaybackPosition(entry, this.videoCurrentMs)
              .catch((): void => {})
          }
          this.updateVideoMediaSession()
        },
        onDuration: (durationMs: number): void => {
          if (token === this.videoOpenToken && this.videoEntry !== null &&
            this.videoEntry.path === entry.path) {
            this.videoDurationMs = Math.max(0, durationMs)
            this.updateVideoMediaSession(true)
          }
        },
        onState: (state: media.AVPlayerState): void => {
          if (token !== this.videoOpenToken || this.videoEntry === null ||
            this.videoEntry.path !== entry.path) {
            return
          }
          this.videoPlaying = state === 'playing'
          this.syncVideoBackgroundTask()
          this.updateVideoPipControlStatus()
          if (state === 'prepared' || state === 'playing' || state === 'paused' ||
            state === 'completed') {
            this.videoPrepared = true
          }
          if (state === 'completed') {
            this.videoCurrentMs = this.videoDurationMs
            this.syncVideoBackgroundTask()
            this.videoTransferManager.savePlaybackPosition(entry, this.videoCurrentMs)
              .catch((): void => {})
          }
          if (state === 'error') {
            this.videoPrepared = false
            this.videoPlaying = false
            this.syncVideoBackgroundTask()
            this.statusText = '视频播放错误'
          }
          this.updateVideoMediaSession(true)
        },
        onBuffering: (percent: number): void => {
          if (token === this.videoOpenToken && this.videoEntry !== null &&
            this.videoEntry.path === entry.path) {
            this.videoBufferingPercent = Math.max(0, Math.min(100, percent))
            this.updateVideoMediaSession()
          }
        },
        onSize: (width: number, height: number): void => {
          if (token === this.videoOpenToken && this.videoEntry !== null &&
            this.videoEntry.path === entry.path) {
            this.videoWidthPx = width
            this.videoHeightPx = height
            this.updateVideoSurfaceRect()
            if (this.videoPipController !== null && width > 0 && height > 0) {
              try {
                this.videoPipController.updateContentSize(width, height)
              } catch (error) {
                console.warn('[UgreenVideo] update PiP content size failed: ' +
                  JSON.stringify(error))
              }
            }
            this.updateVideoMediaSession(true)
          }
        },
        onFirstFrame: (): void => {
          if (token === this.videoOpenToken && this.videoEntry !== null &&
            this.videoEntry.path === entry.path) {
            this.videoPrepared = true
            this.videoFirstFrame = true
            this.syncVideoBackgroundTask()
            this.updateVideoPipControlStatus()
            this.updateVideoMediaSession(true)
          }
        },
        onError: (error: Object): void => {
          if (token !== this.videoOpenToken || this.videoEntry === null ||
            this.videoEntry.path !== entry.path) {
            return
          }
          this.videoPrepared = false
          this.videoPlaying = false
          this.syncVideoBackgroundTask()
          this.statusText = '视频播放错误'
          this.updateVideoMediaSession(true)
          this.reportError(error, '视频播放失败')
        }
      }, this.autoPlayOnOpen)
      if (token !== this.videoOpenToken) {
        return
      }
      this.showVideoPlayer = true
      this.enableVideoPlayerAutoRotation()
      this.startVideoMediaSession(entry)
      this.syncVideoBackgroundTask()
      this.statusText = '正在准备视频…'
    } catch (error) {
      if (token === this.videoOpenToken) {
        await this.videoPlaybackManager.release()
        this.videoSourceHandle = null
        this.videoSourceKey = ''
        this.videoLocalPath = ''
        this.videoEntry = null
        this.showVideoPlayer = false
        this.videoPrepared = false
        this.videoFirstFrame = false
        this.videoPlaying = false
        this.videoCasting = false
        this.videoCastPreparing = false
        this.destroyVideoPipController()
        this.syncVideoBackgroundTask()
        this.videoMediaSession.close().catch((): void => {})
        this.reportError(error as Object, '视频播放失败')
        this.statusText = '视频播放失败'
      }
    } finally {
      if (token === this.videoOpenToken) {
        this.isBusy = false
      }
    }
  }

  private videoMediaSessionSnapshot(): VideoMediaPlaybackSnapshot {
    return {
      playing: this.videoPlaying,
      prepared: this.videoPrepared,
      completed: this.videoDurationMs > 0 && this.videoCurrentMs >= this.videoDurationMs,
      bufferingPercent: this.videoBufferingPercent,
      positionMs: this.videoCurrentMs,
      durationMs: this.videoDurationMs,
      muted: this.videoMuted,
      videoWidthPx: this.videoWidthPx,
      videoHeightPx: this.videoHeightPx
    }
  }

  private updateVideoMediaSession(force: boolean = false): void {
    if (!this.showVideoPlayer || this.videoEntry === null) {
      return
    }
    const now = Date.now()
    if (!force && now - this.videoMediaSessionPositionAt < 250) {
      return
    }
    this.videoMediaSessionPositionAt = now
    this.videoMediaSession.update(this.videoMediaSessionSnapshot())
  }

  private startVideoMediaSession(entry: FileEntry): void {
    const context = getContext(this) as Context
    const nextEntry = this.videoSibling(1)
    this.videoMediaSession.open(context, entry, nextEntry,
      this.videoMediaSessionSnapshot(), {
        onPlay: (): void => {
          this.playVideoFromMediaSession()
        },
        onPause: (): void => {
          this.pauseVideoFromMediaSession()
        },
        onStop: (): void => {
          this.stopVideoFromMediaSession()
        },
        onNext: (): void => {
          this.switchVideo(1).catch((error: Error): void => {
            console.warn('[UgreenAVSession] next video failed: ' + JSON.stringify(error))
          })
        },
        onSeek: (timeMs: number): void => {
          this.seekVideo(timeMs)
        },
        onCastConnected: (): void => {
          this.handleVideoCastConnected().catch((error: Object): void => {
            console.warn('[UgreenVideo] cast connection handling failed: ' +
              JSON.stringify(error))
          })
        },
        onCastDisconnected: (): void => {
          this.handleVideoCastDisconnected()
        },
        onCastPlayback: (snapshot: VideoCastPlaybackSnapshot): void => {
          this.handleVideoCastPlayback(snapshot)
        }
      }).catch((error: Error): void => {
        // The in-app player remains usable when the device does not expose an
        // AVSession service (for example, on an older preview image).
        console.warn('[UgreenAVSession] start bridge failed: ' + JSON.stringify(error))
      })
  }

  private playVideoFromMediaSession(): void {
    if (!this.showVideoPlayer || this.videoEntry === null || this.isBusy ||
      !this.videoPrepared || this.videoControlPending) {
      return
    }
    if (this.videoCasting) {
      this.videoControlPending = true
      this.videoMediaSession.sendCastControl({ command: 'play' }).then((): void => {
        this.videoPlaying = true
        this.syncVideoBackgroundTask()
        this.updateVideoPipControlStatus()
        this.updateVideoMediaSession(true)
      }).catch((error: Error): void => {
        console.warn('[UgreenAVSession] remote play command failed: ' + JSON.stringify(error))
      }).finally((): void => {
        this.videoControlPending = false
      })
      return
    }
    if (this.videoPlaybackManager.state() === 'playing') {
      this.videoPlaying = true
      this.syncVideoBackgroundTask()
      this.updateVideoMediaSession(true)
      return
    }
    this.videoControlPending = true
    this.videoPlaybackManager.play().then((): void => {
      if (this.showVideoPlayer) {
        this.videoPlaying = true
        this.syncVideoBackgroundTask()
        this.updateVideoPipControlStatus()
        this.updateVideoMediaSession(true)
      }
    }).catch((error: Error): void => {
      console.warn('[UgreenAVSession] play command could not be applied: ' +
        JSON.stringify(error))
    }).finally((): void => {
      this.videoControlPending = false
    })
  }

  private pauseVideoFromMediaSession(force: boolean = false): void {
    if (!this.showVideoPlayer || this.videoEntry === null || (!force && this.isBusy) ||
      this.videoControlPending) {
      return
    }
    if (this.videoCasting) {
      this.videoControlPending = true
      this.videoMediaSession.sendCastControl({ command: 'pause' }).then((): void => {
        this.videoPlaying = false
        this.syncVideoBackgroundTask()
        this.updateVideoPipControlStatus()
        this.updateVideoMediaSession(true)
      }).catch((error: Error): void => {
        console.warn('[UgreenAVSession] remote pause command failed: ' + JSON.stringify(error))
      }).finally((): void => {
        this.videoControlPending = false
      })
      return
    }
    if (this.videoPlaybackManager.state() !== 'playing') {
      this.videoPlaying = false
      this.syncVideoBackgroundTask()
      this.updateVideoMediaSession(true)
      return
    }
    this.videoControlPending = true
    this.videoPlaybackManager.pause().then((): void => {
      if (this.showVideoPlayer) {
        this.videoPlaying = false
        this.syncVideoBackgroundTask()
        this.updateVideoPipControlStatus()
        this.updateVideoMediaSession(true)
      }
    }).catch((error: Error): void => {
      console.warn('[UgreenAVSession] pause command could not be applied: ' +
        JSON.stringify(error))
    }).finally((): void => {
      this.videoControlPending = false
    })
  }

  private stopVideoFromMediaSession(): void {
    if (!this.showVideoPlayer || this.videoEntry === null || this.isBusy ||
      this.videoControlPending) {
      return
    }
    if (this.videoCasting) {
      this.videoControlPending = true
      this.videoMediaSession.sendCastControl({ command: 'stop' }).then((): void => {
        this.videoCurrentMs = 0
        this.videoPlaying = false
        this.syncVideoBackgroundTask()
        this.updateVideoPipControlStatus()
        this.updateVideoMediaSession(true)
      }).catch((error: Error): void => {
        console.warn('[UgreenAVSession] remote stop command failed: ' + JSON.stringify(error))
      }).finally((): void => {
        this.videoControlPending = false
      })
      return
    }
    this.videoControlPending = true
    this.videoPlaybackManager.pause().then((): void => {
      this.videoPlaybackManager.seek(0)
      this.videoCurrentMs = 0
      this.videoPlaying = false
      this.syncVideoBackgroundTask()
      this.updateVideoPipControlStatus()
      this.updateVideoMediaSession(true)
    }).catch((error: Error): void => {
      console.warn('[UgreenAVSession] stop command could not be applied: ' +
        JSON.stringify(error))
    }).finally((): void => {
      this.videoControlPending = false
    })
  }

  private handleVideoViewportArea(widthVp: number, heightVp: number): void {
    this.videoViewportWidthVp = widthVp
    this.videoViewportHeightVp = heightVp
    this.videoLandscape = widthVp > heightVp
    this.updateVideoSurfaceRect()
  }

  /**
   * Calculate the largest centered rectangle that can contain the decoded
   * video in the current window.  The AVPlayer scale mode is also configured
   * to SCALED_ASPECT, but sizing the Surface itself is important on rotation:
   * it prevents a previously portrait Surface buffer from being reused as a
   * stretched landscape target during the window transition.
   */
  private updateVideoSurfaceRect(): void {
    if (!this.videoSurfaceReady || !this.showVideoPlayer) {
      return
    }
    const viewportWidthVp = this.videoViewportWidthVp > 0
      ? this.videoViewportWidthVp : this.pageWidthVp
    const viewportHeightVp = this.videoViewportHeightVp > 0
      ? this.videoViewportHeightVp : this.pageHeightVp
    if (viewportWidthVp <= 0 || viewportHeightVp <= 0) {
      return
    }

    let surfaceWidthVp = viewportWidthVp
    let surfaceHeightVp = viewportHeightVp
    if (this.videoWidthPx > 0 && this.videoHeightPx > 0) {
      const videoAspect = this.videoWidthPx / this.videoHeightPx
      const viewportAspect = viewportWidthVp / viewportHeightVp
      if (viewportAspect > videoAspect) {
        surfaceHeightVp = viewportHeightVp
        surfaceWidthVp = surfaceHeightVp * videoAspect
      } else {
        surfaceWidthVp = viewportWidthVp
        surfaceHeightVp = surfaceWidthVp / videoAspect
      }
    }

    const surfaceWidthPx = Math.max(1, Math.round(this.getUIContext().vp2px(surfaceWidthVp)))
    const surfaceHeightPx = Math.max(1, Math.round(this.getUIContext().vp2px(surfaceHeightVp)))
    if (surfaceWidthPx === this.videoSurfaceWidthPx &&
      surfaceHeightPx === this.videoSurfaceHeightPx) {
      return
    }
    this.videoSurfaceWidthPx = surfaceWidthPx
    this.videoSurfaceHeightPx = surfaceHeightPx
    try {
      // Omitting offsetX/offsetY centers the rectangle in the XComponent,
      // exactly as described by the XComponent SurfaceRect contract.
      this.videoSurfaceController.setXComponentSurfaceRect({
        surfaceWidth: surfaceWidthPx,
        surfaceHeight: surfaceHeightPx
      })
      console.info('[UgreenVideo] surface rect=' + surfaceWidthPx + 'x' + surfaceHeightPx +
        ' viewport=' + Math.round(viewportWidthVp) + 'x' + Math.round(viewportHeightVp) +
        ' video=' + this.videoWidthPx + 'x' + this.videoHeightPx)
    } catch (error) {
      console.warn('[UgreenVideo] set surface rect failed: ' + JSON.stringify(error))
    }
  }

  private handleVideoSurfaceLoad(): void {
    if (!this.showVideoPlayer || this.videoEntry === null || this.videoSourceHandle === null) {
      return
    }
    const token = this.videoOpenToken
    const surfaceId = this.videoSurfaceController.getXComponentSurfaceId()
    if (surfaceId.length === 0) {
      this.statusText = '视频画面初始化失败'
      return
    }
    this.videoSurfaceReady = true
    try {
      // Let the Surface follow the window orientation. Without this explicit
      // setting a Surface created in portrait can retain its old rotation
      // matrix after the window becomes landscape.
      this.videoSurfaceController.setXComponentSurfaceRotation({ lock: false })
    } catch (error) {
      console.warn('[UgreenVideo] unlock surface rotation failed: ' + JSON.stringify(error))
    }
    this.updateVideoSurfaceRect()
    this.videoPlaybackManager.attachSurface(surfaceId, this.videoCurrentMs).catch((error: Object): void => {
      if (token !== this.videoOpenToken || !this.showVideoPlayer) {
        return
      }
      this.videoPrepared = false
      this.videoPlaying = false
      this.statusText = '视频画面初始化失败'
      this.reportError(error, '视频播放失败')
    })
  }

  private closeVideoPlayer(): void {
    const closingEntry = this.videoEntry
    const closingPosition = this.videoCurrentMs
    const shouldRestoreSearch = this.searchSession !== null && this.searchSession.returnMode === 'video'
    const context = getContext(this) as Context
    this.videoPipBackgrounded = false
    this.videoPipOrigin = null
    this.videoPipHideOnStart = false
    this.videoPipStarting = false
    this.videoPipStopping = false
    this.videoPipRestorePending = false
    this.videoPipRestoreScheduled = false
    this.videoPipRestoring = false
    this.destroyVideoPipController()
    this.videoCastPreparing = false
    this.videoCasting = false
    this.videoWasPlayingBeforeCast = false
    this.videoBackgroundTask.release(context).catch((error: Object): void => {
      console.warn('[UgreenVideo] release background task failed: ' + JSON.stringify(error))
    })
    this.restoreVideoPlayerOrientation()
    this.videoOpenToken += 1
    if (closingEntry !== null) {
      this.videoTransferManager.savePlaybackPosition(closingEntry, closingPosition)
        .catch((): void => {})
      this.videoTransferManager.releaseSource(closingEntry).catch((): void => {})
    }
    this.showVideoPlayer = false
    this.videoEntry = null
    this.videoSourceKey = ''
    this.videoLocalPath = ''
    this.videoDurationMs = 0
    this.videoCurrentMs = 0
    this.videoPlaying = false
    this.videoPrepared = false
    this.videoLandscape = false
    this.videoControlPending = false
    this.videoFirstFrame = false
    this.videoSurfaceReady = false
    this.videoOrientationChanging = false
    this.videoWidthPx = 0
    this.videoHeightPx = 0
    this.videoBufferingPercent = 0
    this.videoSurfaceWidthPx = 0
    this.videoSurfaceHeightPx = 0
    this.videoViewportWidthVp = 0
    this.videoViewportHeightVp = 0
    this.videoMediaSessionPositionAt = 0
    this.videoSourceHandle = null
    this.videoPlaybackManager.release().catch((): void => {})
    this.videoMediaSession.close().catch((error: Error): void => {
      console.warn('[UgreenAVSession] close bridge failed: ' + JSON.stringify(error))
    })
    if (shouldRestoreSearch) {
      this.restoreSearchSession()
    }
  }

  private videoNavigationEntries(): FileEntry[] {
    const source = this.showSearch ? this.searchResults : this.entries
    return source.filter((candidate: FileEntry): boolean =>
      !candidate.isDirectory && this.isVideo(candidate))
  }

  private videoSibling(delta: number): FileEntry | null {
    if (this.videoEntry === null || delta === 0) {
      return null
    }
    const candidates = this.videoNavigationEntries()
    const currentIndex = candidates.findIndex((candidate: FileEntry): boolean =>
      candidate.path === (this.videoEntry as FileEntry).path)
    if (currentIndex < 0) {
      return null
    }
    const targetIndex = currentIndex + (delta < 0 ? -1 : 1)
    return targetIndex >= 0 && targetIndex < candidates.length
      ? candidates[targetIndex] : null
  }

  private async switchVideo(delta: number): Promise<void> {
    if (this.isBusy || this.videoEntry === null) {
      return
    }
    const target = this.videoSibling(delta)
    if (target === null) {
      return
    }
    const previous = this.videoEntry
    await this.openVideoPlayer(target)
    if (this.videoEntry === null || this.videoEntry.path !== target.path ||
      previous.path === target.path) {
      return
    }
    // The XComponent is deliberately kept mounted while changing the source,
    // so its onLoad callback does not fire a second time. Rebind the new
    // AVPlayer to that already-real surface explicitly.
    this.handleVideoSurfaceLoad()
    await this.videoTransferManager.releaseSource(previous)
  }

  private videoWindowIsLandscape(win: window.Window): boolean {
    try {
      const preferred = win.getPreferredOrientation()
      if (preferred === window.Orientation.LANDSCAPE ||
        preferred === window.Orientation.LANDSCAPE_INVERTED ||
        preferred === window.Orientation.USER_ROTATION_LANDSCAPE ||
        preferred === window.Orientation.USER_ROTATION_LANDSCAPE_INVERTED) {
        return true
      }
      if (preferred === window.Orientation.PORTRAIT ||
        preferred === window.Orientation.PORTRAIT_INVERTED ||
        preferred === window.Orientation.USER_ROTATION_PORTRAIT ||
        preferred === window.Orientation.USER_ROTATION_PORTRAIT_INVERTED) {
        return false
      }
    } catch (error) {
      console.warn('[UgreenVideo] read preferred orientation failed: ' + JSON.stringify(error))
    }
    try {
      const rect = win.getWindowProperties().windowRect
      if (rect.width > 0 && rect.height > 0) {
        return rect.width > rect.height
      }
    } catch (error) {
      console.warn('[UgreenVideo] read window size failed: ' + JSON.stringify(error))
    }
    return this.pageWidthVp > this.pageHeightVp
  }

  /**
   * Apply the official system-bar visibility APIs used by immersive media
   * windows. `setSpecificSystemBarEnabled` is preferred because it makes the
   * status-bar decision explicit; the older list API remains a device/API
   * fallback so the player still becomes immersive on builds that do not
   * expose the per-bar call at runtime.
   */
  private async applyVideoSystemBarVisibility(win: window.Window,
    landscape: boolean): Promise<void> {
    const enabled = !landscape
    let statusUpdated = false
    let navigationUpdated = false
    try {
      await win.setSpecificSystemBarEnabled('status', enabled, false)
      statusUpdated = true
    } catch (error) {
      console.warn('[UgreenVideo] set status bar visibility failed: ' + JSON.stringify(error))
    }
    try {
      await win.setSpecificSystemBarEnabled('navigation', enabled, false)
      navigationUpdated = true
    } catch (error) {
      console.warn('[UgreenVideo] set navigation bar visibility failed: ' +
        JSON.stringify(error))
    }
    if (statusUpdated && navigationUpdated) {
      return
    }
    try {
      await win.setWindowSystemBarEnable(enabled ? ['status', 'navigation'] : [])
    } catch (error) {
      console.warn('[UgreenVideo] set system bar visibility fallback failed: ' +
        JSON.stringify(error))
    }
  }

  /**
   * Window callbacks are synchronous while system-bar APIs return Promises.
   * Keep requests in one chain and invalidate stale requests when a newer
   * orientation or close operation is issued.
   */
  private setVideoSystemBars(win: window.Window, landscape: boolean,
    allowWhenClosed: boolean = false): Promise<void> {
    if (!allowWhenClosed && (!this.showVideoPlayer || this.videoPlayerWindow !== win)) {
      return Promise.resolve()
    }
    if (!allowWhenClosed && this.videoSystemBarsLandscape === landscape) {
      return this.videoSystemBarsQueue
    }
    this.videoSystemBarsLandscape = landscape
    const token = this.videoSystemBarsToken + 1
    this.videoSystemBarsToken = token
    const operation = this.videoSystemBarsQueue
      .catch((): void => {})
      .then(async (): Promise<void> => {
        if (token !== this.videoSystemBarsToken) {
          return
        }
        if (!allowWhenClosed && (!this.showVideoPlayer || this.videoPlayerWindow !== win)) {
          return
        }
        await this.applyVideoSystemBarVisibility(win, landscape)
      })
    this.videoSystemBarsQueue = operation.catch((error: Object): void => {
      console.warn('[UgreenVideo] system bar update failed: ' + JSON.stringify(error))
    })
    return operation
  }

  /**
   * Match the image viewer's orientation policy: the video window follows the
   * device sensor only when the system's automatic-rotation switch permits
   * it. The callback is kept on the same Window instance so the surface and
   * the one-line controller react to the committed window size, not to a
   * guessed timer frame.
   */
  private enableVideoPlayerAutoRotation(): void {
    const token = this.videoOrientationToken + 1
    this.videoOrientationToken = token
    const context = getContext(this) as common.UIAbilityContext
    window.getLastWindow(context).then((win: window.Window): void => {
      if (token !== this.videoOrientationToken || !this.showVideoPlayer) {
        return
      }
      try {
        if (this.videoPlayerWindow !== win) {
          this.videoPlayerWindow = win
        }
        if (this.videoPlayerPreviousOrientation === null) {
          this.videoPlayerPreviousOrientation = win.getPreferredOrientation()
          win.on('windowSizeChange', this.videoWindowSizeChange)
        }
        // If the window is already landscape, no size-change callback is
        // guaranteed to be emitted by the platform. Inspect the committed
        // window rectangle once so the status bar is hidden on first frame.
        try {
          const rect = win.getWindowProperties().windowRect
          if (rect.width > 0 && rect.height > 0) {
            this.videoLandscape = rect.width > rect.height
          }
        } catch (error) {
          console.warn('[UgreenVideo] read initial video window size failed: ' +
            JSON.stringify(error))
        }
        this.setVideoSystemBars(win, this.videoLandscape).catch((error: Error): void => {
          console.warn('[UgreenVideo] set initial video system bars failed: ' +
            JSON.stringify(error))
        })
        // AUTO_ROTATION_RESTRICTED is the official mode that obeys the
        // system auto-rotation lock. It is deliberately different from the
        // unrestricted mode used only by the explicit rotate button below.
        win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED)
          .catch((error: Error): void => {
            console.warn('[UgreenVideo] enable auto rotation failed: ' +
              JSON.stringify(error))
          })
      } catch (error) {
        console.warn('[UgreenVideo] prepare auto rotation failed: ' + JSON.stringify(error))
      }
    }).catch((error: Error): void => {
      console.warn('[UgreenVideo] get video window failed: ' + JSON.stringify(error))
    })
  }

  /**
   * Keep the rotation behavior aligned with the official video-show sample:
   * the window (rather than the video pixels) changes orientation, landscape
   * multi-window is enabled for the landscape presentation, and system bars
   * are hidden only while that presentation is active.
   */
  private async applyVideoWindowOrientation(win: window.Window, landscape: boolean): Promise<void> {
    // Update the overlay immediately, then let windowSizeChange confirm the
    // committed dimensions. This removes the portrait status-bar inset during
    // the orientation animation instead of one frame after it completes.
    this.videoLandscape = landscape
    if (landscape) {
      try {
        await win.enableLandscapeMultiWindow()
      } catch (error) {
        // Some phone/window modes do not support this switch. The orientation
        // change is still useful, so continue with the remaining operations.
        console.warn('[UgreenVideo] enable landscape multi-window failed: ' +
          JSON.stringify(error))
      }
      await this.setVideoSystemBars(win, true)
      await win.setPreferredOrientation(window.Orientation.USER_ROTATION_LANDSCAPE)
      return
    }

    try {
      await win.disableLandscapeMultiWindow()
    } catch (error) {
      console.warn('[UgreenVideo] disable landscape multi-window failed: ' +
        JSON.stringify(error))
    }
    await this.setVideoSystemBars(win, false)
    await win.setPreferredOrientation(window.Orientation.USER_ROTATION_PORTRAIT)
  }

  private rotateVideoInterface(): void {
    if (this.isBusy || this.videoEntry === null || this.videoOrientationChanging) {
      return
    }
    const token = this.videoOrientationToken + 1
    this.videoOrientationToken = token
    this.videoOrientationChanging = true
    const context = getContext(this) as common.UIAbilityContext
    window.getLastWindow(context)
      .then((win: window.Window): Promise<void> => {
        if (token !== this.videoOrientationToken || !this.showVideoPlayer ||
          this.videoEntry === null) {
          return Promise.resolve()
        }
        if (this.videoPlayerWindow === null) {
          this.videoPlayerWindow = win
          try {
            this.videoPlayerPreviousOrientation = win.getPreferredOrientation()
            win.on('windowSizeChange', this.videoWindowSizeChange)
          } catch (error) {
            console.warn('[UgreenVideo] save preferred orientation failed: ' +
              JSON.stringify(error))
          }
        }
        const targetLandscape = !this.videoWindowIsLandscape(win)
        console.info('[UgreenVideo] rotate interface to ' +
          (targetLandscape ? 'landscape' : 'portrait'))
        return this.applyVideoWindowOrientation(win, targetLandscape)
      })
      .catch((error: Error): void => {
        if (token === this.videoOrientationToken && this.showVideoPlayer) {
          this.statusText = '切换视频方向失败'
          console.warn('[UgreenVideo] rotate interface failed: ' + JSON.stringify(error))
        }
      })
      .then((): void => {
        if (token === this.videoOrientationToken) {
          this.videoOrientationChanging = false
        }
      })
  }

  private restoreVideoPlayerOrientation(): void {
    this.videoOrientationToken += 1
    this.videoOrientationChanging = false
    this.videoSystemBarsLandscape = null
    this.videoSystemBarsToken += 1
    const win = this.videoPlayerWindow
    const previous = this.videoPlayerPreviousOrientation
    this.videoPlayerWindow = null
    this.videoPlayerPreviousOrientation = null
    if (win === null) {
      return
    }
    try {
      win.off('windowSizeChange', this.videoWindowSizeChange)
    } catch (error) {
      console.warn('[UgreenVideo] release window size listener failed: ' +
        JSON.stringify(error))
    }
    this.restoreVideoWindowState(win, previous).catch((error: Error): void => {
      console.warn('[UgreenVideo] restore video window state failed: ' + JSON.stringify(error))
    })
  }

  private async restoreVideoWindowState(win: window.Window,
    previous: window.Orientation | null): Promise<void> {
    try {
      await win.disableLandscapeMultiWindow()
    } catch (error) {
      console.warn('[UgreenVideo] restore landscape multi-window failed: ' +
        JSON.stringify(error))
    }
    await this.setVideoSystemBars(win, false, true)
    if (previous === null) {
      return
    }
    try {
      await win.setPreferredOrientation(previous)
    } catch (error) {
      console.warn('[UgreenVideo] restore orientation failed: ' + JSON.stringify(error))
    }
  }

  /**
   * Handles the double-tap gesture on the media surface. The gesture itself
   * is the official ArkUI TapGesture; playback is routed through the same
   * control path as the bottom-bar button so local playback and remote
   * casting stay in sync.
   */
  private async handleVideoDoubleTap(): Promise<void> {
    if (this.isBusy || !this.videoPrepared || this.videoEntry === null ||
      this.videoControlPending) {
      return
    }
    await this.toggleVideo()
  }

  private async toggleVideo(): Promise<void> {
    if (this.isBusy || !this.videoPrepared || this.videoEntry === null ||
      this.videoControlPending) {
      return
    }
    if (this.videoCasting) {
      const shouldPause = this.videoPlaying
      this.videoControlPending = true
      try {
        await this.videoMediaSession.sendCastControl({
          command: shouldPause ? 'pause' : 'play'
        })
        this.videoPlaying = !shouldPause
        this.syncVideoBackgroundTask()
        this.updateVideoPipControlStatus()
        this.updateVideoMediaSession(true)
      } catch (error) {
        this.reportError(error as Object, '视频操作失败')
        this.statusText = '投播操作失败'
      } finally {
        this.videoControlPending = false
      }
      return
    }
    const playerState = this.videoPlaybackManager.state()
    // Read the MediaKit state at the point of the click instead of trusting a
    // possibly one-frame-old @State value. This is important when the player
    // sends `playing` just before the controller is rendered.
    const shouldPause = playerState === 'playing' ||
      (playerState === null && this.videoPlaying)
    this.videoControlPending = true
    try {
      if (shouldPause) {
        await this.videoPlaybackManager.pause()
        this.videoPlaying = false
      } else {
        await this.videoPlaybackManager.play()
        this.videoPlaying = true
      }
      this.syncVideoBackgroundTask()
      this.updateVideoPipControlStatus()
      this.updateVideoMediaSession(true)
    } catch (error) {
      this.reportError(error as Object, '视频操作失败')
      this.statusText = '视频操作失败'
    } finally {
      this.videoControlPending = false
    }
  }

  private toggleVideoMute(): void {
    if (!this.videoPrepared) {
      return
    }
    this.videoMuted = !this.videoMuted
    if (this.videoCasting) {
      this.videoMediaSession.sendCastControl({ command: 'toggleMute' })
        .catch((error: Error): void => {
          console.warn('[UgreenAVSession] remote mute command failed: ' + JSON.stringify(error))
        })
      this.updateVideoMediaSession(true)
      return
    }
    this.videoPlaybackManager.setMuted(this.videoMuted)
  }

  private seekVideo(value: number): void {
    if (!this.videoPrepared || this.videoDurationMs <= 0) {
      return
    }
    const timeMs = Math.min(this.videoDurationMs, Math.max(0, Math.floor(value)))
    this.videoCurrentMs = timeMs
    if (this.videoCasting) {
      this.videoMediaSession.sendCastControl({ command: 'seek', parameter: timeMs })
        .catch((error: Error): void => {
          console.warn('[UgreenAVSession] remote seek command failed: ' + JSON.stringify(error))
        })
    } else {
      this.videoPlaybackManager.seek(timeMs)
    }
    if (this.videoEntry !== null) {
      this.videoTransferManager.savePlaybackPosition(this.videoEntry, timeMs)
        .catch((): void => {})
    }
  }

  private async downloadVideoFromPlayer(entry: FileEntry): Promise<void> {
    if (this.isBusy || entry.isDirectory) {
      return
    }
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在下载视频…'
    try {
      await this.refreshVideoManager()
      await this.videoTransferManager.requestDownload(entry)
      this.statusText = '视频已保存到系统下载目录'
      this.showImmersiveToast('视频已保存到系统下载目录：' + entry.name)
    } catch (error) {
      this.reportError(error as Object, '视频下载失败')
      this.statusText = '视频下载失败'
    } finally {
      this.isBusy = false
    }
  }

  private videoTransferError(entry: FileEntry): string {
    return this.videoStateForEntry(entry).errorMessage
  }

  private videoStatusText(entry: FileEntry): string {
    const error = this.videoTransferError(entry)
    if (error.length > 0) {
      return '传输失败：' + error
    }
    const state = this.videoStateForEntry(entry)
    if (state.status === 'downloading' || state.status === 'queued') {
      const received = this.formatSize(state.receivedBytes)
      const total = state.totalBytes > 0 ? ' / ' + this.formatSize(state.totalBytes) : ''
      return received + total + ' · 下载中'
    }
    if (state.status === 'streaming') {
      if (state.totalBytes > 0) {
        return this.formatSize(state.receivedBytes) + ' / ' + this.formatSize(state.totalBytes) + ' · 边下边播'
      }
      return '正在缓冲视频…'
    }
    if (state.status === 'partial') {
      if (state.totalBytes > 0) {
        return this.formatSize(state.receivedBytes) + ' / ' + this.formatSize(state.totalBytes) + ' · 已缓存部分'
      }
      return '已缓存部分'
    }
    if (state.status === 'completed') {
      return state.durablePath.length > 0 ? '已保存到系统下载目录' : '已缓存，可离线播放'
    }
    if (this.videoPrepared) {
      return this.videoPlaying ? '正在播放' : '已暂停'
    }
    return '正在准备视频…'
  }

  private syncVideoBackgroundTask(): void {
    if (!this.showVideoPlayer || this.videoEntry === null) {
      return
    }
    const context = getContext(this) as Context
    // A remote cast is an AUDIO_PLAYBACK workload too.  Keep the continuous
    // task while the sink is playing even though the local AVPlayer is paused.
    this.videoBackgroundTask.setPlaying(context, this.videoPlaying || this.videoCasting)
  }

  private handleVideoCastPickerState(state: AVCastPickerState): void {
    console.info('[UgreenVideo] AVCastPicker state=' + state.toString())
  }

  private async toggleVideoPip(): Promise<void> {
    if (this.isBusy || !this.showVideoPlayer || !this.videoSurfaceReady ||
      this.videoPipCreating || this.videoPipStarting || this.videoPipStopping) {
      return
    }
    if (this.videoPipActive && this.videoPipController !== null) {
      this.videoPipStopping = true
      try {
        await this.videoPipController.stopPiP()
      } catch (error) {
        console.warn('[UgreenVideo] stop PiP failed: ' + JSON.stringify(error))
      } finally {
        this.videoPipStopping = false
      }
      return
    }
    if (!PiPWindow.isPiPEnabled()) {
      this.statusText = '当前设备不支持小窗播放'
      this.showImmersiveToast('当前设备不支持小窗播放')
      return
    }
    this.captureVideoPipOrigin()
    this.videoPipHideOnStart = true
    this.videoPipStarting = true
    try {
      const controller = await this.createVideoPipController()
      await controller.startPiP()
      this.enterVideoPipBackground()
      this.statusText = '已进入小窗播放'
    } catch (error) {
      this.videoPipHideOnStart = false
      this.videoPipOrigin = null
      this.videoPipActive = false
      this.videoPipBackgrounded = false
      this.videoPipRestorePending = false
      this.videoPipRestoring = false
      this.updateBottomBarVisibility(true)
      // A failed start can leave a controller in an unusable state on some
      // platform releases. Drop it so the next explicit tap creates a fresh
      // controller instead of retrying the rejected instance.
      this.destroyVideoPipController()
      this.statusText = '小窗播放启动失败'
      console.warn('[UgreenVideo] start PiP failed: ' + JSON.stringify(error))
    } finally {
      this.videoPipStarting = false
    }
  }

  private captureVideoPipOrigin(): void {
    if (this.videoPipOrigin !== null || !this.showVideoPlayer) {
      return
    }
    this.videoPipOrigin = {
      screen: this.screen,
      selectedBottomTab: this.selectedBottomTab,
      rootKind: this.rootKind,
      currentPath: this.currentPath,
      currentRootType: this.currentRootType,
      entries: this.entries.slice(),
      navigationStack: this.navigationStack.slice(),
      navigationEntryStack: this.cloneNavigationEntryStack(this.navigationEntryStack),
      navigationRootTypeStack: this.navigationRootTypeStack.slice(),
      navigationViewStateStack: this.cloneNavigationViewStateStack(this.navigationViewStateStack),
      navigationPageIndexStack: this.navigationPageIndexStack.slice(),
      navigationPageHasMoreStack: this.navigationPageHasMoreStack.slice(),
      currentPageIndex: this.currentPageIndex,
      currentPageHasMore: this.currentPageHasMore,
      viewState: this.cloneDirectoryViewState(this.captureDirectoryViewState()),
      topTitle: this.topTitle,
      topTitleOpacity: this.topTitleOpacity
    }
  }

  private enterVideoPipBackground(): void {
    if (!this.showVideoPlayer || this.videoPipBackgrounded) {
      return
    }
    this.videoPipHideOnStart = false
    this.videoPipBackgrounded = true
    // The player remains alive and the original XComponent stays mounted in a
    // 1x1 host. Only the surrounding controls are removed, revealing the file
    // page that launched the video underneath the system PiP window.
    this.updateBottomBarVisibility(true)
  }

  private async stopVideoPipForReplacement(): Promise<void> {
    if (!this.videoPipBackgrounded) {
      return
    }
    this.videoPipBackgrounded = false
    this.videoPipOrigin = null
    this.videoPipHideOnStart = false
    this.videoPipStarting = false
    this.videoPipStopping = true
    this.videoPipRestorePending = false
    this.videoPipRestoreScheduled = false
    this.videoPipRestoring = false
    const controller = this.videoPipController
    if (controller !== null) {
      try {
        await controller.stopPiP()
      } catch (error) {
        console.warn('[UgreenVideo] stop PiP before replacement failed: ' +
          JSON.stringify(error))
      }
    }
    this.destroyVideoPipController()
    this.videoPipStopping = false
  }

  private restoreVideoPipOrigin(): void {
    const origin = this.videoPipOrigin
    this.videoPipOrigin = null
    if (origin === null) {
      return
    }
    this.navigationRequestId += 1
    this.isNavigating = false
    this.cancelFileTransition()
    this.closeActionMenu()
    this.showDestinationPicker = false
    this.showRenameDialog = false
    this.showCreateFolderDialog = false
    this.destinationFolderDialog = false
    this.selectionMode = false
    this.selectedPaths = []
    this.selectedEntryCount = 0
    this.screen = origin.screen
    this.selectedBottomTab = origin.selectedBottomTab
    this.rootKind = origin.rootKind
    this.currentPath = origin.currentPath
    this.currentRootType = origin.currentRootType
    this.navigationStack = origin.navigationStack.slice()
    this.navigationEntryStack = this.cloneNavigationEntryStack(origin.navigationEntryStack)
    this.navigationRootTypeStack = origin.navigationRootTypeStack.slice()
    this.navigationViewStateStack = this.cloneNavigationViewStateStack(origin.navigationViewStateStack)
    this.navigationPageIndexStack = origin.navigationPageIndexStack.slice()
    this.navigationPageHasMoreStack = origin.navigationPageHasMoreStack.slice()
    this.currentPageIndex = origin.currentPageIndex
    this.currentPageHasMore = origin.currentPageHasMore
    this.fileViewMode = origin.viewState.mode
    this.showSearch = false
    // A search result is resolved to its real parent directory before the
    // video is opened. Once PiP restoration has put that directory back under
    // the player, Back must close the player to this directory instead of
    // replaying the suspended search result return route.
    if (this.searchSession !== null && this.searchSession.returnMode === 'video') {
      this.searchSession.returnMode = 'none'
      this.searchSession.targetParentPath = ''
      this.searchSession.targetNavigationDepth = this.navigationStack.length
    }
    this.replaceEntries(origin.entries.slice())
    this.resetPreviewState(false)
    this.restoreDirectoryViewState(origin.viewState)
    this.updateTopTitle(origin.topTitle, false)
    this.topTitleOpacity = origin.topTitleOpacity
    this.errorText = ''
  }

  private async createVideoPipController(): Promise<PiPWindow.PiPController> {
    if (this.videoPipController !== null) {
      return this.videoPipController
    }
    if (this.videoPipCreating) {
      throw new Error('小窗控制器正在创建')
    }
    this.videoPipCreating = true
    try {
      const width = this.videoWidthPx > 0 ? this.videoWidthPx : 16
      const height = this.videoHeightPx > 0 ? this.videoHeightPx : 9
      const config: PiPWindow.PiPConfiguration = {
        context: getContext(this) as Context,
        componentController: this.videoSurfaceController,
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
        contentWidth: width,
        contentHeight: height,
        // The system video template owns the play/pause/close/restore UI;
        // expose only the optional previous/next group supported by the
        // official XComponent PiP sample.
        controlGroups: [PiPWindow.VideoPlayControlGroup.VIDEO_PREVIOUS_NEXT]
      }
      const controller = await PiPWindow.create(config)
      this.videoPipController = controller
      controller.on('stateChange', this.videoPipStateChange)
      controller.on('controlPanelActionEvent', this.videoPipControlEvent)
      // PiP is entered by the explicit top-bar button.  Background audio
      // playback remains enabled independently of automatic PiP.
      controller.setAutoStartEnabled(false)
      return controller
    } finally {
      this.videoPipCreating = false
    }
  }

  private handleVideoPipStateChange(state: PiPWindow.PiPState, reason: string): void {
    console.info('[UgreenVideo] PiP state=' + state.toString() + ' reason=' + reason)
    switch (state) {
      case PiPWindow.PiPState.STARTED:
        this.videoPipActive = true
        if (this.videoPipHideOnStart) {
          this.enterVideoPipBackground()
        }
        this.updateVideoPipControlStatus()
        break
      case PiPWindow.PiPState.STOPPED:
        this.videoPipActive = false
        this.videoPipStopping = false
        if (this.videoPipRestorePending || this.videoPipRestoring) {
          // ABOUT_TO_RESTORE is followed by STOPPED on some releases. The
          // restore callback owns the page transition; STOPPED must not tear
          // down the player or clear the origin snapshot before that frame.
          break
        }
        if (this.videoPipBackgrounded) {
          // Closing or dragging away the system PiP also closes the retained
          // player. The file directory is already visible underneath.
          this.videoPipBackgrounded = false
          this.videoPipOrigin = null
          this.closeVideoPlayer()
        }
        break
      case PiPWindow.PiPState.ABOUT_TO_RESTORE:
        this.videoPipActive = false
        this.videoPipRestoring = true
        this.videoPipRestorePending = true
        this.scheduleVideoPipRestore()
        break
      case PiPWindow.PiPState.ERROR:
        this.videoPipActive = false
        this.videoPipHideOnStart = false
        this.videoPipStarting = false
        this.videoPipStopping = false
        this.videoPipRestorePending = false
        this.videoPipRestoring = false
        this.videoPipOrigin = null
        this.videoPipBackgrounded = false
        this.statusText = '小窗播放不可用'
        this.updateBottomBarVisibility(true)
        break
      default:
        break
    }
  }

  private handleVideoPipControlEvent(event: PiPWindow.PiPActionEventType,
    status?: number): void {
    switch (event) {
      case 'playbackStateChanged':
        if (status === 0) {
          this.pauseVideoFromMediaSession()
        } else if (status === 1) {
          this.playVideoFromMediaSession()
        }
        break
      case 'nextVideo':
        this.switchVideo(1).catch((error: Error): void => {
          console.warn('[UgreenVideo] PiP next video failed: ' + JSON.stringify(error))
        })
        break
      case 'previousVideo':
        this.switchVideo(-1).catch((error: Error): void => {
          console.warn('[UgreenVideo] PiP previous video failed: ' + JSON.stringify(error))
        })
        break
      default:
        break
    }
  }

  private updateVideoPipControlStatus(): void {
    const controller = this.videoPipController
    if (controller === null || !this.videoPipActive) {
      return
    }
    try {
      controller.updatePiPControlStatus(PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
        this.videoPlaying ? PiPWindow.PiPControlStatus.PLAY : PiPWindow.PiPControlStatus.PAUSE)
    } catch (error) {
      // The VIDEO_PLAY template may not expose this optional control on some
      // device releases; playback itself remains valid.
      console.warn('[UgreenVideo] update PiP control status failed: ' + JSON.stringify(error))
    }
  }

  private destroyVideoPipController(): void {
    const controller = this.videoPipController
    this.videoPipController = null
    this.videoPipActive = false
    this.videoPipCreating = false
    this.videoPipStarting = false
    this.videoPipStopping = false
    if (controller === null) {
      return
    }
    try {
      controller.setAutoStartEnabled(false)
      controller.off('stateChange')
      controller.off('controlPanelActionEvent')
    } catch (error) {
      console.warn('[UgreenVideo] destroy PiP controller failed: ' + JSON.stringify(error))
    }
    controller.stopPiP().catch((): void => {})
  }

  private async handleVideoCastConnected(): Promise<void> {
    if (!this.showVideoPlayer || this.videoEntry === null ||
      this.videoCastPreparing || !this.videoMediaSession.isCasting()) {
      return
    }
    const entry = this.videoEntry
    const token = this.videoOpenToken
    this.videoCastPreparing = true
    this.videoWasPlayingBeforeCast = this.videoPlaying
    this.videoCasting = true
    this.syncVideoBackgroundTask()
    try {
      if (this.videoPlaybackManager.state() === 'playing') {
        await this.videoPlaybackManager.pause()
      }
      this.videoPlaying = false
      this.updateVideoMediaSession(true)
      const descriptor = await this.videoTransferManager.castDescriptor(entry)
      if (token !== this.videoOpenToken || !this.showVideoPlayer ||
        !this.videoMediaSession.isCasting()) {
        return
      }
      await this.videoMediaSession.startCasting(descriptor.url, this.videoCurrentMs,
        this.videoDurationMs)
      this.videoPlaying = true
      this.updateVideoPipControlStatus()
      this.updateVideoMediaSession(true)
      this.statusText = '正在投播'
    } catch (error) {
      this.videoCasting = false
      this.syncVideoBackgroundTask()
      this.statusText = '投播失败，已恢复本地播放'
      console.warn('[UgreenVideo] cast start failed: ' + JSON.stringify(error))
      if (this.videoWasPlayingBeforeCast && this.showVideoPlayer &&
        this.videoEntry !== null) {
        this.videoPlaybackManager.play().then((): void => {
          this.videoPlaying = true
          this.syncVideoBackgroundTask()
          this.updateVideoMediaSession(true)
        }).catch((): void => {})
      }
    } finally {
      this.videoCastPreparing = false
    }
  }

  private handleVideoCastDisconnected(): void {
    // `videoWasPlayingBeforeCast` is only the fallback used when preparing a
    // cast fails. Once the remote sink has started, the live `videoPlaying`
    // value reflects the user's last remote pause/play action and must win
    // when the route is disconnected.
    const shouldResume = this.videoPlaying
    this.videoCasting = false
    this.videoWasPlayingBeforeCast = false
    this.syncVideoBackgroundTask()
    if (!shouldResume || !this.showVideoPlayer || this.videoEntry === null) {
      this.videoPlaying = false
      this.updateVideoMediaSession(true)
      return
    }
    this.videoPlaybackManager.seek(this.videoCurrentMs)
    this.videoPlaybackManager.play().then((): void => {
      if (!this.showVideoPlayer) {
        return
      }
      this.videoPlaying = true
      this.syncVideoBackgroundTask()
      this.updateVideoMediaSession(true)
    }).catch((error: Error): void => {
      console.warn('[UgreenVideo] resume local video after cast failed: ' + JSON.stringify(error))
    })
  }

  private handleVideoCastPlayback(snapshot: VideoCastPlaybackSnapshot): void {
    if (!this.videoCasting || this.videoEntry === null) {
      return
    }
    this.videoPlaying = snapshot.playing
    if (snapshot.durationMs > 0) {
      this.videoDurationMs = snapshot.durationMs
    }
    this.videoCurrentMs = Math.max(0, snapshot.positionMs)
    this.syncVideoBackgroundTask()
    this.updateVideoPipControlStatus()
    this.updateVideoMediaSession(true)
  }

  private closeAudioPlayer(): void {
    const shouldRestoreSearch = this.searchSession !== null && this.searchSession.returnMode === 'audio'
    this.showAudioPlayer = false
    this.audioEntry = null
    this.audioLocalPath = ''
    this.audioPlaying = false
    this.audioCurrentMs = 0
    this.audioDurationMs = 0
    this.audioManager.release()
    if (shouldRestoreSearch) {
      this.restoreSearchSession()
    }
  }

  private async toggleAudio(): Promise<void> {
    if (this.isBusy || this.audioEntry === null) {
      return
    }
    try {
      if (this.audioPlaying) {
        await this.audioManager.pause()
      } else {
        await this.audioManager.play()
      }
    } catch (error) {
      this.reportError(error as Object, '音频操作失败')
      this.statusText = '音频操作失败'
    }
  }

  private async rewindAudio(): Promise<void> {
    if (this.isBusy || this.audioEntry === null) {
      return
    }
    try {
      await this.audioManager.rewind()
      this.audioCurrentMs = 0
      this.audioPlaying = false
      this.statusText = '已回到音频开头'
    } catch (error) {
      this.reportError(error as Object, '音频重置失败')
      this.statusText = '音频重置失败'
    }
  }

  private seekAudio(value: number): void {
    if (this.audioDurationMs <= 0) {
      return
    }
    const timeMs = Math.min(this.audioDurationMs, Math.max(0, Math.floor(value)))
    this.audioCurrentMs = timeMs
    this.audioManager.seek(timeMs)
  }

  private async openWithOtherApp(entry: FileEntry): Promise<void> {
    await this.openCachedEntry(entry, true)
  }

  private async quickView(entry: FileEntry): Promise<void> {
    if (this.isImage(entry)) {
      await this.openImageViewer(entry)
      return
    }
    if (this.isAudio(entry)) {
      await this.openAudioPlayer(entry)
      return
    }
    if (this.isVideo(entry)) {
      await this.openVideoPlayer(entry)
      return
    }
    await this.openCachedEntry(entry, false)
  }

  private async openCachedEntry(entry: FileEntry, forcePicker: boolean): Promise<void> {
    if (this.isBusy || entry.isDirectory) {
      return
    }
    this.closeActionMenu()
    this.closeImageMoreMenu()
    this.closeImageDetails()
    if (!await this.confirmMeteredDownload(entry)) {
      return
    }
    this.isBusy = true
    this.errorText = ''
    this.statusText = forcePicker ? '正在准备其他应用打开…' : '正在准备快速查看…'
    try {
      const localPath = await this.ensureCachedFile(entry)
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: fileUri.getUriFromPath(localPath),
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      }
      const fileType = this.fileType(entry)
      if (fileType.length > 0) {
        want.type = fileType
      }
      if (forcePicker) {
        want.parameters = {
          'ohos.ability.params.showDefaultPicker': true
        }
      }
      const context = getContext(this) as common.UIAbilityContext
      await context.startAbility(want)
      this.statusText = forcePicker ? '已拉起应用选择器' : '已打开快速查看'
    } catch (error) {
      this.reportError(error as Object, forcePicker ? '其他应用打开失败' : '快速查看失败')
      this.statusText = forcePicker ? '其他应用打开失败' : '快速查看失败'
    } finally {
      this.isBusy = false
    }
  }

  private async ensureCachedFile(entry: FileEntry,
    onProgress?: BinaryProgressListener, shouldContinue?: () => boolean): Promise<string> {
    if (this.isVideo(entry)) {
      await this.refreshVideoManager()
      const videoLocal = await this.videoTransferManager.resolveLocal(entry)
      if (videoLocal.length > 0) {
        if (onProgress !== undefined) {
          onProgress({ receiveSize: 1, totalSize: 1 })
        }
        return videoLocal
      }
      // Explicit actions such as Save/Share/Open-with are allowed to promote
      // the resumable stream into the user Download/UGREENlink directory.
      await this.videoTransferManager.requestCachedFile(entry)
      const downloaded = await this.videoTransferManager.resolveLocal(entry)
      if (downloaded.length === 0) {
        throw new Error('视频下载未生成本地文件')
      }
      if (onProgress !== undefined) {
        onProgress({ receiveSize: 1, totalSize: 1 })
      }
      return downloaded
    }
    await this.ensureCacheState()
    const cacheKey = this.originalCacheKey(entry)
    const existingPath = CacheManager.findExisting(this.cacheDirectory, entry.name, cacheKey)
    if (existingPath.length > 0) {
      if (onProgress !== undefined) {
        onProgress({ receiveSize: 1, totalSize: 1 })
      }
      return existingPath
    }
    const context = getContext(this) as Context
    const directory = this.cacheDirectory.length > 0 ? this.cacheDirectory : context.cacheDir
    const localPath = await this.repository.download(entry, directory, this.cacheLimitBytes,
      onProgress, shouldContinue)
    await this.refreshCacheUsage()
    return localPath
  }

  private async confirmMeteredDownload(entry: FileEntry): Promise<boolean> {
    await this.ensureNetworkState()
    if (this.isVideo(entry)) {
      await this.refreshVideoManager()
      try {
        if ((await this.videoTransferManager.resolveLocal(entry)).length > 0) {
          return true
        }
      } catch (_) {
        // Initialization/network metadata errors are reported by the action
        // that actually needs the video; keep the existing prompt path here.
      }
    }
    if (this.networkClass === 'offline') {
      return false
    }
    if (!this.networkPolicy.isMetered()) {
      return true
    }
    await this.ensureCacheState()
    const existingPath = CacheManager.findExisting(this.cacheDirectory, entry.name,
      this.originalCacheKey(entry))
    if (existingPath.length > 0) {
      return true
    }
    const sizeText = entry.size > 0 ? this.formatSize(entry.size) : '大小未知'
    const response = await promptAction.showDialog({
      title: '使用移动网络下载？',
      message: entry.name + ' · ' + sizeText,
      buttons: [
        { text: '取消', color: this.isDarkTheme ? '#FFFFFFFF' : '#536174' },
        { text: '继续', color: '#2E6BFF' }
      ],
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false)
    })
    return response.index === 1
  }

  private originalCacheKey(entry: FileEntry): string {
    return this.repository.cacheKeyForFile(entry)
  }

  private async cacheToLocal(entry: FileEntry): Promise<void> {
    if (this.isBusy || entry.isDirectory) {
      return
    }
    this.closeActionMenu()
    this.errorText = ''
    if (this.isVideo(entry)) {
      if (!await this.confirmMeteredDownload(entry)) {
        return
      }
      this.isBusy = true
      this.statusText = '正在下载视频…'
      try {
        await this.refreshVideoManager()
        await this.videoTransferManager.requestDownload(entry)
        this.statusText = '视频已保存到系统下载目录'
        this.showImmersiveToast('视频已保存到系统下载目录：' + entry.name)
      } catch (error) {
        this.reportError(error as Object, '视频下载失败')
        this.statusText = '视频下载失败'
      } finally {
        this.isBusy = false
      }
      return
    }
    try {
      await this.ensureDownloadState()
      await this.downloadQueue.enqueue(entry)
      this.statusText = '已加入下载队列'
      this.showImmersiveToast('已加入下载：' + entry.name)
    } catch (error) {
      this.reportError(error as Object, '加入下载失败')
      this.statusText = '加入下载失败'
    }
  }

  private async saveToGallery(entry: FileEntry): Promise<void> {
    if (this.isBusy || entry.isDirectory || !this.isMedia(entry)) {
      return
    }
    this.closeActionMenu()
    if (!await this.confirmMeteredDownload(entry)) {
      return
    }
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在缓存并保存到图库…'
    try {
      const localPath = await this.ensureCachedFile(entry)
      const context = getContext(this) as Context
      await UserFileManager.saveToGallery(context, localPath, entry.name, this.isVideo(entry))
      this.statusText = '已保存到图库'
      this.showImmersiveToast('已保存到图库：' + entry.name)
    } catch (error) {
      this.reportError(error as Object, '保存到图库失败')
      this.statusText = '保存到图库失败'
    } finally {
      this.isBusy = false
    }
  }

  private enterSelectionMode(): void {
    if (this.screen !== 'files' || this.isBusy) {
      return
    }
    this.closeActionMenu()
    this.showSelectionMoreMenu = false
    this.getUIContext().animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
      this.selectionMode = true
      this.selectedPaths = []
      this.selectedEntryCount = 0
    })
  }

  private enterSelection(entry: FileEntry): void {
    this.closeActionMenu()
    this.showSelectionMoreMenu = false
    this.getUIContext().animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
      this.selectionMode = true
      const nextPaths = this.isSelected(entry) ? this.selectedPaths : [entry.path]
      this.selectedPaths = nextPaths
      this.selectedEntryCount = nextPaths.length
    })
  }

  private toggleSelection(entry: FileEntry): void {
    let nextPaths: string[] = []
    if (this.isSelected(entry)) {
      nextPaths = this.selectedPaths.filter((path: string) => path !== entry.path)
    } else {
      nextPaths = this.selectedPaths.concat([entry.path])
    }
    this.selectedPaths = nextPaths
    this.selectedEntryCount = nextPaths.length
  }

  private isSelected(entry: FileEntry): boolean {
    return this.selectedPaths.indexOf(entry.path) >= 0
  }

  private selectionTitle(): string {
    const count = this.selectedEntryCount
    return count === 0 ? '未选择' : '已选择 ' + count.toString() + ' 项'
  }

  private fileHeaderLeadingVisible(): boolean {
    return this.selectionMode || this.currentPath.length > 0
  }

  private fileHeaderLeadingWidth(): number {
    return this.fileHeaderLeadingVisible() ? 40 : 86
  }

  private topActionButtonWidth(): number {
    if (!this.selectionMode) {
      return 62
    }
    return this.allEntriesSelected() ? 104 : 62
  }

  private topActionButtonX(): number {
    return this.selectionMode ? 110 - this.topActionButtonWidth() : 0
  }

  private selectionAllTitle(): string {
    return this.allEntriesSelected() ? '取消全选' : '全选'
  }

  private allEntriesSelected(): boolean {
    return this.entries.length > 0 && this.selectedPaths.length === this.entries.length &&
      this.entries.every((entry: FileEntry): boolean => this.isSelected(entry))
  }

  private toggleSelectAll(): void {
    const nextPaths = this.allEntriesSelected()
      ? []
      : this.entries.map((entry: FileEntry): string => entry.path)
    this.selectedPaths = nextPaths
    this.selectedEntryCount = nextPaths.length
  }

  private selectedEntriesInCurrentDirectory(): FileEntry[] {
    return this.entries.filter((entry: FileEntry): boolean => this.isSelected(entry))
  }

  private selectedSingleEntry(): FileEntry | null {
    const selected = this.selectedEntriesInCurrentDirectory()
    return selected.length === 1 ? selected[0] : null
  }

  private selectedCachedEntries(): FileEntry[] {
    return this.selectedEntriesInCurrentDirectory().filter((entry: FileEntry): boolean => {
      return this.actionHasLocalCache(entry)
    })
  }

  private selectionCanShare(): boolean {
    const selected = this.selectedEntriesInCurrentDirectory()
    return selected.length > 0 && selected.every((entry: FileEntry): boolean => {
      return !entry.isDirectory && this.actionSupportsShare(entry)
    })
  }

  private selectionActionEnabled(title: string): boolean {
    return title === '分享' ? this.selectionCanShare() : this.selectedEntryCount > 0
  }

  private toggleSelectionMoreMenu(): void {
    if (this.selectedPaths.length === 0) {
      return
    }
    this.showSelectionMoreMenu = !this.showSelectionMoreMenu
  }

  private closeSelectionMoreMenu(): void {
    this.showSelectionMoreMenu = false
  }

  private exitSelectionMode(): void {
    this.closeSelectionMoreMenu()
    this.getUIContext().animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
      this.selectionMode = false
      this.selectedPaths = []
      this.selectedEntryCount = 0
    })
  }

  private beginSelectionDestinationPicker(operation: DestinationOperation): void {
    const selected = this.selectedEntriesInCurrentDirectory()
    if (selected.length === 0 || this.isBusy) {
      return
    }
    this.exitSelectionMode()
    this.beginDestinationPickerForEntries(operation, selected)
  }

  private async confirmMeteredSelection(entries: FileEntry[]): Promise<boolean> {
    await this.ensureNetworkState()
    if (!this.networkPolicy.isMetered()) {
      return true
    }
    await this.ensureCacheState()
    let requiresDownload = false
    for (const entry of entries) {
      if (entry.isDirectory) {
        requiresDownload = true
        break
      }
      if (this.isVideo(entry)) {
        try {
          await this.refreshVideoManager()
          if ((await this.videoTransferManager.resolveLocal(entry)).length > 0) {
            continue
          }
        } catch (_) {
          // Treat an unavailable local index as a download requirement.
        }
      } else if (CacheManager.findExisting(this.cacheDirectory, entry.name,
        this.originalCacheKey(entry)).length > 0) {
        continue
      }
      requiresDownload = true
      break
    }
    if (!requiresDownload) {
      return true
    }
    if (this.networkClass === 'offline') {
      return false
    }
    const response = await promptAction.showDialog({
      title: '使用移动网络分享？',
      message: entries.length.toString() + ' 个文件需要先缓存到本机',
      buttons: [
        { text: '取消', color: this.isDarkTheme ? '#FFFFFFFF' : '#536174' },
        { text: '继续', color: '#2E6BFF' }
      ],
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false)
    })
    return response.index === 1
  }

  private async shareSelectedEntries(): Promise<void> {
    const entries = this.selectedEntriesInCurrentDirectory()
    if (!this.selectionCanShare() || this.isBusy) {
      return
    }
    this.closeSelectionMoreMenu()
    if (!await this.confirmMeteredSelection(entries)) {
      return
    }
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在准备分享…'
    try {
      const localPaths: string[] = []
      for (const entry of entries) {
        localPaths.push(await this.ensureCachedFile(entry))
      }
      if (localPaths.length === 0) {
        return
      }
      const firstEntry = entries[0]
      const sharedData = new systemShare.SharedData(this.shareRecord(firstEntry, localPaths[0]))
      for (let index = 1; index < entries.length; index += 1) {
        const entry = entries[index]
        sharedData.addRecord(this.shareRecord(entry, localPaths[index]))
      }
      const context = getContext(this) as common.UIAbilityContext
      const shareController = new systemShare.ShareController(sharedData)
      await shareController.show(context, {
        selectionMode: entries.length > 1
          ? systemShare.SelectionMode.BATCH : systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DEFAULT
      })
      this.exitSelectionMode()
      this.statusText = '已打开系统分享'
    } catch (error) {
      this.reportError(error as Object, '分享失败')
      this.statusText = '分享失败'
    } finally {
      this.isBusy = false
    }
  }

  private async deleteSelectedEntries(): Promise<void> {
    const entries = this.selectedEntriesInCurrentDirectory()
    if (entries.length === 0 || this.isBusy) {
      return
    }
    this.closeSelectionMoreMenu()
    const response = await promptAction.showDialog({
      title: '删除 ' + entries.length.toString() + ' 项？',
      message: '所选项目会移入云盘回收站，可在云盘中恢复。',
      buttons: [
        { text: '取消', color: this.isDarkTheme ? '#FFFFFFFF' : '#536174' },
        { text: '删除', color: '#D34D5C' }
      ],
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false)
    })
    if (response.index !== 1) {
      return
    }
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在移入云盘回收站…'
    try {
      for (const entry of entries) {
        await this.repository.trash(entry)
      }
      await this.refreshCurrentDirectory()
      this.exitSelectionMode()
      this.statusText = '已移入回收站'
      this.showImmersiveToast('已移入云盘回收站')
    } catch (error) {
      this.reportError(error as Object, '删除失败')
      this.statusText = '删除失败'
    } finally {
      this.isBusy = false
    }
  }

  private async downloadSelectedEntries(): Promise<void> {
    const entries = this.selectedEntriesInCurrentDirectory()
    if (entries.length === 0 || this.isBusy) {
      return
    }
    this.closeSelectionMoreMenu()
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在加入下载队列…'
    try {
      await this.ensureDownloadState()
      await this.refreshVideoManager()
      const destinationRoot = await DownloadDestination.directory()
      let count = 0
      for (const entry of entries) {
        if (entry.isDirectory) {
          count += await this.enqueueRemoteTree(entry, destinationRoot, entry.name)
        } else if (this.isVideo(entry)) {
          this.videoTransferManager.requestDownload(entry).catch((): void => {})
          count += 1
        } else {
          await this.downloadQueue.enqueue(entry)
          count += 1
        }
      }
      this.exitSelectionMode()
      this.statusText = count > 0 ? '已加入下载队列' : '没有可下载文件'
      if (count > 0) {
        this.showImmersiveToast('已加入下载队列')
      }
    } catch (error) {
      this.reportError(error as Object, '加入下载失败')
      this.statusText = '加入下载失败'
    } finally {
      this.isBusy = false
    }
  }

  private async releaseSelectedCaches(): Promise<void> {
    const entries = this.selectedCachedEntries()
    if (entries.length === 0 || this.isBusy) {
      return
    }
    this.closeSelectionMoreMenu()
    this.isBusy = true
    try {
      await this.refreshVideoManager()
      for (const entry of entries) {
        if (this.isVideo(entry)) {
          await this.videoTransferManager.clearCache(entry)
        } else {
          const path = CacheManager.findExisting(this.cacheDirectory, entry.name,
            this.originalCacheKey(entry))
          if (path.length > 0) {
            await CacheManager.remove(path)
          }
        }
      }
      await this.refreshCacheUsage()
      this.exitSelectionMode()
      this.statusText = '已释放缓存'
      this.showImmersiveToast('已释放缓存')
    } catch (error) {
      this.reportError(error as Object, '释放缓存失败')
    } finally {
      this.isBusy = false
    }
  }

  private async saveSelectedGallery(entry: FileEntry): Promise<void> {
    this.exitSelectionMode()
    await this.saveToGallery(entry)
  }

  private async openWithSelectedEntry(entry: FileEntry): Promise<void> {
    this.exitSelectionMode()
    await this.openWithOtherApp(entry)
  }

  private async quickViewSelectedEntry(entry: FileEntry): Promise<void> {
    this.exitSelectionMode()
    await this.quickView(entry)
  }

  private renameSelectedEntry(entry: FileEntry): void {
    this.exitSelectionMode()
    this.openRename(entry)
  }

  private async showEntryDetailsSelected(entry: FileEntry): Promise<void> {
    this.exitSelectionMode()
    await this.showEntryDetails(entry)
  }

  private fileSortTitle(): string {
    switch (this.fileSortKey) {
      case 'name':
        return '按名称排序'
      case 'type':
        return '按类型排序'
      case 'size':
        return '按大小排序'
      case 'time':
      default:
        return '按时间排序'
    }
  }

  private toggleFileSortMenu(): void {
    if (this.isBusy) {
      return
    }
    this.showFileSortMenu = !this.showFileSortMenu
  }

  private closeFileSortMenu(): void {
    this.showFileSortMenu = false
  }

  private selectFileSort(key: FileSortKey): void {
    if (this.fileSortKey === key) {
      this.fileSortAscending = !this.fileSortAscending
    } else {
      this.fileSortKey = key
      this.fileSortAscending = key === 'name' || key === 'type'
    }
    this.closeFileSortMenu()
    this.replaceEntries(this.entries)
  }

  private openCreateFolder(): void {
    if (this.isBusy || this.screen !== 'files' || this.currentPath.length === 0) {
      return
    }
    this.closeFileSortMenu()
    this.newFolderText = ''
    this.errorText = ''
    this.getUIContext().animateTo({
      duration: 280,
      curve: curves.interpolatingSpring(0, 1, 320, 30)
    }, () => {
      this.showCreateFolderDialog = true
    })
  }

  private closeCreateFolder(): void {
    if (this.isBusy) {
      return
    }
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
      this.showCreateFolderDialog = false
      this.newFolderText = ''
    })
  }

  private async confirmCreateFolder(): Promise<void> {
    if (this.isBusy || !this.showCreateFolderDialog || this.currentPath.length === 0) {
      return
    }
    const name = this.newFolderText.trim()
    if (name.length === 0 || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0) {
      this.presentErrorMessage('文件夹名称不能为空，且不能包含路径分隔符', '新建文件夹失败')
      return
    }
    const parent = this.currentPath.replace(/\/+$/, '')
    const path = parent + '/' + name
    this.isBusy = true
    this.errorText = ''
    try {
      await this.repository.createFolder(path)
      await this.refreshCurrentDirectory()
      this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
        this.showCreateFolderDialog = false
        this.newFolderText = ''
      })
      this.showImmersiveToast('文件夹已创建')
    } catch (error) {
      this.reportError(error as Object, '新建文件夹失败')
    } finally {
      this.isBusy = false
    }
  }

  private openRename(entry: FileEntry): void {
    this.closeActionMenu()
    this.renameEntry = entry
    this.renameText = entry.name
    this.showRenameDialog = true
    this.errorText = ''
  }

  private closeRename(): void {
    if (this.isBusy) {
      return
    }
    this.showRenameDialog = false
    this.renameEntry = null
    this.renameText = ''
  }

  private async confirmRename(): Promise<void> {
    if (this.isBusy || this.renameEntry === null) {
      return
    }
    const newName = this.renameText.trim()
    if (newName.length === 0 || newName.indexOf('/') >= 0 || newName.indexOf('\\') >= 0) {
      this.presentErrorMessage('名称不能为空，且不能包含路径分隔符', '重命名失败')
      return
    }
    const entry = this.renameEntry
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在重命名…'
    try {
      await this.repository.rename(entry, newName)
      await this.refreshCurrentDirectory()
      if (this.showImageViewer) {
        for (const updatedEntry of this.entries) {
          if (updatedEntry.path === entry.path) {
            const nextImages: FileEntry[] = []
            for (const imageEntry of this.viewerImages) {
              nextImages.push(imageEntry.path === entry.path ? updatedEntry : imageEntry)
            }
            this.replaceViewerImages(nextImages)
            this.viewerImageEntry = updatedEntry
            if (this.viewerImageIndex >= 0 && this.viewerImageIndex < nextImages.length &&
              nextImages[this.viewerImageIndex].path === updatedEntry.path) {
              this.viewerHeaderTitle = updatedEntry.name
            }
            break
          }
        }
      }
      this.closeRename()
      this.statusText = '重命名成功'
      this.showImmersiveToast('已重命名为：' + newName)
    } catch (error) {
      this.reportError(error as Object, '重命名失败')
      this.statusText = '重命名失败'
    } finally {
      this.isBusy = false
    }
  }

  private async deleteEntry(entry: FileEntry): Promise<void> {
    if (this.isBusy) {
      return
    }
    this.closeActionMenu()
    const response = await promptAction.showDialog({
      title: '删除文件？',
      message: '文件会移入云盘回收站，可在云盘中恢复。',
      buttons: [
        { text: '取消', color: this.isDarkTheme ? '#FFFFFFFF' : '#536174' },
        { text: '删除', color: '#D34D5C' }
      ],
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false)
    })
    if (response.index !== 1) {
      return
    }
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在移入云盘回收站…'
    try {
      await this.repository.trash(entry)
      await this.removePersistedViewerRotation(entry)
      await this.refreshCurrentDirectory()
      this.statusText = '已移入回收站'
      this.showImmersiveToast('已移入云盘回收站')
    } catch (error) {
      this.reportError(error as Object, '删除失败')
      this.statusText = '删除失败'
    } finally {
      this.isBusy = false
    }
  }

  private async refreshCurrentDirectory(): Promise<void> {
    if (this.currentPath.length === 0) {
      this.repository.clearDirectoryCache()
      const root = await this.repository.getRootWithCache(true)
      this.personalRoots = root.personal
      this.sharedRoots = root.shared
      this.setCurrentPageState(1, false)
      this.replaceEntries(this.rootKind === 'personal' ? this.personalRoots : this.sharedRoots)
      this.resetPreviewState()
      return
    }
    const visiblePageIndex = Math.max(1, this.currentPageIndex)
    this.navigationRequestId += 1
    this.repository.invalidateDirectory(this.currentPath, this.currentRootType)
    const refreshed = await this.loadVisibleDirectoryPages(this.currentPath, this.currentRootType,
      visiblePageIndex, true)
    this.setCurrentPageState(refreshed.pageIndex, refreshed.hasMore)
    this.replaceEntries(refreshed.entries)
    this.updateDirectoryCount(this.currentPath, refreshed.totalCount >= 0
      ? refreshed.totalCount : refreshed.entries.length)
    this.resetPreviewState()
  }

  private async loadVisibleDirectoryPages(path: string, rootType: number,
    desiredPageIndex: number, forceNetwork: boolean): Promise<VisibleDirectoryPageSet> {
    const entries: FileEntry[] = []
    const seen: Record<string, boolean> = {}
    let pageIndex = 1
    let hasMore = false
    let totalCount = -1
    while (pageIndex <= desiredPageIndex) {
      const page = await this.repository.listPage(path, rootType, pageIndex, forceNetwork)
      for (const entry of page.entries) {
        if (entry.path.length === 0 || seen[entry.path] === true) {
          continue
        }
        seen[entry.path] = true
        entries.push(entry)
      }
      if (page.totalCount >= 0) {
        totalCount = page.totalCount
      }
      hasMore = page.hasMore && page.entries.length > 0
      if (!hasMore || page.entries.length === 0) {
        break
      }
      pageIndex += 1
    }
    return { entries: entries, pageIndex: pageIndex, hasMore: hasMore, totalCount: totalCount }
  }

  private fileIcon(entry: FileEntry): Resource {
    const extension = this.fileExtension(entry.name)
    if (this.isImage(entry)) {
      return $r('sys.media.ohos_ic_normal_white_grid_image')
    }
    if (this.isVideo(entry)) {
      return $r('sys.media.ohos_ic_normal_white_grid_video')
    }
    if (this.isAudio(entry)) {
      return $r('sys.media.ohos_ic_normal_white_grid_audio')
    }
    if (extension === 'pdf') {
      return $r('sys.media.ohos_ic_normal_white_grid_pdf')
    }
    if (extension === 'doc' || extension === 'docx' || extension === 'txt') {
      return $r('sys.media.ohos_ic_normal_white_grid_doc')
    }
    if (extension === 'zip' || extension === 'rar' || extension === '7z') {
      return $r('sys.media.ohos_ic_normal_white_grid_compress')
    }
    return $r('sys.media.ohos_ic_normal_white_grid_doc')
  }

  private fileIconColor(entry: FileEntry): string {
    if (this.isImage(entry)) {
      return '#4C86E8'
    }
    if (this.isVideo(entry)) {
      return '#8B6DE8'
    }
    if (this.isAudio(entry)) {
      return '#D37AD8'
    }
    if (this.fileExtension(entry.name) === 'pdf') {
      return '#D34D5C'
    }
    return '#6D7D95'
  }

  private previewSignature(entry: FileEntry): string {
    return entry.modifiedTime.toString() + ':' + entry.size.toString()
  }

  private previewUri(entry: FileEntry): string {
    const state = this.imageVisualState(entry.path)
    return state.thumbnailUri.length > 0 &&
      state.thumbnailSignature === this.previewSignature(entry) ? state.thumbnailUri : ''
  }

  private setPreviewUri(entry: FileEntry, uri: string, localPath: string = '',
    canonical: boolean = false): void {
    const path = entry.path
    if (path.length === 0 || uri.length === 0) {
      return
    }
    // Viewer-time derivatives are already persisted by the cache manager.
    // Keep the mounted file surface byte-for-byte stable until the return
    // transition has finished; the next normal preview warmup may adopt them.
    if (this.showImageViewer || this.viewerEntryTransitionActive || this.viewerClosePending) {
      return
    }
    const order: string[] = this.previewUriOrder.filter((key: string): boolean => key !== path)
    order.push(path)
    const evictedPaths: string[] = []
    while (order.length > 96) {
      const evicted = order.shift()
      if (evicted !== undefined) {
        evictedPaths.push(evicted)
      }
    }
    const nextLocalPaths: Record<string, string> = {}
    const nextCanonicalPaths: Record<string, boolean> = {}
    const signature = this.previewSignature(entry)
    for (const key of order) {
      if (key === path) {
        if (localPath.length > 0) {
          nextLocalPaths[key] = localPath
        }
        if (canonical) {
          nextCanonicalPaths[key] = true
        }
      } else {
        const existingLocalPath = this.previewLocalPaths[key]
        if (typeof existingLocalPath === 'string' && existingLocalPath.length > 0) {
          nextLocalPaths[key] = existingLocalPath
        }
        if (this.previewCanonicalPaths[key] === true) {
          nextCanonicalPaths[key] = true
        }
      }
    }
    this.previewUriOrder = order
    this.previewLocalPaths = nextLocalPaths
    this.previewCanonicalPaths = nextCanonicalPaths
    this.updateImageVisualState(path, (state: ImageVisualState): void => {
      if (state.thumbnailUri !== uri || state.thumbnailSignature !== signature) {
        state.thumbnailDecodedUri = ''
      }
      state.thumbnailUri = uri
      state.thumbnailSignature = signature
      state.thumbnailOrientation = canonical
        ? ImageRotateOrientation.UP : ImageRotateOrientation.AUTO
    })
    for (const evictedPath of evictedPaths) {
      this.releaseFileThumbnailBitmap(evictedPath)
      this.updateImageVisualState(evictedPath, (state: ImageVisualState): void => {
        state.thumbnailUri = ''
        state.thumbnailSignature = ''
        if (state.thumbnailVisibleRatio <= 0) {
          state.transitionThumbnailUri = ''
        }
      })
    }
  }

  private replaceEntries(nextEntries: FileEntry[], appendWaterfall: boolean = false): void {
    this.entries = this.sortEntriesForDisplay(nextEntries)
    this.currentDirectoryHasImages = this.hasDirectImageFiles(this.entries)
    if (!this.currentDirectoryHasImages && this.fileViewMode === 'waterfall') {
      this.stopWaterfallPipeline()
      this.fileViewMode = 'list'
      this.waterfallAnchor = null
    }
    this.fileEntryDataSource.replace(this.entries)
    this.syncWaterfallEntries(this.entries, appendWaterfall)
    this.refreshFileListImageRotations(this.entries)
  }

  private appendEntries(nextEntries: FileEntry[]): void {
    if (nextEntries.length === 0) {
      return
    }
    const existing: Record<string, boolean> = {}
    for (const item of this.entries) {
      existing[item.path] = true
    }
    const unique: FileEntry[] = []
    for (const item of nextEntries) {
      if (item.path.length === 0 || existing[item.path] === true) {
        continue
      }
      existing[item.path] = true
      unique.push(item)
    }
    if (unique.length === 0) {
      return
    }
    this.replaceEntries(this.entries.concat(unique), true)
  }

  private syncWaterfallEntries(entries: FileEntry[], appendOnly: boolean): void {
    const nextImages: FileEntry[] = []
    for (const entry of entries) {
      if (!entry.isDirectory && this.isImage(entry)) {
        nextImages.push(entry)
      }
    }
    const previous = this.waterfallEntries
    if (appendOnly && nextImages.length >= previous.length) {
      let keepsPrefix = true
      for (let index = 0; index < previous.length; index++) {
        if (nextImages[index].path !== previous[index].path) {
          keepsPrefix = false
          break
        }
      }
      if (keepsPrefix && nextImages.length > previous.length) {
        this.waterfallEntries = nextImages
        this.waterfallDataSource.append(nextImages.slice(previous.length))
        return
      }
    }
    let unchanged = previous.length === nextImages.length
    if (unchanged) {
      for (let index = 0; index < previous.length; index++) {
        if (previous[index].path !== nextImages[index].path) {
          unchanged = false
          break
        }
      }
    }
    if (!unchanged) {
      this.waterfallEntries = nextImages
      this.waterfallDataSource.replace(nextImages)
    }
  }

  private hasDirectImageFiles(entries: FileEntry[]): boolean {
    for (const entry of entries) {
      if (!entry.isDirectory && this.isImage(entry)) {
        return true
      }
    }
    return false
  }

  private fileViewModeIcon(): Resource {
    if (this.fileViewMode === 'list') {
      return $r('sys.symbol.square_grid_2x2')
    }
    if (this.fileViewMode === 'grid' && this.currentDirectoryHasImages) {
      // Official ArkUI system symbol for the waterfall target mode.
      return $r('sys.symbol.waterfall')
    }
    return $r('sys.symbol.list_bullet_square')
  }

  private sortEntriesForDisplay(entries: FileEntry[]): FileEntry[] {
    const sorted = entries.slice()
    sorted.sort((left: FileEntry, right: FileEntry): number => {
      if (left.isDirectory !== right.isDirectory) {
        return left.isDirectory ? -1 : 1
      }

      let comparison = 0
      switch (this.fileSortKey) {
        case 'name':
          comparison = left.name.localeCompare(right.name)
          break
        case 'type': {
          const leftType = left.isDirectory ? '' : this.fileExtension(left.name)
          const rightType = right.isDirectory ? '' : this.fileExtension(right.name)
          comparison = leftType.localeCompare(rightType)
          break
        }
        case 'size':
          comparison = left.size - right.size
          break
        case 'time':
        default:
          comparison = left.modifiedTime - right.modifiedTime
          break
      }

      if (comparison !== 0) {
        return this.fileSortAscending ? comparison : -comparison
      }
      return left.name.localeCompare(right.name)
    })
    return sorted
  }

  private resetWaterfallDirectoryState(): void {
    this.stopWaterfallPipeline()
    this.waterfallLocalPaths = {}
    this.waterfallAspectRatios = {}
    this.waterfallAnchor = null
    this.waterfallVisibleStartIndex = 0
    this.waterfallVisibleEndIndex = 0
  }

  private resetPreviewState(resetScroll: boolean = true): void {
    this.previewGeneration += 1
    this.loadingNextPage = false
    // Keep the bounded URI LRU across directory snapshots. The signature
    // check in previewUri prevents a changed remote file from reusing stale
    // content, while returning to a parent directory can render a known
    // thumbnail immediately.
    this.previewRequests = {}
    this.previewQueue.cancelPending()
    this.directoryCountRequests = {}
    this.directoryCountTimers = {}
    this.resetWaterfallDirectoryState()
    if (resetScroll) {
      this.resetFileListScroll()
    }
    this.schedulePreviewWarmup(this.previewGeneration)
  }

  private schedulePreviewWarmup(generation: number): void {
    setTimeout((): void => {
      if (generation !== this.previewGeneration || this.screen !== 'files' || this.showSearch ||
        this.fileViewMode === 'waterfall') {
        return
      }
      const limit = this.networkPolicy.isMetered()
        ? (this.fileViewMode === 'grid' ? 8 : 6)
        : (this.fileViewMode === 'grid' ? 16 : 12)
      let scheduled = 0
      for (const entry of this.entries) {
        if (scheduled >= limit) {
          break
        }
        if (entry.isDirectory || (!this.isImage(entry) && !this.isVideo(entry) && !this.isAudio(entry))) {
          continue
        }
        this.loadEntryPreview(entry, scheduled)
        scheduled += 1
      }
    }, 0)
  }

  private resetFileListScroll(): void {
    // The active container is reused when `entries` changes, so ArkUI keeps
    // the previous directory's offset unless we explicitly reset it.
    setTimeout((): void => {
      try {
        if (this.fileViewMode === 'waterfall') {
          this.waterfallScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false })
        } else {
          this.fileListScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false })
        }
      } catch (_) {
        // The new directory may not have completed its first layout pass.
      }
    }, 0)
  }

  private async refreshEntryPreviewFromViewer(entry: FileEntry, displayPath: string): Promise<void> {
    if (!this.isImage(entry) || displayPath.length === 0) {
      return
    }
    try {
      const previewPath = await this.mediaPreviewManager.fromLocal(entry, displayPath,
        this.thumbnailDirectory, this.thumbnailCacheLimitBytes)
      if (previewPath.length > 0) {
        // This local thumbnail was encoded from the canonical display copy;
        // unlike the NAS thumbnail, its pixel data is already upright. The
        // URI marker makes rendering use UP without overwriting the persisted
        // correction needed when the NAS thumbnail is used again.
        await this.primeViewerPreviewGeometryAtPath(entry, previewPath, true)
        this.setPreviewUri(entry, fileUri.getUriFromPath(previewPath), previewPath, true)
      }
    } catch (error) {
      console.warn('[UgreenPreview] canonical viewer preview failed: ' + entry.path + ': ' +
        JSON.stringify(error))
    }
  }

  private loadEntryPreview(entry: FileEntry, priority: number = 0): void {
    if (entry.isDirectory || (!this.isImage(entry) && !this.isVideo(entry) && !this.isAudio(entry))) {
      return
    }
    if (this.isImage(entry)) {
      const canonicalPath = this.mediaPreviewManager.cachedImagePreview(entry,
        this.thumbnailDirectory)
      if (canonicalPath.length > 0) {
        this.publishImagePreview(entry, canonicalPath, true, this.previewGeneration)
          .catch((): void => {})
        return
      }
      const retainedPath = this.previewLocalPaths[entry.path]
      if (typeof retainedPath === 'string' && retainedPath.length > 0 &&
        CacheManager.exists(retainedPath)) {
        this.publishImagePreview(entry, retainedPath,
          this.previewCanonicalPaths[entry.path] === true, this.previewGeneration)
          .catch((): void => {})
        return
      }
    }
    if (this.previewUri(entry).length > 0 || this.previewRequests[entry.path] === true) {
      return
    }
    const generation = this.previewGeneration
    this.previewRequests[entry.path] = true
    // A running task from an old directory generation must not reject a new
    // task for the same path after the user returns to that directory.
    const queueKey = entry.path + '#preview:' + generation.toString()
    const accepted = this.previewQueue.enqueue(queueKey, priority, async (): Promise<void> => {
      await this.loadEntryPreviewNow(entry, generation)
    })
    if (!accepted) {
      this.previewRequests[entry.path] = false
    }
  }

  private async loadEntryPreviewNow(entry: FileEntry, generation: number): Promise<void> {
    try {
      await this.ensureCacheState()
      if (generation !== this.previewGeneration) {
        return
      }

      // A viewer-derived thumbnail has canonical upright pixels and is the
      // only safe base for persisted manual rotations. Prefer it over the NAS
      // thumbnail, whose service response may have stripped EXIF metadata.
      if (this.isImage(entry)) {
        const canonicalPath = this.mediaPreviewManager.cachedImagePreview(entry,
          this.thumbnailDirectory)
        if (canonicalPath.length > 0) {
          await this.publishImagePreview(entry, canonicalPath, true, generation)
          return
        }
      }

      // Prefer a NAS-generated thumbnail. The repository also handles the
      // thumbnail cache and de-duplicates the short-lived signed URL. A bad
      // thumbnail response must not prevent the already-cached original from
      // producing a local fallback.
      let thumbnailPath = ''
      try {
        thumbnailPath = await this.repository.prepareThumbnail(entry, this.thumbnailDirectory,
          this.thumbnailCacheLimitBytes, 'list')
      } catch (error) {
        console.warn('[UgreenPreview] server thumbnail failed: ' + entry.path + ': ' +
          JSON.stringify(error))
      }
      if (generation !== this.previewGeneration) {
        return
      }
      if (thumbnailPath.length > 0) {
          await this.publishThumbnailPreview(entry, thumbnailPath, false, generation)
        return
      }

    } catch (error) {
      // A failed thumbnail must never make the directory itself fail to
      // render, but retain evidence for diagnosing transient NAS/decoder
      // failures and for a later retry triggered by a new appearance.
      console.warn('[UgreenPreview] load failed: ' + entry.path + ': ' + JSON.stringify(error))
    } finally {
      if (generation === this.previewGeneration) {
        this.previewRequests[entry.path] = false
      }
    }
  }

  private async toggleDownloadTask(task: DownloadTaskRecord): Promise<void> {
    try {
      await this.ensureDownloadState()
      if (task.id.startsWith('upload:')) { await this.uploadQueue.toggle(task.id); return }
      if (task.id.startsWith('video:')) { await this.videoTransferManager.toggleTask(task.id); return }
      const accepted = await this.downloadQueue.toggleTask(task.id)
      if (!accepted) {
        this.showImmersiveToast('请按顺序下载')
        return
      }
      if (task.status === 'downloading') {
        this.showImmersiveToast('已暂停下载')
      } else if (task.status !== 'completed') {
        this.showImmersiveToast('已继续下载')
      }
    } catch (error) {
      this.reportError(error as Object, '下载操作失败')
    }
  }

  private async confirmRemoveDownloadTask(task: DownloadTaskRecord): Promise<void> {
    if (task.id.startsWith('upload:')) {
      const response = await promptAction.showDialog({ title: '移除上传记录？',
        message: task.status === 'completed' ? '只移除记录，保留云盘中的文件。' :
          '清理此次上传的本地暂存与云盘断点；原文件不受影响。',
        buttons: [{ text: '取消', color: '#536174' }, { text: '移除', color: '#D34D5C' }],
        systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false) })
      if (response.index === 1) {
        try { await this.uploadQueue.remove(task.id) }
        catch (error) { this.reportError(error as Object, '上传记录清理失败，请重试') }
      }
      return
    }
    const message = task.status === 'completed'
      ? '只移除下载记录，不会删除系统下载目录中的文件。'
      : '会删除当前未完成的临时文件，已下载的部分不能保留。'
    const response = await promptAction.showDialog({
      title: '移除下载记录？',
      message: message,
      buttons: [
        { text: '取消', color: this.isDarkTheme ? '#FFFFFFFF' : '#536174' },
        { text: '移除', color: '#D34D5C' }
      ],
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false)
    })
    if (response.index !== 1) {
      return
    }
    await this.ensureDownloadState()
    if (task.id.startsWith('video:')) { await this.videoTransferManager.removeTask(task.id) }
    else { await this.downloadQueue.removeRecord(task.id) }
    this.showImmersiveToast('已移除下载记录')
  }

  private downloadTaskEntry(task: DownloadTaskRecord): FileEntry {
    const entry = new FileEntry()
    entry.name = task.name
    entry.path = task.remotePath
    entry.size = task.size
    entry.mimeType = task.mimeType
    entry.isDirectory = false
    return entry
  }

  private downloadTaskProgress(task: DownloadTaskRecord): number {
    if (task.status === 'completed') {
      return 100
    }
    if (task.size <= 0) {
      return 0
    }
    return Math.min(99, Math.max(0, task.receivedBytes / task.size * 100))
  }

  private downloadTaskInfo(task: DownloadTaskRecord): string {
    if (task.id.startsWith('upload:')) {
      const upload = task as UploadTaskRecord
      const progress = this.formatSize(task.receivedBytes) + ' / ' + this.formatSize(task.size)
      if (upload.importing) { return '正在导入原文件…' }
      if (upload.skipped) { return '已跳过同名文件 · 未覆盖' }
      if (task.status === 'downloading') { return progress + ' · 上传中' }
      if (task.status === 'failed') { return progress + ' · ' + (task.errorMessage || '上传失败') }
      if (task.status === 'completed') { return this.formatSize(task.size) + ' · 已上传' }
      if (task.status === 'waiting_wifi') { return progress + ' · 等待 WiFi（点击继续）' }
      return progress + (task.status === 'paused' ? ' · 已暂停' : ' · 排队中')
    }
    const received = task.receivedBytes <= 0 ? '0 B' : this.formatSize(task.receivedBytes)
    const transfer = task.size > 0 ? received + ' / ' + this.formatSize(task.size) : received
    switch (task.status) {
      case 'downloading':
        return transfer + ' · 下载中'
      case 'waiting_wifi':
        return transfer + ' · 等待 WiFi'
      case 'paused':
        return transfer + ' · 已暂停'
      case 'failed':
        return transfer + ' · ' + (task.errorMessage || '下载失败')
      case 'completed':
        return this.formatSize(task.size) + ' · 已完成'
      default:
        return transfer + ' · 排队中'
    }
  }

  private hasActiveDownload(): boolean {
    if (this.downloadSpeedBytesPerSecond > 0) {
      return true
    }
    for (const task of this.downloadTasks) {
      if (task.status === 'downloading') {
        return true
      }
    }
    return false
  }

  private formatSpeed(bytesPerSecond: number): string {
    if (bytesPerSecond < 1024) {
      return Math.max(0, Math.round(bytesPerSecond)).toString() + ' B/s'
    }
    if (bytesPerSecond < 1024 * 1024) {
      return (bytesPerSecond / 1024).toFixed(1) + ' KB/s'
    }
    if (bytesPerSecond < 1024 * 1024 * 1024) {
      return (bytesPerSecond / (1024 * 1024)).toFixed(1) + ' MB/s'
    }
    return (bytesPerSecond / (1024 * 1024 * 1024)).toFixed(1) + ' GB/s'
  }

  private isMedia(entry: FileEntry): boolean {
    return this.isImage(entry) || this.isVideo(entry)
  }

  private isImage(entry: FileEntry): boolean {
    const mime = entry.mimeType.trim().toLowerCase()
    if (mime.startsWith('image/')) {
      return true
    }
    const extension = this.fileExtension(entry.name)
    return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tif', 'tiff'].indexOf(extension) >= 0
  }

  private isVideo(entry: FileEntry): boolean {
    const mime = entry.mimeType.trim().toLowerCase()
    if (mime.startsWith('video/')) {
      return true
    }
    const extension = this.fileExtension(entry.name)
    return ['mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm', '3gp', 'ts', 'mpeg', 'mpg',
      'm2ts', 'mts', 'wmv', 'flv', 'f4v', 'rmvb', 'asf'].indexOf(extension) >= 0
  }

  private isAudio(entry: FileEntry): boolean {
    const mime = entry.mimeType.trim().toLowerCase()
    if (mime.startsWith('audio/')) {
      return true
    }
    const extension = this.fileExtension(entry.name)
    return ['mp3', 'wav', 'm4a', 'flac', 'aac', 'ogg', 'amr'].indexOf(extension) >= 0
  }

  private fileType(entry: FileEntry): string {
    if (this.isImage(entry)) {
      return 'general.image'
    }
    if (this.isVideo(entry)) {
      return 'general.video'
    }
    const extension = this.fileExtension(entry.name)
    if (extension === 'pdf') {
      return 'application/pdf'
    }
    if (extension === 'txt' || extension === 'log' || extension === 'md') {
      return 'text/plain'
    }
    if (extension === 'zip') {
      return 'application/zip'
    }
    if (this.isAudio(entry)) {
      if (extension === 'mp3') {
        return 'audio/mpeg'
      }
      if (extension === 'wav') {
        return 'audio/wav'
      }
      if (extension === 'm4a') {
        return 'audio/mp4'
      }
      if (extension === 'flac') {
        return 'audio/flac'
      }
      if (extension === 'aac') {
        return 'audio/aac'
      }
      if (extension === 'ogg') {
        return 'audio/ogg'
      }
      if (extension === 'amr') {
        return 'audio/amr'
      }
    }
    return ''
  }

  private shareRecord(entry: FileEntry, localPath: string): systemShare.SharedRecord {
    const record: systemShare.SharedRecord = {
      utd: this.shareUtd(entry),
      uri: fileUri.getUriFromPath(localPath),
      title: entry.name,
      label: entry.name
    }
    const thumbnailUri = this.gestureShareThumbnailUri(entry)
    if (thumbnailUri.length > 0) {
      record.thumbnailUri = thumbnailUri
    }
    return record
  }

  private shareUtd(entry: FileEntry): string {
    const extension = this.fileExtension(entry.name)
    let belongsTo: string = utd.UniformDataType.FILE
    if (this.isImage(entry)) {
      belongsTo = utd.UniformDataType.IMAGE
    } else if (this.isVideo(entry)) {
      belongsTo = utd.UniformDataType.VIDEO
    } else if (this.isAudio(entry)) {
      belongsTo = utd.UniformDataType.AUDIO
    }
    if (extension.length === 0) {
      return belongsTo
    }
    try {
      const resolved = utd.getUniformDataTypeByFilenameExtension('.' + extension, belongsTo)
      return resolved.length > 0 ? resolved : belongsTo
    } catch (error) {
      console.warn('[UgreenShare] resolve UTD failed: ' + extension + ' ' + JSON.stringify(error))
      return belongsTo
    }
  }

  private async confirmLogout(): Promise<void> {
    if (this.isBusy) {
      return
    }
    const response = await promptAction.showDialog({
      title: '退出账号？',
      message: '退出后将清除当前登录会话，自动登录也会关闭。',
      buttons: [
        { text: '取消', color: this.isDarkTheme ? '#FFFFFFFF' : '#536174' },
        { text: '退出', color: '#D34D5C' }
      ],
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false)
    })
    if (response.index === 1) {
      await this.logout()
    }
  }

  private fileExtension(name: string): string {
    const dot = name.lastIndexOf('.')
    if (dot <= 0 || dot === name.length - 1) {
      return ''
    }
    return name.substring(dot + 1).toLowerCase()
  }

  private async logout(): Promise<void> {
    this.cancelFileTransition()
    this.clearSearchIfPresent()
    this.closeImageViewer()
    this.closeAudioPlayer()
    this.closeVideoPlayer()
    await this.videoTransferManager.flush()
    await this.ensureDownloadState()
    await this.downloadQueue.setReady(false)
    await this.uploadQueue.setReady(false)
    this.repository.logout()
    this.navigationRequestId += 1
    this.isNavigating = false
    this.screen = 'login'
    this.showStorageSettings = false
    this.showPlaybackSettings = false
    this.showNetworkSettings = false
    this.silentAutoLogin = false
    this.baseUrl = ''
    this.password = ''
    this.autoLogin = false
    this.otpCode = ''
    this.replaceEntries([])
    this.directoryCounts = {}
    this.directoryCountRequests = {}
    this.navigationStack = []
    this.navigationEntryStack = []
    this.navigationRootTypeStack = []
    this.navigationViewStateStack = []
    this.navigationPageIndexStack = []
    this.navigationPageHasMoreStack = []
    this.setCurrentPageState(1, false)
    this.bottomBarOffsetY = 0
    this.bottomBarOpacity = 1
    this.resetPreviewState()
    this.errorText = ''
    this.statusText = ''
    await this.persistLoginPreferences()
    this.showImmersiveToast('已退出账号')
  }

  private entryDisplayPath(entry: FileEntry): string {
    if (entry.path.length > 0) {
      return entry.path
    }
    if (this.currentPath.length === 0) {
      return '/' + entry.name
    }
    return this.currentPath.replace(/\/+$/, '') + '/' + entry.name
  }

  private formatFileInfo(entry: FileEntry): string {
    return this.formatSize(entry.size) + ' · ' + this.formatTime(entry.modifiedTime)
  }

  private entryInfo(entry: FileEntry): string {
    return entry.isDirectory ? this.formatDirectoryInfo(entry) : this.formatFileInfo(entry)
  }

  private formatDirectoryInfo(entry: FileEntry): string {
    const parts: string[] = []
    if (entry.modifiedTime > 0) {
      parts.push(this.formatTime(entry.modifiedTime))
    }
    const loadedCount = this.directoryCounts[entry.path]
    if (typeof loadedCount === 'number' && loadedCount >= 0) {
      parts.push(loadedCount.toString() + ' 项')
    } else if (entry.childCount >= 0) {
      parts.push(entry.childCount.toString() + ' 项')
    }
    return parts.join(' - ')
  }

  private scheduleCachedDirectoryCount(entry: FileEntry): void {
    if (!entry.isDirectory || entry.path.length === 0 || entry.childCount >= 0 ||
      typeof this.directoryCounts[entry.path] === 'number' ||
      this.directoryCountRequests[entry.path] === true ||
      this.directoryCountTimers[entry.path] > 0) {
      return
    }
    const generation = this.previewGeneration
    this.directoryCountTimers[entry.path] = setTimeout((): void => {
      if (generation !== this.previewGeneration) {
        return
      }
      this.directoryCountTimers[entry.path] = 0
      this.loadCachedDirectoryCount(entry)
    }, 350)
  }

  private async loadCachedDirectoryCount(entry: FileEntry): Promise<void> {
    if (!entry.isDirectory || entry.path.length === 0 ||
      entry.childCount >= 0 ||
      typeof this.directoryCounts[entry.path] === 'number' ||
      this.directoryCountRequests[entry.path] === true) {
      return
    }
    const generation = this.previewGeneration
    this.directoryCountRequests[entry.path] = true
    try {
      const count = await this.repository.cachedDirectoryCount(entry.path, 3)
      if (generation !== this.previewGeneration) {
        return
      }
      if (count < 0) {
        return
      }
      const next: Record<string, number> = {}
      for (const key of Object.keys(this.directoryCounts)) {
        next[key] = this.directoryCounts[key]
      }
      next[entry.path] = count
      this.directoryCounts = next
    } catch (_) {
      // A count request is decorative; a failed request must not affect browsing.
    } finally {
      if (generation === this.previewGeneration) {
        this.directoryCountRequests[entry.path] = false
      }
    }
  }

  private updateDirectoryCount(path: string, count: number): void {
    if (path.length === 0 || count < 0) {
      return
    }
    const next: Record<string, number> = {}
    for (const key of Object.keys(this.directoryCounts)) {
      next[key] = this.directoryCounts[key]
    }
    next[path] = count
    this.directoryCounts = next
  }

  private resolveEntryPath(entry: FileEntry): string {
    const path = entry.path.trim()
    if (path.length > 0) {
      return path
    }
    if (this.currentPath.length === 0) {
      return '/' + entry.name
    }
    return this.currentPath.replace(/\/+$/, '') + '/' + entry.name
  }

  private formatSize(size: number): string {
    if (size <= 0) {
      return '未知大小'
    }
    if (size < 1024) {
      return size.toString() + ' B'
    }
    if (size < 1024 * 1024) {
      return (size / 1024).toFixed(1) + ' KB'
    }
    if (size < 1024 * 1024 * 1024) {
      return (size / (1024 * 1024)).toFixed(1) + ' MB'
    }
    return (size / (1024 * 1024 * 1024)).toFixed(1) + ' GB'
  }

  private formatStorageSize(size: number): string {
    if (size >= 1024 * 1024 * 1024) {
      return (size / (1024 * 1024 * 1024)).toFixed(size % (1024 * 1024 * 1024) === 0 ? 0 : 1) + ' GB'
    }
    if (size >= 1024 * 1024) {
      return (size / (1024 * 1024)).toFixed(size % (1024 * 1024) === 0 ? 0 : 0) + ' MB'
    }
    if (size >= 1024) {
      return (size / 1024).toFixed(0) + ' KB'
    }
    return size.toString() + ' B'
  }

  private formatTime(value: number): string {
    if (value <= 0) {
      return '时间未知'
    }
    const date = new Date(value < 100000000000 ? value * 1000 : value)
    return date.getFullYear().toString() + '/' + (date.getMonth() + 1).toString().padStart(2, '0') +
      '/' + date.getDate().toString().padStart(2, '0')
  }

  private formatPlaybackTime(value: number): string {
    const totalSeconds = Math.floor(Math.max(0, value) / 1000)
    const minutes = Math.floor(totalSeconds / 60)
    const seconds = totalSeconds % 60
    return minutes.toString().padStart(2, '0') + ':' + seconds.toString().padStart(2, '0')
  }

  private videoBufferedTimelineMs(): number {
    if (this.videoDurationMs <= 0) {
      return 0
    }
    const estimated = this.videoDurationMs *
      Math.max(0, Math.min(100, this.videoBufferingPercent)) / 100
    // A BUFFERING_START callback is allowed to report zero while the decoder
    // is still consuming the last known window. Never draw the buffer behind
    // the playhead, which would make the progress bar visibly jump backwards.
    return Math.min(this.videoDurationMs, Math.max(this.videoCurrentMs, estimated))
  }
}
