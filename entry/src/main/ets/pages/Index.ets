import { promptAction, uiMaterial, curves, window, LengthMetrics } from '@kit.ArkUI'
import { systemShare, harmonyShare } from '@kit.ShareKit'
import { Context, Want, common, wantConstant } from '@kit.AbilityKit'
import { Environment, fileIo, fileUri } from '@kit.CoreFileKit'
import { preferences, uniformTypeDescriptor as utd } from '@kit.ArkData'
import { image } from '@kit.ImageKit'
import { DownloadTaskRecord, FileEntry } from '../model/FileEntry'
import { CacheManager } from '../download/CacheManager'
import { DownloadQueueManager } from '../download/DownloadQueueManager'
import { UserFileManager } from '../download/UserFileManager'
import { AudioPlaybackManager } from '../media/AudioPlaybackManager'
import { MediaPreviewManager } from '../media/MediaPreviewManager'
import { ImageRotationStore } from '../media/ImageRotationStore'
import { RemoteSearchScope, UgreenRemoteRepository } from '../repository/UgreenRemoteRepository'
import { BinaryDownloadProgress, BinaryProgressListener } from '../core/network/HttpTransport'
import { UgreenError, readableUgreenError } from '../ugreen/UgreenErrors'
import { FileEntryDataSource } from '../model/FileEntryDataSource'
import { PreviewLoadQueue } from '../media/PreviewLoadQueue'
import { ThumbnailPolicy, ThumbnailSize } from '../media/ThumbnailPolicy'
import { ThumbnailCacheStore } from '../media/ThumbnailCacheStore'
import { NetworkClass, NetworkPolicy } from '../core/network/NetworkPolicy'

type RemoteScreen = 'login' | 'otp' | 'files' | 'downloads' | 'settings'
type RootKind = 'personal' | 'shared'
type BottomTab = 'home' | 'shared' | 'downloads' | 'settings'
type PageTransitionDirection = 'push' | 'pop'
type FileViewMode = 'list' | 'grid' | 'waterfall'
type FileSortKey = 'name' | 'type' | 'time' | 'size'
type SearchReturnMode = 'none' | 'directory' | 'image' | 'audio' | 'download'
type FileAction = 'share' | 'openWith' | 'quickView' | 'multiSelect' | 'download' |
  'saveGallery' | 'releaseCache' | 'rename' | 'details' | 'delete' | 'copy' | 'move'
type DestinationOperation = 'copy' | 'move'

// Shared-element transitions are deliberately separate from the 180 ms
// Swiper animation.  The image should have enough time to travel from its
// file-row frame to the viewer without delaying network/decode work.
const IMAGE_GEOMETRY_TRANSITION_DURATION: number = 420
const IMAGE_GEOMETRY_TRANSITION_SETTLE: number = 520
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
const FLOATING_BAR_MIN_GAP_VP: number = 8
const FLOATING_BAR_MAX_GAP_VP: number = 16
const FLOATING_BAR_CONTENT_EXTRA_VP: number = 32

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
  @State networkClass: NetworkClass = 'unknown'
  @State meteredAutoOriginal: boolean = false
  @State meteredBackgroundRefresh: boolean = false
  @State meteredDownloadContinue: boolean = false
  @State downloadTasks: DownloadTaskRecord[] = []
  @State downloadSpeedBytesPerSecond: number = 0
  @State contextMenuVisible: boolean = false
  @State contextMenuEntry: FileEntry | null = null
  @State contextMenuAnchorX: number = 0
  @State contextMenuAnchorY: number = 0
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
  @State showImageViewer: boolean = false
  @State viewerImageEntry: FileEntry | null = null
  @State viewerHeaderTitle: string = ''
  @State viewerImages: FileEntry[] = []
  @State viewerImageIndex: number = 0
  // The Swiper index is committed at animation end, while the title and
  // bottom actions must follow the page that is entering during the swipe.
  // Keep that chrome binding explicit so a progress ring cannot reuse the
  // previous page's entry while the two Swiper indices briefly coexist.
  @State viewerChromeIndex: number = 0
  @State showImageMoreMenu: boolean = false
  @State showImageDetails: boolean = false
  @State viewerLastNavigationDirection: number = 1
  @State viewerManualRotations: Record<string, number> = {}
  @State viewerOriginalUris: Record<string, string> = {}
  @State viewerImageSourceSizes: Record<string, ThumbnailSize> = {}
  @State viewerImageLayoutSizes: Record<string, ThumbnailSize> = {}
  @State viewerImageOrientations: Record<string, ImageRotateOrientation> = {}
  @State viewerDecodedImages: Record<string, boolean> = {}
  @State viewerDownloadProgress: Record<string, number> = {}
  @State viewerDownloadProgressKnown: Record<string, boolean> = {}
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
  // The entry animation is limited to the image that was tapped. The normal
  // viewer swiper animation uses viewerTransitionActive and remains separate.
  @State viewerEntryTransitionActive: boolean = false
  @State viewerEntryTransitionPath: string = ''
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
  @State previewUris: Record<string, string> = {}
  @State previewUriSignatures: Record<string, string> = {}
  @State previewCanonicalPaths: Record<string, boolean> = {}
  @State fileListImageRotations: Record<string, number> = {}
  @State fileListImageBaseOrientations: Record<string, ImageRotateOrientation> = {}
  @State waterfallOriginalUris: Record<string, string> = {}
  @State waterfallAspectRatios: Record<string, number> = {}
  @State waterfallVisiblePaths: Record<string, boolean> = {}
  @State waterfallColumnWidthVp: number = 0
  @State directoryCounts: Record<string, number> = {}
  @State pageOffsetX: number = 0
  @State outgoingPageOffsetX: number = 0
  @State pageWidthVp: number = 360
  @State pageHeightVp: number = 800
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
  private repository: UgreenRemoteRepository = new UgreenRemoteRepository()
  private networkPolicy: NetworkPolicy = NetworkPolicy.shared()
  private downloadQueue: DownloadQueueManager = new DownloadQueueManager()
  private audioManager: AudioPlaybackManager = new AudioPlaybackManager()
  private mediaPreviewManager: MediaPreviewManager = new MediaPreviewManager()
  private imageRotationStore: ImageRotationStore = new ImageRotationStore()
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
  private contextMenuAnimationToken: number = 0
  private fileEntryDataSource: FileEntryDataSource = new FileEntryDataSource()
  private waterfallDataSource: FileEntryDataSource = new FileEntryDataSource()
  private viewerImageDataSource: FileEntryDataSource = new FileEntryDataSource()
  private fileListScroller: Scroller = new Scroller()
  private waterfallScroller: Scroller = new Scroller()
  // ImageViewer temporarily replaces the file surface with Blank(). Keep the
  // exact offset of the surface that launched it so returning from a preview
  // does not recreate the list/grid/waterfall at position zero.
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
  private viewerEntryTransitionTimer: number = 0
  private viewerEntryTransitionToken: number = 0
  private viewerCloseCleanupTimer: number = 0
  private viewerClosePending: boolean = false
  private lastImageDoubleTapAt: number = 0
  private imageTouchActive: boolean = false
  private imageTouchMoved: boolean = false
  private imageTouchStartX: number = 0
  private imageTouchStartY: number = 0
  private imageDismissDragging: boolean = false
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
  private loginPreferences: preferences.Preferences | null = null
  private searchPreferences: preferences.Preferences | null = null
  private cacheDirectory: string = ''
  private thumbnailDirectory: string = ''
  private thumbnailCacheLimitBytes: number = ThumbnailCacheStore.DEFAULT_LIMIT_BYTES
  private cacheStatePromise: Promise<void> | null = null
  private networkStatePromise: Promise<void> | null = null
  private loginStatePromise: Promise<void> | null = null
  private searchStatePromise: Promise<void> | null = null
  private imageRotationStatePromise: Promise<void> | null = null
  private downloadStatePromise: Promise<void> | null = null
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
    this.downloadTasks = tasks
    this.downloadSpeedBytesPerSecond = speed
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
    this.ensureCacheState()
    this.ensureNetworkState()
    this.ensureDownloadState()
    this.loginStatePromise = this.loadLoginPreferences()
    this.searchStatePromise = this.loadSearchPreferences()
    this.ensureImageRotationState()
    this.enableGestureShare()
  }

  aboutToDisappear(): void {
    this.disableGestureShare()
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
      const cachedPath = CacheManager.findExisting(this.cacheDirectory, entry.name,
        this.originalCacheKey(entry))
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

  // All file view modes share the same content origin below the common
  // TopFileOverlay. Keeping this in one helper prevents WaterFlow from
  // drifting away from the list/grid header geometry.
  private fileContentTopInset(): number {
    return this.topSafeInset() + 76
  }

  private bottomSafeInset(): number {
    return this.getUIContext().px2vp(this.navigationBarHeightPx)
  }

  private floatingBarGap(): number {
    const windowHeight = this.pageHeightVp > 0 ? this.pageHeightVp : 800
    return Math.min(FLOATING_BAR_MAX_GAP_VP,
      Math.max(FLOATING_BAR_MIN_GAP_VP, windowHeight * 0.02))
  }

  private floatingBarBottomMargin(): number {
    return this.bottomSafeInset() + this.floatingBarGap()
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
      return !this.showStorageSettings && !this.showNetworkSettings
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

  private shouldShowFileToolsBar(): boolean {
    return this.screen === 'files' && !this.showSearch &&
      !this.shouldShowBottomBar() && !this.contextMenuVisible &&
      !this.showRenameDialog &&
      !this.showImageViewer && !this.showAudioPlayer && !this.selectionMode
  }

  private updateBottomBarVisibility(animated: boolean = true): void {
    const shouldShow = this.shouldShowBottomBar()
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
    if (this.showRenameDialog) {
      this.closeRename()
      return true
    }
    if (this.contextMenuVisible) {
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
      .onAreaChange((_, area) => {
        if (typeof area.width === 'number' && area.width > 0) {
          this.pageWidthVp = area.width
        }
        if (typeof area.height === 'number' && area.height > 0) {
          this.pageHeightVp = area.height
        }
      })

      if ((this.screen === 'files' || this.screen === 'downloads' || this.screen === 'settings') &&
        !this.contextMenuVisible && !this.showRenameDialog &&
        !this.showDestinationPicker &&
        !this.showImageViewer &&
        !this.showAudioPlayer && !this.selectionMode) {
        Stack({ alignContent: Alignment.Bottom }) {
          this.FloatingBottomBar()
        }
        .width('100%')
        .height('100%')
        .translate({ x: 0, y: this.bottomBarOffsetY, z: 0 })
        .opacity(this.bottomBarOpacity)
        .zIndex(20)
        // The host is transparent and contains only the capsule. Its empty
        // area must pass through to the file surface below.
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.screen === 'files' && this.selectionMode &&
        !this.showDestinationPicker && !this.showRenameDialog &&
        !this.showImageViewer && !this.showAudioPlayer) {
        Stack({ alignContent: Alignment.Bottom }) {
          this.SelectionBottomBar()
        }
        .width('100%')
        .height('100%')
        .zIndex(21)
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.screen === 'downloads' && this.hasActiveDownload()) {
        this.DownloadSpeedBall()
      }

      if (this.shouldShowFileToolsBar() && !this.showDestinationPicker) {
        Stack({ alignContent: Alignment.Bottom }) {
          this.FileToolsBottomBar()
        }
        .width('100%')
        .height('100%')
        .zIndex(22)
        .hitTestBehavior(HitTestMode.None)
      }

      if ((this.screen === 'files' || this.screen === 'downloads' || this.screen === 'settings') &&
        !this.showDestinationPicker && !this.showImageViewer) {
        Stack({ alignContent: Alignment.TopStart }) {
          this.TopFileOverlay()
        }
        .width('100%')
        .height('100%')
        .zIndex(10)
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.contextMenuVisible && this.contextMenuEntry !== null) {
        this.ActionMenuOverlay(this.contextMenuEntry as FileEntry)
      }

      if (this.showDestinationPicker) {
        this.DestinationPickerOverlay()
      }
      if (this.showRenameDialog && this.renameEntry !== null && !this.showImageViewer &&
        !this.showDestinationPicker) {
        this.RenameOverlay()
      }
      if (this.showCreateFolderDialog && !this.showImageViewer && !this.showDestinationPicker) {
        this.CreateFolderOverlay()
      }
      if (this.destinationFolderDialog) {
        this.DestinationFolderOverlay()
      }
      if (this.showImageViewer && this.currentViewerEntry() !== null) {
        this.ImageViewer(this.currentViewerEntry() as FileEntry)
      }
      if (this.showAudioPlayer && this.audioEntry !== null) {
        this.AudioPlayerOverlay(this.audioEntry as FileEntry)
      }
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
  FileLeadingVisual(entry: FileEntry): void {
    if (this.shouldReplaceViewerTransitionSource(entry)) {
      // Keep the row's measured leading slot, but remove the old shared
      // element node itself. This is the source-side state change required
      // for the documented geometryTransition enter animation.
      Blank()
        .width(40)
        .height(34)
    } else {
      Stack() {
        if (this.previewUri(entry).length > 0) {
          Image(this.previewUri(entry))
            .width(40)
            .height(34)
            .orientation(this.fileListImageBaseOrientation(entry))
            .objectFit(ImageFit.Cover)
            .rotate({ angle: this.fileListImageRotation(entry.path) })
            .borderRadius(6)
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
      .geometryTransition(this.fileImageTransitionId(entry))
    }
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

          ForEach(this.searchResults, (entry: FileEntry) => {
            ListItem() {
              Row() {
                this.FileLeadingVisual(entry)
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
            this.scheduleCachedDirectoryCount(entry)
          })
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
            .height(this.topSafeInset() + 76)
        }
        .width('100%')

        if (this.downloadTasks.length === 0) {
          ListItem() {
            Text('暂无下载任务')
              .fontSize(14)
              .fontColor($r('app.color.text_muted'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 36, bottom: 36 })
          }
          .width('100%')
        } else {
          ForEach(this.downloadTasks, (task: DownloadTaskRecord) => {
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
              if (this.shouldReplaceViewerTransitionSource(entry)) {
                Blank()
                  .width('100%')
                  .height(82)
              } else {
                Stack({ alignContent: Alignment.Center }) {
                  if (this.previewUri(entry).length > 0) {
                    Image(this.previewUri(entry))
                      .width('100%')
                      .height(82)
                      .orientation(this.fileListImageBaseOrientation(entry))
                      .objectFit(ImageFit.Cover)
                      .rotate({ angle: this.fileListImageRotation(entry.path) })
                      .borderRadius(10)
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
                .geometryTransition(this.fileImageTransitionId(entry))
              }

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
          this.scheduleCachedDirectoryCount(entry)
        })
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
          // Keep the shared-element frame separate from the clipped render
          // layer.  Clipping the node that owns geometryTransition can cut
          // the flight snapshot at the card bounds on some releases.
          Stack() {
            if (this.shouldReplaceViewerTransitionSource(entry)) {
              Blank()
                .width('100%')
                .height('100%')
            } else {
              Stack() {
                Stack({ alignContent: Alignment.Center }) {
                  if (this.waterfallUri(entry).length > 0) {
                    Image(this.waterfallUri(entry))
                      .width('100%')
                      .height('100%')
                      .sourceSize(this.waterfallSourceSize(entry))
                      .orientation(this.fileListImageBaseOrientation(entry))
                      .objectFit(ImageFit.Contain)
                      .rotate({ angle: this.fileListImageRotation(entry.path) })
                      .onComplete(() => this.completeWaterfallDecode(entry))
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
              .geometryTransition(this.fileImageTransitionId(entry))
            }
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
          this.enqueueWaterfallOriginal(entry, index)
        })
        .onDisAppear(() => this.markWaterfallVisible(entry, false))
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
            this.FileHeaderLeadingControl()
          } else if ((this.screen === 'settings' && (this.showStorageSettings || this.showNetworkSettings))) {
            this.OfficialBackButton(() => {
              if (this.showStorageSettings) {
                this.closeStorageSettings()
              } else if (this.showNetworkSettings) {
                this.closeNetworkSettings()
              } else {
                this.openHome()
              }
            })
          } else {
            // Downloads/settings root pages have no back button, but reserve
            // the same 86vp side slot as the file header so the title remains
            // optically centered.
            Blank().width(this.screen === 'downloads' ? 86 : 40)
          }

          Text(this.selectionMode ? this.selectionTitle() :
            (this.screen === 'settings' && this.showStorageSettings ? '缓存与存储' :
            (this.screen === 'settings' && this.showNetworkSettings ? '网络与流量' :
            (this.screen === 'settings' ? '设置' :
              (this.screen === 'downloads' ? '下载' : this.topTitle)))))
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
    } else if (this.showNetworkSettings) {
      this.NetworkSettingsContent()
    } else {
      Column() {
        Column({ space: 12 }) {
          Column() {
            Row() {
              Stack() {
                SymbolGlyph($r('sys.symbol.folder'))
                  .fontSize(22)
                  .fontColor(['#2E6BFF'])
              }
              .width(42)
              .height(42)
              .borderRadius(14)
              .backgroundColor('#EAF1FF')

              Column({ space: 4 }) {
                Text('缓存与存储')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('查看占用、调整上限和清理缓存')
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 12 })

              SymbolGlyph($r('sys.symbol.chevron_forward'))
                .fontSize(18)
                .fontColor([$r('app.color.icon_muted')])
            }
            .width('100%')
            .padding(16)
          }
          .width('100%')
          .borderRadius(18)
          .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true))
          .onClick(() => this.openStorageSettings())

          Column() {
            Row() {
              Stack() {
                SymbolGlyph($r('sys.symbol.wifi'))
                  .fontSize(22)
                  .fontColor(['#2E6BFF'])
              }
              .width(42)
              .height(42)
              .borderRadius(14)
              .backgroundColor('#EAF1FF')

              Column({ space: 4 }) {
                Text('网络与流量')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('管理移动网络下的加载、刷新和下载策略')
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 12 })

              SymbolGlyph($r('sys.symbol.chevron_forward'))
                .fontSize(18)
                .fontColor([$r('app.color.icon_muted')])
            }
            .width('100%')
            .padding(16)
          }
          .width('100%')
          .borderRadius(18)
          .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true))
          .onClick(() => this.openNetworkSettings())

          Button('退出账号')
            .width('100%')
            .height(48)
            .fontSize(15)
            .fontColor('#D34D5C')
            .backgroundColor(Color.Transparent)
            .borderRadius(16)
            .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true, '#33D34D5C'))
            .enabled(!this.isBusy)
            .onClick(() => this.confirmLogout())
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 20, right: 20, top: this.topSafeInset() + 99,
        bottom: this.floatingBarContentInset(40) })
    }
  }

  @Builder
  StorageSettingsContent(): void {
    Scroll() {
      Column({ space: 16 }) {
        Column() {
          Text('缓存与存储')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('云盘文件会按缓存上限在本机临时保留，便于快速查看；不会出现在系统文件管理或图库中。缓存空间不足时，会优先清理较早的文件。')
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))
            .lineHeight(22)
            .margin({ top: 8 })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Column({ space: 10 }) {
          Row() {
            Text('当前缓存占用')
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

        Button(this.isBusy ? '处理中…' : '清理全部缓存')
          .width('100%')
          .height(48)
          .fontSize(15)
          .fontColor('#D34D5C')
          .backgroundColor(Color.Transparent)
          .borderRadius(14)
          .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true, '#33D34D5C'))
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
      .padding({ left: 20, right: 20, top: this.topSafeInset() + 99, bottom: this.bottomSafeInset() + 112 })
    }
    .width('100%')
    .height('100%')
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .scrollBar(BarState.Auto)
  }

  @Builder
  NetworkSettingsContent(): void {
    Scroll() {
      Column({ space: 16 }) {
        Column() {
          Text('网络与流量')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('管理移动网络下的原图加载、目录刷新和下载策略。WiFi 下不受这些开关限制。')
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))
            .lineHeight(22)
            .margin({ top: 8 })
        }
        .alignItems(HorizontalAlign.Start)
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
        .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true))

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
      .padding({ left: 20, right: 20, top: this.topSafeInset() + 99, bottom: this.bottomSafeInset() + 112 })
    }
    .width('100%')
    .height('100%')
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .scrollBar(BarState.Auto)
  }

  @Builder
  FloatingBottomBar(): void {
    Row() {
      this.BottomNavItem($r('sys.symbol.house'), '主页', 'home', () => this.openHome())
      this.BottomNavItem($r('sys.symbol.folder'), '共享', 'shared', () => this.openShared())
      this.BottomNavItem($r('sys.symbol.square_and_arrow_down'), '下载', 'downloads',
        () => this.openDownloads())
      this.BottomNavItem($r('sys.symbol.gearshape'), '设置', 'settings', () => this.openSettings())
    }
    .width('auto')
    .height(FLOATING_BAR_HEIGHT_VP)
    .padding({ left: 8, right: 8, top: 0, bottom: 0 })
    .margin({ left: 12, right: 12, bottom: this.floatingBarBottomMargin() })
    .borderRadius(FLOATING_BAR_HEIGHT_VP / 2)
    .systemMaterial(this.bottomCapsuleMaterial)
    // The capsule is above the scrolling page. Keep a drag that starts here
    // inside the capsule instead of letting the underlying List receive it.
    // Default keeps both this capsule and its nav-item children in the hit
    // test, while still blocking the file page sibling beneath it.
    .hitTestBehavior(HitTestMode.Default)
  }

  @Builder
  FileToolsBottomBar(): void {
    Row() {
      this.FileToolCircleButton($r('sys.symbol.folder_badge_plus'), () => this.openCreateFolder())

      Button() {
        Row({ space: 6 }) {
          Text(this.fileSortTitle())
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(15)
            .fontColor([$r('app.color.icon_primary')])
            .rotate({ angle: this.showFileSortMenu ? 180 : 0 })
        }
        .justifyContent(FlexAlign.Center)
      }
      .type(ButtonType.Normal)
      .width(166)
      .height(FLOATING_BAR_HEIGHT_VP)
      .borderRadius(FLOATING_BAR_HEIGHT_VP / 2)
      .backgroundColor(Color.Transparent)
      .systemMaterial(this.bottomCapsuleMaterial)
      .hitTestBehavior(HitTestMode.Default)
      .monopolizeEvents(true)
      .onClick(() => this.toggleFileSortMenu())
      .bindPopup(this.showFileSortMenu, {
        builder: this.FileSortPopup,
        placement: Placement.Top,
        popupColor: Color.Transparent,
        maskColor: Color.Transparent,
        enableArrow: false,
        autoCancel: true,
        // CustomPopupOptions exposes the official transition hook. The SDK does
        // not provide a HarmonyOS 7-only sort-popup animation name; keep the
        // popup on ArkUI's supported transition path instead of faking one.
        transition: this.fileSortPopupTransition(),
        systemMaterial: this.bottomCapsuleMaterial,
        onStateChange: (state: PopupStateChange): void => {
          if (!state.isVisible) {
            this.showFileSortMenu = false
          }
        }
      })

      this.FileToolCircleButton(this.fileViewModeIcon(), () => this.toggleFileViewMode())
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
    .margin({ bottom: this.floatingBarBottomMargin() })
    .justifyContent(FlexAlign.SpaceBetween)
    .hitTestBehavior(HitTestMode.Default)
  }

  @Builder
  SelectionBottomBar(): void {
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
    .width('calc(100% - 40vp)')
    .height(FLOATING_BAR_HEIGHT_VP)
    .padding({ left: 4, right: 4, top: 0, bottom: 0 })
    .margin({ left: 20, right: 20, bottom: this.floatingBarBottomMargin() })
    .borderRadius(FLOATING_BAR_HEIGHT_VP / 2)
    .systemMaterial(this.bottomCapsuleMaterial)
    .hitTestBehavior(HitTestMode.Default)
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
    .hitTestBehavior(HitTestMode.Default)
    .monopolizeEvents(true)
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
    .hitTestBehavior(HitTestMode.Default)
    .monopolizeEvents(true)
    .onClick(() => this.toggleSelectionMoreMenu())
    .bindPopup(this.showSelectionMoreMenu, {
      builder: this.SelectionMorePopup,
      placement: Placement.Top,
      popupColor: Color.Transparent,
      maskColor: Color.Transparent,
      enableArrow: false,
      autoCancel: true,
      transition: this.fileSortPopupTransition(),
      systemMaterial: this.bottomCapsuleMaterial,
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
    .systemMaterial(this.bottomCapsuleMaterial)
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
  FileToolCircleButton(icon: Resource, action: () => void): void {
    Button() {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([$r('app.color.icon_primary')])
    }
    .type(ButtonType.Normal)
    .width(FLOATING_BAR_HEIGHT_VP)
    .height(FLOATING_BAR_HEIGHT_VP)
    .borderRadius(FLOATING_BAR_HEIGHT_VP / 2)
    .backgroundColor(Color.Transparent)
    .systemMaterial(this.bottomCapsuleMaterial)
    .hitTestBehavior(HitTestMode.Default)
    .monopolizeEvents(true)
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
    .systemMaterial(this.bottomCapsuleMaterial)
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
    .hitTestBehavior(HitTestMode.Default)
    .monopolizeEvents(true)
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
      .backgroundColor(Color.Transparent)
      .borderRadius(12)
      .systemMaterial(this.cacheLimitBytes === value
        ? this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true, '#552E6BFF')
        : this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN))
      .enabled(!this.isBusy)
      .onClick(() => this.setCacheLimit(value))
  }

  /**
   * Native ContextMenu preview.  The preview and the action list are two
   * separate builders on purpose: HarmonyOS can then run the same long-press
   * morph/scale animation as Files instead of animating a full-screen custom
   * overlay from a guessed top offset.
   */
  @Builder
  ActionContextPreview(entry: FileEntry): void {
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
    .width(304)
    .height(58)
    .padding({ left: 12, right: 12 })
    .borderRadius(20)
    .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true))
  }

  @Builder
  ActionMenuOverlay(entry: FileEntry): void {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.isDarkTheme ? '#42000000' : '#26000000')
        .backgroundBlurStyle(BlurStyle.Thick, {
          colorMode: ThemeColorMode.SYSTEM,
          adaptiveColor: AdaptiveColor.DEFAULT
        })
        .transition(TransitionEffect.opacity(0).animation({
          duration: 180,
          curve: Curve.EaseOut
        }))
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.opacity(0).animation({
          duration: 160,
          curve: Curve.EaseOut
        }))

      // Use a real clickable node for the transparent mask. A transparent
      // layout container can be skipped by hit testing on some API 26 builds;
      // Button + Block is the documented self-hit-test path and also prevents
      // the tap from falling through to the List.
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
      .onClick(() => this.closeActionMenu())

      Column({ space: 8 }) {
        this.ActionContextPreview(entry)
        this.ActionContextMenu(entry)
      }
      .alignItems(HorizontalAlign.Start)
      .position({ x: 20, y: this.actionMenuTop(entry) })
      .transition(this.actionMenuSurfaceTransition())
      .hitTestBehavior(HitTestMode.Default)
      .monopolizeEvents(true)
      // The preview card is wider than the action list. The uncovered strip
      // on the right belongs to this wrapper, so it must dismiss the menu.
      .onClick(() => this.closeActionMenu())
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Default)
    // The root surface owns the empty area to the right and below the menu.
    // It must close the long-press state instead of consuming that tap.
    .onClick(() => this.closeActionMenu())
  }

  /**
   * Native ContextMenu content.  Widths and section rhythm follow the Files
   * reference: a compact menu (about 212vp) below a wider selected-item card,
   * with quick actions in the first group and destructive actions at the end.
   */
  @Builder
  ActionContextMenu(entry: FileEntry): void {
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
    .width(214)
    .height(this.actionMenuHeight(entry))
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .borderRadius(22)
    .clip(true)
    .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THICK, true))
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
    Column() {
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
      .width('84%')
      .padding({ left: 18, right: 18, top: 18, bottom: 12 })
      .borderRadius(24)
      .backgroundColor(Color.Transparent)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN))
      .transition(this.createFolderDialogTransition())
      .onClick(() => {})
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#55000000')
    .hitTestBehavior(HitTestMode.Default)
  }

  @Builder
  RenameOverlay(): void {
    Column() {
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
          .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true))
          .onChange((value: string) => this.renameText = value)
        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1)
            .height(46)
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor(Color.Transparent)
            .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN))
            .onClick(() => this.closeRename())
          Button(this.isBusy ? '处理中…' : '确定')
            .layoutWeight(1)
            .height(46)
            .fontSize(15)
            .fontColor(Color.White)
            .backgroundColor(Color.Transparent)
            .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true, '#552E6BFF'))
            .enabled(!this.isBusy)
            .onClick(() => this.confirmRename())
        }
        .width('100%')
      }
      .width('88%')
      .borderRadius(20)
      .padding(20)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false))
      .onClick(() => {})
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#66000000')
  }

  @Builder
  CreateFolderOverlay(): void {
    Column() {
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
      .width('84%')
      .padding({ left: 18, right: 18, top: 18, bottom: 12 })
      .borderRadius(24)
      .backgroundColor(Color.Transparent)
      .systemMaterial(this.bottomCapsuleMaterial)
      .transition(this.createFolderDialogTransition())
      .onClick(() => {})
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Color.Transparent)
    .hitTestBehavior(HitTestMode.Default)
  }

  private viewerOriginalUri(entry: FileEntry): string {
    const uri = this.viewerOriginalUris[entry.path]
    return typeof uri === 'string' ? uri : ''
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
  }

  private viewerImageDecoded(entry: FileEntry): boolean {
    return this.viewerDecodedImages[entry.path] === true
  }

  private viewerPageScale(index: number): number {
    return index === this.viewerImageIndex ? this.imageScale : 1
  }

  private viewerPageDismissScale(index: number): number {
    return index === this.viewerImageIndex ? this.imageDismissScale : 1
  }

  private viewerPageVisualScale(entry: FileEntry, index: number): number {
    return this.viewerPageScale(index) * this.viewerPageDismissScale(index) *
      this.viewerManualRotationFitScale(entry)
  }

  /**
   * The preview and original must be measured inside one stable frame.  The
   * Image component's Contain fit preserves the source ratio, but it does not
   * preserve the visible content rectangle when the source is replaced.
   * Keep the frame ratio from the first known display geometry instead.
   */
  private viewerImageFrameAspectRatio(entry: FileEntry): number {
    const size = this.viewerImageLayoutSize(entry)
    if (size !== null && size.width > 0 && size.height > 0) {
      return Math.max(0.05, Math.min(20, size.width / size.height))
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
   * A viewer frame is immutable for the lifetime of the page. If the NAS
   * thumbnail cannot expose metadata, reserve a viewport-ratio frame now;
   * original-file metadata must never replace it later and cause a jump.
   */
  private ensureViewerImageFrame(entry: FileEntry): void {
    if (this.viewerImageLayoutSize(entry) !== null) {
      return
    }
    this.setViewerImageLayoutSize(entry.path, {
      width: Math.max(1, this.imageViewportWidthVp),
      height: Math.max(1, this.imageViewportHeightVp)
    })
    console.info('[UgreenViewerGeometry] frame-locked-fallback path=' + entry.path +
      ' size=' + this.imageViewportWidthVp.toString() + 'x' +
      this.imageViewportHeightVp.toString())
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

  private viewerProgress(entry: FileEntry): number {
    if (this.viewerImageDecoded(entry)) {
      return 100
    }
    const value = this.viewerDownloadProgress[entry.path]
    return typeof value === 'number' ? value : 0
  }

  private viewerProgressKnown(entry: FileEntry): boolean {
    return this.viewerDownloadProgressKnown[entry.path] === true
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
    const previousValue = this.viewerDownloadProgress[path]
    const previousKnown = this.viewerDownloadProgressKnown[path] === true
    const now = Date.now()
    const lastUpdate = this.viewerProgressLastUpdateAt[path]
    if (!force && typeof lastUpdate === 'number' && now - lastUpdate < 80) {
      return
    }
    if (previousValue === nextValue && previousKnown === known) {
      return
    }
    const nextValues: Record<string, number> = {}
    for (const key of Object.keys(this.viewerDownloadProgress)) {
      nextValues[key] = this.viewerDownloadProgress[key]
    }
    nextValues[path] = nextValue
    this.viewerDownloadProgress = nextValues

    const nextKnown: Record<string, boolean> = {}
    for (const key of Object.keys(this.viewerDownloadProgressKnown)) {
      nextKnown[key] = this.viewerDownloadProgressKnown[key]
    }
    nextKnown[path] = known
    this.viewerDownloadProgressKnown = nextKnown
    this.viewerProgressLastUpdateAt[path] = now
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
    // Keep the source slot blank for the entire viewer lifetime, including
    // the close animation. The official geometryTransition pattern changes
    // the hierarchy once: the source thumbnail is restored only in the same
    // state update that removes the viewer. Restoring it earlier would leave
    // a live thumbnail underneath the viewer and produce a second image.
    if (!this.showImageViewer) {
      return false
    }
    const viewerEntry = this.currentViewerEntry()
    return viewerEntry !== null && viewerEntry.path === entry.path && this.isImage(entry)
  }

  private fileImageTransitionId(entry: FileEntry): string {
    // The file surface stays mounted under the viewer. During the shared
    // element state change the source id must be removed while the viewer
    // target id is present; otherwise ArkUI sees two live components with
    // the same geometry-transition id instead of one source/one target.
    if (this.showImageViewer) {
      return ''
    }
    if (!this.viewerEntryTransitionActive ||
      this.viewerEntryTransitionPath !== entry.path || !this.isImage(entry)) {
      return ''
    }
    // A transition is only created when the source has something rendered.
    // This avoids animating a loading placeholder into a full-screen image.
    // During the return state change WaterFlow has not fired onAppear yet;
    // its retained URI is still a valid source and must keep the id alive for
    // that first layout pass.
    const retainedWaterfallUri = this.viewerEntryTransitionPath === entry.path
      ? this.waterfallOriginalUris[entry.path] : ''
    if (this.previewUri(entry).length === 0 && this.waterfallUri(entry).length === 0 &&
      (typeof retainedWaterfallUri !== 'string' || retainedWaterfallUri.length === 0)) {
      return ''
    }
    return this.imageTransitionId(entry.path)
  }

  private viewerImageTransitionId(entry: FileEntry): string {
    if (!this.viewerEntryTransitionActive ||
      this.viewerEntryTransitionPath !== entry.path) {
      return ''
    }
    return this.imageTransitionId(entry.path)
  }

  private clearViewerEntryTransition(): void {
    this.viewerEntryTransitionToken += 1
    if (this.viewerEntryTransitionTimer !== 0) {
      clearTimeout(this.viewerEntryTransitionTimer)
      this.viewerEntryTransitionTimer = 0
    }
    this.viewerEntryTransitionActive = false
    this.viewerEntryTransitionPath = ''
  }

  private scheduleViewerEntryTransitionCleanup(): void {
    if (!this.viewerEntryTransitionActive) {
      return
    }
    if (this.viewerEntryTransitionTimer !== 0) {
      clearTimeout(this.viewerEntryTransitionTimer)
    }
    const token = this.viewerEntryTransitionToken + 1
    this.viewerEntryTransitionToken = token
    this.viewerEntryTransitionTimer = setTimeout((): void => {
      if (token !== this.viewerEntryTransitionToken) {
        return
      }
      this.viewerEntryTransitionActive = false
      this.viewerEntryTransitionPath = ''
      this.viewerEntryTransitionTimer = 0
    }, IMAGE_GEOMETRY_TRANSITION_SETTLE)
  }

  private startViewerEntryTransition(entry: FileEntry): void {
    this.clearViewerEntryTransition()
    if (!this.hasViewerTransitionSource(entry)) {
      return
    }
    this.viewerEntryTransitionPath = entry.path
    this.viewerEntryTransitionActive = true
  }

  private hasViewerTransitionSource(entry: FileEntry | null): boolean {
    if (entry === null || !this.isImage(entry)) {
      return false
    }
    if (this.previewUri(entry).length > 0 || this.waterfallUri(entry).length > 0) {
      return true
    }
    // WaterFlow can briefly report an item as not visible while its layout
    // window is being rebuilt. The URI is still a valid local source for the
    // shared-element return, so do not discard the transition for that
    // transient visibility flag.
    const waterfallUri = this.waterfallOriginalUris[entry.path]
    return typeof waterfallUri === 'string' && waterfallUri.length > 0
  }

  private startViewerExitTransition(entry: FileEntry | null): void {
    this.clearViewerEntryTransition()
    if (!this.hasViewerTransitionSource(entry)) {
      return
    }
    this.viewerEntryTransitionPath = (entry as FileEntry).path
    this.viewerEntryTransitionActive = true
  }

  /**
   * Swiper owns the displayed child. Do not use the entry captured when the
   * viewer builder was first created for overlays or actions after a swipe.
   */
  private currentViewerEntry(): FileEntry | null {
    // The chrome index is updated at animation start, so the title, actions,
    // and progress ring follow the image being entered without waiting for
    // Swiper's committed index at animation end.
    if (this.viewerChromeIndex >= 0 && this.viewerChromeIndex < this.viewerImages.length) {
      return this.viewerImages[this.viewerChromeIndex]
    }
    if (this.viewerImageEntry !== null) {
      return this.viewerImageEntry
    }
    if (this.viewerImageIndex >= 0 && this.viewerImageIndex < this.viewerImages.length) {
      return this.viewerImages[this.viewerImageIndex]
    }
    return this.viewerImageEntry
  }

  private viewerDisplayEntry(fallback: FileEntry): FileEntry {
    const current = this.currentViewerEntry()
    return current === null ? fallback : current
  }

  @Builder
  ImageViewer(entry: FileEntry): void {
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
      .disableSwipe(this.imageScale > 1.001)
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
          // Switch the chrome binding as soon as the new page is entered.
          // The Swiper index remains externally stable until animation end.
          if (targetIndex >= 0 && targetIndex < this.viewerImages.length) {
            this.viewerChromeIndex = targetIndex
            this.viewerImageEntry = this.viewerImages[targetIndex]
            this.viewerHeaderTitle = this.viewerImages[targetIndex].name
            this.ensureViewerImageFrame(this.viewerImages[targetIndex])
          }
          this.resetImageTransform()
          this.prefetchViewerImages(targetIndex)
        }
      })
      // onChange can arrive while the page is still moving. Keep the
      // externally bound index stable during that animation and commit the
      // new page only from the documented animation-end callback.
      .onAnimationEnd((index: number) => {
        this.viewerPendingIndex = -1
        this.onViewerImageChanged(index)
        this.viewerTransitionActive = false
      })

      Column() {
        this.ImageViewerTopOverlay(this.viewerDisplayEntry(entry))
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
        this.ImageViewerBottomBar(this.viewerDisplayEntry(entry))
      }
      .width('100%')
      .height('100%')
      .opacity(this.imageChromeOpacity)
      .translate({ x: 0, y: this.imageBottomChromeOffsetY, z: 0 })
      .hitTestBehavior(HitTestMode.None)

      if (this.showImageMoreMenu) {
        this.ImageViewerMoreOverlay(this.viewerDisplayEntry(entry))
      }
      if (this.showImageDetails) {
        this.ImageViewerDetailsOverlay(this.viewerDisplayEntry(entry))
      }
      if (this.showRenameDialog && this.renameEntry !== null) {
        this.RenameOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  @Builder
  ViewerOriginalImage(entry: FileEntry): void {
    if (this.viewerImageSourceSize(entry) !== null) {
      Image(this.viewerOriginalUri(entry))
        .width('100%')
        .height('100%')
        .sourceSize({
          width: (this.viewerImageSourceSize(entry) as ThumbnailSize).width,
          height: (this.viewerImageSourceSize(entry) as ThumbnailSize).height
        })
        .orientation(this.viewerImageOrientation(entry))
        .objectFit(ImageFit.Contain)
        .onComplete((event?: ViewerImageCompleteEvent): void => {
          this.logViewerRenderGeometry(entry.path, 'original', event)
          this.markViewerImageDecoded(entry.path)
        })
        .onError(() => this.markViewerImageFailed(entry.path))
    } else {
      // Do not invent a square decode target when metadata is unavailable.
      // ImageFit.Contain still guarantees a proportional display, and the
      // next load will populate the aspect-aware decode size.
        Image(this.viewerOriginalUri(entry))
          .width('100%')
          .height('100%')
          .orientation(this.viewerImageOrientation(entry))
          .objectFit(ImageFit.Contain)
          .onComplete((event?: ViewerImageCompleteEvent): void => {
            this.logViewerRenderGeometry(entry.path, 'original', event)
            this.markViewerImageDecoded(entry.path)
          })
          .onError(() => this.markViewerImageFailed(entry.path))
    }
  }

  @Builder
  ViewerImageLayers(entry: FileEntry): void {
    Stack() {
      // Both sources are rendered into the same fixed frame.  The original
      // remains above its preview so the preview is never removed while the
      // decoder is working, but neither source can change the frame's layout.
      if (this.previewUri(entry).length > 0) {
        Image(this.previewUri(entry))
          .width('100%')
          .height('100%')
          .orientation(this.viewerPreviewImageOrientation(entry))
          .objectFit(ImageFit.Contain)
          .onComplete((event?: ViewerImageCompleteEvent): void =>
            this.logViewerRenderGeometry(entry.path, 'preview', event))
      }
      if (this.viewerOriginalUri(entry).length > 0) {
        this.ViewerOriginalImage(entry)
      }
    }
    .width('100%')
    .height('100%')
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
        .geometryTransition(this.viewerImageTransitionId(entry))
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
        .rotate({ angle: this.viewerManualRotation(entry.path) })
      } else {
        Stack() {
          this.ViewerImageLayers(entry)
        }
        .height('100%')
        .aspectRatio(this.viewerImageFrameAspectRatio(entry))
        .geometryTransition(this.viewerImageTransitionId(entry))
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
        .rotate({ angle: this.viewerManualRotation(entry.path) })
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
    .clip(true)
    .gesture(
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
              distance: this.imageDismissGestureEnabled(index) ? 10 : 100000
            })
              .onActionStart(() => this.handleImageDismissStart(index))
              .onActionUpdate((event: GestureEvent) =>
                this.handleImageDismissUpdate(index, event))
              .onActionEnd((event: GestureEvent) =>
                this.handleImageDismissEnd(index, event))
              .onActionCancel(() => this.handleImageDismissCancel())
          )
        )
      )
    .onTouch((event: TouchEvent) => this.handleImageTouch(event, index))
  }

  @Builder
  ImageViewerTopOverlay(entry: FileEntry): void {
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
        this.OfficialBackButton(() => this.closeImageViewer())
        Text(this.viewerHeaderTitle.length > 0 ? this.viewerHeaderTitle : entry.name)
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
  ImageViewerBottomBar(entry: FileEntry): void {
    Row() {
      this.ImageViewerActionItem($r('sys.symbol.square_and_arrow_down'), '保存',
        () => this.saveViewerImage(entry))
      this.ImageViewerActionItem($r('sys.symbol.share'), '分享',
        () => this.shareViewerImage(entry))
      Stack() {
        Progress({ value: this.viewerProgress(entry), total: 100, type: ProgressType.Ring })
          .width(27)
          .height(27)
          // Key the progress component by file identity so ArkUI does not
          // retain the previous image's internal ring value after a swipe.
          .id('viewer_progress_' + entry.path.replace(/[^A-Za-z0-9_]/g, '_'))
          .backgroundColor('#AAB3C1')
          .color('#2E6BFF')
          .style({
            strokeWidth: 3,
            // LOADING is the indeterminate rotating animation. Keep this
            // ring determinate: blue arc is received, gray arc is remaining.
            enableSmoothEffect: false,
            status: ProgressStatus.PROGRESSING
          })
      }
      .layoutWeight(1)
      .height('100%')
      .hitTestBehavior(HitTestMode.Default)
      .monopolizeEvents(true)
      .onClick(() => this.loadCurrentViewerOriginalManually(entry))
      this.ImageViewerActionItem($r('sys.symbol.trash'), '删除',
        () => this.deleteViewerImage(entry))
      this.ImageViewerActionItem($r('sys.symbol.ellipsis_circle'), '更多',
        () => this.openImageMoreMenu())
    }
    .width(this.viewerBottomBarWidthVp > 0 ? this.viewerBottomBarWidthVp : '92%')
    .height(FLOATING_BAR_HEIGHT_VP)
    .padding({ left: 8, right: 8, top: 0, bottom: 0 })
    .margin({ left: 12, right: 12, bottom: this.floatingBarBottomMargin() })
    .borderRadius(FLOATING_BAR_HEIGHT_VP / 2)
    .systemMaterial(this.bottomCapsuleMaterial)
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
  ImageViewerMoreOverlay(entry: FileEntry): void {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .onClick(() => this.closeImageMoreMenu())
      Column() {
        this.ImageViewerMoreRow($r('sys.symbol.arrow_2_circlepath'), '旋转',
          () => this.rotateViewerImage(entry), true)
        this.ImageViewerMoreRow($r('sys.symbol.rectangle_and_arrowshape_turn_up_right'), '其他应用打开',
          () => this.openWithOtherApp(entry), true)
        this.ImageViewerMoreRow($r('sys.symbol.rectangle_on_rectangle'), '重命名',
          () => this.openRenameFromViewer(entry), true)
        this.ImageViewerMoreRow($r('sys.symbol.doc'), '详情',
          () => this.openImageDetails(entry), false)
      }
      .width('88%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .borderRadius(22)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THICK, false))
      // The menu is attached to the bottom action capsule, so it grows from
      // its lower edge instead of appearing at the center of the page.
      .transition(this.imageMoreMenuTransition())
      .onClick(() => {})
      .margin({ bottom: this.floatingBarBottomMargin() + FLOATING_BAR_HEIGHT_VP + 8 })
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Bottom)
    .backgroundColor('#22000000')
    .transition(this.imageMoreOverlayTransition())
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
  ImageViewerDetailsOverlay(entry: FileEntry): void {
    Column() {
      Blank()
        .layoutWeight(1)
        .onClick(() => this.closeImageDetails())
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

        this.ImageDetailsLine('文件名', entry.name)
        this.ImageDetailsLine('路径', this.entryDisplayPath(entry))
        this.ImageDetailsLine('大小', this.formatSize(entry.size))
        this.ImageDetailsLine('修改时间', this.formatTime(entry.modifiedTime))
        this.ImageDetailsLine('文件类型', this.fileType(entry).length > 0 ? this.fileType(entry) : '图片')
      }
      .width('90%')
      .padding({ left: 20, right: 20, top: 18, bottom: 20 })
      .borderRadius(22)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THICK, false))
      .onClick(() => {})
      .margin({ bottom: this.bottomSafeInset() + 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#22000000')
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
    await this.repository.initializeThumbnailCache(context)
    this.thumbnailDirectory = this.repository.thumbnailCacheDirectory()
    this.repository.initializeMetadata(context)
    try {
      this.cachePreferences = await preferences.getPreferences(context, 'ugreen-cache-settings')
      const storedLimit = await this.cachePreferences.get('cache_limit_bytes', CacheManager.DEFAULT_LIMIT_BYTES)
      if (typeof storedLimit === 'number' && storedLimit > 0) {
        this.cacheLimitBytes = storedLimit
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

  private ensureDownloadState(): Promise<void> {
    if (this.downloadStatePromise === null) {
      this.downloadStatePromise = this.loadDownloadState()
    }
    return this.downloadStatePromise
  }

  private async loadDownloadState(): Promise<void> {
    await this.ensureNetworkState()
    try {
      const context = getContext(this) as Context
      await this.downloadQueue.initialize(context, this.repository, this.networkPolicy)
      this.downloadQueue.onChange(this.downloadStateListener)
      this.downloadTasks = this.downloadQueue.snapshot()
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
    const originalUsage = await CacheManager.usage(this.cacheDirectory)
    const thumbnailUsage = await this.repository.thumbnailCacheUsage()
    this.cacheUsageBytes = originalUsage + thumbnailUsage
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
      : (this.isImage(entry) ? 'image' : (this.isAudio(entry) ? 'audio' : 'download'))
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
    const ratio = typeof value === 'number' && value > 0 ? value : 1
    const rotation = ((this.fileListImageRotation(entry.path) % 360) + 360) % 360
    return rotation === 90 || rotation === 270 ? 1 / ratio : ratio
  }

  private waterfallSourceSize(entry: FileEntry): ThumbnailSize {
    const columnVp = this.waterfallColumnWidthVp > 0 ? this.waterfallColumnWidthVp : 160
    const ratio = this.waterfallAspectRatio(entry)
    let width = Math.max(1, Math.round(vp2px(columnVp)))
    let height = Math.max(1, Math.round(width / ratio))
    const longest = Math.max(width, height)
    if (longest > 1024) {
      const scale = 1024 / longest
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
      this.setWaterfallOriginalUri(entry.path, fileUri.getUriFromPath(localPath))
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
      const sourceSize = await this.readViewerImageSourceSize(localPath, entry.path)
      if (sourceSize !== null && generation === this.waterfallGeneration) {
        this.setWaterfallAspectRatio(entry.path, sourceSize.width, sourceSize.height)
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
        (returnMode === 'audio' && !this.showAudioPlayer)) {
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
          (returnMode === 'audio' && !this.showAudioPlayer)) {
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
    this.errorText = ''
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
    this.ensureCacheState()
    this.errorText = ''
    this.updateTopTitle('缓存与存储', true)
    this.updateBottomBarVisibility(true)
  }

  private closeStorageSettings(): void {
    if (this.screen !== 'settings' || !this.showStorageSettings) {
      return
    }
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
    this.showNetworkSettings = false
    this.selectionMode = false
    this.selectedPaths = []
    this.selectedEntryCount = 0
    this.selectedBottomTab = 'downloads'
    this.screen = 'downloads'
    this.updateTopTitle('下载', false)
    this.updateBottomBarVisibility(true)
    this.ensureDownloadState()
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
      this.cacheLimitBytes = value
      if (this.cachePreferences !== null) {
        await this.cachePreferences.put('cache_limit_bytes', value)
        await this.cachePreferences.flush()
      }
      await CacheManager.enforceLimit(this.cacheDirectory, value)
      await this.repository.enforceThumbnailCacheLimit(this.thumbnailCacheLimitBytes)
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
      await CacheManager.clear(this.cacheDirectory)
      await this.repository.clearThumbnailCache()
      await this.repository.clearPersistentDirectoryCache()
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
      await this.ensureDownloadState()
      await this.downloadQueue.setReady(true)
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
      await this.ensureDownloadState()
      await this.downloadQueue.setReady(true)
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
      this.showImageViewer || this.showAudioPlayer || this.showPageTransition) {
      return
    }

    let anchorX = this.effectivePageWidth() / 2
    let anchorY = this.topSafeInset() + 80
    if (event.fingerList.length > 0) {
      anchorX = event.fingerList[0].globalX
      anchorY = event.fingerList[0].globalY
    }

    this.pendingContextAction = null
    this.contextMenuAnchorX = Math.max(0, anchorX)
    this.contextMenuAnchorY = Math.max(0, anchorY)
    this.contextMenuEntry = entry
    this.contextMenuAnimationToken += 1
    this.getUIContext().animateTo({
      duration: 220,
      curve: curves.interpolatingSpring(0, 1, 320, 30)
    }, () => {
      this.contextMenuVisible = true
    })
    console.info('[UgreenContext] longPress path=' + entry.path +
      ' anchor=' + this.contextMenuAnchorX.toString() + ',' + this.contextMenuAnchorY.toString())
  }

  private actionMenuSurfaceTransition(): TransitionEffect {
    const appear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.scale({ x: 0.94, y: 0.94, z: 1 }))
      .animation({
        duration: 220,
        curve: curves.interpolatingSpring(0, 1, 320, 30)
      })
    const disappear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.scale({ x: 0.98, y: 0.98, z: 1 }))
      .animation({ duration: 150, curve: Curve.EaseOut })
    return TransitionEffect.asymmetric(appear, disappear)
  }

  private actionMenuTop(entry: FileEntry): number {
    const totalHeight = 58 + 8 + this.actionMenuHeight(entry)
    const minimumTop = this.topSafeInset() + 44
    const maximumTop = Math.max(minimumTop,
      this.pageHeightVp - this.bottomSafeInset() - totalHeight - 16)
    return Math.min(maximumTop, Math.max(minimumTop, this.contextMenuAnchorY - 29))
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
    const token = this.contextMenuAnimationToken + 1
    this.contextMenuAnimationToken = token
    this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseOut }, () => {
      this.contextMenuVisible = false
    })
    setTimeout((): void => {
      if (token !== this.contextMenuAnimationToken || this.contextMenuVisible) {
        return
      }
      this.contextMenuEntry = null
      this.runPendingContextAction()
    }, 170)
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
    return Math.min(540, height)
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
    if (entry.isDirectory || this.cacheDirectory.length === 0) {
      return false
    }
    return CacheManager.findExisting(this.cacheDirectory, entry.name, this.originalCacheKey(entry)).length > 0
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
      const destinationRoot = this.userDownloadDirectory() + '/UGREENlink'
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
      await this.downloadQueue.enqueue(entry, destinationRoot, relativePath)
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

  private userDownloadDirectory(): string {
    try {
      const publicDirectory = Environment.getUserDownloadDir()
      if (typeof publicDirectory === 'string' && publicDirectory.length > 0) {
        return publicDirectory.replace(/[\\/]$/, '')
      }
    } catch (error) {
      // Public Download is only used by the explicit download action. Its
      // capability is optional on some devices, so keep that action safe too.
      console.warn('[UgreenFile] public download directory unavailable: ' + JSON.stringify(error))
    }
    try {
      const context = getContext(this) as Context
      if (typeof context.filesDir === 'string' && context.filesDir.length > 0) {
        return context.filesDir.replace(/[\\/]$/, '')
      }
    } catch (error) {
      console.warn('[UgreenFile] private files directory unavailable: ' + JSON.stringify(error))
    }
    return ''
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
      const parent = this.parentPath(entries[0].path)
      const records = await this.imageRotationStore.readDirectory(scope, parent)
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
      this.fileListImageRotations = {}
      this.fileListImageBaseOrientations = {}
      return
    }
    const snapshot = entries.slice()
    this.loadPersistedImageDisplayState(snapshot).then((state: ImageDisplayState): void => {
      if (generation !== this.fileListRotationGeneration) {
        return
      }
      this.fileListImageRotations = state.rotations
      this.fileListImageBaseOrientations = state.previewOrientations
    }).catch((error: Error): void => {
      console.warn('[UgreenImage] refresh file-list display metadata failed: ' + JSON.stringify(error))
    })
  }

  private fileListImageRotation(path: string): number {
    const value = this.fileListImageRotations[path]
    return value === undefined ? 0 : value
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
    return ImageRotateOrientation.AUTO
  }

  private setFileListImageBaseOrientation(path: string,
    orientation: ImageRotateOrientation): void {
    if (path.length === 0) {
      return
    }
    const next: Record<string, ImageRotateOrientation> = {}
    for (const key of Object.keys(this.fileListImageBaseOrientations)) {
      next[key] = this.fileListImageBaseOrientations[key]
    }
    next[path] = orientation
    this.fileListImageBaseOrientations = next
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
      this.viewerChromeIndex = initialIndex
      this.viewerImageEntry = entry
      this.viewerHeaderTitle = entry.name
      this.viewerOriginalUris = {}
      this.viewerImageSourceSizes = {}
      this.viewerImageLayoutSizes = {}
      this.viewerImageOrientations = {}
      this.viewerManualRotations = persistedState.rotations
      const baseOrientations: Record<string, ImageRotateOrientation> = {}
      for (const imageEntry of imageEntries) {
        const persistedOrientation = persistedState.previewOrientations[imageEntry.path]
        const currentOrientation = this.fileListImageBaseOrientations[imageEntry.path]
        if (persistedOrientation !== undefined) {
          baseOrientations[imageEntry.path] = persistedOrientation
        } else if (currentOrientation !== undefined) {
          baseOrientations[imageEntry.path] = currentOrientation
        }
      }
      this.fileListImageBaseOrientations = baseOrientations
      // The original may have been released while its thumbnail remains.
      // Seed the shared layout aspect ratio from that thumbnail before the
      // viewer is mounted, including the persisted base-orientation swap.
      await this.primeViewerPreviewGeometry(entry)
      this.ensureViewerImageFrame(entry)
      this.viewerDecodedImages = {}
      this.viewerDownloadProgress = {}
      this.viewerDownloadProgressKnown = {}
      this.viewerProgressLastUpdateAt = {}
      this.viewerBottomBarWidthVp = 0
      this.showImageMoreMenu = false
      this.showImageDetails = false
      this.viewerLastNavigationDirection = 1
      this.resetImageTransform()
      this.viewerTransitionActive = false
      this.setImageChromeVisible(true, false)
      // First expose the source thumbnail with its transition id. Waiting one
      // render turn is important: if source and target are mounted in the
      // same state batch, ArkUI cannot capture the source geometry.
      this.startViewerEntryTransition(entry)
      if (this.viewerEntryTransitionActive) {
        await new Promise<void>((resolve: () => void) => {
          setTimeout(resolve, 0)
        })
      }
      if (this.viewerEntryTransitionActive) {
        // geometryTransition matches the source and target only when the
        // hierarchy change is made inside the same explicit animation.
        this.getUIContext().animateTo({
          duration: IMAGE_GEOMETRY_TRANSITION_DURATION,
          curve: Curve.FastOutSlowIn
        }, () => {
          this.showImageViewer = true
        })
        this.scheduleViewerEntryTransitionCleanup()
      } else {
        // There is no rendered source to fly from. Do not wait for a network
        // thumbnail just to manufacture a transition; open normally.
        this.showImageViewer = true
      }
      this.enableImageViewerAutoRotation()
      // Mount the viewer and its ring before doing any local original work.
      // A cache hit has no HTTP byte progress, so it stays gray during local
      // EXIF/normalization work, reaches 95% when the Image source is bound,
      // and closes only from Image.onComplete.
      this.setViewerDownloadProgress(entry.path, 0, true, true)
      await this.primeCachedViewerOriginal(entry, this.viewerGeneration)
      if (!this.showImageViewer) {
        return
      }
      this.prefetchViewerImages(initialIndex)
      this.statusText = ''
    } catch (error) {
      this.clearViewerEntryTransition()
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
      setTimeout((): void => {
        this.restoreFileViewAnchor(anchor, token, 0)
      }, 0)
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
    setTimeout(restore, 0)
    setTimeout(restore, 80)
  }

  private finishCloseImageViewer(shouldRestoreSearch: boolean): void {
    if (!this.viewerClosePending) {
      return
    }
    if (this.viewerCloseCleanupTimer !== 0) {
      clearTimeout(this.viewerCloseCleanupTimer)
      this.viewerCloseCleanupTimer = 0
    }

    // The shared-element window is over. Only now remove the viewer data and
    // release its local URI state; clearing it earlier removes the target
    // geometry before ArkUI can complete the reverse transition.
    this.clearViewerEntryTransition()
    this.viewerClosePending = false
    this.isBusy = false
    this.viewerImageEntry = null
    this.viewerHeaderTitle = ''
    this.replaceViewerImages([])
    this.viewerImageIndex = 0
    this.viewerChromeIndex = 0
    this.showImageMoreMenu = false
    this.showImageDetails = false
    this.viewerLastNavigationDirection = 1
    this.viewerOriginalUris = {}
    this.viewerImageSourceSizes = {}
    this.viewerImageLayoutSizes = {}
    this.viewerImageOrientations = {}
    this.viewerManualRotations = {}
    this.viewerDecodedImages = {}
    this.viewerDownloadProgress = {}
    this.viewerDownloadProgressKnown = {}
    this.viewerProgressLastUpdateAt = {}
    this.viewerBottomBarWidthVp = 0
    this.viewerTransitionActive = false
    this.imageChromeVisible = true
    this.imageChromeOpacity = 1
    this.imageTopChromeOffsetY = 0
    this.imageBottomChromeOffsetY = 0
    this.resetImageTransform()
    if (shouldRestoreSearch) {
      this.restoreSearchSession()
    }
  }

  private closeImageViewer(): void {
    if (this.viewerClosePending) {
      return
    }
    const shouldRestoreSearch = this.searchSession !== null && this.searchSession.returnMode === 'image'
    const returningEntry = this.currentViewerEntry()
    const canUseGeometryTransition = this.hasViewerTransitionSource(returningEntry)
    // FileContent/SearchContent now remains mounted below the viewer. In the
    // ordinary file-page path its scroller is already at the exact position
    // the user left, so calling scrollTo during the close animation would
    // itself create the downward jump that this transition is meant to avoid.
    // Search restoration remains separate because it may intentionally change
    // the search session after the viewer has closed.
    const keepFileSurfacePosition = this.screen === 'files' &&
      !this.showSearch && this.currentPath.length > 0

    // Do not clear the shared id before the viewer is removed. The file
    // surface is then added with the same id, so ArkUI can match the two
    // image frames for the reverse flight.
    this.startViewerExitTransition(returningEntry)
    this.viewerClosePending = true
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
    this.isBusy = true

    const closeGeneration = this.viewerGeneration
    if (canUseGeometryTransition) {
      this.getUIContext().animateTo({
        duration: IMAGE_GEOMETRY_TRANSITION_DURATION,
        curve: Curve.FastOutSlowIn
      }, () => {
        this.showImageViewer = false
        if (!keepFileSurfacePosition) {
          this.restoreViewerReturnScrollPosition()
        }
      })
      this.viewerCloseCleanupTimer = setTimeout((): void => {
        if (closeGeneration !== this.viewerGeneration) {
          return
        }
        this.finishCloseImageViewer(shouldRestoreSearch)
      }, IMAGE_GEOMETRY_TRANSITION_SETTLE)
    } else {
      // No rendered source exists. Do not delay a normal close for an
      // animation that cannot be matched.
      this.showImageViewer = false
      if (!keepFileSurfacePosition) {
        this.restoreViewerReturnScrollPosition()
      }
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
    this.imageDismissDragging = true
    this.imageTouchMoved = true
  }

  private handleImageDismissUpdate(index: number, event: GestureEvent): void {
    if (!this.imageDismissDragging || !this.imageDismissGestureEnabled(index)) {
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
      curve: curves.interpolatingSpring(0, 1, 320, 30)
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
    this.viewerChromeIndex = index
    this.viewerImageIndex = index
    this.viewerImageEntry = this.viewerImages[index]
    this.viewerHeaderTitle = this.viewerImages[index].name
    this.ensureViewerImageFrame(this.viewerImages[index])
    this.resetImageTransform()
    this.prefetchViewerImages(index)
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
    if (this.viewerOriginalUri(entry).length > 0 && this.viewerDecodedImages[entry.path] === true) {
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
      }
    }
    this.viewerLoadQueue = nextQueue
    for (const key of Object.keys(this.viewerLoadRequests)) {
      if (key !== targetPath && this.viewerActiveLoadPaths[key] !== true) {
        this.viewerLoadRequests[key] = false
      }
    }
  }

  private trimViewerOriginalState(): void {
    // Do not impose an arbitrary number-of-images limit here. These maps only
    // retain file URIs, source dimensions and small progress values; decoded
    // PixelMaps belong to ArkUI/ImageKit and are released by the component
    // lifecycle. The actual original-file bytes are bounded by CacheManager's
    // byte-based LRU cache. Keeping the session state prevents a return swipe
    // from blanking the page and rebinding the same local file unnecessarily.
    const keepPaths: Record<string, boolean> = {}
    for (const item of this.viewerImages) {
      keepPaths[item.path] = true
    }

    const nextUris: Record<string, string> = {}
    for (const key of Object.keys(this.viewerOriginalUris)) {
      if (keepPaths[key] === true) {
        nextUris[key] = this.viewerOriginalUris[key]
      }
    }
    this.viewerOriginalUris = nextUris

    const nextSourceSizes: Record<string, ThumbnailSize> = {}
    const nextLayoutSizes: Record<string, ThumbnailSize> = {}
    for (const key of Object.keys(this.viewerImageSourceSizes)) {
      if (keepPaths[key] === true) {
        nextSourceSizes[key] = this.viewerImageSourceSizes[key]
      }
    }
    this.viewerImageSourceSizes = nextSourceSizes
    for (const key of Object.keys(this.viewerImageLayoutSizes)) {
      if (keepPaths[key] === true) {
        nextLayoutSizes[key] = this.viewerImageLayoutSizes[key]
      }
    }
    this.viewerImageLayoutSizes = nextLayoutSizes

    const nextOrientations: Record<string, ImageRotateOrientation> = {}
    for (const key of Object.keys(this.viewerImageOrientations)) {
      if (keepPaths[key] === true) {
        nextOrientations[key] = this.viewerImageOrientations[key]
      }
    }
    this.viewerImageOrientations = nextOrientations

    const nextDecoded: Record<string, boolean> = {}
    for (const key of Object.keys(this.viewerDecodedImages)) {
      if (keepPaths[key] === true) {
        nextDecoded[key] = this.viewerDecodedImages[key]
      }
    }
    this.viewerDecodedImages = nextDecoded

    const nextProgress: Record<string, number> = {}
    const nextProgressKnown: Record<string, boolean> = {}
    const nextProgressTimes: Record<string, number> = {}
    for (const key of Object.keys(this.viewerDownloadProgress)) {
      if (keepPaths[key] === true) {
        nextProgress[key] = this.viewerDownloadProgress[key]
      }
    }
    for (const key of Object.keys(this.viewerDownloadProgressKnown)) {
      if (keepPaths[key] === true) {
        nextProgressKnown[key] = this.viewerDownloadProgressKnown[key]
      }
    }
    for (const key of Object.keys(this.viewerProgressLastUpdateAt)) {
      if (keepPaths[key] === true) {
        nextProgressTimes[key] = this.viewerProgressLastUpdateAt[key]
      }
    }
    this.viewerDownloadProgress = nextProgress
    this.viewerDownloadProgressKnown = nextProgressKnown
    this.viewerProgressLastUpdateAt = nextProgressTimes

    this.viewerLoadQueue = this.viewerLoadQueue.filter((item: FileEntry): boolean => {
      return keepPaths[item.path] === true
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

  private async loadCurrentViewerOriginalManually(entry: FileEntry): Promise<void> {
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
      const displayPath = await this.prepareViewerImagePath(entry, existingPath)
      const sourceSize = await this.readViewerImageSourceSize(displayPath, entry.path)
      if (!this.showImageViewer || generation !== this.viewerGeneration) {
        return
      }
      if (sourceSize !== null) {
        this.setViewerImageSourceSize(entry.path, sourceSize)
        this.setViewerImageLayoutSizeIfAbsent(entry.path, sourceSize)
      }
      if (displayPath !== existingPath) {
        this.setViewerImageOrientation(entry.path, ImageRotateOrientation.UP)
      } else {
        this.setViewerImageOrientation(entry.path, this.viewerPreviewImageOrientation(entry))
      }
      this.setViewerDownloadProgress(entry.path, 95, true, true)
      this.setViewerOriginalUri(entry.path, fileUri.getUriFromPath(displayPath))
      await this.refreshEntryPreviewFromViewer(entry, displayPath)
    } catch (_) {
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
      const displayPath = await this.prepareViewerImagePath(entry, existingPath)
      const sourceSize = await this.readViewerImageSourceSize(displayPath, entry.path)
      if (generation !== this.viewerGeneration) {
        return
      }
      if (sourceSize !== null) {
        this.setViewerImageSourceSize(entry.path, sourceSize)
        this.setViewerImageLayoutSizeIfAbsent(entry.path, sourceSize)
      }
      this.setViewerImageOrientation(entry.path,
        displayPath !== existingPath ? ImageRotateOrientation.UP : this.viewerPreviewImageOrientation(entry))
      this.setViewerDownloadProgress(entry.path, 95, true, true)
      this.setViewerOriginalUri(entry.path, fileUri.getUriFromPath(displayPath))
      // File rows still use a small, locally downsampled derivative. Binding
      // the full original in a scrolling list would multiply decode memory.
      this.refreshEntryPreviewFromViewer(entry, displayPath).catch((error: Error): void => {
        console.warn('[UgreenPreview] cached-original preview refresh failed: ' + JSON.stringify(error))
      })
    } catch (error) {
      // A reclaimed cache entry simply falls back to the normal preview and
      // download path; it must not make opening the viewer fail.
      console.warn('[UgreenImage] cached-original fast path failed: ' + JSON.stringify(error))
    }
  }

  private async primeViewerPreviewGeometry(entry: FileEntry): Promise<void> {
    await this.primeViewerPreviewGeometryAtPath(entry, this.previewLocalPaths[entry.path],
      this.previewCanonicalPaths[entry.path] === true)
  }

  private async primeViewerPreviewGeometryAtPath(entry: FileEntry, localPath: string,
    canonical: boolean = false): Promise<void> {
    if (typeof localPath !== 'string' || localPath.length === 0 || !CacheManager.exists(localPath)) {
      return
    }
    const physicalSize = await this.readViewerImageSourceSize(localPath, entry.path)
    if (physicalSize === null) {
      return
    }
    // readViewerImageSourceSize already resolves EXIF axis swapping from the
    // physical source. Do not apply the viewer orientation a second time here;
    // doing so was the source of the preview/original ratio mismatch for 90°
    // and 270° images.
    this.setViewerImageLayoutSizeIfAbsent(entry.path, physicalSize)
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
      const displayPath = await this.prepareViewerImagePath(entry, localPath)
      const sourceSize = await this.readViewerImageSourceSize(displayPath, entry.path)
      if (!this.showImageViewer || generation !== this.viewerGeneration) {
        return
      }
      if (sourceSize !== null) {
        this.setViewerImageSourceSize(entry.path, sourceSize)
        this.setViewerImageLayoutSizeIfAbsent(entry.path, sourceSize)
      }
      if (displayPath !== localPath) {
        this.setViewerImageOrientation(entry.path, ImageRotateOrientation.UP)
      } else {
        this.setViewerImageOrientation(entry.path, this.viewerPreviewImageOrientation(entry))
      }
      if (existingPath.length > 0) {
        this.setViewerDownloadProgress(entry.path, 95, true, true)
      }
      this.setViewerOriginalUri(entry.path, fileUri.getUriFromPath(displayPath))
      // Persist a small canonical preview derived from the EXIF-normalized
      // display source. File rows can then apply only the user's manual turn.
      await this.refreshEntryPreviewFromViewer(entry, displayPath)
    } catch (error) {
      if (error instanceof UgreenError && error.status === 499) {
        return
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
        this.viewerActiveLoads = Math.max(0, this.viewerActiveLoads - 1)
        this.viewerLoadRequests[entry.path] = false
        this.viewerActiveLoadPaths[entry.path] = false
        this.viewerManualLoadPaths[entry.path] = false
        this.drainViewerLoadQueue()
      }
    }
  }

  /**
   * Reads the physical image dimensions before the Image component is built.
   * The decoder target must use the same aspect ratio as the source; a fixed
   * square sourceSize is not safe for portrait or panoramic images.
   */
  private async prepareViewerImagePath(entry: FileEntry, localPath: string): Promise<string> {
    let source: image.ImageSource | null = null
    let sourceFd: number = -1
    let pixelMap: image.PixelMap | null = null
    let packer: image.ImagePacker | null = null
    try {
      const sourceFile = fileIo.openSync(localPath, fileIo.OpenMode.READ_ONLY)
      sourceFd = sourceFile.fd
      source = image.createImageSource(sourceFd)
      const info = source.getImageInfoSync()
      const width = Math.max(1, Math.floor(info.size.width))
      const height = Math.max(1, Math.floor(info.size.height))
      let orientation = ''
      try {
        orientation = await source.getImageProperty(image.PropertyKey.ORIENTATION)
      } catch (_) {
        return localPath
      }
      const mapped = this.mapExifOrientation(orientation)
      // Do not guess how the NAS thumbnail service handled EXIF. HarmonyOS
      // recommends AUTO for an external image whose EXIF policy is unknown;
      // it works whether the server retained the tag or already baked the
      // direction into the thumbnail pixels. The canonical viewer copy below
      // is explicitly transformed and rendered as UP.
      this.setFileListImageBaseOrientation(entry.path, ImageRotateOrientation.AUTO)
      this.persistPreviewOrientation(entry, ImageRotateOrientation.AUTO)
      if (mapped === ImageRotateOrientation.AUTO || mapped === ImageRotateOrientation.UP) {
        return localPath
      }

      const outputExtension = this.viewerPreservesAlpha(entry.name) ? 'png' : 'jpg'
      const outputName = entry.name + '.viewer-orientation-v7.' + outputExtension
      const outputKey = this.originalCacheKey(entry) + ':viewer-orientation-v7:' + orientation
      const existingPath = CacheManager.findExisting(this.cacheDirectory, outputName, outputKey)
      if (existingPath.length > 0) {
        console.info('[UgreenImage] normalized-cache-hit path=' + entry.path)
        return existingPath
      }

      // Decode the source pixels, apply the EXIF transform explicitly, and
      // repack without relying on a stale orientation tag. The resulting
      // display copy is canonical UP, so ArkUI never combines an external
      // thumbnail correction with layout sizing.
      pixelMap = await source.createPixelMap({
        sampleSize: ThumbnailPolicy.sampleSize(width, height, 'viewerZoom'),
        editable: true
      })
      await this.applyExifOrientationToPixelMap(pixelMap, mapped)
      packer = image.createImagePacker()
      const encoded = await packer.packToData(pixelMap, {
        format: outputExtension === 'png' ? 'image/png' : 'image/jpeg',
        quality: 92
      })
      const normalizedPath = await CacheManager.save(new Uint8Array(encoded),
        this.cacheDirectory, outputName, this.cacheLimitBytes, outputKey)
      const normalizedInfo = pixelMap.getImageInfoSync()
      console.info('[UgreenImage] normalized path=' + entry.path + ' orientation=' + orientation +
        ' size=' + normalizedInfo.size.width.toString() + 'x' + normalizedInfo.size.height.toString())
      return normalizedPath
    } catch (error) {
      // A decoder-specific EXIF failure must not prevent the original from
      // being viewed. ImageFit.Contain and the normal AUTO fallback remain in
      // place for formats that cannot be rewritten by Image Kit.
      console.warn('[UgreenImage] normalize failed path=' + entry.path + ': ' + JSON.stringify(error))
      return localPath
    } finally {
      if (packer !== null) {
        try {
          await packer.release()
        } catch (_) {
          // The packed display copy is disposable.
        }
      }
      if (pixelMap !== null) {
        try {
          await pixelMap.release()
        } catch (_) {
          // The decoder may have released it after a failed pack operation.
        }
      }
      if (source !== null) {
        try {
          await source.release()
        } catch (_) {
          // Keep the original viewer path usable if cleanup races the decoder.
        }
      }
      if (sourceFd >= 0) {
        try {
          fileIo.closeSync(sourceFd)
        } catch (_) {
          // The source may already own/close the descriptor.
        }
      }
    }
  }

  private viewerPreservesAlpha(name: string): boolean {
    const extension = this.fileExtension(name)
    return extension === 'png' || extension === 'webp' || extension === 'gif'
  }

  private async readViewerImageSourceSize(localPath: string, entryPath: string = ''): Promise<ThumbnailSize | null> {
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
      const displayWidth = this.previewOrientationSwapsAxes(mapped) ? height : width
      const displayHeight = this.previewOrientationSwapsAxes(mapped) ? width : height
      console.info('[UgreenImage] source-metadata path=' + localPath +
        ' size=' + width.toString() + 'x' + height.toString() +
        ' displaySize=' + displayWidth.toString() + 'x' + displayHeight.toString() +
        ' orientation=' + orientation)
      // sourceSize is a decode target, but the viewer frame must use the
      // post-EXIF display geometry. Otherwise a portrait image with a
      // landscape pixel buffer gets a transiently wrong frame ratio.
      return ThumbnailPolicy.targetSize(displayWidth, displayHeight, 'viewerZoom')
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

  private setViewerImageSourceSize(path: string, size: ThumbnailSize): void {
    if (path.length === 0 || !this.isViewerPathNearCurrent(path)) {
      return
    }
    const next: Record<string, ThumbnailSize> = {}
    for (const key of Object.keys(this.viewerImageSourceSizes)) {
      next[key] = this.viewerImageSourceSizes[key]
    }
    next[path] = size
    this.viewerImageSourceSizes = next
  }

  private setViewerImageLayoutSize(path: string, size: ThumbnailSize): void {
    if (path.length === 0 || !this.isViewerPathNearCurrent(path)) {
      return
    }
    const next: Record<string, ThumbnailSize> = {}
    for (const key of Object.keys(this.viewerImageLayoutSizes)) {
      next[key] = this.viewerImageLayoutSizes[key]
    }
    next[path] = size
    this.viewerImageLayoutSizes = next
  }

  private setViewerImageLayoutSizeIfAbsent(path: string, size: ThumbnailSize): void {
    if (path.length === 0 || this.viewerImageLayoutSizes[path] !== undefined) {
      return
    }
    this.setViewerImageLayoutSize(path, size)
  }

  private viewerImageOrientation(entry: FileEntry): ImageRotateOrientation {
    const value = this.viewerImageOrientations[entry.path]
    return value === undefined ? ImageRotateOrientation.AUTO : value
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
    return ImageRotateOrientation.AUTO
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

  private async applyExifOrientationToPixelMap(pixelMap: image.PixelMap,
    orientation: ImageRotateOrientation): Promise<void> {
    // Image Kit's PixelMap operations are explicit pixel transforms. Apply
    // the EXIF operation in the order defined by ArkUI's orientation enum;
    // the packed result is then physically upright and is rendered with UP.
    if (orientation === ImageRotateOrientation.UP_MIRRORED) {
      await pixelMap.flip(true, false)
      return
    }
    if (orientation === ImageRotateOrientation.DOWN_MIRRORED) {
      await pixelMap.flip(false, true)
      return
    }
    if (orientation === ImageRotateOrientation.RIGHT_MIRRORED) {
      await pixelMap.flip(true, false)
      await pixelMap.rotate(90)
      return
    }
    if (orientation === ImageRotateOrientation.LEFT_MIRRORED) {
      await pixelMap.flip(true, false)
      await pixelMap.rotate(270)
      return
    }
    if (orientation === ImageRotateOrientation.RIGHT) {
      await pixelMap.rotate(90)
      return
    }
    if (orientation === ImageRotateOrientation.DOWN) {
      await pixelMap.rotate(180)
      return
    }
    if (orientation === ImageRotateOrientation.LEFT) {
      await pixelMap.rotate(270)
    }
  }

  private setViewerImageOrientation(path: string, orientation: ImageRotateOrientation): void {
    if (path.length === 0 || !this.isViewerPathNearCurrent(path)) {
      return
    }
    const next: Record<string, ImageRotateOrientation> = {}
    for (const key of Object.keys(this.viewerImageOrientations)) {
      next[key] = this.viewerImageOrientations[key]
    }
    next[path] = orientation
    this.viewerImageOrientations = next
  }

  private viewerImageSourceSize(entry: FileEntry): ThumbnailSize | null {
    const size = this.viewerImageSourceSizes[entry.path]
    if (size !== undefined && size.width > 0 && size.height > 0) {
      return size
    }
    return null
  }

  private viewerImageLayoutSize(entry: FileEntry): ThumbnailSize | null {
    const size = this.viewerImageLayoutSizes[entry.path]
    if (size !== undefined && size.width > 0 && size.height > 0) {
      return size
    }
    return null
  }

  private setViewerOriginalUri(path: string, uri: string): void {
    if (path.length === 0 || uri.length === 0 || !this.isViewerPathNearCurrent(path)) {
      return
    }
    const nextUris: Record<string, string> = {}
    for (const key of Object.keys(this.viewerOriginalUris)) {
      nextUris[key] = this.viewerOriginalUris[key]
    }
    nextUris[path] = uri
    this.viewerOriginalUris = nextUris

    const nextDecoded: Record<string, boolean> = {}
    for (const key of Object.keys(this.viewerDecodedImages)) {
      nextDecoded[key] = this.viewerDecodedImages[key]
    }
    nextDecoded[path] = false
    this.viewerDecodedImages = nextDecoded
    this.setViewerDownloadProgress(path, 95, true, true)
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

  private markViewerImageDecoded(path: string): void {
    if (!this.showImageViewer || this.viewerOriginalUris[path] === undefined ||
      this.viewerDecodedImages[path] === true) {
      return
    }
    const next: Record<string, boolean> = {}
    for (const key of Object.keys(this.viewerDecodedImages)) {
      next[key] = this.viewerDecodedImages[key]
    }
    next[path] = true
    this.viewerDecodedImages = next
    this.setViewerDownloadProgress(path, 100, true, true)
    // Do not warm neighbors merely because their files are present locally.
    // Start the adjacent decode window only after the currently selected
    // Image has delivered onComplete, so the visible page always wins.
    if (path === this.viewerPrimaryPath) {
      const primaryIndex = this.viewerImages.findIndex((item: FileEntry): boolean => {
        return item.path === path
      })
      if (primaryIndex >= 0) {
        this.startAdjacentViewerPrefetch(primaryIndex, this.viewerGeneration)
      }
    }
  }

  private markViewerImageFailed(path: string): void {
    if (!this.showImageViewer || this.viewerOriginalUris[path] === undefined) {
      return
    }
    const next: Record<string, boolean> = {}
    for (const key of Object.keys(this.viewerDecodedImages)) {
      next[key] = this.viewerDecodedImages[key]
    }
    next[path] = false
    this.viewerDecodedImages = next
    this.setViewerDownloadProgress(path, 0, false, true)
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
    this.showImageDetails = false
    this.showImageMoreMenu = true
  }

  private closeImageMoreMenu(): void {
    this.showImageMoreMenu = false
  }

  private rotateViewerImage(entry: FileEntry): void {
    if (!this.showImageViewer || this.isBusy) {
      return
    }
    const current = this.viewerManualRotations[entry.path] === undefined
      ? 0 : this.viewerManualRotations[entry.path]
    const nextRotation = (current + 90) % 360
    const next: Record<string, number> = {}
    for (const key of Object.keys(this.viewerManualRotations)) {
      next[key] = this.viewerManualRotations[key]
    }
    next[entry.path] = nextRotation
    this.viewerManualRotations = next

    // The file page remains mounted below the viewer. Update its thumbnail
    // immediately and invalidate any older asynchronous database read.
    this.fileListRotationGeneration += 1
    const nextFileListRotations: Record<string, number> = {}
    for (const key of Object.keys(this.fileListImageRotations)) {
      if (key !== entry.path) {
        nextFileListRotations[key] = this.fileListImageRotations[key]
      }
    }
    if (nextRotation !== 0) {
      nextFileListRotations[entry.path] = nextRotation
    }
    this.fileListImageRotations = nextFileListRotations
    this.persistViewerRotation(entry, nextRotation)
    this.closeImageMoreMenu()
    this.resetImageTransform()
  }

  private viewerManualRotation(path: string): number {
    const value = this.viewerManualRotations[path]
    return value === undefined ? 0 : value
  }

  private viewerManualRotationFitScale(entry: FileEntry): number {
    const angle = this.viewerManualRotation(entry.path) % 360
    if (angle === 0 || angle === 180) {
      return 1
    }
    const size = this.viewerImageLayoutSize(entry)
    if (size === null) {
      return 1
    }
    const viewportWidth = Math.max(1, this.imageViewportWidthVp)
    const viewportHeight = Math.max(1, this.imageViewportHeightVp)
    const unrotatedContain = Math.min(viewportWidth / size.width, viewportHeight / size.height)
    const rotatedContain = Math.min(viewportWidth / size.height, viewportHeight / size.width)
    if (unrotatedContain <= 0 || rotatedContain <= 0) {
      return 1
    }
    return rotatedContain / unrotatedContain
  }

  private openImageDetails(entry: FileEntry): void {
    if (!this.showImageViewer || this.isBusy) {
      return
    }
    this.showImageMoreMenu = false
    this.showImageDetails = true
  }

  private closeImageDetails(): void {
    this.showImageDetails = false
  }

  private openRenameFromViewer(entry: FileEntry): void {
    if (!this.showImageViewer || this.isBusy) {
      return
    }
    this.showImageMoreMenu = false
    this.showImageDetails = false
    this.openRename(entry)
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

    const deletedIndex = this.viewerImageIndex
    const preferredDirection = this.viewerLastNavigationDirection >= 0 ? 1 : -1
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
      this.viewerChromeIndex = boundedIndex
      this.viewerImageIndex = boundedIndex
      this.viewerImageEntry = remainingImages[boundedIndex]
      this.viewerHeaderTitle = remainingImages[boundedIndex].name
      this.viewerOriginalUris = this.filterViewerUris(remainingImages)
      this.viewerImageSourceSizes = this.filterViewerSourceSizes(remainingImages)
      this.viewerImageLayoutSizes = this.filterViewerLayoutSizes(remainingImages)
      this.viewerImageOrientations = this.filterViewerOrientations(
        remainingImages, this.viewerImageOrientations)
      this.viewerDecodedImages = this.filterViewerDecodedImages(remainingImages)
      this.viewerLoadQueue = this.viewerLoadQueue.filter((item: FileEntry) => item.path !== entry.path)
      this.viewerLoadRequests[entry.path] = false
      this.resetImageTransform()
      if (boundedIndex > deletedIndex) {
        this.viewerLastNavigationDirection = 1
      } else if (boundedIndex < deletedIndex) {
        this.viewerLastNavigationDirection = -1
      }
      this.prefetchViewerImages(boundedIndex)
      this.statusText = '已移入回收站'
      this.showImmersiveToast('已移入云盘回收站')
    } catch (error) {
      this.reportError(error as Object, '删除失败')
      this.statusText = '删除失败'
    } finally {
      this.isBusy = false
    }
  }

  private filterViewerUris(entries: FileEntry[]): Record<string, string> {
    const next: Record<string, string> = {}
    for (const item of entries) {
      const uri = this.viewerOriginalUris[item.path]
      if (typeof uri === 'string' && uri.length > 0) {
        next[item.path] = uri
      }
    }
    return next
  }

  private filterViewerDecodedImages(entries: FileEntry[]): Record<string, boolean> {
    const next: Record<string, boolean> = {}
    for (const item of entries) {
      if (this.viewerDecodedImages[item.path] === true) {
        next[item.path] = true
      }
    }
    return next
  }

  private filterViewerSourceSizes(entries: FileEntry[]): Record<string, ThumbnailSize> {
    const next: Record<string, ThumbnailSize> = {}
    for (const item of entries) {
      const size = this.viewerImageSourceSizes[item.path]
      if (size !== undefined) {
        next[item.path] = size
      }
    }
    return next
  }

  private filterViewerLayoutSizes(entries: FileEntry[]): Record<string, ThumbnailSize> {
    const next: Record<string, ThumbnailSize> = {}
    for (const item of entries) {
      const size = this.viewerImageLayoutSizes[item.path]
      if (size !== undefined) {
        next[item.path] = size
      }
    }
    return next
  }

  private filterViewerOrientations(entries: FileEntry[],
    source: Record<string, ImageRotateOrientation>): Record<string, ImageRotateOrientation> {
    const next: Record<string, ImageRotateOrientation> = {}
    for (const item of entries) {
      const orientation = source[item.path]
      if (orientation !== undefined) {
        next[item.path] = orientation
      }
    }
    return next
  }

  private async openAudioPlayer(entry: FileEntry): Promise<void> {
    if (this.isBusy || entry.isDirectory) {
      return
    }
    this.closeActionMenu()
    if (!await this.confirmMeteredDownload(entry)) {
      return
    }
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
      await this.audioManager.play()
      this.statusText = '正在播放：' + entry.name
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
    if (this.networkClass === 'offline') {
      return false
    }
    if (!this.networkPolicy.isMetered()) {
      return true
    }
    await this.ensureCacheState()
    const requiresDownload = entries.some((entry: FileEntry): boolean => {
      return CacheManager.findExisting(this.cacheDirectory, entry.name,
        this.originalCacheKey(entry)).length === 0
    })
    if (!requiresDownload) {
      return true
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
      const destinationRoot = this.userDownloadDirectory() + '/UGREENlink'
      let count = 0
      for (const entry of entries) {
        if (entry.isDirectory) {
          count += await this.enqueueRemoteTree(entry, destinationRoot, entry.name)
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
      for (const entry of entries) {
        const path = CacheManager.findExisting(this.cacheDirectory, entry.name,
          this.originalCacheKey(entry))
        if (path.length > 0) {
          await CacheManager.remove(path)
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
    const uri = this.previewUris[entry.path]
    const signature = this.previewUriSignatures[entry.path]
    return typeof uri === 'string' && uri.length > 0 && signature === this.previewSignature(entry)
      ? uri : ''
  }

  private setPreviewUri(entry: FileEntry, uri: string, localPath: string = '',
    canonical: boolean = false): void {
    const path = entry.path
    if (path.length === 0 || uri.length === 0) {
      return
    }
    const order: string[] = this.previewUriOrder.filter((key: string): boolean => key !== path)
    order.push(path)
    while (order.length > 96) {
      order.shift()
    }
    const next: Record<string, string> = {}
    const nextSignatures: Record<string, string> = {}
    const nextLocalPaths: Record<string, string> = {}
    const nextCanonicalPaths: Record<string, boolean> = {}
    const signature = this.previewSignature(entry)
    for (const key of order) {
      if (key === path) {
        next[key] = uri
        nextSignatures[key] = signature
        if (localPath.length > 0) {
          nextLocalPaths[key] = localPath
        }
        if (canonical) {
          nextCanonicalPaths[key] = true
        }
      } else {
        const existing = this.previewUris[key]
        const existingSignature = this.previewUriSignatures[key]
        const existingLocalPath = this.previewLocalPaths[key]
        if (typeof existing === 'string' && existing.length > 0 &&
          typeof existingSignature === 'string' && existingSignature.length > 0) {
          next[key] = existing
          nextSignatures[key] = existingSignature
          if (typeof existingLocalPath === 'string' && existingLocalPath.length > 0) {
            nextLocalPaths[key] = existingLocalPath
          }
          if (this.previewCanonicalPaths[key] === true) {
            nextCanonicalPaths[key] = true
          }
        }
      }
    }
    this.previewUriOrder = order
    this.previewUris = next
    this.previewUriSignatures = nextSignatures
    this.previewLocalPaths = nextLocalPaths
    this.previewCanonicalPaths = nextCanonicalPaths
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
        this.primeViewerPreviewGeometryAtPath(entry, canonicalPath, true).catch((): void => {})
        this.setPreviewUri(entry, fileUri.getUriFromPath(canonicalPath), canonicalPath, true)
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
          await this.primeViewerPreviewGeometryAtPath(entry, canonicalPath, true)
          this.setPreviewUri(entry, fileUri.getUriFromPath(canonicalPath), canonicalPath, true)
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
        await this.primeViewerPreviewGeometryAtPath(entry, thumbnailPath)
        this.setPreviewUri(entry, fileUri.getUriFromPath(thumbnailPath), thumbnailPath)
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
    const message = task.status === 'completed'
      ? '只移除下载记录，不会删除 Download/UGREENlink 中的文件。'
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
    await this.downloadQueue.removeRecord(task.id)
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
    return Math.min(100, Math.max(0, task.receivedBytes / task.size * 100))
  }

  private downloadTaskInfo(task: DownloadTaskRecord): string {
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
        return transfer + ' · 下载失败'
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
    const extension = this.fileExtension(entry.name)
    return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tif', 'tiff'].indexOf(extension) >= 0
  }

  private isVideo(entry: FileEntry): boolean {
    const extension = this.fileExtension(entry.name)
    return ['mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm', '3gp', 'ts'].indexOf(extension) >= 0
  }

  private isAudio(entry: FileEntry): boolean {
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
    await this.ensureDownloadState()
    await this.downloadQueue.setReady(false)
    this.repository.logout()
    this.navigationRequestId += 1
    this.isNavigating = false
    this.screen = 'login'
    this.showStorageSettings = false
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
}
