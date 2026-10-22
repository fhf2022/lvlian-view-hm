import { StartupAuthorization } from '../core/authorization/StartupAuthorization'
import { ContinuationManager, ContinuationPage, ContinuationAccountRequired } from '../continuation/ContinuationManager'
import { ContinuationPolicy, ContinuationSnapshot } from '../continuation/ContinuationModel'
import { StorageBudget } from '../download/StorageBudget'
import { DownloadDestination } from '../download/DownloadDestination'
import { TransferBackgroundManager } from '../transfer/TransferBackgroundManager'
import { promptAction, uiMaterial, curves, window, LengthMetrics, FrameCallback, PiPWindow,
  CapsuleSegmentButtonV2, SegmentButtonV2Items } from '@kit.ArkUI'
import { systemShare, harmonyShare } from '@kit.ShareKit'
import { Context, Want, common, wantConstant, autoFillManager, bundleManager } from '@kit.AbilityKit'
import { fileIo, fileUri, picker } from '@kit.CoreFileKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { FloatingImportControl } from '../components/FloatingImportControl'
import { AlbumUploadPicker } from '../components/AlbumUploadPicker'
import { AlbumUploadSheet } from '../components/AlbumUploadSheet'
import { AlbumUploadDetails } from '../components/AlbumUploadDetails'
import { TransferTaskListRow } from '../components/TransferTaskListRow'
import { HeaderStyle } from '../ui/HeaderStyle'
import { FileRowStyle } from '../ui/FileRowStyle'
import { TaskPanel, TaskPanelFooter, TaskPanelSection } from '../components/TaskPanel'
import { TaskPanelStyle } from '../ui/TaskPanelStyle'
import { DirectoryHeaderState } from '../ui/DirectoryHeaderState'
import { AlbumUploadManager } from '../upload/AlbumUploadManager'
import { AlbumUploadJob, LocalImageAlbum } from '../upload/AlbumUploadModel'
import { LocalAlbumSource } from '../upload/LocalAlbumSource'
import { FisheyeTimeline } from '../components/FisheyeTimeline'
import { ProximityLightReceiver } from '../components/ProximityLightReceiver'
import { UploadQueueManager, UploadTaskRecord } from '../upload/UploadQueueManager'
import { preferences, uniformTypeDescriptor as utd } from '@kit.ArkData'
import { image } from '@kit.ImageKit'
import { media } from '@kit.MediaKit'
import { audio, AVVolumePanel } from '@kit.AudioKit'
import { AVCastPicker, AVCastPickerState, avSession } from '@kit.AVSessionKit'
import { visionImageAnalyzer } from '@kit.VisionKit'
import { hilog, hiTraceMeter } from '@kit.PerformanceAnalysisKit'
import { systemDateTime } from '@kit.BasicServicesKit'
import { DownloadTaskRecord, FileEntry } from '../model/FileEntry'
import { FileSelectionModel, FileSelectionState } from '../model/FileSelectionModel'
import { DragSelectionScrollPolicy } from '../model/DragSelectionScrollPolicy'
import { ContextMenuPreviewLayout, ContextPreviewRect } from '../model/ContextMenuPreviewLayout'
import { CacheManager } from '../download/CacheManager'
import { DownloadQueueManager } from '../download/DownloadQueueManager'
import { UserFileManager } from '../download/UserFileManager'
import { AudioPlaybackManager } from '../media/AudioPlaybackManager'
import { AudioPlayerPage } from '../components/AudioPlayerPage'
import { AudioCoverRect, AudioLyricLine, AudioPlayerPolicy, AudioPlayMode } from '../media/AudioPlayerPolicy'
import { AudioMetadataReader } from '../media/AudioMetadataReader'
import { AudioSessionManager } from '../media/AudioSessionManager'
import { VideoPlaybackManager } from '../media/VideoPlaybackManager'
import { VideoPlayerControls } from '../components/VideoPlayerControls'
import { PlayerGestures } from '../media/PlayerGestures'
import { PlayerBrightness } from '../media/PlayerBrightness'
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
import { BinaryDownloadProgress, BinaryProgressListener, HttpTransport } from '../core/network/HttpTransport'
import { UgreenError, UgreenErrorKind, readableUgreenError } from '../ugreen/UgreenErrors'
import { FileEntryDataSource, THUMB_PROBE } from '../model/FileEntryDataSource'
import { PreviewLoadQueue } from '../media/PreviewLoadQueue'
import { ImagePipelineTelemetry } from '../media/ImagePipelineTelemetry'
import { ReturnPerfSession } from '../media/ReturnPerfSession'
import { ThumbnailPolicy, ThumbnailSize } from '../media/ThumbnailPolicy'
import { ThumbnailCacheStore } from '../media/ThumbnailCacheStore'
import { ViewerBitmapRecord, ViewerBitmapStore } from '../media/ViewerBitmapStore'
import { ViewerPrefetchCoordinator, ViewerEntryState } from '../media/ViewerPrefetchCoordinator'
import { NetworkClass, NetworkPolicy } from '../core/network/NetworkPolicy'
import { NasConnection, NasConnectionState } from '../core/network/NasConnection'
import { OfflineAccountProfile } from '../core/session/OfflineAccountProfile'
import { HapticFeedback } from '../core/haptic/HapticFeedback'
import {
  DirectoryIndexedSnapshot,
  DirectoryQuery,
  DirectoryTimeline,
  DirectoryTimelinePolicy,
  TimelinePeriod
} from '../model/DirectoryTimeline'

interface PendingViewerCleanupItem {
  record: ViewerBitmapRecord
  path: string
  kind: 'preview' | 'original'
  estimatedBytes: number
}

type RemoteScreen = 'login' | 'otp' | 'files' | 'downloads' | 'settings'
type RootKind = 'personal' | 'shared'
type BottomTab = 'home' | 'shared' | 'downloads' | 'settings'
type PageTransitionDirection = 'push' | 'pop'
type FileViewMode = 'list' | 'grid' | 'waterfall'
type DefaultViewKind = 'file' | 'photo' | 'audio'
type FileSortKey = 'name' | 'type' | 'time' | 'size'
type SearchReturnMode = 'none' | 'directory' | 'image' | 'audio' | 'video' | 'download'
type FileAction = 'share' | 'openWith' | 'quickView' | 'multiSelect' | 'download' |
  'saveGallery' | 'releaseCache' | 'rename' | 'details' | 'delete' | 'copy' | 'move'
type DestinationOperation = 'copy' | 'move'
type DeleteResolution = 'deleted' | 'failed' | 'unknown'

// Shared-element transitions are deliberately separate from the 180 ms
// Swiper animation.  The image should have enough time to travel from its
// file-row frame to the viewer without delaying network/decode work.
// 共享元素转场时长。240ms：比 300ms 更跟手。
// ⚠️ 这个值只影响"动画手感"，与"动画结束后丢触控"无关（那由 isBusy 的释放时机决定）。
const IMAGE_GEOMETRY_TRANSITION_DURATION: number = 240
// ⚠️ 是否使用"共享元素转场"（geometryTransition）做 格子→大图 的飞行。
//
// 【结论：不是卡顿的原因，保持开启】
// 曾依据"官方相册 ACE_GEOMETRY_TRANSITION 为 0 次"推断它不用共享元素，并把这里置为
// false；但实测关闭后卡顿依旧，且过场动画丢失（用户反馈"图库有完整的过场动画，
// 现在改完我这里没了"）。说明相册是用别的机制（自定义 AnimateTo/customNavContentTransition）
// 实现过场，不能用 ACE_GEOMETRY_TRANSITION 的次数来判断；关闭共享元素这条路无效。
// ⚠️ 后续若要验证，改这一行即可，不要再去动两处转场分支。
const VIEWER_USE_SHARED_ELEMENT_TRANSITION: boolean = true
// "长按图片 = 系统识别文字"的判定时长。见 handleImageTouch / armImageLongPressWatch。
const IMAGE_LONG_PRESS_MS: number = 400
// Allow a short NAS download to finish on this grab rather than proactively
// rejecting at 2.5 seconds. Share Kit recommends submission within 3 seconds
// but exposes no API to extend its own timeout; this only bounds our wait.
const GESTURE_SHARE_PREPARATION_MS: number = 5000
const IMAGE_FALLBACK_TRANSITION_DURATION: number = 160
const VIDEO_GEOMETRY_TRANSITION_DURATION: number = 420
const VIDEO_FALLBACK_TRANSITION_DURATION: number = 160
const VIDEO_FRAME_CROSSFADE_DURATION: number = 120
const IMAGE_RETURN_MOUNT_FRAME_LIMIT: number = 8
const IMAGE_VIEWER_DIAGNOSTICS: boolean = true
// 一次性诊断开关：记录「点击 → 画面出现/消失」各段耗时（见 tapTrace / tapTraceBegin）。
// ⚠️ 出结论后改回 false，或整段删除。
const TAP_TRACE: boolean = true
// ── 实验 G：状态写入 hitrace 打点（与 ftrace 同一条时间轴）──────────────────
//
// 目的：把「某个根级 @State 被写入」与「随后的 CustomNodeUpdate name:Index」
// 直接放到同一条 hitrace 时间轴上，判定昂贵的 ExecuteRerender 到底由哪一组
// 状态写入驱动。判读不依赖 hilog 对齐，也没有 console 的额外开销。
//
// 打点形式：零时长区间（startTrace 后立刻 finishTrace），名字精确到状态变量，
// 例如 `StateWrite:cbf.showPageTransition`。字符串全部是字面量，不做拼接。
//
// ⚠️ 出结论后把 STATE_TRACE 改回 false（或整段删除）。
// ⚠️ G4（handleImageDismissUpdate / 下拉手势）刻意不打点：既有 trace 已证明
//    HandleDragUpdate → CNU(Index) 相关性为 0%，无需重复验证。
const STATE_TRACE: boolean = true
const STATE_TRACE_TASK_ID: number = 1001
// ── 实验 H0：条目级精准失效 vs 全局 epoch 重渲染 ────────────────────────────
//
// 目的：验证将"缩略图 ready → 全局 epoch++ → Index 全页重渲染"
//      改为"缩略图 ready → datasource.notifyItemChanged(index) → 单项局部更新"，
//      能否在保持 stable key ((entry) => entry.path) 的前提下：
//      1) 消除缩略图完成导致的 Index.ExecuteRerender（7~11ms 长帧）；
//      2) 保证缩略图依然正常逐张呈现；
//      3) 不破坏 geometryTransition 共享元素动画。
//
//   true  = Baseline（原行为：修改根级 @State viewerBitmapEpoch，整页重跑 build）
//   false = 实验 H0（单条目精准通知 onDataChange(index)，解耦全局 epoch）
const USE_GLOBAL_BITMAP_EPOCH: boolean = false
// ── R2 原型：把网格缩略图那块抽成独立 @Component（@Observed + @ObjectLink） ──
//
// 背景（R1 实测结论，见 2026-09-30 记忆 / r1_continuous.ftrace）：
//   · R0（false）下 `notifyItemChanged` → `onDataChange(index)` 只换了数据对象，
//     因为 keyGenerator 仍是 entry.path（key 未变），LazyForEach 认为还是同一个
//     item，**不会重跑 item 生成器** → `[5]/[6]` 从不出现 → 缩略图永久滞留占位。
//   · R1（true）靠"根组件整树重跑"顺带把已挂载 cell 全部重跑，图是出来了，
//     代价是 43 次 CNU(Index)，其中 14 次 >16.67ms（P90 56.5ms，self 896ms，
//     占坏帧 ~78%）—— 这就是肉眼看到的"滑动时偶尔闪一下"。
//
// 本开关的目标：让"某条目的缩略图版本号变了"只通知【那一个 cell】重算，
//   既不经过根组件整树 build，也不改 keyGenerator（保住 GridItem identity）。
//
//   true  = R2（网格 cell 走 GridThumbCell 子组件 + @ObjectLink entry）
//   false = 基线（保持内联写法，与 R1 前一致）
const EXPERIMENT_R2_THUMB_CELL: boolean = true
// ── R2 推广（瀑布流）：同机制、独立开关，便于单独验证与回滚 ──────────────
//
// 瀑布流与 Grid 不同构，必须单独做：
//   · 图片在独立 @Builder `WaterfallPreviewImage` 里，且与 `LoadingProgress` 是
//     兄弟节点 → 子组件要连 `Stack({alignContent: Center})` 一起包（节点身份不变）。
//   · 多一个「宽高比已就绪」状态：就绪前不传 sourceSize 且 opacity(0)（避免
//     ArkUI 用临时 FlowItem 的 1:1 方框播种解码目标）。
//   · 失效走的是两个【全局 epoch】：`waterfallSourceEpoch`（只在 waterfallUri() 里读）
//     与 `waterfallAspectEpoch`（只在 resolvedWaterfallAspectRatio() 里读），
//     两者都在 item builder 路径上 → 每次 bump 都会重跑整棵树。
//     包成子组件后，这两处读取改在子组件 build 期间发生，依赖落到 cell 上，
//     不再整树重跑；再加上 previewRevision 的就地自增做单条精准刷新。
//
//   true  = R2W（瀑布流走 WaterfallThumbCell 子组件）
//   false = 基线（保持内联 + @Builder 写法）
const EXPERIMENT_R2_WATERFALL_CELL: boolean = true
// ── 🔬 临时探针（Q3 清理时删除）：首次打开共享元素动画的真实绑定状态 ──────────
//
// 已知：`entry-source-bound` 只证明 Index 层"决定启用 geometry transition"，
//      它证明不了 GridThumbCell 里的真实 Image 节点在 L15550 那一静默帧
//      重新 build 并挂上了 transitionId。
// 本探针只补 4 个时间点（+2 个既有 tapTrace），全部只读、无延时、不改结构：
//   1) startViewerEntryTransition：expected transitionId + 闸门结果
//   2) resolveGridImageStateInto（= cell 真正 build 时）：rev + 实际 transitionId
//   3) GridThumbCell 内 Image onAppear：节点出现时刻的 transitionId
//   4) viewer target Image onAppear：目标节点出现时刻的 transitionId
//   附：shouldReplaceViewerTransitionSource（parent build 期）→ source 是保留还是被 Blank 顶掉
// 只在 startViewerEntryTransition 后 800ms 窗口内输出，避免热路径刷屏。
const OPEN_ANIM_PROBE: boolean = true
// ── 缩略图完成路径诊断（用于隔离验证 M1a / M1b）────────────────────────────
//
// M1 实际包含两个子问题：
//   M1a：每张 thumbnail 完成 → installViewerBitmap → clone 整个 Map（O(n)）
//   M1b：每张 thumbnail 完成 → bumpViewerBitmapEpoch → 全局 UI 状态传播
//
// 本开关只处理 M1b：
//   false = Baseline（原行为：每张完成都立即 epoch++）
//   true  = 实验 A（clone 次数【保持不变】，只把 epoch 提交合并为"每帧最多一次"）
//
// ⚠️ 本阶段刻意【不改】installViewerBitmap 的整体 Map 拷贝。
// 这样若长帧明显下降 → M1b 贡献大；只小幅下降 → M1a 仍占相当比例；
// 几乎不下降 → 【不能据此排除 M1】，因为 M1a 完全没动过。（下一阶段再单独取消 clone）
const THUMB_BATCH_EPOCH: boolean = true
// 诊断开关：汇总统计缩略图完成路径。⚠️ 只在窗口结束时输出一条 hilog，
// 绝不逐张打印（日志本身会干扰性能测量）。
const THUMB_DIAG: boolean = true
// ── 实验 A：网格项把 Image 换成同尺寸 Blank（**分界实验**）────────────────
//
// 目的：判断"Grid measure 被拖慢"到底是【Grid 布局算法本身】还是【Image 子树/图片处理】。
// 做法：保持 Grid / GridItem / 列数 / Cell 尺寸 / 文字 / 滚动 / FisheyeTimeline /
//      所有布局参数【完全不变】，只把 `Image(...)` 换成同尺寸 `Blank()`。
// 判读：若 CreateTaskMeasure[Grid] 从 ~85ms 降到几毫秒、长帧基本消失
//      → 不是 Grid 布局算法，而是 Image 子树/图片资源处理把 measure 拖慢。
//
// ⚠️ 注意：本开关仍保留 fileImageSourceAvailable 判断（即仍会解析 1 次图片源），
//   所以它去掉的是「Image 子树 + 另外 2 次源解析 + 实际解码」。
//   若要进一步区分"解码重(M2)"还是"重复解析(R2)"，需要再做 A2（保留 Image、只换常量 source）。
const EXPERIMENT_GRID_BLANK: boolean = false
// ── 实验 C：关闭「从图片查看器返回后的预热」──────────────────────────────
//
// 剩余现象很特定：整体已可接受，但"刚返回开始滑"那一下明显卡。
// 其时间线固定为：
//     viewer-close-done → schedulePreviewWarmup → 约 400ms → scroll-start
// 本开关只影响【返回】这一条路径（finishCloseImageViewer），不碰目录切换那处，
// 也不改任何 UI 结构 —— 唯一变量就是"返回后还预热不预热"。
//
// true  = 关闭返回后的预热（实验组）
// false = 保持现状（对照组）
const DISABLE_RETURN_WARMUP: boolean = true
// ── 实验 D：固定 source 的 Image（比 Blank 更精确的一刀）────────────────────
//
// Blank 实验一次去掉了太多东西（Image 节点 / ImageSource / URI / decode / PixelMap）。
// 本实验【保持 Image 组件与节点结构完全不变】，只把 source 换成"同一个、已缓存
// 的本地小图"，从而只消除：真实 URI / previewUri / getUriFromPath / 每文件不同
// source / thumbnail 解码。
//
// 判读：
//   · 若 CreateImageObj 的耗时从 ~41ms 掉到个位数
//     → 贵的是「创建 Image 时处理真实 source」→ R2（source 解析/复用）是核心
//   · 若固定资源仍要 30~40ms
//     → 贵的是「大量 Image 节点本身创建/绑定进入 Grid 热路径」
//       → 去优化节点复用 / prebuild / cachedCount / 减少同帧创建量
const EXPERIMENT_GRID_FIXED_SOURCE: boolean = false
// ── 实验 B′：网格图片的**解码尺寸**（唯一变量：source resolution）─────────────
//
// 目的：M2 —— 判断"图片太重"里有多少来自"源图太大"。
// 做法：Grid Cell 320×320 / 列数 / 组件树 / fit / orientation / 排序 / 目录
//      **全部不变**，只改 Image 的解码目标尺寸。
//   · 0   = 不限制（= 现状基线：ArkUI 按组件尺寸自动解码）
//   · 128 / 256 / 512 = 指定解码尺寸（SDK 注明 number 单位是 vp）
//
// ⚠️ 相比"生成三套 128/256/512 的缩略图文件"，用 sourceSize 更干净：
//    source 文件完全相同 → disk cache 天然全命中、无额外 NAS 请求 →
//    真正只有"解码目标尺寸"这一个变量在变（不必预热三套缓存）。
//
// 判读：
//   · 若 GetImageData / PixelMap / Grid Measure 的 P95·P99 随分辨率明显下降 → M2 坐实
//   · 若分辨率降了但上述指标变化不明显 → 问题偏向"重复解析/source 创建次数"(R2)
//     下一刀就该做 resolveFileImageState，而不是继续降分辨率
const EXPERIMENT_GRID_SOURCE_SIZE: number = 0
// 生产方案：当前图独占高清 original。邻图仅保留/常驻轻量 preview（~786KB），
// 禁止邻图预加载 33.5MB original，将 Viewer 峰值从 ~103MB 裁减至 ~35MB。
const EXPERIMENT_A3_SINGLE_ORIGINAL_VIEWER: boolean = true
// 生产基线：Grid 缓存窗口固定为 4（兼顾准入削峰与视口抗扰动）
const EXPERIMENT_GRID_CACHED_COUNT: number = 4
// ⚠️ 实验用：取"不超过源尺寸"的解码目标。
//   `sourceSize` 传大于源尺寸的值会导致硬件解码失败
//   （`JPEGHWDECODER failed to do decode, err=-1` → 白屏），所以必须夹住。
//   源尺寸优先取状态里已知的解码后尺寸（渲染路径上零 IO）；未知时退回目标值
//   —— 实测 NAS 缩略图多为 512×384，256 在其之下，安全。
const EXPERIMENT_GRID_SOURCE_SAFE: boolean = true
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
const FLOATING_TIMELINE_WIDTH_VP: number = 68
const FLOATING_TIMELINE_RAIL_WIDTH_VP: number = 42
const FLOATING_TIMELINE_GAP_VP: number = 8
// 收起态：整条向右平移，只在屏幕右缘留出一小截（日期标签的左半截，允许被裁切，
// 正是这一小截提示用户「这里可以点」）。轴条本体因此完全移出屏外，不再挡住最右列。
const FLOATING_TIMELINE_PEEK_VP: number = 28
const FLOATING_TIMELINE_EFFECT_INSET_VP: number = 16
const FLOATING_TIMELINE_UPWARD_SHIFT_VP: number = 8
// 目录索引的新鲜度阈值。原先 30 秒 —— 进过的目录隔半分钟就会被强制全量重拉一次
// （forceNetwork=true 会跳过内存与持久化缓存）。实测 /Photos/Camera 有 5342 项，
// 一次重拉要 6.4 秒；这期间不仅"文件夹较大需等待"的提示一直挂着，连图片的
// 打开/关闭都被拖慢到 2.7 秒（正常约 360ms）。放宽到 5 分钟。
const DIRECTORY_INDEX_STALE_MS: number = 5 * 60 * 1000
// 后台自动刷新只对中小目录做。大目录一次要拉几 MB、解析排序耗时数秒，
// 代价远大于"新鲜度"的收益，不如等用户主动下拉刷新。
const DIRECTORY_AUTO_REFRESH_MAX_ITEMS: number = 2000
// 进目录的等待提示只在【预计项数 >= 这个值】时才显示（小目录不打扰）。
const DIRECTORY_OPENING_HINT_MIN_ITEMS: number = 500
const FILE_TOOL_HEIGHT_VP: number = 40
// Keep a small number of recently decoded WaterFlow rasters alive. The
// durable thumbnail files are much cheaper and can cover the rest of the
// directory; this budget only protects the hot back-scroll path.
const WATERFALL_BITMAP_MEMORY_LIMIT_BYTES: number = 48 * 1024 * 1024
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

/**
 * R2 修复：网格项在一次 build 中需要的全部图片显示信息。
 * 由 `resolveGridImageState()` 一次性解析，避免同一轮构建里重复求值。
 */
class GridImageState {
  available: boolean = false
  hidden: boolean = false
  source: image.PixelMap | string = ''
  orientation: ImageRotateOrientation = ImageRotateOrientation.UP
  transitionId: string = ''
  syncLoad: boolean = false
  sourceWidth: number = 0
  sourceHeight: number = 0
}

class ViewerReturnRect {
  x: number = 0
  y: number = 0
  width: number = 0
  height: number = 0
}

// A borrowed reference to exactly the raster currently shown by Viewer.
// Ownership stays in the Viewer stores until the existing idle cleanup queue.
class ViewerReturnSnapshot {
  path: string = ''
  source: image.PixelMap | string = ''
  orientation: ImageRotateOrientation = ImageRotateOrientation.UP
  fit: ImageFit = ImageFit.Contain
  frameWidth: number = 0
  frameHeight: number = 0
  target: ViewerReturnRect = new ViewerReturnRect()
  hasTarget: boolean = false
}

/**
 * R2 原型：网格缩略图 cell 与 Index 之间的桥。
 *
 * 🔴 纪律：桥上的方法会在【子组件 build 期间】被调用，因此只允许读非 @State 的
 *    存储（位图/URI Map、entry 自身字段）。一旦在子组件里读到 Index 的 @State，
 *    依赖会重新注册回根组件，R2 就失去意义。
 *    `resolveGridImageStateInto()` 满足这一点：它只走 previewUri()（结果缓存 Map）、
 *    imageVisualState()（Map）与 entry 字段，不碰任何 epoch。
 */
class GridThumbBridge {
  resolveInto: (entry: FileEntry, state: GridImageState) => GridImageState =
    (entry: FileEntry, state: GridImageState): GridImageState => state
  icon: (entry: FileEntry) => Resource =
    (entry: FileEntry): Resource => $r('app.media.startIcon')
  onComplete: (entry: FileEntry, index: number, event?: ViewerImageCompleteEvent) => void =
    (entry: FileEntry, index: number, event?: ViewerImageCompleteEvent): void => {}
  onError: (entry: FileEntry) => void = (entry: FileEntry): void => {}
  // 🔬 OpenAnimProbe：cell 内 Image 节点出现（Q3 清理时删除）
  probeAppear: (entry: FileEntry, index: number) => void =
    (entry: FileEntry, index: number): void => {}
}

/**
 * R2 推广（瀑布流）：cell 与 Index 之间的桥。
 * 🔴 与 GridThumbBridge 同纪律：方法在【子组件 build 期间】被调用，
 *    只允许读非 @State 的存储（位图/URI Map、entry 字段）；两个 waterfall epoch
 *    是刻意保留的（它们现在只被 cell 读到，依赖落在 cell 上，不再整树重跑）。
 */
class WaterfallThumbBridge {
  resolveInto: (entry: FileEntry, state: WaterfallImageState) => WaterfallImageState =
    (entry: FileEntry, state: WaterfallImageState): WaterfallImageState => state
  onComplete: (entry: FileEntry, index: number, event?: ViewerImageCompleteEvent) => void =
    (entry: FileEntry, index: number, event?: ViewerImageCompleteEvent): void => {}
  onError: (entry: FileEntry) => void = (entry: FileEntry): void => {}
}

/** 瀑布流一次 build 需要的图片信息（含「宽高比是否就绪」这条瀑布流专属状态）。 */
class WaterfallImageState {
  available: boolean = false
  aspectReady: boolean = false
  source: image.PixelMap | string = ''
  orientation: ImageRotateOrientation = ImageRotateOrientation.UP
  transitionId: string = ''
  syncLoad: boolean = false
  sourceWidth: number = 0
  sourceHeight: number = 0
}

/**
 * R2 推广（瀑布流）：把「图片 + LoadingProgress」这一整块包成独立子组件。
 * ⚠️ 根节点就是原来那个 `Stack({alignContent: Center})`（含 borderRadius/clip），
 *    自定义组件不产生节点，所以外层 FlowItem 看到的子树形状与改前一致。
 * ⚠️ 带 geometryTransition 的 Image 必须【内联】在本组件 build 里。
 */
@Component
struct WaterfallThumbCell {
  @ObjectLink entry: FileEntry
  bridge: WaterfallThumbBridge = new WaterfallThumbBridge()
  index: number = 0
  private state: WaterfallImageState = new WaterfallImageState()

  private st(): WaterfallImageState {
    return this.bridge.resolveInto(this.entry, this.state)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.st().available) {
        if (this.st().aspectReady) {
          Image(this.st().source)
            .width('100%')
            .height('100%')
            .sourceSize({ width: this.st().sourceWidth, height: this.st().sourceHeight })
            .orientation(this.st().orientation)
            .objectFit(ImageFit.Contain)
            .geometryTransition(this.st().transitionId)
            .syncLoad(this.st().syncLoad)
            .opacity(1)
            .onComplete((event?: ViewerImageCompleteEvent): void => {
              this.bridge.onComplete(this.entry, this.index, event)
            })
            .onError((): void => {
              this.bridge.onError(this.entry)
            })
        } else {
          // 不传临时的 1:1 sourceSize：WaterFlow 回收 item 时 ArkUI 可能复用已解码的
          // raster，首次解码必须等 Image Kit 的真实几何，否则会把临时方框的目标尺寸固化。
          Image(this.st().source)
            .width('100%')
            .height('100%')
            .orientation(this.st().orientation)
            .objectFit(ImageFit.Contain)
            .geometryTransition(this.st().transitionId)
            .syncLoad(this.st().syncLoad)
            .opacity(0)
            .onComplete((event?: ViewerImageCompleteEvent): void => {
              this.bridge.onComplete(this.entry, this.index, event)
            })
            .onError((): void => {
              this.bridge.onError(this.entry)
            })
        }
      }
      if (!this.st().available || !this.st().aspectReady) {
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
}

/**
 * R2 原型：只包「缩略图 / 占位图」这一小块。
 *
 * ⚠️ 刻意【不】包外层那个 Stack —— 外层带 aspectRatio / onAreaChange /
 *    onVisibleAreaChange，节点位置与 identity 原样不动，转场最安全。
 *    自定义组件不产生节点，所以在父层 Stack 看来子树形状与改前一致。
 * ⚠️ 带 geometryTransition 的 Image 必须【内联】在本组件 build 里，
 *    不能再提一层 @Builder（历史上提取 @Builder 导致过场动画消失）。
 * ⚠️ 结果对象复用同一个实例（build 内会问 3~4 次，不能每次分配）。
 */
@Component
struct AudioFileLeadingCell {
  @ObjectLink entry: FileEntry
  resolve: (entry: FileEntry) => string = (): string => ''

  private source(): string {
    const revision = this.entry.previewRevision
    return revision >= 0 ? this.resolve(this.entry) : ''
  }

  build() {
    if (this.source().length > 0) {
      Image(this.source())
        .width(FileRowStyle.leadingWidth)
        .height(FileRowStyle.leadingHeight)
        .objectFit(ImageFit.Cover)
        .borderRadius(6)
    } else {
      Image($r('sys.media.ohos_ic_normal_white_grid_audio'))
        .width(FileRowStyle.iconSize)
        .height(FileRowStyle.iconSize)
        .objectFit(ImageFit.Contain)
    }
  }
}

@Component
struct GridThumbCell {
  @ObjectLink entry: FileEntry
  bridge: GridThumbBridge = new GridThumbBridge()
  index: number = 0
  private state: GridImageState = new GridImageState()

  private thumbState(): GridImageState {
    return this.bridge.resolveInto(this.entry, this.state)
  }

  build() {
    if (this.thumbState().available) {
      if (this.thumbState().sourceWidth > 0) {
        Image(this.thumbState().source)
          .width('100%')
          .height('100%')
          .sourceSize({
            width: this.thumbState().sourceWidth,
            height: this.thumbState().sourceHeight
          })
          .orientation(this.thumbState().orientation)
          .objectFit(ImageFit.Cover)
          .geometryTransition(this.thumbState().transitionId)
          .syncLoad(this.thumbState().syncLoad)
          .visibility(this.thumbState().hidden ? Visibility.Hidden : Visibility.Visible)
          .onAppear((): void => {
            this.bridge.probeAppear(this.entry, this.index)
          })
          .onComplete((event?: ViewerImageCompleteEvent): void => {
            this.bridge.onComplete(this.entry, this.index, event)
          })
          .onError((): void => {
            this.bridge.onError(this.entry)
          })
      } else {
        Image(this.thumbState().source)
          .width('100%')
          .height('100%')
          .orientation(this.thumbState().orientation)
          .objectFit(ImageFit.Cover)
          .geometryTransition(this.thumbState().transitionId)
          .syncLoad(this.thumbState().syncLoad)
          .visibility(this.thumbState().hidden ? Visibility.Hidden : Visibility.Visible)
          .onAppear((): void => {
            this.bridge.probeAppear(this.entry, this.index)
          })
          .onComplete((event?: ViewerImageCompleteEvent): void => {
            this.bridge.onComplete(this.entry, this.index, event)
          })
          .onError((): void => {
            this.bridge.onError(this.entry)
          })
      }
    } else {
      Image(this.bridge.icon(this.entry))
        .width(48)
        .height(48)
        .objectFit(ImageFit.Contain)
    }
  }
}

@Component
struct FileSelectionIndicator {
  @State selection: FileSelectionState = new FileSelectionState()
  @Prop dark: boolean = false
  path: string = ''

  build() {
    Checkbox()
      .id('file-selection:' + this.path)
      .select(this.selection.selected)
      .shape(CheckBoxShape.CIRCLE)
      .selectedColor('#2E6BFF')
      .unselectedColor(this.dark ? '#99FFFFFF' : '#89919B')
      .width(28)
      .height(28)
      .hitTestBehavior(HitTestMode.None)
  }
}

@Component
struct FileSelectionOutline {
  @State selection: FileSelectionState = new FileSelectionState()

  build() {
    Stack() {}
      .width('100%')
      .height('100%')
      .outline({ width: this.selection.selected ? 2 : 0, color: '#2E6BFF', radius: 10 })
      .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
  }
}

/**
 * 🔬 临时探针结果（Q3 清理时删除）：图片冷启动 metadata Range 实验的单次尝试。
 * 只承载数据，绝不被写入 Viewer state。
 */
class ImageMetadataProbeResult {
  stage: string = ''
  rangeBytes: number = 0
  httpStatus: number = 0
  receivedBytes: number = 0
  netMs: number = 0
  parseMs: number = 0
  ok: boolean = false
  width: number = 0
  height: number = 0
  orientation: string = ''
  note: string = ''
}

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

// Single argument object for the round buttons in the file tools bar.
//
// This is not style: ArkUI only refreshes the UI inside a @Builder when a
// state-derived value reaches it as ONE object literal passed by reference.
// Passing the icon as its own (second, by-value) parameter silently disables
// that refresh, which is exactly why the view-mode glyph used to freeze at its
// first-frame value no matter how often the mode changed. Keep every
// state-dependent circle button on this single-object form.
interface FileToolCircleButtonOptions {
  icon: Resource
  action: () => void
  // 「一排按钮上滑动」用：按下 A、滑到 B 松手 → 触发 B。
  // slideBar 区分是哪一排（各排重叠在同一位置，必须分组命中）；
  // slideKey 是该按钮在这排里的标识。
  slideBar: string
  slideKey: string
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

interface GestureTransferPreparedData extends GestureTransferCacheResult {
  skippedCount: number
}

class ImageDisplayState {
  rotations: Record<string, number> = {}
  previewOrientations: Record<string, ImageRotateOrientation> = {}
}

// 一行在屏幕上的矩形（globalPosition，px），用于长按拖动扩选时的命中测试。
// 必须记「整行」而不是缩略图——行高 58vp、缩略图只有 40×34vp，
// 按缩略图的框去命中会小一大圈，滑过去点不中。
// ── 一排按钮上的滑动：按下 A、滑到 B 松手 → 触发 B ────────────────────
// 光感跟随手指由 ProximityLightReceiver 负责，这里只解决"松手判定用谁"。
// 注意不能把 onTouch 挂在容器上：子按钮 monopolizeEvents(true) 会独占事件，
// 父级收不到。所以挂在每个按钮上，用「自己的矩形 + 触摸相对偏移」换算全局
// 坐标，再去命中整排里的其它按钮。
class SlideActionItem {
  x: number = 0
  y: number = 0
  width: number = 0
  height: number = 0
  action: (() => void) | null = null
}
class BottomBarTouchRect {
  x: number = 0
  y: number = 0
  width: number = 0
  height: number = 0
}
class RowHitArea {
  entry: FileEntry | null = null
  surface: string = ''
  index: number = -1
  x: number = 0
  y: number = 0
  width: number = 0
  height: number = 0
}

@Entry
@Component
struct Index {
  @StorageProp('continuationPending') continuationPending: boolean = false
  @StorageProp('continuationWaitingForAccount') continuationWaitingForAccount: boolean = false
  @StorageProp('continuationMessage') @Watch('onContinuationMessage') continuationMessage: string = ''
  @State @Watch('onContinuationSceneChanged') continuationSending: boolean = false
  @State @Watch('onContinuationSceneChanged') continuationDialogCount: number = 0
  private continuationAncestorAnchors: Map<string, string> = new Map()
  private continuationPendingDeletes: Set<string> = new Set()
  private continuationPage: ContinuationPage = {
    available: (): boolean => this.continuationAvailable(),
    accountIdentity: (): string => this.linkId.trim().toLowerCase() + '|' + this.repository.sessionIdentity(),
    canReceive: (): boolean => this.continuationCanReceive(),
    capture: (): ContinuationSnapshot => this.captureContinuation(),
    sending: (active: boolean): void => { this.continuationSending = active },
    pauseSourceVideo: async (): Promise<void> => { await this.videoPlaybackManager.pause() },
    resumeSourceVideo: async (): Promise<void> => { await this.videoPlaybackManager.play() },
    restore: async (snapshot: ContinuationSnapshot, valid: () => boolean): Promise<void> => {
      await this.restoreContinuation(snapshot, valid)
    }
  }
  @State @Watch('onContinuationSceneChanged') screen: RemoteScreen = 'login'
  @State @Watch('onContinuationSceneChanged') startupRestoring: boolean = true
  @State @Watch('onContinuationSceneChanged') startupAuthorized: boolean = false
  @State startupAuthorizing: boolean = true
  @State startupAuthorizationMessage: string = ''
  private startupAuthorizationToken: number = 0
  private applicationInitialized: boolean = false
  @State linkId: string = ''
  @State username: string = ''
  @State password: string = ''
  @State otpCode: string = ''
  @State baseUrl: string = ''
  @State statusText: string = ''
  @State errorText: string = ''
  @State @Watch('onContinuationSceneChanged') isBusy: boolean = false
  @State trustDevice: boolean = false
  @State autoLogin: boolean = false
  @State rememberAddress: boolean = false
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
  @State @Watch('onContinuationSceneChanged') contextMenuVisible: boolean = false
  @State contextMenuEntry: FileEntry | null = null
  @State contextMenuLayout: ContextMenuPreviewLayout = new ContextMenuPreviewLayout()
  @State contextMenuPreviewSurface: string = 'list'
  // Which surface supplied the entry the menu is showing. The long-press menu
  // shell (anchor, preview, lifecycle) is shared with the file manager; only
  // the row list inside it differs, so this decides which rows are rendered.
  @State contextMenuContext: string = 'files'
  @State @Watch('onContinuationSceneChanged') showDestinationPicker: boolean = false
  @State destinationOperation: DestinationOperation = 'copy'
  @State destinationPath: string = ''
  @State destinationEntries: DestinationEntry[] = []
  @State destinationTreeRows: DestinationTreeRow[] = []
  @State destinationExpandedPaths: string[] = []
  @State destinationTreeLoadingPath: string = ''
  @State destinationRootExpanded: boolean = true
  @State destinationLoading: boolean = false
  @State @Watch('onContinuationSceneChanged') destinationOperationRunning: boolean = false
  @State destinationPickerClosing: boolean = false
  @State destinationSelectedEntries: FileEntry[] = []
  @State destinationFolderDialog: boolean = false
  @State destinationFolderText: string = ''
  // 选择态/查看器一变就重新评估隔空传送的注册（见 onGestureShareStateChanged）
  @State @Watch('onGestureShareStateChanged') selectionMode: boolean = false
  @State selectedPaths: string[] = []
  @State selectedEntryCount: number = 0
  private fileSelection: FileSelectionModel = new FileSelectionModel()
  private selectedEntriesCache: FileEntry[] | null = null
  @State @Watch('onContinuationSceneChanged') showSelectionMoreMenu: boolean = false
  @State renameEntry: FileEntry | null = null
  @State renameText: string = ''
  @State @Watch('onContinuationSceneChanged') showRenameDialog: boolean = false
  @State showStorageSettings: boolean = false
  @State showNetworkSettings: boolean = false
  @State showPlaybackSettings: boolean = false
  @State showViewSettings: boolean = false
  @State showRecycleBinSettings: boolean = false
  @State appVersionName: string = ''
  // UGOS keeps one recycle repository per first-level folder, so the signed-in
  // user's own folder and the shared folders are genuinely disjoint sets with
  // different permission rules — a shared folder's bin is the administrator's
  // unless that was turned off. They are two scopes of one page rather than a
  // single merged list, because merging them would hide which rule applied.
  @State recycleScope: string = 'personal'
  @State recycleEntries: FileEntry[] = []
  @State recycleLoading: boolean = false
  // Full recycle paths the user has drilled into, e.g.
  // `/home/fhf/#recycle/Photos`. An empty stack means the top level, which
  // lists each share's `#recycle` direct children.
  @State recycleStack: string[] = []
  // Folders whose bin exists but could not be read (usually a permission wall
  // on a shared folder). Kept so a partial result can be explained.
  @State recycleBlockedShares: string[] = []
  private recycleRequestToken: number = 0
  @State @Watch('onGestureShareStateChanged') showImageViewer: boolean = false
  @State @Watch('onGestureShareStateChanged') viewerImageEntry: FileEntry | null = null
  @State viewerInteractionUnlocked: boolean = true
  @State viewerBlocksFileContent: boolean = false
  @State @Watch('onContinuationSceneChanged') viewerClosing: boolean = false
  @State @Watch('onContinuationSceneChanged') viewerReturnOverlayVisible: boolean = false
  @State viewerReturnOverlayX: number = 0
  @State viewerReturnOverlayY: number = 0
  @State viewerReturnOverlayWidth: number = 0
  @State viewerReturnOverlayHeight: number = 0
  @State viewerReturnOverlayScale: number = 1
  @State viewerReturnOverlayOpacity: number = 1
  @State viewerReturnOverlayBackdropOpacity: number = 1
  private viewerReturnSnapshot: ViewerReturnSnapshot = new ViewerReturnSnapshot()
  private viewerReturnOverlayToken: number = 0
  private viewerReturnOverlayStartedAt: number = 0
  private viewerReturnOverlayMountResolve: (() => void) | null = null
  private viewerReturnHiddenPath: string = ''
  private viewerReturnRestoringPath: string = ''
  private viewerLayerOriginX: number = 0
  private viewerLayerOriginY: number = 0
  private viewerCurrentFramePath: string = ''
  private viewerCurrentFrame: ViewerReturnRect = new ViewerReturnRect()
  @State viewerHeaderTitle: string = ''
  @State viewerImages: FileEntry[] = []
  @State viewerImageIndex: number = 0
  // More/details keep their own snapshot of the committed image. Closing the
  // popup must not clear the sheet content before its dismissal completes.
  @State viewerOverlayEntry: FileEntry | null = null
  @State imageDetailsEntry: FileEntry | null = null
  @State @Watch('onContinuationSceneChanged') showImageMoreMenu: boolean = false
  @State @Watch('onContinuationSceneChanged') showImageDetails: boolean = false
  @State viewerLastNavigationDirection: number = 1
  // Pixel/geometry metadata is kept in a private identity map. The previous
  // @State record was copied in full for every visible-row callback, so the
  // ── 返回后首个手势链路精确观测（单会话防抖打点）──────────────────
  private closeSessionId: number = 0
  private closeSessionActive: boolean = false
  private closeAnimFinishMonotonic: number = 0
  private sessionTrackedPointerId: number = -1
  private sessionPreDispatchDownLogged: boolean = false
  private sessionTouchTestCount: number = 0
  private sessionRootDownLogged: boolean = false
  private sessionChildDownLogged: boolean = false
  private sessionPanStartLogged: boolean = false
  private sessionFirstPanUpdateLogged: boolean = false
  private sessionScrollStartLogged: boolean = false
  private localInputMonitor: InputEventMonitor | null = null

  // cost grew with the number of images visited during a scroll session.
  @State imageVisualEpoch: number = 0
  @State imageAnalyzerTypes: ImageAnalyzerType[] = []
  @State imageAnalyzerSupported: boolean = false
  // 用户是否正在"识别文字"（AI 按钮选中 / 识别控件可见）。见 configureImageAnalyzer。
  // 为 true 时禁掉图片的下拉关闭手势，避免拖动文字选择光标时图片跟着移动。
  @State imageAnalyzerActive: boolean = false
  private imageAnalyzerListenerBound: boolean = false
  // 长按识别文字的判定定时器（见 armImageLongPressWatch）。
  private imageLongPressTimer: number = 0
  @State @Watch('onContinuationSceneChanged') imageScale: number = 1
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
  // The dismiss pull follows the finger on BOTH axes, like the system gallery.
  // This cannot come from the dismiss recognizer: that one is deliberately
  // locked to PanDirection.Vertical so a horizontal drag stays with the Swiper,
  // and by the time it wins the arbitration the Swiper is already out of the
  // touch sequence, so the horizontal component would have no consumer at all.
  // It is fed from the raw touch stream instead, which is not subject to
  // gesture arbitration.
  @State imageDismissOffsetX: number = 0
  @State imageDismissBackdropOpacity: number = 1
  @State viewerSurfaceOpacity: number = 1
  // The entry animation is limited to the image that was tapped. The normal
  // viewer swiper animation uses viewerTransitionActive and remains separate.
  @State @Watch('onContinuationSceneChanged') viewerEntryTransitionActive: boolean = false
  @State viewerEntryTransitionPath: string = ''
  @State viewerTransitionKind: ViewerTransitionKind = 'none'
  @State viewerTransitionLayer: ViewerImageLayer = 'thumbnail'
  @State viewerGeometryBound: boolean = false
  @State @Watch('onContinuationSceneChanged') viewerFallbackEntryActive: boolean = false
  // Keep the viewer capsule size stable across device rotation. Only its
  // bottom-safe-area position should be recalculated by the new layout.
  @State viewerBottomBarWidthVp: number = 0
  @State @Watch('onContinuationSceneChanged') viewerTransitionActive: boolean = false
  @State @Watch('onContinuationSceneChanged') showAudioPlayer: boolean = false
  @State audioEntry: FileEntry | null = null
  @State audioLocalPath: string = ''
  @State audioPlaying: boolean = false
  @State audioCurrentMs: number = 0
  @State audioDurationMs: number = 0
  @State audioTitle: string = ''
  @State audioArtist: string = ''
  @State audioCover: string = ''
  @State audioMode: AudioPlayMode = 'order'
  @State audioLyrics: AudioLyricLine[] = []
  @State audioControlPending: boolean = false
  @State showAudioQueue: boolean = false
  @State audioOpening: boolean = false
  @State audioClosing: boolean = false
  @State audioPageOpacity: number = 1
  @State audioCoverHidden: boolean = false
  @State audioTransitionCoverScale: number = 0
  @State audioFlightVisible: boolean = false
  @State audioFlightX: number = 0
  @State audioFlightY: number = 0
  @State audioFlightWidth: number = 0
  @State audioFlightHeight: number = 0
  @State audioFlightRadius: number = 16
  @State audioFlightOpacity: number = 1
  @State audioFlightBaseSize: number = 320
  private audioReturnHiddenPath: string = ''
  private audioFlightSource: ResourceStr = ''
  private audioCoverRect: AudioCoverRect = new AudioCoverRect()
  private audioCoverVisibleRatio: number = 0
  private audioThumbnailFrames: Map<string, AudioCoverRect> = new Map()
  private audioThumbnailVisibility: Map<string, number> = new Map()
  private audioOpenToken: number = 0
  private audioEntryCloseRequested: boolean = false
  private audioEntryTransitionResolve: (() => void) | null = null
  private audioOriginSurface: ThumbnailSurfaceKind = 'none'
  private audioOriginKey: string = ''
  private audioOriginScope: string = ''
  private audioQueue: FileEntry[] = []
  private audioQueueSource: FileEntryDataSource = new FileEntryDataSource()
  private audioQueueScroller: Scroller = new Scroller()
  private audioSession: AudioSessionManager = new AudioSessionManager()
  private audioSessionUpdatedAt: number = 0
  private audioOwnsBusy: boolean = false
  private audioPageOriginX: number = 0
  private audioPageOriginY: number = 0
  // Playback preferences are kept separate from cache/network settings so
  // each settings page has one responsibility.
  @State backgroundVideoPlayback: boolean = true
  @State backgroundAudioPlayback: boolean = true
  @State videoBackgroundAutoPip: boolean = false
  @State autoPlayOnOpen: boolean = true
  @State @Watch('onContinuationSceneChanged') showVideoPlayer: boolean = false
  @State @Watch('onContinuationSceneChanged') videoOverlayClosing: boolean = false
  @State videoChromeVisible: boolean = true
  @State @Watch('onContinuationSceneChanged') videoEntryTransitionActive: boolean = false
  @State videoEntryTransitionPath: string = ''
  @State videoTransitionKind: ViewerTransitionKind = 'none'
  @State videoOverlayOpacity: number = 1
  @State videoSurfaceOpacity: number = 0
  @State videoPosterOpacity: number = 1
  @State videoPosterPath: string = ''
  @State videoPosterUri: string = ''
  @State videoPosterFixedOrientation: ImageRotateOrientation = ImageRotateOrientation.AUTO
  @State videoEntry: FileEntry | null = null
  @State videoSourceKey: string = ''
  @State videoLocalPath: string = ''
  @State videoDurationMs: number = 0
  @State videoCurrentMs: number = 0
  @State videoTimelineReady: boolean = false
  @State videoPlaying: boolean = false
  @State videoFastPlaybackActive: boolean = false
  @State videoGestureFeedback: string = ''
  @State videoGestureSeeking: boolean = false
  @State videoGesturePositionMs: number = 0
  @State @Watch('onContinuationSceneChanged') videoGestureActive: boolean = false
  @State videoSystemVolume: number | undefined = undefined
  @State videoPlaybackRate: number = 1
  @State @Watch('onContinuationSceneChanged') videoRatePending: boolean = false
  @State @Watch('onContinuationSceneChanged') videoRatePanel: boolean = false
  private videoPreferredRate: number = 1
  private videoRateRequestToken: number = 0
  @State videoMuted: boolean = false
  @State @Watch('onContinuationSceneChanged') videoPrepared: boolean = false
  @State videoFirstFrame: boolean = false
  @State videoSurfaceReady: boolean = false
  @State @Watch('onContinuationSceneChanged') videoOrientationChanging: boolean = false
  @State videoLandscape: boolean = false
  @State @Watch('onContinuationSceneChanged') videoControlPending: boolean = false
  @State videoWidthPx: number = 0
  @State videoHeightPx: number = 0
  @State videoBufferingPercent: number = 0
  @State @Watch('onContinuationSceneChanged') videoPipActive: boolean = false
  @State @Watch('onContinuationSceneChanged') videoPipBackgrounded: boolean = false
  @State @Watch('onContinuationSceneChanged') videoSeekDragging: boolean = false
  private videoSeekPending: boolean = false
  private videoSeekTargetMs: number = 0
  private videoCloseRequested: boolean = false
  private videoFrameRevealScheduled: boolean = false
  private videoOpeningPath: string = ''
  private videoReconcileDirectoryKey: string = ''
  private videoReconciledEntries: Record<string, boolean> = {}
  @State @Watch('onContinuationSceneChanged') videoPipCreating: boolean = false
  @State @Watch('onContinuationSceneChanged') videoCasting: boolean = false
  @State videoTransferStates: Record<string, VideoTransferState> = {}
  @State previewCanonicalPaths: Record<string, boolean> = {}
  // Waterfall identity maps stay private so a recycled FlowItem does not
  // copy every visited path. Epochs are the small reactive invalidation keys
  // consumed by the builders below.
  @State waterfallSourceEpoch: number = 0
  // PixelMap source changes are committed on a render frame.  The epoch is
  // intentionally the only reactive value; native PixelMap objects stay in
  // the private store and are never copied through @State records.
  @State viewerBitmapEpoch: number = 0
  // ── 缩略图完成路径诊断（THUMB_DIAG）──────────────────────────
  // 只在窗口结束时汇总输出，避免日志干扰测量。
  private thumbDiagFinished: number = 0
  private thumbDiagCloneCount: number = 0
  private thumbDiagEpochRequested: number = 0
  private thumbDiagEpochCommitted: number = 0
  private thumbDiagFrameCompletions: number = 0
  private thumbDiagFrameMaxCompletions: number = 0
  private thumbDiagCloneMsTotal: number = 0
  private thumbDiagCloneMsMax: number = 0
  private thumbDiagCommitMsTotal: number = 0
  private thumbDiagCommitMsMax: number = 0
  private thumbDiagBatchingPending: boolean = false
  private thumbDiagWindowStartAt: number = 0
  @State waterfallAspectEpoch: number = 0
  @State waterfallColumnWidthVp: number = 0
  @State directoryCounts: Record<string, number> = {}
  // 进目录的等待提示是否该显示（按目录项数判断，见 armDirectoryOpeningHint）
  @State directoryOpeningHintVisible: boolean = false
  private directoryOpeningHintToken: number = 0
  @State pageOffsetX: number = 0
  @State outgoingPageOffsetX: number = 0
  @State transitionSnapshotOnTop: boolean = false
  @State transitionSnapshotMode: FileViewMode = 'list'
  @State pageWidthVp: number = 360
  @State pageHeightVp: number = 800
  @State transferDirection: string = 'download'
  private transferDirectionItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: '下载' }, { text: '上传' }
  ])
  @State uploadTasks: UploadTaskRecord[] = []
  @State albumUploadJobs: AlbumUploadJob[] = []
  @State @Watch('onContinuationSceneChanged') showAlbumPicker: boolean = false
  @State @Watch('onContinuationSceneChanged') showAlbumUpload: boolean = false
  @State albumUploadStarting: boolean = false
  @State albumUploadSelection: LocalImageAlbum = new LocalImageAlbum()
  private albumConfirmationPending: boolean = false
  private albumReselectPending: boolean = false
  @State @Watch('onContinuationSceneChanged') showAlbumDetails: boolean = false
  private albumUploadActionsOpen: boolean = false
  @State albumDetailsId: string = ''
  @State albumDetailsName: string = ''
  @State albumUploadDestination: string = ''
  private albumUploadRootType: number = 0
  private albumUploadScope: string = ''
  private albumUpload: AlbumUploadManager = new AlbumUploadManager()
  @State @Watch('onContinuationSceneChanged') importExpanded: boolean = false
  @State @Watch('onContinuationSceneChanged') importSelecting: boolean = false
  private uploadQueue: UploadQueueManager = new UploadQueueManager()
  @State @Watch('onContinuationSceneChanged') showPageTransition: boolean = false
  @State fileTransitionHeader: DirectoryHeaderState | null = null
  @State outgoingEntries: FileEntry[] = []
  @State @Watch('onContinuationSceneChanged') showSearch: boolean = false
  @State searchQuery: string = ''
  private searchDraft: string = ''
  private searchController: SearchController = new SearchController()
  @State searchScope: RemoteSearchScope = 'current'
  @State searchResults: FileEntry[] = []
  @State searchLoading: boolean = false
  @State searchHistory: string[] = []
  @State searchHistoryExpanded: boolean = false
  @State fileViewMode: FileViewMode = 'list'
  // Defaults are separate for ordinary, photo/video and audio directories.
  // Toolbar changes remain per-directory overrides for this app session only.
  @State defaultFileViewMode: FileViewMode = 'list'
  @State defaultPhotoViewMode: FileViewMode = 'grid'
  @State defaultAudioViewMode: FileViewMode = 'list'
  // This is derived from the metadata already loaded for the current
  // directory. It deliberately does not trigger a second directory scan.
  // 当前目录是不是「图片目录」（全部都是图片/视频才为真）——决定用哪套呈现方式
  @State currentDirectoryIsPhotoAlbum: boolean = false
  @State currentDirectoryIsAudioAlbum: boolean = false
  // 每个目录【本次运行期间】临时切过的视图模式（右下角按钮切的）。
  // 只存内存：进子目录再返回仍然保持，重启应用就回到设置里的默认值。
  private directoryViewModeOverrides: Record<string, FileViewMode> = {}
  @State fileSortKey: FileSortKey = 'time'
  @State fileSortAscending: boolean = false
  @State @Watch('onContinuationSceneChanged') directoryTimeline: DirectoryTimeline = new DirectoryTimeline()
  @State timelineFocusTime: number = 0
  @State @Watch('onContinuationSceneChanged') timelineIndexing: boolean = false
  @State @Watch('onContinuationSceneChanged') showFileSortMenu: boolean = false
  @State @Watch('onContinuationSceneChanged') showCreateFolderDialog: boolean = false
  @State newFolderText: string = ''
  @State bottomBarOffsetY: number = 0
  @State bottomBarOpacity: number = 1
  @StorageProp('statusBarHeightPx') statusBarHeightPx: number = 0
  @StorageProp('navigationBarHeightPx') navigationBarHeightPx: number = 0
  @StorageProp('isDarkTheme') isDarkTheme: boolean = false
  @StorageProp('abilityInBackground') @Watch('onAbilityBackgroundChanged')
  abilityInBackground: boolean = false
  @StorageProp('transferNavigationRequest') @Watch('onTransferNavigationRequested')
  transferNavigationRequest: number = 0
  @StorageProp('transferProtectionActive') transferProtectionActive: boolean = false
  @StorageProp('transferProtectionError') transferProtectionError: string = ''
  @StorageProp('transferNotificationBlocked') transferNotificationBlocked: boolean = false
  @StorageProp('transferProgressText') transferProgressText: string = ''
  private transferNavigationHandled: number = 0
  private repository: UgreenRemoteRepository = new UgreenRemoteRepository()
  private networkPolicy: NetworkPolicy = NetworkPolicy.shared()
  private downloadQueue: DownloadQueueManager = new DownloadQueueManager()
  private audioManager: AudioPlaybackManager = new AudioPlaybackManager()
  private videoPlaybackManager: VideoPlaybackManager = new VideoPlaybackManager()
  private videoBrightness: PlayerBrightness = new PlayerBrightness()
  private videoChromeTimer: number = -1
  private videoControlsTouchActive: boolean = false
  private videoVolumeManager: audio.AudioVolumeManager | null = null
  private videoVolumeMin: number = 0
  private videoVolumeMax: number = 15
  private videoGestureStartMs: number = 0
  private videoVolumeChanged = (event: audio.StreamVolumeEvent): void => {
    if (this.videoSystemVolume !== undefined) { this.videoSystemVolume = event.volume }
  }
  private videoGestures: PlayerGestures = new PlayerGestures({
    tap: () => this.handleVideoSingleTap(),
    togglePlay: () => { this.revealVideoChrome(); this.handleVideoDoubleTap() },
    seek: (value: number) => this.seekVideo(value),
    rate: (rate: number) => { this.setVideoPlaybackRate(rate, true) },
    brightness: (value: number) => this.setVideoGestureBrightness(value),
    volume: (value: number) => {
      this.videoSystemVolume = Math.round(this.videoVolumeMin + (this.videoVolumeMax - this.videoVolumeMin) * value / 100)
    },
    preview: (kind: string, value: number) => this.previewVideoGesture(kind, value),
    active: (active: boolean) => {
      this.videoGestureActive = active
      if (active) { this.clearVideoChromeTimer() } else { this.scheduleVideoChromeHide() }
    }
  })
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
  @State videoViewportWidthVp: number = 0
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
  private waterfallBitmapBytes: Record<string, number> = {}
  private waterfallBitmapLastAccessAt: Record<string, number> = {}
  private waterfallBitmapTotalBytes: number = 0
  // Viewer 位图空闲分片释放器
  private pendingViewerCleanupQueue: PendingViewerCleanupItem[] = []
  private pendingViewerCleanupEstimatedBytes: number = 0
  private viewerCleanupTimer: number = 0
  private viewerCleanupRunning: boolean = false
  private lastUserInteractionMonotonic: number = 0
  private fileContentTouchActive: boolean = false
  private imageRotationStore: ImageRotationStore = new ImageRotationStore()
  private fileListPersistedDisplayState: ImageDisplayState = new ImageDisplayState()
  private fileListRotationReady: boolean = false
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
  /**
   * Transparent margin kept around the long-press menu surface. It must stay 0:
   * the native menu paints its own stroke around the whole content box, so any
   * transparent ring here exposes that stroke as a second, outer frame next to
   * the surface's own edge. The anchor offset below tracks this value.
   */
  private actionMenuSafeMargin: number = 0
  private mainContentOriginX: number = 0
  private mainContentOriginY: number = 0
  private contextMenuOpenToken: number = 0
  private contextMenuOpening: boolean = false
  private contextMenuPreviewSource: image.PixelMap | string = ''
  private contextMenuPreviewOrientation: ImageRotateOrientation = ImageRotateOrientation.UP
  private contextMenuPreviewBitmap: ViewerBitmapRecord | null = null
  private contextMenuScrollMoved: boolean = false
  private contextMenuTouchX: number = 0
  private contextMenuTouchY: number = 0
  private contextMenuScrollRect: BottomBarTouchRect = new BottomBarTouchRect()
  private fileEntryDataSource: FileEntryDataSource = new FileEntryDataSource()
  private waterfallDataSource: FileEntryDataSource = new FileEntryDataSource()
  private viewerImageDataSource: FileEntryDataSource = new FileEntryDataSource()
  private transitionFileEntryDataSource: FileEntryDataSource = new FileEntryDataSource()
  private fileListScroller: Scroller = new Scroller()
  private fileGridOptions: GridLayoutOptions = { regularSize: [1, 1] }
  // R2 原型：网格 cell 子组件与 Index 之间的桥（在 aboutToAppear 里接线）
  private gridThumbBridge: GridThumbBridge = new GridThumbBridge()
  // R2 推广：瀑布流 cell 的桥
  private waterfallThumbBridge: WaterfallThumbBridge = new WaterfallThumbBridge()
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
  // ── R3.1 / RequestToken Fix ────────────────────────────────────────────
  // previewRequests[path] 存的是【请求 token】而不是 boolean：
  //   谁设置的 in-flight 标志，只有它仍是当前 owner 时才有权清除。
  //   0 / undefined = 没有在飞请求。
  // 这样同时解决两件事：
  //   1) 世代/token 失效后不会永久留下 true（旧实现只在 generation 仍匹配时才清，
  //      一旦失配就永久泄漏 → loadEntryPreview 被早退挡住 → 该条目永远占位）；
  //   2) 老请求结束时不会误清新请求的 in-flight 状态（否则会放进重复请求）。
  // 用 0 表示空闲而不是 delete：避免在 Record 上做 delete。
  private previewRequests: Record<string, number> = {}
  private previewRequestSequence: number = 0
  // R3.2：记录「这一格当前实际画的是哪个 preview」。
  // 语义 = desired preview identity（previewUri） vs rendered preview identity。
  //   desired == rendered        → 不动
  //   rendered 是 '' 或旧 key     → 单 Cell notify
  //   desired == '' 且无有效请求   → 发起加载
  // ⚠️ 只在 cell 真正 build 时写（resolveGridImageStateInto），**绝不在 notify 时乐观登记**
  //    —— 否则 notify 一旦失效就失去自愈能力。
  // ⚠️ 普通非响应式字段，写入不触发任何 @State 更新。
  // ⚠️ 不按 typeof source 记录：若 source 是 PixelMap/Resource 而错记成 ''，
  //    下一轮会把"已经画对的格子"再批量 notify 一次。
  private gridRenderedPreviewKey: Record<string, string> = {}
  // R2 推广（瀑布流）：同语义，独立一张表（两个视图各自验证，互不干扰）。
  private waterfallRenderedPreviewKey: Record<string, string> = {}
  // 🔬 仅用于 R3.1 验收观测（Q3 清理时删除）：被 token 去重挡下的重复请求次数。
  private previewDuplicateBlockedCount: number = 0
  private previewLocalPaths: Record<string, string> = {}
  private previewLocalSignatures: Record<string, string> = {}
  private previewQueue: PreviewLoadQueue = new PreviewLoadQueue(
    ThumbnailPolicy.LIST_MAX_CONCURRENT, ThumbnailPolicy.MAX_PENDING_TASKS)
  private imageTelemetry: ImagePipelineTelemetry = new ImagePipelineTelemetry()
  private returnPerfSession: ReturnPerfSession = new ReturnPerfSession()
  private entryPathGenerations: Record<string, number> = {}
  private viewerPrefetchCoordinator: ViewerPrefetchCoordinator | null = null

  private acquirePathGeneration(path: string): number {
    const nextGen = (this.entryPathGenerations[path] || 0) + 1
    this.entryPathGenerations[path] = nextGen
    return nextGen
  }

  private isPathGenerationValid(path: string, token: number): boolean {
    return this.entryPathGenerations[path] === token
  }

  private invalidatePath(path: string): void {
    this.entryPathGenerations[path] = (this.entryPathGenerations[path] || 0) + 1
  }
  private previewUriOrder: string[] = []
  // previewUri() 的结果缓存：key = 条目 path，value = `<signature>\u0000<uri>`。
  // 为什么需要：每个格子每次渲染会调 previewUri 2~3 次（fileImageSource /
  // fileImageSourceAvailable / fileImageSourceOrientation → fileListImageBaseOrientation），
  // 而它内部要过 NAPI fileUri.getUriFromPath。真机 Profiler 落盘数据显示
  // getUriFromPath 的调用次数 ≈ previewUri 的调用次数，说明原有的两级缓存
  // 在渲染路径上几乎不命中，于是每次渲染都白付一次 NAPI + 多层查表。
  // 这里缓存"最终结果"，命中即零 NAPI、零嵌套查；signature 变化自动失效。
  private previewUriResultCache: Map<string, string> = new Map<string, string>()
  private previewUriResultKeys: string[] = []
  private currentPageIndex: number = 1
  private currentPageHasMore: boolean = false
  private loadingNextPage: boolean = false
  private directoryIndexRequestToken: number = 0
  private indexedDirectoryKey: string = ''
  private photosPreindexHomePath: string = ''
  private timelineEntryIndexByDay: Record<string, number> = {}
  private timelineWaterfallIndexByDay: Record<string, number> = {}
  private timelineScrubActive: boolean = false
  private timelineScrubLastScrollAt: number = 0
  private timelineScrubPendingTime: number = 0
  private timelineScrubTimer: number = 0
  private timelineInteractionToken: number = 0
  private timelineFocusPinned: boolean = false
  private timelineIgnoreScrollStartUntil: number = 0
  // 时间轴默认收起（只露一小截日期），点一下展开、再点一下收起。
  @State timelineCollapsed: boolean = true
  private timelineVisibleFocusPendingTime: number = 0
  private timelineVisibleFocusTimer: number = 0
  private timelineLastJumpDay: number = 0
  private timelineLastJumpIndex: number = -1
  private timelineLastJumpPath: string = ''
  private timelineLastJumpMode: FileViewMode = 'list'
  private fileContentScrolling: boolean = false
  private pendingDirectoryIndexSnapshot: DirectoryIndexedSnapshot | null = null
  private indexedDirectoryContentSignature: string = ''
  private locallyDeletedEntryPaths: Record<string, boolean> = {}
  private pendingDeleteEntryPaths: Record<string, boolean> = {}
  private imageVisualStates: Record<string, ImageVisualState> = {}
  private imageVisualPruneTimer: number = 0
  private imageVisualNotifyTimer: number = 0
  private waterfallOriginalUris: Record<string, string> = {}
  private waterfallAspectRatios: Record<string, number> = {}
  private waterfallAspectSignatures: Record<string, string> = {}
  private waterfallVisiblePaths: Record<string, boolean> = {}
  private waterfallSourceNotifyTimer: number = 0
  private waterfallAspectNotifyTimer: number = 0
  private directoryCountRequests: Record<string, boolean> = {}
  private directoryCountTimers: Record<string, number> = {}
  private previewGeneration: number = 0
  private waterfallGeneration: number = 0
  private waterfallEntries: FileEntry[] = []
  private waterfallDownloadQueue: FileEntry[] = []
  private waterfallDecodeQueue: FileEntry[] = []
  private waterfallGeometryQueue: PreviewLoadQueue = new PreviewLoadQueue(2, 32)
  private waterfallLocalPaths: Record<string, string> = {}
  private waterfallLocalSignatures: Record<string, string> = {}
  private waterfallDownloadRequests: Record<string, boolean> = {}
  private waterfallActiveDownloadPaths: Record<string, boolean> = {}
  private waterfallActiveDecodePaths: Record<string, boolean> = {}
  private waterfallDecodedPaths: Record<string, boolean> = {}
  private waterfallActiveDownloads: number = 0
  private waterfallActiveDecodes: number = 0
  private waterfallAnchor: FileViewAnchor | null = null
  private waterfallAnchorRestoreToken: number = 0
  private fileVisibleStartIndex: number = 0
  // 滚动期间被推迟的「视觉状态刷新」标记（见 scheduleImageVisualNotify）
  private imageVisualNotifyDeferred: boolean = false
  // 滚动期间进入可见区、但当时没能发起加载的缩略图（见 flushPendingVisibleLoads）
  private pendingVisibleLoads: Map<string, FileEntry> = new Map<string, FileEntry>()
  private fileVisibleEndIndex: number = 0
  private waterfallVisibleStartIndex: number = 0
  private waterfallVisibleEndIndex: number = 0
  private fileListRotationGeneration: number = 0
  private navigationRequestId: number = 0
  private targetLocateEntryPath: string = ''
  private locateProgrammaticScrolling: boolean = false
  private targetLocateResolve: (() => void) | null = null
  private locateScrollStartTime: number = 0
  private locateTargetIndex: number = -1
  private locateBuildLazyItemCount: number = 0
  private locateMinBuildIndex: number = -1
  private locateMaxBuildIndex: number = -1
  private locateImagePipelineCount: number = 0
  private isNavigating: boolean = false
  private pageTransitionToken: number = 0
  private pageTransitionTimer: number = 0
  private pageTransitionFinishing: boolean = false
  private resetPreviewAfterPageTransition: boolean = false
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
  // Latest raw touch X, refreshed on every Move. The dismiss pull is anchored
  // HERE rather than at touch-down: the recognizer only fires after 5vp of
  // vertical travel, so anchoring at touch-down would make the image jump
  // sideways by however far the finger had already drifted horizontally
  // before the pull was recognised.
  private imageTouchLastX: number = 0
  private imageDismissAnchorX: number = 0
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
  private viewPreferences: preferences.Preferences | null = null
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
    NasConnection.shared().setPhoneOffline(state === 'offline')
    if (state === 'unmetered' && !this.offlineCacheMode && NasConnection.shared().canRequest()) {
      this.videoTransferManager.resumeAwaitingNas(true)
    }
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
  @State private nasState: NasConnectionState = 'unknown'
  @State @Watch('onContinuationSceneChanged') private offlineCacheMode: boolean = false
  private offlineProfile: OfflineAccountProfile | null = null
  private personalRootEntriesType: number = 4
  private offlineProfileTimer: number = 0
  private nasRecoveryTimer: number = 0
  private nasRecoveryPending: boolean = false
  private nasSessionRecovery: Promise<void> | null = null
  private nasStateListener = (state: NasConnectionState): void => {
    const previous = this.nasState
    this.nasState = state
    if (state === 'unavailable' || state === 'connecting') {
      this.stopQueuedViewerAutoLoads()
      this.videoTransferManager.handleNasUnavailable()
    }
    if (state === 'online' && (previous === 'unavailable' || previous === 'connecting')) {
      this.nasRecoveryPending = true
      this.scheduleNasRecovery()
    }
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
  private gestureSharePageVisible: boolean = true
  private gestureSharePreparing: boolean = false
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
  private timelineRailMaterial: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    colorInvert: true,
    applyShadow: false,
    interactive: true,
    lightEffect: { color: '#66FFFFFF' }
  })
  aboutToAppear(): void {
    ContinuationManager.shared().attach(this.continuationPage)
    this.completeStartupAuthorization(false)
  }

  private async showTrackedDialog(options: promptAction.ShowDialogOptions): Promise<promptAction.ShowDialogSuccessResponse> {
    this.continuationDialogCount++
    try {
      return await this.getUIContext().getPromptAction().showDialog(options)
    } finally {
      this.continuationDialogCount = Math.max(0, this.continuationDialogCount - 1)
    }
  }

  private onContinuationSceneChanged(): void {
    ContinuationManager.shared().refresh()
    this.onContinuationMessage()
  }

  private onContinuationMessage(): void {
    if (this.startupAuthorized && !this.startupRestoring && this.continuationMessage !== '') {
      const message = this.continuationMessage
      AppStorage.setOrCreate('continuationMessage', '')
      this.showImmersiveToast(message)
    }
  }

  private continuationOperationIdle(): boolean {
    return this.startupAuthorized && !this.startupRestoring && this.continuationDialogCount === 0 &&
      !this.isBusy && !this.isNavigating &&
      !this.selectionMode && !this.showSearch && this.searchSession === null &&
      !this.showPageTransition && !this.contextMenuVisible && this.contextMenuEntry === null &&
      !this.showDestinationPicker && !this.destinationOperationRunning && !this.destinationFolderDialog &&
      !this.showRenameDialog && !this.showCreateFolderDialog && !this.showAlbumPicker &&
      !this.showAlbumUpload && !this.showAlbumDetails && !this.importSelecting && !this.importExpanded &&
      !this.showFileSortMenu && !this.showSelectionMoreMenu && !this.showAudioPlayer &&
      !this.viewerClosePending && !this.viewerClosing && !this.viewerReturnOverlayVisible &&
      !this.viewerEntryTransitionActive && !this.viewerTransitionActive && !this.viewerFallbackEntryActive &&
      !this.imageDismissDragging && !this.showImageDetails && !this.showImageMoreMenu &&
      !this.videoOverlayClosing && !this.videoEntryTransitionActive && !this.videoCasting &&
      !this.videoPipActive && !this.videoPipBackgrounded && !this.videoPipCreating && !this.videoCastPreparing &&
      !this.videoSeekDragging && !this.videoGestureActive && !this.videoControlPending && !this.videoOrientationChanging &&
      !this.videoRatePending && !this.videoRatePanel &&
      this.continuationPendingDeletes.size === 0
  }

  private continuationAvailable(): boolean {
    if (!this.continuationOperationIdle() || this.continuationSending || this.continuationPending ||
      this.screen !== 'files' || this.offlineCacheMode || this.repository.sessionIdentity() === '' ||
      this.entries.length > ContinuationPolicy.MAX_ENTRIES || this.fileContentTouchActive ||
      this.fileContentScrolling || this.loadingNextPage || this.timelineIndexing ||
      (this.currentPath !== '' && (this.currentPageHasMore || !this.directoryTimeline.complete ||
        this.indexedDirectoryKey !== this.currentRootType.toString() + ':' + this.currentPath))) { return false }
    if (this.showImageViewer) {
      const entry = this.committedViewerEntry()
      return this.viewerInteractionUnlocked && entry !== null &&
        ContinuationPolicy.directChild(this.currentPath, entry.path) && this.imageScale === 1
    }
    if (this.showVideoPlayer) {
      return this.videoPrepared && !this.videoSeekPending && this.videoEntry !== null &&
        ContinuationPolicy.directChild(this.currentPath, this.videoEntry.path)
    }
    return true
  }

  private continuationCanReceive(): boolean {
    return this.continuationOperationIdle() && !this.continuationSending &&
      !this.fileContentTouchActive && !this.fileContentScrolling &&
      !this.showImageViewer && !this.showVideoPlayer &&
      (this.screen === 'files' || this.screen === 'login' || this.screen === 'otp')
  }

  private captureContinuation(): ContinuationSnapshot {
    const snapshot = new ContinuationSnapshot()
    const state = snapshot.state
    const identity = this.repository.sessionIdentity()
    state.nasId = this.linkId.trim().toLowerCase()
    state.userId = identity.substring(identity.lastIndexOf('|') + 1)
    state.rootKind = this.rootKind; state.path = this.currentPath; state.rootType = this.currentRootType
    state.view = this.fileViewMode; state.sort = this.fileSortKey; state.ascending = this.fileSortAscending
    const items = this.fileViewMode === 'waterfall' ? this.waterfallEntries : this.entries
    let first = this.fileViewMode === 'waterfall' ? this.waterfallVisibleStartIndex : this.fileVisibleStartIndex
    if (this.fileViewMode === 'list') { first-- }
    const firstEntry = items[Math.max(0, Math.min(first, items.length - 1))]
    state.anchor = firstEntry === undefined ? '' : firstEntry.path
    if (this.showImageViewer) {
      state.scene = 'image'; state.target = this.committedViewerEntry()?.path ?? ''
      state.anchor = state.target
    } else if (this.showVideoPlayer) {
      state.scene = 'video'; state.target = this.videoEntry?.path ?? ''
      state.anchor = state.target; state.positionMs = Math.max(0, Math.floor(this.videoCurrentMs))
      state.playing = this.videoPlaying
    }
    snapshot.entries = this.entries.slice()
    return snapshot
  }

  private async restoreContinuation(snapshot: ContinuationSnapshot, valid: () => boolean): Promise<void> {
    const state = snapshot.state
    ContinuationPolicy.validate(state)
    if (!ContinuationPolicy.sameAccount(state, this.linkId, this.repository.sessionIdentity()) ||
      this.screen === 'login' || this.screen === 'otp' || this.offlineCacheMode) {
      throw new ContinuationAccountRequired('请先登录相同 NAS 和账号')
    }
    const identity = this.repository.sessionIdentity()
    const request = this.navigationRequestId
    const unchanged = (): boolean => valid() && identity === this.repository.sessionIdentity() &&
      request === this.navigationRequestId && this.continuationCanReceive()
    // The target's authenticated network request is authoritative for permissions.
    // Transferred metadata must never supply an endpoint or authorize a file operation.
    const roots = await this.repository.getRootWithCache(true)
    const visibleRoots = state.rootKind === 'personal' ? roots.personal : roots.shared
    const ancestors = ContinuationPolicy.ancestors(state.path, visibleRoots)
    if (state.path !== '') { await this.repository.listPage(state.path, 3, 1, true) }
    if (!unchanged()) { throw new Error('接续期间页面或账号已经变化') }
    const query = new DirectoryQuery()
    query.path = state.path; query.rootType = state.path === ''
      ? (state.rootKind === 'personal' ? roots.personalRootType : 3) : 3
    query.sortKey = state.sort; query.ascending = state.ascending
    const entries = state.path === '' ? visibleRoots.slice() : snapshot.entries
    const target = entries.find((entry: FileEntry): boolean => entry.path === state.target)
    if (state.scene !== 'directory' && (target === undefined || target.isDirectory ||
      (state.scene === 'image' ? !this.isImage(target) : !this.isVideo(target)))) {
      throw new Error('接续文件类型无效')
    }
    const ordered = DirectoryTimelinePolicy.query(entries, query)
    const timeline = DirectoryTimelinePolicy.build(entries, true)
    if (!unchanged()) { throw new Error('接续已取消') }
    // All fallible network/identity work has finished. Commit one complete page
    // under the opaque cover; never expose a partially restored home header.
    this.navigationRequestId++
    this.directoryIndexRequestToken++
    this.pendingDirectoryIndexSnapshot = null
    this.discardSearchSession()
    this.continuationAncestorAnchors.clear()
    ancestors.forEach((parent: string, index: number): void => {
      this.continuationAncestorAnchors.set(parent, index + 1 < ancestors.length ? ancestors[index + 1] : state.path)
    })
    this.personalRoots = roots.personal; this.sharedRoots = roots.shared
    this.personalRootEntriesType = roots.personalRootType
    this.navigationStack = ancestors
    this.navigationEntryStack = []
    this.navigationRootTypeStack = ancestors.map((path: string): number => path === ''
      ? (state.rootKind === 'personal' ? roots.personalRootType : 3) : 3)
    this.navigationViewStateStack = ancestors.map((): DirectoryViewState => {
      return { mode: this.defaultFileViewMode, offset: null, anchor: null }
    })
    this.navigationPageIndexStack = ancestors.map((): number => 1)
    this.navigationPageHasMoreStack = ancestors.map((): boolean => false)
    this.rootKind = state.rootKind
    this.selectedBottomTab = state.rootKind === 'personal' ? 'home' : 'shared'
    this.screen = 'files'; this.currentPath = state.path; this.currentRootType = query.rootType
    this.fileSortKey = state.sort; this.fileSortAscending = state.ascending
    this.indexedDirectoryKey = query.rootType.toString() + ':' + state.path
    this.indexedDirectoryContentSignature = DirectoryTimelinePolicy.contentSignature(entries)
    this.directoryTimeline = timeline; this.timelineIndexing = false
    this.setCurrentPageState(Math.max(1, Math.ceil(entries.length / 200)), false)
    this.replaceEntries(ordered, false, true)
    this.fileViewMode = state.path === '' ? 'list' :
      (state.view === 'waterfall' && !this.currentDirectoryIsPhotoAlbum ? 'grid' : state.view)
    this.updateTopTitle(this.fileTitle(state.path))
    this.topTitleOpacity = 1
    this.updateBottomBarVisibility(false)
    this.resetTimelineInteraction()
    this.resetPreviewState(false)
    await this.nextRenderFrame()
    await this.nextRenderFrame()
    if (!valid()) { return }
    const anchor = this.entries.find((entry: FileEntry): boolean => entry.path === state.anchor)
    if (anchor !== undefined) { this.scrollToLocatedEntry(anchor) }
    await this.nextRenderFrame()
    if (!valid()) { return }
    if (state.scene === 'image' && target !== undefined) {
      await this.openImageViewer(target, undefined, true, valid)
    } else if (state.scene === 'video' && target !== undefined) {
      await this.openVideoPlayer(target, state.positionMs, state.playing, valid)
    }
    await this.nextRenderFrame()
  }

  private async completeStartupAuthorization(retry: boolean): Promise<void> {
    const token = ++this.startupAuthorizationToken
    this.startupAuthorizing = true
    this.startupAuthorizationMessage = ''
    const gate = StartupAuthorization.shared()
    const allowed = retry ? await gate.authorize(getContext(this) as common.UIAbilityContext) : await gate.waitForInitial()
    if (token !== this.startupAuthorizationToken) { return }
    this.startupAuthorizing = false
    if (!allowed) { this.startupAuthorizationMessage = gate.message(); return }
    this.startupAuthorized = true
    if (!this.applicationInitialized) {
      this.applicationInitialized = true
      this.initializeApplication()
      this.onPageShow()
    }
  }

  private exitBeforeAuthorization(): void {
    this.startupAuthorizationToken++
    (getContext(this) as common.UIAbilityContext).terminateSelf().catch(() => {})
  }

  private initializeApplication(): void {
    try {
      this.appVersionName = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName
    } catch (_) {
      hilog.warn(0x0000, 'LinkFiles', 'Unable to read app version')
    }
    // Ask the motor which presets it has before the first cue needs one, so
    // the very first long press does not fall back unnecessarily.
    HapticFeedback.prepare()
    this.statusText = ''
    this.configureImageAnalyzer()
    this.nasState = NasConnection.shared().current()
    NasConnection.shared().onChange(this.nasStateListener)
    NasConnection.shared().setForeground(!this.abilityInBackground)
    this.ensureCacheState()
    this.ensureNetworkState()
    this.ensureDownloadState()
    this.ensurePlaybackState()
    this.ensureViewState()
    this.ensureVideoState()
    this.loginStatePromise = this.loadLoginPreferences()
    this.searchStatePromise = this.loadSearchPreferences()
    this.ensureImageRotationState()
    this.fileEntryDataSource.onItemRequested = (index: number, entry: FileEntry): void => {
      this.noteLocateItemBuild(entry, index)
    }
    // ── R2 原型接线 ────────────────────────────────────────────────────────
    // 1) datasource 就地自增 previewRevision（不换实例，否则 @ObjectLink 断链）
    this.fileEntryDataSource.bumpInPlace = EXPERIMENT_R2_THUMB_CELL
    // 2) 桥上的方法只在子组件 build 期间被调用，绝不能读 Index 的 @State
    this.gridThumbBridge.resolveInto = (entry: FileEntry, state: GridImageState): GridImageState =>
      this.resolveGridImageStateInto(entry, state)
    this.gridThumbBridge.icon = (entry: FileEntry): Resource => this.fileIcon(entry)
    this.gridThumbBridge.onComplete = (entry: FileEntry, index: number,
      event?: ViewerImageCompleteEvent): void => {
      this.imageTelemetry.recordPipelineComplete(entry.path, 'grid')
      this.recordThumbnailComplete(entry, this.previewUri(entry), index, 'grid', event)
    }
    this.gridThumbBridge.onError = (entry: FileEntry): void => {
      this.imageTelemetry.recordPipelineError(entry.path, 'grid')
    }
    // 🔬 OpenAnimProbe 时间点 3 的落点（只读）
    this.gridThumbBridge.probeAppear = (entry: FileEntry, index: number): void => {
      this.openAnimProbe('cellImageAppear', 'path=' + entry.path +
        ' index=' + index.toString() +
        ' tidNow=' + this.fileImageTransitionId(entry, 'grid'))
    }
    // ── R2 推广：瀑布流接线 ────────────────────────────────────────────────
    // 就地自增同样必须开，否则 waterfallDataSource.notifyItemChanged 仍走 clone
    // 路径 → 换实例 → @ObjectLink 断链。
    this.waterfallDataSource.bumpInPlace = EXPERIMENT_R2_WATERFALL_CELL
    this.waterfallThumbBridge.resolveInto = (entry: FileEntry,
      state: WaterfallImageState): WaterfallImageState =>
      this.resolveWaterfallImageStateInto(entry, state)
    this.waterfallThumbBridge.onComplete = (entry: FileEntry, index: number,
      event?: ViewerImageCompleteEvent): void => {
      this.recordThumbnailComplete(entry, this.thumbnailSurfaceUri(entry, 'waterfall'), index,
        'waterfall', event)
      this.completeWaterfallDecode(entry)
    }
    this.waterfallThumbBridge.onError = (entry: FileEntry): void => {
      this.failWaterfallDecode(entry)
    }
    // 不再无条件注册：由 syncGestureShareRegistration 按"当前有没有可分享内容"决定。
    this.syncGestureShareRegistration()
    this.setupLocalInputMonitor()
    this.viewerPrefetchCoordinator = new ViewerPrefetchCoordinator({
      isViewerActive: (): boolean => this.showImageViewer && !this.viewerClosePending,
      isInteractionBusy: (): boolean => this.viewerVisualCommitBlocked('') || this.imageScale > 1.001 || this.imageTouchActive,
      shouldAutoPrefetch: (): boolean => this.shouldAutoLoadViewerOriginal(),
      isFileCached: (entry: FileEntry): boolean => {
        const cacheKey = this.originalCacheKey(entry)
        return CacheManager.findExisting(this.cacheDirectory, entry.name, cacheKey).length > 0
      },
      downloadOriginalFile: async (entry: FileEntry, shouldContinue: () => boolean): Promise<string> => {
        return await this.ensureCachedFile(entry, undefined, shouldContinue)
      },
      onOriginalFileReady: async (entry: FileEntry, _localPath: string): Promise<void> => {
        await this.primeViewerOriginalFrame(entry)
        this.ensureViewerImageFrame(entry, false)
      }
    })
  }

  aboutToDisappear(): void {
    ContinuationManager.shared().detach(this.continuationPage)
    this.startupAuthorizationToken++
    this.albumUpload.setForeground(false)
    this.gestureSharePageVisible = false
    NasConnection.shared().setForeground(false)
    NasConnection.shared().offChange(this.nasStateListener)
    if (this.nasRecoveryTimer !== 0) { clearTimeout(this.nasRecoveryTimer); this.nasRecoveryTimer = 0 }
    this.closeActionMenu()
    this.finishActionMenuDismiss()
    this.endDragSelection()
    this.viewerReturnOverlayToken += 1
    if (this.viewerReturnOverlayMountResolve !== null) {
      this.viewerReturnOverlayMountResolve()
      this.viewerReturnOverlayMountResolve = null
    }
    this.viewerReturnOverlayVisible = false
    this.viewerReturnHiddenPath = ''
    this.viewerReturnSnapshot = new ViewerReturnSnapshot()
    this.viewerPrefetchCoordinator?.onViewerClosed()
    this.cancelViewerCleanupTimer()
    this.drainPendingViewerCleanupOnDisappear()
    this.closeAudioPlayer(true)
    this.closeVideoPlayer()
    this.releaseImageAnalyzer()
    this.disableGestureShare()
    this.releaseLocalInputMonitor()
  }

  private formatGuardSnapshot(): string {
    return 'showViewer=' + this.showImageViewer.toString() +
      ' vet=' + this.viewerEntryTransitionActive.toString() +
      ' fallback=' + this.viewerFallbackEntryActive.toString() +
      ' closePending=' + this.viewerClosePending.toString() +
      ' isBusy=' + this.isBusy.toString() +
      ' unlocked=' + this.viewerInteractionUnlocked.toString() +
      ' ownsParent=' + this.viewerOwnsParentInteraction().toString() +
      ' vbfc=' + this.viewerBlocksFileContent.toString()
  }

  private getMonotonicNow(): number {
    try {
      return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP)
    } catch (_err) {
      return Date.now()
    }
  }

  private setupLocalInputMonitor(): void {
    try {
      const uiContext = this.getUIContext()
      if (typeof uiContext.addLocalInputEventMonitor === 'function') {
        this.localInputMonitor = uiContext.addLocalInputEventMonitor(
          InputEventSubTypeMask.TOUCH_DOWN,
          (wrapper: RawInputEventWrapper): InputEventInterceptResult => {
            if (wrapper.isTouchEvent()) {
              this.noteUserInteraction()
            }
            if (this.closeSessionActive && !this.sessionPreDispatchDownLogged && wrapper.isTouchEvent()) {
              const touch = wrapper.asTouchEvent()
              if (touch !== null && touch.touches.length > 0) {
                this.sessionPreDispatchDownLogged = true
                const first = touch.touches[0]
                this.sessionTrackedPointerId = first.id
                const dt = this.getMonotonicNow() - this.closeAnimFinishMonotonic
                console.info('[TouchChain] #' + this.closeSessionId.toString() +
                  ' PreDispatchDown +' + dt.toString() + 'ms ptr=' + first.id.toString() +
                  ' win=(' + Math.round(first.windowX).toString() + ',' + Math.round(first.windowY).toString() + ')' +
                  ' loc=(' + Math.round(first.x).toString() + ',' + Math.round(first.y).toString() + ')' +
                  ' | ' + this.formatGuardSnapshot())
              }
            }
            const result: InputEventInterceptResult = { action: InputEventInterceptAction.CONTINUE }
            return result
          }
        )
      }
    } catch (_err) {
      console.warn('[TouchChain] addLocalInputEventMonitor error')
    }
  }

  private releaseLocalInputMonitor(): void {
    if (this.localInputMonitor !== null) {
      try {
        this.getUIContext().removeLocalInputEventMonitor(this.localInputMonitor)
      } catch (_err) {
      }
      this.localInputMonitor = null
    }
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
      // ⚠️ 必须知道"用户是否正在识别文字"：此时文字选择层浮在图片上方，
      // 拖动选择光标的手势会被图片的下拉关闭接走，导致图片跟着乱动。
      // 官方提供两个回调正好用来判断 —— 注册后把状态记进 imageAnalyzerActive。
      if (this.imageAnalyzerSupported && !this.imageAnalyzerListenerBound) {
        this.imageAnalyzerListenerBound = true
        try {
          this.imageAnalyzerController.on('aiButtonStatusChange',
            (status: visionImageAnalyzer.AIButtonStatus): void => {
              this.imageAnalyzerActive =
                status === visionImageAnalyzer.AIButtonStatus.SELECTED
              console.info('[UgreenImageAnalyzer] aiButtonStatus=' + status.toString())
            })
          this.imageAnalyzerController.on('imageAnalyzerVisibilityChange',
            (visibility: visionImageAnalyzer.ImageAnalyzerVisibility): void => {
              if (visibility === visionImageAnalyzer.ImageAnalyzerVisibility.HIDDEN) {
                this.imageAnalyzerActive = false
              }
              console.info('[UgreenImageAnalyzer] visibility=' + visibility.toString())
            })
        } catch (error) {
          console.warn('[UgreenImageAnalyzer] bind listener failed: ' + JSON.stringify(error))
        }
      }
      console.info('[UgreenImageAnalyzer] supportTypes=' + JSON.stringify(enabledTypes))
    } catch (error) {
      this.imageAnalyzerTypes = []
      this.imageAnalyzerSupported = false
      console.warn('[UgreenImageAnalyzer] capability check failed: ' + JSON.stringify(error))
    }
  }

  private releaseImageAnalyzer(): void {
    try {
      if (this.imageAnalyzerListenerBound) {
        this.imageAnalyzerListenerBound = false
        this.imageAnalyzerActive = false
        try {
          this.imageAnalyzerController.off('aiButtonStatusChange')
          this.imageAnalyzerController.off('imageAnalyzerVisibilityChange')
        } catch (error) {
          console.warn('[UgreenImageAnalyzer] unbind failed: ' + JSON.stringify(error))
        }
      }
      this.imageAnalyzerController.setImageAnalyzerVisibility(
        visionImageAnalyzer.ImageAnalyzerVisibility.HIDDEN)
    } catch (error) {
      console.warn('[UgreenImageAnalyzer] hide failed: ' + JSON.stringify(error))
    }
  }

  onPageHide(): void {
    if (!this.startupAuthorized) { return }
    this.albumUpload.setForeground(false)
    this.gestureSharePageVisible = false
    NasConnection.shared().setForeground(false)
    this.disableGestureShare()
    this.endDragSelection()
    this.handlePlaybackBackgroundState(true)
    this.updateVideoMediaSession(true)
  }

  onPageShow(): void {
    if (!this.startupAuthorized) { return }
    this.albumUpload.setForeground(!this.abilityInBackground)
    this.gestureSharePageVisible = true
    NasConnection.shared().setForeground(!this.abilityInBackground)
    this.scheduleNasRecovery()
    this.syncGestureShareRegistration()
    this.handlePlaybackBackgroundState(false)
    this.scheduleVideoPipRestore()
    if (this.showVideoPlayer) {
      // Refresh the system card when the page is visible again without issuing
      // a duplicate play command.
      this.updateVideoMediaSession(true)
    }
  }

  onAbilityBackgroundChanged(): void {
    if (!this.startupAuthorized) { return }
    this.albumUpload.setForeground(this.gestureSharePageVisible && !this.abilityInBackground)
    NasConnection.shared().setForeground(this.gestureSharePageVisible && !this.abilityInBackground)
    if (!this.abilityInBackground) { this.scheduleNasRecovery() }
    this.syncGestureShareRegistration()
    this.handlePlaybackBackgroundState(this.abilityInBackground)
    if (!this.abilityInBackground) {
      this.scheduleVideoPipRestore()
    }
  }

  onTransferNavigationRequested(): void {
    if (!this.startupAuthorized) { return }
    if (this.transferNavigationRequest <= this.transferNavigationHandled ||
      this.screen === 'login' || this.screen === 'otp') { return }
    if (this.continuationPending || this.continuationSending) { ContinuationManager.shared().cancel() }
    if (this.isBusy && !this.isNavigating && !this.showPageTransition) { return }
    this.transferNavigationHandled = this.transferNavigationRequest
    if (this.showVideoPlayer) { this.closeVideoPlayer() }
    if (this.showImageViewer) { this.closeImageViewer() }
    this.openDownloads()
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
      this.observeVideoVolume()
      this.revealVideoChrome()
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
      if (this.showVideoPlayer && !this.videoPipBackgrounded) {
        this.observeVideoVolume()
        this.revealVideoChrome()
      }
      return
    }

    this.suspendVideoInteractions()
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
      const token = this.audioOpenToken
      this.audioManager.pause().then((): void => {
        if (token === this.audioOpenToken && this.playbackBackgroundActive) {
          this.audioPlaying = false
          this.updateAudioSession(true)
        }
      }).catch((error: Object): void => {
        console.warn('[UgreenAudio] background pause failed: ' + JSON.stringify(error))
      })
    }
  }

  /**
   * Register the official HarmonyOS one-grab-one-release sender callback.
   * Only the visible foreground page with shareable content owns a listener.
   * HarmonyOS owns the gesture affordance and transfer animation; the app
   * supplies only a local SharedData payload.
   */
  private enableGestureShare(): void {
    if (this.gestureShareRegistered ||
      !canIUse('SystemCapability.Collaboration.HarmonyShare')) {
      return
    }
    try {
      // Use the documented page listener. getLastWindow() can return a native
      // context-menu child window that is already dismissing, leaving the
      // listener attached to a window that immediately disappears.
      harmonyShare.on('gesturesShare', this.gestureShareCallback)
      this.gestureShareRegistered = true
      console.info('[UgreenShare] gestures-listener registered scene=' +
        (this.showImageViewer ? 'viewer' : 'selection'))
    } catch (error) {
      console.warn('[UgreenShare] register gesturesShare failed: ' + JSON.stringify(error))
    }
  }

  private disableGestureShare(): void {
    if (!this.gestureShareRegistered) {
      return
    }
    try {
      harmonyShare.off('gesturesShare', this.gestureShareCallback)
      console.info('[UgreenShare] gestures-listener unregistered')
    } catch (error) {
      console.warn('[UgreenShare] unregister gesturesShare failed: ' + JSON.stringify(error))
    }
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

  /**
   * 当前界面到底有没有可分享的内容（只读状态 + 过滤数组，没有 I/O，可以高频调）。
   * 隔空传送的注册必须跟着它走：无条件注册会让系统把这个手势一直派给本应用，
   * 于是"没有内容的界面"上截屏手势也被吃掉、还会弹"无可分享内容"。
   */
  private hasGestureShareContent(): boolean {
    return this.gestureShareCandidates().some((entry: FileEntry): boolean => !entry.isDirectory)
  }

  private onGestureShareStateChanged(): void {
    this.onContinuationSceneChanged()
    this.syncGestureShareRegistration()
  }

  /** 有内容才注册、没内容就注销（幂等，可重复调用）。 */
  /** 时间轴展开/收起（唯一的切换入口：由轴条的点击回调触发）。 */
  private toggleTimelineCollapsed(): void {
    this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
      this.timelineCollapsed = !this.timelineCollapsed
    })
  }

  private syncGestureShareRegistration(): void {
    if (this.gestureSharePageVisible && !this.abilityInBackground && this.hasGestureShareContent()) {
      this.enableGestureShare()
    } else {
      this.disableGestureShare()
    }
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
      if (cachedPath.length > 0) {
        allowed.push(entry)
        continue
      }
      if (this.networkClass === 'offline' || this.offlineCacheMode || !NasConnection.shared().canRequest()) {
        skippedCount += 1
        continue
      }
      if (this.networkClass === 'unmetered') { allowed.push(entry); continue }
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

  private async cacheGestureEntries(entries: FileEntry[],
    pinnedPaths: string[]): Promise<GestureTransferCacheResult> {
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
            // A later download in the same selection must not evict an
            // earlier record before HarmonyShare has consumed its URI.
            if (pinnedPaths.indexOf(localPath) < 0) {
              StorageBudget.pin(localPath)
              pinnedPaths.push(localPath)
            }
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
      return typeof localPaths[entry.path] === 'string' && CacheManager.exists(localPaths[entry.path])
    })
    return { entries: cachedEntries, localPaths: localPaths, failedCount: failedCount }
  }

  private async prepareGestureShare(candidates: FileEntry[],
    pinnedPaths: string[]): Promise<GestureTransferPreparedData> {
    const selection = await this.filterGestureTransferEntries(candidates)
    // SharedData supports at most 500 records.
    const transferEntries = selection.entries.slice(0, 500)
    for (const entry of transferEntries) {
      if (!this.isVideo(entry)) {
        // Pin even an as-yet missing destination before awaiting downloads:
        // DownloadManager releases its own pin as it returns, and another
        // worker may otherwise evict the file before this caller resumes.
        const path = CacheManager.cachePath(this.cacheDirectory, entry.name, this.originalCacheKey(entry))
        if (pinnedPaths.indexOf(path) < 0) {
          StorageBudget.pin(path)
          pinnedPaths.push(path)
        }
      }
    }
    const cached = await this.cacheGestureEntries(transferEntries, pinnedPaths)
    return { entries: cached.entries, localPaths: cached.localPaths,
      failedCount: cached.failedCount,
      skippedCount: selection.skippedCount + Math.max(0, selection.entries.length - 500) }
  }

  private canShowGestureShareFeedback(candidates: FileEntry[]): boolean {
    if (!this.gestureSharePageVisible || this.abilityInBackground || this.isBusy) {
      return false
    }
    const current = this.gestureShareCandidates()
    return current.length === candidates.length && current.every(
      (entry: FileEntry, index: number): boolean => entry.path === candidates[index].path)
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
    const startedAt = this.getMonotonicNow()
    const candidates = this.gestureShareCandidates()
    console.info('[UgreenShare] gesture received scene=' +
      (this.showImageViewer ? 'viewer' : 'selection') + ' count=' + candidates.length.toString())
    if (this.gestureSharePreparing || this.isBusy) {
      this.showImmersiveToast(this.gestureSharePreparing
        ? '原文件正在准备，请完成后再次抓取' : '正在处理中，请稍后重试')
      await this.rejectGestureShare(target, harmonyShare.SharableErrorCode.DOWNLOAD_ERROR)
      return
    }
    if (!this.gestureSharePageVisible || this.abilityInBackground ||
      !candidates.some((entry: FileEntry): boolean => !entry.isDirectory)) {
      await this.rejectGestureShare(target, harmonyShare.SharableErrorCode.NO_CONTENT_ERROR)
      return
    }
    // Claim before the first await. This operation owns its own flag, never
    // isBusy: viewer transitions and unrelated file actions own that flag.
    this.gestureSharePreparing = true
    const pinnedPaths: string[] = []
    let preparationTimer = -1
    let shareRequested = false
    let targetRejected = false
    let stage = 'prepare'
    try {
      this.errorText = ''
      this.statusText = '正在准备隔空传送…'
      const preparation = this.prepareGestureShare(candidates.map(
        (entry: FileEntry): FileEntry => entry.clone()), pinnedPaths)
      const deadline = new Promise<GestureTransferPreparedData | null>((resolve): void => {
        preparationTimer = setTimeout((): void => resolve(null), GESTURE_SHARE_PREPARATION_MS)
      })
      const cached = await Promise.race([preparation, deadline])
      clearTimeout(preparationTimer)
      preparationTimer = -1
      if (cached === null || this.getMonotonicNow() - startedAt >= GESTURE_SHARE_PREPARATION_MS) {
        targetRejected = true
        await this.rejectGestureShare(target, harmonyShare.SharableErrorCode.DOWNLOAD_ERROR)
        console.info('[UgreenShare] preparation exceeded app wait elapsedMs=' +
          (this.getMonotonicNow() - startedAt).toString())
        if (this.canShowGestureShareFeedback(candidates)) {
          this.showImmersiveToast('原文件正在准备，完成后请再次抓取')
        }
        // Continue only the user's explicit preparation. Never send using the
        // expired target and never prefetch originals on selection changes.
        const completed = cached === null ? await preparation : cached
        console.info('[UgreenShare] retry-ready count=' + completed.entries.length.toString() +
          ' failed=' + completed.failedCount.toString() + ' elapsedMs=' +
          (this.getMonotonicNow() - startedAt).toString())
        if (this.canShowGestureShareFeedback(candidates)) {
          this.showImmersiveToast(completed.entries.length > 0
            ? '已准备 ' + completed.entries.length.toString() + ' 个原文件，请再次抓取'
            : '原文件准备失败，请检查网络或缓存空间')
        }
        return
      }
      if (cached.entries.length === 0) {
        targetRejected = true
        await this.rejectGestureShare(target, cached.failedCount > 0
          ? harmonyShare.SharableErrorCode.DOWNLOAD_ERROR : harmonyShare.SharableErrorCode.NO_CONTENT_ERROR)
        if (this.canShowGestureShareFeedback(candidates)) {
          this.showImmersiveToast(this.offlineCacheMode || !NasConnection.shared().canRequest()
            ? 'NAS 暂时无法连接，此文件尚未缓存，请恢复连接后传送'
            : (cached.failedCount > 0 ? '原文件准备失败，请检查网络或缓存空间' : '当前没有可传送的文件，请检查网络设置'))
        }
        return
      }

      stage = 'submit'
      const sharedData = new systemShare.SharedData(this.shareRecord(
        cached.entries[0], cached.localPaths[cached.entries[0].path]))
      for (let index = 1; index < cached.entries.length; index += 1) {
        const entry = cached.entries[index]
        sharedData.addRecord(this.shareRecord(entry, cached.localPaths[entry.path]))
      }
      console.info('[UgreenShare] submit count=' + cached.entries.length.toString() +
        ' elapsedMs=' + (this.getMonotonicNow() - startedAt).toString())
      shareRequested = true
      await target.share(sharedData)
      console.info('[UgreenShare] share completed elapsedMs=' +
        (this.getMonotonicNow() - startedAt).toString())
      if ((cached.skippedCount > 0 || cached.failedCount > 0) && this.canShowGestureShareFeedback(candidates)) {
        this.showImmersiveToast('已提交 ' + cached.entries.length.toString() + ' 个文件，' +
          (cached.skippedCount + cached.failedCount).toString() + ' 个文件未能传送')
      }
    } catch (error) {
      console.warn('[UgreenShare] gesturesShare failed stage=' + stage + ' elapsedMs=' +
        (this.getMonotonicNow() - startedAt).toString() + ' error=' + JSON.stringify(error))
      if (!shareRequested && !targetRejected) {
        await this.rejectGestureShare(target, harmonyShare.SharableErrorCode.DOWNLOAD_ERROR)
      }
      if (this.canShowGestureShareFeedback(candidates)) {
        this.reportError(error as Object, '隔空传送失败')
      }
    } finally {
      if (preparationTimer >= 0) {
        clearTimeout(preparationTimer)
      }
      for (const path of pinnedPaths) {
        StorageBudget.unpin(path)
      }
      if (this.statusText === '正在准备隔空传送…') {
        this.statusText = ''
      }
      this.gestureSharePreparing = false
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
    return this.topSafeInset() + HeaderStyle.contentTopInset
  }

  private hasSettingsSubpage(): boolean {
    return this.showStorageSettings || this.showPlaybackSettings || this.showViewSettings ||
      this.showNetworkSettings || this.showRecycleBinSettings
  }

  private filePresentationPath(): string {
    return this.fileTransitionHeader === null ? this.currentPath : this.fileTransitionHeader.path
  }

  private mainHeaderHasLeading(): boolean {
    return this.screen === 'files' ? this.fileHeaderLeadingVisible() :
      this.screen === 'settings' && this.hasSettingsSubpage()
  }

  private mainHeaderTitle(): string {
    if (this.screen === 'files') {
      return this.selectionMode ? this.selectionTitle() :
        (this.fileTransitionHeader === null ? this.fileTitle(this.currentPath) : this.fileTransitionHeader.title)
    }
    if (this.screen === 'downloads') { return '传输' }
    if (this.screen !== 'settings') { return this.topTitle }
    if (this.showStorageSettings) { return '缓存与存储' }
    if (this.showPlaybackSettings) { return '播放与控制' }
    if (this.showViewSettings) { return '默认视图' }
    if (this.showNetworkSettings) { return '网络与流量' }
    return this.showRecycleBinSettings ? this.topTitle : '设置'
  }

  private closeSettingsSubpage(): void {
    if (this.showStorageSettings) { this.closeStorageSettings() }
    else if (this.showPlaybackSettings) { this.closePlaybackSettings() }
    else if (this.showViewSettings) { this.closeViewSettings() }
    else if (this.showNetworkSettings) { this.closeNetworkSettings() }
    else if (this.showRecycleBinSettings) { this.recycleBackAction() }
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

  private shouldShowTimeline(): boolean {
    if (this.floatingTimelineHeight() <= 0) {
      return false
    }
    const visibleImageCount = this.timelineVisibleImageCount()
    const currentDirectoryKey = this.currentRootType.toString() + ':' + this.currentPath
    // The index is keyed by directory. During a push/pop the live page and its
    // metadata can be one step apart; never paint the previous directory's
    // rail over the incoming page.
    return this.fileSortKey === 'time' && !this.showPageTransition &&
      this.indexedDirectoryKey === currentDirectoryKey && this.directoryTimeline.eligible(
      DirectoryTimelinePolicy.minimumImageCount(visibleImageCount)) &&
      this.shouldShowFileToolsBar()
  }

  private timelineVisibleImageCount(): number {
    let source = this.entries
    let start = this.fileVisibleStartIndex
    let end = this.fileVisibleEndIndex
    if (this.fileViewMode === 'waterfall') {
      source = this.waterfallEntries
      start = this.waterfallVisibleStartIndex
      end = this.waterfallVisibleEndIndex
    } else if (this.fileViewMode === 'list') {
      // List index zero is the fixed top spacer, not a file entry.
      start = Math.max(0, start - 1)
      end = Math.max(start, end - 1)
    }
    if (source.length === 0 || end < start) {
      return 0
    }
    const lower = Math.max(0, start)
    const upper = Math.min(source.length - 1, end)
    let count = 0
    for (let index = lower; index <= upper; index += 1) {
      if (!source[index].isDirectory && this.isImage(source[index])) {
        count += 1
      }
    }
    return count
  }

  private floatingTimelineHeight(): number {
    const fileRegionHeight = this.pageHeightVp - this.fileContentTopInset() -
      this.floatingBarBottomMargin() - FLOATING_BAR_HEIGHT_VP
    // 预留与底栏及顶部内容的安全留白（与底栏顶部保留 FLOATING_TIMELINE_GAP_VP 间距，决不重叠）
    const safeMaxHeight = fileRegionHeight - FLOATING_TIMELINE_GAP_VP * 2 - FLOATING_TIMELINE_EFFECT_INSET_VP * 2
    if (safeMaxHeight < 120) {
      return 0
    }
    return Math.min(520, safeMaxHeight)
  }

  private fileToolsBarHeight(): number {
    return FLOATING_BAR_HEIGHT_VP
  }

  private isUserRootPath(path: string): boolean {
    if (path.length === 0) {
      return false
    }
    const normalized = path.replace(/\/+$/, '').toLowerCase()
    const accountName = this.username.trim().replace(/^\/+|\/+$/g, '').toLowerCase()
    if (accountName.length > 0 && (normalized === ('/home/' + accountName) || normalized === ('/' + accountName))) {
      return true
    }
    // 注意：不要把 findDefaultPersonalDirectory()（个人空间里的第一个文件夹）当成用户根 ✗
    // 那只是个普通文件夹；把它算作根会导致"打开它永远是列表、且切换按钮失效"。
    // 用户根只有 /home/<登录用户名> 这一种形态，上面已经判过。
    return false
  }

  private shouldShowBottomBar(): boolean {
    if (this.showSearch) {
      return false
    }
    if (this.screen === 'downloads') {
      return true
    }
    if (this.screen === 'settings') {
      return !this.hasSettingsSubpage()
    }
    if (this.screen !== 'files') {
      return false
    }
    // 根目录（仅管理员可见的个人空间根、或共享空间根）
    const path = this.filePresentationPath()
    if (path.length === 0) {
      return true
    }
    // 用户个人空间主界面（用户根目录，如 /admin、/home/admin）
    if (this.rootKind === 'personal' && this.isUserRootPath(path)) {
      return true
    }
    return false
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
    if (this.viewerInteractionUnlocked) {
      return false
    }
    return this.showImageViewer || this.viewerEntryTransitionActive ||
      this.viewerFallbackEntryActive || this.viewerClosePending
  }

  // Parent chrome is retained beneath overlays. Only input ownership changes;
  // do not use these flags to unmount material hosts or change the bar's mode.
  private parentOverlayOwnsInteraction(): boolean {
    return !this.startupAuthorized || this.startupRestoring || this.viewerOwnsParentInteraction() || this.showAudioPlayer ||
      this.videoPlaybackUiVisible() || this.videoEntryTransitionActive ||
      this.contextMenuEntry !== null || this.showRenameDialog ||
      this.showDestinationPicker || this.showCreateFolderDialog ||
      this.showAlbumPicker || this.showAlbumUpload || this.showAlbumDetails
  }

  private shouldShowFloatingImportControl(): boolean {
    return this.screen === 'files' && this.filePresentationPath().length > 0 &&
      !this.showSearch && !this.selectionMode
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
      !this.shouldShowBottomBar() && !this.selectionMode
  }

  private videoPlaybackUiVisible(): boolean {
    return (this.showVideoPlayer || this.videoOverlayClosing) && !this.videoPipBackgrounded
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

  private updateTopTitle(title: string): void {
    // A title belongs to the route that is committed in this same turn.
    // A delayed fade used to paint the previous page after its back control had changed.
    this.topTitle = title.length > 0 ? title : '我的云盘'
    this.topTitleOpacity = 1
  }

  private effectivePageWidth(): number {
    return this.pageWidthVp > 0 ? this.pageWidthVp : 360
  }

  private cancelFileTransition(): void {
    const shouldResetPreview = this.resetPreviewAfterPageTransition
    this.resetPreviewAfterPageTransition = false
    this.pageTransitionFinishing = false
    this.pageTransitionToken += 1
    if (this.pageTransitionTimer > 0) {
      clearTimeout(this.pageTransitionTimer)
      this.pageTransitionTimer = 0
    }
    this.showPageTransition = false
    this.fileTransitionHeader = null
    this.pageOffsetX = 0
    this.outgoingPageOffsetX = 0
    this.transitionSnapshotOnTop = false
    this.transitionSnapshotMode = 'list'
    this.outgoingEntries = []
    if (shouldResetPreview) {
      this.resetPreviewState(false)
    }
  }

  private prepareFileTransition(outgoingEntries: FileEntry[], direction: PageTransitionDirection,
    stageIncomingOffscreen: boolean = true): number {
    this.cancelFileTransition()
    const token = this.pageTransitionToken
    const width = this.effectivePageWidth()
    this.fileTransitionHeader = new DirectoryHeaderState(this.currentPath, this.rootKind === 'personal')
    this.outgoingEntries = outgoingEntries.slice()
    this.transitionFileEntryDataSource.replace(this.outgoingEntries)
    this.transitionSnapshotMode = this.fileViewMode
    this.transitionSnapshotOnTop = false
    this.outgoingPageOffsetX = 0
    // A transactional directory push first submits the outgoing snapshot while
    // the live page is still covering it. Moving the live page in that same
    // insertion frame can expose an unpainted conditional snapshot for one
    // frame. Callers that have already replaced the live page keep the legacy
    // offscreen staging through the default value.
    this.pageOffsetX = stageIncomingOffscreen ? (direction === 'push' ? width : -width) : 0
    this.showPageTransition = true
    return token
  }

  private animatePreparedFileTransition(token: number, direction: PageTransitionDirection,
    incomingPath: string): void {
    if (token !== this.pageTransitionToken || !this.showPageTransition) {
      return
    }
    const width = this.effectivePageWidth()
    // The incoming page travels one full screen width while the outgoing
    // page travels half a screen width in the same duration. Linear motion
    // keeps the 1:1/2 speed ratio visible instead of hiding it in easing.
    this.fileTransitionHeader = new DirectoryHeaderState(incomingPath, this.rootKind === 'personal')
    this.updateTopTitle(this.fileTitle(incomingPath))
    const outgoingTarget = direction === 'push' ? -width * 0.5 : width * 0.5
    this.getUIContext().animateTo({
      duration: 180,
      curve: Curve.FastOutSlowIn,
      finishCallbackType: FinishCallbackType.REMOVED,
      onFinish: (): void => {
        this.finishPreparedFileTransition(token)
      }
    }, () => {
      if (token !== this.pageTransitionToken) {
        return
      }
      this.pageOffsetX = 0
      this.outgoingPageOffsetX = outgoingTarget
    })
  }

  private finishPreparedFileTransition(token: number): void {
    if (token !== this.pageTransitionToken || !this.showPageTransition) {
      return
    }
    this.pageTransitionTimer = 0
    this.showPageTransition = false
    this.fileTransitionHeader = null
    this.pageOffsetX = 0
    this.outgoingPageOffsetX = 0
    this.transitionSnapshotOnTop = false
    this.transitionSnapshotMode = 'list'
    this.outgoingEntries = []
    this.isBusy = false
    if (this.resetPreviewAfterPageTransition) {
      this.resetPreviewAfterPageTransition = false
      this.resetPreviewState(false)
    }
  }

  /**
   * Keep the outgoing lazy container intact for one submitted frame before
   * reloading the hidden incoming container. This follows ArkUI's documented
   * transition ordering: insertion first, data replacement second, animation
   * only after both surfaces have completed an initial frame.
   */
  private async transitionFileContent(outgoingEntries: FileEntry[], direction: PageTransitionDirection,
    incomingPath: string, outgoingState: DirectoryViewState | null, commitIncoming: () => void,
    settleIncoming: (() => void) | null = null,
    resetPreviewOnFinish: boolean = false): Promise<boolean> {
    const token = this.prepareFileTransition(outgoingEntries, direction, false)
    this.resetPreviewAfterPageTransition = resetPreviewOnFinish
    await this.nextRenderFrame()
    if (token !== this.pageTransitionToken || !this.showPageTransition) {
      return false
    }
    // The snapshot is still covered by the live outgoing page. Position it
    // now and submit that frame before exposing it; otherwise a reused
    // transitionScroller can show the position left by an earlier directory.
    if (!await this.settleFileTransitionSnapshotBeforeReveal(token, outgoingState)) {
      return false
    }
    // The outgoing snapshot now owns a submitted frame. Replace and place the
    // incoming live surface offscreen in one update so no intermediate empty
    // directory frame can reach the compositor.
    const width = this.effectivePageWidth()
    this.pageOffsetX = direction === 'push' ? width : -width
    try {
      commitIncoming()
    } catch (error) {
      this.cancelFileTransition()
      const message = error instanceof Error ? error.message : JSON.stringify(error)
      throw new Error(message)
    }
    await this.nextRenderFrame()
    if (token !== this.pageTransitionToken || !this.showPageTransition) {
      return false
    }
    if (settleIncoming !== null) {
      settleIncoming()
      await this.nextRenderFrame()
      if (token !== this.pageTransitionToken || !this.showPageTransition) {
        return false
      }
    }
    this.animatePreparedFileTransition(token, direction, incomingPath)
    return true
  }

  private settleFileTransitionSnapshot(state: DirectoryViewState | null): void {
    if (state === null || state.mode === 'waterfall' || state.offset === null) {
      return
    }
    try {
      this.transitionScroller.scrollTo({
        xOffset: state.offset.xOffset,
        yOffset: state.offset.yOffset,
        animation: false
      })
    } catch (_) {
      // The transition surface may still be completing its first layout.
    }
  }

  private transitionSnapshotStateIsSettled(state: DirectoryViewState | null): boolean {
    if (state === null || state.mode === 'waterfall' || state.offset === null) {
      return true
    }
    try {
      const offset = this.transitionScroller.currentOffset()
      return offset !== undefined && typeof offset.yOffset === 'number' &&
        Math.abs(offset.yOffset - state.offset.yOffset) <= 1
    } catch (_) {
      return false
    }
  }

  private async settleFileTransitionSnapshotBeforeReveal(token: number,
    state: DirectoryViewState | null): Promise<boolean> {
    if (state === null || state.mode === 'waterfall' || state.offset === null) {
      return true
    }
    for (let attempt = 0; attempt < 6; attempt += 1) {
      this.settleFileTransitionSnapshot(state)
      await this.nextRenderFrame()
      if (token !== this.pageTransitionToken || !this.showPageTransition) {
        return false
      }
      if (this.transitionSnapshotStateIsSettled(state)) {
        return true
      }
    }
    // A changed or shortened directory may clamp an old offset. The snapshot
    // still holds the closest valid position and must not block navigation.
    return true
  }

  private finishBackFileTransition(token: number, incomingState: DirectoryViewState | null,
    commitIncoming: () => void): void {
    if (token !== this.pageTransitionToken || !this.showPageTransition || this.pageTransitionFinishing) {
      return
    }
    this.pageTransitionFinishing = true
    if (this.pageTransitionTimer > 0) {
      clearTimeout(this.pageTransitionTimer)
      this.pageTransitionTimer = 0
    }
    // The parent snapshot entered above the live child and now covers the
    // viewport completely. Rebuild the real parent behind that stable surface.
    try {
      commitIncoming()
    } catch (error) {
      this.cancelFileTransition()
      this.isBusy = false
      this.reportError(error as Object, '返回目录失败')
      return
    }
    // The live parent is behind the fully arrived snapshot. Try immediately,
    // then verify its real Scroller position on submitted frames. The snapshot
    // is removed only after the live page is at the captured position.
    this.settleDirectoryViewStateForTransition(incomingState)
    this.waitForBackDirectoryPosition(token, incomingState, 0)
  }

  private waitForBackDirectoryPosition(token: number, incomingState: DirectoryViewState | null,
    attempt: number): void {
    this.postRenderFrame((): void => {
      if (token !== this.pageTransitionToken || !this.showPageTransition) {
        return
      }
      if (this.directoryViewStateIsSettled(incomingState) || attempt >= 5) {
        this.completeBackFileTransition()
        return
      }
      this.settleDirectoryViewStateForTransition(incomingState)
      this.waitForBackDirectoryPosition(token, incomingState, attempt + 1)
    })
  }

  private directoryViewStateIsSettled(state: DirectoryViewState | null): boolean {
    if (state === null || state.offset === null || this.screen !== 'files' || this.showSearch) {
      return true
    }
    try {
      if (state.mode === 'waterfall' && state.anchor !== null) {
        const index = this.waterfallEntries.findIndex(
          (entry: FileEntry): boolean => entry.path === state.anchor?.path)
        if (index < 0) {
          return true
        }
        const rect = this.waterfallScroller.getItemRect(index)
        return rect !== undefined && typeof rect.y === 'number' &&
          Math.abs(rect.y - state.anchor.y) <= 1
      }
      const scroller = this.fileViewMode === 'waterfall'
        ? this.waterfallScroller : this.fileListScroller
      const offset = scroller.currentOffset()
      return offset !== undefined && typeof offset.yOffset === 'number' &&
        Math.abs(offset.yOffset - state.offset.yOffset) <= 1
    } catch (_) {
      return false
    }
  }

  private completeBackFileTransition(): void {
    this.traceStateWrite('StateWrite:cbf.pageOffsetX')
    this.pageOffsetX = 0
    this.traceStateWrite('StateWrite:cbf.outgoingPageOffsetX')
    this.outgoingPageOffsetX = 0
    this.traceStateWrite('StateWrite:cbf.showPageTransition')
    this.showPageTransition = false
    this.fileTransitionHeader = null
    this.traceStateWrite('StateWrite:cbf.transitionSnapshotOnTop')
    this.transitionSnapshotOnTop = false
    this.traceStateWrite('StateWrite:cbf.transitionSnapshotMode')
    this.transitionSnapshotMode = 'list'
    this.traceStateWrite('StateWrite:cbf.outgoingEntries')
    this.outgoingEntries = []
    this.resetPreviewState(false)
    this.pageTransitionFinishing = false
    this.traceStateWrite('StateWrite:cbf.isBusy')
    this.isBusy = false
  }

  /**
   * Pop keeps the current file surface mounted for the whole exit animation.
   * The parent snapshot enters above it; only after the animation completes
   * do we replace the live data source and release the outgoing previews.
   */
  private async transitionBackFileContent(incomingEntries: FileEntry[], incomingState: DirectoryViewState | null,
    incomingPath: string, commitIncoming: (preparedEntries: FileEntry[]) => void): Promise<boolean> {
    this.cancelFileTransition()
    const token = this.pageTransitionToken
    const width = this.effectivePageWidth()
    this.fileTransitionHeader = new DirectoryHeaderState(this.currentPath, this.rootKind === 'personal')
    this.traceStateWrite('StateWrite:tbf.outgoingEntries')
    const preparedEntries = this.sortEntriesForDisplay(incomingEntries)
    this.outgoingEntries = preparedEntries
    this.transitionFileEntryDataSource.replace(this.outgoingEntries)
    this.traceStateWrite('StateWrite:tbf.transitionSnapshotMode')
    this.transitionSnapshotMode = incomingState === null || incomingState.mode === 'waterfall'
      ? 'list' : incomingState.mode
    // Keep the returning parent above the outgoing child for the entire pop.
    // At x = -width it is outside the viewport; at x = 0 it already forms the
    // complete final frame, so no end-of-animation z-order handoff is needed.
    this.traceStateWrite('StateWrite:tbf.transitionSnapshotOnTop')
    this.transitionSnapshotOnTop = true
    this.traceStateWrite('StateWrite:tbf.outgoingPageOffsetX')
    this.outgoingPageOffsetX = -width
    this.traceStateWrite('StateWrite:tbf.pageOffsetX')
    this.pageOffsetX = 0
    this.traceStateWrite('StateWrite:tbf.showPageTransition')
    this.showPageTransition = true

    await this.nextRenderFrame()
    if (token !== this.pageTransitionToken || !this.showPageTransition) {
      return false
    }
    if (!await this.settleFileTransitionSnapshotBeforeReveal(token, incomingState)) {
      return false
    }
    if (token !== this.pageTransitionToken || !this.showPageTransition) { return false }

    this.fileTransitionHeader = new DirectoryHeaderState(incomingPath, this.rootKind === 'personal')
    this.updateTopTitle(this.fileTitle(incomingPath))
    this.getUIContext().animateTo({
      duration: 180,
      curve: Curve.FastOutSlowIn,
      finishCallbackType: FinishCallbackType.REMOVED,
      onFinish: (): void => {
        this.finishBackFileTransition(token, incomingState, (): void => commitIncoming(preparedEntries))
      }
    }, () => {
      if (token !== this.pageTransitionToken) {
        return
      }
      this.pageOffsetX = width * 0.5
      this.outgoingPageOffsetX = 0
    })
    return true
  }

  onBackPress(): boolean {
    if (this.continuationPending || this.continuationSending) {
      ContinuationManager.shared().cancel(); return true
    }
    if (!this.startupAuthorized) { this.exitBeforeAuthorization(); return true }
    if (this.showAlbumPicker) { this.albumConfirmationPending = false; this.showAlbumPicker = false; return true }
    if (this.showAlbumUpload) {
      if (!this.albumUploadStarting) { this.showAlbumUpload = false }
      return true
    }
    if (this.showAlbumDetails) { this.showAlbumDetails = false; return true }
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
    if (this.showAudioQueue) { this.showAudioQueue = false; return true }
    if (this.audioClosing) { return true }
    if (this.showAudioPlayer) {
      this.closeAudioPlayer()
      return true
    }
    if (this.videoRatePanel) { this.videoRatePanel = false; this.scheduleVideoChromeHide(); return true }
    if (this.videoPlaybackUiVisible()) {
      this.closeVideoPlayer(true)
      return true
    }
    if (this.showSearch) {
      this.dismissKeyboard()
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
      if (this.showViewSettings) {
        this.closeViewSettings()
        return true
      }
      if (this.showNetworkSettings) {
        this.closeNetworkSettings()
        return true
      }
      if (this.showRecycleBinSettings) {
        this.recycleBackAction()
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
          this.FileContentSnapshot(this.outgoingEntries, this.transitionSnapshotMode)
        }
        .width('100%')
        .height('100%')
        .translate({ x: this.outgoingPageOffsetX, y: 0, z: 0 })
        .zIndex(this.transitionSnapshotOnTop ? 5 : 0)
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
      .id('main-file-content')
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      .translate({ x: this.pageOffsetX, y: 0, z: 0 })
      // Viewer Input Ownership: main-file-content 恒定为 Default，不再依赖动态 BLOCK_DESCENDANTS。
      .hitTestBehavior(HitTestMode.Default)
      .onAreaChange((_, area) => {
        if (this.contextMenuEntry !== null &&
          ((typeof area.width === 'number' && area.width > 0 && area.width !== this.pageWidthVp) ||
            (typeof area.height === 'number' && area.height > 0 && area.height !== this.pageHeightVp))) {
          this.closeActionMenu()
        }
        if (typeof area.globalPosition.x === 'number' && typeof area.globalPosition.y === 'number') {
          this.mainContentOriginX = area.globalPosition.x
          this.mainContentOriginY = area.globalPosition.y
        }
        if (typeof area.width === 'number' && area.width > 0) {
          this.pageWidthVp = area.width
        }
        if (typeof area.height === 'number' && area.height > 0) {
          this.pageHeightVp = area.height
        }
      })

      // Keep material hosts and the current bar mode across every overlay,
      // matching the image viewer's return path.
      if (this.screen === 'files' || this.screen === 'downloads' || this.screen === 'settings') {
        // 三种底栏形态共用这一个常驻外壳，内部按 bottomBarMode() 交叉淡化；
        // 显隐仍由 bottomBarOffsetY/bottomBarOpacity 控制。
        Stack({ alignContent: Alignment.Bottom }) {
          this.BottomBar()
        }
        .id('bottom-bar-host')
        .width('100%')
        .height('100%')
        .translate({ x: 0, y: this.bottomBarOffsetY, z: 0 })
        .opacity(this.bottomBarOpacity)
        .zIndex(20)
        // The host is transparent and contains only the capsule. Its empty
        // area must pass through to the file surface below.
        .hitTestBehavior(this.parentOverlayOwnsInteraction()
          ? HitTestMode.BLOCK_DESCENDANTS : HitTestMode.None)
      }

      if (this.screen === 'files') {
        // Keep the immersive-material scope as narrow as the timeline itself.
        // A full-width, full-height TabBar consumes file-row taps even when
        // its authored child is transparent.
        // Keep the material/renderer node mounted for the whole file screen.
        // Recreating it around directory transitions can leave a native draw
        // buffer targeting an already released UIContext. Visibility and
        // interaction therefore change independently, like the bottom bar.
        Stack() {
          this.DirectoryTimelineBar()
        }
        .id('timeline-bar-host')
        .width(FLOATING_TIMELINE_WIDTH_VP)
        .height(this.floatingTimelineHeight() + FLOATING_TIMELINE_EFFECT_INSET_VP * 2)
        .position({
          x: Math.max(0, this.effectivePageWidth() - FLOATING_TIMELINE_WIDTH_VP - 8),
          // Move the visible rail upward while placing real renderer space
          // above and below it. The TabBar may clip its own child, but that
          // clip now lands in the reserved area instead of on the material.
          y: this.fileContentTopInset() + FLOATING_TIMELINE_GAP_VP -
            FLOATING_TIMELINE_EFFECT_INSET_VP - FLOATING_TIMELINE_UPWARD_SHIFT_VP
        })
        // 收起时整体右移，只留 FLOATING_TIMELINE_PEEK_VP 在屏内。
        .translate({
          x: this.timelineCollapsed
            ? FLOATING_TIMELINE_WIDTH_VP - FLOATING_TIMELINE_PEEK_VP : 0,
          y: this.bottomBarOffsetY, z: 0
        })
        .opacity(this.shouldShowTimeline() ? this.bottomBarOpacity : 0)
        // Opacity alone does not reliably suppress the native material and
        // Canvas sublayers during a directory transaction. Hidden preserves
        // the renderer node and its layout while removing it from painting,
        // so the previous directory's rail cannot survive the pop frame.
        .visibility(this.shouldShowTimeline() ? Visibility.Visible : Visibility.Hidden)
        .zIndex(this.showDestinationPicker ? 8 : 21)
        // 收起态：整层自己要点击（露出的那一小截不能被下面的图片接走）。
        // 展开态：必须用 Default —— None 是「自身不响应」，挂在整层上的 onClick 永远收不到 ✗；
        // Default 是「自身响应 + 子节点照常响应」，轴条的拖动定位不受影响。
        // 未显示或大图查看态：必须用 BLOCK_DESCENDANTS —— 自身不响应【且阻塞所有后代】，
        // 整棵子树退出命中测试，事件才真正落到下面的底栏/列表 ✗
        // （None 只让「自身」不响应，子节点照常参与命中 → 隐藏态的轴条会吃掉点击。）
        .hitTestBehavior(this.shouldShowTimeline() && !this.parentOverlayOwnsInteraction()
          ? HitTestMode.Default
          : HitTestMode.BLOCK_DESCENDANTS)
      }

      if (this.screen === 'downloads' && this.transferDirection === 'download' && this.hasActiveDownload()) {
        this.DownloadSpeedBall()
      }

      // Retain the control's docking state and native material while an overlay
      // covers it. Search/selection only hide it; they do not create a new ball.
      if (this.screen === 'files' && this.currentPath.length > 0) {
        if (this.importExpanded && this.shouldShowFloatingImportControl() &&
          !this.parentOverlayOwnsInteraction()) {
          Row().width('100%').height('100%').backgroundColor(Color.Transparent).zIndex(24)
            .onClick(() => {
              this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
                this.importExpanded = false
              })
            })
        }
        // 进目录的等待反馈：大目录首次打开要建索引，可能停在本页好几秒。
        // 期间用户停在上一层，必须给一个居中的明确提示，否则像卡死。
        if (this.isBusy && this.isNavigating && this.screen === 'files' &&
          this.directoryOpeningHintVisible) {
          Stack() {
            Column({ space: 10 }) {
              LoadingProgress()
                .width(26)
                .height(26)
                .color('#2E6BFF')
              Text('正在打开，目录较大时首次需要等待…')
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
            }
            .alignItems(HorizontalAlign.Center)
            .justifyContent(FlexAlign.Center)
            .padding({ left: 24, right: 24, top: 20, bottom: 20 })
            .borderRadius(16)
            .backgroundColor($r('app.color.surface_card'))
          }
          .width('100%')
          .height('100%')
          .alignContent(Alignment.Center)
          .hitTestBehavior(HitTestMode.None)
          .zIndex(18)
        }
        FloatingImportControl({ viewportWidth: this.pageWidthVp, viewportHeight: this.pageHeightVp,
          // The title controls end at topSafeInset + 56vp. Keep only an 8vp
          // clearance instead of treating the 30vp gradient tail as a blocker.
          safeTop: this.topSafeInset() + 64, safeBottom: this.floatingBarContentInset(8),
          expanded: $importExpanded, onSelect: (source: string): void => { this.selectImportSource(source) },
          onControlAreaChange: (area: Area): void => { this.updateFloatingImportRect(area) } })
          .id('floating-import-host')
          .position({ x: 0, y: 0 })
          .visibility(this.shouldShowFloatingImportControl() ? Visibility.Visible : Visibility.Hidden)
          // 选取页的层级是 20；悬浮球平时是 25，会一直压在选取页上面（显示逻辑不对）。
          // 选取页打开时把它降到 8，正好被盖在底下。
          .zIndex(this.showDestinationPicker || this.viewerClosePending ? 8 : 25)
          // The overlay is a full page sized host whose only interactive part is
          // the ball itself. Keeping the host out of the touch test lets taps
          // reach the file list under it.
          .hitTestBehavior(!this.shouldShowFloatingImportControl() || this.parentOverlayOwnsInteraction()
            ? HitTestMode.BLOCK_DESCENDANTS
            : (this.importSelecting || this.showCreateFolderDialog
              ? HitTestMode.BLOCK_DESCENDANTS : HitTestMode.None))
      }

      // Native title materials stay mounted beneath media and picker overlays.
      if (this.screen === 'files' || this.screen === 'downloads' || this.screen === 'settings') {
        Stack({ alignContent: Alignment.TopStart }) {
          this.NativeFileHeader()
        }
        .id('native-file-header-host')
        .width('100%')
        .height('100%')
        .zIndex(10)
        .hitTestBehavior(this.parentOverlayOwnsInteraction()
          ? HitTestMode.BLOCK_DESCENDANTS : HitTestMode.None)
      }

      this.ActionMenuOverlay()

      if (this.showDestinationPicker) {
        // 包一层给足 zIndex：标题栏现在一直挂在树上（zIndex 10），选取页必须压在它
        // 上面，否则会被标题栏盖住。
        Stack() {
          this.DestinationPickerOverlay()
        }
        .width('100%')
        .height('100%')
        .zIndex(20)
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
        .id('viewer-overlay-root')
        .width('100%')
        .height('100%')
        .zIndex(30)
        .onAreaChange((_, area) => {
          if (typeof area.globalPosition.x === 'number' &&
            typeof area.globalPosition.y === 'number') {
            this.viewerLayerOriginX = area.globalPosition.x
            this.viewerLayerOriginY = area.globalPosition.y
          }
        })
        .hitTestBehavior(this.viewerClosing ? HitTestMode.Transparent : HitTestMode.Default)
      }
      if (this.viewerReturnOverlayVisible) {
        // A sibling of main-file-content, outside Grid/LazyForEach and its clip.
        // Same page layer as Viewer; later sibling draws over Viewer during handoff.
        this.ViewerReturnOverlay()
      }
      if (this.showAudioPlayer && this.audioEntry !== null) {
        this.AudioPlayerOverlay()
      }
      if (this.audioFlightVisible) { this.AudioCoverFlight() }
      if (this.showVideoPlayer && this.videoEntry !== null) {
        this.VideoPlayerOverlay(this.videoEntry as FileEntry)
      }
      // Keep native sheet anchors mounted for both opening and dismissal.
      this.RenameOverlay()
      this.CreateFolderOverlay()
      this.DestinationFolderOverlay()
      this.ImageViewerDetailsOverlay()
      this.AlbumUploadOverlay()
      if (this.startupAuthorized && !this.startupRestoring && this.continuationPending &&
        this.continuationWaitingForAccount) {
        Row({ space: 12 }) {
          Text('接续需要登录相同的 NAS 和账号').fontSize(14).layoutWeight(1)
            .fontColor($r('sys.color.font_primary'))
          Button('取消').fontSize(14).height(36)
            .onClick(() => ContinuationManager.shared().cancel())
        }
        .padding(16).width('100%').backgroundColor($r('app.color.page_background'))
        .position({ x: 0, y: this.topSafeInset() + HeaderStyle.overlayHeight }).zIndex(190)
      }
      if (this.startupAuthorized && !this.startupRestoring &&
        ((this.continuationPending && !this.continuationWaitingForAccount) || this.continuationSending)) {
        Column({ space: 16 }) {
          Image($r('app.media.icon')).width(76).height(76).objectFit(ImageFit.Contain).borderRadius(18)
          LoadingProgress().width(24).height(24).color('#2E6BFF')
          Text(this.continuationSending ? '正在准备接续…' : '正在接续…')
            .fontSize(14).fontColor($r('sys.color.font_secondary'))
          Button('取消').height(40).fontSize(14).backgroundColor(Color.Transparent)
            .fontColor($r('sys.color.font_secondary')).onClick(() => ContinuationManager.shared().cancel())
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.page_background'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .hitTestBehavior(HitTestMode.Block).zIndex(190).id('continuation-restoration-cover')
      }
      if (!this.startupAuthorized || this.startupRestoring) {
        Column({ space: 16 }) {
          Image($r('app.media.icon')).width(76).height(76)
            .objectFit(ImageFit.Contain).borderRadius(18).clip(true)
            .accessibilityText('联文件应用图标').id('startup-app-logo')
          if (this.startupAuthorizing || this.startupAuthorized) {
            LoadingProgress().width(24).height(24).color('#2E6BFF')
          } else {
            Text(this.startupAuthorizationMessage).fontSize(14).fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Center).id('startup-authorization-message')
            Button('查看隐私声明').height(48).padding({ left: 24, right: 24 })
              .fontSize(16).backgroundColor($r('sys.color.comp_background_emphasize'))
              .fontColor($r('sys.color.font_on_primary'))
              .onClick(() => this.completeStartupAuthorization(true)).id('startup-authorization-retry')
            Button('退出').height(40).fontSize(14).backgroundColor(Color.Transparent)
              .fontColor($r('sys.color.font_secondary')).onClick(() => this.exitBeforeAuthorization())
              .id('startup-authorization-exit')
          }
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.page_background'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .hitTestBehavior(HitTestMode.Block)
        .id('startup-restoration-cover')
        .zIndex(200)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // While the long-press menu is up, swallow page touches so the tap that
    // dismisses the menu cannot also activate the file list underneath
    // (official bindContextMenu event-passthrough guidance).
    .hitTestBehavior(this.contextMenuEntry !== null ? HitTestMode.Block : HitTestMode.Default)
    .onChildTouchTest((infos: Array<TouchTestInfo>): TouchResult => {
      if (this.closeSessionActive && this.sessionTouchTestCount < 3) {
        this.sessionTouchTestCount += 1
        const dt = this.getMonotonicNow() - this.closeAnimFinishMonotonic
        const candidateStrs: string[] = []
        for (let i = 0; i < infos.length; i++) {
          const item = infos[i]
          const r = item.rect
          const rStr = r ? `[${Math.round(r.x)},${Math.round(r.y)},${Math.round(r.width)},${Math.round(r.height)}]` : '[]'
          const idStr = item.id && item.id.length > 0 ? item.id : 'unnamed'
          candidateStrs.push(`${idStr}(rect=${rStr} local=(${Math.round(item.x)},${Math.round(item.y)}) win=(${Math.round(item.windowX)},${Math.round(item.windowY)}))`)
        }
        console.info('[TouchChain] #' + this.closeSessionId.toString() +
          ' ChildTouchTest #' + this.sessionTouchTestCount.toString() +
          ' +' + dt.toString() + 'ms candidates=[' + candidateStrs.join(', ') + ']')
      }
      if (infos.length > 0 && !this.parentOverlayOwnsInteraction() &&
        !this.showFileSortMenu && !this.showSelectionMoreMenu) {
        const point = infos[0]
        const winX = point.windowX
        const winY = point.windowY
        if (this.isInsideFloatingImportControl(winX, winY)) {
          return { strategy: TouchTestStrategy.DEFAULT, id: '' }
        }
        if (this.isInsideRealBottomBarControl(winX, winY)) {
          return { strategy: TouchTestStrategy.DEFAULT, id: '' }
        }
        if (this.isInsideBottomBarVisualHost(winX, winY)) {
          if (TAP_TRACE) {
            console.info('[TouchTrace] onChildTouchTest FORWARD -> main-file-content at (' +
              Math.round(winX).toString() + ',' + Math.round(winY).toString() + ')')
          }
          return { strategy: TouchTestStrategy.FORWARD, id: 'main-file-content' }
        }
      }
      return { strategy: TouchTestStrategy.DEFAULT, id: '' }
    })
    .onTouch((event: TouchEvent): void => {
      this.handleDragSelectionTouch(event)
      if (event.type === TouchType.Down) {
        this.fileContentTouchActive = true
        this.noteUserInteraction()
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.fileContentTouchActive = false
        ContinuationManager.shared().refresh()
        this.lastUserInteractionMonotonic = this.getMonotonicNow()
        this.requestViewerCleanup()
      }
      if (this.closeSessionActive && event.type === TouchType.Down && !this.sessionRootDownLogged) {
        const point = event.touches.length > 0 ? event.touches[0] : null
        const ptrId = point !== null ? point.id : -1
        if (this.sessionTrackedPointerId === -1 || ptrId === this.sessionTrackedPointerId) {
          this.sessionRootDownLogged = true
          if (this.sessionTrackedPointerId === -1) {
            this.sessionTrackedPointerId = ptrId
          }
          const dt = this.getMonotonicNow() - this.closeAnimFinishMonotonic
          const winStr = point !== null ? ' win=(' + Math.round(point.windowX).toString() + ',' + Math.round(point.windowY).toString() + ')' : ''
          const locStr = point !== null ? ' loc=(' + Math.round(point.x).toString() + ',' + Math.round(point.y).toString() + ')' : ''
          console.info('[TouchChain] #' + this.closeSessionId.toString() +
            ' RootDown +' + dt.toString() + 'ms ptr=' + ptrId.toString() +
            winStr + locStr +
            ' | ' + this.formatGuardSnapshot())
        }
      }
    })
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
            } else if (this.showViewSettings) {
              this.closeViewSettings()
            } else if (this.showRecycleBinSettings) {
              this.recycleBackAction()
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
    Column({ space: 26 }) {
      Column({ space: 12 }) {
        Image($r('app.media.private_cloud'))
          .width(76)
          .height(76)
        Text('联文件')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('登录你的私有云盘')
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
      }
      .alignItems(HorizontalAlign.Center)
      .width('100%')

      Column({ space: 12 }) {
        // 云盘 ID。解析是这个字段自己的动作，放进字段尾部而不是和登录并排
        Row({ space: 12 }) {
          TextInput({ placeholder: '当前仅支持绿联 NAS', text: this.linkId })
            .layoutWeight(1)
            .height(46)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_faint'))
            .backgroundColor(Color.Transparent)
            .padding({ left: 0, right: 0 })
            .onChange((value: string) => this.linkId = value)
          Button('解析')
            .height(34)
            .padding({ left: 14, right: 14 })
            .fontSize(13)
            .fontColor('#2E6BFF')
            .backgroundColor($r('app.color.surface_selected'))
            .borderRadius(17)
            .enabled(!this.isBusy)
            .onClick(() => this.handleResolve())
        }
        .width('100%')
        .height(58)
        .padding({ left: 16, right: 8 })
        .backgroundColor($r('app.color.surface_input'))
        .borderRadius(14)

        TextInput({ placeholder: '云盘账号', text: this.username })
          .type(InputType.USER_NAME)
          .height(52)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_faint'))
          .backgroundColor($r('app.color.surface_input'))
          .borderRadius(14)
          .padding({ left: 16, right: 16 })
          .onChange((value: string) => this.username = value)

        TextInput({ placeholder: '云盘密码', text: this.password })
          .type(InputType.Password)
          .showPasswordIcon(true)
          .height(52)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_faint'))
          .backgroundColor($r('app.color.surface_input'))
          .borderRadius(14)
          .padding({ left: 16, right: 16 })
          .onChange((value: string) => this.password = value)
      }
      .width('100%')

      // 选项胶囊必须内联：@Builder 按值传参不会随状态重渲染，
      // 写成 this.LoginOptionButton(active) 时 active 是值拷贝，
      // 点开关只会改状态、颜色永远停在初始值。
      Row({ space: 12 }) {
        Row({ space: 6 }) {
          if (this.autoLogin) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(14)
              .fontColor([Color.White])
          }
          Text('自动登录')
            .fontSize(14)
            .fontColor(this.autoLogin ? Color.White : $r('app.color.text_secondary'))
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .height(44)
        .borderRadius(22)
        .backgroundColor(this.autoLogin ? '#2E6BFF' : $r('app.color.surface_input'))
        .onClick(() => this.toggleAutoLogin())

        Row({ space: 6 }) {
          if (this.rememberAddress) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(14)
              .fontColor([Color.White])
          }
          Text('记住地址')
            .fontSize(14)
            .fontColor(this.rememberAddress ? Color.White : $r('app.color.text_secondary'))
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .height(44)
        .borderRadius(22)
        .backgroundColor(this.rememberAddress ? '#2E6BFF' : $r('app.color.surface_input'))
        .onClick(() => this.toggleRememberAddress())
      }
      .width('100%')

      Button(this.isBusy ? '登录中…' : '登录')
        .width('100%')
        .height(52)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor('#2E6BFF')
        .borderRadius(16)
        .enabled(!this.isBusy)
        .onClick(() => this.handleLogin())

      if (this.statusText.length > 0) {
        Text(this.statusText)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .padding({ left: 30, right: 30 })
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
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
          .width(FileRowStyle.leadingWidth)
          .height(FileRowStyle.leadingHeight)
      } else if (this.isAudio(entry)) {
        // List rows use in-place observed revisions like the grid. A value
        // builder alone can stay on its initial icon after artwork arrives.
        AudioFileLeadingCell({ entry: entry, resolve: (item: FileEntry): string => this.previewUri(item) })
      } else if (this.fileImageSourceAvailable(entry, surface)) {
        Image(this.fileImageSource(entry, surface))
            .width(FileRowStyle.leadingWidth)
            .height(FileRowStyle.leadingHeight)
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
        this.FolderIcon(FileRowStyle.iconSize)
      } else {
        Image(this.fileIcon(entry))
          .width(FileRowStyle.iconSize)
          .height(FileRowStyle.iconSize)
          .objectFit(ImageFit.Contain)
      }
    }
    .width(FileRowStyle.leadingWidth)
    .height(FileRowStyle.leadingHeight)
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
          .fontColor([$r('sys.color.icon_secondary')])
          .margin({ left: 8, right: 4 })
      } else if (this.videoStateForEntry(entry).status === 'completed') {
        Progress({ value: 100, total: 100, type: ProgressType.Ring })
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
      } else if (this.videoTransferIndicatorActive(entry)) {
        if (this.videoTransferIsIndeterminate(entry)) {
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
      } else {
        Blank()
          .width(0)
          .height(0)
      }
    }
  }

  private videoTransferIndicatorActive(entry: FileEntry): boolean {
    const state = this.videoStateForEntry(entry)
    if (state.status === 'queued' || state.status === 'downloading') {
      return true
    }
    // AVPlayer's online buffer is not app cache. A streaming/partial state is
    // visible only when the app actually owns resumable bytes on disk.
    return (state.status === 'streaming' || state.status === 'partial') &&
      state.receivedBytes > 0
  }

  private videoTransferIsIndeterminate(entry: FileEntry): boolean {
    const state = this.videoStateForEntry(entry)
    return state.totalBytes <= 0 || (state.status === 'streaming' && state.receivedBytes <= 0)
  }

  @Builder
  SelectionCheckbox(entry: FileEntry): void {
    // Only this observed marker updates; selection never invalidates Image.
    FileSelectionIndicator({ selection: this.fileSelection.stateFor(entry.path),
      dark: this.isDarkTheme, path: entry.path })
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
      .fontColor([$r('sys.color.icon_secondary')])
  }

  @Builder
  SearchScopeButton(title: string, scope: RemoteSearchScope): void {
    Button(title)
      .height(36)
      // 光有 .height() 实测被压成 18vp（带 label 的 Button 会按 label 量），
      // 这里再钉一个最小高度，保证胶囊是完整的 36vp。
      .constraintSize({ minHeight: 36 })
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
      .onClick(() => {
        this.dismissKeyboard()
        this.submitSearch(keyword)
      })
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
                  .fontColor([$r('sys.color.icon_primary')])
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
                  .fontColor([$r('sys.color.icon_primary')])
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
          top: this.topSafeInset() + 148,
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
              .height(this.topSafeInset() + 144)
          }
          .width('100%')

          if (this.searchLoading && this.searchResults.length === 0) {
            ListItem() {
              Row({ space: 8 }) {
                LoadingProgress()
                  .width(20)
                  .height(20)
                  .color($r('sys.color.icon_primary'))
                Text('正在搜索文件…')
                  .fontSize(14)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 32, bottom: 32 })
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
                    .fontColor([$r('sys.color.icon_secondary')])
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            }
            .onClick(() => this.openSearchResult(entry))
          }, (entry: FileEntry) => entry.path)

          if (this.searchLoading && this.searchResults.length > 0) {
            ListItem() {
              Row({ space: 8 }) {
                LoadingProgress()
                  .width(18)
                  .height(18)
                  .color($r('sys.color.icon_primary'))
                Text(`正在搜索更多结果（已找到 ${this.searchResults.length} 项）…`)
                  .fontSize(13)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 16, bottom: 20 })
            }
          }

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
        .onDidScroll((_scrollOffset: number, _state: ScrollState): void => {
          try {
            const offset = this.searchResultScroller.currentOffset()
            if (offset !== undefined && typeof offset.yOffset === 'number') {
              this.searchScrollOffset = Math.max(0, offset.yOffset)
            }
          } catch (_) {}
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
      } else if (this.fileViewMode === 'waterfall' && this.currentDirectoryIsPhotoAlbum) {
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
                .margin({ right: FileRowStyle.leadingGap })
                Column() {
                  Text(entry.name)
                    .fontSize(FileRowStyle.titleSize)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.entryInfo(entry).length > 0) {
                    Text(this.entryInfo(entry))
                      .fontSize(FileRowStyle.infoSize)
                      .fontColor($r('app.color.text_muted'))
                      .margin({ top: FileRowStyle.textGap })
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
              .padding({ left: FileRowStyle.horizontalPadding, right: FileRowStyle.horizontalPadding,
                top: FileRowStyle.verticalPadding, bottom: FileRowStyle.verticalPadding })

              if (index < this.entries.length - 1) {
                Divider()
                  .width('calc(100% - 16vp)')
                  .strokeWidth(0.5)
                  .color($r('app.color.divider'))
              }
            }
            .width('100%')
            .onAreaChange((_, area) => this.recordRowHitArea(entry, index, 'list', area))
            .onClick(() => this.handleFileEntryClick(entry))
            // 序列组：必须先长按成功，后面的 Pan 才会被识别。所以普通滑动
            // 碰不到它、列表照常滚动；只有长按之后再拖，才是滑动多选。
            .priorityGesture(
              GestureGroup(GestureMode.Sequence,
                // duration 比默认的 500ms 短一点，拖选起手更跟手。
                LongPressGesture({ repeat: false, duration: 380 })
                  .onAction((event: GestureEvent): void => {
                    if (this.selectionMode) {
                      this.beginDragSelection(entry, index)
                    } else {
                      this.showActionMenu(entry, event)
                    }
                  }),
                PanGesture({ direction: PanDirection.All, distance: 8 })
                  .onActionStart((event: GestureEvent): void => {
                    this.extendDragSelection(event)
                  })
                  .onActionUpdate((event: GestureEvent): void => {
                    this.extendDragSelection(event)
                  })
                  .onActionEnd((event: GestureEvent): void => {
                    this.extendDragSelection(event)
                    this.endDragSelection()
                  })
                  .onActionCancel((): void => {
                    this.cancelDragSelectionGesture()
                  })
              ).onCancel((): void => this.cancelDragSelectionGesture())
            )
          }
          .onAppear(() => {
            this.resolveFileListImageRotation(entry)
            this.loadEntryPreview(entry, this.previewPriority(index, 'list'))
            this.recordThumbnailMountedSource(entry, this.previewUri(entry), index, 'list')
            this.scheduleCachedDirectoryCount(entry)
          })
          .onDisAppear(() => {
            this.forgetRowHitArea(entry, 'list')
            this.recordThumbnailVisibility(entry, index, 'list', 0)
          })
        }, (entry: FileEntry) => entry.path)

      }
      .width('100%')
      .layoutWeight(1)
      .cachedCount(4)
      .onScrollIndex((start: number, end: number, _center: number): void => {
        this.fileVisibleStartIndex = Math.max(0, start)
        this.fileVisibleEndIndex = Math.max(this.fileVisibleStartIndex, end)
        this.updateTimelineFocusFromVisible(start, 'list')
      })
      .onScrollStart((): void => this.onFileContentScrollStart())
      .onScrollStop((): void => this.onFileContentScrollStop())
      .onDidScroll((): void => this.onDragSelectionContentScrolled())
      .onAreaChange((_, area) => this.recordFileScrollViewport('list', area))
      .onReachEnd(() => this.loadNextDirectoryPage())
      .contentEndOffset(this.floatingBarContentInset())
      .padding({ left: 0, right: 0 })
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      }
      if (!this.isBusy && ((this.fileViewMode === 'waterfall'
        && this.waterfallEntries.length === 0) || (this.fileViewMode !== 'waterfall'
        && this.entries.length === 0))) {
        Text(this.nasState === 'unavailable' || this.nasState === 'connecting' || this.offlineCacheMode
          ? '此目录暂无可用缓存，连接恢复后可重试'
          : (this.fileViewMode === 'waterfall'
          ? '当前目录没有图片' : '当前目录为空或没有可显示的文件')
          )
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
            .height(this.fileContentTopInset())
        }
        .width('100%')

        if (this.transferProgressText.length > 0 || this.transferProtectionError.length > 0 || this.transferNotificationBlocked) {
          ListItem() {
            Column({ space: 6 }) {
              if (this.transferProgressText.length > 0) {
                Text(this.transferProgressText).fontSize(14).fontColor($r('sys.color.font_primary'))
                  .width('100%').id('transfer-total-progress')
              }
              Text(this.transferNotificationBlocked ? '通知未开启，当前仅前台传输' : (this.transferProtectionError.length > 0 ? this.transferProtectionError :
                (this.transferProtectionActive ? '后台传输保护已开启，锁屏后可继续' : '正在申请后台传输保护'))
              )
                .fontSize(FileRowStyle.infoSize).fontColor($r('app.color.text_muted')).width('100%')
                .id('transfer-background-status')
              if (this.transferNotificationBlocked) {
                Button('开启通知').fontSize(13).height(36)
                  .onClick(() => { TransferBackgroundManager.shared().openNotificationSettings().catch(() => {}) })
                  .id('transfer-notifications-enable')
              }
            }.padding({ left: 20, right: 20, top: 8, bottom: 16 }).width('100%')
          }.width('100%')
        }
        if (this.transferDirection === 'upload') {
          ForEach(this.albumUploadJobs, (job: AlbumUploadJob) => {
            ListItem() {
              this.AlbumUploadTaskRow(job)
            }
            .width('100%')
            .id('album-upload-task:' + job.id)
            .onClick(() => this.activateAlbumUpload(job))
            .priorityGesture(LongPressGesture({ repeat: false }).onAction(() => {
              this.showAlbumUploadActions(job)
            }))
          }, (job: AlbumUploadJob): string => job.id)
        }
        if (this.visibleTransferTasks().length === 0 &&
          (this.transferDirection !== 'upload' || this.albumUploadJobs.length === 0)) {
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

        }
      }
      .width('100%')
      .layoutWeight(1)
      .contentEndOffset(this.floatingBarContentInset())
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

  private albumUploadStatus(job: AlbumUploadJob): string {
    if (job.state === 'building') { return '正在固定图片清单' }
    if (job.state === 'checking') { return '正在检查 NAS 已有图片' }
    if (job.state === 'paused') { return '已暂停' }
    if (job.state === 'waiting_wifi') { return '等待 WiFi' }
    if (job.state === 'waiting_server') { return '等待 NAS 恢复连接' }
    if (job.state === 'waiting_foreground') { return '回到应用前台后继续' }
    if (job.state === 'completed') { return '已完成' }
    if (job.state === 'failed') {
      return job.failed > 0 ? '失败 ' + job.failed.toString() + ' 张，点击重试' : (job.error || '上传失败，点击重试')
    }
    return job.state === 'running' ? '正在上传' : '等待上传'
  }

  private albumUploadTaskInfo(job: AlbumUploadJob): string {
    if (job.state === 'building') { return this.albumUploadStatus(job) }
    const count = job.state === 'completed' ? job.total.toString() + ' 张' :
      Math.min(job.total, job.uploaded + job.skipped).toString() + '/' + job.total.toString() + ' 张'
    return count + ' · ' + this.albumUploadStatus(job) +
      (job.skipped > 0 ? ' · 跳过 ' + job.skipped.toString() : '')
  }

  private albumUploadTaskProgress(job: AlbumUploadJob): number {
    if (job.state === 'completed') { return 100 }
    if (job.bytes <= 0) { return 0 }
    return Math.min(99, Math.max(0, (job.completedBytes + job.currentBytes) / job.bytes * 100))
  }

  private albumUploadTaskEntry(job: AlbumUploadJob): FileEntry {
    const entry = new FileEntry()
    entry.name = job.albumName; entry.path = job.destination; entry.isDirectory = true
    return entry
  }

  private openAlbumUploadDetails(job: AlbumUploadJob): void {
    this.albumDetailsId = job.id; this.albumDetailsName = job.albumName; this.showAlbumDetails = true
  }

  private activateAlbumUpload(job: AlbumUploadJob): void {
    if (job.state === 'completed' || job.state === 'building') { this.openAlbumUploadDetails(job); return }
    this.toggleAlbumUpload(job)
  }

  private albumUploadActionLabel(job: AlbumUploadJob): string {
    if (job.state === 'running' || job.state === 'checking' || job.state === 'queued') { return '暂停' }
    return job.state === 'failed' ? '重试失败项' : '继续'
  }

  @Builder
  AlbumUploadTaskRow(job: AlbumUploadJob): void {
    this.TransferTaskRow(this.albumUploadTaskEntry(job), job.albumName + ' · 图库文件夹',
      this.albumUploadTaskInfo(job), this.albumUploadTaskProgress(job),
      job.state === 'building' || job.state === 'checking' || (job.state === 'running' && job.bytes <= 0))
  }

  private async showAlbumUploadActions(job: AlbumUploadJob): Promise<void> {
    if (this.albumUploadActionsOpen) { return }
    this.albumUploadActionsOpen = true
    const canToggle = job.state !== 'completed' && job.state !== 'building'
    const canRemove = job.state !== 'building'
    const colour = this.isDarkTheme ? '#FFFFFFFF' : '#536174'
    const options: promptAction.ActionMenuOptions = {
      title: job.albumName + ' · 图库文件夹',
      buttons: canToggle ? [
        { text: '明细', color: colour }, { text: this.albumUploadActionLabel(job), color: colour },
        { text: '移除', color: '#D34D5C' }, { text: '取消', color: colour }
      ] : (canRemove ? [
        { text: '明细', color: colour }, { text: '移除', color: '#D34D5C' }, { text: '取消', color: colour }
      ] : [{ text: '明细', color: colour }, { text: '取消', color: colour }]),
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.THICK, false)
    }
    let selected = -1
    try { selected = (await this.getUIContext().getPromptAction().showActionMenu(options)).index }
    catch (_) { return } // Dismissing the native action menu performs no task action.
    finally { this.albumUploadActionsOpen = false }
    if (this.screen !== 'downloads' || !this.albumUploadJobs.some((value: AlbumUploadJob): boolean => value.id === job.id)) { return }
    if (selected === 0) { this.openAlbumUploadDetails(job) }
    else if (canToggle && selected === 1 && job.state !== 'completed' && job.state !== 'building') {
      await this.toggleAlbumUpload(job)
    } else if (canRemove && selected === (canToggle ? 2 : 1)) { await this.confirmRemoveAlbumUpload(job) }
  }

  private async confirmRemoveAlbumUpload(job: AlbumUploadJob): Promise<void> {
    HapticFeedback.warn()
    const result = await this.showTrackedDialog({ title: '移除图库文件夹上传记录？',
      message: '停止本批上传并移除任务记录，已上传到 NAS 的图片会保留。',
      buttons: [{ text: '取消', color: this.isDarkTheme ? '#FFFFFFFF' : '#536174' }, { text: '移除', color: '#D34D5C' }],
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false) })
    if (result.index !== 1) { return }
    try { await this.albumUpload.remove(job.id) }
    catch (error) { this.showImmersiveToast((error as Error).message || '移除失败，请恢复 NAS 连接后重试') }
  }

  private async toggleAlbumUpload(job: AlbumUploadJob): Promise<void> {
    try {
      if (job.state !== 'running' && job.state !== 'checking' && job.state !== 'queued') {
        await new LocalAlbumSource(getContext(this) as common.UIAbilityContext).requestPermission()
      }
      await this.albumUpload.toggle(job.id)
    } catch (error) { this.showImmersiveToast((error as Error).message || '继续上传失败') }
  }

  @Builder
  AlbumUploadOverlay(): void {
    Column() {}.width(0).height(0)
      .bindContentCover($$this.showAlbumPicker, this.AlbumUploadPickerContent, {
        modalTransition: ModalTransition.DEFAULT, enableSafeArea: false,
        backgroundColor: Color.Transparent,
        onDisappear: () => {
          // Open the next modal only after the native picker has released its input layer.
          if (!this.albumConfirmationPending) { return }
          this.albumConfirmationPending = false
          if (this.albumUploadContextValid()) { this.showAlbumUpload = true }
        }
      })
    Column() {}.width(0).height(0)
      .bindSheet($$this.showAlbumUpload, this.AlbumUploadOverlayContent, {
        height: SheetSize.FIT_CONTENT, dragBar: false, showClose: false,
        radius: { topLeft: TaskPanelStyle.corner, topRight: TaskPanelStyle.corner },
        backgroundColor: $r('app.color.task_panel_background'),
        onWillDismiss: (action: DismissSheetAction): void => {
          if (!this.albumUploadStarting) { action.dismiss(); this.showAlbumUpload = false }
        },
        onDisappear: () => {
          if (!this.albumReselectPending) { return }
          this.albumReselectPending = false
          if (this.albumUploadContextValid()) { this.showAlbumPicker = true }
        }
      })
    Column() {}.width(0).height(0)
      .bindSheet($$this.showAlbumDetails, this.AlbumUploadDetailsContent, {
        height: '85%', dragBar: true, showClose: true,
        systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.THICK, false)
      })
  }

  @Builder
  AlbumUploadPickerContent(): void {
    AlbumUploadPicker({ visible: $showAlbumPicker, safeTop: this.topSafeInset(), safeBottom: this.bottomSafeInset(),
      onSelected: (album: LocalImageAlbum): void => {
        this.albumUploadSelection = album
        this.albumConfirmationPending = this.albumUploadContextValid()
        this.showAlbumPicker = false
      } })
  }

  private albumUploadContextValid(): boolean {
    return this.screen === 'files' && this.currentPath === this.albumUploadDestination &&
      this.currentRootType === this.albumUploadRootType && this.repository.cacheScopeHash() === this.albumUploadScope
  }

  @Builder
  AlbumUploadOverlayContent(): void {
    AlbumUploadSheet({ visible: $showAlbumUpload, album: this.albumUploadSelection,
      destination: this.albumUploadDestination, starting: this.albumUploadStarting,
      contentMaxHeight: Math.max(80, this.pageHeightVp * 0.85 - this.topSafeInset() - this.bottomSafeInset() -
        TaskPanelStyle.compactChromeHeight),
      onReselect: (): void => {
        if (this.albumUploadStarting) { return }
        this.albumReselectPending = true; this.showAlbumUpload = false
      },
      onStart: async (album: LocalImageAlbum): Promise<void> => {
        if (this.albumUploadStarting || !this.albumUploadContextValid()) {
          throw new Error('目标文件夹已变化，请重新选择')
        }
        const destination = this.albumUploadDestination
        const rootType = this.albumUploadRootType
        const scope = this.albumUploadScope
        this.albumUploadStarting = true
        try {
          await this.albumUpload.create(album, destination, rootType, scope, false)
          this.showAlbumUpload = false
          this.transferDirection = 'upload'
          this.openDownloads()
          this.showImmersiveToast('已创建图片文件夹上传任务')
        } finally { this.albumUploadStarting = false }
      } })
  }

  @Builder
  AlbumUploadDetailsContent(): void {
    AlbumUploadDetails({ manager: this.albumUpload, batchId: this.albumDetailsId, albumName: this.albumDetailsName,
      total: this.albumUploadDetailsJob().total, failedCount: this.albumUploadDetailsJob().failed,
      batchState: this.albumUploadDetailsJob().state, currentName: this.albumUploadDetailsJob().currentName,
      currentBytes: this.albumUploadDetailsJob().currentBytes, currentSize: this.albumUploadDetailsJob().currentSize,
      revision: this.albumUploadDetailsRevision() })
  }

  private albumUploadDetailsJob(): AlbumUploadJob {
    return this.albumUploadJobs.find((job: AlbumUploadJob): boolean => job.id === this.albumDetailsId) ?? new AlbumUploadJob()
  }

  private albumUploadDetailsRevision(): string {
    const job = this.albumUploadDetailsJob()
    return job.state + ':' + job.total.toString() + ':' + job.uploaded.toString() + ':' +
      job.skipped.toString() + ':' + job.failed.toString() + ':' + job.currentName
  }

  @Builder
  TransferDirectionControl(): void {
    // Keep the official selector inside the existing Navigation title subtree:
    // one material backplate, native selection/drag animation and accessibility.
    CapsuleSegmentButtonV2({
      items: this.transferDirectionItems,
      selectedIndex: this.transferDirection === 'upload' ? 1 : 0,
      $selectedIndex: (index: number): void => { this.transferDirection = index === 1 ? 'upload' : 'download' },
      itemFontSize: LengthMetrics.fp(HeaderStyle.actionSize), itemSelectedFontSize: LengthMetrics.fp(HeaderStyle.actionSize),
      // Match the home header's 40 vp controls: a 36 vp item inside a 2 vp frame.
      buttonMinHeight: LengthMetrics.vp(HeaderStyle.controlHeight), itemMinHeight: LengthMetrics.vp(HeaderStyle.controlHeight - 4),
      buttonPadding: LengthMetrics.vp(2),
      itemPadding: { top: LengthMetrics.vp(4), bottom: LengthMetrics.vp(4),
        start: LengthMetrics.vp(12), end: LengthMetrics.vp(12) },
      backgroundSystemMaterial: this.transferControlMaterial()
    })
      .width(132)
      .height(HeaderStyle.controlHeight)
      .id('transfer-direction-control')
  }

  private transferControlMaterial(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN,
      applyShadow: false, colorInvert: true, interactive: true, lightEffect: { color: '#66FFFFFF' } })
  }

  private async selectImportSource(source: string): Promise<void> {
    if (source === 'folder') { this.openCreateFolder(); return }
    if (this.currentPath.length === 0 || this.importSelecting || this.isBusy || this.showAlbumPicker || this.showAlbumUpload) { return }
    if (source === 'album') {
      const destination = this.currentPath
      const rootType = this.currentRootType
      const scope = this.repository.cacheScopeHash()
      await this.ensureDownloadState()
      if (this.currentPath !== destination || this.repository.cacheScopeHash() !== scope || this.screen !== 'files') { return }
      this.albumUploadDestination = destination
      this.albumUploadRootType = rootType
      this.albumUploadScope = scope
      this.albumConfirmationPending = false
      this.albumReselectPending = false
      this.showAlbumPicker = true
      return
    }
    const target = this.currentPath
    const scope = this.repository.cacheScopeHash()
    this.importSelecting = true
    try {
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
      const confirmation = await this.showTrackedDialog({ title: '上传 ' + uris.length + ' 个文件',
        message: '上传到：' + target + '\n保留原文件，同名文件跳过。',
        buttons: [{ text: '取消', color: '#536174' }, { text: '上传', color: '#2E6BFF' }],
        systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false) })
      if (confirmation.index !== 1) { return }
      // Opening a system picker does not depend on the transfer queues. Wait
      // for them only after the user has selected files and confirmed upload.
      await this.ensureDownloadState()
      // Record the direction so 传输 opens on the uploads tab when the user
      // goes there, but stay put. The files were picked in THIS directory, and
      // dragging the user off to the transfer page for something that runs in
      // the background loses their place for no reason.
      this.transferDirection = 'upload'
      for (const uri of uris) { await this.uploadQueue.enqueue(uri, target, scope) }
      // The file page does not render statusText, so without this the upload
      // would start with nothing on screen to say so.
      this.showImmersiveToast('已加入上传：' + uris.length.toString() + ' 个文件')
    } catch (error) { this.reportError(error as Object, '文件导入失败') }
    finally { this.importSelecting = false }
  }

  @Builder
  DownloadTaskRow(task: DownloadTaskRecord): void {
    this.TransferTaskRow(this.downloadTaskEntry(task), task.name, this.downloadTaskInfo(task),
      this.downloadTaskProgress(task), task.status === 'downloading' && task.size <= 0)
  }

  @Builder
  TransferTaskRow(entry: FileEntry, title: string, info: string, progress: number, loading: boolean): void {
    TransferTaskListRow({ title: title, info: info, progress: progress, loading: loading }) {
      this.FileLeadingVisual(entry)
    }
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
            .fontSize(FileRowStyle.titleSize)
            .fontColor([$r('sys.color.icon_primary')])
          Text(this.formatSpeed(this.downloadSpeedBytesPerSecond))
            .fontSize(10)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
        }
        .justifyContent(FlexAlign.Center)
      }
      .width(64)
      .height(64)
      .borderRadius(32)
      .systemMaterial(this.adaptiveControlMaterial(uiMaterial.ImmersiveStyle.THIN, true, '#442E6BFF'))
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

  /**
   * 网格列数按可用宽度算：目标格子约 94vp（和系统相册一个量级）。
   * 手机 376vp -> 4 列；平板会自动变多，窄屏也不会挤出半格。
   */
  private fileGridColumnCount(): number {
    const width = this.pageWidthVp
    if (!(width > 0)) {
      return 2
    }
    // 目标格子宽 80–140vp（文件的网格：要放下文件名与勾选角标；图片网格同一档，
    // 保持两者列数一致）。手机 376vp -> 4 列（与以前一致），平板竖屏 -> 上限 10 列。
    return Math.max(2, Math.min(10, Math.floor(width / 80)))
  }

  /** 瀑布流列数：目标列宽 240vp（区间 240–360vp）。列宽直接决定图片高度，所以比网格大一档。 */
  private waterfallColumnCount(): number {
    const width = this.pageWidthVp - 20
    if (!(width > 0)) {
      return 2
    }
    return Math.max(2, Math.min(5, Math.floor(width / 240)))
  }

  private waterfallColumnsTemplate(): string {
    const count = this.waterfallColumnCount()
    let template = ''
    for (let i = 0; i < count; i++) {
      template += (i === 0 ? '' : ' ') + '1fr'
    }
    return template
  }

  private fileGridColumns(): string {
    const count = this.fileGridColumnCount()
    let template = ''
    for (let i = 0; i < count; i++) {
      template += (i === 0 ? '' : ' ') + '1fr'
    }
    return template
  }

  @Builder
  GridItemThumbnail(entry: FileEntry, index: number, state: GridImageState): void {
    Stack({ alignContent: Alignment.Center }) {
      if (this.shouldReplaceViewerTransitionSource(entry)) {
        Blank()
          .width('100%')
          .height('100%')
      } else if (state.available) {
        if (EXPERIMENT_GRID_BLANK) {
          // 实验 A：同尺寸占位，去掉 Image 子树与图片解码。
          // ⚠️ 必须 hitTestBehavior(None)：Blank 默认会吃掉触摸。
          Blank()
            .width('100%')
            .height('100%')
            .backgroundColor('#EFEFF3')
            .hitTestBehavior(HitTestMode.None)
        } else if (state.sourceWidth > 0) {
          // 实验 B′：指定解码尺寸。宽高严格按源图比例（gridSourceSizeFor 负责），
          // 绝不传正方形（会改比例），也绝不超过源尺寸（会解码失败）。
          Image(state.source)
            .width('100%')
            .height('100%')
            .sourceSize({ width: state.sourceWidth, height: state.sourceHeight })
            .orientation(state.orientation)
            .objectFit(ImageFit.Cover)
            .geometryTransition(state.transitionId)
            .syncLoad(state.syncLoad)
            .onComplete((event?: ViewerImageCompleteEvent): void =>
              this.recordThumbnailComplete(entry, this.previewUri(entry), index, 'grid', event))
        } else {
          Image(state.source)
            .width('100%')
            .height('100%')
            .orientation(state.orientation)
            .objectFit(ImageFit.Cover)
            .geometryTransition(state.transitionId)
            .syncLoad(state.syncLoad)
            .onComplete((event?: ViewerImageCompleteEvent): void =>
              this.recordThumbnailComplete(entry, this.previewUri(entry), index, 'grid', event))
        }
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
    // 固定 1:1，和系统相册一致：不论屏幕多宽，格子永远是正方形。
    .aspectRatio(1)
    .borderRadius(0)
    // ⚠️ 这里绝不能加 .clip(true)：
    // ImageFit.Cover 的官方语义是「两边都大于或等于显示边界，超出部分被截断」；
    // 本 Stack 的其它子节点是固定 44vp 的文件夹图标和 Blank，都不会溢出。
    // 外层再加 clip 只会给每个格子生成一个离屏图层。
    .onAreaChange((_, area) => {
      this.recordThumbnailArea(entry, index, 'grid', area)
      this.recordRowHitArea(entry, index, 'grid', area)
    })
    .onVisibleAreaChange([0.0, 0.999],
      (_isExpanding: boolean, ratio: number): void => {
        this.recordThumbnailVisibility(entry, index, 'grid', ratio)
        this.noteVisibleEntryForLoad(entry, ratio)
      })
  }

  @Builder
  GridFileList(): void {
    Grid(this.fileListScroller, this.fileGridOptions) {
      LazyForEach(this.fileEntryDataSource, (entry: FileEntry, index: number) => {
        GridItem() {
          // 勾选角标放右下角（多选态）。
          Stack({ alignContent: Alignment.BottomEnd }) {
            Column({ space: 0 }) {
              // ⚠️ 这里必须【内联】而不是提取成带参数的 @Builder：
              // @Builder 传入新建对象会让这一层每帧重建，打断 geometryTransition
              // 的共享元素转场（实测"过场动画消失"）。回到内联后动画恢复。
              Stack({ alignContent: Alignment.Center }) {
                if (this.shouldReplaceViewerTransitionSource(entry)) {
                  Blank()
                    .width('100%')
                    .height('100%')
                } else if (EXPERIMENT_GRID_FIXED_SOURCE && !entry.isDirectory) {
                  // 实验 D：Image 组件与节点结构完全不变，只把 source 换成
                  // 「同一个、已缓存的本地小图」。这样只消除真实 URI / previewUri /
                  // getUriFromPath / 每文件不同 source / thumbnail 解码，
                  // 用来区分「Image 节点本身贵」还是「处理真实 source 贵」。
                  Image($r('app.media.startIcon'))
                    .width('100%')
                    .height('100%')
                    .orientation(ImageRotateOrientation.UP)
                    .objectFit(ImageFit.Cover)
                    .geometryTransition(this.fileImageTransitionId(entry, 'grid'))
                } else if (EXPERIMENT_R2_THUMB_CELL && !entry.isDirectory) {
                  // R2 原型：文件类缩略图交给独立子组件。
                  // 依赖 entry.previewRevision（@ObjectLink）驱动局部重算，
                  // 不再需要"整树重跑"来顺带刷新这一格。
                  GridThumbCell({ entry: entry, bridge: this.gridThumbBridge, index: index })
                } else if (this.fileImageSourceAvailable(entry, 'grid')) {
                  if (this.gridSourceWidth(entry) > 0) {
                    // 实验 B′/F：指定解码尺寸。
                    // ⚠️ 宽高严格按源图比例（gridSourceSizeFor 负责），
                    //    绝不传正方形（会改比例），也绝不超过源尺寸（会解码失败）。
                    Image(this.fileImageSource(entry, 'grid'))
                      .width('100%')
                      .height('100%')
                      .sourceSize({
                        width: this.gridSourceWidth(entry),
                        height: this.gridSourceHeight(entry)
                      })
                      .orientation(this.fileImageSourceOrientation(entry, 'grid'))
                      .objectFit(ImageFit.Cover)
                      .geometryTransition(this.fileImageTransitionId(entry, 'grid'))
                      .syncLoad(this.fileImageShouldSyncLoad(entry))
                      .onComplete((event?: ViewerImageCompleteEvent): void => {
                        this.imageTelemetry.recordPipelineComplete(entry.path, 'grid')
                        this.recordThumbnailComplete(entry, this.previewUri(entry), index,
                          'grid', event)
                      })
                      .onError((): void => {
                        this.imageTelemetry.recordPipelineError(entry.path, 'grid')
                      })
                  } else {
                    Image(this.fileImageSource(entry, 'grid'))
                      .width('100%')
                      .height('100%')
                      .orientation(this.fileImageSourceOrientation(entry, 'grid'))
                      .objectFit(ImageFit.Cover)
                      .geometryTransition(this.fileImageTransitionId(entry, 'grid'))
                      .syncLoad(this.fileImageShouldSyncLoad(entry))
                      .onComplete((event?: ViewerImageCompleteEvent): void => {
                        this.imageTelemetry.recordPipelineComplete(entry.path, 'grid')
                        this.recordThumbnailComplete(entry, this.previewUri(entry), index,
                          'grid', event)
                      })
                      .onError((): void => {
                        this.imageTelemetry.recordPipelineError(entry.path, 'grid')
                      })
                  }
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
              // 固定 1:1，和系统相册一致：不论屏幕多宽，格子永远是正方形。
              .aspectRatio(1)
              .borderRadius(0)
              .onAreaChange((_, area) => {
                this.recordThumbnailArea(entry, index, 'grid', area)
                this.recordRowHitArea(entry, index, 'grid', area)
              })
              .onVisibleAreaChange([0.0, 0.999],
                (_isExpanding: boolean, ratio: number): void => {
                  this.recordThumbnailVisibility(entry, index, 'grid', ratio)
                  this.noteVisibleEntryForLoad(entry, ratio)
                  if (!entry.isDirectory && this.isImage(entry) && ratio > 0.05) {
                    const isReady = this.fileImageSourceAvailable(entry, 'grid')
                    this.imageTelemetry.recordVisibleEnter(entry.path, isReady)
                  }
                })

              // 图片/视频不再占文字位（紧凑方块才好看）；文件夹仍保留名字，
              // 否则网格里分不出哪个是文件夹。
              if (entry.isDirectory) {
                Text(entry.name)
                  .fontSize(11)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .margin({ top: 2 })
              }
            }
            .width('100%')
            .padding(1)
            this.VideoTransferIndicator(entry)
            if (this.selectionMode) {
              Row() {
                this.SelectionCheckbox(entry)
              }
                .margin({ bottom: 6, right: 6 })
            }
          }
          // 顶部留白，照抄瀑布流的做法：加在【条目】的 margin 上，不是容器的 padding。
          // 容器的 padding 会变成一条裁切线（图滚到那儿就整块消失 ✗）；
          // margin 属于内容本身，会跟着一起滚走 ✓ —— 刚打开时首行落在标题下方能点到，
          // 往上滑时又仍能钻进页头底下继续露一截。
          .margin({ top: index < this.fileGridColumnCount() ? this.fileContentTopInset() : 0 })
          .onClick(() => this.handleFileEntryClick(entry))
          // 与文件列表同一套：序列组要求先长按成功，后面的 Pan 才参与，
          // 普通滑动仍然是网格滚动；长按后拖动才是连续多选。
          .priorityGesture(
            GestureGroup(GestureMode.Sequence,
              LongPressGesture({ repeat: false, duration: 380 })
                .onAction((event: GestureEvent): void => {
                  if (this.selectionMode) {
                    this.beginDragSelection(entry, index)
                  } else {
                    this.showActionMenu(entry, event)
                  }
                }),
              PanGesture({ direction: PanDirection.All, distance: 8 })
                .onActionStart((event: GestureEvent): void => {
                  this.extendDragSelection(event)
                })
                .onActionUpdate((event: GestureEvent): void => {
                  this.extendDragSelection(event)
                })
                .onActionEnd((event: GestureEvent): void => {
                  this.extendDragSelection(event)
                  this.endDragSelection()
                })
                .onActionCancel((): void => {
                  this.cancelDragSelectionGesture()
                })
            ).onCancel((): void => this.cancelDragSelectionGesture())
          )
        }
        .onAppear(() => {
          this.resolveFileListImageRotation(entry)
          this.loadEntryPreview(entry, this.previewPriority(index, 'grid'))
          this.recordThumbnailMountedSource(entry, this.previewUri(entry), index, 'grid')
          this.scheduleCachedDirectoryCount(entry)
          if (!entry.isDirectory && this.isImage(entry)) {
            this.imageTelemetry.recordPipelineStart(entry.path, 'grid')
            this.returnPerfSession.recordItemMounted(entry.path)
          }
        })
        .onDisAppear(() => {
          this.forgetRowHitArea(entry, 'grid')
          this.recordThumbnailVisibility(entry, index, 'grid', 0)
        })
      }, (entry: FileEntry) => entry.path)
    }
    .id('main-grid')
    .columnsTemplate(this.fileGridColumns())
    .columnsGap(1)
    .rowsGap(1)
    // 每侧缓存的条目数 = cachedCount × 列数。官方 grid.d.ts 原文：
    // "The number of the grid items to be cached before and after the currently displayed
    //  one equals the value of cachedCount multiplied by the number of columns."
    // 注：cachedCount 的单位是「行」而不是「条目」。
    // 取 16 是保守值 —— 双参重载 cachedCount(count, show) 的文档注明上限为 16
    // （单参重载未注明上限）。此前为 32，即 32 × 4 列 = 上下各 128 个条目，
    // 缓存量偏大、内存占用高。
    .cachedCount(EXPERIMENT_GRID_CACHED_COUNT)
    // 诊断：触摸是否到达列表容器。用于区分两种情况 ——
    //   有 [TouchTrace] 但没有 [TapTrace] >>> click  → UI 收到了触摸但 click 没触发（手势/命中问题）
    //   连 [TouchTrace] 都没有                        → 被上层覆盖层挡住了
    .onTouch((event: TouchEvent): void => {
      if (this.closeSessionActive && event.type === TouchType.Down && !this.sessionChildDownLogged) {
        const point = event.touches.length > 0 ? event.touches[0] : null
        const ptrId = point !== null ? point.id : -1
        if (this.sessionTrackedPointerId === -1 || ptrId === this.sessionTrackedPointerId) {
          this.sessionChildDownLogged = true
          const dt = this.getMonotonicNow() - this.closeAnimFinishMonotonic
          const winStr = point !== null ? ' win=(' + Math.round(point.windowX).toString() + ',' + Math.round(point.windowY).toString() + ')' : ''
          const locStr = point !== null ? ' loc=(' + Math.round(point.x).toString() + ',' + Math.round(point.y).toString() + ')' : ''
          console.info('[TouchChain] #' + this.closeSessionId.toString() +
            ' ChildDown +' + dt.toString() + 'ms ptr=' + ptrId.toString() +
            winStr + locStr)
        }
      }
      if (TAP_TRACE && event.type === TouchType.Down) {
        const point = event.touches.length > 0 ? event.touches[0] : null
        console.info('[TouchTrace] grid-down x=' +
          (point === null ? -1 : Math.round(point.x)).toString() + ' y=' +
          (point === null ? -1 : Math.round(point.y)).toString())
      }
    })
    .parallelGesture(
      PanGesture({ direction: PanDirection.Vertical, distance: 4 })
        .onActionStart((event: GestureEvent): void => {
          if (this.closeSessionActive && !this.sessionPanStartLogged) {
            this.sessionPanStartLogged = true
            const ptrId = event.fingerList.length > 0 ? event.fingerList[0].id : -1
            const dt = this.getMonotonicNow() - this.closeAnimFinishMonotonic
            const f = event.fingerList.length > 0 ? event.fingerList[0] : null
            const winStr = f !== null ? ' win=(' + Math.round(f.globalX).toString() + ',' + Math.round(f.globalY).toString() + ')' : ''
            console.info('[TouchChain] #' + this.closeSessionId.toString() +
              ' PanStart +' + dt.toString() + 'ms ptr=' + ptrId.toString() + winStr)
          }
        })
        .onActionUpdate((event: GestureEvent): void => {
          if (this.closeSessionActive && this.sessionPanStartLogged && !this.sessionFirstPanUpdateLogged) {
            this.sessionFirstPanUpdateLogged = true
            const dt = this.getMonotonicNow() - this.closeAnimFinishMonotonic
            console.info('[TouchChain] #' + this.closeSessionId.toString() +
              ' FirstPanUpdate +' + dt.toString() + 'ms dy=' + Math.round(event.offsetY).toString())
          }
        })
    )
    .onScrollIndex((first: number, last: number): void => {
      this.fileVisibleStartIndex = Math.max(0, first)
      this.fileVisibleEndIndex = Math.max(this.fileVisibleStartIndex, last)
      this.updateTimelineFocusFromVisible(first, 'grid')
    })
    .onScrollStart((): void => this.onFileContentScrollStart())
    .onScrollStop((): void => this.onFileContentScrollStop())
    .onDidScroll((): void => this.onDragSelectionContentScrolled())
    .onAreaChange((_, area) => this.recordFileScrollViewport('grid', area))
    .onReachEnd(() => this.loadNextDirectoryPage())
    .width('100%')
    .layoutWeight(1)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .contentEndOffset(this.floatingBarContentInset())
    .padding({ left: 0, right: 0, top: 0, bottom: 0 })
  }

  @Builder
  WaterfallPreviewImage(entry: FileEntry, index: number): void {
    if (this.waterfallAspectRatioReady(entry)) {
      Image(this.fileImageSource(entry, 'waterfall'))
        .width('100%')
        .height('100%')
        .sourceSize(this.waterfallSourceSize(entry))
        .orientation(this.fileImageSourceOrientation(entry, 'waterfall'))
        .objectFit(ImageFit.Contain)
        .geometryTransition(this.fileImageTransitionId(entry, 'waterfall'))
        .syncLoad(this.fileImageShouldSyncLoad(entry))
        .opacity(1)
        .onComplete((event?: ViewerImageCompleteEvent): void => {
          this.recordThumbnailComplete(entry, this.thumbnailSurfaceUri(entry, 'waterfall'), index,
            'waterfall', event)
          this.completeWaterfallDecode(entry)
        })
        .onError(() => this.failWaterfallDecode(entry))
    } else {
      // Do not pass a provisional square sourceSize. ArkUI can reuse the
      // decoded raster while WaterFlow is recycling the item, so the first
      // decode must wait for Image Kit geometry instead of seeding a 1:1
      // target that belongs to the temporary FlowItem.
      Image(this.fileImageSource(entry, 'waterfall'))
        .width('100%')
        .height('100%')
        .orientation(this.fileImageSourceOrientation(entry, 'waterfall'))
        .objectFit(ImageFit.Contain)
        .geometryTransition(this.fileImageTransitionId(entry, 'waterfall'))
        .syncLoad(this.fileImageShouldSyncLoad(entry))
        .opacity(0)
        .onComplete((event?: ViewerImageCompleteEvent): void => {
          this.recordThumbnailComplete(entry, this.thumbnailSurfaceUri(entry, 'waterfall'), index,
            'waterfall', event)
          this.completeWaterfallDecode(entry)
        })
        .onError(() => this.failWaterfallDecode(entry))
    }
  }

  @Builder
  FileContentEndSpace(): void {
    Row().width('100%').height(this.floatingBarContentInset())
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
  }

  @Builder
  WaterfallFileList(): void {
    WaterFlow({
      scroller: this.waterfallScroller,
      // WaterFlow has no contentEndOffset; its scrollable footer uses the
      // same inset as List/Grid without changing the FlowItem indexes.
      footer: () => { this.FileContentEndSpace() },
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
                if (EXPERIMENT_R2_WATERFALL_CELL) {
                  // R2 推广：图片 + LoadingProgress 整块交给独立子组件，
                  // 依赖 entry.previewRevision（@ObjectLink）做单条精准刷新。
                  WaterfallThumbCell({ entry: entry, bridge: this.waterfallThumbBridge, index: index })
                } else {
                  Stack({ alignContent: Alignment.Center }) {
                    if (this.fileImageSourceAvailable(entry, 'waterfall')) {
                      this.WaterfallPreviewImage(entry, index)
                    }
                    if (!this.fileImageSourceAvailable(entry, 'waterfall') ||
                      !this.waterfallAspectRatioReady(entry)) {
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
              }
              .width('100%')
              .height('100%')
            }
            if (this.selectionMode) {
              FileSelectionOutline({ selection: this.fileSelection.stateFor(entry.path) })
            }
            this.VideoTransferIndicator(entry)
          }
          .width('100%')
          .aspectRatio(this.waterfallAspectRatio(entry))
          .backgroundColor('#12000000')
          .borderRadius(10)
          .onAreaChange((_, area) => {
            this.recordThumbnailArea(entry, index, 'waterfall', area)
            this.recordRowHitArea(entry, index, 'waterfall', area)
          })
          .onVisibleAreaChange([0.0, 0.999],
            (_isExpanding: boolean, ratio: number): void =>
              this.recordThumbnailVisibility(entry, index, 'waterfall', ratio))
          .onClick(() => this.handleFileEntryClick(entry))
          .priorityGesture(
            GestureGroup(GestureMode.Sequence,
              LongPressGesture({ repeat: false, duration: 380 })
                .onAction((event: GestureEvent): void => {
                  if (this.selectionMode) {
                    this.beginDragSelection(entry, index)
                  } else {
                    this.showActionMenu(entry, event)
                  }
                }),
              PanGesture({ direction: PanDirection.All, distance: 8 })
                .onActionStart((event: GestureEvent): void => this.extendDragSelection(event))
                .onActionUpdate((event: GestureEvent): void => this.extendDragSelection(event))
                .onActionEnd((event: GestureEvent): void => {
                  this.extendDragSelection(event)
                  this.endDragSelection()
                })
                .onActionCancel((): void => this.cancelDragSelectionGesture())
            ).onCancel((): void => this.cancelDragSelectionGesture())
          )
        }
        // WaterFlow does not use the top padding here as the scroll-content
        // origin on this device. Put the breathing room on the first row's
        // FlowItems instead; later rows remain unchanged and can still scroll
        // naturally under the common TopFileOverlay, just like list/grid.
        .margin({ top: index < this.waterfallColumnCount() ? this.fileContentTopInset() : 0 })
        .onAppear(() => {
          this.resolveFileListImageRotation(entry)
          this.markWaterfallVisible(entry, true)
          this.recordThumbnailMountedSource(entry, this.thumbnailSurfaceUri(entry, 'waterfall'), index,
            'waterfall')
          this.loadEntryPreview(entry, this.previewPriority(index, 'waterfall'))
          this.enqueueWaterfallPreviewGeometry(entry, index)
          this.enqueueWaterfallOriginal(entry, index)
        })
        .onDisAppear(() => {
          this.forgetRowHitArea(entry, 'waterfall')
          this.markWaterfallVisible(entry, false)
          this.recordThumbnailVisibility(entry, index, 'waterfall', 0)
        })
      }, (entry: FileEntry) => entry.path)
    }
    .columnsTemplate(this.waterfallColumnsTemplate())
    .columnsGap(8)
    .rowsGap(8)
    // Only visible FlowItems are mounted. Original-file downloads are
    // prefetched separately and are limited by waterfallDownloadQueue.
    .cachedCount(0)
    .onScrollIndex((first: number, last: number): void => {
      this.waterfallVisibleStartIndex = Math.max(0, first)
      this.waterfallVisibleEndIndex = Math.max(this.waterfallVisibleStartIndex, last)
      this.updateTimelineFocusFromVisible(first, 'waterfall')
      this.prefetchWaterfallRange(first, last)
    })
    .onScrollStart((): void => this.onFileContentScrollStart())
    .onScrollStop((): void => this.onFileContentScrollStop())
    .onDidScroll((): void => this.onDragSelectionContentScrolled())
    .onReachEnd(() => this.loadNextDirectoryPage())
    .onAreaChange((_, area) => {
      this.recordFileScrollViewport('waterfall', area)
      if (typeof area.width === 'number' && area.width > 0) {
        const columns = this.waterfallColumnCount()
        // 20 = 左右内边距，8 = 列间距；(columns - 1) 个间距
        this.waterfallColumnWidthVp =
          Math.max(1, (area.width - 20 - (columns - 1) * 8) / columns)
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
  FileContentSnapshot(snapshotEntries: FileEntry[], snapshotMode: FileViewMode): void {
    Column() {
      if (snapshotMode === 'grid') {
        Grid(this.transitionScroller) {
          LazyForEach(this.transitionFileEntryDataSource, (entry: FileEntry, index: number) => {
            GridItem() {
              // 与真实网格条目的 Column({ space: 0 }) 对齐（名字靠 margin top:2 定位 ✗ 不用 space）
              Column({ space: 0 }) {
                Stack({ alignContent: Alignment.Center }) {
                  if (this.fileImageSourceAvailable(entry, 'grid')) {
                    Image(this.fileImageSource(entry, 'grid'))
                      .width('100%')
                      .height('100%')
                      .orientation(this.fileImageSourceOrientation(entry, 'grid'))
                      .objectFit(ImageFit.Cover)
                      .borderRadius(0)
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
                .height('100%')
                .aspectRatio(1)
                .clip(true)

                // 与真实网格（GridFileList）逐字对齐：只有文件夹显示名字、11 号、top 2。
                // 之前这里对所有条目都显示名字且是 14 号，转场时字会跳一下 ✗
                if (entry.isDirectory) {
                  Text(entry.name)
                    .fontSize(11)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .margin({ top: 2 })
                }
              }
              .width('100%')
              .padding(1)
            }
            // 与真实网格（GridFileList）保持完全一样的顶部留白。缺了它，转场快照会
            // 整体偏高约一个内容顶距，动画看起来就是"内容先往上跳一下再打开"。
            .margin({ top: index < this.fileGridColumnCount() ? this.fileContentTopInset() : 0 })
          }, (entry: FileEntry, _index: number) => entry.path)
        }
        // 与真实网格（GridFileList 的 .columnsGap(1)/.rowsGap(1)）保持一致。
        // 之前这里是 2，每个格子差 1vp、四列累积后整体几何不同，转场会挪一下 ✗
        .columnsTemplate(this.fileGridColumns())
        .columnsGap(1)
        .rowsGap(1)
        .width('100%')
        .layoutWeight(1)
        .contentEndOffset(this.floatingBarContentInset())
        .padding({ left: 0, right: 0, top: 0, bottom: 0 })
      } else {
        List({ space: 0, scroller: this.transitionScroller }) {
        ListItem() {
          Row()
            .width('100%')
            .height(this.topSafeInset() + 76)
        }
        .width('100%')

        LazyForEach(this.transitionFileEntryDataSource, (entry: FileEntry, index: number) => {
          ListItem() {
            Column() {
              Row() {
                Row() {
                  this.FileLeadingVisual(entry)
                }
                .margin({ right: FileRowStyle.leadingGap })
                Column() {
                  Text(entry.name)
                    .fontSize(FileRowStyle.titleSize)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.entryInfo(entry).length > 0) {
                    Text(this.entryInfo(entry))
                      .fontSize(FileRowStyle.infoSize)
                      .fontColor($r('app.color.text_muted'))
                      .margin({ top: FileRowStyle.textGap })
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
              .padding({ left: FileRowStyle.horizontalPadding, right: FileRowStyle.horizontalPadding,
                top: FileRowStyle.verticalPadding, bottom: FileRowStyle.verticalPadding })

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
        .contentEndOffset(this.floatingBarContentInset())
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      }
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
      // 标题栏的高度就是它的裁切边界。搜索时下面还要挂「本级/跨级」那排 chip
      // （位于 safeTop + 76、高 36vp，伸到 safeTop + 112）。
      // 搜索时固定使用 136，避免输入字符时因条件判断导致高度跳变，进而重建标题栏引发软键盘强制收起。
      .title({
        builder: this.TopFileOverlay,
        height: this.topSafeInset() + (this.showSearch ? HeaderStyle.searchOverlayHeight : HeaderStyle.overlayHeight)
      }, {
        barStyle: BarStyle.STACK,
        paddingStart: LengthMetrics.vp(0),
        paddingEnd: LengthMetrics.vp(0),
        backgroundColor: Color.Transparent
      })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .width('100%')
      // 这层 Navigation 的高度就是标题区的裁切边界，同时决定内容区从哪里开始。
      // 搜索时固定 136，平时为 94。全程高度恒定，保证输入时不发生布局重建与失焦。
      .height(this.topSafeInset() + (this.showSearch ? HeaderStyle.searchOverlayHeight : HeaderStyle.overlayHeight))
      .backgroundColor(Color.Transparent)
      .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  TopFileOverlay(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      Row()
        .width('100%')
        .height(this.topSafeInset() + HeaderStyle.overlayHeight)
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
        Row({ space: HeaderStyle.gap }) {
          this.OfficialBackButton(() => {
            this.dismissKeyboard()
            this.closeSearch()
          })
          Search({ value: this.searchQuery, placeholder: '搜索文件', controller: this.searchController })
            .layoutWeight(1)
            .height(HeaderStyle.controlHeight)
            .fontColor($r('sys.color.font_primary'))
            .placeholderColor($r('sys.color.font_secondary'))
            .backgroundColor(Color.Transparent)
            .borderRadius(HeaderStyle.controlHeight / 2)
            .cancelButton({ style: CancelButtonStyle.INPUT })
            .systemMaterial(this.adaptiveControlMaterial(uiMaterial.ImmersiveStyle.THIN, true))
            .monopolizeEvents(true)
            .onChange((value: string) => this.onSearchQueryChanged(value))
            .onSubmit((value: string) => {
              if (value.trim().length > 0) {
                this.dismissKeyboard()
                this.submitSearch(value)
              }
            })
          Button() {
            Row({ space: 4 }) {
              if (this.searchLoading) {
                LoadingProgress()
                  .width(14)
                  .height(14)
                  .color($r('sys.color.icon_primary'))
              }
              Text(this.searchLoading ? '搜索中' : '搜索')
                .fontSize(HeaderStyle.actionSize)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
            }
          }
            .type(ButtonType.Normal)
            .height(HeaderStyle.controlHeight)
            .padding({ left: 12, right: 12 })
            .borderRadius(HeaderStyle.controlHeight / 2)
            .backgroundColor(Color.Transparent)
            .systemMaterial(this.adaptiveControlMaterial(uiMaterial.ImmersiveStyle.THIN, true))
            .hitTestBehavior(HitTestMode.Default)
            .monopolizeEvents(true)
            .onClick(() => {
              if (this.searchDraft.trim().length > 0) {
                this.dismissKeyboard()
                this.submitSearch(this.searchDraft)
              }
            })
        }
        .width('100%')
        // Keep the search header in exactly the same layout box as the normal
        // file header. A shorter Row is centered by the parent Stack, which
        // makes the back button visibly drop when Search is opened.
        .height(this.topSafeInset() + HeaderStyle.overlayHeight)
        .padding({ left: HeaderStyle.sideInset, right: HeaderStyle.sideInset,
          top: this.topSafeInset() + HeaderStyle.topPadding, bottom: HeaderStyle.bottomPadding })
        .zIndex(2)
        .hitTestBehavior(HitTestMode.Default)
      } else {
        Row() {
          this.MainHeaderLeadingControl()

          Text(this.mainHeaderTitle())
            .fontSize(HeaderStyle.titleSize)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
            .margin({ left: this.mainHeaderHasLeading() ? HeaderStyle.gap : 0, right: HeaderStyle.gap })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .id('main-header-title')

          if (this.screen === 'files') {
            this.FileTopActionCluster()
          } else if (this.screen === 'downloads') {
            this.TransferDirectionControl()
          } else if (this.screen === 'settings' && this.showRecycleBinSettings) {
            this.RecycleScopeToggle()
          }
        }
        .width('100%')
        .height(this.topSafeInset() + HeaderStyle.overlayHeight)
        .padding({ left: HeaderStyle.sideInset, right: HeaderStyle.sideInset,
          top: this.topSafeInset() + HeaderStyle.topPadding, bottom: HeaderStyle.bottomPadding })
        .zIndex(2)
        .hitTestBehavior(HitTestMode.Default)
      }

      if (this.nasState === 'unavailable' || this.nasState === 'connecting' || this.offlineCacheMode) {
        Row() { this.NasConnectionNotice() }
          .width('100%')
          .margin({ top: this.topSafeInset() + (this.showSearch ? 108 : 56) })
          .hitTestBehavior(HitTestMode.None)
          .zIndex(4)
      }
      if (this.showSearch) {
        Row({ space: HeaderStyle.gap }) {
          this.SearchScopeButton('本级', 'current')
          this.SearchScopeButton('跨级', 'descendants')
          if (this.searchLoading) {
            Blank()
            Row({ space: 6 }) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color($r('sys.color.icon_primary'))
              Text(this.searchResults.length > 0 ? `已找到 ${this.searchResults.length} 项…` : '正在搜索…')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
            }
            .padding({ right: 4 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .margin({ top: this.topSafeInset() + 76 })
        .alignSelf(ItemAlign.Start)
        .backgroundColor(Color.Transparent)
        .zIndex(3)
        .hitTestBehavior(HitTestMode.Default)
      }
    }
    .width('100%')
    // The blur/gradient child always keeps the file-page height (94vp).
    // Search controls may extend the overlay's transparent hit-test area,
    // but must never stretch the gradient background itself.
    // 搜索时固定 136（容纳那排 chip），平时回到 94。全程高度恒定，避免输入导致键盘收起。
    .height(this.topSafeInset() + (this.showSearch ? HeaderStyle.searchOverlayHeight : HeaderStyle.overlayHeight))
    .backgroundColor(Color.Transparent)
    .clip(false)
    // The gradient is visual only. The root must not pass a touch started on
    // a floating control into the List below; its child controls remain in
    // the hit-test chain.
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  NasConnectionNotice(): void {
    Row({ space: 6 }) {
      Text(this.nasState === 'connecting' ? '正在连接 NAS…' :
        (this.offlineCacheMode && this.nasState === 'online' ? '正在恢复登录…' :
        (this.networkClass === 'offline' ? '手机暂无网络 · 缓存可浏览' : 'NAS 暂时无法连接 · 缓存可浏览')))
        .fontSize(11)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .hitTestBehavior(HitTestMode.None)
      Button('重试')
        .fontSize(12)
        .height(24)
        .padding({ left: 10, right: 10 })
        .backgroundColor(Color.Transparent)
        .fontColor($r('sys.color.font_primary'))
        .enabled(this.nasState !== 'connecting')
        .onClick((): void => { this.retryNasConnection() })
    }
    .height(24)
    .width('100%')
    .padding({ left: 24, right: 16 })
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
            .fontSize(HeaderStyle.actionSize)
            .fontColor($r('sys.color.font_primary'))
            .textAlign(TextAlign.Center)
            .width(104)
            .opacity(this.selectionMode ? 0 : 1)
          Text('全选')
            .fontSize(HeaderStyle.actionSize)
            .fontColor($r('sys.color.font_primary'))
            .textAlign(TextAlign.Center)
            .width(104)
            .opacity(this.selectionMode && !this.allEntriesSelected() ? 1 : 0)
          Text('取消全选')
            .fontSize(HeaderStyle.actionSize)
            .fontColor($r('sys.color.font_primary'))
            .textAlign(TextAlign.Center)
            .width(104)
            .opacity(this.selectionMode && this.allEntriesSelected() ? 1 : 0)
        }
        .width('100%')
        .height('100%')
      }
      .fontSize(HeaderStyle.actionSize)
      .fontColor($r('sys.color.font_primary'))
      .backgroundColor(Color.Transparent)
      .borderRadius(HeaderStyle.controlHeight / 2)
      .width(this.topActionButtonWidth())
      .height(HeaderStyle.controlHeight)
      .padding({ left: 0, right: 0, top: 0, bottom: 0 })
      .position({ x: this.topActionButtonX(), y: 0 })
      .systemMaterial(this.adaptiveControlMaterial(uiMaterial.ImmersiveStyle.THIN, true))
      .overlay(this.ImportLightOverlay, { align: Alignment.Center })
      // ⚠️ 不再绑 isBusy：转场/加载期间它会在 true/false 之间快速切换，
      // 按钮就一闪一闪地变灰，而那段窗口用户本来就来不及点，视觉噪音没有意义。
      // 真的忙时点击会被各自的入口守卫挡下，不会出错。空目录时禁用仍然合理。
      .enabled(this.entries.length > 0)
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
          .fontSize(HeaderStyle.iconSize)
          .fontColor([$r('sys.color.icon_primary')])
      }
      .type(ButtonType.Normal)
      .width(HeaderStyle.controlHeight)
      .height(HeaderStyle.controlHeight)
      .borderRadius(HeaderStyle.controlHeight / 2)
      .backgroundColor(Color.Transparent)
      .position({ x: 70, y: 0 })
      .opacity(this.selectionMode ? 0 : 1)
      .enabled(!this.selectionMode)
      .systemMaterial(this.adaptiveControlMaterial(uiMaterial.ImmersiveStyle.THIN, true))
      .overlay(this.ImportLightOverlay, { align: Alignment.Center })
      .monopolizeEvents(true)
      .onClick(() => this.openSearch())
      .animation({ duration: 180, curve: Curve.FastOutSlowIn })
    }
    .width(110)
    .height(HeaderStyle.controlHeight)
  }

  @Builder
  SettingsContent(): void {
    if (this.showStorageSettings) {
      this.StorageSettingsContent()
    } else if (this.showPlaybackSettings) {
      this.PlaybackSettingsContent()
    } else if (this.showNetworkSettings) {
      this.NetworkSettingsContent()
    } else if (this.showViewSettings) {
      this.ViewSettingsContent()
    } else if (this.showRecycleBinSettings) {
      this.RecycleBinSettingsContent()
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
            this.SettingsEntryRow($r('sys.symbol.list_bullet_square'), '#2E6BFF', '默认视图',
              '设置文件与图片分别用哪种显示方式', () => this.openViewSettings(), false)
            this.SettingsGroupDivider()
            this.SettingsEntryRow($r('sys.symbol.wifi'), '#0FA47F', '网络与流量',
              '管理移动网络下的加载、刷新和下载策略', () => this.openNetworkSettings(), false)
            this.SettingsGroupDivider()
            // Deliberately the last row in the card: the recycle bin is a place
            // you go looking for, not one that should compete for attention.
            this.SettingsEntryRow($r('sys.symbol.trash'), '#5F6B7A', '回收站',
              '查看并还原已删除的文件', () => this.openRecycleBinSettings(), false)
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

          if (this.appVersionName.length > 0) {
            Text('版本 ' + this.appVersionName)
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Center)
          }
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
          .fontColor([$r('sys.color.icon_secondary')])
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

  // ── Recycle bin page ─────────────────────────────────────────────────────

  /**
   * The personal/shared switch, pinned to the top-right corner as the mirror of
   * the back button on the left: same 40vp glass circle, same material, same
   * light overlay. It carries a single character rather than an icon because a
   * glyph for "which half of the NAS am I looking at" would need a legend,
   * while the character is self-evident at a glance.
   */
  @Builder
  RecycleScopeToggle(): void {
    Button() {
      Text(this.recycleScope === 'personal' ? '个' : '共')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.icon_primary'))
    }
    .type(ButtonType.Normal)
    .width(40)
    .height(40)
    .borderRadius(20)
    .backgroundColor(Color.Transparent)
    .systemMaterial(this.adaptiveControlMaterial(uiMaterial.ImmersiveStyle.THIN))
    .overlay(this.ImportLightOverlay, { align: Alignment.Center })
    .hitTestBehavior(HitTestMode.Default)
    .monopolizeEvents(true)
    .onClick(() => this.selectRecycleScope(this.recycleScope === 'personal' ? 'shared' : 'personal'))
  }

  /**
   * The caveats that apply to the current list, in both the empty and the
   * populated state. A bin that silently omits folders would look identical to
   * an empty one, which is exactly the wrong impression.
   */
  @Builder
  RecycleNotices(): void {
    if (this.recycleBlockedShares.length > 0) {
      Text('无法读取：' + this.recycleBlockedShares.join('、') + '（可能是权限限制）')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .lineHeight(18)
        .width('100%')
    }
  }

  /**
   * One recycled item, built to match the file manager's list row exactly: no
   * card surface, no radius, 58vp tall, the same 40x34 leading visual, the same
   * 16/12 type ramp and the same chevron — which only a folder gets, because
   * only a folder can be entered.
   *
   * The leading visual is reused as-is. It falls back to a folder/file icon
   * whenever no thumbnail URI resolves, and for a `#recycle` path none ever
   * does, which is precisely the "placeholder instead of loading a cover"
   * behaviour this page wants — with no extra code and no cover requests.
   */
  @Builder
  RecycleRow(entry: FileEntry, index: number): void {
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
          if (this.recycleEntryInfo(entry).length > 0) {
            Text(this.recycleEntryInfo(entry))
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

      if (index < this.recycleEntries.length - 1) {
        Divider()
          .width('calc(100% - 16vp)')
          .strokeWidth(0.5)
          .color($r('app.color.divider'))
      }
    }
    .width('100%')
    .onClick(() => this.onRecycleEntryClick(entry))
    .priorityGesture(
      LongPressGesture({ repeat: false })
        .onAction((event: GestureEvent): void => {
          this.showActionMenu(entry, event)
        })
    )
  }

  /**
   * The recycle bin page: one directory level at a time.
   *
   * The top level lists the folders that have something deleted inside them, so
   * tapping one drills in the same way the file manager does. Emptying is
   * scoped to the level on screen, which is why its control sits directly below
   * the list instead of in the header — the count next to it is exactly what
   * would be deleted.
   */
  @Builder
  RecycleBinSettingsContent(): void {
    Column() {
      if (this.recycleLoading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(30)
            .height(30)
            .color('#2E6BFF')
          Text('正在读取回收站…')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.recycleEntries.length === 0) {
        Column({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(34)
            .fontColor([$r('app.color.text_tertiary')])
          Text(this.recycleScope === 'shared' ? '共享回收站是空的' : '个人回收站是空的')
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))
          this.RecycleNotices()
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 20, right: 20 })
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 0 }) {
          // The file manager keeps its top breathing room in a blank first item
          // so its content origin sits below the gradient header. Matching that
          // here puts the first row at the same height on both pages.
          ListItem() {
            Row()
              .width('100%')
              .height(this.fileContentTopInset())
          }
          .width('100%')

          ForEach(this.recycleEntries, (entry: FileEntry, index: number) => {
            ListItem() {
              this.RecycleRow(entry, index)
            }
          }, (entry: FileEntry): string => entry.path)
        }
        .width('100%')
        .layoutWeight(1)
        .cachedCount(4)
        .padding({ left: 0, right: 0 })
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })

        Column({ space: 6 }) {
          this.RecycleNotices()
          Text('清空当前目录的 ' + this.recycleEntries.length.toString() + ' 项')
            .fontSize(14)
            .fontColor('#D34D5C')
            .width('100%')
            .textAlign(TextAlign.Center)
            .onClick(() => {
              if (!this.isBusy) {
                this.purgeCurrentRecycleLayer()
              }
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: this.bottomSafeInset() + 16 })
      }

      if (this.statusText.length > 0) {
        Text(this.statusText)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 20, right: 20, top: 8, bottom: this.bottomSafeInset() + 8 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .height('100%')
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

  private fileViewModeOptions(): FileViewMode[] {
    return ['list', 'grid']
  }

  private photoViewModeOptions(): FileViewMode[] {
    return ['list', 'grid', 'waterfall']
  }

  /** 一个分段选择器：当前值高亮。 */
  @Builder
  ViewModeSegment(kind: DefaultViewKind) {
    // 注意：当前值必须在 builder 内部读（this.xxx），不能当参数传进来 ——
    // @Builder 的值传参在状态变化时不会重建，高亮会停在旧值上。
    Row({ space: 8 }) {
      ForEach(kind === 'photo' ? this.photoViewModeOptions() : this.fileViewModeOptions(),
        (mode: FileViewMode) => {
        Text(mode === 'list' ? '列表' : (mode === 'grid' ? '网格' : '瀑布流'))
          .fontSize(14)
          .fontColor(this.defaultViewMode(kind) === mode
            ? Color.White : $r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(34)
          .borderRadius(17)
          .backgroundColor(this.defaultViewMode(kind) === mode
            ? '#2E6BFF' : $r('app.color.surface_card'))
          .onClick(() => { this.setDefaultViewMode(kind, mode) })
          .id('default-view-' + kind + '-' + mode)
      }, (mode: FileViewMode) => mode)
    }
    .width('100%')
  }

  @Builder
  ViewSettingsContent(): void {
    Scroll() {
      Column({ space: 16 }) {
        Text('选好之后，每次进入目录都按这里的设置显示；工具栏上的临时切换不会改掉它。')
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
          .lineHeight(22)
          .width('100%')

        Column({ space: 10 }) {
          Text('文件夹的默认视图')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text('普通文件与混合目录用这个')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
          this.ViewModeSegment('file')
        }
        .width('100%')
        .padding(14)
        .borderRadius(16)
        .backgroundColor($r('app.color.surface_card'))

        Column({ space: 10 }) {
          Text('图片目录的默认视图')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text('有图片的目录用这个，多一个瀑布流')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
          this.ViewModeSegment('photo')
        }
        .width('100%')
        .padding(14)
        .borderRadius(16)
        .backgroundColor($r('app.color.surface_card'))

        Column({ space: 10 }) {
          Text('音频目录的默认视图')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text('纯音频目录用这个')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
          this.ViewModeSegment('audio')
        }
        .width('100%')
        .padding(14)
        .borderRadius(16)
        .backgroundColor($r('app.color.surface_card'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    // 内边距必须在 Scroll 上、且 top 要加 topSafeInset()，否则内容会顶进标题栏底下
    // （工程里其它设置子页都是这么写的，这里照抄）。
    .padding({ left: 20, right: 20, top: this.topSafeInset() + 76,
      bottom: this.bottomSafeInset() + 112 })
    .align(Alignment.TopStart)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .scrollBar(BarState.Off)
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
  DirectoryTimelineBar(): void {
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() {}.tabBar(this.DirectoryTimelineBarContent)
    }
    .vertical(false)
    .scrollable(false)
    .barOverlap(true)
    .barHeight(this.floatingTimelineHeight() + FLOATING_TIMELINE_EFFECT_INSET_VP * 2)
    .barBackgroundColor(Color.Transparent)
    .barBackgroundBlurStyle(BlurStyle.NONE)
    .width(FLOATING_TIMELINE_WIDTH_VP)
    .height(this.floatingTimelineHeight() + FLOATING_TIMELINE_EFFECT_INSET_VP * 2)
    .clip(false)
    .hitTestBehavior(HitTestMode.Default)
  }

  @Builder
  DirectoryTimelineBarContent(): void {
    FisheyeTimeline({
      timeline: this.directoryTimeline,
      focusTime: $timelineFocusTime,
      widthVp: FLOATING_TIMELINE_WIDTH_VP,
      railWidthVp: FLOATING_TIMELINE_RAIL_WIDTH_VP,
      heightVp: this.floatingTimelineHeight(),
      verticalEffectInsetVp: FLOATING_TIMELINE_EFFECT_INSET_VP,
      material: this.timelineRailMaterial,
      onScrubStart: (): void => { this.beginTimelineScrub() },
      onScrub: (time: number): void => { this.previewTimelineTime(time) },
      onScrubEnd: (time: number): void => { this.finishTimelineScrub(time) },
      onTap: (): void => {
        // ⚠️ 必须同时结束 scrub 交互：按下时 FisheyeTimeline 会调 onScrubStart →
        // beginTimelineScrub() 会把 timelineScrubActive 置为 true，而"没有拖动的点击"
        // 不会走 onScrubEnd / onSelect —— 那两个是唯一会复位该标志的地方。
        // 结果就是点一次日期之后 timelineScrubActive 永久为 true，
        // loadEntryPreview 的开头判断会跳过一切加载（连手动滑动都救不回来）。
        this.toggleTimelineCollapsed()
        this.releaseTimelineInteraction()
      },
      onSelect: (time: number, period: TimelinePeriod): void => {
        // 只定位，不收起。展开/收起的唯一入口是点「凸出来的日期」（onTap）。
        this.selectTimelinePeriod(time, period)
      }
    })
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
    .barHeight(this.fileToolsBarHeight() + FLOATING_BAR_EFFECT_TOP_INSET_VP + 40)
    // This Tabs instance only supplies the supported bottom-TabBar material
    // scope. Its own rectangular bar must stay visually transparent.
    .barBackgroundColor(Color.Transparent)
    .barBackgroundBlurStyle(BlurStyle.NONE)
    .width('100%')
    .height(this.fileToolsBarHeight() + FLOATING_BAR_EFFECT_TOP_INSET_VP + 80)
    .margin({ bottom: this.floatingBarBottomMargin() - 40 })
    .clip(false)
    // Cut 4E-1: 将底栏全宽 Tabs 宿主的 hitTestBehavior 从 Default 改为 None。
    // 该透明宿主自身不参与命中测试，不阻塞下层 Grid；其内部胶囊子节点继续按各自命中行为参与交互。
    .hitTestBehavior(HitTestMode.None)
    .onAreaChange((_, area: Area) => {
      this.updateBottomBarVisualHostRect(area)
    })
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
      // ⚠️ 隐藏态必须用 BLOCK_DESCENDANTS ✗ 不能用 None：
      // 三个底栏是【互相重叠的兄弟】，后画的压在上面。None 只让「自身」不响应，
      // 子按钮照常参与命中 → 隐藏态的按钮会盖住可见底栏 → 底栏整体点不动 ✗
      .hitTestBehavior(this.bottomBarMode() === 'home'
        ? HitTestMode.Default : HitTestMode.BLOCK_DESCENDANTS)
      .animation({ duration: 200, curve: Curve.FastOutSlowIn })

      // 多选操作
      Stack() {
        this.SelectionBarContent()
      }
      .width('100%')
      .height(FLOATING_BAR_HEIGHT_VP)
      .opacity(this.bottomBarMode() === 'selection' ? 1 : 0)
      .translate({ x: 0, y: this.bottomBarMode() === 'selection' ? 0 : 12, z: 0 })
      // ⚠️ 与另两个底栏保持一致：隐藏态必须 BLOCK_DESCENDANTS。
      // None 只让「自身」退出命中、子节点（图标/文字）照常参与，
      // 而 selection 层压在 home 之上 → 会挡掉落在该区域的底栏点击。
      .hitTestBehavior(this.bottomBarMode() === 'selection'
        ? HitTestMode.Default : HitTestMode.BLOCK_DESCENDANTS)
      .animation({ duration: 200, curve: Curve.FastOutSlowIn })

      // 文件详情页：左圆钮 + 中间排序胶囊 + 右圆钮
      Stack() {
        this.FileToolsBarContent()
      }
      .width('100%')
      .height(this.fileToolsBarHeight())
      .opacity(this.bottomBarMode() === 'tools' ? 1 : 0)
      .translate({ x: 0, y: this.bottomBarMode() === 'tools' ? 0 : 12, z: 0 })
      .hitTestBehavior(this.bottomBarMode() === 'tools'
        ? HitTestMode.Default : HitTestMode.BLOCK_DESCENDANTS)
      .animation({ duration: 200, curve: Curve.FastOutSlowIn })
    }
    .width('100%')
    .height(this.fileToolsBarHeight() + FLOATING_BAR_EFFECT_TOP_INSET_VP)
    // The visible 56vp controls stay bottom-aligned at their previous screen
    // position. The extra top area only carries native shadow/deformation.
    .margin({ bottom: 40 })
    // Cut 4E-2: 将 BottomBarContent 全宽外壳从 Default 改为 None。
    // 该容器仅用于排版与阴影承载，自身不拦截触摸，将空白区域透传给底层 Grid；
    // 内部各胶囊子组件继续按自身的 hitTestBehavior 处理点击交互。
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  HomeBarContent(): void {
    Stack({ alignContent: Alignment.Center }) {
      Row() {
        this.BottomNavItem($r('sys.symbol.house'), '主页', 'home', () => this.openHome())
        this.BottomNavItem($r('sys.symbol.folder'), '共享', 'shared', () => this.openShared())
        this.BottomNavItem($r('sys.symbol.transfer'), '传输', 'downloads',
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
    .onAreaChange((_, area: Area) => {
      this.updateBottomBarInteractiveRect('home:capsule', area)
    })
  }

  @Builder
  FileToolsBarContent(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        this.FileToolCircleButton({
          icon: $r('sys.symbol.folder_badge_plus'),
          action: () => this.openCreateFolder(),
          slideBar: 'tools',
          slideKey: '新建'
        })

        Button() {
          Row({ space: 6 }) {
            Text(this.fileSortTitle())
              .fontSize(15)
              .fontColor($r('sys.color.font_primary'))
            SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
              .fontSize(10)
              .fontColor([$r('sys.color.icon_primary')])
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
        .onAreaChange((_, area: Area) => {
          this.updateBottomBarInteractiveRect('tools:sort', area)
        })
        .onClick(() => {
          HapticFeedback.confirm()
          this.toggleFileSortMenu()
        })
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

        // The glyph is the mode this tap will switch TO, so the icon and the
        // next tap always correspond one-to-one. It only repaints because the
        // whole button is handed over as one object literal (see
        // FileToolCircleButtonOptions).
        this.FileToolCircleButton({
          icon: this.fileViewModeIcon(),
          action: () => this.toggleFileViewMode(),
          slideBar: 'tools',
          slideKey: '视图'
        })
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
        .height(FLOATING_BAR_HEIGHT_VP)
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height(this.fileToolsBarHeight())
    .hitTestBehavior(this.bottomBarMode() === 'tools' ? HitTestMode.Default : HitTestMode.None)
  }

  @Builder
  SelectionBarContent(): void {
    Row() {
      this.SelectionActionButton($r('sys.symbol.share'), '分享',
        () => this.shareSelectedEntries())
      this.SelectionActionButton($r('sys.symbol.doc_text_on_doc_text'), '复制',
        () => this.beginSelectionDestinationPicker('copy'))
      this.SelectionActionButton($r('sys.symbol.trash'), '删除',
        () => this.deleteSelectedEntries())
      this.SelectionMoreButton()
    }
    .id('selection_bottom_bar')
    .width(this.bottomBarCapsuleWidth())
    .height(FLOATING_BAR_HEIGHT_VP)
    .padding({ left: 8, right: 8, top: 0, bottom: 0 })
    .borderRadius(FLOATING_BAR_HEIGHT_VP / 2)
    .systemMaterial(this.bottomCapsuleMaterial)
    .hitTestBehavior(this.bottomBarMode() === 'selection' ? HitTestMode.Default : HitTestMode.None)
    .onAreaChange((_, area: Area) => {
      this.updateBottomBarInteractiveRect('selection:capsule', area)
    })
  }

  @Builder
  SelectionActionButton(icon: Resource, title: string, action: () => void): void {
    Button() {
      Column({ space: 2 }) {
        SymbolGlyph(icon)
          .fontSize(24)
          .fontColor([this.selectionActionEnabled(title)
            ? $r('sys.color.icon_primary') : $r('sys.color.icon_tertiary')])
        Text(title)
          .fontSize(12)
          .fontColor(this.selectionActionEnabled(title)
            ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary'))
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
    .onAreaChange((_, area) => this.registerSlideItem('selection', title, area, action))
    .onTouch((event: TouchEvent) => this.slideItemTouch('selection', title, event))
    .onClick(() => {
      HapticFeedback.confirm()
      action()
    })
  }

  @Builder
  SelectionMoreButton(): void {
    Button() {
      Column({ space: 2 }) {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(24)
          .fontColor([this.selectedEntryCount > 0
            ? $r('sys.color.icon_primary') : $r('sys.color.icon_tertiary')])
        Text('更多')
          .fontSize(12)
          .fontColor(this.selectedEntryCount > 0
            ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary'))
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
    .onAreaChange((_, area) =>
      this.registerSlideItem('selection', '更多', area, () => this.toggleSelectionMoreMenu()))
    .onTouch((event: TouchEvent) => this.slideItemTouch('selection', '更多', event))
    .onClick(() => {
      HapticFeedback.confirm()
      this.toggleSelectionMoreMenu()
    })
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
      this.SelectionMoreRow($r('sys.symbol.move'), '移动',
        () => this.beginSelectionDestinationPicker('move'))
      this.SelectionMoreRow($r('sys.symbol.download'), '下载',
        () => this.downloadSelectedEntries())

      if (this.selectedPaths.length === 1) {
        if (this.selectedSingleEntry() !== null &&
          this.actionSupportsOpenWith(this.selectedSingleEntry() as FileEntry)) {
          this.SelectionMoreRow($r('sys.symbol.rectangle_and_arrowshape_turn_up_right'), '其他应用打开',
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
          this.SelectionMoreRow($r('sys.symbol.picture_badge_arrow_down'), '保存图库',
            () => this.saveSelectedGallery(this.selectedSingleEntry() as FileEntry))
        }
        if (this.selectedSingleEntry() !== null &&
          this.actionHasLocalCache(this.selectedSingleEntry() as FileEntry)) {
          this.SelectionMoreRow($r('sys.symbol.arrow_down'), '释放缓存',
            () => this.releaseSelectedCaches())
        }
        if (this.selectedSingleEntry() !== null) {
          this.SelectionMoreRow($r('sys.symbol.rename'), '重命名',
            () => this.renameSelectedEntry(this.selectedSingleEntry() as FileEntry))
          this.SelectionMoreRow($r('sys.symbol.info_circle'), '详情',
            () => this.showEntryDetailsSelected(this.selectedSingleEntry() as FileEntry), false)
        }
      } else if (this.selectedCachedEntries().length > 0) {
        this.SelectionMoreRow($r('sys.symbol.arrow_down'), '释放缓存',
          () => this.releaseSelectedCaches(), false)
      }
    }
    .width(228)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(22)
    .hitTestBehavior(HitTestMode.Default)
  }

  @Builder
  SelectionMoreRow(icon: Resource, title: string, action: () => void,
    showDivider: boolean = true): void {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
      SymbolGlyph(icon)
        .fontSize(21)
        .fontColor([$r('sys.color.icon_primary')])
        .width(30)
    }
    .width('100%')
    .height(48)
    .padding({ left: 10, right: 8 })
    .borderRadius(14)
    .backgroundColor(Color.Transparent)
    // 和其它菜单一致：按下 A、滑到 B 松手 → 执行 B（并同样收起菜单）。
    .onAreaChange((_, area) => this.registerSlideItem('selmore', title, area, () => {
      this.showSelectionMoreMenu = false
      action()
    }))
    .onTouch((event: TouchEvent) => this.slideItemTouch('selmore', title, event))
    .onClick(() => {
      this.showSelectionMoreMenu = false
      action()
    })

    if (showDivider) {
      Divider()
        .strokeWidth(0.5)
        .color($r('sys.color.comp_divider'))
        .margin({ left: 10, right: 10 })
    }
  }

  @Builder
  ImportLightOverlay(): void {
    ProximityLightReceiver()
      .width('100%').height('100%')
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  FileToolCircleButton(options: FileToolCircleButtonOptions): void {
    Button() {
      SymbolGlyph(options.icon)
        .fontSize(24)
        .fontColor([$r('sys.color.icon_primary')])
    }
    .type(ButtonType.Normal)
    .width(FLOATING_BAR_HEIGHT_VP)
    .height(FLOATING_BAR_HEIGHT_VP)
    .borderRadius(FLOATING_BAR_HEIGHT_VP / 2)
    .backgroundColor(Color.Transparent)
    .systemMaterial(this.bottomCapsuleMaterial)
    .hitTestBehavior(this.bottomBarMode() === 'tools' ? HitTestMode.Default : HitTestMode.None)
    .monopolizeEvents(this.bottomBarMode() === 'tools')
    .onAreaChange((_, area: Area) => {
      this.updateBottomBarInteractiveRect('tools:' + options.slideKey, area)
    })
    .onClick(() => {
      HapticFeedback.confirm()
      options.action()
    })
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
        duration: 180,
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
          .fontColor([$r('sys.color.icon_primary')])
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
          .fontColor([this.selectedBottomTab === tab
            ? $r('sys.color.icon_emphasize') : $r('sys.color.icon_primary')])
      }
      .width('100%')
      .height(24)

      Text(title)
        .fontSize(12)
        .fontWeight(this.selectedBottomTab === tab ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.selectedBottomTab === tab
          ? $r('sys.color.font_emphasize') : $r('sys.color.font_primary'))
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    // 非当前形态的层仍挂在树上（材质不重建），但子按钮必须退出命中测试，
    // 否则 monopolizeEvents 会越过父级 HitTestMode.None 挡住可见层。
    .hitTestBehavior(this.bottomBarMode() === 'home' ? HitTestMode.Default : HitTestMode.None)
    .monopolizeEvents(this.bottomBarMode() === 'home')
    .onAreaChange((_, area) => this.registerSlideItem('home', tab, area, action))
    .onTouch((event: TouchEvent) => this.slideItemTouch('home', tab, event))
    .onClick(() => {
      HapticFeedback.confirm()
      action()
    })
  }

  @Builder
  OfficialBackButton(action: () => void): void {
    Button() {
      SymbolGlyph($r('sys.symbol.chevron_backward'))
        .fontSize(HeaderStyle.iconSize)
        .fontColor([$r('sys.color.icon_primary')])
    }
    .type(ButtonType.Normal)
    .width(HeaderStyle.controlHeight)
    .height(HeaderStyle.controlHeight)
    .borderRadius(HeaderStyle.controlHeight / 2)
    .backgroundColor(Color.Transparent)
    .systemMaterial(this.adaptiveControlMaterial(uiMaterial.ImmersiveStyle.THIN))
    .overlay(this.ImportLightOverlay, { align: Alignment.Center })
    .hitTestBehavior(HitTestMode.Default)
    .monopolizeEvents(true)
    .onClick(action)
  }

  @Builder
  MainHeaderLeadingControl(): void {
    Stack({ alignContent: Alignment.Center }) {
      // Retain the native material node across root/child and file/settings switches.
      // Hidden removes painting as well as input; opacity alone leaves native material visible.
      Button() {
        SymbolGlyph(this.screen === 'files' && this.selectionMode
          ? $r('sys.symbol.xmark') : $r('sys.symbol.chevron_backward'))
          .fontSize(HeaderStyle.iconSize)
          .fontColor([$r('sys.color.icon_primary')])
      }
      .type(ButtonType.Normal)
      .width(HeaderStyle.controlHeight)
      .height(HeaderStyle.controlHeight)
      .borderRadius(HeaderStyle.controlHeight / 2)
      .backgroundColor(Color.Transparent)
      .systemMaterial(this.adaptiveControlMaterial(uiMaterial.ImmersiveStyle.THIN))
      .overlay(this.ImportLightOverlay, { align: Alignment.Center })
      .visibility(this.mainHeaderHasLeading() ? Visibility.Visible : Visibility.Hidden)
      .hitTestBehavior(this.mainHeaderHasLeading() ? HitTestMode.Default : HitTestMode.BLOCK_DESCENDANTS)
      .monopolizeEvents(true)
      .id('main-header-leading')
      .onClick(() => {
        if (this.screen === 'files') {
          if (this.selectionMode) { this.exitSelectionMode() }
          else if (this.currentPath.length > 0) { this.goBack() }
        } else if (this.screen === 'settings') {
          this.closeSettingsSubpage()
        }
      })
    }
    .width(this.mainHeaderHasLeading() ? HeaderStyle.controlHeight : 0)
    .height(HeaderStyle.controlHeight)
  }

  @Builder
  SelectionCloseButton(action: () => void): void {
    Button() {
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(HeaderStyle.iconSize)
        .fontColor([$r('sys.color.icon_primary')])
    }
    .type(ButtonType.Normal)
    .width(HeaderStyle.controlHeight)
    .height(HeaderStyle.controlHeight)
    .borderRadius(HeaderStyle.controlHeight / 2)
    .backgroundColor(Color.Transparent)
    .systemMaterial(this.adaptiveControlMaterial(uiMaterial.ImmersiveStyle.THIN))
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
      .id('context-preview-' + this.contextMenuPreviewSurface)
      .mode(NavigationMode.Stack)
      .hideBackButton(true)
      .hideToolBar(true)
      .title({ builder: this.ActionContextPreviewCard.bind(this, entry),
        height: this.contextMenuLayout.height }, {
        barStyle: BarStyle.STACK,
        paddingStart: LengthMetrics.vp(0),
        paddingEnd: LengthMetrics.vp(0),
        backgroundColor: Color.Transparent
      })
      .width(this.contextMenuLayout.width)
      .height(this.contextMenuLayout.height)
      .backgroundColor(Color.Transparent)
      .clip(false)
  }

  @Builder
  ActionMenuOverlay(): void {
    Column() {}
      .id('context-menu-anchor')
      .width(this.contextMenuLayout.width)
      .height(this.contextMenuLayout.height)
      // Offset by the menu's transparent safe margin so the visible surface
      // still lands exactly where it used to.
      .position({
        x: this.contextMenuLayout.x - this.actionMenuSafeMargin,
        y: this.contextMenuLayout.y - this.actionMenuSafeMargin
      })
      .hitTestBehavior(HitTestMode.None)
      .bindContextMenu(this.contextMenuVisible, this.NativeActionMenuContent, {
        preview: this.NativeActionMenuPreview,
        previewAnimationOptions: { scale: [1, this.contextMenuLayout.scale] },
        previewBorderRadius: this.contextMenuPreviewSurface === 'list' ? 20 : 14,
        placement: Placement.BottomLeft,
        borderRadius: 22,
        transition: this.actionMenuSurfaceTransition(),
        // The immersive material must NOT live on the menu panel here.
        // `ContextMenuOptions.systemMaterial` paints the system subwindow's own
        // panel, which is a passive container that never enters a press state, so
        // its lightEffect (press point-light) can never fire - that is exactly
        // why the menu had no light while the preview card above it did (the card
        // is hosted in a Navigation title bar, which IS an interactive node).
        // So the panel is made fully invisible and the material moves onto the
        // menu content itself (see ActionContextMenu), where the press light
        // works just like on the card.
        systemMaterial: uiMaterial.Material.empty,
        backgroundColor: Color.Transparent,
        backgroundBlurStyle: BlurStyle.NONE,
        // Belt and braces for the panel's own edge. The visible stray hairline
        // turned out to be the panel's bounds, not its outline: cancelling the
        // panel's content inset (see ActionContextMenu) is what actually removes
        // it. These two stay because they cost nothing and pin the outline shut
        // on builds/themes where it is honoured - outlineColor's documented
        // default ('#19ffffff') is the exact colour that hairline sampled as.
        outlineWidth: 0,
        outlineColor: Color.Transparent,
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
    if (this.contextMenuPreviewSurface !== 'list') {
      this.ActionContextTilePreview(entry)
    } else {
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
    // Tapping the title card must not dismiss the menu. By default the native
    // menu treats a tap anywhere inside as "close"; blocking here keeps the
    // card - and the menu - alive until a real action is actually picked.
    .hitTestBehavior(HitTestMode.Block)
    }
  }

  @Builder
  ActionContextTilePreview(entry: FileEntry): void {
    Stack({ alignContent: Alignment.Center }) {
      if (typeof this.contextMenuPreviewSource !== 'string' || this.contextMenuPreviewSource.length > 0) {
        Image(this.contextMenuPreviewSource)
          .width('100%')
          .height('100%')
          .orientation(this.contextMenuPreviewOrientation)
          .objectFit(this.contextMenuPreviewSurface === 'waterfall' ? ImageFit.Contain : ImageFit.Cover)
        if (this.isVideo(entry)) {
          SymbolGlyph($r('sys.symbol.play'))
            .fontSize(24)
            .fontColor([Color.White])
        }
      } else {
        Column({ space: 6 }) {
          if (entry.isDirectory) {
            this.FolderIcon(40)
          } else {
            Image(this.fileIcon(entry))
              .width(40)
              .height(40)
              .objectFit(ImageFit.Contain)
          }
          Text(entry.name)
            .fontSize(11)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding(6)
      }
    }
    .width('100%')
    .height(this.contextMenuLayout.height)
    .borderRadius(14)
    .clip(true)
    .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, false))
    // This image has no visibility/geometry callbacks or shared-element ID:
    // it cannot overwrite the real thumbnail's telemetry or return target.
    .hitTestBehavior(HitTestMode.Block)
  }

  /**
   * Native ContextMenu content. Widths and section rhythm follow the Files
   * reference: a compact menu (224vp) below a wider selected-item card,
   * with quick actions in the first group and destructive actions at the end.
   *
   * The menu needs its own immersive surface, because the native panel is made
   * fully transparent (see ActionMenuOverlay). An immersive material only renders
   * - and only gets its press point-light - inside a supported scope, and a plain
   * container is not one. A Navigation title bar is, and that is exactly how the
   * preview card above gets both its material and its press light, so the whole
   * menu is hosted there as ONE surface that lights up wherever it is pressed
   * (centre, edge or corner).
   */
  /**
   * Chooses which set of rows the shared long-press menu renders.
   *
   * The menu shell — anchor, preview card, material host, dismissal lifecycle —
   * is deliberately common to the file manager and the recycle bin so a long
   * press behaves and looks the same in both. Only the rows differ, and this is
   * the single place that decides.
   */
  @Builder
  ActionMenuSurfaceFor(entry: FileEntry): void {
    if (this.contextMenuContext === 'recycle') {
      this.RecycleActionMenuSurface(entry)
    } else {
      this.ActionContextMenuSurface(entry)
    }
  }

  @Builder
  ScrollableActionMenuSurface(entry: FileEntry): void {
    Scroll() {
      this.ActionMenuSurfaceFor(entry)
    }
    .id('context-menu-actions')
    .width('100%')
    .height(this.actionMenuHeight(entry))
    .enableScrollInteraction(this.actionMenuNaturalHeight(entry) > this.actionMenuHeight(entry) + 1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .borderRadius(22)
    .clip(true)
    .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, false, '', false))
    .onAreaChange((_, area) => {
      if (typeof area.globalPosition.x === 'number' && typeof area.globalPosition.y === 'number') {
        this.contextMenuScrollRect.x = area.globalPosition.x
        this.contextMenuScrollRect.y = area.globalPosition.y
        this.contextMenuScrollRect.width = area.width as number
        this.contextMenuScrollRect.height = area.height as number
      }
    })
    .onScrollStart((): void => {
      this.contextMenuScrollMoved = true
      this.slidePressKey = ''
    })
  }

  /**
   * The only two things you can do with something that is already deleted.
   * Restore leads and is not destructive; permanent deletion follows in the
   * warning colour, the same way the file manager marks 删除.
   *
   * No section gap between them, unlike the file menu: that gap exists to
   * separate groups, and with just two peer actions it reads as uneven
   * spacing — the distance between the rows came out ~50% wider than the
   * panel's top and bottom margins.
   */
  @Builder
  RecycleActionMenuSurface(entry: FileEntry): void {
    Column() {
      this.ActionMenuRow($r('sys.symbol.arrow_counterclockwise'), '还原',
        () => { this.runContextAction(() => { this.restoreRecycleEntry(entry) }) }, false, false)
      this.ActionMenuRow($r('sys.symbol.trash'), '永久删除',
        () => { this.runContextAction(() => { this.purgeRecycleEntry(entry) }) }, true, true)
    }
    .width('100%')
    .height(this.actionMenuNaturalHeight(entry))
  }

  @Builder
  ActionContextMenu(entry: FileEntry): void {
    Navigation() {}
      .mode(NavigationMode.Stack)
      .hideBackButton(true)
      .hideToolBar(true)
      .title({
        builder: this.ScrollableActionMenuSurface.bind(this, entry),
        height: this.actionMenuHeight(entry)
      }, {
        barStyle: BarStyle.STACK,
        paddingStart: LengthMetrics.vp(0),
        paddingEnd: LengthMetrics.vp(0),
        backgroundColor: Color.Transparent
      })
      .width(Math.min(224, this.effectivePageWidth() - 52))
      .height(this.actionMenuHeight(entry))
      .backgroundColor(Color.Transparent)
      .clip(false)
      // Cancel the native menu's 4vp content inset. ArkUI lays menu content out
      // 4vp inside the panel (a fixed gutter, same on all four sides), so the
      // panel's own edge - a 1px light hairline tracing the panel's rounded rect
      // - was left visible 4vp OUTSIDE this surface and read as a second frame
      // around the menu. No option removes that edge: outlineWidth: 0 /
      // outlineColor: Transparent do not touch it, mask: false does not, and
      // neither Material.empty nor a real ImmersiveMaterial on the panel does.
      // Pulling the content out by exactly the gutter instead makes the panel
      // collapse onto this surface (verified on device: panel and Navigation
      // both become [91,934][875,2082], gutter 0px on all sides), so the only
      // remaining edge is this surface's own material rim - which is what the
      // preview card has too, and the menu now lines up flush with that card.
      .margin({ left: -4, top: -4, right: -4, bottom: -4 })
      // Consume empty-area drags without competing with the child Scroll.
      // A normal Pan here prevents a clipped menu from scrolling and sends
      // its Up event into the slide-to-another-action path instead.
      .parallelGesture(
        PanGesture({ direction: PanDirection.All, distance: 4 })
          .onActionStart((event: GestureEvent) => {})
          .onActionUpdate((event: GestureEvent) => {})
          .onActionEnd((event: GestureEvent) => {})
      )
  }

  /**
   * The menu surface: one immersive-material container holding every row, hosted
   * in ActionContextMenu's Navigation title bar. No Menu()/MenuItem() wrapper -
   * those paint the stock row highlight, which turned the whole menu uniformly
   * grey on press.
   */
  @Builder
  ActionContextMenuSurface(entry: FileEntry): void {
    Column() {
        Row() {
          if (entry.isDirectory) {
            this.ActionQuickButton($r('sys.symbol.doc_text_on_doc_text'), '复制',
              () => this.beginDestinationPicker('copy', entry))
            this.ActionQuickButton($r('sys.symbol.move'), '移动',
              () => this.beginDestinationPicker('move', entry))
          } else {
            if (this.actionSupportsShare(entry)) {
              this.ActionQuickButton($r('sys.symbol.share'), '分享',
                () => this.shareViewerImage(entry))
            }
            this.ActionQuickButton($r('sys.symbol.doc_text_on_doc_text'), '复制',
              () => this.beginDestinationPicker('copy', entry))
            this.ActionQuickButton($r('sys.symbol.move'), '移动',
              () => this.beginDestinationPicker('move', entry))
          }
        }
        .width('100%')
        .height(58)

        this.ActionSectionGap()

        if (!entry.isDirectory && this.actionSupportsOpenWith(entry)) {
          this.ActionMenuRow($r('sys.symbol.rectangle_and_arrowshape_turn_up_right'), '其他应用打开',
            () => this.openWithOtherApp(entry), false, true)
          this.ActionSectionGap()
        }

        if (!entry.isDirectory && this.actionSupportsQuickView(entry)) {
          this.ActionMenuRow($r('sys.symbol.play'), '快速查看',
            () => this.quickView(entry), false, false)
        }
        this.ActionMenuRow($r('sys.symbol.list_bullet_square'), '多选',
          () => this.enterSelection(entry), false, false)
        this.ActionMenuRow($r('sys.symbol.download'), '下载',
          () => this.downloadEntryFromMenu(entry), false, false)
        if (!entry.isDirectory && this.isMedia(entry)) {
          this.ActionMenuRow($r('sys.symbol.picture_badge_arrow_down'), '保存图库',
            () => this.saveToGallery(entry), false, !this.actionHasLocalCache(entry))
        }
        if (!entry.isDirectory && this.actionHasLocalCache(entry)) {
          this.ActionMenuRow($r('sys.symbol.arrow_down'), '释放缓存',
            () => this.releaseCache(entry), false, false)
        }
        this.ActionMenuRow($r('sys.symbol.rename'), '重命名',
          () => this.openRename(entry), false, true)

        this.ActionSectionGap()

        this.ActionMenuRow($r('sys.symbol.info_circle'), '详情',
          () => this.showEntryDetails(entry), false, false)
        this.ActionMenuRow($r('sys.symbol.trash'), '删除',
          () => this.deleteEntry(entry), true, true)
    }
    .width('100%')
    .height(this.actionMenuNaturalHeight(entry))
  }

  @Builder
  ActionSectionGap(): void {
    // 系统文件管理的菜单里，功能区之间有一条灰色分隔带，这里对齐它。
    // 注意：之前这里用过半透明黑，在沉浸材质上看起来像一块黑砖，所以被拿掉了。
    // 现在按主题给浅色（浅灰 / 低透明白），既有分隔带又不会发黑。
    Row()
      .width('100%')
      .height(8)
      .backgroundColor(this.isDarkTheme ? '#1FFFFFFF' : '#F2F3F5')
  }

  @Builder
  ActionQuickButton(icon: Resource, title: string, action: () => void): void {
    Column({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([$r('sys.color.icon_primary')])
      Text(title)
        .fontSize(12)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .height(58)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Color.Transparent)
    .borderRadius(14)
    .onAreaChange((_, area) =>
      this.registerSlideItem('ctxmenu', title, area, () => this.runContextAction(action)))
    .onTouch((event: TouchEvent) => this.slideItemTouch('ctxmenu', title, event))
    .onClick(() => this.runContextAction(action))
  }

  @Builder
  ActionMenuRow(icon: Resource, title: string, action: () => void, danger: boolean = false,
    last: boolean = false): void {
    Column() {
      Row() {
        Text(title)
          .fontSize(16)
          .fontColor(danger ? $r('sys.color.warning') : $r('sys.color.font_primary'))
          .layoutWeight(1)
        SymbolGlyph(icon)
          .fontSize(21)
          .fontColor([danger ? $r('sys.color.warning') : $r('sys.color.icon_primary')])
          .width(30)
      }
      .width('100%')
      .height(50)
      .padding({ left: 16, right: 10 })
      if (!last) {
        // 用 100% 宽 + 左右 margin，别用 calc：菜单这种嵌套结构里
        // calc(100% - 24vp) 有时量出 0 宽，线就整条不见了。
        Divider()
          .width('100%')
          .strokeWidth(0.5)
          .color($r('app.color.divider'))
          .margin({ left: 12, right: 12 })
      }
    }
    .width('100%')
    .backgroundColor(Color.Transparent)
    // 菜单里也要「按下 A、滑到 B 松手 → 执行 B」。菜单虽然挂在原生
    // bindContextMenu 上，但条目是自绘的，所以能收到触摸事件。
    .onAreaChange((_, area) =>
      this.registerSlideItem('ctxmenu', title, area, () => this.runContextAction(action)))
    .onTouch((event: TouchEvent) => this.slideItemTouch('ctxmenu', title, event))
    .onClick(() => this.runContextAction(action))
  }

  @Builder
  DestinationPickerOverlay(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      Button() {}.type(ButtonType.Normal).width('100%').height('100%')
        .padding(0).borderRadius(0).backgroundColor(Color.Transparent).stateEffect(false)
        .hitTestBehavior(HitTestMode.Block).onClick(() => this.closeDestinationPicker())
      if (!this.destinationPickerClosing) {
        TaskPanel({ title: '选择目标文件夹', idPrefix: 'destination-picker', safeTop: this.topSafeInset(),
          hasFooter: true, showAuxiliary: true, auxiliaryLabel: '新建文件夹',
          auxiliaryEnabled: !this.destinationLoading, closeEnabled: !this.destinationOperationRunning,
          onClose: (): void => { this.closeDestinationPicker() },
          onAuxiliary: (): void => { this.openDestinationFolderDialog() },
          content: (): void => { this.DestinationPickerContent() },
          footer: (): void => { this.DestinationPickerFooter() } })
          .id('destinationPickerSurface').transition(this.destinationPickerSurfaceTransition())
      }
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.Default)
  }

  @Builder
  DestinationPickerContent(): void {
    TaskPanelSection({ fillHeight: true, paddingSize: 0 }) {
      Stack() {
        if (this.destinationLoading) {
          LoadingProgress().width(24).height(24).color($r('sys.color.comp_background_emphasize'))
            .accessibilityText(this.destinationOperationRunning ? '处理中' : '读取目录')
        } else {
          Scroll() {
            Column() {
              this.DestinationCloudRootRow()
              if (this.destinationRootExpanded) {
                ForEach(this.destinationTreeRows, (row: DestinationTreeRow) => {
                  this.DestinationTreeRowView(row)
                }, (row: DestinationTreeRow): string => row.entry.path)
                if (this.destinationTreeRows.length === 0) {
                  Text('暂无文件夹').fontSize(14).fontColor($r('sys.color.font_secondary'))
                    .width('100%').textAlign(TextAlign.Center).padding(24)
                }
              }
            }.width('100%').alignItems(HorizontalAlign.Start)
          }.width('100%').height('100%').scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
            .align(Alignment.TopStart)
            .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(16) })
        }
      }.width('100%').height('100%')
    }
  }

  @Builder
  DestinationPickerFooter(): void {
    TaskPanelFooter({ label: this.destinationOperationRunning ? '处理中…' :
      (this.destinationOperation === 'copy' ? '复制 ' : '移动 ') +
        this.destinationSelectedEntries.length.toString() + ' 项到此处',
      actionId: 'destination-picker-confirm', busy: this.destinationOperationRunning,
      actionEnabled: !this.destinationLoading && !this.destinationPickerClosing &&
        this.destinationSelectedEntries.length > 0 && this.destinationPath.length > 0,
      summaryTitle: this.destinationDisplayName(), summaryValue: this.destinationPath,
      safeBottom: this.bottomSafeInset(), onAction: (): void => { this.confirmDestinationOperation() } })
  }

  @Builder
  DestinationStorageVisual(): void {
    Image($r('app.media.private_cloud')).width(FileRowStyle.iconSize).height(FileRowStyle.iconSize).objectFit(ImageFit.Contain)
  }

  @Builder
  DestinationCloudRootRow(): void {
    Column() {
      Row({ space: FileRowStyle.leadingGap }) {
        Stack() { this.DestinationStorageVisual() }.width(FileRowStyle.leadingWidth).height(FileRowStyle.leadingHeight)
        Text('我的云盘').fontSize(FileRowStyle.titleSize).fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary')).layoutWeight(1)
        SymbolGlyph(this.destinationRootExpanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_forward'))
          .fontSize(18).fontColor([$r('sys.color.icon_secondary')]).width(24)
      }.width('100%').padding({ left: FileRowStyle.horizontalPadding, right: FileRowStyle.horizontalPadding,
        top: FileRowStyle.verticalPadding, bottom: FileRowStyle.verticalPadding })
        .backgroundColor(this.destinationPath === this.destinationUserRootPath()
          ? $r('app.color.surface_selected') : Color.Transparent)
        .onClick(() => this.toggleDestinationRoot()).id('destination-picker-root')
      Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 56, right: FileRowStyle.horizontalPadding })
    }.width('100%')
  }

  @Builder
  DestinationTreeRowView(row: DestinationTreeRow): void {
    Column() {
      Row({ space: FileRowStyle.leadingGap }) {
        Stack() { this.FolderIcon(FileRowStyle.iconSize) }.width(FileRowStyle.leadingWidth).height(FileRowStyle.leadingHeight)
        Column({ space: FileRowStyle.textGap }) {
          Text(row.entry.name).fontSize(FileRowStyle.titleSize).fontColor($r('sys.color.font_primary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.destinationEntryInfo(row.entry).length > 0) {
            Text(this.destinationEntryInfo(row.entry)).fontSize(FileRowStyle.infoSize).fontColor($r('sys.color.font_secondary'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        SymbolGlyph(row.expanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_forward'))
          .fontSize(18).fontColor([$r('sys.color.icon_secondary')]).width(24)
      }.width('100%').padding({ left: FileRowStyle.horizontalPadding + (row.depth + 1) * 24, right: FileRowStyle.horizontalPadding,
        top: FileRowStyle.verticalPadding, bottom: FileRowStyle.verticalPadding })
        .backgroundColor(this.destinationPath === row.entry.path ? $r('app.color.surface_selected') : Color.Transparent)
        .onClick(() => this.toggleDestinationFolder(row.entry))
      if (row.loading) {
        Row() {
          LoadingProgress().width(18).height(18).color($r('sys.color.comp_background_emphasize'))
            .accessibilityText('读取目录')
        }.width('100%').padding({ left: 56 + (row.depth + 1) * 24, bottom: 8 })
      }
      Divider().strokeWidth(0.5).color($r('app.color.divider'))
        .margin({ left: 56 + (row.depth + 1) * 24, right: FileRowStyle.horizontalPadding })
    }.width('100%').id('destinationTreeRow_' + row.entry.path)
      .transition(this.destinationFolderListTransition())
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

  private updateImageVisualState(path: string, update: (state: ImageVisualState) => void,
    notify: boolean = true): void {
    if (path.length === 0) {
      return
    }
    const next = this.copyImageVisualState(this.imageVisualStates[path])
    update(next)
    this.imageVisualStates[path] = next
    if (notify) {
      this.imageVisualEpoch += 1
    }
  }

  private scheduleImageVisualNotify(): void {
    // ⚠️ 滚动期间绝不 bump imageVisualEpoch：
    // grid 里 fileImageSource() 每个条目都读这个 @State，一次 bump = 整片网格
    // （可见条目和仍挂载的缓存条目）都会收到更新。
    // 滚动中每个新进入的条目都会走 resolveFileListImageRotation → 这里。
    // 所以滚动中只记 dirty 标记，等 onScrollStop 统一补一次。
    if (this.fileContentScrolling) {
      this.imageVisualNotifyDeferred = true
      return
    }
    if (this.imageVisualNotifyTimer > 0) {
      return
    }
    this.imageVisualNotifyTimer = setTimeout((): void => {
      this.imageVisualNotifyTimer = 0
      // 定时器排队后可能已经开始下一次滚动，执行时必须重新检查。
      if (this.fileContentScrolling) {
        this.imageVisualNotifyDeferred = true
        return
      }
      this.imageVisualEpoch += 1
    }, 16)
  }

  private scheduleImageVisualPrune(): void {
    if (this.imageVisualPruneTimer > 0) {
      return
    }
    this.imageVisualPruneTimer = setTimeout((): void => {
      this.imageVisualPruneTimer = 0
      // 裁剪包含全表遍历和全局刷新。若已恢复滚动，交给下一次
      // onFileContentScrollStop 重新安排，避免在滚动中间清理。
      if (this.fileContentScrolling) {
        return
      }
      this.pruneImageVisualStates()
    }, 450)
  }

  private pruneImageVisualStates(): void {
    const keys = Object.keys(this.imageVisualStates)
    if (keys.length <= 768) {
      return
    }

    const keep: Record<string, boolean> = {}
    const keepEntries = (items: FileEntry[], start: number, end: number): void => {
      const lower = Math.max(0, start)
      const upper = Math.min(items.length - 1, Math.max(lower, end))
      for (let index = lower; index <= upper; index += 1) {
        keep[items[index].path] = true
      }
    }

    let visibleItems = this.entries
    let visibleStart = this.fileVisibleStartIndex
    let visibleEnd = this.fileVisibleEndIndex
    if (this.fileViewMode === 'waterfall') {
      visibleItems = this.waterfallEntries
      visibleStart = this.waterfallVisibleStartIndex
      visibleEnd = this.waterfallVisibleEndIndex
    } else if (this.fileViewMode === 'list') {
      visibleStart = Math.max(0, visibleStart - 1)
      visibleEnd = Math.max(visibleStart, visibleEnd - 1)
    }
    // 这个窗口是按【条目索引】算的。网格一行有 N 列，8 个条目只够 2 行 ✗，
    // 顶部几行的视觉状态会被过早裁掉、往回滑就露出空白。按列数放大。
    const prunePadding = 8 * (this.fileViewMode === 'grid' ? this.fileGridColumnCount() : 1)
    keepEntries(visibleItems, visibleStart - prunePadding, visibleEnd + prunePadding)

    // The bounded URI LRU is the source used when a recycled row is mounted
    // again. Keep its state record so a return to a recently visited window
    // does not need to publish the same URI a second time.
    for (const path of this.previewUriOrder) {
      keep[path] = true
    }
    for (const path of Object.keys(this.waterfallVisiblePaths)) {
      if (this.waterfallVisiblePaths[path] === true) {
        keep[path] = true
      }
    }
    for (const entry of this.viewerImages) {
      keep[entry.path] = true
    }
    if (this.viewerImageEntry !== null) {
      keep[this.viewerImageEntry.path] = true
    }
    if (this.viewerEntryTransitionPath.length > 0) {
      keep[this.viewerEntryTransitionPath] = true
    }

    const nextStates: Record<string, ImageVisualState> = {}
    let removed = 0
    for (const key of keys) {
      const state = this.imageVisualStates[key]
      if (keep[key] === true || (state !== undefined && state.thumbnailVisibleRatio > 0)) {
        nextStates[key] = state
      } else {
        removed += 1
      }
    }
    if (removed > 0) {
      this.imageVisualStates = nextStates
      this.imageVisualEpoch += 1
    }
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
    const visualEpoch = this.imageVisualEpoch
    if (visualEpoch < 0) {
      return ''
    }
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
    const _rev = entry.previewRevision
    // Native bitmap maps and the private visual-state map are intentionally
    // outside @State. Reading both scalar epochs makes a targeted source or
    // orientation change re-render without copying all visited rows.
    if (USE_GLOBAL_BITMAP_EPOCH) {
      const epoch = this.viewerBitmapEpoch
      if (epoch < 0) {
        return ''
      }
      const visualEpoch = this.imageVisualEpoch
      if (visualEpoch < 0) {
        return ''
      }
    }
    if (THUMB_PROBE) {
      hilog.info(IMAGE_VIEWER_HILOG_DOMAIN, 'ThumbProbe', `[6-fileImageSource] path=${entry.path}, surface=${surface}, rev=${_rev}`)
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
        this.touchWaterfallBitmap(entry.path)
        return waterfallBitmap.pixelMap
      }
      // Use the durable list thumbnail as an immediate first frame. The
      // waterfall pipeline can still replace it with the column-sized local
      // original after the current scroll settles, without exposing a blank
      // card while that decode is in flight.
      return this.isImage(entry) ? this.previewUri(entry) : this.waterfallUri(entry)
    }
    if (this.isImage(entry)) {
      // The normal file surface is URI-backed. ArkUI owns the bounded
      // thumbnail decode and can reuse its native image cache while scrolling;
      // Image Kit PixelMaps are reserved for viewer transitions.
      return this.previewUri(entry)
    }
    return this.previewUri(entry)
  }

  private fileImageSourceAvailable(entry: FileEntry, surface: ThumbnailSurfaceKind): boolean {
    const _rev = entry.previewRevision
    const source = this.fileImageSource(entry, surface)
    const avail = typeof source === 'string' ? source.length > 0 : true
    if (THUMB_PROBE) {
      hilog.info(IMAGE_VIEWER_HILOG_DOMAIN, 'ThumbProbe', `[5-fileImageSourceAvailable] path=${entry.path}, surface=${surface}, rev=${_rev}, avail=${avail}`)
    }
    return avail
  }

  private fileImageSourceOrientation(entry: FileEntry,
    surface: ThumbnailSurfaceKind): ImageRotateOrientation {
    return typeof this.fileImageSource(entry, surface) === 'string'
      ? this.fileListImageBaseOrientation(entry) : ImageRotateOrientation.UP
  }

  private viewerImageSourceOrientation(entry: FileEntry): ImageRotateOrientation {
    const visualEpoch = this.imageVisualEpoch
    if (visualEpoch < 0) {
      return ImageRotateOrientation.AUTO
    }
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
      // previewUri() can now render directly from the persistent thumbnail
      // index. That hot path intentionally avoids publishing UI state while a
      // row is being recycled, but the shared-element transition still needs
      // the local file so both surfaces can consume the same decoded raster.
      // Recover that path only when entering/leaving the viewer; this keeps
      // scrolling free of filesystem work and preserves the original
      // transition contract.
      const cachedPath = this.repository.cachedThumbnailFast(entry, 'list')
      if (cachedPath.length > 0 && CacheManager.exists(cachedPath)) {
        localPath = cachedPath
        this.previewLocalPaths[entry.path] = cachedPath
        this.previewLocalSignatures[entry.path] = this.previewSignature(entry)
        this.previewCanonicalPaths[entry.path] = false
      }
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
    if (THUMB_DIAG) {
      this.thumbDiagEpochRequested += 1
    }
    if (!THUMB_BATCH_EPOCH) {
      // Baseline：每张完成都立即提交。
      this.traceStateWrite('StateWrite:epoch')
      this.viewerBitmapEpoch += 1
      if (THUMB_DIAG) {
        this.thumbDiagEpochCommitted += 1
        // 两种模式口径一致：Baseline 也要按帧产出窗口汇总。
        this.flushThumbnailDiagWindow()
      }
      return
    }
    // ⚠️ 合并到"下一次 UI frame"，而不是固定 16ms 定时器：
    // 16ms 只是 60Hz 的一帧近似，在 90/120Hz 上已跨帧；且定时器与真实渲染帧不同步，
    // 还会人为增加图片出现的延迟。postRenderFrame 用的是 postFrameCallback，语义正确。
    if (this.thumbDiagBatchingPending) {
      return
    }
    this.thumbDiagBatchingPending = true
    this.postRenderFrame((): void => {
      this.thumbDiagBatchingPending = false
      const startedAt = Date.now()
      this.traceStateWrite('StateWrite:epoch')
      this.viewerBitmapEpoch += 1
      const cost = Date.now() - startedAt
      if (THUMB_DIAG) {
        this.thumbDiagEpochCommitted += 1
        this.thumbDiagCommitMsTotal += cost
        if (cost > this.thumbDiagCommitMsMax) {
          this.thumbDiagCommitMsMax = cost
        }
      }
      this.flushThumbnailDiagWindow()
    })
  }

  /** 每 UI frame 结束产出一次窗口汇总（THUMB_DIAG 关闭时为空操作）。 */
  private flushThumbnailDiagWindow(): void {
    if (!THUMB_DIAG) {
      return
    }
    if (this.thumbDiagFrameCompletions > this.thumbDiagFrameMaxCompletions) {
      this.thumbDiagFrameMaxCompletions = this.thumbDiagFrameCompletions
    }
    this.thumbDiagFrameCompletions = 0
    const now = Date.now()
    if (this.thumbDiagWindowStartAt === 0) {
      this.thumbDiagWindowStartAt = now
      return
    }
    // 每 3 秒汇总一条；测试结束时也会由 reportThumbnailDiag 兜底输出。
    if (now - this.thumbDiagWindowStartAt < 3000) {
      return
    }
    this.reportThumbnailDiag('window')
  }

  private reportThumbnailDiag(reason: string): void {
    if (!THUMB_DIAG) {
      return
    }
    const cloneAvg = this.thumbDiagCloneCount > 0
      ? Math.round(this.thumbDiagCloneMsTotal / this.thumbDiagCloneCount) : 0
    const commitAvg = this.thumbDiagEpochCommitted > 0
      ? Math.round(this.thumbDiagCommitMsTotal / this.thumbDiagEpochCommitted) : 0
    console.info('[ThumbDiag] ' + reason +
      ' finished=' + this.thumbDiagFinished.toString() +
      ' clone=' + this.thumbDiagCloneCount.toString() +
      ' epochReq=' + this.thumbDiagEpochRequested.toString() +
      ' epochCommitted=' + this.thumbDiagEpochCommitted.toString() +
      ' frameMaxCompletions=' + this.thumbDiagFrameMaxCompletions.toString() +
      ' cloneMsAvg=' + cloneAvg.toString() +
      ' cloneMsMax=' + this.thumbDiagCloneMsMax.toString() +
      ' commitMsAvg=' + commitAvg.toString() +
      ' commitMsMax=' + this.thumbDiagCommitMsMax.toString() +
      ' batch=' + (THUMB_BATCH_EPOCH ? 'on' : 'off'))
    this.thumbDiagWindowStartAt = Date.now()
  }

  private installViewerBitmap(target: Record<string, ViewerBitmapRecord>,
    path: string, record: ViewerBitmapRecord): void {
    const isWaterfallTarget = target !== this.viewerPreviewBitmaps &&
      target !== this.viewerOriginalBitmaps
    const previous = target[path]
    // ⚠️ M1a：整体替换 Map（O(n)）。本阶段【刻意不改】，只做计数以便归因。
    const cloneStartedAt = THUMB_DIAG ? Date.now() : 0
    const next: Record<string, ViewerBitmapRecord> = {}
    for (const key of Object.keys(target)) {
      next[key] = target[key]
    }
    next[path] = record
    if (THUMB_DIAG) {
      const cloneCost = Date.now() - cloneStartedAt
      this.thumbDiagCloneCount += 1
      this.thumbDiagCloneMsTotal += cloneCost
      if (cloneCost > this.thumbDiagCloneMsMax) {
        this.thumbDiagCloneMsMax = cloneCost
      }
      this.thumbDiagFinished += 1
      this.thumbDiagFrameCompletions += 1
    }
    if (target === this.viewerPreviewBitmaps) {
      this.viewerPreviewBitmaps = next
      this.viewerPreviewBitmapAliases[path] = false
    } else if (target === this.viewerOriginalBitmaps) {
      this.viewerOriginalBitmaps = next
    } else {
      this.waterfallBitmaps = next
      if (previous !== undefined && previous !== record) {
        const previousBytes = this.waterfallBitmapBytes[path]
        this.waterfallBitmapTotalBytes = Math.max(0,
          this.waterfallBitmapTotalBytes - (previousBytes === undefined ? 0 : previousBytes))
      }
      const bytes = this.waterfallBitmapSize(record)
      this.waterfallBitmapBytes[path] = bytes
      this.waterfallBitmapLastAccessAt[path] = Date.now()
      this.waterfallBitmapTotalBytes += bytes
    }
    if (isWaterfallTarget) {
      if (USE_GLOBAL_BITMAP_EPOCH) {
        this.bumpViewerBitmapEpoch()
      } else {
        this.notifyEntryChanged(path, 'waterfall')
      }
    } else {
      this.bumpViewerBitmapEpoch()
    }
    if (isWaterfallTarget) {
      this.trimWaterfallBitmapCache()
    }
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

  private waterfallBitmapSize(record: ViewerBitmapRecord): number {
    try {
      return Math.max(1, record.pixelMap.getPixelBytesNumber())
    } catch (_) {
      return Math.max(1, record.decodeWidth * record.decodeHeight * 4)
    }
  }

  private touchWaterfallBitmap(path: string): void {
    if (this.waterfallBitmaps[path] !== undefined) {
      this.waterfallBitmapLastAccessAt[path] = Date.now()
    }
  }

  private removeWaterfallBitmapTracking(path: string): void {
    const bytes = this.waterfallBitmapBytes[path]
    if (bytes !== undefined) {
      this.waterfallBitmapTotalBytes = Math.max(0, this.waterfallBitmapTotalBytes - bytes)
    }
    // ArkTS does not support delete on dynamic records. Zeroing the tracking
    // entries is equivalent here because the authoritative bitmap map has
    // already removed the PixelMap and the next install overwrites them.
    this.waterfallBitmapBytes[path] = 0
    this.waterfallBitmapLastAccessAt[path] = 0
  }

  private trimWaterfallBitmapCache(): void {
    while (this.waterfallBitmapTotalBytes > WATERFALL_BITMAP_MEMORY_LIMIT_BYTES) {
      let oldestPath = ''
      let oldestAccess = Number.MAX_SAFE_INTEGER
      for (const path of Object.keys(this.waterfallBitmaps)) {
        if (this.waterfallVisiblePaths[path] === true ||
          (this.viewerPreviewBitmapAliases[path] === true &&
            this.viewerPreviewBitmaps[path] === this.waterfallBitmaps[path])) {
          continue
        }
        const access = this.waterfallBitmapLastAccessAt[path] || 0
        if (access < oldestAccess) {
          oldestPath = path
          oldestAccess = access
        }
      }
      if (oldestPath.length === 0) {
        return
      }
      const record = this.removeViewerBitmap(this.waterfallBitmaps, oldestPath)
      if (record === null) {
        continue
      }
      this.waterfallDecodedPaths[oldestPath] = false
      this.waterfallOriginalUris[oldestPath] = ''
      this.scheduleWaterfallSourceNotify()
      this.viewerBitmapStore.release(record).catch((): void => {})
    }
  }

  private async publishImagePreview(entry: FileEntry, localPath: string,
    canonical: boolean, generation: number): Promise<void> {
    if (generation !== this.previewGeneration || localPath.length === 0) {
      return
    }
    // Normal file rows stay URI-backed. Image Kit metadata/PixelMap work is
    // reserved for the selected viewer image and its shared-element handoff;
    // doing it here for every visible row was the main source of scroll jank.
    this.setPreviewUri(entry, fileUri.getUriFromPath(localPath), localPath, canonical)
    if (this.fileViewMode === 'waterfall' && this.waterfallVisiblePaths[entry.path] === true) {
      this.enqueueWaterfallPreviewGeometry(entry, this.waterfallVisibleStartIndex)
    }
  }

  /**
   * Images, video and audio thumbnails are all published as bounded local
   * URIs. The viewer alone promotes the selected image to a PixelMap when a
   * rotation-aware transition or analysis session needs it.
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
      this.removeWaterfallBitmapTracking(path)
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

  private isPixelMapHeldByActiveStores(pixelMap: image.PixelMap): boolean {
    if (this.viewerReturnSnapshot.source === pixelMap) {
      return true
    }
    for (const key of Object.keys(this.waterfallBitmaps)) {
      const rec = this.waterfallBitmaps[key]
      if (rec !== undefined && rec.pixelMap === pixelMap) {
        return true
      }
    }
    for (const key of Object.keys(this.fileThumbnailBitmaps)) {
      const rec = this.fileThumbnailBitmaps[key]
      if (rec !== undefined && rec.pixelMap === pixelMap) {
        return true
      }
    }
    for (const key of Object.keys(this.viewerPreviewBitmaps)) {
      const rec = this.viewerPreviewBitmaps[key]
      if (rec !== undefined && rec.pixelMap === pixelMap) {
        return true
      }
    }
    for (const key of Object.keys(this.viewerOriginalBitmaps)) {
      const rec = this.viewerOriginalBitmaps[key]
      if (rec !== undefined && rec.pixelMap === pixelMap) {
        return true
      }
    }
    return false
  }

  private enqueuePendingViewerCleanup(
    closingImages: FileEntry[],
    closingPreviewBitmaps: Record<string, ViewerBitmapRecord>,
    closingOriginalBitmaps: Record<string, ViewerBitmapRecord>,
    closingPreviewAliases: Record<string, boolean>
  ): void {
    for (const entry of closingImages) {
      const preview = closingPreviewBitmaps[entry.path]
      if (preview !== undefined && closingPreviewAliases[entry.path] !== true) {
        this.tryEnqueueViewerCleanupItem(preview, entry.path, 'preview')
      }
      const original = closingOriginalBitmaps[entry.path]
      if (original !== undefined) {
        this.tryEnqueueViewerCleanupItem(original, entry.path, 'original')
      }
    }
  }

  private tryEnqueueViewerCleanupItem(
    record: ViewerBitmapRecord,
    path: string,
    kind: 'preview' | 'original'
  ): void {
    if (record === null || record.pixelMap === null || record.pixelMap === undefined) {
      return
    }
    // 1. 同一 PixelMap 实例防重入队（避免 preview 与 original 共享对象时双重释放）
    for (const item of this.pendingViewerCleanupQueue) {
      if (item.record.pixelMap === record.pixelMap) {
        return
      }
    }
    // 2. 若仍被活动 Store 持有，不入待释放队列
    if (this.isPixelMapHeldByActiveStores(record.pixelMap)) {
      return
    }

    let bytes = 0
    try {
      bytes = Math.max(1, record.pixelMap.getPixelBytesNumber())
    } catch (_) {
      bytes = Math.max(1, (record.physicalWidth || 1080) * (record.physicalHeight || 1920) * 4)
    }

    this.pendingViewerCleanupQueue.push({
      record: record,
      path: path,
      kind: kind,
      estimatedBytes: bytes
    })
    this.pendingViewerCleanupEstimatedBytes += bytes
  }

  private cancelViewerCleanupTimer(): void {
    if (this.viewerCleanupTimer !== 0) {
      clearTimeout(this.viewerCleanupTimer)
      this.viewerCleanupTimer = 0
    }
  }

  private noteUserInteraction(): void {
    this.lastUserInteractionMonotonic = this.getMonotonicNow()
    this.cancelViewerCleanupTimer()
  }

  private requestViewerCleanup(delayMs?: number): void {
    if (this.pendingViewerCleanupQueue.length === 0) {
      return
    }
    if (this.viewerCleanupRunning) {
      return
    }

    const isPressure = this.pendingViewerCleanupQueue.length >= 8 ||
      this.pendingViewerCleanupEstimatedBytes >= 120 * 1024 * 1024
    const normalQuietWindow = 120
    const pressureQuietWindow = 40
    const quietWindow = isPressure ? pressureQuietWindow : normalQuietWindow

    let scheduledDelay = typeof delayMs === 'number' ? delayMs : 0
    const timeSinceInteraction = this.getMonotonicNow() - this.lastUserInteractionMonotonic
    if (timeSinceInteraction < quietWindow) {
      scheduledDelay = Math.max(scheduledDelay, quietWindow - timeSinceInteraction)
    }

    this.cancelViewerCleanupTimer()
    this.viewerCleanupTimer = setTimeout((): void => {
      this.viewerCleanupTimer = 0
      this.cleanupOneSlice()
    }, Math.max(16, scheduledDelay))
  }

  private cleanupOneSlice(): void {
    if (this.viewerCleanupRunning) {
      return
    }
    if (this.pendingViewerCleanupQueue.length === 0) {
      return
    }

    // 全量交互守卫：任意交互活跃，坚决不 release
    if (this.showImageViewer ||
      this.viewerClosing ||
      this.viewerClosePending ||
      this.viewerTransitionActive ||
      this.viewerEntryTransitionActive ||
      this.fileContentScrolling ||
      this.fileContentTouchActive) {
      return
    }

    const isPressure = this.pendingViewerCleanupQueue.length >= 8 ||
      this.pendingViewerCleanupEstimatedBytes >= 120 * 1024 * 1024
    const quietWindow = isPressure ? 40 : 120
    const timeSinceInteraction = this.getMonotonicNow() - this.lastUserInteractionMonotonic
    if (timeSinceInteraction < quietWindow) {
      this.requestViewerCleanup(quietWindow - timeSinceInteraction)
      return
    }

    this.viewerCleanupRunning = true
    try {
      const item = this.pendingViewerCleanupQueue[0]
      if (item === undefined) {
        return
      }

      // 1. 若该 PixelMap 已被活动 Store（如瀑布流、文件列表缩略图或重新打开的 viewer）持有：
      //    ownership 已明确转移至该活动 Store，由该 Store 负责生命周期。从队列移除，不 release
      if (this.isPixelMapHeldByActiveStores(item.record.pixelMap)) {
        this.pendingViewerCleanupQueue.shift()
        this.pendingViewerCleanupEstimatedBytes = Math.max(0,
          this.pendingViewerCleanupEstimatedBytes - item.estimatedBytes)
        console.info('[ViewerCleanup] ownership transferred for ' + item.path + ', skipped release')
        return
      }

      // 2. 确认无人持有：立即同步触发释放（检查与释放间无 await，杜绝事件循环插队竞态）
      this.viewerBitmapStore.release(item.record).catch((e: Error): void => {
        console.warn('[ViewerCleanup] release failed: ' + JSON.stringify(e))
      })

      // 3. 成功触发释放后，正式出队并扣减记账内存
      this.pendingViewerCleanupQueue.shift()
      this.pendingViewerCleanupEstimatedBytes = Math.max(0,
        this.pendingViewerCleanupEstimatedBytes - item.estimatedBytes)
      this.returnPerfSession.recordViewerRelease(item.path,
        this.pendingViewerCleanupEstimatedBytes, this.getMonotonicNow())
      console.info('[ViewerCleanup] released slice: path=' + item.path +
        ' kind=' + item.kind + ' remainCount=' + this.pendingViewerCleanupQueue.length.toString() +
        ' remainBytes=' + this.pendingViewerCleanupEstimatedBytes.toString())
    } finally {
      this.viewerCleanupRunning = false
      if (this.pendingViewerCleanupQueue.length > 0) {
        const isPressureNext = this.pendingViewerCleanupQueue.length >= 8 ||
          this.pendingViewerCleanupEstimatedBytes >= 120 * 1024 * 1024
        this.requestViewerCleanup(isPressureNext ? 16 : 32)
      }
    }
  }

  private drainPendingViewerCleanupOnDisappear(): void {
    while (this.pendingViewerCleanupQueue.length > 0) {
      const item = this.pendingViewerCleanupQueue.shift()
      if (item !== undefined && !this.isPixelMapHeldByActiveStores(item.record.pixelMap)) {
        this.viewerBitmapStore.release(item.record).catch((_e: Error): void => {})
      }
    }
    this.pendingViewerCleanupEstimatedBytes = 0
    this.viewerCleanupRunning = false
  }

  private viewerThumbnailUri(entry: FileEntry): string {
    const state = this.imageVisualState(entry.path)
    if (state.transitionThumbnailUri.length > 0) {
      return state.transitionThumbnailUri
    }
    return this.previewUri(entry)
  }

  /**
   * 一次性诊断：记录「点击 → 画面出现/消失」链路上各段的耗时。
   *
   * 用法：把 TAP_TRACE 打开后编译装机，复现「打开图片 / 打开文件夹 / 关闭」
   * 各若干次，再用 `hdc shell hilog` 抓 `[TapTrace]` 行。
   * 日志格式：
   *   `[TapTrace] >>> open-viewer`            一轮开始
   *   `[TapTrace] stage total=NNNms step=MMms | detail`   各打点
   * 出结论后把 TAP_TRACE 改回 false（或整段删除）。
   */
  private tapTraceT0: number = 0
  private tapTraceLast: number = 0

  private tapTraceBegin(label: string): void {
    if (!TAP_TRACE) {
      return
    }
    this.tapTraceT0 = Date.now()
    this.tapTraceLast = this.tapTraceT0
    console.info('[TapTrace] >>> ' + label)
  }

  private tapTrace(stage: string, detail: string = ''): void {
    if (!TAP_TRACE) {
      return
    }
    const now = Date.now()
    console.info('[TapTrace] ' + stage +
      ' total=' + (now - this.tapTraceT0).toString() +
      ' step=' + (now - this.tapTraceLast).toString() +
      (detail.length > 0 ? ' | ' + detail : ''))
    this.tapTraceLast = now
  }

  /**
   * 实验 G：根级 @State 写入的 hitrace 打点。
   * 产生一个零时长的 trace 区间（B/E 同刻），名字即状态变量名。
   * 配套分析：把每个 StateWrite 与其后的第一条 `CustomNodeUpdate name:Index`
   * 配对，统计「触发命中率 × 触发后 rerender 成本」。
   */
  private traceStateWrite(name: string): void {
    if (!STATE_TRACE) {
      return
    }
    hiTraceMeter.startTrace(name, STATE_TRACE_TASK_ID)
    hiTraceMeter.finishTrace(name, STATE_TRACE_TASK_ID)
  }

  /**
   * 实验 H0：条目级局部刷新，仅通知对应索引的 LazyForEach Item 重新求值。
   */
  private notifyEntryChanged(path: string, surfaceHint?: string): void {
    if (STATE_TRACE) {
      this.traceStateWrite('StateWrite:thumbNotify')
    }
    if (surfaceHint === undefined || surfaceHint === 'grid' || surfaceHint === 'list') {
      const listIdx = this.fileEntryDataSource.indexOfPath(path)
      if (THUMB_PROBE) {
        hilog.info(IMAGE_VIEWER_HILOG_DOMAIN, 'ThumbProbe', `[2-notifyEntry] surface=grid/list, path=${path}, listIdx=${listIdx}`)
      }
      if (listIdx >= 0) {
        this.fileEntryDataSource.notifyItemChanged(listIdx)
        // R2：子组件已由 @ObjectLink 局部刷新，这里不能再写 @State 数组
        //（那会重新把根组件标脏，白费 R2）。
        if (!EXPERIMENT_R2_THUMB_CELL &&
          listIdx < this.entries.length && this.entries[listIdx].path === path) {
          this.entries[listIdx] = this.fileEntryDataSource.getData(listIdx)
        }
      }
    }
    if (surfaceHint === undefined || surfaceHint === 'waterfall') {
      const wfIdx = this.waterfallDataSource.indexOfPath(path)
      if (THUMB_PROBE) {
        hilog.info(IMAGE_VIEWER_HILOG_DOMAIN, 'ThumbProbe', `[2-notifyEntry] surface=waterfall, path=${path}, wfIdx=${wfIdx}`)
      }
      if (wfIdx >= 0) {
        this.waterfallDataSource.notifyItemChanged(wfIdx)
        // R2W：瀑布流子组件已由 @ObjectLink 局部刷新，这里不能再写 @State 数组。
        if (!EXPERIMENT_R2_WATERFALL_CELL &&
          wfIdx < this.waterfallEntries.length && this.waterfallEntries[wfIdx].path === path) {
          this.waterfallEntries[wfIdx] = this.waterfallDataSource.getData(wfIdx)
        }
      }
    }
  }

  // 转场/动画期间的点击会被 busy 守卫直接吞掉，用户的感觉就是"点了没反应、
  // 像不能触控"。这里记下最后点的那一个，等这次交互收尾时补上。
  // 只保留最后一个：连点多次时打开最后点的那个才符合直觉。
  private pendingOpenEntry: FileEntry | null = null

  private deferOpenEntry(entry: FileEntry): void {
    this.pendingOpenEntry = entry
    this.tapTrace('deferred-while-busy')
  }

  /** 交互收尾（释放 isBusy）时调用，补上被推迟的那一次点击。 */
  private runPendingOpenEntry(): void {
    const next = this.pendingOpenEntry
    if (next === null || this.isBusy || this.isNavigating) {
      return
    }
    this.pendingOpenEntry = null
    this.openEntry(next).catch((error: Error): void => {
      console.warn('[UgreenOpen] deferred open failed: ' + JSON.stringify(error))
    })
  }

  /**
   * 诊断：把可能"占着触控"的守卫标志一次性打出来。
   * 复现"动画已结束但点不动/滑不动"时看这一行，就知道是谁没释放。
   */
  private traceInteractionGuards(tag: string): void {
    if (!TAP_TRACE) {
      return
    }
    console.info('[GuardTrace] ' + tag +
      ' isBusy=' + this.isBusy.toString() +
      ' isNavigating=' + this.isNavigating.toString() +
      ' pageTransition=' + this.showPageTransition.toString() +
      ' viewerClosing=' + this.viewerClosePending.toString() +
      ' viewerTransition=' + this.viewerTransitionActive.toString() +
      ' entryTransition=' + this.viewerEntryTransitionActive.toString() +
      ' fallbackEntry=' + this.viewerFallbackEntryActive.toString() +
      ' scrolling=' + this.fileContentScrolling.toString() +
      ' scrub=' + this.timelineScrubActive.toString() +
      ' showViewer=' + this.showImageViewer.toString() +
      ' closeRequested=' + this.viewerCloseRequested.toString())
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
    if (typeof waterfallRatio === 'number' && waterfallRatio > 0 &&
      this.waterfallAspectSignatures[entry.path] === this.waterfallEntrySignature(entry)) {
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
    // Symmetric with viewerPageOffsetY: the zoom drag and the pull-to-dismiss
    // drag are separate machines that both translate the same page.
    return index === this.viewerImageIndex
      ? this.imageOffsetX + this.imageDismissOffsetX : 0
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
    // The progress value lives in the private visual-state map. Read the
    // scalar epoch here so the bottom-bar ring is rebuilt when the original
    // reaches 95%/100%, just like the viewer Image source.
    const visualEpoch = this.imageVisualEpoch
    if (visualEpoch < 0) {
      return 0
    }
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
      if (typeof uri === 'string' && uri.length > 0) {
        return uri
      }
      return this.previewUri(entry)
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
    }, false)
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
    this.returnPerfSession.recordThumbnailComplete(entry.path, this.getMonotonicNow())
    this.updateImageVisualState(entry.path, (state: ImageVisualState): void => {
      state.thumbnailIndex = index
      state.thumbnailSurface = surface
      state.transitionThumbnailUri = uri
      state.thumbnailDecodedUri = uri
      // A URI-backed WaterFlow thumbnail may still be rendered with AUTO
      // orientation. Its onComplete source axes are not authoritative for
      // the visible card until Image Kit has resolved EXIF/user rotation.
      // Keep those dimensions out of the viewer frame candidate; the
      // rotation-aware geometry pipeline fills them in instead.
      if (surface !== 'waterfall') {
        state.thumbnailDisplayWidth = displayWidth
        state.thumbnailDisplayHeight = displayHeight
      }
    }, false)
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
    if (this.isAudio(entry)) { this.recordAudioThumbnailArea(entry, surface, area); return }
    if (!this.isImage(entry) || !this.thumbnailSurfaceIsCurrent(surface) ||
      typeof area.width !== 'number' || typeof area.height !== 'number' ||
      typeof area.globalPosition.x !== 'number' || typeof area.globalPosition.y !== 'number') {
      return
    }
    const uri = this.thumbnailSurfaceUri(entry, surface)
    const x = area.globalPosition.x as number
    const y = area.globalPosition.y as number
    const width = area.width as number
    const height = area.height as number
    const existing = this.imageVisualStates[entry.path]
    if (existing === undefined) {
      // 首次：沿用原有创建路径（负责建立 state 记录），之后一律就地更新。
      this.updateImageVisualState(entry.path, (state: ImageVisualState): void => {
        state.thumbnailIndex = index
        state.thumbnailSurface = surface
        state.thumbnailX = x
        state.thumbnailY = y
        state.thumbnailWidth = width
        state.thumbnailHeight = height
        if (uri.length > 0) {
          state.transitionThumbnailUri = uri
        }
      }, false)
      return
    }
    // ⚠️ 就地更新（不拷贝、不新建对象）：本回调在滑动期可达上万次/秒（真机实测），
    // 每次都走 copyImageVisualState 会制造同量级的堆分配 → Young GC 反复触发 → 掉帧。
    // 这些字段的消费方（hasViewerTransitionSource 的视口校验）只要求"值是准的"，
    // 与对象身份无关，所以就地修改即可，行为与原来完全一致。
    existing.thumbnailIndex = index
    existing.thumbnailSurface = surface
    existing.thumbnailX = x
    existing.thumbnailY = y
    existing.thumbnailWidth = width
    existing.thumbnailHeight = height
    if (uri.length > 0 && existing.transitionThumbnailUri !== uri) {
      existing.transitionThumbnailUri = uri
    }
  }

  private recordThumbnailVisibility(entry: FileEntry, index: number,
    surface: ThumbnailSurfaceKind, ratio: number): void {
    if (this.isAudio(entry)) {
      if (this.thumbnailSurfaceIsCurrent(surface)) { this.audioThumbnailVisibility.set(entry.path, ratio) }
      return
    }
    if (!this.isImage(entry) || !this.thumbnailSurfaceIsCurrent(surface)) {
      return
    }
    const uri = this.thumbnailSurfaceUri(entry, surface)
    const clamped = Math.min(1, Math.max(0, ratio))
    const existing = this.imageVisualStates[entry.path]
    if (existing === undefined) {
      // 首次：沿用原有创建路径（负责建立 state 记录），之后一律就地更新。
      this.updateImageVisualState(entry.path, (state: ImageVisualState): void => {
        state.thumbnailIndex = index
        state.thumbnailSurface = surface
        state.thumbnailVisibleRatio = clamped
        if (uri.length > 0) {
          state.transitionThumbnailUri = uri
        }
      }, false)
      return
    }
    // ⚠️ 就地更新（不拷贝、不新建对象）：本回调滑动期约每秒数百次，
    // 原实现每次都走 copyImageVisualState → 多一份堆分配。
    // 消费方（hasViewerTransitionSource 的可见比例校验）只要求"值是准的"，
    // 与对象身份无关，所以就地修改行为完全一致。
    existing.thumbnailIndex = index
    existing.thumbnailSurface = surface
    existing.thumbnailVisibleRatio = clamped
    if (uri.length > 0 && existing.transitionThumbnailUri !== uri) {
      existing.transitionThumbnailUri = uri
    }
    if (this.targetLocateEntryPath.length > 0 && entry.path === this.targetLocateEntryPath && clamped > 0) {
      this.notifyTargetLocateVisible('visibility', 'path=' + entry.name + ' ratio=' + clamped.toString() + ' surface=' + surface)
    }
  }

  private noteLocateItemBuild(entry: FileEntry, index: number): void {
    if (this.locateProgrammaticScrolling) {
      this.locateBuildLazyItemCount += 1
      if (this.locateMinBuildIndex === -1 || index < this.locateMinBuildIndex) {
        this.locateMinBuildIndex = index
      }
      if (this.locateMaxBuildIndex === -1 || index > this.locateMaxBuildIndex) {
        this.locateMaxBuildIndex = index
      }
      if (this.targetLocateEntryPath.length > 0 && entry.path === this.targetLocateEntryPath) {
        const dt = this.locateScrollStartTime > 0 ? (this.getMonotonicNow() - this.locateScrollStartTime) : 0
        this.tapTrace('target-build-item', 'index=' + index.toString() +
          ' totalBuilt=' + this.locateBuildLazyItemCount.toString() +
          ' dt=' + dt.toString() + 'ms')
      }
    }
  }

  private notifyTargetLocateVisible(source: string, detail: string = ''): void {
    if (this.targetLocateEntryPath.length === 0 && !this.locateProgrammaticScrolling) {
      return
    }
    const dt = this.locateScrollStartTime > 0 ? (this.getMonotonicNow() - this.locateScrollStartTime) : 0

    this.targetLocateEntryPath = ''
    this.locateProgrammaticScrolling = false

    let flushedCount = 0
    // 修复缩略图一直占位：仅在无真实手势触控时结束滚动状态并 flush pending queue
    if (!this.fileContentTouchActive) {
      this.fileContentScrolling = false
      ContinuationManager.shared().refresh()
      flushedCount = this.flushPendingVisibleLoads()
    }

    this.tapTrace('target-visible', 'source=' + source + ' ' + detail +
      ' totalBuilt=' + this.locateBuildLazyItemCount.toString() +
      ' builtRange=[' + this.locateMinBuildIndex.toString() + '..' + this.locateMaxBuildIndex.toString() + ']' +
      ' imageLoads=' + flushedCount.toString() +
      ' (intercepted=' + this.locateImagePipelineCount.toString() + ')' +
      ' dt=' + dt.toString() + 'ms')

    if (this.targetLocateResolve !== null) {
      const resolve = this.targetLocateResolve
      this.targetLocateResolve = null
      resolve()
    }
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
    if (this.audioReturnHiddenPath === entry.path) { return true }
    // A shared element must leave the source hierarchy when its target is
    // inserted. Keeping the video thumbnail Image mounted (and merely
    // clearing its id) makes the opening hierarchy contain two real images,
    // so ArkUI has no source-removal event to animate. The image viewer has
    // always used this placeholder swap; apply the same rule to video.
    if (this.showVideoPlayer && this.videoEntry !== null &&
      this.videoEntry.path === entry.path && this.isVideo(entry)) {
      return true
    }
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
    const replaceSource = viewerEntry !== null && viewerEntry.path === entry.path && this.isImage(entry)
    // 🔬 OpenAnimProbe：parent build 期问一次"这个 source 是否会被 Blank 顶掉"
    if (this.openAnimProbeActive() && replaceSource) {
      this.openAnimProbe('sourceReplacedByBlank', 'path=' + entry.path +
        ' showViewer=' + this.showImageViewer.toString() +
        ' entryActive=' + this.viewerEntryTransitionActive.toString() +
        ' geometryBound=' + this.viewerGeometryBound.toString() +
        ' kind=' + this.viewerTransitionKind)
    }
    return replaceSource
  }

  /**
   * 退出共享元素飞行窗口判定：`viewerClosing`（退出动画进行中）且 path = 返回目标。
   * ⚠️ 仅供诊断探针使用；opacity / zIndex 两个实验都已判定无效并撤销，
   *    现在它**不代表任何"隐藏"行为**。
   */
  private inViewerExitFlight(entry: FileEntry): boolean {
    return this.viewerClosing && this.viewerReturnReadyPath.length > 0 &&
      this.viewerReturnReadyPath === entry.path
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
    if (this.videoEntryTransitionActive && !this.showVideoPlayer &&
      this.videoEntryTransitionPath === entry.path && this.isVideo(entry) &&
      this.thumbnailSurfaceIsCurrent(surface)) {
      return this.videoTransitionId(entry.path)
    }
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

  private videoTransitionId(path: string): string {
    return path.length > 0 ? 'ugreen-video-geometry-' + path : ''
  }

  private currentThumbnailSurface(): ThumbnailSurfaceKind {
    if (this.screen !== 'files') {
      return 'none'
    }
    if (this.showSearch) {
      return 'search'
    }
    return this.fileViewMode
  }

  private videoPosterSource(entry: FileEntry): image.PixelMap | string {
    if (this.videoPosterPath === entry.path && this.videoPosterUri.length > 0) {
      return this.videoPosterUri
    }
    const surface = this.currentThumbnailSurface()
    if (surface === 'none') {
      return this.previewUri(entry)
    }
    return this.fileImageSource(entry, surface)
  }

  private videoPosterOrientation(entry: FileEntry): ImageRotateOrientation {
    if (this.videoPosterPath === entry.path && this.videoPosterUri.length > 0) {
      return this.videoPosterFixedOrientation
    }
    const surface = this.currentThumbnailSurface()
    return surface === 'none' ? ImageRotateOrientation.AUTO :
      this.fileImageSourceOrientation(entry, surface)
  }

  private videoPosterAvailable(entry: FileEntry): boolean {
    const source = this.videoPosterSource(entry)
    return typeof source === 'string' ? source.length > 0 : true
  }

  private videoPosterTransitionId(entry: FileEntry): string {
    if (!this.videoEntryTransitionActive ||
      this.videoEntryTransitionPath !== entry.path) {
      return ''
    }
    return this.videoTransitionId(entry.path)
  }

  private clearVideoEntryTransition(): void {
    this.videoEntryTransitionActive = false
    this.videoEntryTransitionPath = ''
    this.videoTransitionKind = 'none'
  }

  private startVideoEntryTransition(entry: FileEntry): boolean {
    this.clearVideoEntryTransition()
    if (this.showVideoPlayer || this.currentThumbnailSurface() === 'none' ||
      !this.videoPosterAvailable(entry)) {
      return false
    }
    this.videoEntryTransitionPath = entry.path
    this.videoTransitionKind = 'entry'
    this.videoEntryTransitionActive = true
    return true
  }

  private startVideoExitTransition(entry: FileEntry): boolean {
    this.clearVideoEntryTransition()
    if (this.currentThumbnailSurface() === 'none' ||
      !this.videoPosterAvailable(entry)) {
      return false
    }
    this.videoEntryTransitionPath = entry.path
    this.videoTransitionKind = 'exit'
    this.videoEntryTransitionActive = true
    return true
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
    if (this.viewerEntryTransitionActive) {
      this.traceStateWrite('StateWrite:vet.off')
      this.viewerEntryTransitionActive = false
    }
    if (this.viewerEntryTransitionPath.length > 0) {
      this.viewerEntryTransitionPath = ''
    }
    if (this.viewerTransitionKind !== 'none') {
      this.viewerTransitionKind = 'none'
    }
    if (this.viewerTransitionLayer !== 'thumbnail') {
      this.viewerTransitionLayer = 'thumbnail'
    }
    if (this.viewerGeometryBound) {
      this.viewerGeometryBound = false
    }
  }

  private startViewerEntryTransition(entry: FileEntry): void {
    this.clearViewerEntryTransition()
    // 关闭共享元素转场时，这里直接返回 → viewerEntryTransitionActive 保持 false，
    // 打开流程自然走"淡入"的 fallback 分支（见 VIEWER_USE_SHARED_ELEMENT_TRANSITION）。
    if (!VIEWER_USE_SHARED_ELEMENT_TRANSITION) {
      return
    }
    this.openAnimProbeAt = this.getMonotonicNow()
    const canBindSource = this.hasViewerTransitionSource(entry, false)
    this.openAnimProbe('startViewerEntryTransition',
      'path=' + entry.path +
      ' expected=' + this.imageTransitionId(entry.path) +
      ' gate=' + canBindSource.toString() +
      ' bitmap=' + (this.viewerPreviewBitmaps[entry.path] !== undefined).toString())
    if (!canBindSource) {
      return
    }
    this.viewerEntryTransitionPath = entry.path
    this.viewerTransitionKind = 'entry'
    this.viewerTransitionLayer = 'thumbnail'
    this.viewerGeometryBound = true
    this.traceStateWrite('StateWrite:vet.on')
    this.viewerEntryTransitionActive = true
    // ── 最小单变量实验（方案 b）：补一次局部刷新，让 source 在动画前真正带上 id ──
    //
    // 背景（OpenAnimProbe 已坐实）：GridThumbCell 并不订阅 vet / geometry 状态，
    // 因此在 `startViewerEntryTransition` → `showImageViewer=true` 之间那个关键静默帧
    // （openImageViewer 里的 nextRenderFrame）里，cell 从不 rebuild → 真实 Image 节点
    // 仍挂着旧的 `geometryTransition('')` → source 被 Blank 顶掉时配对不上
    // → 首次打开没有共享元素动画（代码层却已经打了 entry-source-bound）。
    //
    // 这里只补一次【现有】的局部 invalidation，让该 cell 在 showImageViewer 之前重建并拿到新 id。
    // ⚠️ 这是诊断性的复用：transition 与 preview 是两类状态，正式方案应把 transition 刷新拆成
    //    独立输入（transitionRevision / 显式 @Prop）；本实验只验证"是否只缺一次局部 invalidation"。
    // ⚠️ 只在闸门通过（真的要走共享元素）时才补，fallback 分支不受影响。
    this.notifyEntryChanged(entry.path, 'grid')
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
    this.traceStateWrite('StateWrite:vet.on')
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
  ViewerReturnOverlay(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.page_background'))
        .opacity(this.viewerReturnOverlayBackdropOpacity)
      Stack({ alignContent: Alignment.Center }) {
        Image(this.viewerReturnSnapshot.source)
          .id('viewer-return-image')
          .width(this.viewerReturnSnapshot.frameWidth)
          .height(this.viewerReturnSnapshot.frameHeight)
          .orientation(this.viewerReturnSnapshot.orientation)
          .objectFit(this.viewerReturnSnapshot.fit)
          .syncLoad(true)
          .scale({ x: this.viewerReturnOverlayScale, y: this.viewerReturnOverlayScale })
      }
      .id('viewer-return-frame')
      .width(this.viewerReturnOverlayWidth)
      .height(this.viewerReturnOverlayHeight)
      .position({ x: this.viewerReturnOverlayX, y: this.viewerReturnOverlayY })
      .clip(true)
      .opacity(this.viewerReturnOverlayOpacity)
    }
    .id('viewer-return-overlay')
    .width('100%')
    .height('100%')
    .clip(true)
    .zIndex(30)
    // Pure drawing subtree: None only excludes this Stack; its full-screen
    // backdrop and Image would still take the next gesture's initial Down.
    // Exclude every descendant so Grid keeps the gesture across unmount.
    .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
    .onAppear((): void => {
      this.logViewerReturnOverlay('mounted')
      // postFrameCallback alone can run before this conditional node is built.
      // Arm the single frame sync only after ArkUI has actually inserted it.
      const resolve = this.viewerReturnOverlayMountResolve
      this.viewerReturnOverlayMountResolve = null
      if (resolve !== null) {
        this.postRenderFrame(resolve)
      }
    })
  }

  private recordViewerFrameArea(entry: FileEntry, index: number, area: Area): void {
    if (index !== this.viewerImageIndex || this.viewerClosePending ||
      typeof area.width !== 'number' || typeof area.height !== 'number' ||
      typeof area.globalPosition.x !== 'number' || typeof area.globalPosition.y !== 'number') {
      return
    }
    this.viewerCurrentFramePath = entry.path
    this.viewerCurrentFrame.x = area.globalPosition.x
    this.viewerCurrentFrame.y = area.globalPosition.y
    this.viewerCurrentFrame.width = area.width
    this.viewerCurrentFrame.height = area.height
  }

  private logViewerReturnOverlay(stage: string): void {
    console.info('[ViewerReturnOverlay] session=' + this.closeSessionId.toString() +
      ' stage=' + stage + ' dt=' +
      (this.getMonotonicNow() - this.viewerReturnOverlayStartedAt).toString() +
      ' path=' + this.viewerReturnSnapshot.path +
      ' source=' + (typeof this.viewerReturnSnapshot.source === 'string' ? 'uri' : 'pixelmap') +
      ' target=' + this.viewerReturnSnapshot.hasTarget.toString() +
      ' rect=' + this.viewerReturnOverlayX.toString() + ',' + this.viewerReturnOverlayY.toString() +
      ',' + this.viewerReturnOverlayWidth.toString() + ',' + this.viewerReturnOverlayHeight.toString() +
      ' showViewer=' + this.showImageViewer.toString())
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
        if (this.nasState === 'unavailable' || this.nasState === 'connecting' || this.offlineCacheMode) {
          this.NasConnectionNotice()
        }
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
    .id('viewer-chrome-host')
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
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
      // 🔬 OpenAnimProbe 时间点 4：viewer target 节点出现时刻的 transitionId（只读）
      .onAppear((): void => {
        if (OPEN_ANIM_PROBE) {
          console.info('[OpenAnimProbe] viewerTargetAppear path=' + entry.path +
            ' tid=' + this.viewerImageTransitionId(entry, this.viewerTransitionLayer) +
            ' layer=' + this.viewerTransitionLayer +
            ' kind=' + this.viewerTransitionKind +
            ' geometryBound=' + this.viewerGeometryBound.toString())
        }
      })
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
        // 兜底：高度不许超过父容器。'100%' 取的是【真实布局】，不是会过期的视口状态值
        // —— 旋转瞬间分支可能按旧朝向选错，这一层保证盒子永远不会撑出屏幕。
        .constraintSize({ maxHeight: '100%' })
        .onAreaChange((_, area) => this.recordViewerFrameArea(entry, index, area))
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
        // 兜底：宽度不许超过父容器（同样用 '100%' 取真实布局）。
        .constraintSize({ maxWidth: '100%' })
        .onAreaChange((_, area) => this.recordViewerFrameArea(entry, index, area))
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
      .title({ builder: this.ImageViewerTopOverlay, height: this.topSafeInset() + HeaderStyle.overlayHeight }, {
        barStyle: BarStyle.STACK,
        paddingStart: LengthMetrics.vp(0),
        paddingEnd: LengthMetrics.vp(0),
        backgroundColor: Color.Transparent
      })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],
        [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .width('100%')
      .height(this.topSafeInset() + HeaderStyle.overlayHeight)
      .backgroundColor(Color.Transparent)
      .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  ImageViewerTopOverlay(): void {
    Stack() {
      Row()
        .width('100%')
        .height(this.topSafeInset() + HeaderStyle.overlayHeight)
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

      Row({ space: HeaderStyle.gap }) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_backward'))
            .fontSize(HeaderStyle.iconSize)
            .fontColor([$r('sys.color.icon_primary')])
        }
          .type(ButtonType.Normal)
          .width(HeaderStyle.controlHeight)
          .height(HeaderStyle.controlHeight)
          .borderRadius(HeaderStyle.controlHeight / 2)
          .backgroundColor(Color.Transparent)
          .systemMaterial(this.adaptiveControlMaterial(uiMaterial.ImmersiveStyle.THIN))
          .hitTestBehavior(HitTestMode.Default)
          .monopolizeEvents(true)
          .onClick(() => this.closeImageViewer())
        Text(this.viewerHeaderTitle)
          .fontSize(HeaderStyle.titleSize)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .id('image-header-title')
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
          .maxLines(1)
        if (this.isSearchViewer()) {
          Button() {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.folder'))
                .fontSize(15)
                .fontColor([$r('sys.color.icon_primary')])
              Text('定位到所在目录')
                .fontSize(13)
                .fontColor($r('sys.color.font_primary'))
            }
            .padding({ left: 10, right: 10 })
          }
          .type(ButtonType.Normal)
          .height(HeaderStyle.controlHeight)
          .borderRadius(HeaderStyle.controlHeight / 2)
          .backgroundColor(Color.Transparent)
          .systemMaterial(this.adaptiveControlMaterial(uiMaterial.ImmersiveStyle.THIN))
          .hitTestBehavior(HitTestMode.Default)
          .monopolizeEvents(true)
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Up) {
              this.tapTrace('touch-up', 'locate-btn')
            }
          })
          .onClick(() => this.triggerLocateFromViewer())
        }
      }
      .width('100%')
      .height(this.topSafeInset() + HeaderStyle.overlayHeight)
      .padding({ left: HeaderStyle.sideInset, right: HeaderStyle.sideInset,
        top: this.topSafeInset() + HeaderStyle.topPadding, bottom: HeaderStyle.bottomPadding })
      .hitTestBehavior(HitTestMode.Default)
    }
    .width('100%')
    .height(this.topSafeInset() + HeaderStyle.overlayHeight)
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
    // barFloatingStyle places the 56vp capsule 40vp from the bottom of this
    // 136vp Tabs host. Restrict the host to that exact visual rectangle, then
    // let the material-owning Tabs block image gestures without cutting off
    // its own press light and deformation handling.
    .responseRegion({
      x: Math.max(0, (this.effectivePageWidth() - this.wideBottomBarCapsuleWidth()) / 2),
      y: 40,
      width: this.wideBottomBarCapsuleWidth(),
      height: FLOATING_BAR_HEIGHT_VP
    })
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }

  @Builder
  ImageViewerBarContent(): void {
    Row() {
      this.ImageViewerActionItem($r('sys.symbol.picture_badge_arrow_down'), '保存',
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
      .onAreaChange((_, area) => this.registerSlideItem('viewer', '进度', area,
        () => this.loadCommittedViewerOriginalManually()))
      .onTouch((event: TouchEvent) => this.slideItemTouch('viewer', '进度', event))
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
    .hitTestBehavior(HitTestMode.Default)
  }

  @Builder
  ImageViewerActionItem(icon: Resource, title: string, action: () => void): void {
    Column({ space: 2 }) {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(24)
          .fontColor([$r('sys.color.icon_primary')])
      }
      .width('100%')
      .height(24)

      Text(title)
        .fontSize(12)
        .fontColor($r('sys.color.font_primary'))
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Default)
    .monopolizeEvents(true)
    // 一排按钮上滑动：按下 A、滑到 B 松手 → 触发 B。
    .onAreaChange((_, area) => this.registerSlideItem('viewer', title, area, action))
    .onTouch((event: TouchEvent) => this.slideItemTouch('viewer', title, event))
    .onClick(action)
  }

  @Builder
  ImageViewerMoreButton(): void {
    Row() {
      this.ImageViewerActionItem($r('sys.symbol.more'), '更多',
        () => this.openImageMoreMenu())
    }
    .layoutWeight(1)
    .height('100%')
    .bindPopup(this.showImageMoreMenu, {
      builder: this.ImageViewerMoreContent,
      placement: Placement.Top,
      targetSpace: 6,
      maskColor: Color.Transparent,
      enableArrow: false,
      autoCancel: true,
      radius: 24,
      transition: this.imageMoreMenuTransition(),
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
      if (this.isSearchViewer()) {
        this.ImageViewerMoreRow($r('sys.symbol.folder'), '定位到所在目录',
          () => this.triggerLocateFromViewer(), true)
      }
      this.ImageViewerMoreRow($r('sys.symbol.rotate_left'), '旋转',
        () => this.rotateViewerOverlayImage(), true)
      this.ImageViewerMoreRow($r('sys.symbol.rectangle_and_arrowshape_turn_up_right'), '其他应用打开',
        () => this.openViewerOverlayWithOtherApp(), true)
      this.ImageViewerMoreRow($r('sys.symbol.rename'), '重命名',
        () => this.openRenameFromViewerOverlay(), true)
      this.ImageViewerMoreRow($r('sys.symbol.info_circle'), '详情',
        () => this.openImageDetails(), false)
    }
    .width(Math.min(228, this.effectivePageWidth() - 40))
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(24)
    .hitTestBehavior(HitTestMode.Default)
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
        centerX: '78%',
        centerY: '100%'
      }))
      .combine(TransitionEffect.translate({ y: 28 }))
      .animation({
        duration: 280,
        curve: curves.interpolatingSpring(0, 1, 320, 30)
      })
    const disappear = TransitionEffect.opacity(0)
      .combine(TransitionEffect.scale({
        x: 0.08,
        y: 0.08,
        z: 1,
        centerX: '78%',
        centerY: '100%'
      }))
      .combine(TransitionEffect.translate({ y: 28 }))
      .animation({
        duration: 170,
        curve: Curve.EaseIn
      })
    return TransitionEffect.asymmetric(appear, disappear)
  }

  @Builder
  ImageViewerMoreRow(icon: Resource, title: string, action: () => void, showDivider: boolean): void {
    Column() {
      Button() {
        Row() {
          Text(title)
            .fontSize(16)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
          SymbolGlyph(icon)
            .fontSize(22)
            .fontColor([$r('sys.color.icon_primary')])
            .width(32)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 10, right: 8 })
      }
      .type(ButtonType.Normal)
      .width('100%')
      .height(48)
      .padding(0)
      .borderRadius(14)
      .backgroundColor(Color.Transparent)
      .stateEffect(true)
      // 和其它菜单一样：按下 A、滑到 B 松手 → 执行 B。
      .onAreaChange((_, area) =>
        this.registerSlideItem('viewermenu', title, area, action))
      .onTouch((event: TouchEvent) => this.slideItemTouch('viewermenu', title, event))
      .onClick(action)

      if (showDivider) {
        Divider()
          .strokeWidth(0.5)
          .color($r('sys.color.comp_divider'))
          .margin({ left: 10, right: 10 })
      }
    }
    .width('100%')
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
        // Native dismissal also updates the two-way bound visibility. Keep
        // FIT_CONTENT stable until the sheet and its modal mask have gone.
        onDisappear: (): void => {
          this.showImageDetails = false
          this.imageDetailsEntry = null
        }
      })
  }

  @Builder
  ImageViewerDetailsContent(): void {
    if (this.imageDetailsEntry !== null) {
    Column({ space: 12 }) {
      Row() {
        Text('详情')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text('×')
          .id('image-details-close')
          .fontSize(28)
          .fontColor($r('app.color.text_tertiary'))
          .onClick(() => this.closeImageDetails())
      }
      .width('100%')

      this.ImageDetailsLine('文件名', (this.imageDetailsEntry as FileEntry).name)
      this.ImageDetailsLine('路径', this.entryDisplayPath(this.imageDetailsEntry as FileEntry))
      this.ImageDetailsLine('大小', this.formatSize((this.imageDetailsEntry as FileEntry).size))
      this.ImageDetailsLine('修改时间',
        this.formatTime((this.imageDetailsEntry as FileEntry).modifiedTime))
      this.ImageDetailsLine('文件类型',
        this.fileType(this.imageDetailsEntry as FileEntry).length > 0
          ? this.fileType(this.imageDetailsEntry as FileEntry) : '图片')
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
  AudioPlayerOverlay(): void {
    Stack() {
      AudioPlayerPage({ cover: this.audioCover.length > 0 ? this.audioCover : $r('sys.media.ohos_ic_normal_white_grid_audio'),
        title: this.audioTitle, artist: this.audioArtist,
        format: AudioPlayerPolicy.format(this.audioEntry?.name ?? ''),
        playing: this.audioPlaying, opening: this.audioOpening, coverScale: this.audioTransitionCoverScale,
        busy: this.audioPageBusy(),
        positionMs: this.audioCurrentMs, durationMs: this.audioDurationMs, playMode: this.audioMode,
        lyrics: this.audioLyrics, safeTop: this.topSafeInset(), safeBottom: this.bottomSafeInset(),
        dark: this.isDarkTheme, coverHidden: this.audioCoverHidden,
        onBack: () => this.closeAudioPlayer(), onToggle: () => this.toggleAudio(),
        onPrevious: () => this.skipAudio(-1), onNext: () => this.skipAudio(1),
        onMode: () => this.cycleAudioMode(), onQueue: () => this.openAudioQueue(),
        onDownload: () => { if (this.audioEntry !== null) { this.cacheToLocal(this.audioEntry) } },
        onDetails: () => {
          if (this.audioEntry !== null && !this.audioPageBusy() && this.continuationDialogCount === 0) {
            this.showEntryDetails(this.audioEntry)
          }
        },
        onShare: () => { if (this.audioEntry !== null) { this.shareViewerImage(this.audioEntry) } },
        onSeek: (value: number) => this.seekAudio(value),
        onCoverArea: (area: Area) => this.recordAudioCoverArea(area),
        onCoverVisibility: (ratio: number) => { this.audioCoverVisibleRatio = ratio },
        backButton: () => { this.OfficialBackButton(() => this.closeAudioPlayer()) } })
    }
    .width('100%').height('100%').zIndex(30).id('audio-overlay-root')
    .opacity(this.audioPageOpacity)
    .onAreaChange((_old: Area, area: Area) => {
      this.audioPageOriginX = Number(area.globalPosition.x)
      this.audioPageOriginY = Number(area.globalPosition.y)
    })
    .hitTestBehavior(this.audioClosing ? HitTestMode.BLOCK_DESCENDANTS : HitTestMode.Default)
    .bindSheet($$this.showAudioQueue, this.AudioQueueContent, {
      height: SheetSize.LARGE, dragBar: true, showClose: false,
      backgroundColor: $r('app.color.task_panel_background'),
      onAppear: () => {
        const index = this.audioQueue.findIndex((item: FileEntry) => item.path === this.audioEntry?.path)
        if (index >= 0) { this.audioQueueScroller.scrollToIndex(index, false, ScrollAlign.CENTER) }
      }
    })
  }

  @Builder
  AudioQueueContent(): void {
    TaskPanel({ title: '播放列表', idPrefix: 'audio-queue',
      onClose: () => { this.showAudioQueue = false },
      content: () => { this.AudioQueueList() } })
  }

  @Builder
  AudioQueueList(): void {
        List({ scroller: this.audioQueueScroller }) {
          LazyForEach(this.audioQueueSource, (item: FileEntry) => {
            ListItem() {
              Row({ space: 12 }) {
                SymbolGlyph(item.path === this.audioEntry?.path ? $r('sys.symbol.speaker_wave_2_fill') :
                  $r('sys.symbol.music_note_list')).fontSize(22).fontColor([$r('sys.color.icon_secondary')])
                Text(AudioPlayerPolicy.title(item.name)).fontSize(16).layoutWeight(1).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('sys.color.font_primary'))
              }
              .width('100%').height(FileRowStyle.leadingHeight + FileRowStyle.verticalPadding * 2)
              .padding({ left: 12, right: 12 })
              .onClick(() => {
                if (this.isBusy || this.audioClosing) { return }
                this.showAudioQueue = false
                this.openAudioPlayer(item, true)
              })
            }
          }, (item: FileEntry) => item.path)
        }.width('100%').height('100%').scrollBar(BarState.Auto)
          .contentEndOffset(this.bottomSafeInset() + 16)
  }

  @Builder
  AudioCoverFlight(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack() {
        // Keep the artwork square and animate its render scale. Animating an
        // Image's layout size alone crops its final-sized content mid-flight.
        Image(this.audioFlightSource).width(this.audioFlightBaseSize).height(this.audioFlightBaseSize)
          .draggable(false)
          .objectFit(ImageFit.Cover).syncLoad(true)
          .scale({ x: Math.max(this.audioFlightWidth, this.audioFlightHeight) / this.audioFlightBaseSize,
            y: Math.max(this.audioFlightWidth, this.audioFlightHeight) / this.audioFlightBaseSize })
          .hitTestBehavior(HitTestMode.None)
      }
      .width(this.audioFlightWidth).height(this.audioFlightHeight)
      .renderFit(RenderFit.CENTER).borderRadius(this.audioFlightRadius).clip(true)
      .position({ x: this.audioFlightX, y: this.audioFlightY }).opacity(this.audioFlightOpacity)
      .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
    }
    .width('100%').height('100%').zIndex(31).id('audio-cover-flight-overlay')
    .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
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
          .opacity(this.videoSurfaceOpacity)
          .onLoad(() => this.handleVideoSurfaceLoad())

        if (this.videoPosterAvailable(entry)) {
            Image(this.videoPosterSource(entry))
              .width('100%')
              .height('100%')
              .syncLoad(true)
              .orientation(this.videoPosterOrientation(entry))
              .objectFit(ImageFit.Contain)
              .opacity(this.videoPosterOpacity)
              .geometryTransition(this.videoPosterTransitionId(entry))
              .hitTestBehavior(HitTestMode.None)
        } else if (!this.videoFirstFrame) {
            SymbolGlyph($r('sys.symbol.play'))
              .fontSize(72)
              .fontColor([$r('sys.color.icon_secondary')])
              .opacity(this.videoPosterOpacity)
        }
        if (!this.videoEntryTransitionActive && !this.videoFirstFrame &&
          (!this.videoPrepared || this.videoBufferingPercent < 100)) {
            LoadingProgress()
              .width(32)
              .height(32)
              .color('#2E6BFF')
        }

        // The same gesture state machine as HarmonyCast owns this surface.
        // Header and bottom controls are higher siblings and consume their own input.
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.Transparent)
          .id('video-gesture-surface').accessibilityText('视频手势控制区')
          .onTouch((event: TouchEvent) => this.handleVideoTouch(event))

        if (this.videoGestureFeedback.length > 0) {
          Text(this.videoGestureFeedback)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(18)
            .backgroundColor('#66000000')
            .draggable(false).id('video-gesture-feedback')
            .hitTestBehavior(HitTestMode.None)
        }
        if (this.videoSystemVolume !== undefined) {
          AVVolumePanel({ volumeLevel: this.videoSystemVolume })
            .width(0).height(0).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
        }
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
          this.VideoPlayerControlBar(entry)
        }
          .width('100%')
          .height('100%')
          .zIndex(2)
          .id('video-controls-overlay')
          .opacity(this.videoChromeVisible ? 1 : 0)
          .translate({ x: 0, y: this.videoChromeVisible ? 0 : 18, z: 0 })
          .hitTestBehavior(this.videoChromeVisible
            ? HitTestMode.None : HitTestMode.BLOCK_DESCENDANTS)

        this.VideoPlayerNativeHeader()
      }
    }
    // Keep the original XComponent mounted while PiP is active so the system
    // controller keeps its surface. Shrinking only this host reveals the file
    // page underneath without creating a second video node or stopping AVPlayer.
    .width(this.videoPipBackgrounded ? 1 : '100%')
    .height(this.videoPipBackgrounded ? 1 : '100%')
    .id('video-overlay-root')
    .zIndex(30)
    .backgroundColor(this.videoPipBackgrounded ? Color.Transparent : Color.Black)
    .opacity(this.videoPipBackgrounded ? 1 : this.videoOverlayOpacity)
    .hitTestBehavior(this.videoPipBackgrounded ? HitTestMode.None :
      (this.videoOverlayClosing ? HitTestMode.Block : HitTestMode.Default))
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
      .title({ builder: this.VideoPlayerHeaderContent, height: HeaderStyle.overlayHeight }, {
        barStyle: BarStyle.STACK,
        paddingStart: LengthMetrics.vp(0),
        paddingEnd: LengthMetrics.vp(0),
        backgroundColor: Color.Transparent
      })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],
        [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .width('100%')
      .height(HeaderStyle.overlayHeight)
      .margin({ top: this.videoTopInset() })
      .backgroundColor(Color.Transparent)
      .opacity(this.videoChromeVisible ? 1 : 0)
      .translate({ x: 0, y: this.videoChromeVisible ? 0 : -14, z: 0 })
      .hitTestBehavior(this.videoChromeVisible
        ? HitTestMode.Transparent : HitTestMode.BLOCK_DESCENDANTS)
      .zIndex(3)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) { this.handleVideoControlInteraction(true) }
        else if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.handleVideoControlInteraction(false) }
      })
  }

  @Builder
  VideoPlayerHeaderContent(): void {
    Row({ space: HeaderStyle.gap }) {
    Button() {
      SymbolGlyph($r('sys.symbol.chevron_backward'))
        .fontSize(HeaderStyle.iconSize)
        .fontColor([$r('sys.color.font_on_primary')])
    }
      .type(ButtonType.Normal)
      .width(HeaderStyle.controlHeight)
      .height(HeaderStyle.controlHeight)
      .borderRadius(HeaderStyle.controlHeight / 2)
      .backgroundColor(Color.Transparent)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true, '#44202020'))
      .onClick(() => this.closeVideoPlayer(true))
    Text(this.videoEntry === null ? '' : (this.videoEntry as FileEntry).name)
      .fontSize(HeaderStyle.titleSize)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('sys.color.font_on_primary'))
      .textAlign(TextAlign.Start)
      .id('video-header-title')
      .layoutWeight(1)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
    Button() {
      // Keep the supplied PiP artwork as a hand-drawn vector asset.  The
      // SVG has no raster background, so it stays crisp at every density.
      Image($r('app.media.video_pip_icon'))
        .width(HeaderStyle.iconSize)
        .height(HeaderStyle.iconSize)
        .objectFit(ImageFit.Contain)
        .syncLoad(true)
    }
      .type(ButtonType.Normal)
      .width(HeaderStyle.controlHeight)
      .height(HeaderStyle.controlHeight)
      .backgroundColor(Color.Transparent)
      .borderRadius(HeaderStyle.controlHeight / 2)
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
        .width(HeaderStyle.iconSize)
        .height(HeaderStyle.iconSize)
        .backgroundColor(Color.Transparent)
    }
      .width(HeaderStyle.controlHeight)
      .height(HeaderStyle.controlHeight)
      .borderRadius(HeaderStyle.controlHeight / 2)
      .systemMaterial(this.immersiveMaterial(uiMaterial.ImmersiveStyle.THIN, true, '#44202020'))
    }
      .width('100%')
      .height(HeaderStyle.overlayHeight)
      .padding({ left: HeaderStyle.sideInset, right: HeaderStyle.sideInset,
        top: HeaderStyle.topPadding, bottom: HeaderStyle.bottomPadding })
      .zIndex(3)
  }

  @Builder
  VideoCastIcon(): void {
    Image($r('app.media.video_cast_icon'))
      .width(HeaderStyle.iconSize)
      .height(HeaderStyle.iconSize)
      .objectFit(ImageFit.Contain)
      .fillColor(this.videoCasting
        ? $r('sys.color.icon_emphasize') : $r('sys.color.font_on_primary'))
      .syncLoad(true)
  }

  @Builder
  VideoPlayerControlBar(entry: FileEntry): void {
    Column({ space: 4 }) {
      if (this.videoTransferError(entry).length > 0) {
        Text(this.videoStatusText(entry)).fontSize(12).fontColor('#FFFF8A8A')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
      VideoPlayerControls({ controlWidth: Math.max(128, this.videoViewportWidthVp - 32),
        positionMs: this.videoGestureSeeking ? this.videoGesturePositionMs : this.videoCurrentMs,
        durationMs: this.videoDurationMs,
        bufferedMs: this.videoBufferedTimelineMs(), rate: this.videoCasting ? 1 : this.videoPlaybackRate,
        playing: this.videoPlaying, isEnabled: this.videoPrepared && !this.isBusy,
        timelineReady: this.videoTimelineReady, rotating: this.videoOrientationChanging,
        landscape: this.videoLandscape, rateEnabled: !this.videoCasting,
        ratePending: this.videoRatePending, ratePanel: this.videoRatePanel,
        onToggle: () => this.toggleVideo(), onSeek: (value: number) => this.seekVideo(value),
        onSeeking: (active: boolean) => {
          this.videoSeekDragging = active
          if (active) { this.clearVideoChromeTimer() } else { this.scheduleVideoChromeHide() }
        },
        onInteraction: (active: boolean) => this.handleVideoControlInteraction(active),
        onRate: (rate: number) => this.setVideoPlaybackRate(rate),
        onRatePanel: (visible: boolean) => {
          this.videoRatePanel = visible
          if (visible) { this.cancelVideoGestures(); this.clearVideoChromeTimer() }
          else { this.scheduleVideoChromeHide() }
        },
        onRotate: () => { this.videoRatePanel = false; this.rotateVideoInterface() } })
    }
      .width(Math.max(128, this.videoViewportWidthVp - 32))
      .margin({ bottom: this.videoBottomInset() })
      .hitTestBehavior(HitTestMode.Default)
  }

  private immersiveMaterial(style: uiMaterial.ImmersiveStyle, interactive: boolean = true,
    materialColor: string = '', applyShadow: boolean = true): uiMaterial.Material {
    const options: uiMaterial.ImmersiveOptions = {
      style: style,
      interactive: interactive,
      applyShadow: applyShadow,
      lightEffect: { color: '#FFFFFFFF' }
    }
    if (materialColor.length > 0) {
      options.materialColor = materialColor
    }
    return new uiMaterial.ImmersiveMaterial(options)
  }

  /**
   * Material for small floating controls whose glyphs sit over changing page
   * content. Keep automatic inversion on this narrow subtree only; menus and
   * dialogs continue to use immersiveMaterial without broad color processing.
   */
  private adaptiveControlMaterial(style: uiMaterial.ImmersiveStyle = uiMaterial.ImmersiveStyle.THIN,
    interactive: boolean = true, materialColor: string = ''): uiMaterial.Material {
    const options: uiMaterial.ImmersiveOptions = {
      style: style,
      colorInvert: true,
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
    // The page's own UIContext, not the module-level promptAction: the global
    // one resolves against whichever context is current, which is wrong (and
    // fails outright) when the call comes from a dismissing subwindow such as
    // the long-press menu.
    this.getUIContext().getPromptAction().showToast({
      message: message,
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THIN)
    })
  }

  private reportError(error: Object, title: string = '操作失败'): void {
    if (error instanceof UgreenError && error.kind === UgreenErrorKind.NAS_UNAVAILABLE && this.screen !== 'login') {
      const mutation = title.includes('复制') || title.includes('移动') || title.includes('删除') ||
        title.includes('重命名') || title.includes('创建') || title.includes('还原')
      this.showImmersiveToast(mutation ? title + '，结果尚未确认，请恢复连接后检查' :
        'NAS 暂时无法连接，已缓存内容仍可浏览')
      return
    }
    this.presentErrorMessage(readableUgreenError(error), title)
  }

  private presentErrorMessage(message: string, title: string = '操作失败'): void {
    const normalized = message.trim().length > 0 ? message.trim() : '操作失败，请稍后重试'
    this.errorText = normalized
    if (this.errorDialogShowing) {
      return
    }
    // Every failure in the app funnels through here, so this is the whole
    // failure cue: one place, and only for a dialog that is actually going to
    // be shown (the guard above already folded away repeats).
    HapticFeedback.failure()
    this.errorDialogShowing = true
    this.showErrorDialog(normalized, title)
  }

  private async showErrorDialog(message: string, title: string): Promise<void> {
    try {
      await this.showTrackedDialog({
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
      paths.push(...this.albumUpload.protectedPaths())
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
    this.scheduleImageVisualNotify()
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
        (tasks: UploadTaskRecord[]): void => {
          this.uploadTasks = tasks.slice()
          this.syncImportedUploads(tasks)
        })
      await this.albumUpload.initialize(context as common.UIAbilityContext, this.repository, this.networkPolicy,
        (jobs: AlbumUploadJob[]): void => { this.albumUploadJobs = jobs },
        (): void => {})
      this.albumUpload.setForeground(this.gestureSharePageVisible && !this.abilityInBackground)
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
    NasConnection.shared().setPhoneOffline(this.networkClass === 'offline')
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
    if (value && !this.offlineCacheMode) { this.videoTransferManager.resumeAwaitingNas(true) }
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
      const storedAddress = await this.loginPreferences.get('remember_address', false)
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
      if (typeof storedAddress === 'boolean') {
        this.rememberAddress = storedAddress
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
      this.offlineProfile = OfflineAccountProfile.read(
        String(await this.loginPreferences.get('offline_account_v1', '')), this.linkId, this.username)
      if (this.autoLogin && this.rememberPassword && this.linkId.length > 0 &&
        this.username.length > 0 && this.password.length > 0) {
        this.silentAutoLogin = true
        // Do not render the login card during startup recovery. Show the
        // normal file-page shell while the session is restored in background.
        this.screen = 'files'
        this.selectedBottomTab = 'home'
        this.currentPath = ''
        this.replaceEntries([])
        this.updateTopTitle('个人空间')
        this.updateBottomBarVisibility(false)
        try {
          await this.handleLogin(true)
        } finally {
          this.silentAutoLogin = false
        }
      } else if (this.autoLogin && this.linkId.length > 0) {
        // 还没有保存的凭据时，先把记住的地址解析好（凭据由系统密码保险箱填充）
        await this.handleResolve()
      }
    } catch (_) {
      // Login remains available with empty fields if local preferences are unavailable.
    } finally {
      // Submit the restored destination beneath the opaque launch surface before revealing it.
      await this.nextRenderFrame()
      this.startupRestoring = false
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
      await this.loginPreferences.put('remember_address', this.rememberAddress)
      await this.loginPreferences.put('auto_login', this.autoLogin)
      if (!this.rememberPassword || !this.autoLogin) {
        this.offlineProfile = null
        await this.loginPreferences.put('offline_account_v1', '')
      }
      await this.loginPreferences.flush()
    } catch (_) {
      // The login flow must not fail only because preferences cannot be written.
    }
  }

  private scheduleOfflineProfileSave(): void {
    if (this.offlineProfileTimer !== 0) { clearTimeout(this.offlineProfileTimer) }
    if (!this.rememberPassword || !this.autoLogin || this.offlineCacheMode ||
      this.repository.sessionIdentity().length === 0) { this.offlineProfileTimer = 0; return }
    this.offlineProfileTimer = setTimeout((): void => {
      this.offlineProfileTimer = 0
      this.saveOfflineProfile().catch(() => {})
    }, 1000)
  }

  private async saveOfflineProfile(): Promise<void> {
    if (!this.rememberPassword || !this.autoLogin || this.offlineCacheMode || this.loginPreferences === null) { return }
    const identity = this.repository.sessionIdentity()
    const separator = identity.lastIndexOf('|')
    if (separator <= 0) { return }
    const profile = new OfflineAccountProfile()
    profile.linkId = this.linkId
    profile.username = this.username
    profile.baseUrl = identity.substring(0, separator)
    profile.uid = identity.substring(separator + 1)
    profile.path = this.currentPath
    profile.rootType = this.currentRootType
    profile.personalRootType = this.personalRootEntriesType
    profile.rootKind = this.rootKind
    this.offlineProfile = profile
    try {
      await this.loginPreferences.put('offline_account_v1', JSON.stringify(profile))
      await this.loginPreferences.flush()
    } catch (_) {}
  }

  private async openOfflineCache(): Promise<boolean> {
    const profile = this.offlineProfile
    if (profile === null || profile.linkId !== this.linkId || profile.username !== this.username ||
      !this.autoLogin || !this.rememberPassword) { return false }
    this.baseUrl = profile.baseUrl
    this.repository.restoreOfflineIdentity(profile.baseUrl, profile.uid)
    this.offlineCacheMode = true
    await this.ensureCacheState()
    this.rootKind = profile.rootKind
    this.selectedBottomTab = profile.rootKind === 'personal' ? 'home' : 'shared'
    this.personalRootEntriesType = profile.personalRootType
    try { this.personalRoots = await this.repository.list('', profile.personalRootType) } catch (_) {}
    try { this.sharedRoots = await this.repository.list('', 3) } catch (_) {}
    this.currentPath = profile.path
    this.currentRootType = profile.rootType
    let cached: FileEntry[] = []
    if (profile.path.length === 0) { cached = this.rootKind === 'personal' ? this.personalRoots : this.sharedRoots }
    else {
      try {
        const snapshot = await this.repository.ensureDirectoryIndex(profile.path, profile.rootType)
        cached = snapshot.entries
        this.setCurrentPageState(Math.max(1, Math.ceil(cached.length / 200)), false)
      } catch (_) {
        try {
          const page = await this.repository.listPage(profile.path, profile.rootType, 1)
          cached = page.entries
          this.setCurrentPageState(page.pageIndex, page.hasMore)
        } catch (_) {
          this.currentPath = ''
          this.currentRootType = this.rootKind === 'personal' ? profile.personalRootType : 3
          cached = this.rootKind === 'personal' ? this.personalRoots : this.sharedRoots
          this.setCurrentPageState(1, false)
        }
      }
    }
    this.navigationStack = this.currentPath.length > 0 ? [''] : []
    this.navigationEntryStack = []
    this.navigationRootTypeStack = []
    this.navigationViewStateStack = []
    this.navigationPageIndexStack = []
    this.navigationPageHasMoreStack = []
    this.replaceEntries(cached)
    this.applyPreferredViewMode()
    this.updateTopTitle(this.fileTitle(this.currentPath))
    this.screen = 'files'
    this.updateBottomBarVisibility(false)
    return true
  }

  private async retryNasConnection(): Promise<void> {
    await this.networkPolicy.refresh()
    if (this.networkPolicy.current() === 'offline') {
      this.showImmersiveToast('手机暂无网络，请先连接网络')
      return
    }
    if (NasConnection.shared().current() !== 'online') { await NasConnection.shared().retryNow() }
    if (NasConnection.shared().current() === 'online') {
      this.nasRecoveryPending = true
      this.scheduleNasRecovery()
    }
  }

  private scheduleNasRecovery(): void {
    if (!this.nasRecoveryPending || this.nasRecoveryTimer !== 0 ||
      !this.gestureSharePageVisible || this.abilityInBackground) { return }
    this.nasRecoveryTimer = setTimeout((): void => {
      this.nasRecoveryTimer = 0
      if (!this.nasRecoveryPending || !NasConnection.shared().canRequest() ||
        !this.gestureSharePageVisible || this.abilityInBackground) { return }
      if (this.isBusy || this.isNavigating || this.fileContentScrolling || this.imageTouchActive ||
        this.viewerClosePending || this.viewerReturnOverlayVisible || this.showPageTransition || this.dragSelectionPanActive) {
        this.scheduleNasRecovery()
        return
      }
      if (this.offlineCacheMode) {
        if (this.nasSessionRecovery === null) {
          this.nasSessionRecovery = this.recoverOfflineSession().finally((): void => {
            this.nasSessionRecovery = null
          })
        }
        return
      }
      this.nasRecoveryPending = false
      this.videoTransferManager.resumeAwaitingNas(this.networkClass === 'unmetered' || this.meteredDownloadContinue)
      if (this.showImageViewer) {
        this.prefetchViewerImages(this.viewerImageIndex)
        const entry = this.committedViewerEntry()
        if (entry !== null) { this.ensureViewerImageFrame(entry, false) }
      } else if (this.screen === 'files') {
        this.flushPendingVisibleLoads()
        this.warmTimelineVisibleEntries()
      }
    }, 300)
  }

  private async recoverOfflineSession(): Promise<void> {
    const profile = this.offlineProfile
    if (profile === null || this.screen === 'login') { return }
    try {
      const restored = await this.repository.restoreSession()
      if (profile !== this.offlineProfile || String(this.screen) === 'login') { return }
      if (!restored) {
        this.nasRecoveryPending = false
        this.offlineCacheMode = false
        this.screen = 'login'
        this.presentErrorMessage('登录状态已失效，请重新登录', '需要登录')
        return
      }
      if (this.repository.sessionIdentity() !== profile.baseUrl + '|' + profile.uid) {
        this.nasRecoveryPending = false
        this.offlineCacheMode = false
        this.offlineProfile = null
        this.repository.logout()
        this.replaceEntries([])
        this.resetPreviewState()
        this.screen = 'login'
        if (this.loginPreferences !== null) {
          await this.loginPreferences.put('offline_account_v1', '')
          await this.loginPreferences.flush()
        }
        this.presentErrorMessage('账号信息已变化，请重新登录', '需要登录')
        return
      }
      if (this.entries.length === 0 && !this.showImageViewer) { await this.loadRoot() }
      this.offlineCacheMode = false
      await this.refreshVideoManager()
      await this.ensureDownloadState()
      if (profile !== this.offlineProfile || String(this.screen) === 'login') { return }
      await this.downloadQueue.setReady(true)
      if (profile !== this.offlineProfile || String(this.screen) === 'login') { return }
      await this.uploadQueue.setReady(true)
      await this.albumUpload.setReady(true)
      await this.saveOfflineProfile()
      this.scheduleNasRecovery()
    } catch (error) {
      if (!(error instanceof UgreenError) || error.kind !== UgreenErrorKind.NAS_UNAVAILABLE) {
        this.nasRecoveryPending = false
        this.reportError(error as Object, '连接恢复失败')
      }
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
    this.dismissKeyboard()
    this.searchSession = null
    this.searchResultCache = {}
    this.searchScrollOffset = 0
    this.showSearch = false
    this.searchDraft = ''
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
    this.searchDraft = session.query
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
    this.showSearch = true
    this.updateTopTitle(this.fileTitle(this.currentPath))
    this.updateBottomBarVisibility(true)
    const offset = this.searchScrollOffset
    setTimeout((): void => {
      if (this.showSearch) {
        this.searchResultScroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false })
      }
    }, 0)
  }

  private dismissKeyboard(): void {
    try {
      this.searchController.stopEditing()
    } catch (_) {}
    try {
      this.getUIContext().getFocusController().clearFocus()
    } catch (_) {}
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
    this.searchDraft = ''
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
    this.dismissKeyboard()
    this.exitSearchToOrigin()
  }

  private exitSearchToOrigin(): void {
    const session = this.searchSession
    this.discardSearchSession()
    if (session !== null) {
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
      this.updateTopTitle(this.fileTitle(this.currentPath))
      this.restoreDirectoryViewState(session.originViewState)
    }
  }

  private captureDirectoryViewState(): DirectoryViewState {
    return {
      mode: this.fileViewMode,
      offset: this.captureFileViewOffset(this.fileViewMode),
      anchor: this.fileViewMode === 'waterfall' ? this.captureFileViewAnchor() : null
    }
  }

  private defaultViewMode(kind: DefaultViewKind): FileViewMode {
    if (kind === 'photo') { return this.defaultPhotoViewMode }
    return kind === 'audio' ? this.defaultAudioViewMode : this.defaultFileViewMode
  }

  private preferredViewMode(): FileViewMode {
    return this.defaultViewMode(this.currentDirectoryIsPhotoAlbum ? 'photo' :
      (this.currentDirectoryIsAudioAlbum ? 'audio' : 'file'))
  }

  private async ensureViewState(): Promise<void> {
    if (this.viewPreferences !== null) {
      return
    }
    try {
      this.viewPreferences = await preferences.getPreferences(getContext(this), 'ugreen-view-settings')
      const storedFile = await this.viewPreferences.get('default_file_mode', 'list')
      const storedPhoto = await this.viewPreferences.get('default_photo_mode', 'grid')
      // Audio starts in list mode independently of the ordinary-file default.
      const storedAudio = await this.viewPreferences.get('default_audio_mode', '')
      if (storedFile === 'list' || storedFile === 'grid') {
        this.defaultFileViewMode = storedFile
      }
      if (storedPhoto === 'list' || storedPhoto === 'grid' || storedPhoto === 'waterfall') {
        this.defaultPhotoViewMode = storedPhoto
      }
      this.defaultAudioViewMode = storedAudio === 'list' || storedAudio === 'grid'
        ? storedAudio : 'list'
      if (storedAudio !== 'list' && storedAudio !== 'grid') {
        // Persist the initial audio choice once; saved user choices stay intact.
        await this.viewPreferences.put('default_audio_mode', this.defaultAudioViewMode)
        await this.viewPreferences.flush()
      }
      this.applyPreferredViewMode()
    } catch (error) {
      console.warn('[UgreenView] load preferences failed: ' + JSON.stringify(error))
    }
  }

  private async setDefaultViewMode(kind: DefaultViewKind, mode: FileViewMode): Promise<void> {
    if (kind !== 'photo' && mode === 'waterfall') { return }
    try {
      await this.ensureViewState()
      if (kind === 'photo') { this.defaultPhotoViewMode = mode }
      else if (kind === 'audio') { this.defaultAudioViewMode = mode }
      else { this.defaultFileViewMode = mode }
      this.applyPreferredViewMode()
      if (this.viewPreferences === null) { return }
      await this.viewPreferences.put('default_' + kind + '_mode', mode)
      await this.viewPreferences.flush()
    } catch (error) {
      console.warn('[UgreenView] save preferences failed: ' + JSON.stringify(error))
    }
  }

  /** 把设置里的默认落到当前视图（方案 A：手动切换只在本次停留期间有效）。 */
  /**
   * 根级界面 = 【强制列表模式】。不看设置里的默认视图，也不允许右下角切换按钮生效。
   *
   * 视图规则一共就四种情况（其它一律跟设置走）：
   * | 界面                        | 路径形态                          | 视图          |
   * |----------------------------|----------------------------------|---------------|
   * | 根目录（个人空间根/共享根） | 空字符串（currentPath === ''）    | 🔒 强制列表   |
   * | 用户空间主界面（用户根）     | /home/<登录用户名> 或 /<登录用户名> | 🔒 强制列表   |
   * | 共享主界面（共享根）         | 空字符串（同上第一条覆盖）         | 🔒 强制列表   |
   * | 其它一切目录（含"个人空间里   | 更深                              | ⚙️ 跟设置走   |
   * | 第一个文件夹"）              |                                  |               |
   *
   * ⚠️ 两个容易搞错的地方（都踩过）：
   * 1. **不要**把 findDefaultPersonalDirectory() 的结果当"用户根"——它虽然优先返回
   *    /home/<用户名>（那确实是用户根 ✓），但以前还有一条"personalRoots 只有一个就用它"的
   *    兜底 ✗，会把【普通文件夹】当成根 ✗。那条已删 ✓。isUserRootPath() 现在只认路径形态 ✓。
   * 2. **不要**把"登录落点"当成"用户根"之外的东西 ✗ —— 落点统一为 /home/<用户名> ✓
   *    （openDefaultPersonalDirectory / loadRoot 都是 ✓），所以两端打开的层级一致 ✓。
   */
  private isRootListing(): boolean {
    if (this.currentPath.length === 0) {
      return true
    }
    if (this.rootKind === 'shared') {
      return false
    }
    if (this.rootKind === 'personal') {
      return this.isUserRootPath(this.currentPath)
    }
    return false
  }

  private applyPreferredViewMode(): void {
    if (this.screen !== 'files' || this.showSearch) {
      return
    }
    // 根级界面（用户空间主界面 / 共享主界面 / 根目录）强制列表，不看设置也不看记录。
    if (this.isRootListing()) {
      if (this.fileViewMode !== 'list') {
        if (this.fileViewMode === 'waterfall') {
          this.stopWaterfallPipeline()
        }
        this.fileViewMode = 'list'
        this.waterfallAnchor = null
      }
      return
    }
    // 该目录本次运行期间被手动切过 → 保持那个模式；否则用设置里的默认视图。
    const recorded = this.directoryViewModeOverrides[
      this.currentRootType.toString() + ':' + this.currentPath]
    const preferred = recorded !== undefined ? recorded : this.preferredViewMode()
    if (this.fileViewMode === preferred) {
      return
    }
    if (this.fileViewMode === 'waterfall') {
      this.stopWaterfallPipeline()
    }
    if (preferred === 'waterfall') {
      this.prepareWaterfallPipeline()
    }
    this.fileViewMode = preferred
    this.waterfallAnchor = null
  }

  private restoreDirectoryViewState(state: DirectoryViewState | null): void {
    if (state === null || this.screen !== 'files' || this.showSearch) {
      return
    }
    // A directory can change while its snapshot is suspended. Do not force an
    // invalid WaterFlow mode on a directory that no longer contains images.
    // 方案 A：视图模式由设置决定，不再恢复各目录自己的模式；
    // 位置只在「当初存的就是同一个模式」时才恢复，否则偏移量对不上。
    this.applyPreferredViewMode()
    if (state.mode !== this.fileViewMode) {
      return
    }
    this.waterfallAnchorRestoreToken += 1
    const token = this.waterfallAnchorRestoreToken
    setTimeout((): void => {
      this.restoreFileViewModePosition(state.mode, state.anchor, state.offset, token, 0)
    }, 0)
  }

  private settleDirectoryViewStateForTransition(state: DirectoryViewState | null): void {
    if (this.screen !== 'files' || this.showSearch) {
      return
    }
    // 同上：模式来自设置，位置只在模式一致时恢复。
    this.applyPreferredViewMode()
    if (state === null || state.mode !== this.fileViewMode) {
      return
    }
    this.waterfallAnchorRestoreToken += 1
    const token = this.waterfallAnchorRestoreToken
    // The incoming container has already completed its first layout frame.
    // Restore it once while it is still outside the viewport; retrying every
    // 48 ms would relayout the page throughout the horizontal transition.
    this.restoreFileViewModePosition(state.mode, state.anchor, state.offset, token, 0, 0)
  }

  private settleNewDirectoryAtTopForTransition(): void {
    // List, Grid and WaterFlow reuse their Scroller across directory pages.
    // Reset the incoming page while it is still staged offscreen so a new
    // child never inherits the offset of the directory that launched it.
    this.waterfallAnchorRestoreToken += 1
    try {
      const scroller = this.fileViewMode === 'waterfall'
        ? this.waterfallScroller : this.fileListScroller
      scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false })
    } catch (_) {
      // transitionFileContent calls this after the first incoming layout.
    }
  }

  private toggleFileViewMode(): void {
    if (this.isBusy || this.showSearch) {
      return
    }
    // 根级界面强制列表，不给切（避免出现"主界面变成网格"）
    if (this.isRootListing()) {
      return
    }
    const sourceMode = this.fileViewMode
    const anchor = this.captureFileViewAnchor()
    const sourceOffset = this.captureFileViewOffset(sourceMode)
    // Ordinary folders still keep the existing list/grid switch. The
    // waterfall mode is only a valid target after an image has appeared in
    // the already-loaded metadata for this directory.
    const nextMode: FileViewMode = this.currentDirectoryIsPhotoAlbum
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
    // 记住"这个目录被手动切到过哪种模式"，返回时保持（本次运行期间有效）。
    this.directoryViewModeOverrides[this.currentRootType.toString() + ':' + this.currentPath] = nextMode
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
    token: number, attempt: number, maxAttempts: number = 8): void {
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
      this.restoreFileViewAnchor(anchor, token, 0, maxAttempts)
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
    if (attempt < maxAttempts && token === this.waterfallAnchorRestoreToken) {
      setTimeout((): void => {
        this.restoreFileViewModePosition(sourceMode, anchor, sourceOffset,
          token, attempt + 1, maxAttempts)
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
    attempt: number = 0, maxAttempts: number = 8): void {
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
    const maxRestoreAttempts = isWaterfall ? maxAttempts : 0
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
        this.restoreFileViewAnchor(anchor, token, attempt + 1, maxAttempts)
      }, 48)
    }
    this.waterfallAnchor = null
  }

  private prepareWaterfallPipeline(): void {
    this.waterfallGeneration += 1
    this.waterfallGeometryQueue.cancelPending()
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
    this.waterfallSourceEpoch += 1
  }

  private stopWaterfallPipeline(): void {
    // A generation change makes in-flight HTTP work self-cancel through its
    // continuation callback. Completed originals remain in the normal cache.
    this.waterfallGeneration += 1
    this.waterfallGeometryQueue.cancelPending()
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
    this.waterfallSourceEpoch += 1
    const bitmaps = this.waterfallBitmaps
    this.waterfallBitmaps = {}
    this.waterfallBitmapBytes = {}
    this.waterfallBitmapLastAccessAt = {}
    this.waterfallBitmapTotalBytes = 0
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
    const sourceEpoch = this.waterfallSourceEpoch
    if (sourceEpoch < 0) {
      return ''
    }
    if (this.waterfallVisiblePaths[entry.path] !== true) {
      return ''
    }
    const uri = this.waterfallOriginalUris[entry.path]
    return typeof uri === 'string' ? uri : ''
  }

  private resolvedWaterfallAspectRatio(entry: FileEntry): number {
    const aspectEpoch = this.waterfallAspectEpoch
    if (aspectEpoch < 0) {
      return 0
    }
    const value = this.waterfallAspectRatios[entry.path]
    // This cache contains the final Image Kit raster ratio after EXIF and the
    // persisted user rotation. WaterFlow must measure the same axes that the
    // Image node renders.
    if (typeof value === 'number' && value > 0 &&
      this.waterfallAspectSignatures[entry.path] === this.waterfallEntrySignature(entry)) {
      return value
    }
    return 0
  }

  private waterfallAspectRatioReady(entry: FileEntry): boolean {
    return this.resolvedWaterfallAspectRatio(entry) > 0
  }

  private waterfallAspectRatio(entry: FileEntry): number {
    const ratio = this.resolvedWaterfallAspectRatio(entry)
    return ratio > 0 ? ratio : 1
  }

  /**
   * 实验 B′ 专用：网格图片的解码目标尺寸（**严格保持源图比例**）。
   *
   * · 返回 null → 不设置 sourceSize（基线）
   * · 否则返回 {width, height}，宽高严格等于源图比例，且两轴都 ≤ 源尺寸
   *
   * ⚠️ 两条硬约束（都踩过坑）：
   *   1. 绝不能传正方形：源是 512×384 时按正方形缩放会【改变显示比例】。
   *   2. 绝不能超过源尺寸：会触发 `JPEGHWDECODER failed to do decode` → 白屏。
   * 源尺寸取状态里已知的解码尺寸（渲染路径零 IO）；两者未知时不设置，宁可走基线。
   */
  private gridSourceSizeFor(entry: FileEntry): ThumbnailSize | null {
    const target = EXPERIMENT_GRID_SOURCE_SIZE
    if (target <= 0) {
      return null
    }
    const state = this.imageVisualState(entry.path)
    let srcW = state.thumbnailDisplayWidth
    let srcH = state.thumbnailDisplayHeight
    if (!(srcW > 0) || !(srcH > 0)) {
      // 退到物理尺寸；仍未知则本次不设置（不做任何猜测，避免变形或解码失败）。
      srcW = state.physicalWidth
      srcH = state.physicalHeight
      if (!(srcW > 0) || !(srcH > 0)) {
        return null
      }
    }
    // 方案 A：针对 Grid 1:1 正方形单元格以 Cover 渲染的特性，
    // 统一以短边限制在 target（320px），且绝不反向放大（限制最大 decode size）。
    // 比例始终严格不变，Cover 裁剪保证点对点清晰，避免大缩略图（如 960x648）显存浪费。
    const minDim = Math.min(srcW, srcH)
    const scale = Math.min(target / minDim, 1)
    const width = Math.max(1, Math.round(srcW * scale))
    const height = Math.max(1, Math.round(srcH * scale))
    const result: ThumbnailSize = { width: width, height: height }
    return result
  }

  /**
   * 实验 B′/F：解码目标宽度（0 = 本次不设置 sourceSize）。 */
  private gridSourceWidth(entry: FileEntry): number {
    const size = this.gridSourceSizeFor(entry)
    return size === null ? 0 : size.width
  }

  /**
   * 实验 B′/F：解码目标高度（0 = 本次不设置 sourceSize）。 */
  private gridSourceHeight(entry: FileEntry): number {
    const size = this.gridSourceSizeFor(entry)
    return size === null ? 0 : size.height
  }

  /**
   * R2 修复：网格项"一次算完"的图片显示状态。
   *
   * 背景：改造前，一个 GridItem 的单次 build 会通过三个 helper 重复求值
   *      —— `fileImageSourceAvailable()`、`Image(fileImageSource())`、
   *      `fileImageSourceOrientation()` 各自走一遍 `fileImageSource()`，
   *      而它内部在 grid 路径下恒为 `previewUri()`（含 NAPI `fileUri.getUriFromPath`
   *      + 多层查表）。即"同一轮构建里把同一个事实查了 3 遍"。
   * 现在：只解析一次，后续全部读这个对象。
   */
  private resolveGridImageState(entry: FileEntry): GridImageState {
    return this.resolveGridImageStateInto(entry, new GridImageState())
  }

  /**
   * 同上，但把结果写进调用方给的实例（R2 子组件复用同一个 state，
   * 避免 build 内 3~4 次问询各分配一个对象）。
   * ⚠️ 被复用的实例必须显式复位每个字段，不能依赖默认值。
   *
   * R3.2：这里同时登记「这一格实际画的是哪个 preview」——
   * 这是唯一权威写入点：只被 GridThumbCell 的桥在 cell build 期间调用，
   * 不会被 onVisibleAreaChange 之类的旁路调用污染。
   * 记录的是 preview identity（previewUri），不是 Image() 参数的 typeof：
   * source 可能是 PixelMap（例如 viewer 转场期间），按类型判会错记成 ''，
   * 下一轮就会把"已经画对的格子"再批量 notify 一次。
   */
  private resolveGridImageStateInto(entry: FileEntry, state: GridImageState): GridImageState {
    state.hidden = this.viewerReturnHiddenPath === entry.path || this.audioReturnHiddenPath === entry.path
    const source: image.PixelMap | string = this.fileImageSource(entry, 'grid')
    const isUri = typeof source === 'string'
    state.source = source
    state.available = isUri ? (source as string).length > 0 : true
    if (!state.available) {
      // 画的是占位图 → 记 ''，这样它将来【静默】变 ready 时一定被补一次 notify。
      this.gridRenderedPreviewKey[entry.path] = ''
      state.orientation = ImageRotateOrientation.UP
      state.transitionId = ''
      state.syncLoad = false
      state.sourceWidth = 0
      state.sourceHeight = 0
      return state
    }
    state.orientation = isUri
      ? this.fileListImageBaseOrientation(entry) : ImageRotateOrientation.UP
    state.transitionId = this.fileImageTransitionId(entry, 'grid')
    state.syncLoad = this.fileImageShouldSyncLoad(entry)
    const size = this.gridSourceSizeFor(entry)
    state.sourceWidth = size === null ? 0 : size.width
    state.sourceHeight = size === null ? 0 : size.height
    this.gridRenderedPreviewKey[entry.path] = this.previewUri(entry)
    if (!state.hidden && this.viewerReturnRestoringPath === entry.path) {
      this.viewerReturnRestoringPath = ''
      console.info('[ViewerReturnOverlay] session=' + this.closeSessionId.toString() +
        ' stage=cell-restored dt=' +
        (this.getMonotonicNow() - this.viewerReturnOverlayStartedAt).toString() +
        ' path=' + entry.path + ' tid=' + state.transitionId)
    }
    // 🔬 时间点 2：这一格真正 build 时算出来的 transitionId（只读）
    this.openAnimProbe('cellBuild',
      'path=' + entry.path + ' rev=' + entry.previewRevision.toString() +
      ' tid=' + state.transitionId +
      ' hide=' + this.inViewerExitFlight(entry).toString() +
      ' showViewer=' + this.showImageViewer.toString() +
      ' entryActive=' + this.viewerEntryTransitionActive.toString() +
      ' geometryBound=' + this.viewerGeometryBound.toString())
    return state
  }

  /**
   * R2 推广（瀑布流）：同 resolveGridImageStateInto 的契约。
   * 唯一权威写入点 —— 只被 WaterfallThumbCell 的桥在 cell build 期间调用。
   * 原 item builder 里 `fileImageSourceAvailable()` 被调了两次、`fileImageSource()`
   * 又被 @Builder 里再调两次；这里一次算完，次数与原来相当或更少。
   */
  private resolveWaterfallImageStateInto(entry: FileEntry,
    state: WaterfallImageState): WaterfallImageState {
    const source = this.fileImageSource(entry, 'waterfall')
    const available = typeof source === 'string' ? source.length > 0 : true
    const aspectReady = this.waterfallAspectRatioReady(entry)
    state.available = available
    state.aspectReady = aspectReady
    if (!available) {
      state.source = ''
      state.orientation = ImageRotateOrientation.UP
      state.transitionId = ''
      state.syncLoad = false
      state.sourceWidth = 0
      state.sourceHeight = 0
      this.waterfallRenderedPreviewKey[entry.path] = ''
      return state
    }
    state.source = source
    state.orientation = typeof source === 'string'
      ? this.fileListImageBaseOrientation(entry) : ImageRotateOrientation.UP
    state.transitionId = this.fileImageTransitionId(entry, 'waterfall')
    state.syncLoad = this.fileImageShouldSyncLoad(entry)
    if (aspectReady) {
      const size = this.waterfallSourceSize(entry)
      state.sourceWidth = size.width
      state.sourceHeight = size.height
    } else {
      // 宽高比未就绪时不传 sourceSize（等 Image Kit 的真实几何）。
      state.sourceWidth = 0
      state.sourceHeight = 0
    }
    this.waterfallRenderedPreviewKey[entry.path] = this.previewUri(entry)
    return state
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
    this.waterfallVisiblePaths[entry.path] = retainedForViewer ? true : visible
    if (retainedForViewer) {
      // Do not enqueue a new decode while WaterFlow is hidden. Existing
      // downloads continue under the same generation; onAppear will only
      // decode a local source that still needs a render pass.
      return
    }
    if (!visible && !retainedForViewer) {
      const cachedBitmap = this.waterfallBitmaps[entry.path]
      if (cachedBitmap !== undefined) {
        // Keep recently decoded rasters available for a reverse scroll. The
        // bounded LRU, rather than every onDisAppear callback, decides when
        // the PixelMap is safe to release.
        this.touchWaterfallBitmap(entry.path)
        this.waterfallDecodedPaths[entry.path] = true
        this.trimWaterfallBitmapCache()
        return
      }
      this.releaseViewerBitmap(this.waterfallBitmaps, entry.path).catch((): void => {})
      this.waterfallOriginalUris[entry.path] = ''
      this.scheduleWaterfallSourceNotify()
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
    if (uri.length > 0) {
      this.waterfallOriginalUris[path] = uri
    } else {
      this.waterfallOriginalUris[path] = ''
    }
    this.scheduleWaterfallSourceNotify()
    this.updateImageVisualState(path, (state: ImageVisualState): void => {
      state.thumbnailDecodedUri = ''
      if (uri.length > 0) {
        state.transitionThumbnailUri = uri
      }
    }, false)
  }

  private setWaterfallAspectRatio(entry: FileEntry, width: number, height: number,
    rotationOverride?: number): void {
    if (entry.path.length === 0 || width <= 0 || height <= 0) {
      return
    }
    this.waterfallAspectRatios[entry.path] = width / height
    this.waterfallAspectSignatures[entry.path] = this.waterfallEntrySignature(entry,
      rotationOverride)
    this.scheduleWaterfallAspectNotify()
  }

  private scheduleWaterfallSourceNotify(): void {
    if (this.waterfallSourceNotifyTimer > 0) {
      return
    }
    this.waterfallSourceNotifyTimer = setTimeout((): void => {
      this.waterfallSourceNotifyTimer = 0
      this.waterfallSourceEpoch += 1
    }, 16)
  }

  private scheduleWaterfallAspectNotify(): void {
    if (this.waterfallAspectNotifyTimer > 0) {
      return
    }
    this.waterfallAspectNotifyTimer = setTimeout((): void => {
      this.waterfallAspectNotifyTimer = 0
      this.waterfallAspectEpoch += 1
    }, 16)
  }

  private enqueueWaterfallPreviewGeometry(entry: FileEntry, index: number = 0): void {
    if (this.fileViewMode !== 'waterfall' || !this.isImage(entry) ||
      !this.fileListRotationReady || this.waterfallAspectRatioReady(entry) ||
      this.timelineScrubActive || this.fileContentScrolling ||
      this.waterfallVisiblePaths[entry.path] !== true) {
      return
    }
    const generation = this.waterfallGeneration
    const queueKey = entry.path + '#waterfall-geometry:' + generation.toString()
    this.waterfallGeometryQueue.enqueue(queueKey, this.previewPriority(index, 'waterfall'),
      async (): Promise<void> => {
        await this.loadWaterfallPreviewGeometry(entry, generation)
      })
  }

  private async loadWaterfallPreviewGeometry(entry: FileEntry,
    generation: number): Promise<void> {
    await this.ensureCacheState()
    if (generation !== this.waterfallGeneration || this.fileViewMode !== 'waterfall' ||
      this.fileContentScrolling || this.timelineScrubActive ||
      this.waterfallVisiblePaths[entry.path] !== true || this.waterfallAspectRatioReady(entry)) {
      return
    }

    // Match the viewer's frame policy. An already cached original is
    // authoritative; otherwise the persistent thumbnail supplies the same
    // EXIF- and user-rotation-aware provisional geometry used on viewer entry.
    let localPath = CacheManager.findExisting(this.cacheDirectory, entry.name,
      this.originalCacheKey(entry))
    let canonicalPreview = false
    let usesPreview = false
    if (localPath.length === 0) {
      localPath = this.previewLocalPaths[entry.path]
      canonicalPreview = this.previewCanonicalPaths[entry.path] === true
      usesPreview = true
      if (typeof localPath !== 'string' || localPath.length === 0 ||
        this.previewLocalSignatures[entry.path] !== this.previewSignature(entry) ||
        !CacheManager.exists(localPath)) {
        localPath = this.repository.cachedThumbnailFast(entry, 'list')
        canonicalPreview = false
        if (localPath.length > 0 && CacheManager.exists(localPath)) {
          this.previewLocalPaths[entry.path] = localPath
          this.previewLocalSignatures[entry.path] = this.previewSignature(entry)
          this.previewCanonicalPaths[entry.path] = false
        }
      }
    }
    if (typeof localPath !== 'string' || localPath.length === 0 || !CacheManager.exists(localPath)) {
      return
    }

    const rotation = this.imageVisualState(entry.path).userRotation
    const geometry = await this.readViewerImageGeometry(localPath, entry.path)
    if (geometry === null || generation !== this.waterfallGeneration ||
      this.fileViewMode !== 'waterfall' || this.fileContentScrolling ||
      this.timelineScrubActive || this.waterfallVisiblePaths[entry.path] !== true ||
      this.imageVisualState(entry.path).userRotation !== rotation) {
      return
    }
    this.updateImageVisualState(entry.path, (state: ImageVisualState): void => {
      state.physicalWidth = geometry.physicalWidth
      state.physicalHeight = geometry.physicalHeight
      state.exifDisplayWidth = geometry.exifDisplayWidth
      state.exifDisplayHeight = geometry.exifDisplayHeight
      state.displayWidth = geometry.displayWidth
      state.displayHeight = geometry.displayHeight
      state.thumbnailDisplayWidth = geometry.displayWidth
      state.thumbnailDisplayHeight = geometry.displayHeight
      if (!state.frameLocked) {
        state.frameWidth = geometry.displayWidth
        state.frameHeight = geometry.displayHeight
      }
      if (usesPreview) {
        state.thumbnailOrientation = canonicalPreview
          ? ImageRotateOrientation.UP : ImageRotateOrientation.AUTO
      }
    })
    this.setWaterfallAspectRatio(entry, geometry.displayWidth, geometry.displayHeight)
  }

  private enqueueWaterfallOriginal(entry: FileEntry, _index: number = 0,
    priority: boolean = true): void {
    if (this.fileViewMode !== 'waterfall' || !this.isImage(entry) ||
      this.timelineScrubActive || this.fileContentScrolling) {
      return
    }
    const localPath = this.waterfallLocalPaths[entry.path]
    if (typeof localPath === 'string' && localPath.length > 0 &&
      this.waterfallLocalSignatures[entry.path] === this.waterfallEntrySignature(entry) &&
      CacheManager.exists(localPath)) {
      this.enqueueWaterfallDecode(entry)
      return
    }
    this.waterfallLocalPaths[entry.path] = ''
    this.waterfallLocalSignatures[entry.path] = ''
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
    if (this.fileViewMode !== 'waterfall' || this.waterfallEntries.length === 0 ||
      this.fileContentScrolling) {
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
      this.waterfallActiveDecodePaths[entry.path] === true || this.timelineScrubActive ||
      this.fileContentScrolling) {
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
        this.imageVisualState(entry.path).userRotation !== rotation || this.fileContentScrolling) {
        if (record !== null) {
          await this.viewerBitmapStore.release(record)
        }
        return
      }
      this.installViewerBitmap(this.waterfallBitmaps, entry.path, record)
      this.applyDecodedBitmapGeometry(entry.path, record, false)
      this.setWaterfallAspectRatio(entry, record.displayWidth, record.displayHeight)
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
    // A fallback list thumbnail also fires Image.onComplete while the
    // column-sized PixelMap is being decoded. It must not consume that decode
    // slot or mark the original raster complete before it is installed.
    if (this.waterfallBitmaps[entry.path] === undefined ||
      this.waterfallActiveDecodePaths[entry.path] !== true) {
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
      this.waterfallLocalSignatures[entry.path] = this.waterfallEntrySignature(entry)
      // Keep completed bytes for reuse, but do not publish geometry or start
      // a PixelMap decode while the WaterFlow is moving. The settled visible
      // window will pick this local path up in onScrollStop.
      if (this.fileContentScrolling) {
        return
      }
      const geometry = await this.readViewerImageGeometry(localPath, entry.path)
      if (geometry !== null && generation === this.waterfallGeneration) {
        this.setWaterfallAspectRatio(entry, geometry.displayWidth, geometry.displayHeight)
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

  private onSearchQueryChanged(value: string): void {
    this.searchDraft = value
    if (value.trim().length === 0) {
      this.searchGeneration += 1
      if (this.searchTimer > 0) {
        clearTimeout(this.searchTimer)
        this.searchTimer = 0
      }
      this.searchDraft = ''
      this.searchQuery = ''
      this.searchResults = []
      this.resetSearchResultScroll()
      this.searchLoading = false
    }
  }

  private scheduleSearch(value: string): void {
    this.onSearchQueryChanged(value)
  }

  private submitSearch(value: string): void {
    const normalized = value.trim()
    if (normalized.length === 0) {
      return
    }
    this.dismissKeyboard()
    this.saveCurrentSearchResultSnapshot()
    this.searchGeneration += 1
    if (this.searchTimer > 0) {
      clearTimeout(this.searchTimer)
      this.searchTimer = 0
    }
    this.searchDraft = value
    this.searchQuery = value
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
    if (batch.length === 0) {
      return
    }
    const seen = new Set<string>()
    for (const item of this.searchResults) {
      seen.add(item.path)
    }
    const newlyAdded: FileEntry[] = []
    for (const entry of batch) {
      if (!seen.has(entry.path)) {
        seen.add(entry.path)
        newlyAdded.push(entry)
      }
    }
    if (newlyAdded.length === 0) {
      return
    }
    this.searchResults = this.searchResults.concat(newlyAdded)
    this.cacheSearchResults(this.searchQuery, this.searchScope, this.searchResults, this.searchLoading, this.searchScrollOffset)
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

  private isSearchViewer(): boolean {
    return this.searchSession !== null && this.searchSession.returnMode === 'image'
  }

  private buildAncestorNavigationStack(targetParent: string): string[] {
    const normalized = targetParent.replace(/\/+$/, '')
    if (normalized.length === 0) {
      return []
    }

    if (this.rootKind === 'personal') {
      const personalBaseEntry = this.findDefaultPersonalDirectory()
      const personalBase = (personalBaseEntry !== null && personalBaseEntry.path.length > 0)
        ? personalBaseEntry.path
        : (this.username.trim().length > 0 ? '/home/' + this.username.trim() : '')
      const baseNormalized = personalBase.replace(/\/+$/, '')

      if (baseNormalized.length > 0 && normalized.startsWith(baseNormalized)) {
        if (normalized === baseNormalized) {
          // Exactly at user's home folder (/home/<user>), ancestor is the personal root ('')
          return ['']
        }
        // Subdirectory of user's home folder (e.g. /home/fhf/Photos/Camera)
        const stack: string[] = ['', baseNormalized]
        const subPath = normalized.substring(baseNormalized.length).replace(/^\/+/, '')
        const subParts = subPath.split('/').filter((p: string) => p.length > 0)
        // Add all intermediate folders except the last one (which is targetParent itself)
        let current = baseNormalized
        for (let i = 0; i < subParts.length - 1; i++) {
          current = current + '/' + subParts[i]
          stack.push(current)
        }
        return stack
      }
    }

    // Shared space or general path
    const stack: string[] = ['']
    const parts = normalized.split('/').filter((p: string) => p.length > 0)
    let current = ''
    for (let i = 0; i < parts.length - 1; i++) {
      current = current + '/' + parts[i]
      stack.push(current)
    }
    return stack
  }

  private scrollToLocatedEntry(targetEntry: FileEntry, attempt: number = 0): void {
    const isWaterfall = this.fileViewMode === 'waterfall'
    const items = isWaterfall ? this.waterfallEntries : this.entries
    const index = items.findIndex((item: FileEntry): boolean => item.path === targetEntry.path)
    if (index < 0) {
      return
    }
    const childIndex = this.fileViewMode === 'list' ? index + 1 : index
    const scroller = isWaterfall ? this.waterfallScroller : this.fileListScroller

    this.locateScrollStartTime = this.getMonotonicNow()
    this.locateTargetIndex = childIndex
    this.locateBuildLazyItemCount = 0
    this.locateMinBuildIndex = -1
    this.locateMaxBuildIndex = -1
    this.locateImagePipelineCount = 0
    this.pendingVisibleLoads.clear()

    this.tapTrace('target-scroll start', 'childIndex=' + childIndex.toString() + ' mode=' + this.fileViewMode)

    const t0 = this.getMonotonicNow()
    try {
      scroller.scrollToIndex(childIndex, false, ScrollAlign.CENTER)
    } catch (_) {}
    const tScrollCost = this.getMonotonicNow() - t0
    this.tapTrace('scrollToIndex-sync', 'cost=' + tScrollCost.toString() + 'ms')

    this.postRenderFrame((): void => {
      const dt = this.getMonotonicNow() - t0
      this.tapTrace('postRenderFrame-first', 'dt=' + dt.toString() + 'ms')
      this.scrollItemIntoContentBand(scroller, childIndex, attempt)
    })
  }

  private triggerLocateFromViewer(): void {
    if (this.isBusy || this.targetLocateEntryPath.length > 0) {
      return
    }
    const entry = this.committedViewerEntry() || this.viewerImageEntry
    if (entry === null) {
      return
    }
    const targetParent = this.parentPath(entry.path)
    if (targetParent.length === 0 && entry.path.lastIndexOf('/') <= 0) {
      this.showImmersiveToast('无法定位文件所在目录')
      return
    }

    this.tapTraceBegin('locate-tap: ' + entry.name)

    // 立即设置防重状态
    this.isBusy = true
    this.showImageMoreMenu = false

    // 点击后即时隐藏 Viewer 顶栏与底栏 Chrome（时长 0ms，避免 120ms 动画与后方 530ms 重任务碰撞）
    this.tapTrace('chrome-hide-start')
    this.setImageChromeVisible(false, false)

    // 保持提示逻辑不变
    this.showImmersiveToast('正在定位所在目录…')
    this.statusText = '正在定位所在目录…'

    // G3a: 延到下一渲染帧启动真正的定位重型逻辑，让当前帧完成 Touch Up 与按钮 stateEffect 释放
    this.postRenderFrame((): void => {
      this.tapTrace('locate-work-start')
      void this.locateViewerImageDirectory(entry)
    })
  }

  private async locateViewerImageDirectory(entry: FileEntry): Promise<void> {
    const targetParent = this.parentPath(entry.path)
    const targetRootType = targetParent.length > 0 ? 3 :
      (this.rootKind === 'personal' ? 4 : 3)

    try {
      this.targetLocateEntryPath = entry.path

      // 阶段一：静默拉取目标目录数据（Viewer 保持静止作为自然 Cover）
      const snapshot = await this.repository.ensureDirectoryIndex(targetParent, targetRootType)
      const query = new DirectoryQuery()
      query.path = targetParent
      query.rootType = targetRootType
      query.sortKey = this.fileSortKey
      query.ascending = this.fileSortAscending
      const targetEntries = DirectoryTimelinePolicy.query(snapshot.entries, query)

      // 阶段二：探测成功，在 Viewer 后面静默切换目录
      this.locateProgrammaticScrolling = true
      this.pendingVisibleLoads.clear()
      this.discardSearchSession()

      const ancestors = this.buildAncestorNavigationStack(targetParent)
      this.navigationStack = ancestors
      this.navigationEntryStack = []
      this.navigationRootTypeStack = []
      this.navigationViewStateStack = ancestors.map((): DirectoryViewState => {
        const state: DirectoryViewState = {
          mode: this.defaultFileViewMode,
          offset: null,
          anchor: null
        }
        return state
      })
      this.navigationPageIndexStack = []
      this.navigationPageHasMoreStack = []

      this.currentPath = targetParent
      this.currentRootType = targetRootType
      this.indexedDirectoryKey = targetRootType.toString() + ':' + targetParent
      this.indexedDirectoryContentSignature = snapshot.contentSignature.length > 0
        ? snapshot.contentSignature : DirectoryTimelinePolicy.contentSignature(snapshot.entries)
      this.directoryTimeline = snapshot.timeline
      this.timelineIndexing = false
      this.resetTimelineInteraction()
      this.setCurrentPageState(Math.max(1, Math.ceil(targetEntries.length / 200)), false)
      this.replaceEntries(targetEntries, false, true)
      this.applyPreferredViewMode()
      this.updateTopTitle(this.fileTitle(targetParent))
      this.updateBottomBarVisibility(true)
      this.updateDirectoryCount(targetParent, snapshot.totalCount >= 0
        ? snapshot.totalCount : targetEntries.length)
      this.resetPreviewState(false)

      // 阶段三：启动程序化定位滚动，并等待目标项进入视口 (target-visible)
      let locateTimer = 0
      const visiblePromise = new Promise<void>((resolve: () => void): void => {
        let finished = false
        const done = (): void => {
          if (!finished) {
            finished = true
            if (locateTimer > 0) {
              clearTimeout(locateTimer)
              locateTimer = 0
            }
            resolve()
          }
        }
        this.targetLocateResolve = done
        locateTimer = setTimeout((): void => {
          this.notifyTargetLocateVisible('timeout')
          done()
        }, 4000)
      })

      this.scrollToLocatedEntry(entry)

      // 等待目标 Cell 真正挂载并进入可视区（或超时兜底）
      await visiblePromise

      // 阶段四：目标项已就位，Viewer 进行纯粹的 120~160ms 干净淡出
      this.statusText = ''
      this.closeImageViewer(true)
      this.showImmersiveToast(`已定位到: ${entry.name}`)
    } catch (error) {
      // 失败保持现场
      this.targetLocateEntryPath = ''
      this.locateProgrammaticScrolling = false
      if (this.targetLocateResolve !== null) {
        this.targetLocateResolve()
        this.targetLocateResolve = null
      }
      this.isBusy = false
      this.statusText = ''
      this.setImageChromeVisible(true, true)
      this.showImmersiveToast('定位所在目录失败')
      console.error(`[locateViewerImageDirectory] failed: ${String(error)}`)
    }
  }

  public async runLocateGradientExperiment(customIndices: number[] = [100, 1000, 2500, 4800]): Promise<void> {
    console.info('[TapTrace] >>> STARTING LOCATE GRADIENT EXPERIMENT <<<')
    this.showImmersiveToast('开始执行定位梯度实验…')

    const targetParent = this.currentPath.length > 0 ? this.currentPath : '/home/fhf/Photos'
    const targetRootType = this.currentRootType > 0 ? this.currentRootType : 3
    const snapshot = await this.repository.ensureDirectoryIndex(targetParent, targetRootType)
    const query = new DirectoryQuery()
    query.path = targetParent
    query.rootType = targetRootType
    query.sortKey = this.fileSortKey
    query.ascending = this.fileSortAscending
    const targetEntries = DirectoryTimelinePolicy.query(snapshot.entries, query)

    console.info(`[TapTrace] Gradient experiment directory: ${targetParent}, total entries: ${targetEntries.length}`)
    if (targetEntries.length === 0) {
      this.showImmersiveToast('梯度实验失败：目录无数据')
      return
    }

    if (this.entries.length !== targetEntries.length) {
      this.replaceEntries(targetEntries, false, true)
      await new Promise<void>((r: () => void) => setTimeout(r, 600))
    }

    for (const targetIdx of customIndices) {
      const idx = Math.min(targetIdx, targetEntries.length - 1)
      const targetEntry = targetEntries[idx]
      console.info(`[TapTrace] ========================================`)
      console.info(`[TapTrace] >>> GRADIENT TEST POINT: index=${idx} name=${targetEntry.name}`)
      console.info(`[TapTrace] ========================================`)
      this.tapTraceBegin(`gradient-test-${idx}: ${targetEntry.name}`)

      // Reset scroll to top first so each test starts from a clean offset
      try {
        this.fileListScroller.scrollToIndex(0, false, ScrollAlign.START)
      } catch (_) {}
      await new Promise<void>((r: () => void) => setTimeout(r, 600))

      this.targetLocateEntryPath = targetEntry.path
      this.locateProgrammaticScrolling = true

      let testTimer = 0
      const testPromise = new Promise<void>((resolve: () => void) => {
        let done = false
        const finish = (): void => {
          if (!done) {
            done = true
            if (testTimer > 0) {
              clearTimeout(testTimer)
              testTimer = 0
            }
            resolve()
          }
        }
        this.targetLocateResolve = finish
        testTimer = setTimeout((): void => {
          this.notifyTargetLocateVisible('timeout')
          finish()
        }, 5000)
      })

      this.scrollToLocatedEntry(targetEntry)
      await testPromise

      console.info(`[TapTrace] <<< GRADIENT TEST POINT FINISHED: index=${idx}`)
      await new Promise<void>((r: () => void) => setTimeout(r, 800))
    }

    console.info('[TapTrace] >>> FINISHED LOCATE GRADIENT EXPERIMENT <<<')
    this.showImmersiveToast('定位梯度实验全部完成！')
  }

  // ────────────────────────────────────────────────────────────────────────
  // 🔬 临时探针（Q3 清理时删除）：图片冷启动 metadata Range 可行性 + 成本
  //
  // 目的：验证「原图完全未缓存时，能否在 Viewer 动画开始前，以足够低的成本拿到
  //      authoritative physical size + EXIF orientation」，为首次打开的
  //      "frame 直接用 Original display ratio" 方案提供耗时依据（P50/P95）。
  //
  // 🚫 纪律（用户明确要求）：
  //    · 本探针【不写任何 Viewer state】，不碰 viewerFrame / 不碰 openImageViewer 时序；
  //    · 不下载完整原图、不解码 PixelMap；
  //    · 递增式 Range：64KB → 128KB → 256KB → 512KB，成功即停。
  // ────────────────────────────────────────────────────────────────────────

  // ── 🔬 OpenAnimProbe 辅助（Q3 清理时删除）──────────────────────────────
  private openAnimProbeAt: number = 0

  /** 只在"刚触发过 entry transition"的时间窗内输出，避免热路径刷屏。 */
  private openAnimProbeActive(): boolean {
    if (!OPEN_ANIM_PROBE || this.openAnimProbeAt <= 0) {
      return false
    }
    return (this.getMonotonicNow() - this.openAnimProbeAt) < 800
  }

  private openAnimProbe(tag: string, detail: string): void {
    if (!this.openAnimProbeActive()) {
      return
    }
    console.info('[OpenAnimProbe] ' + tag + ' ' + detail)
  }

  /** 单次 Range 尝试：发请求 + 只解析文件头（不解码）。 */  private async probeRangeOne(entry: FileEntry, url: string,
    headers: Record<string, string>, rangeBytes: number,
    transport: HttpTransport): Promise<ImageMetadataProbeResult> {
    const result = new ImageMetadataProbeResult()
    result.rangeBytes = rangeBytes
    result.stage = Math.round(rangeBytes / 1024).toString() + 'KB'
    let bytes: Uint8Array = new Uint8Array(0)
    const netStart = this.getMonotonicNow()
    try {
      const range = await transport.requestBinaryRange(url, 0, rangeBytes, headers)
      result.netMs = this.getMonotonicNow() - netStart
      result.httpStatus = range.responseCode
      result.receivedBytes = range.bytes.length
      bytes = range.bytes
    } catch (error) {
      result.netMs = this.getMonotonicNow() - netStart
      result.note = 'range-failed:' + String(error).substring(0, 70)
      return result
    }
    let source: image.ImageSource | null = null
    const parseStart = this.getMonotonicNow()
    try {
      // ⚠️ 必须按 byteOffset/byteLength 精确切片，否则会把底层多余字节带进解析器。
      const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
      source = image.createImageSource(buffer)
      const info = source.getImageInfoSync()
      result.width = Math.floor(info.size.width)
      result.height = Math.floor(info.size.height)
      try {
        result.orientation = await source.getImageProperty(image.PropertyKey.ORIENTATION)
      } catch (_) {
        // 部分编码器不暴露 EXIF；这不是失败，但要如实记录，避免误判为"可解析"。
        result.orientation = 'unavailable'
      }
      result.ok = result.width > 0 && result.height > 0
    } catch (error) {
      result.note = 'parse-failed:' + String(error).substring(0, 70)
    } finally {
      result.parseMs = this.getMonotonicNow() - parseStart
      if (source !== null) {
        try {
          await source.release()
        } catch (_) {
        }
      }
    }
    return result
  }

  /** 对单张图做递增式 Range 探测（成功即停）。 */
  private async probeImageMetadataRange(entry: FileEntry): Promise<void> {
    const transport = new HttpTransport()
    let url = ''
    let headers: Record<string, string> = {}
    try {
      // 优先验证现有 mediaPlayer URL（视频路径已在用它，且注释称支持 byte range）。
      const descriptor = await this.repository.mediaPlayerDescriptor(entry)
      url = descriptor.url
      headers = descriptor.headers
    } catch (error) {
      console.info('[MetaRangeProbe] descriptor-failed path=' + entry.path +
        ' err=' + String(error).substring(0, 70))
      return
    }
    const steps: number[] = [65536, 131072, 262144, 524288]
    for (const step of steps) {
      const r = await this.probeRangeOne(entry, url, headers, step, transport)
      console.info('[MetaRangeProbe] path=' + entry.path + ' step=' + r.stage +
        ' status=' + r.httpStatus.toString() +
        ' bytes=' + r.receivedBytes.toString() +
        ' netMs=' + r.netMs.toFixed(1) +
        ' parseMs=' + r.parseMs.toFixed(1) +
        ' size=' + r.width.toString() + 'x' + r.height.toString() +
        ' orientation=' + r.orientation +
        ' ok=' + r.ok.toString() +
        (r.note.length > 0 ? ' note=' + r.note : ''))
      if (r.ok) {
        return
      }
    }
  }

  /** 入口：从当前目录里按格式取样（jpg / heic / png 各一张）+ 当前打开的那张。 */
  public async runImageMetadataRangeProbe(): Promise<void> {
    const samples: FileEntry[] = []
    const seenExt: Record<string, boolean> = {}
    const current = this.committedViewerEntry() || this.viewerImageEntry
    if (current !== null) {
      samples.push(current)
      seenExt[this.probeExtension(current.name)] = true
    }
    for (const entry of this.entries) {
      if (entry.isDirectory || !this.isImage(entry)) {
        continue
      }
      const ext = this.probeExtension(entry.name)
      if ((ext === 'jpg' || ext === 'jpeg' || ext === 'heic' || ext === 'heif' ||
        ext === 'png') && seenExt[ext] !== true) {
        seenExt[ext] = true
        samples.push(entry)
      }
      if (samples.length >= 6) {
        break
      }
    }
    console.info('[MetaRangeProbe] ==== START samples=' + samples.length.toString() +
      ' exts=' + samples.map((item: FileEntry): string => this.probeExtension(item.name)).join(',') +
      ' ====')
    for (const entry of samples) {
      await this.probeImageMetadataRange(entry)
    }
    console.info('[MetaRangeProbe] ==== END ====')
    this.showImmersiveToast('metadata Range 探针完成，请看日志')
  }

  private probeExtension(name: string): string {
    const dot = name.lastIndexOf('.')
    return dot > 0 ? name.substring(dot + 1).toLowerCase() : ''
  }

  private async openSearchResult(entry: FileEntry): Promise<void> {
    if (this.isBusy) {
      return
    }
    this.dismissKeyboard()
    if (entry.isDirectory) {
      await this.openSearchResultFolder(entry)
      return
    }
    if (this.isImage(entry)) {
      await this.openSearchResultImage(entry)
      return
    }
    if (this.isAudio(entry)) {
      await this.openSearchResultAudio(entry)
      return
    }
    if (this.isVideo(entry)) {
      await this.openSearchResultVideo(entry)
      return
    }
    await this.downloadEntry(entry)
  }

  private async openSearchResultImage(entry: FileEntry): Promise<void> {
    if (this.searchSession === null) {
      this.searchSession = this.createSearchSession()
    }
    this.captureSearchSession()
    this.searchSession.returnMode = 'image'
    try {
      const offset = this.searchResultScroller.currentOffset()
      if (offset !== undefined && typeof offset.yOffset === 'number') {
        this.searchScrollOffset = Math.max(0, offset.yOffset)
      }
    } catch (_) {}
    this.searchSession.scrollOffset = this.searchScrollOffset

    const searchImages = this.searchResults.filter((item: FileEntry) => !item.isDirectory && this.isImage(item))
    await this.openImageViewer(entry, searchImages)
  }

  private async openSearchResultFolder(entry: FileEntry): Promise<void> {
    if (this.searchSession === null) {
      this.searchSession = this.createSearchSession()
    }
    this.captureSearchSession()
    try {
      const offset = this.searchResultScroller.currentOffset()
      if (offset !== undefined && typeof offset.yOffset === 'number') {
        this.searchScrollOffset = Math.max(0, offset.yOffset)
      }
    } catch (_) {}
    this.searchSession.scrollOffset = this.searchScrollOffset
    this.searchSession.returnMode = 'directory'
    this.searchSession.targetParentPath = entry.path
    this.searchSession.targetNavigationDepth = this.navigationStack.length

    const requestId = ++this.navigationRequestId
    this.isNavigating = true
    this.isBusy = true
    this.statusText = '正在打开文件夹…'
    try {
      const nextPath = entry.path
      const nextRootType = nextPath.length > 0 ? 3 :
        (entry.rootType > 0 ? entry.rootType : this.currentRootType)
      const nextSnapshot = await this.repository.ensureDirectoryIndex(nextPath, nextRootType)
      const query = new DirectoryQuery()
      query.path = nextPath
      query.rootType = nextRootType
      query.sortKey = this.fileSortKey
      query.ascending = this.fileSortAscending
      const nextEntries = DirectoryTimelinePolicy.query(nextSnapshot.entries, query)

      if (requestId !== this.navigationRequestId || !this.showSearch || this.searchSession === null) { return }
      // The outgoing surface is Search, not the origin directory. Reveal the ready target
      // in one commit instead of briefly painting a reconstructed file-page snapshot.
      this.captureSearchSession()
      this.dismissKeyboard()
      this.cancelFileTransition()
      this.currentPath = nextPath
      this.currentRootType = nextRootType
      this.setCurrentPageState(1, false)
      this.replaceEntries(nextEntries, false, true)
      this.applyPreferredViewMode()
      this.updateDirectoryCount(nextPath, nextEntries.length)
      this.resetPreviewState()
      this.updateTopTitle(this.fileTitle(nextPath))
      this.showSearch = false
      this.updateBottomBarVisibility(true)
      this.statusText = ''
    } catch (error) {
      if (requestId !== this.navigationRequestId || !this.showSearch) { return }
      this.reportError(error as Object, '打开文件夹失败')
      this.statusText = '打开失败'
    } finally {
      if (requestId === this.navigationRequestId) {
        this.isNavigating = false
        this.isBusy = false
      }
    }
  }

  private async openSearchResultAudio(entry: FileEntry): Promise<void> {
    if (this.searchSession === null) {
      this.searchSession = this.createSearchSession()
    }
    this.captureSearchSession()
    this.searchSession.returnMode = 'audio'
    await this.openAudioPlayer(entry)
  }

  private async openSearchResultVideo(entry: FileEntry): Promise<void> {
    if (this.searchSession === null) {
      this.searchSession = this.createSearchSession()
    }
    this.captureSearchSession()
    this.searchSession.returnMode = 'video'
    await this.openVideoPlayer(entry)
  }

  private async toggleAutoLogin(): Promise<void> {
    if (this.isBusy) {
      return
    }
    this.autoLogin = !this.autoLogin
    // 开启自动登录即自动保存：静默登录与会话内自动重连都依赖本地保存的凭据。
    this.rememberPassword = this.autoLogin
    await this.persistLoginPreferences()
  }

  // 「记住地址」只在解析成功后可点：记住的是设备地址，不是凭据。
  // 记住成功后胶囊变色；再点一次视为取消记住。
  private async toggleRememberAddress(): Promise<void> {
    if (this.isBusy) {
      return
    }
    if (this.baseUrl.length === 0) {
      this.showImmersiveToast('请先解析设备，再记住地址')
      return
    }
    if (this.rememberAddress) {
      this.rememberAddress = false
      await this.persistLoginPreferences()
      this.showImmersiveToast('已取消记住设备地址')
      return
    }
    try {
      if (this.loginPreferences === null) {
        await this.ensureLoginState()
      }
      if (this.loginPreferences === null) {
        return
      }
      await this.loginPreferences.put('cloud_link_id', this.linkId)
      await this.loginPreferences.put('remember_address', true)
      await this.loginPreferences.flush()
      this.rememberAddress = true
      this.showImmersiveToast('已记住设备地址')
    } catch (_) {
      this.showImmersiveToast('地址没有保存成功，请再试一次')
    }
  }

  private openSettings(): void {
    if (this.isBusy) {
      return
    }
    this.clearSearchIfPresent()
    this.showViewSettings = false
    this.showStorageSettings = false
    this.showNetworkSettings = false
    this.showPlaybackSettings = false
    this.leaveRecycleBinIfOpen()
    this.errorText = ''
    // statusText 是全局的操作状态文案：文件页浏览时会写入“个人目录”“正在读取目录…”
    // 等消息，而设置页的二级页面底部也渲染它。进入设置页时先清空，避免这些
    // 文件页文案串到设置页里。
    this.statusText = ''
    this.selectedBottomTab = 'settings'
    this.screen = 'settings'
    this.updateTopTitle('设置')
    this.updateBottomBarVisibility(true)
  }

  private openStorageSettings(): void {
    if (this.isBusy || this.screen !== 'settings') {
      return
    }
    this.showViewSettings = false
    this.showStorageSettings = true
    this.showNetworkSettings = false
    this.showPlaybackSettings = false
    this.ensureCacheState()
    this.errorText = ''
    this.updateTopTitle('缓存与存储')
    this.updateBottomBarVisibility(true)
  }

  private openViewSettings(): void {
    if (this.isBusy || this.screen !== 'settings') {
      return
    }
    this.showStorageSettings = false
    this.showPlaybackSettings = false
    this.showNetworkSettings = false
    this.showRecycleBinSettings = false
    this.showViewSettings = true
    this.ensureViewState()
    this.errorText = ''
    this.updateTopTitle('默认视图')
    this.updateBottomBarVisibility(true)
  }

  private closeViewSettings(): void {
    if (this.screen !== 'settings' || !this.showViewSettings) {
      return
    }
    this.showViewSettings = false
    this.errorText = ''
    this.updateTopTitle('设置')
    this.updateBottomBarVisibility(true)
  }

  private openPlaybackSettings(): void {
    if (this.isBusy || this.screen !== 'settings') {
      return
    }
    this.showStorageSettings = false
    this.showPlaybackSettings = true
    this.showNetworkSettings = false
    this.showViewSettings = false
    this.ensurePlaybackState()
    this.errorText = ''
    this.updateTopTitle('播放与控制')
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
    this.updateTopTitle('设置')
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
    this.updateTopTitle('设置')
    this.updateBottomBarVisibility(true)
  }

  private openNetworkSettings(): void {
    if (this.isBusy || this.screen !== 'settings') {
      return
    }
    this.showViewSettings = false
    this.showStorageSettings = false
    this.showNetworkSettings = true
    this.showPlaybackSettings = false
    this.ensureNetworkState()
    this.errorText = ''
    this.updateTopTitle('网络与流量')
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
    this.updateTopTitle('设置')
    this.updateBottomBarVisibility(true)
  }

  // ── Recycle bin ──────────────────────────────────────────────────────────

  private openRecycleBinSettings(): void {
    if (this.isBusy || this.screen !== 'settings') {
      return
    }
    this.showViewSettings = false
    this.showStorageSettings = false
    this.showPlaybackSettings = false
    this.showNetworkSettings = false
    this.showRecycleBinSettings = true
    this.errorText = ''
    this.statusText = ''
    this.recycleScope = 'personal'
    this.recycleEntries = []
    this.recycleStack = []
    this.recycleBlockedShares = []
    this.updateTopTitle('回收站')
    this.updateBottomBarVisibility(true)
    this.reloadRecycleEntries()
  }

  private closeRecycleBinSettings(): void {
    if (this.screen !== 'settings' || !this.showRecycleBinSettings) {
      return
    }
    // Bump the token so a walk still in flight cannot write into a page the
    // user has already left.
    this.recycleRequestToken += 1
    this.showRecycleBinSettings = false
    this.showStorageSettings = false
    this.showPlaybackSettings = false
    this.showNetworkSettings = false
    this.recycleEntries = []
    this.recycleLoading = false
    this.recycleStack = []
    this.recycleBlockedShares = []
    this.errorText = ''
    this.statusText = ''
    this.updateTopTitle('设置')
    this.updateBottomBarVisibility(true)
  }

  /**
   * Drops the recycle page state without the title/bar work that
   * closeRecycleBinSettings() does, for when another tab takes over the
   * screen. Bumping the token keeps an in-flight walk from resurrecting the
   * list behind the new page.
   */
  private leaveRecycleBinIfOpen(): void {
    if (!this.showRecycleBinSettings) {
      return
    }
    this.recycleRequestToken += 1
    this.showRecycleBinSettings = false
    this.recycleEntries = []
    this.recycleLoading = false
    this.recycleStack = []
    this.recycleBlockedShares = []
  }

  private selectRecycleScope(scope: string): void {
    if (this.recycleScope === scope && !this.recycleLoading) {
      return
    }
    this.recycleScope = scope
    // Switching scope always lands on the top level: a stack left over from the
    // other scope holds paths belonging to shares this scope does not have.
    this.recycleStack = []
    this.updateRecycleTitle()
    this.reloadRecycleEntries()
  }

  /**
   * The first-level folders whose recycle bin the current scope covers.
   *
   * "Personal" is the signed-in account's own folder — the same `/home/<user>`
   * the Home tab opens, deliberately not the whole `/home` collection that
   * also lists other accounts. "Shared" is every shared folder; each has its
   * own repository and its own permission story.
   */
  private recycleSharesForScope(): string[] {
    if (this.recycleScope === 'shared') {
      const shares: string[] = []
      for (const entry of this.sharedRoots) {
        if (entry.isDirectory && entry.path.length > 0) {
          shares.push(entry.path)
        }
      }
      return shares
    }
    const account = this.username.trim().replace(/^\/+|\/+$/g, '')
    return account.length > 0 ? ['/home/' + account] : []
  }

  /**
   * Loads one level of the recycle bin for the active scope.
   *
   * Each folder's bin is read independently: a shared folder whose bin is
   * administrator-only would otherwise abort the whole page, and a refusal
   * there is an expected outcome rather than a failure. Refusals are collected
   * so the page can explain why the list is shorter than expected.
   */
  private async reloadRecycleEntries(): Promise<void> {
    if (!this.showRecycleBinSettings) {
      return
    }
    this.recycleRequestToken += 1
    const token = this.recycleRequestToken
    const shares = this.recycleSharesForScope()
    this.recycleLoading = true
    this.recycleEntries = []
    this.recycleBlockedShares = []
    this.errorText = ''
    this.statusText = ''
    if (shares.length === 0) {
      this.recycleLoading = false
      this.statusText = this.recycleScope === 'shared'
        ? '当前账号没有可访问的共享文件夹'
        : '无法确定个人目录，请重新登录后重试'
      return
    }
    const current = this.recycleCurrentPath()
    const collected: FileEntry[] = []
    const blocked: string[] = []
    if (current.length === 0) {
      // Top level: merge the `#recycle` direct children of every share in scope.
      for (const share of shares) {
        try {
          const items = await this.repository.listRecycleChildren(
            share, UgreenRemoteRepository.recycleRepositoryPath(share))
          for (const item of items) {
            collected.push(item)
          }
        } catch (_) {
          blocked.push(share)
        }
      }
    } else {
      // Below the top level a path can only belong to one share.
      const share = this.recycleShareOfPath(current)
      try {
        const items = await this.repository.listRecycleChildren(share, current)
        for (const item of items) {
          collected.push(item)
        }
      } catch (_) {
        blocked.push(share)
      }
    }
    if (token !== this.recycleRequestToken || !this.showRecycleBinSettings) {
      return
    }
    // Folders first, then newest deletion first inside each group. Folders lead
    // because they are the only rows that can be entered, and mixing them into
    // a date order made the drill-down hard to spot.
    collected.sort((left: FileEntry, right: FileEntry): number => {
      if (left.isDirectory !== right.isDirectory) {
        return left.isDirectory ? -1 : 1
      }
      return right.deletedTime - left.deletedTime
    })
    this.recycleEntries = collected
    this.recycleBlockedShares = blocked
    this.recycleLoading = false
  }

  /** The recycle directory currently being shown; empty means the top level. */
  private recycleCurrentPath(): string {
    return this.recycleStack.length > 0 ? this.recycleStack[this.recycleStack.length - 1] : ''
  }

  /** Which share a recycle path belongs to, for reading the right repository. */
  private recycleShareOfPath(directoryPath: string): string {
    for (const share of this.recycleSharesForScope()) {
      const repository = UgreenRemoteRepository.recycleRepositoryPath(share)
      if (repository.length > 0 &&
        (directoryPath === repository || directoryPath.startsWith(repository + '/'))) {
        return share
      }
    }
    return ''
  }

  private enterRecycleDirectory(entry: FileEntry): void {
    if (!entry.isDirectory || this.recycleLoading) {
      return
    }
    this.recycleStack = this.recycleStack.concat([entry.path])
    this.recycleEntries = []
    this.updateRecycleTitle()
    this.reloadRecycleEntries()
  }

  /**
   * Pops one level. Returns false when already at the top, letting the caller
   * decide to close the page instead.
   */
  private leaveRecycleLayer(): boolean {
    // A level must be left even while a read is in flight — waiting it out
    // makes Back feel dead. Invalidate the pending read first so its result
    // cannot land on the level we are about to show.
    this.recycleRequestToken += 1
    this.recycleLoading = false
    if (this.recycleStack.length === 0) {
      return false
    }
    this.recycleStack = this.recycleStack.slice(0, -1)
    this.recycleEntries = []
    this.updateRecycleTitle()
    this.reloadRecycleEntries()
    return true
  }

  /** Single entry point for both the header button and the system back key. */
  private recycleBackAction(): void {
    if (this.leaveRecycleLayer()) {
      return
    }
    this.closeRecycleBinSettings()
  }

  private onRecycleEntryClick(entry: FileEntry): void {
    // Mirrors handleFileEntryClick: while the long-press menu owns the screen,
    // the tap that dismisses it must not also act on the row underneath.
    if (this.contextMenuVisible || this.contextMenuEntry !== null) {
      return
    }
    if (entry.isDirectory) {
      this.enterRecycleDirectory(entry)
    }
    // Files have no tap action — they carry no chevron and every operation on
    // them lives in the long-press menu, matching the file manager.
  }

  /**
   * The row subtitle. A folder reports when its contents were deleted; a file
   * also reports its size, which is what makes a 90GB item obvious before it is
   * restored or purged.
   */
  private recycleEntryInfo(entry: FileEntry): string {
    const time = this.formatRecycleDeletedAt(entry.deletedTime)
    if (entry.isDirectory) {
      return time
    }
    const size = entry.size > 0 ? this.formatStorageSize(entry.size) : ''
    return size.length > 0 ? size + ' · ' + time : time
  }

  /**
   * Commits the recycle title together with its current navigation depth.
   */
  private updateRecycleTitle(): void {
    const current = this.recycleCurrentPath()
    if (current.length === 0) {
      this.updateTopTitle('回收站')
      return
    }
    const repository = UgreenRemoteRepository.recycleRepositoryPath(this.recycleShareOfPath(current))
    const prefix = repository.length > 0 ? repository + '/' : ''
    let relative = current.startsWith(prefix) ? current.slice(prefix.length) : current
    relative = relative.replace(/^\/+|\/+$/g, '')
    this.updateTopTitle(relative.length > 0
      ? '回收站 · ' + relative.split('/').join(' / ') : '回收站')
  }

  /** The folder a recycled item was deleted from, for the row's subtitle. */
  private recycleOriginDirectory(entry: FileEntry): string {
    const original = UgreenRemoteRepository.originalPathOfRecycledItem(entry.path, entry.recycleSharePath)
    const trimmed = original.replace(/\/+$/, '')
    const separator = trimmed.lastIndexOf('/')
    if (separator > 0) {
      return trimmed.slice(0, separator)
    }
    return entry.recycleSharePath.length > 0 ? entry.recycleSharePath : '未知位置'
  }

  /**
   * `dtime` is unix seconds. The date alone is not enough here — "deleted ten
   * minutes ago" and "deleted last Tuesday" are very different situations to
   * be looking at, so the time of day is included.
   */
  private formatRecycleDeletedAt(seconds: number): string {
    if (seconds <= 0) {
      return '删除时间未知'
    }
    const date = new Date(seconds * 1000)
    const hours = date.getHours().toString().padStart(2, '0')
    const minutes = date.getMinutes().toString().padStart(2, '0')
    return this.formatTime(seconds) + ' ' + hours + ':' + minutes
  }

  private async restoreRecycleEntry(entry: FileEntry): Promise<void> {
    if (this.isBusy) {
      return
    }
    this.isBusy = true
    this.errorText = ''
    const origin = this.recycleOriginDirectory(entry)
    this.statusText = '正在还原…'
    try {
      await this.repository.restoreFromRecycle(entry, entry.recycleSharePath)
      this.removeRecycleEntry(entry.path)
      this.statusText = '已还原到 ' + origin
      HapticFeedback.success()
      this.showImmersiveToast('已还原：' + entry.name)
    } catch (error) {
      this.reportError(error as Object, '还原失败')
      this.statusText = '还原失败'
    } finally {
      this.isBusy = false
    }
  }

  private async purgeRecycleEntry(entry: FileEntry): Promise<void> {
    if (this.isBusy) {
      return
    }
    HapticFeedback.warn()
    const response = await this.showTrackedDialog({
      title: '永久删除？',
      message: '「' + entry.name + '」会被永久删除，之后无法恢复。',
      buttons: [
        { text: '取消', color: this.isDarkTheme ? '#FFFFFFFF' : '#536174' },
        { text: '永久删除', color: '#D34D5C' }
      ],
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false)
    })
    if (response.index !== 1) {
      return
    }
    await this.purgeRecyclePaths([entry.path], '已永久删除 ' + entry.name)
  }

  /**
   * Permanently deletes everything currently listed — i.e. this one level.
   *
   * Scoping it to the visible level is what makes the confirmation honest: the
   * count in the dialog is exactly the count on screen. Deleting a folder row
   * here takes the deleted content nested beneath it along with it, which is
   * the same thing emptying that folder would do.
   */
  private async purgeCurrentRecycleLayer(): Promise<void> {
    const entries = this.recycleEntries
    if (entries.length === 0 || this.isBusy || this.recycleLoading) {
      return
    }
    HapticFeedback.warn()
    const response = await this.showTrackedDialog({
      title: '清空当前目录？',
      message: this.recycleEntries.length.toString() + ' 项会被永久删除，之后无法恢复。',
      buttons: [
        { text: '取消', color: this.isDarkTheme ? '#FFFFFFFF' : '#536174' },
        { text: '全部删除', color: '#D34D5C' }
      ],
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false)
    })
    if (response.index !== 1) {
      return
    }
    const paths: string[] = []
    for (const entry of entries) {
      paths.push(entry.path)
    }
    await this.purgeRecyclePaths(paths, '已清空当前目录')
  }

  private async purgeRecyclePaths(paths: string[], successMessage: string): Promise<void> {
    if (paths.length === 0 || this.isBusy) {
      return
    }
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在删除…'
    try {
      await this.repository.purgeRecycle(paths)
      this.statusText = successMessage
      HapticFeedback.success()
      this.showImmersiveToast(successMessage)
      // Purging removes items from the repository itself, so the flattened
      // list has to be rebuilt rather than filtered — parent folders that only
      // existed to hold the deleted content disappear with them.
      await this.reloadRecycleEntries()
    } catch (error) {
      this.reportError(error as Object, '删除失败')
      this.statusText = '删除失败'
    } finally {
      this.isBusy = false
    }
  }

  private removeRecycleEntry(path: string): void {
    const remaining: FileEntry[] = []
    for (const entry of this.recycleEntries) {
      if (entry.path !== path) {
        remaining.push(entry)
      }
    }
    this.recycleEntries = remaining
  }

  private enterFileScreen(kind: RootKind): void {
    this.clearSearchIfPresent()
    this.closeActionMenu()
    this.showStorageSettings = false
    this.showPlaybackSettings = false
    this.showNetworkSettings = false
    this.showViewSettings = false
    this.leaveRecycleBinIfOpen()
    this.rootKind = kind
    this.selectedBottomTab = kind === 'personal' ? 'home' : 'shared'
    this.screen = 'files'
  }

  private openHome(): void {
    if (this.isBusy && !this.isNavigating && !this.showPageTransition) { return }
    this.navigationRequestId += 1
    this.isNavigating = false
    this.cancelFileTransition()
    this.isBusy = false
    this.closeActionMenu()
    this.openDefaultPersonalDirectory()
  }

  private openShared(): void {
    if (this.isBusy) {
      return
    }
    this.clearSearchIfPresent()
    this.closeActionMenu()
    this.showViewSettings = false
    this.showStorageSettings = false
    this.showPlaybackSettings = false
    this.showNetworkSettings = false
    this.leaveRecycleBinIfOpen()
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
    this.showViewSettings = false
    this.showStorageSettings = false
    this.showPlaybackSettings = false
    this.showNetworkSettings = false
    this.leaveRecycleBinIfOpen()
    this.selectionMode = false
    this.setSelectedPaths([])
    this.selectedBottomTab = 'downloads'
    this.screen = 'downloads'
    this.importExpanded = false
    this.updateTopTitle('传输')
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

  // 密码保险箱的系统保存是在"页面跳转"时触发的，而本应用的登录是同一页内的状态切换
  // （screen: 'login' -> 'files'），跳转事件从不发生，保险箱里也就一直没有这条凭据，
  // 登录页自然填不出东西。这里显式请求一次保存。
  //
  // 必须在登录字段还在树上时调用：系统是在请求那一刻去读当前页面的可填充节点的，
  // 所以调用点放在 this.screen = 'files' 之前。
  //
  // 用的是两参数版本（SDK 只导出了这个）；文档里带 SaveRequest/viewData 的三参数版本
  // 是 API 26 新增的，当前 SDK 声明文件里还没有。
  private requestVaultSave(): void {
    if (this.username.length === 0 || this.password.length === 0) {
      return
    }
    try {
      autoFillManager.requestAutoSave(this.getUIContext())
    } catch (_) {
      // 写不进密码保险箱不能影响登录本身。
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
      this.offlineCacheMode = false
      await this.saveOfflineProfile()
      await this.refreshVideoManager()
      await this.ensureDownloadState()
      await this.downloadQueue.setReady(true)
      await this.uploadQueue.setReady(true)
      await this.albumUpload.setReady(true)
      if (!silent) {
        // 只有用户亲手登录才请求保存（自动登录每次进来都弹保存提示会很烦），
        // 且必须赶在切换页面之前，系统要读登录字段。
        this.requestVaultSave()
      }
      this.screen = 'files'
      this.updateBottomBarVisibility(false)
      this.statusText = silent ? '' : '登录成功'
    } catch (error) {
      const connectionFailure = error instanceof UgreenError &&
        (error.kind === UgreenErrorKind.NAS_UNAVAILABLE ||
        (error.kind === UgreenErrorKind.NETWORK && (error.status === 0 || error.status >= 500)))
      if (silent && connectionFailure && await this.openOfflineCache()) {
        this.statusText = ''
        return
      }
      if (silent) {
        this.screen = 'login'
      }
      this.reportError(error as Object, silent ? '自动登录失败' : '登录失败')
      this.statusText = ''
    } finally {
      this.isBusy = false
      if (this.offlineCacheMode) { this.retryNasConnection().catch(() => {}) }
      this.onTransferNavigationRequested()
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
      this.offlineCacheMode = false
      await this.saveOfflineProfile()
      await this.refreshVideoManager()
      await this.ensureDownloadState()
      await this.downloadQueue.setReady(true)
      await this.uploadQueue.setReady(true)
      await this.albumUpload.setReady(true)
      this.requestVaultSave()
      this.screen = 'files'
      this.updateBottomBarVisibility(false)
      this.statusText = result.message
    } catch (error) {
      this.reportError(error as Object, '验证码验证失败')
      this.statusText = '验证码验证失败'
    } finally {
      this.isBusy = false
      this.onTransferNavigationRequested()
    }
  }

  private setCurrentPageState(pageIndex: number, hasMore: boolean): void {
    this.currentPageIndex = Math.max(1, pageIndex)
    this.currentPageHasMore = hasMore
    this.loadingNextPage = false
    this.scheduleOfflineProfileSave()
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

  private scheduleCurrentDirectoryIndex(forceNetwork: boolean = false): void {
    if (forceNetwork && (this.offlineCacheMode || !NasConnection.shared().canRequest())) { return }
    if (this.screen !== 'files' || this.showSearch || this.currentPath.length === 0) {
      this.directoryIndexRequestToken += 1
      this.indexedDirectoryKey = ''
      this.timelineIndexing = false
      this.directoryTimeline = new DirectoryTimeline()
      this.timelineFocusTime = 0
      this.pendingDirectoryIndexSnapshot = null
      this.indexedDirectoryContentSignature = ''
      this.resetTimelineInteraction()
      return
    }
    const path = this.currentPath
    const rootType = this.currentRootType
    const key = rootType.toString() + ':' + path
    if (!forceNetwork && this.indexedDirectoryKey === key) {
      return
    }
    if (this.indexedDirectoryKey.length > 0 && this.indexedDirectoryKey !== key) {
      this.directoryTimeline = new DirectoryTimeline()
      this.timelineFocusTime = 0
      this.pendingDirectoryIndexSnapshot = null
      this.indexedDirectoryContentSignature = ''
      this.resetTimelineInteraction()
    }
    const token = this.directoryIndexRequestToken + 1
    this.directoryIndexRequestToken = token
    this.timelineIndexing = true
    this.repository.ensureDirectoryIndex(path, rootType, forceNetwork)
      .then((snapshot: DirectoryIndexedSnapshot): void => {
        this.applyDirectoryIndexSnapshot(snapshot, key, token)
      })
      .catch((error: Error): void => {
        if (token === this.directoryIndexRequestToken) {
          this.timelineIndexing = false
          console.warn('[UgreenTimeline] directory index failed: ' + JSON.stringify(error))
        }
      })
  }

  private applyDirectoryIndexSnapshot(snapshot: DirectoryIndexedSnapshot,
    key: string, token: number): void {
    const currentKey = this.currentRootType.toString() + ':' + this.currentPath
    if (token !== this.directoryIndexRequestToken || key !== currentKey ||
      this.screen !== 'files' || this.showSearch) {
      return
    }
    // The metadata request may finish while the directory page is still
    // moving. Keep fetching in parallel, then swap the full snapshot only
    // after the transition releases its visual snapshot.
    if (this.showPageTransition || this.isNavigating || this.fileContentScrolling) {
      this.pendingDirectoryIndexSnapshot = snapshot
      return
    }
    const effectiveEntries = this.filterDeletedEntries(snapshot.entries, [])
    const suppressedCount = snapshot.entries.length - effectiveEntries.length
    const effectiveTimeline = suppressedCount > 0
      ? DirectoryTimelinePolicy.build(effectiveEntries, snapshot.timeline.complete)
      : snapshot.timeline
    const contentSignature = suppressedCount > 0
      ? DirectoryTimelinePolicy.contentSignature(effectiveEntries)
      : (snapshot.contentSignature.length > 0
        ? snapshot.contentSignature : DirectoryTimelinePolicy.contentSignature(snapshot.entries))
    const contentUnchanged = contentSignature === this.indexedDirectoryContentSignature &&
      this.entries.length === effectiveEntries.length
    this.pendingDirectoryIndexSnapshot = null
    // A background freshness check must not replace the mounted lazy data
    // source after a fling ends. ArkUI delivers the deferred result from
    // onScrollStop; reloading thousands of keyed rows there invalidates the
    // current scroll anchor and can expose the parent page for a frame. The
    // repository has already persisted this newer snapshot, so keep the
    // current directory session consistent and consume it on the next entry
    // (or an explicit refresh) instead.
    const mountedCompleteIndex = this.indexedDirectoryKey === key &&
      this.indexedDirectoryContentSignature.length > 0
    if (mountedCompleteIndex && !contentUnchanged) {
      this.timelineIndexing = false
      return
    }
    this.indexedDirectoryKey = key
    this.indexedDirectoryContentSignature = contentSignature
    this.directoryTimeline = effectiveTimeline
    this.timelineIndexing = false
    if (!effectiveTimeline.complete) {
      this.timelineFocusTime = 0
      this.resetTimelineInteraction()
      return
    }
    if (contentUnchanged) {
      // A stale refresh is common while a large directory is being viewed.
      // The complete metadata signature proves that the mounted order and
      // timeline inputs are unchanged, so do not sort or replace the lazy
      // container again just to update an access timestamp.
      this.setCurrentPageState(Math.max(1, Math.ceil(effectiveEntries.length / 200)), false)
      this.updateDirectoryCount(this.currentPath,
        snapshot.totalCount >= 0
          ? Math.max(0, snapshot.totalCount - suppressedCount) : effectiveEntries.length)
      if (effectiveTimeline.eligible()) {
        const earliest = DirectoryTimelinePolicy.localDayStart(effectiveTimeline.earliestTime)
        const latest = DirectoryTimelinePolicy.localDayStart(effectiveTimeline.latestTime)
        if (this.timelineFocusTime < earliest || this.timelineFocusTime > latest) {
          this.timelineFocusTime = this.fileSortAscending ? earliest : latest
        }
      } else {
        this.timelineFocusTime = 0
      }
      if (Date.now() - snapshot.fetchedAt > DIRECTORY_INDEX_STALE_MS &&
        effectiveEntries.length <= DIRECTORY_AUTO_REFRESH_MAX_ITEMS) {
        setTimeout((): void => {
          if (key === this.currentRootType.toString() + ':' + this.currentPath) {
            this.scheduleCurrentDirectoryIndex(true)
          }
        }, 0)
      }
      return
    }
    const query = new DirectoryQuery()
    query.path = this.currentPath
    query.rootType = this.currentRootType
    query.sortKey = this.fileSortKey
    query.ascending = this.fileSortAscending
    const sorted = DirectoryTimelinePolicy.query(effectiveEntries, query)
    this.setCurrentPageState(Math.max(1, Math.ceil(sorted.length / 200)), false)
    this.replaceEntries(sorted, false, true)
    this.updateDirectoryCount(this.currentPath,
      snapshot.totalCount >= 0
        ? Math.max(0, snapshot.totalCount - suppressedCount) : sorted.length)
    if (effectiveTimeline.eligible()) {
      const earliest = DirectoryTimelinePolicy.localDayStart(effectiveTimeline.earliestTime)
      const latest = DirectoryTimelinePolicy.localDayStart(effectiveTimeline.latestTime)
      if (this.timelineFocusTime < earliest || this.timelineFocusTime > latest) {
        this.timelineFocusTime = this.fileSortAscending ? earliest : latest
      }
    } else {
      this.timelineFocusTime = 0
    }
    if (Date.now() - snapshot.fetchedAt > DIRECTORY_INDEX_STALE_MS &&
      effectiveEntries.length <= DIRECTORY_AUTO_REFRESH_MAX_ITEMS) {
      setTimeout((): void => {
        if (key === this.currentRootType.toString() + ':' + this.currentPath) {
          this.scheduleCurrentDirectoryIndex(true)
        }
      }, 0)
    }
  }

  private updateTimelineFocusFromVisible(firstIndex: number, mode: FileViewMode): void {
    if (!this.shouldShowTimeline() || this.timelineScrubActive || this.timelineFocusPinned) {
      return
    }
    const source = mode === 'waterfall' ? this.waterfallEntries : this.entries
    let index = mode === 'list' ? Math.max(0, firstIndex - 1) : Math.max(0, firstIndex)
    while (index < source.length) {
      const entry = source[index]
      if (!entry.isDirectory && this.isImage(entry) && entry.modifiedTime > 0) {
        const dayStart = DirectoryTimelinePolicy.localDayStart(entry.modifiedTime)
        if (dayStart !== this.timelineFocusTime || this.timelineVisibleFocusPendingTime > 0) {
          this.scheduleTimelineVisibleFocus(dayStart)
        }
        return
      }
      index += 1
    }
  }

  private scheduleTimelineVisibleFocus(dayStart: number): void {
    this.timelineVisibleFocusPendingTime = dayStart
    if (this.timelineVisibleFocusTimer > 0) {
      return
    }
    this.timelineVisibleFocusTimer = setTimeout((): void => {
      this.timelineVisibleFocusTimer = 0
      const pendingTime = this.timelineVisibleFocusPendingTime
      this.timelineVisibleFocusPendingTime = 0
      if (pendingTime > 0 && !this.timelineScrubActive && !this.timelineFocusPinned &&
        pendingTime !== this.timelineFocusTime) {
        this.timelineFocusTime = pendingTime
      }
    }, 48)
  }

  private flushTimelineVisibleFocus(): void {
    if (this.timelineVisibleFocusTimer > 0) {
      clearTimeout(this.timelineVisibleFocusTimer)
      this.timelineVisibleFocusTimer = 0
    }
    const pendingTime = this.timelineVisibleFocusPendingTime
    this.timelineVisibleFocusPendingTime = 0
    if (pendingTime > 0 && !this.timelineScrubActive && !this.timelineFocusPinned &&
      pendingTime !== this.timelineFocusTime) {
      this.timelineFocusTime = pendingTime
    }
  }

  private cancelTimelineVisibleFocus(): void {
    if (this.timelineVisibleFocusTimer > 0) {
      clearTimeout(this.timelineVisibleFocusTimer)
      this.timelineVisibleFocusTimer = 0
    }
    this.timelineVisibleFocusPendingTime = 0
  }

  private resetTimelineInteraction(): void {
    this.timelineInteractionToken += 1
    this.timelineScrubActive = false
    this.timelineFocusPinned = false
    this.timelineIgnoreScrollStartUntil = 0
    this.timelineScrubPendingTime = 0
    this.timelineScrubLastScrollAt = 0
    if (this.timelineScrubTimer > 0) {
      clearTimeout(this.timelineScrubTimer)
      this.timelineScrubTimer = 0
    }
    this.cancelTimelineVisibleFocus()
    this.timelineEntryIndexByDay = {}
    this.timelineWaterfallIndexByDay = {}
    this.timelineLastJumpDay = 0
    this.timelineLastJumpIndex = -1
    this.timelineLastJumpPath = ''
    this.timelineLastJumpMode = 'list'
  }

  private cancelPendingPreviewLoads(): void {
    const cancelled = this.previewQueue.cancelPending()
    for (const key of cancelled) {
      const separator = key.indexOf('#preview:')
      const path = separator > 0 ? key.substring(0, separator) : key
      if (path.length > 0) {
        this.previewRequests[path] = 0
      }
    }
  }

  /** 该 path 当前是否有在飞的缩略图请求（token > 0 即为有）。 */
  private isPreviewRequestActive(path: string): boolean {
    const token = this.previewRequests[path]
    return typeof token === 'number' && token > 0
  }

  private onFileContentScrollStart(): void {
    if (this.dragSelectionPanActive && this.fileContentScrolling) {
      this.noteUserInteraction()
      return
    }
    if (this.closeSessionActive && !this.sessionScrollStartLogged) {
      this.sessionScrollStartLogged = true
      const dt = this.getMonotonicNow() - this.closeAnimFinishMonotonic
      console.info('[TouchChain] #' + this.closeSessionId.toString() +
        ' ScrollStart +' + dt.toString() + 'ms')
      this.closeSessionActive = false
    }
    // 诊断：滑动是否被识别。若复现"丢触控"时这里没有日志，
    // 说明滑动在 UI 层就被拦掉了。
    if (TAP_TRACE) {
      console.info('[TapTrace] scroll-start')
    }
    this.fileContentScrolling = true
    ContinuationManager.shared().refresh()
    this.noteUserInteraction()
    let currentOffsetY = 0
    try {
      currentOffsetY = this.fileListScroller.currentOffset().yOffset
    } catch (_) {}
    this.returnPerfSession.noteScrollStart(currentOffsetY, this.getMonotonicNow())
    this.cancelPendingPreviewLoads()
    this.waterfallGeometryQueue.cancelPending()
    for (const entry of this.waterfallDownloadQueue) {
      this.waterfallDownloadRequests[entry.path] = false
    }
    this.waterfallDownloadQueue = []
    this.waterfallDecodeQueue = []
    this.releaseTimelineFocusPinFromFileScroll()
  }

  private onFileContentScrollStop(): void {
    if (this.dragSelectionPanActive) {
      // scrollBy can emit Stop for each small step. Flush once after the drag,
      // keeping preview work and PixelMap cleanup away from the active finger.
      this.dragSelectionDeferredScrollStop = true
      return
    }
    this.closeSessionActive = false
    this.fileContentScrolling = false
    ContinuationManager.shared().refresh()
    this.lastUserInteractionMonotonic = this.getMonotonicNow()
    this.requestViewerCleanup()
    let currentOffsetY = 0
    try {
      currentOffsetY = this.fileListScroller.currentOffset().yOffset
    } catch (_) {}
    this.returnPerfSession.noteScrollStop(currentOffsetY, this.getMonotonicNow())
    hilog.info(IMAGE_VIEWER_HILOG_DOMAIN, IMAGE_VIEWER_HILOG_TAG, this.imageTelemetry.dumpStats())
    // 滚动期间被推迟的视觉状态刷新（缩略图旋转修正等）在这里统一补一次
    if (this.imageVisualNotifyDeferred) {
      this.imageVisualNotifyDeferred = false
      this.scheduleImageVisualNotify()
    }
    this.flushTimelineVisibleFocus()
    const pending = this.pendingDirectoryIndexSnapshot
    this.pendingDirectoryIndexSnapshot = null
    if (pending !== null) {
      const key = this.currentRootType.toString() + ':' + this.currentPath
      this.applyDirectoryIndexSnapshot(pending, key, this.directoryIndexRequestToken)
    }
    // 滚动期间只记账的可见项，在这里补加载（与 onScrollIndex 的索引无关）
    this.flushPendingVisibleLoads()
    this.warmTimelineVisibleEntries()
    this.scheduleImageVisualPrune()
  }

  private releaseTimelineFocusPinFromFileScroll(): void {
    // scrollToIndex() can synchronously emit onScrollStart. Keep that event
    // from looking like a user gesture; the next real list gesture releases
    // the selected timeline date and lets the rail follow visible content.
    if (this.timelineScrubActive || Date.now() < this.timelineIgnoreScrollStartUntil) {
      return
    }
    this.timelineFocusPinned = false
  }

  private rebuildTimelineIndexes(): void {
    const isLocating = this.targetLocateEntryPath.length > 0
    if (isLocating) {
      this.tapTrace('rebuildTimelineIndexes start')
    }
    const entryIndexes: Record<string, number> = {}
    for (let index = 0; index < this.entries.length; index++) {
      const entry = this.entries[index]
      if (entry.isDirectory || !this.isImage(entry) || entry.modifiedTime <= 0) {
        continue
      }
      const key = DirectoryTimelinePolicy.localDayStart(entry.modifiedTime).toString()
      if (entryIndexes[key] === undefined) {
        entryIndexes[key] = index
      }
    }
    const waterfallIndexes: Record<string, number> = {}
    for (let index = 0; index < this.waterfallEntries.length; index++) {
      const entry = this.waterfallEntries[index]
      if (entry.modifiedTime <= 0) {
        continue
      }
      const key = DirectoryTimelinePolicy.localDayStart(entry.modifiedTime).toString()
      if (waterfallIndexes[key] === undefined) {
        waterfallIndexes[key] = index
      }
    }
    this.timelineEntryIndexByDay = entryIndexes
    this.timelineWaterfallIndexByDay = waterfallIndexes
    if (isLocating) {
      this.tapTrace('rebuildTimelineIndexes end')
    }
  }

  private scrollTimelineToDay(dayStart: number, updateFocus: boolean): void {
    const key = dayStart.toString()
    let targetIndex = -1
    let childOffset = this.fileViewMode === 'list' ? 1 : 0
    let scroller = this.fileListScroller
    if (this.fileViewMode === 'waterfall') {
      const waterfallIndex = this.timelineWaterfallIndexByDay[key]
      targetIndex = waterfallIndex === undefined ? -1 : waterfallIndex
      childOffset = 0
      scroller = this.waterfallScroller
    } else {
      const entryIndex = this.timelineEntryIndexByDay[key]
      targetIndex = entryIndex === undefined ? -1 : entryIndex
    }
    if (targetIndex < 0) {
      return
    }
    if (updateFocus) {
      this.timelineFocusTime = dayStart
    }
    // onTouch may publish several samples for the same physical position.
    // During one interaction the list only needs one jump per resolved day.
    if (this.timelineScrubActive && this.timelineLastJumpDay === dayStart &&
      this.timelineLastJumpIndex === targetIndex && this.timelineLastJumpPath === this.currentPath &&
      this.timelineLastJumpMode === this.fileViewMode) {
      return
    }
    // Direct indexed jumps avoid a long inertial animation when the selected
    // month or year is far away and make the file surface track scrubbing.
    scroller.scrollToIndex(targetIndex + childOffset, false, ScrollAlign.CENTER)
    this.timelineLastJumpDay = dayStart
    this.timelineLastJumpIndex = targetIndex
    this.timelineLastJumpPath = this.currentPath
    this.timelineLastJumpMode = this.fileViewMode
  }

  private beginTimelineScrub(): void {
    this.cancelTimelineVisibleFocus()
    this.timelineInteractionToken += 1
    this.timelineScrubActive = true
    this.timelineFocusPinned = true
    this.timelineIgnoreScrollStartUntil = Date.now() + 180
    this.timelineScrubPendingTime = this.timelineFocusTime
    this.timelineScrubLastScrollAt = 0
    this.timelineLastJumpDay = 0
    this.timelineLastJumpIndex = -1
    this.timelineLastJumpPath = ''
    this.timelineLastJumpMode = this.fileViewMode
    if (this.timelineScrubTimer > 0) {
      clearTimeout(this.timelineScrubTimer)
      this.timelineScrubTimer = 0
    }
  }

  private runTimelineScrubPreview(): void {
    this.timelineScrubTimer = 0
    if (!this.timelineScrubActive || this.timelineScrubPendingTime <= 0) {
      return
    }
    const dayStart = DirectoryTimelinePolicy.closestDay(
      this.directoryTimeline, this.timelineScrubPendingTime)
    this.timelineScrubLastScrollAt = Date.now()
    if (dayStart > 0) {
      this.scrollTimelineToDay(dayStart, false)
    }
  }

  private previewTimelineTime(time: number): void {
    if (!this.timelineScrubActive || !this.shouldShowTimeline()) {
      return
    }
    this.timelineScrubPendingTime = time
    const elapsed = Date.now() - this.timelineScrubLastScrollAt
    if (this.timelineScrubLastScrollAt === 0 || elapsed >= 32) {
      this.runTimelineScrubPreview()
      return
    }
    if (this.timelineScrubTimer === 0) {
      this.timelineScrubTimer = setTimeout((): void => {
        this.runTimelineScrubPreview()
      }, Math.max(1, 32 - elapsed))
    }
  }

  private releaseTimelineInteraction(): void {
    const token = this.timelineInteractionToken
    setTimeout((): void => {
      if (token === this.timelineInteractionToken) {
        this.timelineScrubActive = false
        this.warmTimelineVisibleEntries()
      }
    }, 48)
  }

  private warmTimelineVisibleEntries(): void {
    let source = this.entries
    let start = this.fileVisibleStartIndex
    let end = this.fileVisibleEndIndex
    if (this.fileViewMode === 'waterfall') {
      source = this.waterfallEntries
      start = this.waterfallVisibleStartIndex
      end = this.waterfallVisibleEndIndex
    } else if (this.fileViewMode === 'list') {
      // List index zero is the fixed top spacer.
      start = Math.max(0, start - 1)
      end = Math.max(start, end - 1)
    }
    if (source.length === 0) {
      return
    }
    // 上下缓冲要多留几行：onScrollIndex 上报的 last 只算「完整可见」的条目，
    // 屏幕上只露出一部分的最后一行不在其中（首行同理）。缓冲不足时就会出现
    // 某个固定相对位置的格子一直补不到缩略图、停在占位图 —— 往下滚动把它移到
    // 中间才会加载。多留 2 行（8 条）足够覆盖「只露出一部分」的那一行。
    // ⚠️ 队列上限已从 32 提到 256，所以这里扩大范围不会再被 enqueue 拒绝
    // （之前 ±8 失败正是因为一次 warm 36~48 条 > 上限 32）。
    const visibleStart = Math.max(0, start)
    const visibleEnd = Math.min(source.length - 1, Math.max(visibleStart, end))
    start = Math.max(0, visibleStart - 8)
    end = Math.min(source.length - 1, Math.max(start, visibleEnd + 8))
    // A malformed/stale visible range must not turn a scrub release into
    // another whole-directory warmup.
    end = Math.min(end, start + 47)
    const indexes: number[] = []
    // Real visible requests start before adjacent preloads can occupy all four
    // slots. Preserve the same warm window, concurrency and amount of work.
    for (let index = visibleStart; index <= Math.min(visibleEnd, end); index++) { indexes.push(index) }
    for (let index = start; index < visibleStart && index <= end; index++) { indexes.push(index) }
    for (let index = visibleEnd + 1; index <= end; index++) { indexes.push(index) }
    for (const index of indexes) {
      const entry = source[index]
      this.resolveFileListImageRotation(entry)
      if (this.fileViewMode === 'waterfall') {
        this.loadEntryPreview(entry, this.previewPriority(index, 'waterfall'))
        this.enqueueWaterfallPreviewGeometry(entry, index)
        this.enqueueWaterfallOriginal(entry, index, true)
      } else {
        this.loadEntryPreview(entry, this.previewPriority(index, this.fileViewMode))
      }
    }
  }

  /**
   * 记录「进入可见区的条目」以便加载缩略图，与 onScrollIndex 的索引无关。
   *
   * 为什么需要：GridItem.onAppear 只在挂载时触发一次；若那一刻正好在滚动，
   * loadEntryPreview 会直接返回，而该条目此后再也不会触发 onAppear —— 表现就是
   * 某个固定相对位置的格子一直停在占位图（尤其屏幕上只露出一部分的最后一行，
   * onScrollIndex 上报的 last 并不包含它）。
   *
   * ⚠️ 这里只做记账，绝不在滚动中入队：预览队列有并发与待处理上限
   * （LIST_MAX_CONCURRENT / MAX_PENDING_TASKS），滚动中批量入队会把队列挤满，
   * 反而让别的条目加载不出来（这个坑已踩过两次）。
   */
  private noteVisibleEntryForLoad(entry: FileEntry, ratio: number): void {
    if (ratio <= 0) {
      this.pendingVisibleLoads.delete(entry.path)
      return
    }
    // Keep the actual visible set, including partial edge rows and entries
    // that became ready silently while the viewer temporarily froze commits.
    this.pendingVisibleLoads.set(entry.path, entry)
    if (this.previewUri(entry).length > 0) {
      if (!this.fileContentScrolling && !this.locateProgrammaticScrolling) {
        this.refreshVisiblePreviewIfNeeded(entry)
      }
      return
    }
    if (this.fileContentScrolling || this.locateProgrammaticScrolling) {
      this.pendingVisibleLoads.set(entry.path, entry)
      return
    }
    // 不在滚动中，可以直接发起，无需记账。
    this.resolveFileListImageRotation(entry)
    this.loadEntryPreview(entry, 0)
  }

  private refreshVisiblePreviewIfNeeded(entry: FileEntry): boolean {
    if (this.fileViewMode === 'list' || this.showImageViewer || this.viewerEntryTransitionActive ||
      this.viewerClosePending || this.showPageTransition) { return false }
    const uri = this.previewUri(entry)
    const rendered = this.fileViewMode === 'waterfall'
      ? this.waterfallRenderedPreviewKey[entry.path] : this.gridRenderedPreviewKey[entry.path]
    if (uri.length === 0 || rendered === uri) { return false }
    this.notifyEntryChanged(entry.path, this.fileViewMode)
    return true
  }

  /** 滚动停止后，把滚动期间记下的可见项补加载一次（集合很小，只有屏上那几十条）。 */
  private flushPendingVisibleLoads(): number {
    const pending: FileEntry[] = Array.from(this.pendingVisibleLoads.values())

    const isWaterfall = this.fileViewMode === 'waterfall'
    let visibleStart = isWaterfall ? this.waterfallVisibleStartIndex : this.fileVisibleStartIndex
    let visibleEnd = isWaterfall ? this.waterfallVisibleEndIndex : this.fileVisibleEndIndex
    if (this.fileViewMode === 'list') {
      visibleStart = Math.max(0, visibleStart - 1)
      visibleEnd = Math.max(visibleStart, visibleEnd - 1)
    }
    const items = isWaterfall ? this.waterfallEntries : this.entries

    if (this.locateTargetIndex >= 0 && (visibleEnd <= 0 || visibleEnd < this.locateTargetIndex - 20)) {
      visibleStart = Math.max(0, this.locateTargetIndex - 10)
      visibleEnd = Math.min(items.length - 1, this.locateTargetIndex + 10)
    }

    const minIdx = Math.max(0, visibleStart - 8)
    const maxIdx = Math.min(items.length - 1, visibleEnd + 8)
    let flushedCount = 0
    let scanNotifiedCount = 0
    const processedPaths = new Set<string>()
    for (const entry of pending) {
      // onVisibleAreaChange is more accurate than onScrollIndex for clipped
      // edge rows. Reject old-directory descriptors, not valid visible edges.
      if (this.fileEntryDataSource.indexOfPath(entry.path) < 0) {
        this.pendingVisibleLoads.delete(entry.path)
        continue
      }
      processedPaths.add(entry.path)
      if (this.previewUri(entry).length > 0) {
        if (this.refreshVisiblePreviewIfNeeded(entry)) { scanNotifiedCount++ }
        continue
      }
      flushedCount++
      this.resolveFileListImageRotation(entry)
      this.loadEntryPreview(entry, 0)
    }

    // ── 兜底扫描当前可视区（visibleStart ~ visibleEnd）：
    // 1) 未缓存且未 loading：发起 loadEntryPreview 启动加载
    // 2) 缩略图已 ready：触发 notifyEntryChanged 单 Cell 刷新
    //
    // ⚠️ R3.2（取代 R3.1 的"已通知过 URI"判据）：
    //   R2 每轮把整段可视区 ~38 条全 notify（38 次 cell 重建挤进 OnScrollStop 一帧，
    //   合计 582.4ms / 平均 41.6ms / 最大 69.8ms）；
    //   R3 一刀不 notify → previewUri() 惰性 ready 的格子永远不知道（成片占位）；
    //   R3.1 用"是否通知过这个 URI"去重 → 新画面首次停滑仍 40 条（那些格子挂载时就已
    //     ready、本来就画对了，只是从没走过 setPreviewUri，被误判成漏刷）。
    //   正确语义 = 比较【期望画的】和【实际画了的】：
    //     desired = previewUri(entry)（现在应该画什么）
    //     rendered = gridRenderedPreviewKey[path]（这一格上次 build 实际画了什么）
    //   只有两者不一致才补一次 notify；一致就是 0 操作。
    let scanLoadedCount = 0
    const endScan = visibleEnd > 0 ? visibleEnd : Math.min(items.length - 1, 24)
    for (let i = visibleStart; i <= endScan; i++) {
      const entry = items[i]
      if (!entry || processedPaths.has(entry.path) || entry.isDirectory || !this.isImage(entry)) {
        continue
      }
      const uri = this.previewUri(entry)
      if (uri.length > 0) {
        // R2W：两个视图各有一张 rendered 表，按当前视图取对应的一张。
        const renderedKey = isWaterfall
          ? this.waterfallRenderedPreviewKey[entry.path]
          : this.gridRenderedPreviewKey[entry.path]
        if (renderedKey !== uri) {
          scanNotifiedCount++
          this.notifyEntryChanged(entry.path, isWaterfall ? 'waterfall' : 'grid')
        }
      } else {
        scanLoadedCount++
        this.resolveFileListImageRotation(entry)
        this.loadEntryPreview(entry, 0)
      }
    }

    const hadLocate = this.locateTargetIndex >= 0
    this.locateTargetIndex = -1
    if (hadLocate) {
      this.tapTrace('flushPendingVisibleLoads', 'flushed=' + flushedCount.toString() +
        ' scanLoaded=' + scanLoadedCount.toString() +
        ' scanNotified=' + scanNotifiedCount.toString() +
        ' suppressed=' + (pending.length - flushedCount).toString() +
        ' totalPending=' + pending.length.toString() +
        ' visibleRange=[' + minIdx.toString() + '..' + maxIdx.toString() + ']')
    }
    hilog.info(IMAGE_VIEWER_HILOG_DOMAIN, 'ThumbProbe',
      `[flushPendingVisibleLoads] flushed=${flushedCount}, scanLoaded=${scanLoadedCount}, scanNotified=${scanNotifiedCount}, range=[${visibleStart}..${endScan}]`)
    // 🔬 R3.1 验收观测：previewRequests 无永久残留（活跃数应回落到 0~少量）、重复请求去重计数。
    let activeReqCount = 0
    const reqKeys = Object.keys(this.previewRequests)
    for (const reqKey of reqKeys) {
      const reqToken = this.previewRequests[reqKey]
      if (typeof reqToken === 'number' && reqToken > 0) {
        activeReqCount += 1
      }
    }
    hilog.info(IMAGE_VIEWER_HILOG_DOMAIN, 'ThumbProbe',
      `[R31Metrics] activeRequests=${activeReqCount}, requestTokens=${reqKeys.length}, duplicateBlocked=${this.previewDuplicateBlockedCount}`)
    return flushedCount
  }

  private finishTimelineScrub(time: number): void {
    if (this.timelineScrubTimer > 0) {
      clearTimeout(this.timelineScrubTimer)
      this.timelineScrubTimer = 0
    }
    this.timelineScrubPendingTime = 0
    this.timelineFocusPinned = true
    this.timelineIgnoreScrollStartUntil = Date.now() + 180
    const dayStart = DirectoryTimelinePolicy.closestDay(this.directoryTimeline, time)
    if (dayStart > 0) {
      this.scrollTimelineToDay(dayStart, true)
    }
    this.releaseTimelineInteraction()
  }

  private selectTimelinePeriod(time: number, period: TimelinePeriod): void {
    if (this.timelineScrubTimer > 0) {
      clearTimeout(this.timelineScrubTimer)
      this.timelineScrubTimer = 0
    }
    this.timelineScrubPendingTime = 0
    this.timelineFocusPinned = true
    this.timelineIgnoreScrollStartUntil = Date.now() + 180
    const dayStart = DirectoryTimelinePolicy.dayInPeriod(
      this.directoryTimeline, time, period, this.fileSortAscending)
    if (dayStart > 0) {
      this.scrollTimelineToDay(dayStart, true)
    }
    this.releaseTimelineInteraction()
  }

  private schedulePhotosPreindex(homePath: string): void {
    if (homePath.length === 0 || this.photosPreindexHomePath === homePath) {
      return
    }
    this.photosPreindexHomePath = homePath
    // Reuse/await the home index already requested by replaceEntries(), then
    // warm likely folders below <home>/Photos serially.
    this.repository.ensureDirectoryIndex(homePath, 3)
      .then((): Promise<void> => this.repository.preindexPhotosDirectories(homePath))
      .catch((error: Error): void => {
        console.warn('[UgreenTimeline] Photos pre-index failed: ' + JSON.stringify(error))
      })
  }

  private async loadRoot(): Promise<void> {
    this.navigationRequestId += 1
    this.isNavigating = false
    this.photosPreindexHomePath = ''
    const root = await this.repository.getRoot()
    const accountName = this.username.trim()
    const defaultDirectory = root.personal.find((entry: FileEntry): boolean =>
      entry.isDirectory && entry.name.trim().toLowerCase() === accountName.toLowerCase())
    const personalPath = defaultDirectory !== undefined
      ? (defaultDirectory.path.length > 0 ? defaultDirectory.path : '/' + defaultDirectory.name)
      : (accountName.length > 0 ? '/home/' + accountName : '')
    let nextPath = ''
    let nextRootType = root.personalRootType
    let nextEntries = root.personal
    let nextPageIndex = 1
    let nextPageHasMore = false
    let nextTotalCount = -1
    if (personalPath.length > 0) {
      try {
        const page = await this.repository.listPage(personalPath, 3, 1)
        nextPath = personalPath
        nextRootType = 3
        nextEntries = page.entries
        nextPageIndex = page.pageIndex
        nextPageHasMore = page.hasMore
        nextTotalCount = page.totalCount
      } catch (_) {
        // If the user's directory is unavailable, commit the usable root once.
      }
    }
    this.directoryCounts = {}
    this.directoryCountRequests = {}
    this.personalRoots = root.personal
    this.sharedRoots = root.shared
    this.rootKind = 'personal'
    this.selectedBottomTab = 'home'
    this.personalRootEntriesType = root.personalRootType
    this.currentRootType = nextRootType
    this.currentPath = nextPath
    this.navigationStack = nextPath.length > 0 ? [''] : []
    this.navigationEntryStack = []
    this.navigationRootTypeStack = []
    this.navigationViewStateStack = []
    this.navigationPageIndexStack = []
    this.navigationPageHasMoreStack = []
    this.setCurrentPageState(nextPageIndex, nextPageHasMore)
    this.replaceEntries(nextEntries)
    this.updateTopTitle(this.fileTitle(nextPath))
    this.resetPreviewState()
    if (nextPath.length > 0) {
      this.updateDirectoryCount(nextPath, nextTotalCount >= 0 ? nextTotalCount : nextEntries.length)
      this.statusText = '个人目录'
      this.schedulePhotosPreindex(nextPath)
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
    // 不要用"personalRoots 只有一个就用它"兜底 ✗ —— /home 下唯一的那个文件夹
    // 仍然是【普通文件夹】不是用户根 ✓ 把它当根会导致"打开它永远列表 + 切换按钮失效"。
    return null
  }

  /**
   * 进目录的等待提示只在【确实是大目录】时才显示。判断来源（都很快）：
   *   ① directoryCounts[path] —— 本次会话真的拉过它时记下的（见 updateDirectoryCount）
   *   ② entry.childCount      —— 父目录列表里就带着（DirectoryMetadataStore 解析服务端
   *                              childCount，-1 = 服务端没给 = 未知）
   *   ③ 都未知 → 用 limit=1 的轻请求问 total（UgreenRemoteRepository.countDirectory）
   * 未知且结果还没回来时【不显示】——宁可晚一点出现，也不要"什么都不知道就弹"。
   */
  private async armDirectoryOpeningHint(entry: FileEntry): Promise<void> {
    this.directoryOpeningHintVisible = false
    const token = this.directoryOpeningHintToken + 1
    this.directoryOpeningHintToken = token
    const recorded = this.directoryCounts[entry.path]
    const estimate = typeof recorded === 'number' ? recorded : entry.childCount
    if (estimate >= 0) {
      this.directoryOpeningHintVisible = estimate >= DIRECTORY_OPENING_HINT_MIN_ITEMS
      return
    }
    try {
      const total = await this.repository.countDirectory(entry.path, entry.rootType)
      if (token !== this.directoryOpeningHintToken) {
        return
      }
      this.directoryOpeningHintVisible = total >= DIRECTORY_OPENING_HINT_MIN_ITEMS
    } catch (error) {
      console.warn('[UgreenDirectory] count failed: ' + JSON.stringify(error))
    }
  }

  private async openDefaultPersonalDirectory(): Promise<void> {
    const defaultDirectory = this.findDefaultPersonalDirectory()
    const accountName = this.username.trim()
    // 落点统一为【用户根】✓：优先用服务端给的同名目录路径；拿不到就直接用 /home/<用户名> ✓
    // （这样非管理员和管理员打开都停在同一级 ✓ 而且它属于根级 → 强制列表 ✓）
    const personalPath = defaultDirectory !== null
      ? (defaultDirectory.path.length > 0 ? defaultDirectory.path : '/' + defaultDirectory.name)
      : (accountName.length > 0 ? '/home/' + accountName : '')
    if (personalPath.length === 0) {
      this.enterFileScreen('personal')
      this.showRoot('personal')
      return
    }
    const requestId = this.navigationRequestId
    this.isBusy = true
    this.isNavigating = true
    if (defaultDirectory !== null) {
      this.armDirectoryOpeningHint(defaultDirectory).catch((): void => {})
    }
    try {
      const personalPage = await this.repository.listPage(personalPath, 3, 1)
      if (requestId !== this.navigationRequestId) {
        return
      }
      this.enterFileScreen('personal')
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
      // 首页这条加载路径以前不下发默认视图 ✗ → 默认设了网格也要"进二级目录再返回"才生效 ✓
      this.applyPreferredViewMode()
      this.updateTopTitle(this.fileTitle(personalPath))
      this.updateBottomBarVisibility(true)
      this.updateDirectoryCount(personalPath, personalPage.totalCount >= 0
        ? personalPage.totalCount : personalPage.entries.length)
      this.resetPreviewState()
      this.statusText = '个人目录'
      this.schedulePhotosPreindex(personalPath)
    } catch (_) {
      if (requestId === this.navigationRequestId) {
        this.enterFileScreen('personal')
        this.showRoot('personal')
      }
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
    this.currentRootType = kind === 'personal' ? this.personalRootEntriesType : 3
    this.currentPath = ''
    this.navigationStack = []
    this.navigationEntryStack = []
    this.navigationRootTypeStack = []
    this.navigationViewStateStack = []
    this.navigationPageIndexStack = []
    this.navigationPageHasMoreStack = []
    this.setCurrentPageState(1, false)
    this.replaceEntries(kind === 'personal' ? this.personalRoots : this.sharedRoots)
    // 首页/共享这两个根目录也走这里 —— 以前这条路径不下发默认视图 ✗ 所以永远是列表 ✓
    this.applyPreferredViewMode()
    this.updateTopTitle(this.fileTitle('', kind))
    this.updateBottomBarVisibility(true)
    this.resetPreviewState()
    this.statusText = kind === 'personal' ? '个人空间' : '共享空间'
  }

  private async openEntry(entry: FileEntry): Promise<void> {
    this.tapTraceBegin('openEntry ' + (entry.isDirectory ? 'dir' : 'file') + ' ' + entry.name)
    if (this.isBusy) {
      // 不再直接丢弃：转场/动画期间的点击推迟到这次交互收尾时执行，
      // 否则用户会以为"返回之后一段时间点不动"。
      this.traceInteractionGuards('openEntry-blocked')
      this.deferOpenEntry(entry)
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
    this.armDirectoryOpeningHint(entry).catch((): void => {})
    // 目录要换了：可见范围还是上一个目录留下的值，会让时间轴的资格判断误判通过，
    // 于是"闪出来一下又闪没"。这里先清零，等新目录渲染后的滚动回调再填真实值。
    this.fileVisibleStartIndex = 0
    this.fileVisibleEndIndex = 0
    const requestId = this.navigationRequestId + 1
    this.navigationRequestId = requestId
    this.errorText = ''
    this.statusText = '正在读取目录…'
    const nextPath = this.resolveEntryPath(entry)
    const nextRootType = nextPath.length > 0 ? 3 :
      (entry.rootType > 0 ? entry.rootType : this.currentRootType)
    try {
      // Global sorting cannot be derived from the server's first page. Prefer
      // the persisted complete index (or build it once) before mounting the
      // directory, so the user never sees a temporary page order followed by
      // a full-directory reorder.
      const nextSnapshot = await this.repository.ensureDirectoryIndex(nextPath, nextRootType)
      this.tapTrace('after-ensureIndex', 'entries=' + nextSnapshot.entries.length.toString())
      const query = new DirectoryQuery()
      query.path = nextPath
      query.rootType = nextRootType
      query.sortKey = this.fileSortKey
      query.ascending = this.fileSortAscending
      const nextEntries = DirectoryTimelinePolicy.query(nextSnapshot.entries, query)
      this.tapTrace('after-query', 'shown=' + nextEntries.length.toString())
      if (requestId !== this.navigationRequestId) {
        return
      }
      // The directory read has completed. From this point the staged visual
      // transition owns input until its finish callback releases isBusy.
      this.isNavigating = false
      const transitioned = await this.transitionFileContent(outgoingEntries, 'push',
        nextPath, outgoingViewState, (): void => {
        this.navigationStack = this.navigationStack.concat([this.currentPath])
        this.navigationEntryStack = this.navigationEntryStack.concat([this.entries.slice()])
        this.navigationRootTypeStack = this.navigationRootTypeStack.concat([this.currentRootType])
        this.navigationViewStateStack = this.navigationViewStateStack.concat([
          this.cloneDirectoryViewState(outgoingViewState)])
        this.navigationPageIndexStack = this.navigationPageIndexStack.concat([this.currentPageIndex])
        this.navigationPageHasMoreStack = this.navigationPageHasMoreStack.concat([this.currentPageHasMore])
        this.currentPath = nextPath
        this.currentRootType = nextRootType
        this.indexedDirectoryKey = nextRootType.toString() + ':' + nextPath
        this.indexedDirectoryContentSignature = nextSnapshot.contentSignature.length > 0
          ? nextSnapshot.contentSignature : DirectoryTimelinePolicy.contentSignature(nextSnapshot.entries)
        this.directoryTimeline = nextSnapshot.timeline
        this.timelineIndexing = false
        this.resetTimelineInteraction()
        if (nextSnapshot.timeline.eligible()) {
          const endpoint = this.fileSortAscending
            ? nextSnapshot.timeline.earliestTime : nextSnapshot.timeline.latestTime
          this.timelineFocusTime = DirectoryTimelinePolicy.localDayStart(endpoint)
        } else {
          this.timelineFocusTime = 0
        }
        this.setCurrentPageState(Math.max(1, Math.ceil(nextEntries.length / 200)), false)
        this.replaceEntries(nextEntries, false, true)
        // 进入新目录：按设置里的默认视图落地。放这里是因为 replaceEntries 刚把
        // currentDirectoryIsPhotoAlbum 更新好，而且这个回调每次进入只跑一次 ——
        // 不能放进 replaceEntries 本身（加载/排序/刷新/翻页都会跑，会拖垮加载）。
        this.applyPreferredViewMode()
        this.updateBottomBarVisibility(true)
        this.updateDirectoryCount(nextPath, nextSnapshot.totalCount >= 0
          ? nextSnapshot.totalCount : nextEntries.length)
      }, (): void => this.settleNewDirectoryAtTopForTransition(), true)
      this.tapTrace('after-transition', 'transitioned=' + transitioned.toString())
      if (!transitioned) {
        return
      }
      this.statusText = nextEntries.length === 0 ? '目录读取成功（空目录）' : '目录读取成功'
      if (Date.now() - nextSnapshot.fetchedAt > DIRECTORY_INDEX_STALE_MS &&
        nextEntries.length <= DIRECTORY_AUTO_REFRESH_MAX_ITEMS) {
        setTimeout((): void => {
          if (nextPath === this.currentPath && nextRootType === this.currentRootType) {
            this.scheduleCurrentDirectoryIndex(true)
          }
        }, 0)
      }
    } catch (error) {
      if (requestId === this.navigationRequestId) {
        if (this.isMissingRemoteEntryError(error as Object)) {
          try {
            await this.refreshCurrentDirectory([entry.path])
            this.statusText = '文件夹已不存在，目录已刷新'
            this.showImmersiveToast('文件夹已不存在，已从目录移除')
          } catch (refreshError) {
            this.presentErrorMessage(readableUgreenError(refreshError as Object) +
              '（路径：' + nextPath + '）', '目录读取失败')
            this.statusText = '目录读取失败'
          }
        } else if (error instanceof UgreenError && error.kind === UgreenErrorKind.NAS_UNAVAILABLE) {
          this.reportError(error, '目录读取失败')
        } else {
          this.presentErrorMessage(readableUgreenError(error as Object) + '（路径：' + nextPath + '）', '目录读取失败')
          this.statusText = '目录读取失败'
        }
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
    // 返回父目录时同样先清掉当前目录留下的可见范围（时间轴资格判断要用干净的值）
    this.fileVisibleStartIndex = 0
    this.fileVisibleEndIndex = 0
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
    if (this.searchSession !== null && this.searchSession.returnMode === 'directory' &&
      this.currentPath === this.searchSession.targetParentPath) {
      this.restoreSearchSession()
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
    if (this.shouldRestoreSearch(previousPath, stack.length)) {
      this.restoreSearchSession()
      return
    }
    if (previousPath.length === 0) {
      this.isBusy = true
      const childAnchor = this.continuationAncestorAnchors.get('')
      const incomingEntries = this.rootKind === 'personal' ? this.personalRoots : this.sharedRoots
      await this.transitionBackFileContent(incomingEntries, previousViewState,
        '', (preparedEntries: FileEntry[]): void => {
        this.navigationStack = stack
        this.navigationEntryStack = entryStack
        this.navigationRootTypeStack = rootTypeStack
        this.navigationViewStateStack = viewStateStack
        this.navigationPageIndexStack = pageIndexStack
        this.navigationPageHasMoreStack = pageHasMoreStack
        this.currentPath = previousPath
        this.currentRootType = this.rootKind === 'personal' ? this.personalRootEntriesType : 3
        this.setCurrentPageState(1, false)
        this.replaceEntries(preparedEntries, false, true)
        if (previousViewState !== null) {
          this.fileViewMode = previousViewState.mode
        }
        this.applyPreferredViewMode()
        this.updateBottomBarVisibility(true)
      })
      if (childAnchor !== undefined) {
        this.continuationAncestorAnchors.delete('')
        const child = this.entries.find((entry: FileEntry): boolean => entry.path === childAnchor)
        if (child !== undefined) { this.scrollToLocatedEntry(child) }
      }
      return
    }

    // The parent page was already visible before entering the child. Restore
    // that snapshot immediately; the repository cache remains available for
    // a later explicit refresh.
    if (previousEntries !== null) {
      this.isBusy = true
      await this.transitionBackFileContent(previousEntries, previousViewState,
        previousPath, (preparedEntries: FileEntry[]): void => {
        this.navigationStack = stack
        this.navigationEntryStack = entryStack
        this.navigationRootTypeStack = rootTypeStack
        this.navigationViewStateStack = viewStateStack
        this.navigationPageIndexStack = pageIndexStack
        this.navigationPageHasMoreStack = pageHasMoreStack
        this.currentPath = previousPath
        this.currentRootType = previousRootType
        this.setCurrentPageState(previousPageIndex, previousPageHasMore)
        // Determine the parent directory type before selecting its view mode.
        // Using the child's album flag here can remount List/Grid during the
        // position restore and reset the parent Scroller to the top.
        this.replaceEntries(preparedEntries, false, true)
        if (previousViewState !== null) {
          this.fileViewMode = previousViewState.mode
        }
        this.applyPreferredViewMode()
        this.updateBottomBarVisibility(true)
      })
      return
    }

    this.isBusy = true
    const returnIdentity = this.repository.sessionIdentity()
    const returnRequest = this.navigationRequestId
    try {
      const childAnchor = this.continuationAncestorAnchors.get(previousPath)
      const loadedPage = await this.repository.listPage(previousPath, previousRootType, 1)
      let loadedEntries = loadedPage.entries
      if (childAnchor !== undefined) {
        const snapshot = await this.repository.ensureDirectoryIndex(previousPath, previousRootType)
        if (!snapshot.timeline.complete) { throw new Error('父目录尚未加载完整') }
        const query = new DirectoryQuery()
        query.path = previousPath; query.rootType = previousRootType
        query.sortKey = this.fileSortKey; query.ascending = this.fileSortAscending
        loadedEntries = DirectoryTimelinePolicy.query(snapshot.entries, query)
        loadedPage.pageIndex = Math.max(1, Math.ceil(loadedEntries.length / 200))
        loadedPage.hasMore = false
      }
      if (returnIdentity !== this.repository.sessionIdentity() || returnRequest !== this.navigationRequestId ||
        this.screen !== 'files') { return }
      await this.transitionBackFileContent(loadedEntries, previousViewState,
        previousPath, (preparedEntries: FileEntry[]): void => {
        this.navigationStack = stack
        this.navigationEntryStack = entryStack
        this.navigationRootTypeStack = rootTypeStack
        this.navigationViewStateStack = viewStateStack
        this.navigationPageIndexStack = pageIndexStack
        this.navigationPageHasMoreStack = pageHasMoreStack
        this.currentPath = previousPath
        this.currentRootType = previousRootType
        this.setCurrentPageState(loadedPage.pageIndex, loadedPage.hasMore)
        this.replaceEntries(preparedEntries, false, true)
        if (previousViewState !== null) {
          this.fileViewMode = previousViewState.mode
        }
        this.applyPreferredViewMode()
        this.updateBottomBarVisibility(true)
        this.updateDirectoryCount(previousPath, loadedPage.totalCount >= 0
          ? loadedPage.totalCount : loadedPage.entries.length)
      })
      if (childAnchor !== undefined) {
        this.continuationAncestorAnchors.delete(previousPath)
        const child = this.entries.find((entry: FileEntry): boolean => entry.path === childAnchor)
        if (child !== undefined) { this.scrollToLocatedEntry(child) }
      }
    } catch (error) {
      this.reportError(error as Object, '返回目录失败')
    } finally {
      if (!this.showPageTransition && returnRequest === this.navigationRequestId) {
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
    // 诊断：点击事件是否真的到达了 JS。若复现"丢触控"时这里没有日志，
    // 说明触摸在 UI 层就被拦掉了（而不是被下面的 isBusy 等守卫丢掉）。
    this.tapTraceBegin('click ' + entry.name)
    this.traceInteractionGuards('click-in')
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
    // The file manager and the recycle bin share this one menu shell — the
    // anchor, the preview and the dismissal lifecycle — because a long press
    // should feel identical in both places. Only the rows inside differ, and
    // `contextMenuContext` records which set to render.
    const inFiles = this.screen === 'files' && !this.showSearch && !this.selectionMode &&
      !this.showDestinationPicker && !this.showRenameDialog && !this.showCreateFolderDialog &&
      !this.showImageViewer && !this.showAudioPlayer && !this.videoPlaybackUiVisible() &&
      !this.showPageTransition && this.contextMenuEntry === null
    const inRecycle = this.showRecycleBinSettings && !this.recycleLoading &&
      this.contextMenuEntry === null
    if (!inFiles && !inRecycle) {
      return
    }
    this.contextMenuContext = inRecycle ? 'recycle' : 'files'

    // The one haptic on this whole interaction, and the reason haptics are
    // worth having at all: the finger is still on the row, so the menu
    // appearing is partly under the hand. Fired here rather than at each of
    // the four long-press call sites, and only once the guards above have
    // passed so a swallowed long press stays silent.
    HapticFeedback.longPress()

    this.pendingContextAction = null
    this.contextMenuScrollMoved = false
    this.slidePressKey = ''
    this.contextMenuPreviewSurface = inRecycle ? 'list' : this.activeListSurface()
    const tile = this.contextMenuPreviewSurface !== 'list'
    const width = this.contextMenuPreviewSurface === 'waterfall'
      ? Math.max(1, (this.effectivePageWidth() - 20 - (this.waterfallColumnCount() - 1) * 8) /
        this.waterfallColumnCount())
      : Math.max(1, (this.effectivePageWidth() - this.fileGridColumnCount() + 1) /
        this.fileGridColumnCount() - 2)
    const height = this.contextMenuPreviewSurface === 'waterfall'
      ? width / this.waterfallAspectRatio(entry) : width
    const finger = event.fingerList.length > 0 ? event.fingerList[0] : null
    const fallback: ContextPreviewRect = {
      x: (finger === null ? this.effectivePageWidth() / 2 : finger.globalX - this.mainContentOriginX) - width / 2,
      y: (finger === null ? this.pageHeightVp / 2 : finger.globalY - this.mainContentOriginY) -
        (tile ? height / 2 : 29),
      width: width,
      height: height
    }
    const directoryKey = this.currentRootType.toString() + ':' + this.currentPath + ':' +
      this.contextMenuPreviewSurface
    const area = tile && this.rowHitDirectoryKey === directoryKey
      ? this.rowHitAreas.get(this.contextMenuPreviewSurface + ':' + entry.path) : undefined
    const rect: ContextPreviewRect | null = area === undefined ? null : {
      x: area.x - this.mainContentOriginX,
      y: area.y - this.mainContentOriginY,
      width: area.width,
      height: area.height
    }
    this.contextMenuLayout = ContextMenuPreviewLayout.fit(tile, rect, fallback,
      this.effectivePageWidth(), this.pageHeightVp, this.topSafeInset(), this.bottomSafeInset(),
      this.actionMenuNaturalHeight(entry))
    // Freeze exactly one existing source, without downloads or Image Kit
    // decoding. The lease prevents an LRU eviction/replacement from releasing
    // a WaterFlow raster while its native preview is still animating out.
    const bitmap = this.contextMenuPreviewSurface === 'waterfall' ? this.waterfallBitmaps[entry.path] : undefined
    this.contextMenuPreviewBitmap = bitmap === undefined ? null : bitmap
    if (bitmap !== undefined) {
      this.viewerBitmapStore.retainPreview(bitmap)
      this.contextMenuPreviewSource = bitmap.pixelMap
      this.contextMenuPreviewOrientation = ImageRotateOrientation.UP
    } else {
      this.contextMenuPreviewSource = tile ? this.previewUri(entry) : ''
      this.contextMenuPreviewOrientation = this.fileListImageBaseOrientation(entry)
    }
    this.contextMenuEntry = entry
    this.contextMenuOpening = true
    const token = ++this.contextMenuOpenToken
    // Submit the new anchor geometry before presenting the native subwindow.
    // Otherwise a second long press can animate from the previous item's rect.
    this.postRenderFrame((): void => {
      if (token !== this.contextMenuOpenToken || this.contextMenuEntry === null) {
        return
      }
      this.contextMenuOpening = false
      this.contextMenuVisible = true
    })
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
    if (this.contextMenuScrollMoved) {
      return
    }
    // Run the chosen action in the SAME tick as the dismiss request, rather
    // than waiting for onDidDisappear.
    //
    // Waiting looks tidier but breaks every row that opens a dialog. By the
    // time onDidDisappear fires, the menu's subwindow is already being torn
    // down, and the window manager refuses the dialog its own new window:
    //     WMS: SetWindowType: permission denied!
    //     WMSLife: Create: context is nullptr
    //     Window: CreateWindowWithSession: error: 15
    //     AceSubWindow: [(-1:100000:singleton)] init toast dialog window failed
    // The menu closes, no dialog appears, and 详情 / 删除 read as dead rows.
    // Asking while the menu is still up keeps a valid window context; the
    // dialog simply covers the menu, which closes underneath it.
    this.pendingContextAction = null
    this.dismissActionMenu()
    action()
  }

  private dismissActionMenu(): void {
    this.contextMenuOpenToken += 1
    if (this.contextMenuOpening) {
      this.finishActionMenuDismiss()
      return
    }
    this.contextMenuVisible = false
  }

  private finishActionMenuDismiss(): void {
    if (this.contextMenuEntry === null) {
      return
    }
    // Keep the preview data and the bottom bar's visibility stable until the
    // native menu AND preview have completed their exit animation.
    //
    // The action itself already ran in runContextAction, which is why nothing
    // is dispatched from here.
    this.contextMenuVisible = false
    this.contextMenuOpenToken += 1
    this.contextMenuOpening = false
    const bitmap = this.contextMenuPreviewBitmap
    this.contextMenuPreviewBitmap = null
    this.contextMenuPreviewSource = ''
    this.contextMenuEntry = null
    this.pendingContextAction = null
    this.contextMenuScrollMoved = false
    this.slideItems.forEach((_, key: string): void => {
      if (key.startsWith('ctxmenu:')) {
        this.slideItems.delete(key)
      }
    })
    if (bitmap !== null) {
      this.viewerBitmapStore.releasePreview(bitmap).catch((): void => {})
    }
  }

  private closeActionMenu(): void {
    this.pendingContextAction = null
    this.dismissActionMenu()
  }

  private actionMenuHeight(entry: FileEntry): number {
    return Math.min(this.actionMenuNaturalHeight(entry), this.contextMenuLayout.menuHeight)
  }

  private actionMenuNaturalHeight(entry: FileEntry): number {
    if (this.contextMenuContext === 'recycle') {
      // Two rows, no section gap — the rows are peers, so they sit flush and
      // the panel is exactly as tall as they are. Nothing here depends on the
      // entry: restore and permanent deletion apply to folders and files
      // alike, and a recycled entry has no quick actions, no open-with and no
      // cache state.
      return 2 * 51
    }
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
    return height
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
        // download. The route remains the same system download directory.
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
    await this.showTrackedDialog({
      title: entry.name,
      message: lines.join('\n'),
      buttons: [{ text: '确定', color: '#2E6BFF' }],
      systemMaterial: this.immersiveMaterial(uiMaterial.ImmersiveStyle.ULTRA_THICK, false)
    })
  }

  private beginDestinationPicker(operation: DestinationOperation, entry: FileEntry): void {
    this.beginDestinationPickerForEntries(operation, [entry])
  }

  private beginDestinationPickerForEntries(operation: DestinationOperation,
    entries: FileEntry[]): void {
    if (this.isBusy || this.destinationOperationRunning) {
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
    this.destinationOperationRunning = false
    this.showDestinationPicker = true
    this.closeActionMenu()
    this.loadDestinationEntries()
  }

  private closeDestinationPicker(): void {
    if (this.destinationOperationRunning || this.destinationPickerClosing) {
      return
    }
    this.destinationPickerClosing = true
    this.destinationLoading = false
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
      // Release the input layer after the 180 ms card exit completes.
    }, 200)
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
    if (this.destinationOperationRunning || this.destinationPickerClosing) { return }
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
    if (this.destinationOperationRunning || this.destinationPickerClosing) { return }
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
    this.destinationOperationRunning = true
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
      this.destinationOperationRunning = false
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
      return '我的云盘'
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
    this.fileListPersistedDisplayState = new ImageDisplayState()
    this.fileListRotationReady = false
    if (entries.length === 0) {
      this.fileListRotationReady = true
      return
    }
    const snapshot = entries.slice()
    this.loadPersistedImageDisplayState(snapshot).then((state: ImageDisplayState): void => {
      if (generation !== this.fileListRotationGeneration) {
        return
      }
      this.fileListPersistedDisplayState = state
      this.fileListRotationReady = true
      // Lazy containers only need display metadata for mounted images. The
      // complete directory snapshot may contain thousands of files; creating
      // one reactive ImageVisualState per file here makes every later
      // onAppear update copy that entire table.
      for (const entry of snapshot) {
        if (this.imageVisualStates[entry.path] !== undefined) {
          this.resolveFileListImageRotation(entry, true)
        }
      }
    }).catch((error: Error): void => {
      if (generation === this.fileListRotationGeneration) {
        this.fileListPersistedDisplayState = new ImageDisplayState()
        this.fileListRotationReady = true
        for (const entry of snapshot) {
          if (this.imageVisualStates[entry.path] !== undefined) {
            this.resolveFileListImageRotation(entry, true)
          }
        }
      }
      console.warn('[UgreenImage] refresh file-list display metadata failed: ' + JSON.stringify(error))
    })
  }

  private resolveFileListImageRotation(entry: FileEntry, force: boolean = false): void {
    if (!this.isImage(entry) || !this.fileListRotationReady) {
      return
    }
    const previous = this.imageVisualState(entry.path)
    if (!force && previous.rotationResolved) {
      return
    }
    const storedRotation = this.fileListPersistedDisplayState.rotations[entry.path]
    const storedOrientation =
      this.fileListPersistedDisplayState.previewOrientations[entry.path]
    const rotation = storedRotation === undefined ? 0 : storedRotation
    const orientation = storedOrientation === undefined
      ? (this.previewCanonicalPaths[entry.path] === true
        ? ImageRotateOrientation.UP : ImageRotateOrientation.AUTO) : storedOrientation
    if (!previous.rotationResolved || previous.userRotation !== rotation ||
      previous.thumbnailOrientation !== orientation) {
      this.updateImageVisualState(entry.path, (next: ImageVisualState): void => {
        next.userRotation = rotation
        next.rotationResolved = true
        next.thumbnailOrientation = orientation
      }, false)
      if (USE_GLOBAL_BITMAP_EPOCH) {
        this.scheduleImageVisualNotify()
      } else {
        this.notifyEntryChanged(entry.path, 'grid')
      }
    }
    const thumbnail = this.fileThumbnailBitmaps[entry.path]
    if (thumbnail !== undefined && thumbnail.userRotation !== rotation) {
      this.releaseFileThumbnailBitmap(entry.path)
    }
    const waterfall = this.waterfallBitmaps[entry.path]
    if (waterfall !== undefined && waterfall.userRotation !== rotation) {
      this.releaseViewerBitmap(this.waterfallBitmaps, entry.path).catch((): void => {})
      this.waterfallDecodedPaths[entry.path] = false
    }
    if (this.fileViewMode === 'waterfall' && this.waterfallVisiblePaths[entry.path] === true) {
      this.enqueueWaterfallPreviewGeometry(entry)
      this.enqueueWaterfallDecode(entry)
    }
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
    }, false)
    if (USE_GLOBAL_BITMAP_EPOCH) {
      this.scheduleImageVisualNotify()
    } else {
      this.notifyEntryChanged(path, 'grid')
    }
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
    this.destinationOperationRunning = true
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
      HapticFeedback.success()
      this.showImmersiveToast(this.statusText)
      this.destinationLoading = false
      this.destinationOperationRunning = false
      this.closeDestinationPicker()
    } catch (error) {
      this.reportError(error as Object, this.destinationOperation === 'copy' ? '复制失败' : '移动失败')
    } finally {
      this.destinationOperationRunning = false
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
    this.imageVisualEpoch += 1
  }

  private async openImageViewer(entry: FileEntry, customImageEntries?: FileEntry[],
    continuationOpen: boolean = false, continuationValid: (() => boolean) | null = null): Promise<void> {
    this.tapTraceBegin('openImageViewer ' + entry.name)
    this.cancelViewerCleanupTimer()
    if (this.isBusy || this.viewerClosePending || entry.isDirectory) {
      this.traceInteractionGuards('openImageViewer-blocked')
      return
    }
    this.closeActionMenu()
    this.viewerBlocksFileContent = true
    this.viewerClosing = false
    this.viewerInteractionUnlocked = false
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在准备图片预览…'
    try {
      const imageEntries = customImageEntries !== undefined && customImageEntries.length > 0
        ? customImageEntries
        : this.imageEntriesInCurrentDirectory()
      const initialIndex = imageEntries.findIndex((item: FileEntry) => item.path === entry.path)
      this.tapTrace('after-collect', 'imgs=' + imageEntries.length.toString() +
        ' idx=' + initialIndex.toString())
      if (initialIndex < 0) {
        throw new Error('未找到对应图片')
      }
      this.captureViewerReturnScrollPosition()
      const persistedState = await this.loadPersistedImageDisplayState(imageEntries)
      if (continuationValid !== null && !continuationValid()) { throw new Error('Continuation cancelled') }
      this.tapTrace('after-persistedState')
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
      if (continuationValid !== null && !continuationValid()) { throw new Error('Continuation cancelled') }
      this.tapTrace('after-primeFrameWindow')
      this.ensureViewerImageFrame(entry)
      this.tapTrace('after-ensureFrame')
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
      if (continuationValid !== null && !continuationValid()) { throw new Error('Continuation cancelled') }
      this.tapTrace('after-ensurePreviewBitmap')
      // Commit the source-only frame first. The following hierarchy swap is
      // the sole state change inside animateTo, so one Image leaves the file
      // surface at exactly the moment its viewer counterpart is inserted.
      if (!continuationOpen) { this.startViewerEntryTransition(entry) }
      this.tapTrace('after-startTransition',
        'sharedElement=' + this.viewerEntryTransitionActive.toString())
      this.logViewerDiagnostic(this.viewerEntryTransitionActive
        ? 'entry-source-bound' : 'entry-fallback', entry.path)
      if (this.viewerEntryTransitionActive) {
        await this.nextRenderFrame()
        this.tapTrace('entry-frame1-done')
        // ── 实验 A（单变量）：source 多留一个完整渲染周期 ──────────────────────
        //
        // 背景（R3.3 回归已坐实）：entry 的局部 notify 让 GridThumbCell 在交换前
        // ~1ms 就 build 出 tid=X，但「cell 执行了 build」≠「带 X 的 Image 已完成一次
        // ArkUI 渲染/几何注册」；实测这一帧不足以注册 source → 打开动画消失。
        // （此前 b1 版"有动画"是骑在"关闭时残留的 X"上，R3.3 正确清掉残留后即暴露。）
        //
        // 这里只多等一个渲染帧，让带 X 的 source 完整存活一个渲染周期再交换。
        // ⚠️ 这不是 setTimeout 盲等，而是与"渲染注册时序"直接相关的帧同步。
        // ⚠️ 若仍失败就到此为止，不要继续加帧（那说明需要改 source 的显式输入/生命周期）。
        await this.nextRenderFrame()
        this.tapTrace('entry-frame2-done')
        await new Promise<void>((resolve: () => void): void => {
          this.getUIContext().animateTo({
            duration: IMAGE_GEOMETRY_TRANSITION_DURATION,
            curve: Curve.FastOutSlowIn,
            onFinish: (): void => {
              this.tapTrace('anim-finish(shared)')
              // ⚠️ 动画播完就是用户眼里的"已经进去了"。此刻必须放开交互锁：
              // 否则用户"看到动画结束立刻点击/滑动"会被 isBusy 挡掉，感觉丢触控。
              // （后面的 nextRenderFrame / clearViewerEntryTransition 只是收尾。）
              this.isBusy = false
              this.runPendingOpenEntry()
              resolve()
            }
          }, () => {
            this.tapTrace('VISIBLE(shared) animStart')
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
        this.tapTrace('VISIBLE(fallback)')
        this.showImageViewer = true
        await this.nextRenderFrame()
        await new Promise<void>((resolve: () => void): void => {
          this.getUIContext().animateTo({
            duration: IMAGE_FALLBACK_TRANSITION_DURATION,
            curve: Curve.EaseOut,
            onFinish: (): void => {
              this.isBusy = false
              this.runPendingOpenEntry()
              resolve()
            }
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
      if (continuationValid !== null && !continuationValid()) { throw new Error('Continuation cancelled') }
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
      this.viewerPrefetchCoordinator?.onViewerOpened(initialIndex, this.viewerImages)
      this.prefetchViewerImages(initialIndex)
      this.statusText = ''
    } catch (error) {
      this.viewerInteractionUnlocked = true
      this.clearViewerEntryTransition()
      this.showImageViewer = false
      this.viewerSurfaceOpacity = 1
      this.viewerFallbackEntryActive = false
      if (continuationValid !== null && !continuationValid()) {
        this.viewerGeneration++
        this.viewerBlocksFileContent = false
        this.statusText = ''
      } else {
      this.reportError(error as Object, '图片预览失败')
      this.statusText = '图片预览失败'
      }
    } finally {
      this.isBusy = false
      // 打开期间被挡下的点击在这里补上
      this.runPendingOpenEntry()
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

  private scrollMediaReturnSourceIntoView(entry: FileEntry): boolean {
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
      this.scrollItemIntoContentBand(scroller, childIndex, 0, false)
      return true
    } catch (error) {
      console.warn('[UgreenMedia] position return source failed: ' + JSON.stringify(error))
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
    attempt: number = 0, retryOnMissing: boolean = true): void {
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
    if (hasRect && this.targetLocateEntryPath.length > 0) {
      this.notifyTargetLocateVisible('contentBand', 'itemY=' + itemY.toString() + ' itemH=' + itemHeight.toString())
    }
    if (!hasRect) {
      // 目标还没挂载：先滚进视口，下一帧拿到真实矩形后再按可视带校正。
      if (attempt < 8) {
        try {
          scroller.scrollToIndex(childIndex, false, ScrollAlign.AUTO)
        } catch (_) {
        }
        // Media returns retry from their bounded rendered-frame loop. Only
        // the explicit file locator needs an independent delayed retry.
        if (retryOnMissing) {
          setTimeout((): void => {
            this.scrollItemIntoContentBand(scroller, childIndex, attempt + 1)
          }, 48)
        }
      }
      return
    }
    // getItemRect is relative to the actual scroll container. Safe-area
    // expansion can put its origin at 0 instead of below the status bar; use
    // the measured viewport shared with drag selection, not a fixed 94 vp.
    const viewportY = this.fileScrollViewport.y
    const viewportHeight = this.fileScrollViewport.height > 0
      ? this.fileScrollViewport.height : this.pageHeightVp
    const bandTop = Math.max(0, this.fileContentTopInset() - viewportY)
    const bandBottom = Math.max(bandTop, Math.min(this.pageHeightVp, viewportY + viewportHeight) -
      this.floatingBarContentInset(0) - viewportY)
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

  /** Shared image/audio return preparation. Never use the explicit file locator here. */
  private async prepareMediaReturnSource(entry: FileEntry, isCurrent: () => boolean,
    sourceReady: () => boolean, prepareSource?: () => Promise<void>): Promise<boolean> {
    if (!isCurrent()) { return false }
    // Match the Grid image return overlay: use mounted geometry only. A
    // missing target fades out without moving or rebuilding the file grid.
    if (this.screen === 'files' && !this.showSearch && this.fileViewMode === 'grid') {
      return sourceReady()
    }
    if (!this.scrollMediaReturnSourceIntoView(entry)) { return false }
    if (prepareSource !== undefined) { await prepareSource() }
    for (let frame = 0; frame < IMAGE_RETURN_MOUNT_FRAME_LIMIT; frame += 1) {
      await this.nextRenderFrame()
      if (!isCurrent()) { return false }
      if (sourceReady()) { return true }
      // A post-frame callback can still see the pre-scroll rect. Allow the
      // following layout to commit before applying another minimal correction;
      // otherwise the same scrollBy delta can be submitted twice.
      if (frame % 2 === 1 && frame + 1 < IMAGE_RETURN_MOUNT_FRAME_LIMIT) {
        this.scrollMediaReturnSourceIntoView(entry)
      }
    }
    // No independent timers survive this bounded preparation, so the first
    // file-page gesture cannot be overridden by a late scroll correction.
    return false
  }

  private async prepareViewerReturnSource(entry: FileEntry): Promise<boolean> {
    const isCurrent = (): boolean => this.showImageViewer && this.viewerImageEntry !== null &&
      this.viewerImageEntry.path === entry.path
    const ready = await this.prepareMediaReturnSource(entry, isCurrent,
      (): boolean => this.hasViewerTransitionSource(entry, true),
      // Swiper can return to another image. Prepare its shared preview bitmap
      // before binding the return id; audio uses its already displayed cover.
      async (): Promise<void> => { await this.ensureViewerPreviewBitmap(entry) })
    if (isCurrent()) { this.viewerReturnReadyPath = ready ? entry.path : '' }
    return ready
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
    // 架构清理：Viewer session cleanup 不应该让 Grid 产生无意义响应依赖。
  }

  private finishCloseImageViewer(shouldRestoreSearch: boolean): void {
    if (!this.viewerClosePending) {
      return
    }
    const closingImages = this.viewerImages.slice()
    const returnedEntry = this.viewerImageEntry
    // R3.3 步骤 2 需要用到"返回目标 path"，但它在下面会被清空，先抓下来。
    const returningPath = this.viewerReturnReadyPath.length > 0
      ? this.viewerReturnReadyPath
      : (returnedEntry === null ? '' : returnedEntry.path)
    this.clearViewerEntryTransition()
    const closingPreviewBitmaps = this.viewerPreviewBitmaps
    const closingOriginalBitmaps = this.viewerOriginalBitmaps
    const closingPreviewAliases = this.viewerPreviewBitmapAliases
    this.viewerPreviewBitmaps = {}
    this.viewerOriginalBitmaps = {}
    this.viewerOriginalLocalPaths = {}
    this.viewerPreviewBitmapAliases = {}

    this.viewerBlocksFileContent = false
    this.viewerClosing = false
    this.viewerInteractionUnlocked = true
    this.viewerClosePending = false
    this.viewerCloseRequested = false
    this.viewerReturnReadyPath = ''
    // ── R3.3 步骤 2：动画真正结束后，显式局部刷新返回目标这一格 ──
    //
    // 必须在本行之前的清理完成后再做：
    //   1) clearViewerEntryTransition()（L16126）→ 结束 exit transition / 清 geometryBound；
    //   2) viewerClosing = false（L16136）→ 退出动画语义结束；
    //   3) viewerReturnReadyPath = ''（上一行）→ source 不再处于 transition-active 状态。
    // 此时再补一次【既有的】局部刷新：
    //   · R2 之后 viewerClosing / geometryBound 这类父状态变化**驱动不到** GridThumbCell，
    //     不能只等状态自己生效，必须主动通知该 cell；
    //   · cell 重建时会重算 transitionId —— 此时已不在 transition 中，算出来是 ''（idle），
    //     **不残留本次 exit 的 id**；
    //   · 只通知这一个 path（不泛化、不做全 Grid 刷新、不动全局 epoch）。
    if (returningPath.length > 0) {
      this.notifyEntryChanged(returningPath, 'grid')
    }
    this.isBusy = false
    this.tapTrace('viewer-close-done')
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
    // 1. 重置 viewer 会话视觉状态（立即执行，不再推迟 250ms，且不再触发全局状态标脏）
    this.releaseViewerVisualSession(closingImages)
    // 2. 将关闭位图移入待释放队列，在交互静默期单张分片释放
    this.enqueuePendingViewerCleanup(closingImages, closingPreviewBitmaps, closingOriginalBitmaps, closingPreviewAliases)
    this.requestViewerCleanup()
    let originalLiveBytes = 0
    for (const key of Object.keys(closingOriginalBitmaps)) {
      const rec = closingOriginalBitmaps[key]
      if (rec && rec.pixelMap) {
        try {
          originalLiveBytes += rec.pixelMap.getPixelBytesNumber()
        } catch (_) {
          originalLiveBytes += (rec.physicalWidth || 1080) * (rec.physicalHeight || 1920) * 4
        }
      }
    }
    this.returnPerfSession.noteViewerClosed(
      this.getMonotonicNow(),
      originalLiveBytes,
      this.pendingViewerCleanupEstimatedBytes,
      this.pendingViewerCleanupQueue.length
    )
    this.postRenderFrame((): void => {
      if (returnedEntry !== null) {
        setTimeout((): void => {
          this.loadEntryPreview(returnedEntry, 0)
        }, 200)
      }
      // 实验 C：只隔离"返回后预热"这一步，UI 结构与其它逻辑完全不动。
      if (!DISABLE_RETURN_WARMUP) {
        this.schedulePreviewWarmup(this.previewGeneration)
      }
    })
    // A queued open must see a completely cleared old Viewer session. Starting
    // it before replaceViewerImages([])/resetImageTransform corrupts fast reopen.
    this.runPendingOpenEntry()
  }

  private closeImageViewer(skipReturnGeometry: boolean = false): void {
    if (!skipReturnGeometry) {
      this.tapTraceBegin('closeImageViewer')
    }
    if (this.viewerClosePending) {
      this.traceInteractionGuards('close-blocked')
      return
    }
    if (this.viewerTransitionActive ||
      (this.viewerEntryTransitionActive && this.viewerTransitionKind === 'entry')) {
      this.viewerCloseRequested = true
      this.setImageChromeVisible(false, false)
      return
    }
    this.beginCloseImageViewer(skipReturnGeometry)
  }

  private async beginCloseImageViewer(skipReturnGeometry: boolean = false): Promise<void> {
    if (this.viewerClosePending || !this.showImageViewer || this.viewerImageEntry === null) {
      return
    }
    this.viewerPrefetchCoordinator?.onViewerClosed()
    const shouldRestoreSearch = this.searchSession !== null && this.searchSession.returnMode === 'image'
    const returningEntry = this.viewerImageEntry as FileEntry
    const keepFileSurfacePosition = this.screen === 'files' &&
      !this.showSearch && this.currentPath.length > 0
    this.closeSessionId += 1
    // 🔬 实验 γ 诊断：把 OpenAnimProbe 的时间窗也覆到关闭阶段，这样日志才能看到
    //    关闭期间的 cellBuild（returning cell 是否存在 / tid）与 viewerTargetAppear
    //    （target 是否仍在树上）。**纯日志，不改行为。**
    this.openAnimProbeAt = this.getMonotonicNow()
    this.closeSessionActive = false
    this.sessionTouchTestCount = 0
    this.viewerInteractionUnlocked = false
    this.viewerClosePending = true
    this.isBusy = true
    this.setImageChromeVisible(false, false)

    // PoC scope: ordinary Grid. The close path reads cached geometry only;
    // it never scrolls, measures other items or prepares/decodes an Original.
    if (!skipReturnGeometry && this.screen === 'files' && !this.showSearch &&
      this.fileViewMode === 'grid') {
      await this.closeGridViewerWithReturnOverlay(returningEntry, shouldRestoreSearch)
      return
    }

    let returnReady = false
    if (!skipReturnGeometry) {
      returnReady = await this.prepareViewerReturnSource(returningEntry)
      this.tapTrace('after-prepareReturnSource', 'ready=' + returnReady.toString())
      if (!this.showImageViewer) {
        return
      }
      this.logViewerDiagnostic(returnReady ? 'return-source-ready' : 'return-fallback',
        returningEntry.path)
      if (!this.showImageViewer || this.viewerImageEntry === null ||
        this.viewerImageEntry.path !== returningEntry.path) {
        return
      }
    } else {
      this.viewerReturnReadyPath = ''
    }

    const lockedLayer = this.viewerActiveLayer(returningEntry)
    // 关闭共享元素转场时恒为 false → 退场走"淡出"的 fallback 分支
    const canUseGeometryTransition = !skipReturnGeometry &&
      VIEWER_USE_SHARED_ELEMENT_TRANSITION && returnReady &&
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
      this.viewerClosing = true
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
      if (skipReturnGeometry) {
        this.tapTrace('locate-exit-animation-start')
      }
      // An offscreen/unmounted source gets a single-image shrink and fade;
      // it never flies to a stale rectangle from another Swiper page.
      this.viewerClosing = true
      await new Promise<void>((resolve: () => void): void => {
        this.getUIContext().animateTo({
          duration: IMAGE_FALLBACK_TRANSITION_DURATION,
          curve: Curve.EaseIn,
          onFinish: (): void => {
            if (skipReturnGeometry) {
              this.tapTrace('locate-exit-animation-end')
            }
            resolve()
          }
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
    this.closeAnimFinishMonotonic = this.getMonotonicNow()
    this.closeSessionActive = true
    this.sessionTrackedPointerId = -1
    this.sessionPreDispatchDownLogged = false
    this.sessionRootDownLogged = false
    this.sessionChildDownLogged = false
    this.sessionPanStartLogged = false
    this.sessionFirstPanUpdateLogged = false
    this.sessionScrollStartLogged = false
    this.sessionTouchTestCount = 0
    this.tapTrace('after-closeAnim')
    if (closeGeneration === this.viewerGeneration) {
      this.finishCloseImageViewer(shouldRestoreSearch)
    }
  }

  private async closeGridViewerWithReturnOverlay(entry: FileEntry,
    shouldRestoreSearch: boolean): Promise<void> {
    const token = ++this.viewerReturnOverlayToken
    this.viewerReturnOverlayStartedAt = this.getMonotonicNow()
    const snapshot = new ViewerReturnSnapshot()
    snapshot.path = entry.path
    snapshot.source = this.viewerImageSource(entry)
    snapshot.orientation = this.viewerImageSourceOrientation(entry)
    snapshot.fit = this.viewerImageFit(entry)
    const viewportWidth = Math.max(1, this.imageViewportWidthVp)
    const viewportHeight = Math.max(1, this.imageViewportHeightVp)
    const ratio = this.viewerImageFrameAspectRatio(entry)
    const frame = this.viewerCurrentFrame
    const hasFrame = this.viewerCurrentFramePath === entry.path &&
      frame.width > 0 && frame.height > 0
    snapshot.frameWidth = hasFrame ? frame.width : Math.min(viewportWidth, viewportHeight * ratio)
    snapshot.frameHeight = hasFrame ? frame.height : snapshot.frameWidth / ratio
    const scale = this.viewerPageVisualScale(entry, this.viewerImageIndex)
    const width = snapshot.frameWidth * scale
    const height = snapshot.frameHeight * scale
    const frameX = hasFrame ? frame.x - this.viewerLayerOriginX : (viewportWidth - snapshot.frameWidth) / 2
    const frameY = hasFrame ? frame.y - this.viewerLayerOriginY : (viewportHeight - snapshot.frameHeight) / 2
    this.viewerReturnOverlayX = frameX + (snapshot.frameWidth - width) / 2 +
      this.viewerPageOffsetX(this.viewerImageIndex)
    this.viewerReturnOverlayY = frameY + (snapshot.frameHeight - height) / 2 +
      this.viewerPageOffsetY(this.viewerImageIndex)
    this.viewerReturnOverlayWidth = width
    this.viewerReturnOverlayHeight = height
    this.viewerReturnOverlayScale = scale
    this.viewerReturnOverlayOpacity = this.viewerSurfaceOpacity
    this.viewerReturnOverlayBackdropOpacity = this.imageDismissBackdropOpacity
    const state = this.imageVisualState(entry.path)
    snapshot.hasTarget = state.thumbnailSurface === 'grid' &&
      state.thumbnailVisibleRatio >= 0.999 && state.thumbnailWidth > 0 && state.thumbnailHeight > 0 &&
      state.thumbnailY >= this.fileContentTopInset() &&
      state.thumbnailY + state.thumbnailHeight <= this.pageHeightVp - this.bottomSafeInset() - 8
    snapshot.target.x = state.thumbnailX - this.viewerLayerOriginX
    snapshot.target.y = state.thumbnailY - this.viewerLayerOriginY
    snapshot.target.width = state.thumbnailWidth
    snapshot.target.height = state.thumbnailHeight
    this.viewerReturnSnapshot = snapshot
    this.viewerReturnReadyPath = snapshot.hasTarget ? entry.path : ''
    this.logViewerReturnOverlay('request')
    this.clearViewerEntryTransition()
    this.viewerGeneration += 1
    const closeGeneration = this.viewerGeneration
    this.viewerLoadQueue = []
    this.viewerLoadRequests = {}
    this.viewerManualLoadPaths = {}
    this.viewerActiveLoads = 0
    this.viewerActiveLoadPaths = {}
    this.viewerPrimaryPath = ''
    this.viewerPendingIndex = -1
    this.lastImageDoubleTapAt = 0
    this.viewerClosing = true
    // One atomic handoff: mount the single borrowed raster and remove Swiper.
    // No ImageViewer survives into the attribute animation below.
    this.viewerReturnHiddenPath = entry.path
    this.notifyEntryChanged(entry.path, 'grid')
    await new Promise<void>((resolve: () => void): void => {
      this.viewerReturnOverlayMountResolve = resolve
      this.viewerReturnOverlayVisible = true
      this.showImageViewer = false
    })
    if (token !== this.viewerReturnOverlayToken || closeGeneration !== this.viewerGeneration) {
      return
    }
    this.logViewerReturnOverlay('animation-start')
    await new Promise<void>((resolve: () => void): void => {
      this.getUIContext().animateTo({
        duration: snapshot.hasTarget ? IMAGE_GEOMETRY_TRANSITION_DURATION : IMAGE_FALLBACK_TRANSITION_DURATION,
        curve: Curve.FastOutSlowIn,
        onFinish: resolve
      }, (): void => {
        this.viewerReturnOverlayBackdropOpacity = 0
        if (snapshot.hasTarget) {
          this.viewerReturnOverlayX = snapshot.target.x
          this.viewerReturnOverlayY = snapshot.target.y
          this.viewerReturnOverlayWidth = snapshot.target.width
          this.viewerReturnOverlayHeight = snapshot.target.height
          // Uniform scale preserves the shown raster's ratio. The outer frame
          // crops into Grid's Cover square instead of stretching the image.
          this.viewerReturnOverlayScale = Math.max(snapshot.target.width / snapshot.frameWidth,
            snapshot.target.height / snapshot.frameHeight)
        } else {
          this.viewerReturnOverlayOpacity = 0
          this.viewerReturnOverlayScale = scale * 0.94
        }
      })
    })
    if (token !== this.viewerReturnOverlayToken || closeGeneration !== this.viewerGeneration) {
      return
    }
    this.logViewerReturnOverlay('animation-finish')
    this.viewerReturnRestoringPath = entry.path
    this.viewerReturnHiddenPath = ''
    this.viewerReturnOverlayVisible = false
    this.viewerReturnSnapshot = new ViewerReturnSnapshot()
    this.restoreImageViewerOrientation()
    this.closeAnimFinishMonotonic = this.getMonotonicNow()
    this.closeSessionActive = true
    this.sessionTrackedPointerId = -1
    this.sessionPreDispatchDownLogged = false
    this.sessionRootDownLogged = false
    this.sessionChildDownLogged = false
    this.sessionPanStartLogged = false
    this.sessionFirstPanUpdateLogged = false
    this.sessionScrollStartLogged = false
    this.sessionTouchTestCount = 0
    this.tapTrace('after-closeAnim')
    this.finishCloseImageViewer(shouldRestoreSearch)
    console.info('[ViewerReturnOverlay] session=' + this.closeSessionId.toString() +
      ' stage=closed dt=' +
      (this.getMonotonicNow() - this.viewerReturnOverlayStartedAt).toString() +
      ' path=' + entry.path)
  }

  private setImageChromeVisible(visible: boolean, animated: boolean = true): void {
    this.traceStateWrite('StateWrite:chrome.visible')
    this.imageChromeVisible = visible
    this.imageChromeAnimationToken += 1
    const token = this.imageChromeAnimationToken
    const targetOpacity = visible ? 1 : 0
    const targetTopOffset = visible ? 0 : -(this.topSafeInset() + 110)
    const targetBottomOffset = visible ? 0 : 130
    if (!animated) {
      this.traceStateWrite('StateWrite:chrome.opacity')
      this.imageChromeOpacity = targetOpacity
      this.traceStateWrite('StateWrite:chrome.offsets')
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
      this.traceStateWrite('StateWrite:chrome.opacity')
      this.imageChromeOpacity = targetOpacity
      this.traceStateWrite('StateWrite:chrome.offsets')
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
      this.viewerPrefetchCoordinator?.onUserInteraction()
      this.imageTouchActive = true
      this.imageTouchMoved = false
      if (point !== null) {
        this.imageTouchStartX = point.x
        this.imageTouchStartY = point.y
        this.imageTouchLastX = point.x
      }
      // ⚠️ 长按图片会触发系统的"识别文字"，文字层浮在图片上方；此时拖动选择光标
      // 会被图片的下拉关闭接走 → 图片跟着移动。
      // 系统没有"文字层已显示"的回调（aiButtonStatusChange /
      // imageAnalyzerVisibilityChange 只管右下角的 AI 按钮，实测长按不触发），
      // 所以这里自己判定：按住不动超过阈值即视为"正在识别文字"。
      this.imageAnalyzerActive = false
      this.armImageLongPressWatch()
      return
    }
    if (event.type === TouchType.Move && this.imageTouchActive && point !== null) {
      this.imageTouchLastX = point.x
      // Once the pull is running, the raw touch stream is the only place the
      // horizontal component still exists: the dismiss recognizer is
      // vertical-only and the Swiper has already lost this touch sequence.
      // TouchObject.x and translate() are both vp, so the delta maps 1:1.
      if (this.imageDismissDragging && !this.imageAnalyzerActive) {
        this.imageDismissOffsetX = point.x - this.imageDismissAnchorX
      }
      const movedX = Math.abs(point.x - this.imageTouchStartX)
      const movedY = Math.abs(point.y - this.imageTouchStartY)
      if (movedX > 8 || movedY > 8) {
        this.imageTouchMoved = true
        // 手指动过了 → 不是长按（但若已经判定为长按，说明文字层已浮出，保持）
        if (!this.imageAnalyzerActive) {
          this.cancelImageLongPressWatch()
        }
      }
      return
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.imageTouchActive = false
      this.imageTouchMoved = false
      // 只清定时器：若已经判定为"长按识别"，保持 imageAnalyzerActive 直到下一次
      // 在图片上按下（那时会重新判断），因为文字层此刻仍然浮着。
      this.cancelImageLongPressWatch()
      this.viewerPrefetchCoordinator?.onInteractionEnded()
    }
  }

  /** 长按判定的等待时长。系统长按识别约 500ms 触发，这里略早进入保护态。 */
  private armImageLongPressWatch(): void {
    this.cancelImageLongPressWatch()
    this.imageLongPressTimer = setTimeout((): void => {
      this.imageLongPressTimer = 0
      this.imageAnalyzerActive = true
      console.info('[UgreenImageAnalyzer] longPress -> analyzer active')
    }, IMAGE_LONG_PRESS_MS)
  }

  private cancelImageLongPressWatch(): void {
    if (this.imageLongPressTimer > 0) {
      clearTimeout(this.imageLongPressTimer)
      this.imageLongPressTimer = 0
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
    // ⚠️ imageAnalyzerActive = 用户正在识别文字，此时文字选择层浮在图片上方，
    // 若仍允许下拉关闭，拖动选择光标就会被它接走、导致图片跟着移动。
    return this.showImageViewer && !this.viewerClosePending &&
      index === this.viewerImageIndex && this.imageScale <= 1.001 &&
      !this.viewerTransitionActive && !this.viewerEntryTransitionActive &&
      !this.showImageMoreMenu && !this.showImageDetails && !this.showRenameDialog &&
      !this.imageAnalyzerActive
  }

  private resetImageDismissTransform(): void {
    this.imageDismissDragging = false
    this.imageDismissScale = 1
    this.imageDismissOffsetY = 0
    this.imageDismissOffsetX = 0
    this.imageDismissAnchorX = 0
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
    // imageDismissOffsetX/Y and imageDismissScale are deliberately left as they
    // are: the geometry transition flies the image from whatever 2-D pose the
    // finger left it in, so clearing either offset here would break the single
    // continuous motion into the thumbnail.
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
    // Take the horizontal origin from the finger's CURRENT position, not from
    // touch-down, so the pull starts from zero sideways instead of snapping to
    // however far the finger had already drifted before the vertical threshold
    // was crossed.
    this.imageDismissAnchorX = this.imageTouchLastX
    this.imageDismissOffsetX = 0
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
        this.viewerPrefetchCoordinator?.onInteractionEnded()
      }
    }, () => {
      // The horizontal offset MUST be cleared inside this same closure. It has
      // to travel back to the centre on the very same spring as the vertical
      // offset and the scale; clearing it outside the animation would snap the
      // image sideways on release.
      this.imageDismissOffsetY = 0
      this.imageDismissOffsetX = 0
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
    this.viewerPrefetchCoordinator?.onInteractionEnded()
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

  private viewerContainsPath(path: string): boolean {
    for (const entry of this.viewerImages) {
      if (entry.path === path) {
        return true
      }
    }
    return false
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
    this.viewerPrefetchCoordinator?.onViewerIndexChanged(index, this.viewerImages)
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
      this.viewerPrefetchCoordinator?.onCurrentOriginalRevealed(entry.path)
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
      if (!EXPERIMENT_A3_SINGLE_ORIGINAL_VIEWER) {
        this.enqueueViewerOriginal(adjacent, false, false)
      }
    }
  }

  private shouldAutoLoadViewerOriginal(): boolean {
    if (this.networkClass === 'offline' || this.offlineCacheMode || !NasConnection.shared().canRequest()) {
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
    if (EXPERIMENT_A3_SINGLE_ORIGINAL_VIEWER) {
      // A3: 仅当前项（以及正在滑动的目标 pending 项）允许保留 original
      const centers: number[] = [this.viewerImageIndex, this.viewerPendingIndex]
      for (const center of centers) {
        if (center >= 0 && center < this.viewerImages.length) {
          keepPaths[this.viewerImages[center].path] = true
        }
      }
    } else {
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
    }
    for (const key of Object.keys(this.viewerOriginalBitmaps)) {
      if (keepPaths[key] === true || this.viewerActiveLoadPaths[key] === true) {
        continue
      }
      if (EXPERIMENT_A3_SINGLE_ORIGINAL_VIEWER) {
        const oldRec = this.viewerOriginalBitmaps[key]
        if (oldRec !== undefined) {
          this.tryEnqueueViewerCleanupItem(oldRec, key, 'original')
          this.removeViewerBitmap(this.viewerOriginalBitmaps, key)
          this.viewerOriginalLocalPaths[key] = ''
          this.requestViewerCleanup()
        }
      } else {
        this.releaseViewerBitmap(this.viewerOriginalBitmaps, key).catch((): void => {})
      }
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
      if (!this.showImageViewer || generation !== this.viewerGeneration ||
        !this.viewerContainsPath(entry.path)) {
        return
      }
      const existingPath = CacheManager.findExisting(this.cacheDirectory, entry.name,
        this.originalCacheKey(entry))
      if (existingPath.length === 0) {
        return
      }
      this.markViewerOriginalLoading(entry.path)
      const record = await this.decodeViewerOriginalBitmap(entry, existingPath)
      if (record === null || !this.showImageViewer || generation !== this.viewerGeneration ||
        !this.viewerContainsPath(entry.path)) {
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
      if (generation !== this.viewerGeneration || !this.showImageViewer ||
        !this.viewerContainsPath(entry.path)) {
        return
      }
      const existingPath = CacheManager.findExisting(this.cacheDirectory, entry.name,
        this.originalCacheKey(entry))
      if (existingPath.length === 0) {
        return
      }
      this.markViewerOriginalLoading(entry.path)
      const record = await this.decodeViewerOriginalBitmap(entry, existingPath)
      if (record === null || generation !== this.viewerGeneration || !this.showImageViewer ||
        !this.viewerContainsPath(entry.path)) {
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
    if (typeof localPath !== 'string' || localPath.length === 0 || !CacheManager.exists(localPath)) {
      const cachedPath = this.repository.cachedThumbnailFast(entry, 'list')
      if (cachedPath.length > 0 && CacheManager.exists(cachedPath)) {
        localPath = cachedPath
        canonical = false
        this.previewLocalPaths[entry.path] = cachedPath
        this.previewLocalSignatures[entry.path] = this.previewSignature(entry)
        this.previewCanonicalPaths[entry.path] = false
      }
    }
    await this.primeViewerPreviewGeometryAtPath(entry, localPath, canonical)
  }

  private async primeViewerFrameWindow(entries: FileEntry[], center: number,
    radius: number): Promise<void> {
    // 当前这张必须准备好再返回（首帧要立刻正确）。
    const centerEntry = entries[center]
    if (centerEntry !== undefined) {
      await this.primeViewerPreviewGeometry(centerEntry)
      await this.primeViewerOriginalFrame(centerEntry)
      this.ensureViewerImageFrame(centerEntry, false)
    }
    // ⚠️ 相邻图原来也是串行 await（5 张 × 2 次 I/O = 10 次串行），
    // 实测首次打开要 228~270ms。这里改为并行，行为不变但快得多。
    const start = Math.max(0, center - radius)
    const end = Math.min(entries.length - 1, center + radius)
    const neighbours: Promise<void>[] = []
    for (let index = start; index <= end; index += 1) {
      if (index === center) {
        continue
      }
      const entry = entries[index]
      neighbours.push((async (): Promise<void> => {
        await this.primeViewerPreviewGeometry(entry)
        await this.primeViewerOriginalFrame(entry)
        this.ensureViewerImageFrame(entry, false)
      })())
    }
    await Promise.all(neighbours)
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
      if (!this.showImageViewer || generation !== this.viewerGeneration ||
        !this.viewerContainsPath(entry.path)) {
        return
      }
      if (existingPath.length > 0) {
        this.setViewerDownloadProgress(entry.path, 95, true, true)
      }
      const record = await this.decodeViewerOriginalBitmap(entry, localPath)
      if (record === null || !this.showImageViewer || generation !== this.viewerGeneration ||
        !this.viewerContainsPath(entry.path)) {
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
      this.viewerPrefetchCoordinator?.onCurrentOriginalRevealed(path)
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
    const oldWaterfall = this.waterfallBitmaps[path]
    let nextPreview: ViewerBitmapRecord | null = null
    let nextOriginal: ViewerBitmapRecord | null = null
    let nextWaterfall: ViewerBitmapRecord | null = null
    let committed = false
    try {
      nextPreview = await this.viewerBitmapStore.decode(previewPath, 'viewerPreview', nextRotation)
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
      if (visibleRecord === null || nextPreview === null ||
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
      if (nextWaterfall !== null) {
        this.installViewerBitmap(this.waterfallBitmaps, path, nextWaterfall)
        this.waterfallDecodedPaths[path] = true
        this.setWaterfallAspectRatio(entry, nextWaterfall.displayWidth,
          nextWaterfall.displayHeight, nextRotation)
      } else {
        if (oldWaterfall !== undefined) {
          this.removeViewerBitmap(this.waterfallBitmaps, path)
          this.waterfallDecodedPaths[path] = false
        }
        this.setWaterfallAspectRatio(entry, visibleRecord.displayWidth,
          visibleRecord.displayHeight, nextRotation)
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
        next.thumbnailDisplayWidth = nextPreview!.displayWidth
        next.thumbnailDisplayHeight = nextPreview!.displayHeight
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
    this.imageDetailsEntry = this.viewerOverlayEntry
    this.closeImageMoreMenu()
    this.showImageDetails = true
  }

  private closeImageDetails(): void {
    this.showImageDetails = false
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
    if (this.isBusy || !this.showImageViewer ||
      this.isDeletePending(entry.path, this.currentRootType)) {
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
    HapticFeedback.warn()
    const response = await this.showTrackedDialog({
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

    const parentPath = this.currentPath
    const rootType = this.currentRootType
    if (!this.beginDeleteOperation([entry], rootType)) {
      return
    }
    const originalViewerImages = this.viewerImages.slice()
    const originalViewerIndex = deletedIndex
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在移入云盘回收站…'
    let resolution: DeleteResolution = 'failed'
    try {
      this.applyOptimisticDelete([entry], parentPath, rootType)
      this.advanceViewerAfterOptimisticDelete(originalViewerImages, deletedIndex, preferredDirection, entry.path)
      // The visible list/viewer is already consistent. Do not keep the whole
      // page in the busy state while the NAS confirms the mutation.
      this.isBusy = false
      resolution = await this.resolveRemoteDelete(entry, parentPath, rootType)
    } catch (error) {
      this.isBusy = false
      this.reportError(error as Object, '删除失败')
    }

    this.finishDeleteOperation(entry, rootType, resolution === 'deleted')
    if (resolution === 'deleted') {
      this.removePersistedViewerRotation(entry).catch((): void => {})
      if (originalViewerImages.length > 1) {
        this.discardDeletedViewerState(entry.path)
      } else if (this.showImageViewer) {
        this.closeImageViewer()
      }
      this.statusText = '已移入回收站'
      HapticFeedback.success()
      this.showImmersiveToast('已移入云盘回收站')
      return
    }

    this.restoreOptimisticDelete([entry], parentPath, rootType)
    this.restoreViewerAfterDelete(entry, originalViewerImages, originalViewerIndex)
    if (resolution === 'unknown') {
      this.statusText = '无法确认删除结果，文件已恢复显示'
      this.showImmersiveToast('无法确认删除结果，已恢复显示')
    } else {
      this.statusText = '删除失败'
      this.showImmersiveToast('删除失败，文件已恢复显示')
    }
  }

  private async openAudioPlayer(entry: FileEntry, keepQueue: boolean = false): Promise<void> {
    if (this.isBusy || this.audioOpening || this.audioClosing || entry.isDirectory) { return }
    this.closeActionMenu()
    if (!await this.confirmMeteredDownload(entry)) { return }
    await this.ensurePlaybackState()
    if (this.isBusy || this.audioOpening || this.audioClosing) { return }
    const token = ++this.audioOpenToken
    const scope = this.repository.sessionIdentity()
    const valid = (): boolean => token === this.audioOpenToken && !this.audioEntryCloseRequested &&
      scope === this.repository.sessionIdentity()
    const opening = !this.showAudioPlayer
    this.isBusy = true
    this.audioOwnsBusy = true
    this.errorText = ''
    this.statusText = '正在准备音频…'
    if (!keepQueue || !this.showAudioPlayer) {
      const candidates = this.showSearch ? this.searchResults : this.entries
      this.audioQueue = candidates.filter((item: FileEntry): boolean => !item.isDirectory && this.isAudio(item))
      if (!this.audioQueue.some((item: FileEntry): boolean => item.path === entry.path)) { this.audioQueue = [entry] }
      this.audioQueueSource.replace(this.audioQueue)
      this.audioOriginSurface = this.currentThumbnailSurface()
      this.audioOriginKey = this.currentRootType.toString() + ':' + this.currentPath
      this.audioOriginScope = scope
    }
    this.audioEntry = entry
    this.audioTitle = AudioPlayerPolicy.title(entry.name)
    this.audioArtist = ''
    this.audioCover = this.previewUri(entry)
    this.audioLyrics = []
    // Switching tracks keeps this mounted cover's layout. ArkUI only reports
    // a new area when geometry changes, so retain the last measured frame.
    if (opening) {
      this.audioCoverRect = new AudioCoverRect()
      this.audioCoverVisibleRatio = 0
    }
    this.audioEntryCloseRequested = false
    this.audioOpening = opening
    this.audioTransitionCoverScale = opening ? 0.95 : 0
    this.audioPageOpacity = opening ? 0 : 1; this.audioCoverHidden = opening
    this.audioCurrentMs = 0; this.audioDurationMs = 0; this.audioPlaying = false
    this.showAudioPlayer = true
    // Downloading/preparing the audio proceeds in parallel with the visual
    // transition. Only the optional artwork hand-off waits for the flight.
    const entryTransition = opening ? this.animateOpenAudioPlayer(entry, token, scope) : Promise.resolve()
    try {
      await this.audioManager.release()
      await this.audioSession.close()
      const localPath = await this.ensureCachedFile(entry)
      if (!valid()) { return }
      this.audioLocalPath = localPath
      await this.audioManager.open(localPath,
        (timeMs: number): void => {
          if (!valid()) { return }
          this.audioCurrentMs = Math.max(0, timeMs)
          this.updateAudioSession()
        },
        (durationMs: number): void => {
          if (valid()) { this.audioDurationMs = Math.max(0, durationMs); this.updateAudioSession(true) }
        },
        (state: string): void => {
          if (!valid()) { return }
          this.audioPlaying = state === 'playing'
          if (state === 'completed') {
            this.audioCurrentMs = this.audioDurationMs
            setTimeout((): void => { if (valid() && !this.audioClosing) { this.skipAudio(1, true) } }, 0)
          }
          this.updateAudioSession(true)
        },
        (error: Object): void => {
          if (!valid()) { return }
          this.audioPlaying = false; this.updateAudioSession(true)
          this.reportError(error, '音频播放错误')
        })
      if (!valid()) { return }
      await this.audioSession.open(getContext(this) as common.UIAbilityContext, entry.path,
        this.audioTitle, this.audioArtist, this.audioCover, {
          play: () => this.setAudioPlaying(true), pause: () => this.setAudioPlaying(false),
          stop: () => this.closeAudioPlayer(), next: () => this.skipAudio(1),
          previous: () => this.skipAudio(-1), seek: (position: number) => this.seekAudio(position),
          loopMode: (mode: AudioPlayMode): void => { this.audioMode = mode; this.updateAudioSession(true) }
        })
      if (!valid()) { return }
      this.updateAudioSession(true)
      if (this.autoPlayOnOpen && (!this.playbackBackgroundActive || this.backgroundAudioPlayback)) {
        await this.audioManager.play()
      }
      if (!valid()) { return }
      this.statusText = ''
      // Artwork/tags are optional and settle after playback is usable. No
      // thumbnail or metadata decoder failure is allowed to stop an audio file.
      this.prepareAudioPresentation(entry, localPath, token, scope, entryTransition)
    } catch (error) {
      if (valid()) {
        await this.audioManager.release()
        this.finishCloseAudioPlayer(false)
        this.reportError(error as Object, '音频播放失败')
      }
    } finally {
      if (token === this.audioOpenToken && this.audioOwnsBusy) {
        this.audioOwnsBusy = false
        this.isBusy = false
      }
    }
  }

  private async prepareAudioPresentation(entry: FileEntry, localPath: string,
    token: number, scope: string, entryTransition: Promise<void> = Promise.resolve()): Promise<void> {
    const valid = (): boolean => token === this.audioOpenToken && !this.audioClosing &&
      !this.audioEntryCloseRequested && scope === this.repository.sessionIdentity() && this.audioEntry?.path === entry.path
    await entryTransition
    if (!valid()) { return }
    const info = await AudioMetadataReader.read(localPath)
    if (!valid()) { return }
    if (info.title.length > 0) { this.audioTitle = info.title }
    this.audioArtist = info.artist
    try {
      const coverPath = await this.repository.prepareAudioThumbnail(entry, localPath,
        this.thumbnailDirectory, this.thumbnailCacheLimitBytes)
      if (!valid()) { return }
      if (coverPath.length > 0) {
        this.audioCover = fileUri.getUriFromPath(coverPath)
        this.setPreviewUri(entry, this.audioCover, coverPath)
      }
    } catch (_) {}
    if (!valid()) { return }
    await this.audioSession.setMetadata(this.audioTitle, this.audioArtist, info.album, this.audioCover)
    if (!valid()) { return }
    this.updateAudioSession(true)
    const lyric = AudioPlayerPolicy.lyricEntry(entry, this.showSearch ? this.searchResults : this.entries)
    if (lyric !== undefined) {
      try {
        const path = await this.ensureCachedFile(lyric)
        if (!valid() || (await fileIo.stat(path)).size > 256 * 1024) { return }
        const text = await fileIo.readText(path, { length: 256 * 1024 })
        if (valid()) { this.audioLyrics = AudioPlayerPolicy.parseLyrics(text) }
      } catch (_) {}
    }
  }

  private updateAudioSession(force: boolean = false): void {
    if (!this.showAudioPlayer || this.audioClosing) { return }
    const now = Date.now()
    if (!force && now - this.audioSessionUpdatedAt < 500) { return }
    this.audioSessionUpdatedAt = now
    this.audioSession.update(this.audioPlaying, this.audioCurrentMs, this.audioDurationMs, this.backgroundAudioPlayback,
      this.audioMode)
  }

  private audioPageBusy(): boolean {
    // Short play/pause requests only serialize commands. Do not propagate
    // them into every Button.enabled state and flash the disabled styling.
    return this.isBusy || this.audioOpening || this.audioClosing
  }

  private async setAudioPlaying(playing: boolean): Promise<void> {
    if (this.audioEntry === null || this.audioPageBusy() || this.audioControlPending) { return }
    if (playing && this.playbackBackgroundActive && !this.backgroundAudioPlayback) { return }
    const token = this.audioOpenToken
    this.audioControlPending = true
    try {
      if (playing) { await this.audioManager.play() } else { await this.audioManager.pause() }
      if (token !== this.audioOpenToken) { return }
      this.audioPlaying = playing
      this.updateAudioSession(true)
    } catch (error) {
      if (token === this.audioOpenToken) { this.reportError(error as Object, '音频操作失败') }
    } finally {
      if (token === this.audioOpenToken) { this.audioControlPending = false }
    }
  }

  private cycleAudioMode(): void {
    this.audioMode = this.audioMode === 'order' ? 'repeat' : (this.audioMode === 'repeat' ? 'shuffle' : 'order')
    this.updateAudioSession(true)
    this.showImmersiveToast(this.audioMode === 'order' ? '顺序循环' : (this.audioMode === 'repeat' ? '单曲循环' : '随机播放'))
  }

  private skipAudio(direction: number, completed: boolean = false): void {
    if (this.audioPageBusy() || this.audioControlPending || this.audioEntry === null) { return }
    const index = this.audioQueue.findIndex((item: FileEntry): boolean => item.path === this.audioEntry?.path)
    const next = AudioPlayerPolicy.nextIndex(this.audioQueue.length, index, direction, this.audioMode, completed)
    if (next >= 0) { this.openAudioPlayer(this.audioQueue[next], true) }
  }

  private openAudioQueue(): void {
    if (!this.audioOpening && !this.audioClosing) { this.showAudioQueue = true }
  }

  /**
   * Opens one AVPlayer surface for a video.  The transfer manager owns the
   * source selection, cache/download hand-off, and the playback manager owns
   * the MediaKit player and its native network buffer; the page only
   * coordinates their lifetime and renders a poster until the first real
   * video frame arrives.
   */
  private async openVideoPlayer(entry: FileEntry, continuationPosition: number = -1,
    continuationPlaying: boolean = true, continuationValid: (() => boolean) | null = null): Promise<void> {
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
    const openingSurface = this.currentThumbnailSurface()
    this.videoOpeningPath = entry.path
    this.videoPosterPath = entry.path
    this.videoPosterUri = this.previewUri(entry)
    this.videoPosterFixedOrientation = openingSurface === 'none'
      ? ImageRotateOrientation.AUTO : this.fileImageSourceOrientation(entry, openingSurface)
    await this.ensurePlaybackState()
    if (continuationValid !== null && !continuationValid()) { return }

    const playerAlreadyVisible = this.showVideoPlayer && this.videoEntry !== null
    this.cancelVideoGestures(false)
    this.clearVideoChromeTimer()
    this.videoRatePanel = false
    this.videoSystemVolume = undefined
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
      if (continuationValid !== null && !continuationValid()) { throw new Error('Continuation cancelled') }
      const position = continuationPosition >= 0 ? continuationPosition :
        await this.videoTransferManager.playbackPosition(entry)
      if (this.videoPosterUri.length === 0) {
        this.videoPosterUri = this.previewUri(entry)
      }
      this.videoSourceHandle = handle
      this.videoSourceKey = handle.sourceKey
      this.videoLocalPath = handle.localPath
      this.videoEntry = entry
      this.videoOverlayClosing = false
      this.videoCloseRequested = false
      this.videoOverlayOpacity = 1
      // A SURFACE XComponent may expose its native layer before AVPlayer has
      // submitted a drawable buffer. Keep that layer hidden under the poster
      // until startRenderFrame and the compositor hand-off have both settled.
      this.videoSurfaceOpacity = 0
      this.videoPosterOpacity = 1
      this.videoFrameRevealScheduled = false
      this.clearVideoEntryTransition()
      this.videoDurationMs = 0
      this.videoCurrentMs = position
      this.videoTimelineReady = false
      this.videoFastPlaybackActive = false
      this.resetVideoRateState()
      this.videoSeekDragging = false
      this.videoSeekPending = position > 0
      this.videoSeekTargetMs = Math.max(0, position)
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
          if (this.videoSeekDragging || this.videoGestureSeeking || this.videoSeekPending) {
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
            // A saved end position is not resumable. AVPlayer starts that
            // case from zero, so expose zero rather than waiting for a seek
            // operation that the player deliberately does not issue.
            if (this.videoSeekPending && this.videoDurationMs > 0 &&
              this.videoSeekTargetMs >= this.videoDurationMs) {
              this.videoSeekPending = false
              this.videoSeekTargetMs = 0
              this.videoCurrentMs = 0
            }
            this.videoTimelineReady = this.videoDurationMs > 0 && !this.videoSeekPending
            this.updateVideoMediaSession(true)
          }
        },
        onSeekDone: (requestedMs: number, actualMs: number): void => {
          if (token !== this.videoOpenToken || this.videoEntry === null ||
            this.videoEntry.path !== entry.path || !this.videoSeekPending ||
            Math.abs(requestedMs - this.videoSeekTargetMs) > 1) {
            return
          }
          this.videoSeekPending = false
          this.videoCurrentMs = this.videoDurationMs > 0
            ? Math.min(this.videoDurationMs, Math.max(0, actualMs)) : Math.max(0, actualMs)
          this.videoTimelineReady = this.videoDurationMs > 0
          ContinuationManager.shared().refresh()
          this.videoTransferManager.savePlaybackPosition(entry, this.videoCurrentMs)
            .catch((): void => {})
          this.updateVideoMediaSession(true)
        },
        onState: (state: media.AVPlayerState): void => {
          if (token !== this.videoOpenToken || this.videoEntry === null ||
            this.videoEntry.path !== entry.path) {
            return
          }
          if (state === 'playing') {
            this.videoPlaying = true
          } else if (state === 'paused' || state === 'completed' ||
            state === 'stopped' || state === 'released' || state === 'error') {
            this.videoPlaying = false
            this.cancelVideoGestures()
          }
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
            this.revealVideoSurfaceIfReady(entry)
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
      }, continuationPosition >= 0 ? continuationPlaying : this.autoPlayOnOpen)
      if (continuationValid !== null && !continuationValid()) { throw new Error('Continuation cancelled') }
      if (token !== this.videoOpenToken) {
        return
      }
      if (playerAlreadyVisible) {
        this.videoChromeVisible = true
        this.showVideoPlayer = true
      } else {
        const useGeometryTransition = continuationPosition < 0 && this.startVideoEntryTransition(entry)
        this.videoChromeVisible = false
        this.videoOverlayOpacity = useGeometryTransition ? 1 : 0
        if (useGeometryTransition) {
          await this.nextRenderFrame()
          await new Promise<void>((resolve: () => void): void => {
            this.getUIContext().animateTo({
              duration: VIDEO_GEOMETRY_TRANSITION_DURATION,
              curve: Curve.FastOutSlowIn,
              onFinish: resolve
            }, (): void => {
              this.showVideoPlayer = true
              this.videoChromeVisible = true
            })
          })
          await this.nextRenderFrame()
          this.clearVideoEntryTransition()
        } else {
          this.showVideoPlayer = true
          await this.nextRenderFrame()
          await new Promise<void>((resolve: () => void): void => {
            this.getUIContext().animateTo({
              duration: VIDEO_FALLBACK_TRANSITION_DURATION,
              curve: Curve.EaseOut,
              onFinish: resolve
            }, (): void => {
              this.videoOverlayOpacity = 1
              this.videoChromeVisible = true
            })
          })
        }
      }
      if (continuationValid !== null && !continuationValid()) { throw new Error('Continuation cancelled') }
      this.revealVideoSurfaceIfReady(entry)
      this.videoOpeningPath = ''
      if (this.videoCloseRequested) {
        this.videoCloseRequested = false
        this.closeVideoPlayer(true)
        return
      }
      this.enableVideoPlayerAutoRotation()
      this.observeVideoVolume()
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
        this.videoOverlayClosing = false
        this.videoCloseRequested = false
        this.videoChromeVisible = true
        this.videoOverlayOpacity = 1
        this.videoSurfaceOpacity = 0
        this.videoPosterOpacity = 1
        this.videoPosterPath = ''
        this.videoPosterUri = ''
        this.videoPosterFixedOrientation = ImageRotateOrientation.AUTO
        this.videoFrameRevealScheduled = false
        this.videoOpeningPath = ''
        this.clearVideoEntryTransition()
        this.videoPrepared = false
        this.videoFirstFrame = false
        this.videoTimelineReady = false
        this.videoFastPlaybackActive = false
        this.resetVideoRateState()
        this.videoSeekDragging = false
        this.videoSeekPending = false
        this.videoSeekTargetMs = 0
        this.videoPlaying = false
        this.videoCasting = false
        this.videoCastPreparing = false
        this.destroyVideoPipController()
        this.syncVideoBackgroundTask()
        this.videoMediaSession.close().catch((): void => {})
        if (continuationValid !== null && !continuationValid()) {
          await this.videoTransferManager.releaseSource(entry)
          this.statusText = ''
        } else {
        this.reportError(error as Object, '视频播放失败')
        this.statusText = '视频播放失败'
        }
      }
    } finally {
      if (token === this.videoOpenToken) {
        this.isBusy = false
        this.scheduleVideoChromeHide()
      }
    }
  }

  private videoMediaSessionSnapshot(): VideoMediaPlaybackSnapshot {
    return {
      playbackRate: this.videoCasting ? 1 : this.videoPlaybackRate,
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
    if (this.videoViewportWidthVp !== widthVp || this.videoViewportHeightVp !== heightVp) {
      this.cancelVideoGestures()
      this.videoRatePanel = false
    }
    this.videoViewportWidthVp = widthVp
    this.videoViewportHeightVp = heightVp
    this.videoLandscape = widthVp > heightVp
    this.updateVideoSurfaceRect()
    this.scheduleVideoChromeHide()
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

  private revealVideoSurfaceIfReady(entry: FileEntry): void {
    if (!this.showVideoPlayer || this.videoOverlayClosing ||
      this.videoEntryTransitionActive || !this.videoFirstFrame ||
      this.videoEntry === null || this.videoEntry.path !== entry.path ||
      this.videoFrameRevealScheduled) {
      return
    }
    const token = this.videoOpenToken
    this.videoFrameRevealScheduled = true
    // startRenderFrame means decoding has entered rendering, while the native
    // Surface may still reach the compositor one or two frames later. Keep it
    // hidden first, enable it under the opaque poster, and only fade the poster
    // after that layer has survived one submitted frame.
    this.postRenderFrame((): void => {
      this.postRenderFrame((): void => {
        if (token !== this.videoOpenToken || !this.showVideoPlayer ||
          this.videoOverlayClosing || this.videoEntryTransitionActive ||
          this.videoEntry === null || this.videoEntry.path !== entry.path) {
          this.videoFrameRevealScheduled = false
          return
        }
        this.videoSurfaceOpacity = 1
        this.postRenderFrame((): void => {
          this.videoFrameRevealScheduled = false
          if (token !== this.videoOpenToken || !this.showVideoPlayer ||
            this.videoOverlayClosing || this.videoEntryTransitionActive ||
            this.videoEntry === null || this.videoEntry.path !== entry.path) {
            return
          }
          if (this.videoPosterOpacity <= 0) {
            return
          }
          this.getUIContext().animateTo({
            duration: VIDEO_FRAME_CROSSFADE_DURATION,
            curve: Curve.EaseOut
          }, (): void => {
            if (token === this.videoOpenToken && this.showVideoPlayer &&
              !this.videoOverlayClosing && this.videoEntry !== null &&
              this.videoEntry.path === entry.path) {
              this.videoPosterOpacity = 0
            }
          })
        })
      })
    })
  }

  private async beginCloseVideoPlayer(): Promise<void> {
    if (this.videoOverlayClosing || !this.showVideoPlayer ||
      this.videoEntry === null || this.videoPipBackgrounded) {
      return
    }
    const entry = this.videoEntry as FileEntry
    this.videoOverlayClosing = true
    this.videoCloseRequested = false
    this.videoPlaying = false
    this.videoPlaybackManager.pause().catch((): void => {})
    this.syncVideoBackgroundTask()
    this.updateVideoPipControlStatus()
    this.updateVideoMediaSession(true)

    if (this.videoPosterAvailable(entry) && this.videoPosterOpacity < 1) {
      await new Promise<void>((resolve: () => void): void => {
        this.getUIContext().animateTo({
          duration: VIDEO_FRAME_CROSSFADE_DURATION,
          curve: Curve.EaseIn,
          onFinish: resolve
        }, (): void => {
          this.videoChromeVisible = false
          this.videoPosterOpacity = 1
        })
      })
      this.videoSurfaceOpacity = 0
    } else {
      this.videoChromeVisible = false
      this.videoSurfaceOpacity = 0
      this.videoPosterOpacity = 1
    }
    if (this.videoEntry === null || this.videoEntry.path !== entry.path) {
      return
    }

    const useGeometryTransition = this.startVideoExitTransition(entry)
    if (useGeometryTransition) {
      await this.nextRenderFrame()
      await new Promise<void>((resolve: () => void): void => {
        this.getUIContext().animateTo({
          duration: VIDEO_GEOMETRY_TRANSITION_DURATION,
          curve: Curve.FastOutSlowIn,
          onFinish: resolve
        }, (): void => {
          this.showVideoPlayer = false
        })
      })
    } else {
      await new Promise<void>((resolve: () => void): void => {
        this.getUIContext().animateTo({
          duration: VIDEO_FALLBACK_TRANSITION_DURATION,
          curve: Curve.EaseIn,
          onFinish: resolve
        }, (): void => {
          this.videoOverlayOpacity = 0
        })
      })
      this.showVideoPlayer = false
    }
    await this.nextRenderFrame()
    if (this.videoEntry !== null && this.videoEntry.path === entry.path) {
      this.closeVideoPlayer()
    }
  }

  private closeVideoPlayer(animated: boolean = false): void {
    this.suspendVideoInteractions()
    if (animated) {
      if (this.videoOverlayClosing) {
        return
      }
      if (this.videoEntryTransitionActive && this.videoTransitionKind === 'entry') {
        this.videoCloseRequested = true
        this.videoChromeVisible = false
        return
      }
      if (this.showVideoPlayer && this.videoEntry !== null && !this.videoPipBackgrounded) {
        this.beginCloseVideoPlayer().catch((error: Error): void => {
          console.warn('[UgreenVideo] close transition failed: ' + JSON.stringify(error))
          this.closeVideoPlayer()
        })
        return
      }
    }
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
    this.videoOverlayClosing = false
    this.videoCloseRequested = false
    this.videoChromeVisible = true
    this.videoOverlayOpacity = 1
    this.videoSurfaceOpacity = 0
    this.videoPosterOpacity = 1
    this.videoPosterPath = ''
    this.videoPosterUri = ''
    this.videoPosterFixedOrientation = ImageRotateOrientation.AUTO
    this.videoFrameRevealScheduled = false
    this.videoOpeningPath = ''
    this.clearVideoEntryTransition()
    this.videoEntry = null
    this.videoSourceKey = ''
    this.videoLocalPath = ''
    this.videoDurationMs = 0
    this.videoCurrentMs = 0
    this.videoTimelineReady = false
    this.videoFastPlaybackActive = false
    this.resetVideoRateState()
    this.videoSeekDragging = false
    this.videoSeekPending = false
    this.videoSeekTargetMs = 0
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
    this.cancelVideoGestures()
    this.clearVideoChromeTimer()
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
          this.revealVideoChrome()
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

  private observeVideoVolume(): void {
    if (this.videoVolumeManager !== null) { return }
    try {
      const manager = audio.getAudioManager().getVolumeManager()
      manager.on('streamVolumeChange', audio.StreamUsage.STREAM_USAGE_MOVIE, this.videoVolumeChanged)
      this.videoVolumeManager = manager
    } catch (error) { console.warn('[UgreenVideo] observe volume failed: ' + String(error)) }
  }

  private suspendVideoInteractions(): void {
    this.cancelVideoGestures()
    this.videoControlsTouchActive = false
    this.clearVideoChromeTimer()
    this.videoRatePanel = false
    try { this.videoVolumeManager?.off('streamVolumeChange', this.videoVolumeChanged) } catch (error) {
      console.warn('[UgreenVideo] stop volume observation failed: ' + String(error))
    }
    this.videoVolumeManager = null
    this.videoSystemVolume = undefined
    this.videoBrightness.restore().catch((error: Object) => {
      console.warn('[UgreenVideo] restore brightness failed: ' + String(error))
    })
  }

  private handleVideoTouch(event: TouchEvent): void {
    if (event.type === TouchType.Cancel || event.touches.length > 1 ||
      !this.showVideoPlayer || !this.videoPrepared || this.isBusy || this.videoOverlayClosing ||
      this.videoEntryTransitionActive || this.videoPipBackgrounded || this.playbackBackgroundActive ||
      this.videoRatePanel || this.videoControlsTouchActive || this.videoOrientationChanging) {
      this.cancelVideoGestures()
      return
    }
    const point = event.touches[0] ?? event.changedTouches[0]
    if (!point) { return }
    if (event.type === TouchType.Down) {
      let volume = 50
      try {
        const manager = this.videoVolumeManager ?? audio.getAudioManager().getVolumeManager()
        const stream = audio.StreamUsage.STREAM_USAGE_MOVIE
        this.videoVolumeMin = manager.getMinVolumeByStream(stream)
        this.videoVolumeMax = manager.getMaxVolumeByStream(stream)
        volume = (manager.getVolumeByStream(stream) - this.videoVolumeMin) /
          Math.max(1, this.videoVolumeMax - this.videoVolumeMin) * 100
      } catch (error) { console.warn('[UgreenVideo] read volume failed: ' + String(error)) }
      let brightness = 50
      try {
        const current = this.videoPlayerWindow?.getWindowProperties().brightness ?? -1
        if (current >= 0) { brightness = current * 100 }
      } catch (error) { console.warn('[UgreenVideo] read brightness failed: ' + String(error)) }
      this.videoGestureStartMs = this.videoCurrentMs
      this.videoGestures.down(point.x, point.y, { width: this.videoViewportWidthVp,
        positionMs: this.videoCurrentMs, durationMs: this.videoTimelineReady ? this.videoDurationMs : 0,
        rate: this.videoPlaybackRate, playing: this.videoPlaying && !this.videoCasting && !this.videoRatePending &&
          !this.videoControlPending, brightness, volume })
    } else if (event.type === TouchType.Move) {
      this.videoGestures.move(point.x, point.y)
    } else if (event.type === TouchType.Up) {
      this.videoGestures.up()
    }
  }

  private previewVideoGesture(kind: string, value: number): void {
    this.videoGestureSeeking = kind === 'seek'
    if (kind === 'seek') {
      this.videoGesturePositionMs = value
      const seconds = Math.round((value - this.videoGestureStartMs) / 1000)
      this.videoGestureFeedback = (seconds >= 0 ? '+' : '') + seconds + ' 秒'
    } else if (kind === 'brightness') {
      this.videoGestureFeedback = '亮度 ' + Math.round(value) + '%'
    } else if (kind === 'speed') {
      this.videoFastPlaybackActive = true
      this.videoGestureFeedback = '2× 加速'
      HapticFeedback.longPress()
    } else {
      this.videoGestureFeedback = ''
      this.videoFastPlaybackActive = false
    }
  }

  private setVideoGestureBrightness(value: number): void {
    if (this.videoPlayerWindow === null) { return }
    this.videoBrightness.set(this.videoPlayerWindow, value).catch((error: Object) => {
      console.warn('[UgreenVideo] set brightness failed: ' + String(error))
    })
  }

  private cancelVideoGestures(restoreRate: boolean = true): void {
    this.videoGestures.cancel(restoreRate)
  }

  private handleVideoControlInteraction(active: boolean): void {
    this.videoControlsTouchActive = active
    if (active) { this.cancelVideoGestures(); this.clearVideoChromeTimer() }
    else { this.scheduleVideoChromeHide() }
  }

  private clearVideoChromeTimer(): void {
    if (this.videoChromeTimer >= 0) { clearTimeout(this.videoChromeTimer); this.videoChromeTimer = -1 }
  }

  private scheduleVideoChromeHide(): void {
    this.clearVideoChromeTimer()
    if (!this.showVideoPlayer || !this.videoChromeVisible || this.videoOverlayClosing ||
      this.videoEntryTransitionActive || this.videoPipBackgrounded || this.playbackBackgroundActive ||
      this.videoRatePanel || this.videoSeekDragging || this.videoGestureActive || this.videoControlsTouchActive || this.videoOrientationChanging ||
      this.videoRatePending || this.videoControlPending || this.isBusy) { return }
    const token = this.videoOpenToken
    this.videoChromeTimer = setTimeout(() => {
      this.videoChromeTimer = -1
      if (token !== this.videoOpenToken || !this.showVideoPlayer || this.videoOverlayClosing ||
        this.videoRatePanel || this.videoSeekDragging || this.videoGestureActive || this.videoControlsTouchActive || this.playbackBackgroundActive ||
        this.videoPipBackgrounded || this.videoOrientationChanging || this.videoRatePending || this.videoControlPending) { return }
      this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => { this.videoChromeVisible = false })
    }, 4000)
  }

  private revealVideoChrome(): void {
    if (!this.showVideoPlayer || this.videoOverlayClosing || this.videoPipBackgrounded) { return }
    this.videoChromeVisible = true
    this.scheduleVideoChromeHide()
  }

  private async handleVideoDoubleTap(): Promise<void> {
    if (this.isBusy || !this.videoPrepared || this.videoEntry === null ||
      this.videoControlPending) {
      return
    }
    await this.toggleVideo()
  }

  /**
   * A confirmed single tap changes only the player chrome.  It shares one
   * Exclusive gesture group with double tap, so playback double taps and
   * control/slider gestures keep their existing behavior.
   */
  private handleVideoSingleTap(): void {
    if (!this.showVideoPlayer || this.videoOverlayClosing ||
      this.videoPipBackgrounded || this.videoEntry === null) {
      return
    }
    if (this.videoRatePanel) { this.videoRatePanel = false; this.scheduleVideoChromeHide(); return }
    const visible = !this.videoChromeVisible
    this.getUIContext().animateTo({
      duration: visible ? 220 : 180,
      curve: Curve.FastOutSlowIn
    }, (): void => {
      this.videoChromeVisible = visible
    })
    if (visible) { this.scheduleVideoChromeHide() } else { this.clearVideoChromeTimer() }
  }

  private resetVideoRateState(): void {
    this.videoRateRequestToken++
    this.videoPreferredRate = 1
    this.videoPlaybackRate = 1
    this.videoRatePending = false
    this.videoRatePanel = false
  }

  private async setVideoPlaybackRate(rate: number, temporary: boolean = false): Promise<void> {
    if (!this.showVideoPlayer || !this.videoPrepared || this.videoCasting ||
      this.isBusy || !Number.isFinite(rate) || rate < 0.25 || rate > 4) { return }
    const token = this.videoOpenToken
    const request = ++this.videoRateRequestToken
    this.videoRatePending = true
    this.clearVideoChromeTimer()
    try {
      await this.videoPlaybackManager.setPlaybackRate(rate)
      if (token !== this.videoOpenToken || request !== this.videoRateRequestToken || this.videoCasting) { return }
      this.videoPlaybackRate = rate
      if (!temporary) { this.videoPreferredRate = rate }
      this.updateVideoMediaSession(true)
      console.info('[UgreenVideo] playback rate=' + rate)
    } catch (error) {
      if (token === this.videoOpenToken && request === this.videoRateRequestToken) {
        if (temporary && this.videoFastPlaybackActive) { this.cancelVideoGestures(false) }
        console.warn('[UgreenVideo] playback rate failed: ' + String(error))
        this.showImmersiveToast('倍速调整失败')
      }
    } finally {
      if (token === this.videoOpenToken && request === this.videoRateRequestToken) {
        this.videoRatePending = false
        this.scheduleVideoChromeHide()
      }
    }
  }

  private async toggleVideo(): Promise<void> {
    if (this.isBusy || !this.videoPrepared || this.videoEntry === null ||
      this.videoControlPending) {
      return
    }
    const token = this.videoOpenToken
    const casting = this.videoCasting
    const current = (): boolean => token === this.videoOpenToken && this.showVideoPlayer
    // Local and cast controls share command ownership and completion. Native
    // player state can be newer than the rendered playing flag at click time.
    const playerState = casting ? null : this.videoPlaybackManager.state()
    const shouldPause = playerState === 'playing' ||
      (playerState === null && this.videoPlaying)
    this.videoControlPending = true
    try {
      if (casting) {
        await this.videoMediaSession.sendCastControl({ command: shouldPause ? 'pause' : 'play' })
      } else if (shouldPause) {
        await this.videoPlaybackManager.pause()
      } else {
        await this.videoPlaybackManager.play()
      }
      if (!current() || casting !== this.videoCasting) { return }
      this.videoPlaying = !shouldPause
      this.syncVideoBackgroundTask()
      this.updateVideoPipControlStatus()
      this.updateVideoMediaSession(true)
    } catch (error) {
      if (current() && casting === this.videoCasting) {
        this.reportError(error as Object, '视频操作失败')
        this.statusText = casting ? '投播操作失败' : '视频操作失败'
      }
    } finally {
      // An old command must not change a newly opened video's state/guard.
      if (current()) { this.videoControlPending = false; this.scheduleVideoChromeHide() }
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
    this.videoSeekDragging = false
    this.videoSeekPending = true
    this.videoSeekTargetMs = timeMs
    if (this.videoCasting) {
      this.videoMediaSession.sendCastControl({ command: 'seek', parameter: timeMs })
        .catch((error: Error): void => {
          if (this.videoSeekTargetMs === timeMs) {
            this.videoSeekPending = false
          }
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
    if (this.showVideoPlayer) {
      this.handleVideoControlInteraction(state === AVCastPickerState.STATE_APPEARING)
    }
  }

  private async toggleVideoPip(): Promise<void> {
    this.videoRatePanel = false
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
    this.suspendVideoInteractions()
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
    this.setSelectedPaths([])
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
    this.updateTopTitle(origin.topTitle)
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
    this.videoRatePanel = false
    this.cancelVideoGestures()
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
      this.setVideoPlaybackRate(this.videoPreferredRate)
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
    this.setVideoPlaybackRate(this.videoPreferredRate)
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
    if (!this.videoSeekDragging) {
      const positionMs = Math.max(0, snapshot.positionMs)
      if (!this.videoSeekPending || Math.abs(positionMs - this.videoSeekTargetMs) <= 1500) {
        this.videoSeekPending = false
        this.videoCurrentMs = positionMs
        this.videoTimelineReady = this.videoDurationMs > 0
      }
    }
    this.syncVideoBackgroundTask()
    this.updateVideoPipControlStatus()
    this.updateVideoMediaSession(true)
  }

  private recordAudioCoverArea(area: Area): void {
    if (this.audioClosing) { return }
    const rect = new AudioCoverRect()
    rect.x = Number(area.globalPosition.x) - this.audioPageOriginX
    rect.y = Number(area.globalPosition.y) - this.audioPageOriginY
    rect.width = Number(area.width); rect.height = Number(area.height); rect.radius = 16
    this.audioCoverRect = rect
  }

  /** One cover owner from the mounted thumbnail to the measured player cover. */
  private async animateOpenAudioPlayer(entry: FileEntry, token: number, scope: string): Promise<void> {
    const valid = (): boolean => token === this.audioOpenToken && !this.audioClosing && this.showAudioPlayer &&
      scope === this.repository.sessionIdentity() && this.audioEntry?.path === entry.path
    const source = this.audioThumbnailFrames.get(entry.path)
    const sourceTop = this.showSearch ? this.topSafeInset() + 124 : this.fileContentTopInset()
    const hasSource = source !== undefined && AudioPlayerPolicy.returnTarget(source,
      this.audioThumbnailVisibility.get(entry.path) ?? 0, sourceTop,
      this.pageHeightVp - this.bottomSafeInset() - 8, this.pageWidthVp)
    // Copy the source before hiding it: its mounted placeholder may report a
    // different area while the transition is being prepared.
    const iconSize = this.audioOriginSurface === 'list' || this.audioOriginSurface === 'search' ? 32 : 48
    const start = source === undefined ? new AudioCoverRect() :
      AudioPlayerPolicy.thumbnailRect(source, this.audioCover.length > 0, iconSize)
    try {
      let previous = new AudioCoverRect()
      for (let attempt = 0; attempt < 4 && valid(); attempt++) {
        await this.nextRenderFrame()
        const current = this.audioCoverRect
        if (current.width > 0 && current.height > 0 && previous.width > 0 &&
          Math.abs(current.x - previous.x) < 0.5 && Math.abs(current.y - previous.y) < 0.5 &&
          Math.abs(current.width - previous.width) < 0.5 && Math.abs(current.height - previous.height) < 0.5) { break }
        previous = current
        if (current.width <= 0 || current.height <= 0) {
          await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 16) })
        }
      }
      if (!valid()) { return }
      const end = this.audioCoverRect
      const hasTarget = end.width > 0 && end.height > 0 && end.x >= -1 && end.y >= -1 &&
        end.y + end.height <= this.pageHeightVp + 1 &&
        end.x + end.width <= this.pageWidthVp + 1 &&
        [end.x, end.y, end.width, end.height].every((value: number): boolean => Number.isFinite(value))
      const flying = hasSource && hasTarget
      if (flying) {
        this.audioFlightSource = this.audioCover.length > 0 ? this.audioCover : this.fileIcon(entry)
        this.audioFlightBaseSize = Math.max(end.width, end.height, start.width, start.height, 1)
        this.audioFlightX = start.x - this.audioPageOriginX; this.audioFlightY = start.y - this.audioPageOriginY
        this.audioFlightWidth = start.width; this.audioFlightHeight = start.height
        this.audioFlightRadius = start.radius; this.audioFlightOpacity = 1
        this.audioReturnHiddenPath = entry.path
        this.notifyEntryChanged(entry.path, this.audioOriginSurface)
        this.audioFlightVisible = true
        await this.nextRenderFrame()
      } else {
        this.audioCoverHidden = false
      }
      if (!valid()) { return }
      const duration = flying ? IMAGE_GEOMETRY_TRANSITION_DURATION : IMAGE_FALLBACK_TRANSITION_DURATION
      await new Promise<void>((resolve: () => void): void => {
        let finished = false
        const finish = (): void => {
          if (finished) { return }
          finished = true; clearTimeout(timer)
          if (this.audioEntryTransitionResolve === finish) { this.audioEntryTransitionResolve = null }
          resolve()
        }
        const timer = setTimeout(finish, duration + 160)
        this.audioEntryTransitionResolve = finish
        this.getUIContext().animateTo({ duration: duration, curve: Curve.FastOutSlowIn, onFinish: finish }, (): void => {
          this.audioPageOpacity = 1
          if (flying) {
            // The live cover retains its paused scale during the flight. A
            // cached track may already be playing, without moving this target.
            this.audioFlightX = end.x + end.width * 0.025
            this.audioFlightY = end.y + end.height * 0.025
            this.audioFlightWidth = end.width * 0.95; this.audioFlightHeight = end.height * 0.95
            this.audioFlightRadius = end.radius * 0.95
          }
        })
      })
    } catch (_) {
      // Missing geometry or a discarded window must not strand an invisible page.
    } finally {
      if (token === this.audioOpenToken && this.showAudioPlayer && scope !== this.repository.sessionIdentity()) {
        this.finishCloseAudioPlayer(false)
      }
      if (valid()) {
        this.audioEntryTransitionResolve?.()
        this.audioEntryTransitionResolve = null
        const hidden = this.audioReturnHiddenPath
        this.audioReturnHiddenPath = ''
        this.audioCoverHidden = false; this.audioPageOpacity = 1; this.audioOpening = false
        if (!this.audioEntryCloseRequested) { this.audioTransitionCoverScale = 0 }
        this.audioFlightVisible = false; this.audioFlightSource = ''
        if (hidden.length > 0) { this.notifyEntryChanged(hidden, this.audioOriginSurface) }
        if (this.audioEntryCloseRequested) { void this.beginCloseAudioPlayer() }
      }
    }
  }

  private recordAudioThumbnailArea(entry: FileEntry, surface: ThumbnailSurfaceKind, area: Area): void {
    if (!this.thumbnailSurfaceIsCurrent(surface)) { return }
    const existing = this.audioThumbnailFrames.get(entry.path) ?? new AudioCoverRect()
    existing.x = Number(area.globalPosition.x)
    existing.y = Number(area.globalPosition.y)
    existing.width = Number(area.width); existing.height = Number(area.height)
    existing.radius = surface === 'grid' ? 0 : 6
    this.audioThumbnailFrames.set(entry.path, existing)
    if (this.audioThumbnailFrames.size > 256) {
      const oldest = this.audioThumbnailFrames.keys().next().value as string
      this.audioThumbnailFrames.delete(oldest); this.audioThumbnailVisibility.delete(oldest)
    }
  }

  private closeAudioPlayer(immediate: boolean = false): void {
    if (immediate) {
      this.audioOpenToken++
      this.finishCloseAudioPlayer(false)
      return
    }
    if (!this.showAudioPlayer || this.audioClosing) { return }
    if (this.audioOpening) {
      // Match the image viewer: retain an early Back request until the cover
      // hand-off, then reverse from the actual cover instead of its end value.
      this.audioEntryCloseRequested = true
      this.audioManager.release().catch(() => {})
      this.audioSession.close().catch(() => {})
      return
    }
    void this.beginCloseAudioPlayer()
  }

  private async beginCloseAudioPlayer(): Promise<void> {
    const entry = this.audioEntry
    if (entry === null || this.audioClosing) { return }
    const token = ++this.audioOpenToken
    this.audioEntryCloseRequested = false
    this.audioClosing = true
    this.showAudioQueue = false
    this.audioControlPending = false
    if (this.audioOwnsBusy) { this.isBusy = false; this.audioOwnsBusy = false }
    this.audioManager.release().catch(() => {})
    this.audioSession.close().catch(() => {})
    const matchingOrigin = (): boolean => this.audioOriginScope === this.repository.sessionIdentity() &&
      this.audioOriginSurface === this.currentThumbnailSurface() &&
      this.audioOriginKey === this.currentRootType.toString() + ':' + this.currentPath
    const isCurrent = (): boolean => token === this.audioOpenToken && this.audioClosing &&
      this.showAudioPlayer && this.audioEntry?.path === entry.path && matchingOrigin()
    let target: AudioCoverRect | undefined = undefined
    const targetTop = this.showSearch ? this.topSafeInset() + 124 : this.fileContentTopInset()
    const targetBottom = this.pageHeightVp - this.bottomSafeInset() - 8
    const sourceReady = (): boolean => {
      target = this.audioThumbnailFrames.get(entry.path)
      return target !== undefined && AudioPlayerPolicy.returnTarget(target,
        this.audioThumbnailVisibility.get(entry.path) ?? 0, targetTop, targetBottom, this.pageWidthVp)
    }
    const returnReady = await this.prepareMediaReturnSource(entry, isCurrent, sourceReady)
    if (token !== this.audioOpenToken) { return }
    const frame = this.audioCoverRect
    const hasFrame = (this.audioCoverVisibleRatio >= 0.999 || this.audioTransitionCoverScale > 0) &&
      frame.width > 0 && frame.height > 0 &&
      frame.x >= -1 && frame.x + frame.width <= this.pageWidthVp + 1 &&
      [frame.x, frame.y, frame.width, frame.height].every((value: number): boolean => Number.isFinite(value))
    const hasTarget = returnReady && isCurrent()
    const iconSize = this.audioOriginSurface === 'list' || this.audioOriginSurface === 'search' ? 32 : 48
    const landing = target === undefined ? new AudioCoverRect() :
      AudioPlayerPolicy.thumbnailRect(target, this.audioCover.length > 0, iconSize)
    this.audioFlightSource = this.audioCover.length > 0 ? this.audioCover : this.fileIcon(entry)
    this.audioFlightBaseSize = Math.max(frame.width, frame.height, landing.width, landing.height, 1)
    const coverScale = this.audioTransitionCoverScale > 0 ? this.audioTransitionCoverScale :
      (this.audioPlaying ? 1.05 : 0.95)
    this.audioFlightX = frame.x + frame.width * (1 - coverScale) / 2
    this.audioFlightY = frame.y + frame.height * (1 - coverScale) / 2
    this.audioFlightWidth = frame.width * coverScale; this.audioFlightHeight = frame.height * coverScale
    this.audioFlightRadius = frame.radius * coverScale; this.audioFlightOpacity = 1
    if (hasFrame && hasTarget) {
      this.audioReturnHiddenPath = entry.path
      this.notifyEntryChanged(entry.path, this.audioOriginSurface)
      this.audioCoverHidden = true
      this.audioFlightVisible = true
      await this.nextRenderFrame()
    }
    if (token !== this.audioOpenToken) { return }
    await new Promise<void>((resolve: () => void): void => {
      this.getUIContext().animateTo({ duration: hasFrame && hasTarget ? IMAGE_GEOMETRY_TRANSITION_DURATION :
        IMAGE_FALLBACK_TRANSITION_DURATION, curve: Curve.FastOutSlowIn, onFinish: resolve }, (): void => {
        this.audioPageOpacity = 0
        if (hasFrame && hasTarget && target !== undefined) {
          this.audioFlightX = landing.x - this.audioPageOriginX
          this.audioFlightY = landing.y - this.audioPageOriginY
          this.audioFlightWidth = landing.width; this.audioFlightHeight = landing.height
          this.audioFlightRadius = landing.radius
        }
      })
    })
    if (token !== this.audioOpenToken) { return }
    const restoreSearch = this.searchSession !== null && this.searchSession.returnMode === 'audio'
    this.finishCloseAudioPlayer(restoreSearch)
  }

  private finishCloseAudioPlayer(restoreSearch: boolean): void {
    this.audioEntryTransitionResolve?.()
    this.audioEntryTransitionResolve = null
    this.audioOpening = false; this.audioEntryCloseRequested = false
    this.audioTransitionCoverScale = 0
    const hidden = this.audioReturnHiddenPath
    this.audioReturnHiddenPath = ''
    if (hidden.length > 0) { this.notifyEntryChanged(hidden, this.audioOriginSurface) }
    this.audioFlightVisible = false
    this.audioFlightSource = ''
    this.showAudioPlayer = false; this.showAudioQueue = false
    this.audioClosing = false; this.audioCoverHidden = false; this.audioPageOpacity = 1
    this.audioEntry = null; this.audioLocalPath = ''; this.audioCover = ''; this.audioLyrics = []
    this.audioPlaying = false; this.audioCurrentMs = 0; this.audioDurationMs = 0
    this.audioControlPending = false
    if (this.audioOwnsBusy) { this.audioOwnsBusy = false; this.isBusy = false }
    this.audioManager.release().catch(() => {})
    this.audioSession.close().catch(() => {})
    if (restoreSearch) { this.restoreSearchSession() }
  }

  private async toggleAudio(): Promise<void> { await this.setAudioPlaying(!this.audioPlaying) }

  private seekAudio(value: number): void {
    if (!Number.isFinite(value) || this.audioDurationMs <= 0 || this.audioOpening || this.audioClosing || this.isBusy) { return }
    const timeMs = Math.min(this.audioDurationMs, Math.max(0, Math.floor(value)))
    this.audioCurrentMs = timeMs
    this.audioManager.seek(timeMs)
    this.updateAudioSession(true)
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
      // the resumable stream into the user system download directory.
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
    const response = await this.showTrackedDialog({
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
      HapticFeedback.success()
      this.showImmersiveToast('已保存到图库：' + entry.name)
    } catch (error) {
      this.reportError(error as Object, '保存到图库失败')
      this.statusText = '保存到图库失败'
    } finally {
      this.isBusy = false
    }
  }

  // ── 长按滑动多选 ────────────────────────────────────────────────
  // 三种手势要分清，靠的是 GestureGroup(GestureMode.Sequence)：
  //   ① 快速滑动（没长按到）→ 序列组不成立，Pan 根本不参与 → 列表正常滚动
  //   ② 长按不动松手        → 非多选弹菜单 / 多选无动作
  //   ③ 长按后拖动          → 长按成功后才轮到这个 Pan → 连续选中
  // 所以千万别在列表上挂裸 PanGesture 或裸 onTouch，那会直接抢走滚动。
  private rowHitAreas: Map<string, RowHitArea> = new Map<string, RowHitArea>()
  private rowHitDirectoryKey: string = ''
  private dragSelectionActive: boolean = false
  private dragSelectionPanActive: boolean = false
  private dragSurface: string = ''
  private lastHitIndex: number = -1
  private fileScrollViewport: BottomBarTouchRect = new BottomBarTouchRect()
  private dragSelectionPointerId: number = -1
  private dragSelectionX: number = 0
  private dragSelectionY: number = 0
  private dragSelectionScrollTimer: number = 0
  private dragSelectionScrollToken: number = 0
  private dragSelectionScrollRunning: boolean = false
  private dragSelectionScrollLastAt: number = 0
  private dragSelectionDeferredScrollStop: boolean = false

  /** 当前实际渲染的是哪种表面（和 FileContent 的分支保持一致）。 */
  private activeListSurface(): string {
    if (this.fileViewMode === 'grid') {
      return 'grid'
    }
    if (this.fileViewMode === 'waterfall' && this.currentDirectoryIsPhotoAlbum) {
      return 'waterfall'
    }
    return 'list'
  }

  private recordRowHitArea(entry: FileEntry, index: number, surface: string, area: Area): void {
    const position = area.globalPosition
    if (typeof position.x !== 'number' || typeof position.y !== 'number') {
      return
    }
    const directoryKey = this.currentRootType.toString() + ':' + this.currentPath + ':' + surface
    if (this.rowHitDirectoryKey !== directoryKey) {
      this.rowHitAreas.clear()
      this.rowHitDirectoryKey = directoryKey
    }
    const key = surface + ':' + entry.path
    // ⚠️ 就地更新：本回调在滑动期频率极高（真机实测 onAreaChange 可达上万次/秒），
    // 每次 new 一个 RowHitArea 会制造同量级的堆分配 → Young GC 反复触发 → 掉帧。
    // 只在首次建立记录时分配，之后只改字段。
    let record = this.rowHitAreas.get(key)
    if (record === undefined) {
      record = new RowHitArea()
      record.surface = surface
      this.rowHitAreas.set(key, record)
    }
    record.entry = entry
    record.index = index
    record.x = position.x as number
    record.y = position.y as number
    record.width = area.width as number
    record.height = area.height as number
  }

  private forgetRowHitArea(entry: FileEntry, surface: string): void {
    this.rowHitAreas.delete(surface + ':' + entry.path)
  }

  private dragSelectionEntries(): FileEntry[] {
    return this.dragSurface === 'waterfall' ? this.waterfallEntries : this.entries
  }

  // Long press arms a snapshot. Apply the inclusive XOR interval only when
  // Pan succeeds, so a stationary long press cannot accidentally select one.
  private beginDragSelection(entry: FileEntry, index: number): void {
    if (!this.selectionMode) {
      return
    }
    this.dragSurface = this.activeListSurface()
    const source = this.dragSelectionEntries()
    if (source[index] === undefined || source[index].path !== entry.path) {
      this.dragSurface = ''
      return
    }
    this.dragSelectionActive = true
    this.dragSelectionPanActive = false
    this.lastHitIndex = -1
    this.fileSelection.beginRange(index, source.map((item: FileEntry): string => item.path))
    HapticFeedback.threshold()
    if (TAP_TRACE) {
      console.info('[FileSelection] drag-start surface=' + this.dragSurface +
        ' anchor=' + index.toString() + ' selected=' + this.selectedEntryCount.toString())
    }
  }

  private endDragSelection(): void {
    this.stopDragSelectionAutoScroll()
    const needsScrollStop = this.dragSelectionDeferredScrollStop
    this.dragSelectionDeferredScrollStop = false
    if (this.dragSelectionActive) {
      HapticFeedback.threshold()
    }
    this.dragSelectionActive = false
    this.dragSelectionPanActive = false
    this.dragSelectionPointerId = -1
    this.lastHitIndex = -1
    this.dragSurface = ''
    this.fileSelection.endRange()
    if (needsScrollStop) {
      this.onFileContentScrollStop()
    }
  }

  private extendDragSelection(event: GestureEvent): void {
    if (!this.dragSelectionActive || !this.selectionMode || this.dragSurface !== this.activeListSurface()) {
      return
    }
    const fingers = event.fingerList
    if (fingers === undefined || fingers.length === 0) {
      return
    }
    // Keep one window-coordinate source for the whole drag. A recycled or
    // moving item's Pan callbacks can report a different global position.
    // Root touch keeps following the original finger even after that item leaves.
    if (this.dragSelectionPointerId < 0) {
      this.dragSelectionPointerId = fingers[0].id
      this.dragSelectionX = fingers[0].globalX
      this.dragSelectionY = fingers[0].globalY
    }
    if (!fingers.some((finger: FingerInfo): boolean => finger.id === this.dragSelectionPointerId)) {
      return
    }
    this.dragSelectionPanActive = true
    this.moveDragSelectionTo(this.dragSelectionX, this.dragSelectionY)
  }

  private moveDragSelectionTo(x: number, y: number): void {
    this.dragSelectionX = x
    this.dragSelectionY = y
    this.updateDragSelectionHit()
    this.updateDragSelectionAutoScroll()
  }

  private updateDragSelectionHit(): void {
    const viewport = this.fileScrollViewport
    const top = this.dragSelectionBandTop()
    const bottom = this.dragSelectionBandBottom()
    const x = viewport.width > 0
      ? Math.max(viewport.x + 1, Math.min(viewport.x + viewport.width - 1, this.dragSelectionX))
      : this.dragSelectionX
    const y = bottom > top
      ? Math.max(top + 1, Math.min(bottom - 1, this.dragSelectionY)) : this.dragSelectionY
    if (this.dragSelectionScrollRunning) {
      try {
        const childIndex = this.dragSelectionScroller().getItemIndex(x - viewport.x, y - viewport.y)
        const index = childIndex - (this.dragSurface === 'list' ? 1 : 0)
        if (index >= 0 && index < this.dragSelectionEntries().length) {
          this.applyDragSelectionHit(index)
          return
        }
      } catch (_) {
        // A fresh item may still be mounting. Cached row geometry is the fallback.
      }
    }
    const source = this.dragSelectionEntries()
    let hit: RowHitArea | null = null
    let bestDistance = 5
    this.rowHitAreas.forEach((record: RowHitArea): void => {
      const current = source[record.index]
      if (record.surface !== this.dragSurface || record.entry === null || current === undefined ||
        current.path !== record.entry.path || record.width <= 0 || record.height <= 0) {
        return
      }
      const dx = Math.max(record.x - x, 0, x - record.x - record.width)
      const dy = Math.max(record.y - y, 0, y - record.y - record.height)
      const distance = dx * dx + dy * dy
      // Include only the tiny inter-cell gap; never jump to a distant row.
      if (distance < bestDistance) {
        bestDistance = distance
        hit = record
      }
    })
    if (hit === null) {
      return
    }
    const target = hit as RowHitArea
    this.applyDragSelectionHit(target.index)
  }

  private applyDragSelectionHit(index: number): void {
    if (index < 0 || index === this.lastHitIndex) {
      return
    }
    this.lastHitIndex = index
    this.applyDragRange(index)
  }

  private recordFileScrollViewport(surface: string, area: Area): void {
    if (surface !== this.activeListSurface() || typeof area.width !== 'number' ||
      typeof area.height !== 'number' || typeof area.globalPosition.x !== 'number' ||
      typeof area.globalPosition.y !== 'number') {
      return
    }
    this.fileScrollViewport.x = area.globalPosition.x
    this.fileScrollViewport.y = area.globalPosition.y
    this.fileScrollViewport.width = area.width
    this.fileScrollViewport.height = area.height
  }

  private dragSelectionBandTop(): number {
    return Math.max(this.fileScrollViewport.y, this.fileContentTopInset() + 18)
  }

  private dragSelectionBandBottom(): number {
    return this.fileScrollViewport.y + this.fileScrollViewport.height - this.floatingBarContentInset(0)
  }

  private dragSelectionScroller(): Scroller {
    return this.dragSurface === 'waterfall' ? this.waterfallScroller : this.fileListScroller
  }

  private onDragSelectionContentScrolled(): void {
    if (this.dragSelectionActive && this.dragSelectionPanActive) {
      this.updateDragSelectionHit()
    }
  }

  private updateDragSelectionAutoScroll(): void {
    const velocity = DragSelectionScrollPolicy.velocity(this.dragSelectionY,
      this.dragSelectionBandTop(), this.dragSelectionBandBottom())
    if (velocity === 0) {
      this.stopDragSelectionAutoScroll()
      return
    }
    if (this.dragSelectionScrollRunning || !this.dragSelectionPanActive) {
      return
    }
    this.dragSelectionScrollRunning = true
    this.dragSelectionScrollLastAt = this.getMonotonicNow()
    const token = ++this.dragSelectionScrollToken
    if (TAP_TRACE) {
      console.info('[FileSelection] auto-scroll start direction=' + (velocity < 0 ? 'up' : 'down'))
    }
    this.dragSelectionScrollTimer = setTimeout((): void => this.tickDragSelectionAutoScroll(token), 16)
  }

  private tickDragSelectionAutoScroll(token: number): void {
    this.dragSelectionScrollTimer = 0
    if (token !== this.dragSelectionScrollToken || !this.dragSelectionScrollRunning) {
      return
    }
    if (!this.dragSelectionActive || !this.dragSelectionPanActive || !this.selectionMode ||
      !this.fileContentTouchActive || this.screen !== 'files' || this.showSearch ||
      this.dragSurface !== this.activeListSurface()) {
      this.stopDragSelectionAutoScroll()
      return
    }
    const velocity = DragSelectionScrollPolicy.velocity(this.dragSelectionY,
      this.dragSelectionBandTop(), this.dragSelectionBandBottom())
    const now = this.getMonotonicNow()
    const delta = DragSelectionScrollPolicy.step(velocity, now - this.dragSelectionScrollLastAt)
    this.dragSelectionScrollLastAt = now
    try {
      const scroller = this.dragSelectionScroller()
      const offset = scroller.currentOffset().yOffset
      if (velocity === 0 || (velocity < 0 && offset <= 0) || (velocity > 0 && scroller.isAtEnd())) {
        this.stopDragSelectionAutoScroll()
        return
      }
      scroller.scrollBy(0, velocity < 0 ? Math.max(-offset, delta) : delta)
      this.noteUserInteraction()
      this.updateDragSelectionHit()
    } catch (_) {
      this.stopDragSelectionAutoScroll()
      return
    }
    if (token === this.dragSelectionScrollToken && this.dragSelectionScrollRunning) {
      this.dragSelectionScrollTimer = setTimeout((): void => this.tickDragSelectionAutoScroll(token), 16)
    }
  }

  private stopDragSelectionAutoScroll(): void {
    const wasRunning = this.dragSelectionScrollRunning
    this.dragSelectionScrollRunning = false
    this.dragSelectionScrollToken += 1
    if (this.dragSelectionScrollTimer !== 0) {
      clearTimeout(this.dragSelectionScrollTimer)
      this.dragSelectionScrollTimer = 0
    }
    if (wasRunning && TAP_TRACE) {
      console.info('[FileSelection] auto-scroll stop')
    }
  }

  private cancelDragSelectionGesture(): void {
    // A lazy item can be recycled while its original finger remains down.
    // The persistent page touch chain finishes that drag on Up/Cancel.
    if (this.dragSelectionPanActive && this.fileContentTouchActive) {
      return
    }
    this.endDragSelection()
  }

  private handleDragSelectionTouch(event: TouchEvent): void {
    if (!this.selectionMode && !this.dragSelectionActive) {
      return
    }
    if (event.type === TouchType.Cancel) {
      this.endDragSelection()
      return
    }
    const points = event.changedTouches.length > 0 ? event.changedTouches : event.touches
    if (event.type === TouchType.Down && this.dragSelectionPointerId < 0 && points.length > 0) {
      this.dragSelectionPointerId = points[0].id
    }
    const point = points.find((item: TouchObject): boolean => item.id === this.dragSelectionPointerId)
    if (point === undefined) {
      return
    }
    this.dragSelectionX = point.windowX
    this.dragSelectionY = point.windowY
    if (this.dragSelectionPanActive && (event.type === TouchType.Move || event.type === TouchType.Up)) {
      this.moveDragSelectionTo(point.windowX, point.windowY)
    }
    if (event.type === TouchType.Up) {
      this.endDragSelection()
    }
  }

  private applyDragRange(targetIndex: number): void {
    if (!this.fileSelection.extendRange(targetIndex)) {
      return
    }
    this.publishFileSelection()
    if (TAP_TRACE) {
      console.info('[FileSelection] range end=' + targetIndex.toString() +
        ' selected=' + this.selectedEntryCount.toString())
    }
  }



  private floatingImportRect: BottomBarTouchRect = new BottomBarTouchRect()

  private updateFloatingImportRect(area: Area): void {
    const pos = area.globalPosition
    if (typeof pos.x === 'number' && typeof pos.y === 'number' &&
      typeof area.width === 'number' && typeof area.height === 'number' &&
      area.width > 0 && area.height > 0) {
      this.floatingImportRect.x = pos.x as number
      this.floatingImportRect.y = pos.y as number
      this.floatingImportRect.width = area.width as number
      this.floatingImportRect.height = area.height as number
    }
  }

  private isInsideFloatingImportControl(windowX: number, windowY: number): boolean {
    if (!this.shouldShowFloatingImportControl() || this.parentOverlayOwnsInteraction()) {
      return false
    }
    const rect = this.floatingImportRect
    if (rect.width <= 0 || rect.height <= 0) {
      return false
    }
    return windowX >= rect.x && windowX <= rect.x + rect.width &&
      windowY >= rect.y && windowY <= rect.y + rect.height
  }

  private bottomBarVisualHostRect: BottomBarTouchRect = new BottomBarTouchRect()
  private bottomBarInteractiveRects: Map<string, BottomBarTouchRect> = new Map<string, BottomBarTouchRect>()

  private updateBottomBarVisualHostRect(area: Area): void {
    const pos = area.globalPosition
    if (typeof pos.x === 'number' && typeof pos.y === 'number' &&
      typeof area.width === 'number' && typeof area.height === 'number' &&
      area.width > 0 && area.height > 0) {
      this.bottomBarVisualHostRect.x = pos.x as number
      this.bottomBarVisualHostRect.y = pos.y as number
      this.bottomBarVisualHostRect.width = area.width as number
      this.bottomBarVisualHostRect.height = area.height as number
    }
  }

  private updateBottomBarInteractiveRect(key: string, area: Area): void {
    const pos = area.globalPosition
    if (typeof pos.x === 'number' && typeof pos.y === 'number' &&
      typeof area.width === 'number' && typeof area.height === 'number' &&
      area.width > 0 && area.height > 0) {
      const rect = new BottomBarTouchRect()
      rect.x = pos.x as number
      rect.y = pos.y as number
      rect.width = area.width as number
      rect.height = area.height as number
      this.bottomBarInteractiveRects.set(key, rect)
    }
  }

  private isInsideRealBottomBarControl(windowX: number, windowY: number): boolean {
    const mode = this.bottomBarMode()
    const prefix = mode + ':'
    let inside = false
    this.bottomBarInteractiveRects.forEach((rect: BottomBarTouchRect, key: string): void => {
      if (inside || !key.startsWith(prefix)) {
        return
      }
      if (windowX >= rect.x && windowX <= rect.x + rect.width &&
        windowY >= rect.y && windowY <= rect.y + rect.height) {
        inside = true
      }
    })
    return inside
  }

  private isInsideBottomBarVisualHost(windowX: number, windowY: number): boolean {
    if (!this.shouldShowAnyBottomBar() || this.parentOverlayOwnsInteraction() ||
      this.bottomBarOffsetY > 20 || this.bottomBarOpacity < 0.1) {
      return false
    }
    const rect = this.bottomBarVisualHostRect
    if (rect.width <= 0 || rect.height <= 0) {
      return false
    }
    return windowX >= rect.x && windowX <= rect.x + rect.width &&
      windowY >= rect.y && windowY <= rect.y + rect.height
  }

  private slideItems: Map<string, SlideActionItem> = new Map<string, SlideActionItem>()
  private slidePressKey: string = ''

  private registerSlideItem(barId: string, key: string, area: Area, action: () => void): void {
    const position = area.globalPosition
    if (typeof position.x !== 'number' || typeof position.y !== 'number') {
      return
    }
    const item = new SlideActionItem()
    item.x = position.x as number
    item.y = position.y as number
    item.width = area.width as number
    item.height = area.height as number
    item.action = action
    this.slideItems.set(barId + ':' + key, item)
  }

  private hitSlideItem(barId: string, x: number, y: number): string {
    if (barId === 'ctxmenu' && (x < this.contextMenuScrollRect.x ||
      x > this.contextMenuScrollRect.x + this.contextMenuScrollRect.width ||
      y < this.contextMenuScrollRect.y || y > this.contextMenuScrollRect.y + this.contextMenuScrollRect.height)) {
      return ''
    }
    let found = ''
    const prefix = barId + ':'
    this.slideItems.forEach((item: SlideActionItem, key: string): void => {
      if (found.length > 0 || key.indexOf(prefix) !== 0) {
        return
      }
      if (x >= item.x && x <= item.x + item.width &&
        y >= item.y && y <= item.y + item.height) {
        found = key.substring(prefix.length)
      }
    })
    return found
  }

  // 挂在每个按钮上。松手落在哪个按钮上就执行哪个；若松手仍在按下的那个上，
  // 这里不处理——onClick 会正常触发，避免重复执行。
  private slideItemTouch(barId: string, selfKey: string, event: TouchEvent): void {
    const self = this.slideItems.get(barId + ':' + selfKey)
    const touches = event.touches
    if (self === undefined || touches.length === 0) {
      return
    }
    const pointX = self.x + touches[0].x
    const pointY = self.y + touches[0].y
    const hit = this.hitSlideItem(barId, pointX, pointY)
    if (event.type === TouchType.Down) {
      if (barId === 'ctxmenu') {
        this.contextMenuScrollMoved = false
        this.contextMenuTouchX = pointX
        this.contextMenuTouchY = pointY
      }
      this.slidePressKey = hit
      return
    }
    if (barId === 'ctxmenu' && this.contextMenuEntry !== null &&
      this.actionMenuNaturalHeight(this.contextMenuEntry) > this.actionMenuHeight(this.contextMenuEntry) + 1 &&
      (Math.abs(pointX - this.contextMenuTouchX) > 8 || Math.abs(pointY - this.contextMenuTouchY) > 8)) {
      this.contextMenuScrollMoved = true
      this.slidePressKey = ''
    }
    if (event.type !== TouchType.Up) {
      return
    }
    const pressed = this.slidePressKey
    this.slidePressKey = ''
    if (barId === 'ctxmenu' && this.contextMenuScrollMoved) {
      return
    }
    if (hit.length === 0 || hit === pressed || hit === selfKey) {
      return
    }
    const item = this.slideItems.get(barId + ':' + hit)
    if (item === undefined || item.action === null) {
      return
    }
    HapticFeedback.confirm()
    const run = item.action as () => void
    run()
  }

  private enterSelectionMode(): void {
    if (this.screen !== 'files' || this.isBusy) {
      return
    }
    this.closeActionMenu()
    this.showSelectionMoreMenu = false
    this.getUIContext().animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
      this.selectionMode = true
      this.setSelectedPaths([])
    })
  }

  private enterSelection(entry: FileEntry): void {
    this.closeActionMenu()
    this.showSelectionMoreMenu = false
    this.getUIContext().animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
      this.selectionMode = true
      const nextPaths = this.isSelected(entry) ? this.selectedPaths : [entry.path]
      this.setSelectedPaths(nextPaths)
    })
  }

  private toggleSelection(entry: FileEntry): void {
    this.fileSelection.toggle(entry.path)
    this.publishFileSelection()
  }

  private setSelectedPaths(paths: string[]): void {
    this.endDragSelection()
    this.fileSelection.replace(paths)
    this.publishFileSelection()
  }

  private publishFileSelection(): void {
    this.selectedEntriesCache = null
    this.selectedPaths = this.fileSelection.paths()
    this.selectedEntryCount = this.fileSelection.count()
    this.syncGestureShareRegistration()
  }

  private isSelected(entry: FileEntry): boolean {
    return this.fileSelection.has(entry.path)
  }

  private selectionTitle(): string {
    const count = this.selectedEntryCount
    return count === 0 ? '未选择' : '已选择 ' + count.toString() + ' 项'
  }

  private fileHeaderLeadingVisible(): boolean {
    return this.selectionMode || (this.fileTransitionHeader === null
      ? this.currentPath.length > 0 : this.fileTransitionHeader.hasBack)
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
    this.setSelectedPaths(nextPaths)
  }

  private selectedEntriesInCurrentDirectory(): FileEntry[] {
    // Keep the action controls subscribed, but filter at most once per change.
    const paths = this.selectedPaths
    if (paths.length === 0) {
      return []
    }
    if (this.selectedEntriesCache === null) {
      this.selectedEntriesCache = this.entries.filter((entry: FileEntry): boolean => this.isSelected(entry))
    }
    return this.selectedEntriesCache
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
      this.setSelectedPaths([])
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
    const response = await this.showTrackedDialog({
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
    const entries = this.selectedEntriesInCurrentDirectory().filter((entry: FileEntry): boolean =>
      !this.isDeletePending(entry.path, this.currentRootType))
    if (entries.length === 0 || this.isBusy) {
      return
    }
    this.closeSelectionMoreMenu()
    HapticFeedback.warn()
    const response = await this.showTrackedDialog({
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
    const parentPath = this.currentPath
    const rootType = this.currentRootType
    if (!this.beginDeleteOperation(entries, rootType)) {
      return
    }
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在移入云盘回收站…'
    let resolutions: DeleteResolution[] = []
    try {
      this.applyOptimisticDelete(entries, parentPath, rootType)
      this.exitSelectionMode()
      this.isBusy = false
      // Independent trash requests can run together. The list has already
      // been updated optimistically, so network latency no longer blocks it.
      resolutions = await Promise.all(entries.map(async (entry: FileEntry): Promise<DeleteResolution> =>
        await this.resolveRemoteDelete(entry, parentPath, rootType)))
    } catch (error) {
      this.isBusy = false
      this.reportError(error as Object, '删除失败')
      resolutions = entries.map((): DeleteResolution => 'failed')
    }

    const failedEntries: FileEntry[] = []
    let successCount = 0
    let unknownCount = 0
    for (let index = 0; index < entries.length; index += 1) {
      const resolution = resolutions[index] === undefined ? 'failed' : resolutions[index]
      this.finishDeleteOperation(entries[index], rootType, resolution === 'deleted')
      if (resolution === 'deleted') {
        successCount += 1
        this.removePersistedViewerRotation(entries[index]).catch((): void => {})
      } else {
        failedEntries.push(entries[index])
        if (resolution === 'unknown') {
          unknownCount += 1
        }
      }
    }
    if (failedEntries.length > 0) {
      this.restoreOptimisticDelete(failedEntries, parentPath, rootType)
    }
    if (failedEntries.length === 0) {
      this.statusText = '已移入回收站'
      HapticFeedback.success()
      this.showImmersiveToast('已移入云盘回收站')
    } else if (successCount > 0) {
      this.statusText = '已删除 ' + successCount.toString() + ' 项，' +
        '有 ' + failedEntries.length.toString() + ' 项未删除'
      this.showImmersiveToast(unknownCount > 0
        ? '部分删除状态无法确认，未确认项目已恢复'
        : '部分删除失败，未删除项目已恢复')
    } else if (unknownCount > 0) {
      this.statusText = '无法确认删除结果，项目已恢复显示'
      this.showImmersiveToast('无法确认删除结果，项目已恢复显示')
    } else {
      this.statusText = '删除失败'
      this.showImmersiveToast('删除失败，项目已恢复显示')
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
    this.resetTimelineInteraction()
    if (this.fileSortKey === 'time' && this.directoryTimeline.eligible()) {
      const endpoint = this.fileSortAscending
        ? this.directoryTimeline.earliestTime : this.directoryTimeline.latestTime
      this.timelineFocusTime = DirectoryTimelinePolicy.localDayStart(endpoint)
      // Replacing a lazy container can emit an intermediate visible-index
      // callback before its offset is reset. Keep the selected endpoint stable
      // until the next real list gesture.
      this.timelineFocusPinned = true
      this.timelineIgnoreScrollStartUntil = Date.now() + 180
    }
    // Re-apply the sort to the complete directory snapshot. Sorting only the
    // pages already reached by the list would make both order and timeline wrong.
    this.indexedDirectoryKey = ''
    this.indexedDirectoryContentSignature = ''
    this.replaceEntries(this.entries)
    this.resetFileListScroll()
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
    if (this.isBusy || this.isDeletePending(entry.path, this.currentRootType)) {
      return
    }
    this.closeActionMenu()
    HapticFeedback.warn()
    const response = await this.showTrackedDialog({
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
    const parentPath = this.currentPath
    const rootType = this.currentRootType
    if (!this.beginDeleteOperation([entry], rootType)) {
      return
    }
    this.isBusy = true
    this.errorText = ''
    this.statusText = '正在移入云盘回收站…'
    let resolution: DeleteResolution = 'failed'
    try {
      this.applyOptimisticDelete([entry], parentPath, rootType)
      this.isBusy = false
      resolution = await this.resolveRemoteDelete(entry, parentPath, rootType)
    } catch (error) {
      this.isBusy = false
      this.reportError(error as Object, '删除失败')
    }

    this.finishDeleteOperation(entry, rootType, resolution === 'deleted')
    if (resolution === 'deleted') {
      this.removePersistedViewerRotation(entry).catch((): void => {})
      this.statusText = '已移入回收站'
      HapticFeedback.success()
      this.showImmersiveToast('已移入云盘回收站')
      return
    }

    this.restoreOptimisticDelete([entry], parentPath, rootType)
    if (resolution === 'unknown') {
      this.statusText = '无法确认删除结果，文件已恢复显示'
      this.showImmersiveToast('无法确认删除结果，已恢复显示')
    } else {
      this.statusText = '删除失败'
      this.showImmersiveToast('删除失败，文件已恢复显示')
    }
    if (this.isBusy) {
      this.isBusy = false
    }
  }

  private beginDeleteOperation(entries: FileEntry[], rootType: number): boolean {
    for (const entry of entries) {
      if (this.isDeletePending(entry.path, rootType)) {
        return false
      }
    }
    for (const entry of entries) {
      this.pendingDeleteEntryPaths[this.directoryEntryKey(entry.path, rootType)] = true
      this.continuationPendingDeletes.add(this.directoryEntryKey(entry.path, rootType))
    }
    return true
  }

  private finishDeleteOperation(entry: FileEntry, rootType: number, deleted: boolean): void {
    const key = this.directoryEntryKey(entry.path, rootType)
    this.pendingDeleteEntryPaths[key] = false
    this.continuationPendingDeletes.delete(key)
    this.locallyDeletedEntryPaths[key] = deleted
    ContinuationManager.shared().refresh()
  }

  private isDeletePending(path: string, rootType: number): boolean {
    return this.pendingDeleteEntryPaths[this.directoryEntryKey(path, rootType)] === true
  }

  private async resolveRemoteDelete(entry: FileEntry, parentPath: string,
    rootType: number): Promise<DeleteResolution> {
    try {
      await this.repository.trash(entry, parentPath, rootType)
      return 'deleted'
    } catch (error) {
      const failure = error as Object
      // Deleting an already missing object has reached the desired final
      // state. Invalidate the parent so a stale cached row cannot return.
      if (this.isMissingRemoteEntryError(failure)) {
        this.repository.invalidateDirectory(parentPath, rootType)
        return 'deleted'
      }
      if (!this.isAmbiguousDeleteError(failure)) {
        return 'failed'
      }

      // A timeout or gateway error may happen after NAS has committed the
      // trash operation. Verify only this exceptional path; normal deletes do
      // not pay for a second directory scan.
      const present = await this.remoteEntryPresence(entry, parentPath, rootType)
      if (present === false) {
        this.repository.invalidateDirectory(parentPath, rootType)
        return 'deleted'
      }
      return present === null ? 'unknown' : 'failed'
    }
  }

  private isAmbiguousDeleteError(error: Object): boolean {
    if (!(error instanceof UgreenError)) {
      return true
    }
    return error.kind === UgreenErrorKind.NETWORK || error.status === 0 ||
      error.status === 408 || error.status === 429 || error.status >= 500 ||
      error.apiCode >= 500
  }

  private async remoteEntryPresence(entry: FileEntry, parentPath: string,
    rootType: number): Promise<boolean | null> {
    try {
      const remoteEntries = await this.repository.list(parentPath, rootType, true)
      for (const remoteEntry of remoteEntries) {
        if (remoteEntry.path === entry.path) {
          return true
        }
      }
      return false
    } catch (error) {
      console.warn('[UgreenDelete] unable to verify delete result: ' + JSON.stringify(error))
      return null
    }
  }

  private applyOptimisticDelete(entries: FileEntry[], parentPath: string, rootType: number): void {
    const paths: Record<string, boolean> = {}
    for (const entry of entries) {
      paths[entry.path] = true
    }
    const nextEntries = this.removeEntriesByPathSet(this.entries, paths)
    const removedCount = this.entries.length - nextEntries.length
    if (removedCount > 0) {
      this.replaceEntries(nextEntries, false, true)
      if (parentPath === this.currentPath && rootType === this.currentRootType) {
        const knownCount = this.directoryCounts[parentPath]
        if (typeof knownCount === 'number' && knownCount >= 0) {
          this.updateDirectoryCount(parentPath, Math.max(0, knownCount - removedCount))
        }
      }
    }
    if (parentPath.length === 0) {
      if (rootType === 4) {
        this.personalRoots = this.removeEntriesByPathSet(this.personalRoots, paths)
      } else if (rootType === 3) {
        this.sharedRoots = this.removeEntriesByPathSet(this.sharedRoots, paths)
      }
    }
    const nextSelectedPaths = this.selectedPaths.filter((path: string): boolean => paths[path] !== true)
    this.setSelectedPaths(nextSelectedPaths)
  }

  private restoreOptimisticDelete(entries: FileEntry[], parentPath: string, rootType: number): void {
    if (parentPath !== this.currentPath || rootType !== this.currentRootType) {
      return
    }
    const existing: Record<string, boolean> = {}
    for (const entry of this.entries) {
      existing[entry.path] = true
    }
    const restored = this.entries.slice()
    let restoredCount = 0
    for (const entry of entries) {
      if (existing[entry.path] === true) {
        continue
      }
      existing[entry.path] = true
      restored.push(entry)
      restoredCount += 1
    }
    if (restoredCount > 0) {
      this.replaceEntries(this.sortEntriesForDisplay(restored), false, true)
      if (parentPath.length > 0) {
        const knownCount = this.directoryCounts[parentPath]
        if (typeof knownCount === 'number' && knownCount >= 0) {
          this.updateDirectoryCount(parentPath, knownCount + restoredCount)
        }
      }
    }
    if (parentPath.length === 0) {
      if (rootType === 4) {
        this.personalRoots = this.restoreMissingEntries(this.personalRoots, entries)
      } else if (rootType === 3) {
        this.sharedRoots = this.restoreMissingEntries(this.sharedRoots, entries)
      }
    }
  }

  private removeEntriesByPathSet(entries: FileEntry[], paths: Record<string, boolean>): FileEntry[] {
    const result: FileEntry[] = []
    for (const entry of entries) {
      if (paths[entry.path] === true) {
        continue
      }
      result.push(entry)
    }
    return result
  }

  private restoreMissingEntries(existingEntries: FileEntry[], additions: FileEntry[]): FileEntry[] {
    const known: Record<string, boolean> = {}
    const result = existingEntries.slice()
    for (const entry of result) {
      known[entry.path] = true
    }
    for (const entry of additions) {
      if (known[entry.path] === true) {
        continue
      }
      known[entry.path] = true
      result.push(entry)
    }
    return this.sortEntriesForDisplay(result)
  }

  private advanceViewerAfterOptimisticDelete(originalImages: FileEntry[], deletedIndex: number,
    preferredDirection: number, deletedPath: string): void {
    const remainingImages: FileEntry[] = []
    for (const image of originalImages) {
      if (image.path !== deletedPath) {
        remainingImages.push(image)
      }
    }
    if (remainingImages.length === 0) {
      // Keep the last image mounted until the remote outcome is known. A
      // failed delete can then be rolled back without reopening the viewer.
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
    this.viewerLoadQueue = this.viewerLoadQueue.filter((item: FileEntry): boolean => item.path !== deletedPath)
    this.viewerLoadRequests[deletedPath] = false
    this.viewerManualLoadPaths[deletedPath] = false
    this.resetImageTransform()
    if (boundedIndex > deletedIndex) {
      this.viewerLastNavigationDirection = 1
    } else if (boundedIndex < deletedIndex) {
      this.viewerLastNavigationDirection = -1
    }
    this.ensureViewerImageFrame(remainingImages[boundedIndex])
    this.prefetchViewerImages(boundedIndex)
    this.prepareViewerReturnSource(remainingImages[boundedIndex]).catch((): void => {})
  }

  private restoreViewerAfterDelete(entry: FileEntry, originalImages: FileEntry[],
    originalIndex: number): void {
    if (!this.showImageViewer) {
      return
    }
    const currentPath = this.viewerImageEntry === null ? '' : this.viewerImageEntry.path
    let containsDeleted = false
    for (const image of this.viewerImages) {
      if (image.path === entry.path) {
        containsDeleted = true
        break
      }
    }
    if (!containsDeleted) {
      const insertIndex = Math.min(Math.max(0, originalIndex), this.viewerImages.length)
      const restored: FileEntry[] = []
      for (let index = 0; index <= this.viewerImages.length; index += 1) {
        if (index === insertIndex) {
          restored.push(entry)
        }
        if (index < this.viewerImages.length) {
          restored.push(this.viewerImages[index])
        }
      }
      this.replaceViewerImages(restored)
    }
    let targetPath = currentPath
    if (targetPath.length === 0) {
      targetPath = entry.path
    }
    const targetIndex = this.viewerImages.findIndex((image: FileEntry): boolean => image.path === targetPath)
    if (targetIndex >= 0) {
      this.viewerImageIndex = targetIndex
      this.viewerImageEntry = this.viewerImages[targetIndex]
      this.viewerHeaderTitle = this.viewerImages[targetIndex].name
      if (targetPath === entry.path) {
        this.ensureViewerImageFrame(entry)
        this.resetImageTransform()
      }
    } else if (originalImages.length > 0) {
      const fallbackIndex = Math.min(Math.max(0, originalIndex), this.viewerImages.length - 1)
      if (fallbackIndex >= 0) {
        this.viewerImageIndex = fallbackIndex
        this.viewerImageEntry = this.viewerImages[fallbackIndex]
        this.viewerHeaderTitle = this.viewerImages[fallbackIndex].name
      }
    }
  }

  private discardDeletedViewerState(path: string): void {
    const nextStates: Record<string, ImageVisualState> = {}
    for (const key of Object.keys(this.imageVisualStates)) {
      if (key !== path) {
        nextStates[key] = this.imageVisualStates[key]
      }
    }
    this.imageVisualStates = nextStates
    this.imageVisualEpoch += 1
    this.viewerLoadRequests[path] = false
    this.viewerManualLoadPaths[path] = false
    this.viewerProgressLastUpdateAt[path] = 0
    const previewAlias = this.viewerPreviewBitmapAliases[path] === true
    const preview = this.removeViewerBitmap(this.viewerPreviewBitmaps, path)
    const original = this.removeViewerBitmap(this.viewerOriginalBitmaps, path)
    this.viewerOriginalLocalPaths[path] = ''
    this.viewerPreviewBitmapAliases[path] = false
    this.postRenderFrame((): void => {
      if (preview !== null && !previewAlias) {
        this.viewerBitmapStore.release(preview).catch((): void => {})
      }
      if (original !== null) {
        this.viewerBitmapStore.release(original).catch((): void => {})
      }
    })
  }

  private async refreshCurrentDirectory(excludedPaths: string[] = []): Promise<void> {
    // A full index may have been fetched from the old directory snapshot and
    // deferred while the list was scrolling. It must not be allowed to apply
    // after a mutation refresh, otherwise a deleted row can reappear.
    this.directoryIndexRequestToken += 1
    this.pendingDirectoryIndexSnapshot = null
    this.timelineIndexing = false
    if (this.currentPath.length === 0) {
      this.repository.clearDirectoryCache()
      const root = await this.repository.getRootWithCache(true)
      this.clearConfirmedDeletedPaths(root.personal, excludedPaths, 4)
      this.clearConfirmedDeletedPaths(root.shared, excludedPaths, 3)
      this.personalRoots = this.filterDeletedEntries(root.personal, excludedPaths, 4)
      this.sharedRoots = this.filterDeletedEntries(root.shared, excludedPaths, 3)
      this.setCurrentPageState(1, false)
      this.replaceEntries(this.rootKind === 'personal' ? this.personalRoots : this.sharedRoots)
      this.resetPreviewState()
      return
    }
    const visiblePageIndex = Math.max(1, this.currentPageIndex)
    this.navigationRequestId += 1
    this.indexedDirectoryKey = ''
    this.indexedDirectoryContentSignature = ''
    this.repository.invalidateDirectory(this.currentPath, this.currentRootType)
    const refreshed = await this.loadVisibleDirectoryPages(this.currentPath, this.currentRootType,
      visiblePageIndex, true)
    this.clearConfirmedDeletedPaths(refreshed.entries, excludedPaths, this.currentRootType)
    const refreshedEntries = this.filterDeletedEntries(refreshed.entries, excludedPaths)
    this.setCurrentPageState(refreshed.pageIndex, refreshed.hasMore)
    this.replaceEntries(refreshedEntries)
    this.updateDirectoryCount(this.currentPath, refreshed.totalCount >= 0
      ? Math.max(0, refreshed.totalCount - (refreshed.entries.length - refreshedEntries.length))
      : refreshedEntries.length)
    this.resetPreviewState()
  }

  private directoryEntryKey(path: string, rootType: number = this.currentRootType): string {
    return rootType.toString() + ':' + path
  }

  private filterDeletedEntries(entries: FileEntry[], excludedPaths: string[],
    rootType: number = this.currentRootType): FileEntry[] {
    const excluded: Record<string, boolean> = {}
    for (const path of excludedPaths) {
      if (path.length > 0) {
        excluded[path] = true
      }
    }
    const result: FileEntry[] = []
    for (const entry of entries) {
      if (excluded[entry.path] === true ||
        this.locallyDeletedEntryPaths[this.directoryEntryKey(entry.path, rootType)] === true ||
        this.pendingDeleteEntryPaths[this.directoryEntryKey(entry.path, rootType)] === true) {
        continue
      }
      result.push(entry)
    }
    return result
  }

  private clearConfirmedDeletedPaths(entries: FileEntry[], paths: string[], rootType: number): void {
    for (const path of paths) {
      if (path.length === 0) {
        continue
      }
      let present = false
      for (const entry of entries) {
        if (entry.path === path) {
          present = true
          break
        }
      }
      if (!present) {
        this.locallyDeletedEntryPaths[rootType.toString() + ':' + path] = false
      }
    }
  }

  private isMissingRemoteEntryError(error: Object): boolean {
    if (error instanceof UgreenError) {
      if (error.kind === UgreenErrorKind.NOT_FOUND || error.status === 404 ||
        error.status === 410 || error.apiCode === 404 || error.apiCode === 410) {
        return true
      }
      const errorMessage = error.message.toLowerCase()
      return errorMessage.includes('not found') || errorMessage.includes('no such file') ||
        errorMessage.includes('does not exist') || errorMessage.includes('不存在') ||
        errorMessage.includes('找不到')
    }
    const message = String(error).toLowerCase()
    return message.includes('not found') || message.includes('no such file') ||
      message.includes('does not exist') || message.includes('不存在') ||
      message.includes('找不到')
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

  private waterfallEntrySignature(entry: FileEntry, rotationOverride?: number): string {
    const rotation = rotationOverride === undefined
      ? this.imageVisualState(entry.path).userRotation : rotationOverride
    return entry.modifiedTime.toString() + ':' + entry.size.toString() + ':' +
      entry.etag + ':' + entry.checksum + ':' + rotation.toString()
  }

  private previewUri(entry: FileEntry): string {
    const signature = this.previewSignature(entry)
    // 结果缓存优先：渲染路径上同一格子一帧内会问 2~3 次，命中即可省掉 NAPI。
    const cached = this.previewUriResultCache.get(entry.path)
    if (cached !== undefined) {
      const sep = cached.indexOf('\u0000')
      if (sep > 0 && cached.substring(0, sep) === signature) {
        return cached.substring(sep + 1)
      }
    }
    const resolved = this.resolvePreviewUri(entry, signature)
    this.rememberPreviewUri(entry.path, signature, resolved)
    return resolved
  }

  private rememberPreviewUri(path: string, signature: string, uri: string): void {
    // 空结果不缓存：下一次可能已经有缩略图了，缓存空会把"还没好"固化下来。
    if (path.length === 0 || uri.length === 0) {
      return
    }
    if (!this.previewUriResultCache.has(path)) {
      this.previewUriResultKeys.push(path)
    }
    this.previewUriResultCache.set(path, signature + '\u0000' + uri)
    while (this.previewUriResultKeys.length > 512) {
      const oldest = this.previewUriResultKeys.shift()
      if (oldest !== undefined) {
        this.previewUriResultCache.delete(oldest)
      }
    }
  }

  private resolvePreviewUri(entry: FileEntry, signature: string): string {
    const state = this.imageVisualState(entry.path)
    if (state.thumbnailUri.length > 0 && state.thumbnailSignature === signature) {
      return state.thumbnailUri
    }
    // Visual state is bounded independently from the URI LRU. Reconstruct a
    // recently retained URI without a synchronous stat or a new publish pass.
    const retainedPath = this.previewLocalPaths[entry.path]
    if (typeof retainedPath === 'string' && retainedPath.length > 0 &&
      this.previewLocalSignatures[entry.path] === signature) {
      return fileUri.getUriFromPath(retainedPath)
    }
    // The persistent thumbnail index is loaded before the directory is
    // rendered. Resolve it synchronously from memory so a recycled item can
    // use its local URI on the first render pass, including while scrolling.
    // This does not scan the directory or touch the filesystem.
    const cachedPath = this.repository.cachedThumbnailFast(entry, 'list')
    if (cachedPath.length > 0) {
      return fileUri.getUriFromPath(cachedPath)
    }
    return ''
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
    // Keep the enlarged video poster byte-for-byte stable from the source
    // thumbnail through first-frame hand-off. Replacing its URI with a newly
    // cached preview rebuilds the full-screen Image and produces one flash.
    const freezesCurrentVideoPoster = this.videoPosterPath === path &&
      this.videoPosterUri.length > 0 &&
      (this.videoOpeningPath === path || this.showVideoPlayer ||
        this.videoEntryTransitionActive || this.videoOverlayClosing)
    if (freezesCurrentVideoPoster) {
      return
    }
    // previewUri() 的结果缓存必须同步失效，否则会继续返回被替换掉的旧 URI
    // （尤其是旋转修正这类 signature 不变、而 URI 变了的更新）。
    this.previewUriResultCache.delete(path)
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
    const nextLocalSignatures: Record<string, string> = {}
    const nextCanonicalPaths: Record<string, boolean> = {}
    const signature = this.previewSignature(entry)
    for (const key of order) {
      if (key === path) {
        if (localPath.length > 0) {
          nextLocalPaths[key] = localPath
          nextLocalSignatures[key] = signature
        }
        if (canonical) {
          nextCanonicalPaths[key] = true
        }
      } else {
        const existingLocalPath = this.previewLocalPaths[key]
        if (typeof existingLocalPath === 'string' && existingLocalPath.length > 0) {
          nextLocalPaths[key] = existingLocalPath
          const existingSignature = this.previewLocalSignatures[key]
          if (typeof existingSignature === 'string' && existingSignature.length > 0) {
            nextLocalSignatures[key] = existingSignature
          }
        }
        if (this.previewCanonicalPaths[key] === true) {
          nextCanonicalPaths[key] = true
        }
      }
    }
    this.previewUriOrder = order
    this.previewLocalPaths = nextLocalPaths
    this.previewLocalSignatures = nextLocalSignatures
    this.previewCanonicalPaths = nextCanonicalPaths
    this.updateImageVisualState(path, (state: ImageVisualState): void => {
      if (state.thumbnailUri !== uri || state.thumbnailSignature !== signature) {
        state.thumbnailDecodedUri = ''
      }
      state.thumbnailUri = uri
      state.thumbnailSignature = signature
      state.thumbnailOrientation = canonical
        ? ImageRotateOrientation.UP : ImageRotateOrientation.AUTO
    }, false)
    for (const evictedPath of evictedPaths) {
      this.releaseFileThumbnailBitmap(evictedPath)
      this.updateImageVisualState(evictedPath, (state: ImageVisualState): void => {
        state.thumbnailUri = ''
        state.thumbnailSignature = ''
        if (state.thumbnailVisibleRatio <= 0) {
          state.transitionThumbnailUri = ''
        }
      }, false)
    }
    if (THUMB_PROBE) {
      hilog.info(IMAGE_VIEWER_HILOG_DOMAIN, 'ThumbProbe', `[1-setPreviewUri] path=${path}, epochMode=${USE_GLOBAL_BITMAP_EPOCH}`)
    }
    if (USE_GLOBAL_BITMAP_EPOCH) {
      this.scheduleImageVisualNotify()
    } else {
      this.notifyEntryChanged(path, this.fileViewMode)
    }
  }

  private replaceEntries(nextEntries: FileEntry[], appendWaterfall: boolean = false,
    alreadySorted: boolean = false): void {
    const isLocating = this.targetLocateEntryPath.length > 0
    const sortedEntries = alreadySorted ? nextEntries.slice() : this.sortEntriesForDisplay(nextEntries)
    if (this.sameFileEntryList(this.entries, sortedEntries)) {
      this.scheduleCurrentDirectoryIndex()
      return
    }
    if (isLocating) {
      this.tapTrace('replaceEntries start', 'count=' + sortedEntries.length.toString())
    }
    this.entries = sortedEntries
    this.endDragSelection()
    this.selectedEntriesCache = null
    this.currentDirectoryIsPhotoAlbum = this.isPhotoAlbumDirectory(this.entries)
    this.currentDirectoryIsAudioAlbum = this.isAudioAlbumDirectory(this.entries)
    // 这里只做「无图目录不能停在瀑布流」的兜底。默认视图的下发只在进/回目录时
    // （restore/settleDirectoryViewState）—— 绝不能放这里：replaceEntries 在加载、
    // 排序、刷新、分页追加时都会跑，在这里改模式会反复启停瀑布流管线、拖垮加载。
    if (!this.currentDirectoryIsPhotoAlbum && this.fileViewMode === 'waterfall') {
      this.stopWaterfallPipeline()
      this.fileViewMode = 'list'
      this.waterfallAnchor = null
    }
    if (!appendWaterfall) {
      this.imageTelemetry.reset()
      this.returnPerfSession.resetAll()
    }
    this.fileEntryDataSource.replace(this.entries)
    this.syncWaterfallEntries(this.entries, appendWaterfall)
    this.rebuildTimelineIndexes()
    this.refreshFileListImageRotations(this.entries)
    this.scheduleDirectoryVideoReconcile(this.entries)
    this.scheduleCurrentDirectoryIndex()
    if (isLocating) {
      this.tapTrace('replaceEntries end')
    }
  }

  private sameFileEntryList(left: FileEntry[], right: FileEntry[]): boolean {
    if (left.length !== right.length) {
      return false
    }
    for (let index = 0; index < left.length; index += 1) {
      const previous = left[index]
      const next = right[index]
      if (previous.path !== next.path || previous.name !== next.name ||
        previous.isDirectory !== next.isDirectory || previous.size !== next.size ||
        previous.modifiedTime !== next.modifiedTime || previous.createdTime !== next.createdTime ||
        previous.childCount !== next.childCount || previous.rootType !== next.rootType ||
        previous.intranetShareId !== next.intranetShareId ||
        previous.thumbnailUrl !== next.thumbnailUrl || previous.coverUrl !== next.coverUrl ||
        previous.mimeType !== next.mimeType || previous.etag !== next.etag ||
        previous.checksum !== next.checksum) {
        return false
      }
    }
    return true
  }

  private scheduleDirectoryVideoReconcile(entries: FileEntry[]): void {
    if (this.screen !== 'files' || this.showSearch) {
      return
    }
    const directoryKey = this.currentRootType.toString() + ':' + this.currentPath
    if (directoryKey !== this.videoReconcileDirectoryKey) {
      this.videoReconcileDirectoryKey = directoryKey
      this.videoReconciledEntries = {}
    }
    const pending: FileEntry[] = []
    for (const entry of entries) {
      if (entry.isDirectory || !this.isVideo(entry) ||
        this.videoReconciledEntries[entry.path] === true) {
        continue
      }
      this.videoReconciledEntries[entry.path] = true
      pending.push(entry)
    }
    if (pending.length === 0) {
      return
    }
    this.ensureVideoState().then((): Promise<void> =>
      this.videoTransferManager.reconcileDirectoryDownloads(pending)
    ).catch((error: Error): void => {
      for (const entry of pending) {
        this.videoReconciledEntries[entry.path] = false
      }
      console.warn('[UgreenVideo] directory download reconcile failed: ' +
        JSON.stringify(error))
    })
  }

  // 已经处理过的上传任务 id（避免每次任务列表 publish 都重复插入）
  private syncedUploadTaskIds: string[] = []

  /**
   * 导入（上传）完成一个文件，就把它【增量插入】当前目录列表。
   * 用的是 LazyForEach 的精准通知（onDataAdd）：
   *   - 不重拉目录、不 replace  → 已有条目不重建 → 不闪烁、不上下位移
   *   - 每完成一个插一个        → 需求要的「逐渐弹出新增文件」
   * 边界：
   *   - 只处理【刚变成 completed】的（用 id 去重，publish 会多次回调）
   *   - 同名跳过（skipped）不插：服务器上本来就有，列表里也已经有
   *   - 目标目录 ≠ 当前目录不插；不在文件页/正在搜索不插
   *   - 同一 path 已在列表里不重复插
   */
  private syncImportedUploads(tasks: UploadTaskRecord[]): void {
    const aliveIds: string[] = []
    for (const task of tasks) {
      if (this.syncedUploadTaskIds.indexOf(task.id) >= 0) {
        aliveIds.push(task.id)
        continue
      }
      if (task.status !== 'completed') {
        continue
      }
      aliveIds.push(task.id)
      if (task.skipped === true) {
        continue
      }
      if (this.screen !== 'files' || this.showSearch) {
        continue
      }
      if (task.destinationRoot.replace(/\/$/, '') !== this.currentPath.replace(/\/$/, '')) {
        continue
      }
      this.insertImportedEntry(this.importedFileEntry(task))
    }
    this.syncedUploadTaskIds = aliveIds
  }

  private importedFileEntry(task: UploadTaskRecord): FileEntry {
    const entry = new FileEntry()
    entry.name = task.name
    entry.path = task.remotePath
    entry.isDirectory = false
    entry.size = task.size
    // 任务创建时间约等于文件落盘时间；下一次目录索引刷新会被真实值覆盖。
    entry.modifiedTime = task.createdAt
    entry.createdTime = task.createdAt
    entry.rootType = this.currentRootType
    entry.mimeType = task.mimeType
    return entry
  }

  private insertImportedEntry(entry: FileEntry): void {
    if (entry.path.length === 0) {
      return
    }
    for (const item of this.entries) {
      if (item.path === entry.path) {
        return
      }
    }
    // 用工程自己的排序函数定位，避免出现第二套排序规则
    const next = this.sortEntriesForDisplay(this.entries.concat([entry]))
    let index = -1
    for (let i = 0; i < next.length; i++) {
      if (next[i].path === entry.path) {
        index = i
        break
      }
    }
    if (index < 0) {
      return
    }
    this.entries = next
    this.fileEntryDataSource.insertAt(index, entry)
    this.syncWaterfallEntries(this.entries, false)
    this.rebuildTimelineIndexes()
    this.scheduleDirectoryVideoReconcile([entry])
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
      if (item.path.length === 0 || existing[item.path] === true ||
        this.locallyDeletedEntryPaths[this.directoryEntryKey(item.path)] === true ||
        this.pendingDeleteEntryPaths[this.directoryEntryKey(item.path)] === true) {
        continue
      }
      existing[item.path] = true
      unique.push(item)
    }
    if (unique.length === 0) {
      return
    }
    const previousLength = this.entries.length
    const sorted = this.sortEntriesForDisplay(this.entries.concat(unique))
    let keepsExistingPrefix = sorted.length >= previousLength
    if (keepsExistingPrefix) {
      for (let index = 0; index < previousLength; index += 1) {
        if (sorted[index].path !== this.entries[index].path) {
          keepsExistingPrefix = false
          break
        }
      }
    }
    if (!keepsExistingPrefix) {
      this.replaceEntries(sorted, true, true)
      return
    }

    const appended = sorted.slice(previousLength)
    this.entries = sorted
    this.endDragSelection()
    this.selectedEntriesCache = null
    this.currentDirectoryIsPhotoAlbum = this.isPhotoAlbumDirectory(this.entries)
    this.currentDirectoryIsAudioAlbum = this.isAudioAlbumDirectory(this.entries)
    this.fileEntryDataSource.append(appended)
    this.syncWaterfallEntries(this.entries, true)
    this.rebuildTimelineIndexes()
    this.refreshFileListImageRotations(this.entries)
    this.scheduleDirectoryVideoReconcile(appended)
    this.scheduleCurrentDirectoryIndex()
  }

  private syncWaterfallEntries(entries: FileEntry[], appendOnly: boolean): void {
    const isLocating = this.targetLocateEntryPath.length > 0
    if (isLocating) {
      this.tapTrace('syncWaterfallEntries start', 'entries=' + entries.length.toString())
    }
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
        if (!this.sameWaterfallEntry(nextImages[index], previous[index])) {
          keepsPrefix = false
          break
        }
      }
      if (keepsPrefix && nextImages.length > previous.length) {
        this.waterfallEntries = nextImages
        this.waterfallDataSource.append(nextImages.slice(previous.length))
        if (isLocating) {
          this.tapTrace('syncWaterfallEntries end', 'images=' + this.waterfallEntries.length.toString())
        }
        return
      }
    }
    let unchanged = previous.length === nextImages.length
    if (unchanged) {
      for (let index = 0; index < previous.length; index++) {
        if (!this.sameWaterfallEntry(previous[index], nextImages[index])) {
          unchanged = false
          break
        }
      }
    }
    if (!unchanged) {
      // WaterFlow and its PixelMap cache are keyed by path, but a NAS refresh
      // can replace the file at the same path. Drop the complete waterfall
      // pipeline before replacing the data source so an old aspect ratio or
      // decoded bitmap cannot be attached to the new file.
      this.resetWaterfallDirectoryState()
      this.waterfallEntries = nextImages
      this.waterfallDataSource.replace(nextImages)
    }
    if (isLocating) {
      this.tapTrace('syncWaterfallEntries end', 'images=' + this.waterfallEntries.length.toString())
    }
  }

  private sameWaterfallEntry(left: FileEntry, right: FileEntry): boolean {
    return left.path === right.path && left.name === right.name &&
      left.isDirectory === right.isDirectory && left.size === right.size &&
      left.modifiedTime === right.modifiedTime && left.createdTime === right.createdTime &&
      left.childCount === right.childCount && left.rootType === right.rootType &&
      left.intranetShareId === right.intranetShareId &&
      left.thumbnailUrl === right.thumbnailUrl && left.coverUrl === right.coverUrl &&
      left.mimeType === right.mimeType && left.etag === right.etag &&
      left.checksum === right.checksum
  }

  /**
   * 这个目录算不算「图片目录」——用【图片目录的呈现方式】（默认视图、网格/瀑布流那套）。
   *
   * 规则（用户定）：目录里【全部】都是图片或视频才算图片目录（且至少有一条）；
   * 只要有任何一个别的文件、或者子目录，就算【文件目录】，用文件目录的呈现方式。
   * 注意：这不是"怎么画每条内容"——单条要不要显示缩略图由 isImage(entry) 各自决定。
   */
  private isPhotoAlbumDirectory(entries: FileEntry[]): boolean {
    if (entries.length === 0) {
      return false
    }
    for (const entry of entries) {
      if (entry.isDirectory) {
        return false
      }
      if (!this.isImage(entry) && !this.isVideo(entry)) {
        return false
      }
    }
    return true
  }

  private isAudioAlbumDirectory(entries: FileEntry[]): boolean {
    return entries.length > 0 && entries.every((entry: FileEntry): boolean =>
      !entry.isDirectory && this.isAudio(entry))
  }

  /**
   * Glyph for the view-mode button. It deliberately shows the mode the NEXT tap
   * switches TO, not the mode currently on screen, so the icon names its own
   * outcome and 点哪个就切到哪个:
   *
   *   list            -> grid icon        (tap -> grid)
   *   grid  + images  -> waterfall icon   (tap -> waterfall)
   *   grid  no images -> list icon        (tap -> list)
   *   waterfall       -> list icon        (tap -> list)
   *
   * Each mode therefore maps to exactly one glyph, and no glyph ever appears in
   * a mode it does not lead to. This mirrors the branch in toggleFileViewMode(),
   * which owns the same decision - change both together.
   */
  private fileViewModeIcon(): Resource {
    if (this.fileViewMode === 'list') {
      return $r('sys.symbol.square_grid_2x2')
    }
    if (this.fileViewMode === 'grid' && this.currentDirectoryIsPhotoAlbum) {
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
    this.waterfallLocalSignatures = {}
    this.waterfallAspectRatios = {}
    this.waterfallAspectSignatures = {}
    this.waterfallAspectEpoch += 1
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
    this.pendingVisibleLoads.clear()
    // R3.2：rendered preview key 是 per-条目状态，换目录即作废。
    // 不做 LRU，目录切换清空即可（避免长期浏览大量目录后无限增长）。
    this.gridRenderedPreviewKey = {}
    this.waterfallRenderedPreviewKey = {}
    this.previewQueue.cancelPending()
    this.fileVisibleStartIndex = 0
    this.fileVisibleEndIndex = 0
    this.waterfallVisibleStartIndex = 0
    this.waterfallVisibleEndIndex = 0
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
      let start = this.fileVisibleStartIndex
      let end = this.fileVisibleEndIndex
      if (end <= start) {
        start = 0
        end = Math.min(this.entries.length - 1, limit * 2 - 1)
      } else if (this.fileViewMode === 'list') {
        start = Math.max(0, start - 1)
        end = Math.max(start, end - 1)
      }
      start = Math.max(0, start - 4)
      end = Math.min(this.entries.length - 1, Math.max(start, end + 4))
      end = Math.min(end, start + 31)
      let scheduled = 0
      for (let index = start; index <= end && index < this.entries.length; index += 1) {
        const entry = this.entries[index]
        if (scheduled >= limit) {
          break
        }
        if (entry.isDirectory || (!this.isImage(entry) && !this.isVideo(entry) && !this.isAudio(entry))) {
          continue
        }
        this.resolveFileListImageRotation(entry)
        this.loadEntryPreview(entry, this.previewPriority(index, this.fileViewMode))
        scheduled += 1
      }
    }, 0)
  }

  private previewPriority(index: number, surface: ThumbnailSurfaceKind): number {
    let visibleStart = this.fileVisibleStartIndex
    let visibleEnd = this.fileVisibleEndIndex
    if (surface === 'waterfall') {
      visibleStart = this.waterfallVisibleStartIndex
      visibleEnd = this.waterfallVisibleEndIndex
    } else if (surface === 'list') {
      visibleStart = Math.max(0, visibleStart - 1)
      visibleEnd = Math.max(visibleStart, visibleEnd - 1)
    }
    if (index >= visibleStart && index <= visibleEnd) { return 0 }
    return 1 + (index < visibleStart ? visibleStart - index : index - visibleEnd)
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
    if (this.locateProgrammaticScrolling) {
      this.locateImagePipelineCount += 1
      this.pendingVisibleLoads.set(entry.path, entry)
      return
    }
    // The incoming directory is already visible during the push animation,
    // but starting its cache stats, network work and decoders here can delay
    // the JS cleanup of the outgoing snapshot. Warm the settled visible range
    // from finishPreparedFileTransition instead.
    if (this.showPageTransition && this.screen === 'files' && !this.showImageViewer) {
      return
    }
    // During timeline scrubbing, visible rows can change several times per
    // frame. Cached pixels may render, but network/decode work starts only for
    // the settled visible range after release.
    if (this.timelineScrubActive && this.screen === 'files' && !this.showImageViewer) {
      return
    }
    // A visible row may reappear many times while scrolling. Resolve the
    // in-memory URI first so a cache hit does not synchronously stat/touch the
    // thumbnail on every mount. The request flag also deduplicates the short
    // gap before an async cache result is published.
    if (this.previewUri(entry).length > 0) {
      return
    }
    if (this.isPreviewRequestActive(entry.path)) {
      this.previewQueue.promote(entry.path + '#preview:' + this.previewGeneration.toString(), priority)
      // 🔬 重复请求被 token 去重挡下（验收用计数）。
      this.previewDuplicateBlockedCount += 1
      return
    }
    // LazyForEach mounts rows throughout an inertial scroll. Delay cache
    // stats, persistent-index reads and new downloads until onScrollStop
    // warms the final visible window.
    if (this.fileContentScrolling && this.screen === 'files' && !this.showImageViewer) {
      return
    }
    const generation = this.previewGeneration
    const pathToken = this.acquirePathGeneration(entry.path)
    // R3.1：本请求的 owner token。只有它仍然拥有这个 path 时才有权在结束时清除标志。
    const requestToken = this.previewRequestSequence + 1
    this.previewRequestSequence = requestToken
    this.previewRequests[entry.path] = requestToken
    // A running task from an old directory generation must not reject a new
    // task for the same path after the user returns to that directory.
    const queueKey = entry.path + '#preview:' + generation.toString()
    const accepted = this.previewQueue.enqueue(queueKey, priority, async (): Promise<void> => {
      await this.loadEntryPreviewNow(entry, generation, pathToken, requestToken)
    })
    if (!accepted) {
      if (this.previewRequests[entry.path] === requestToken) {
        this.previewRequests[entry.path] = 0
      }
    }
  }

  private async loadEntryPreviewNow(entry: FileEntry, generation: number, pathToken: number,
    requestToken: number): Promise<void> {
    try {
      await this.ensureCacheState()
      if (generation !== this.previewGeneration || !this.isPathGenerationValid(entry.path, pathToken)) {
        this.imageTelemetry.recordStaleCompletion(entry.path, 'generationMismatch')
        return
      }
      if (this.fileEntryDataSource.indexOfPath(entry.path) < 0) {
        this.imageTelemetry.recordStaleCompletion(entry.path, 'entryNotFound')
        return
      }

      // A viewer-derived thumbnail has canonical upright pixels and is the
      // only safe base for persisted manual rotations. Prefer it over the NAS
      // thumbnail, whose service response may have stripped EXIF metadata.
      if (this.isImage(entry)) {
        const canonicalPath = this.mediaPreviewManager.cachedImagePreview(entry,
          this.thumbnailDirectory)
        if (canonicalPath.length > 0) {
          if (!this.isPathGenerationValid(entry.path, pathToken)) {
            this.imageTelemetry.recordStaleCompletion(entry.path, 'pathTokenSuperseded')
            return
          }
          await this.publishImagePreview(entry, canonicalPath, true, generation)
          return
        }
        const retainedPath = this.previewLocalPaths[entry.path]
        if (typeof retainedPath === 'string' && retainedPath.length > 0 &&
          CacheManager.exists(retainedPath)) {
          if (!this.isPathGenerationValid(entry.path, pathToken)) {
            this.imageTelemetry.recordStaleCompletion(entry.path, 'pathTokenSuperseded')
            return
          }
          await this.publishImagePreview(entry, retainedPath,
            this.previewCanonicalPaths[entry.path] === true, generation)
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
      if (thumbnailPath.length === 0 && this.isAudio(entry) && generation === this.previewGeneration &&
        this.isPathGenerationValid(entry.path, pathToken)) {
        const localPath = CacheManager.findExisting(this.cacheDirectory, entry.name, this.originalCacheKey(entry))
        thumbnailPath = await this.repository.prepareAudioThumbnail(entry, localPath,
          this.thumbnailDirectory, this.thumbnailCacheLimitBytes)
      }
      if (generation !== this.previewGeneration || !this.isPathGenerationValid(entry.path, pathToken)) {
        this.imageTelemetry.recordStaleCompletion(entry.path, 'generationMismatch')
        return
      }
      if (this.fileEntryDataSource.indexOfPath(entry.path) < 0) {
        this.imageTelemetry.recordStaleCompletion(entry.path, 'entryNotFound')
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
      // RequestToken Fix：无条件按【所有权】清除，不再要求 generation/token 仍匹配。
      // 旧实现在世代失配时不清 → 标志永久为 true → 该 path 被早退永久挡住。
      // 而按所有者清除也不会让老请求误清新请求的状态。
      if (this.previewRequests[entry.path] === requestToken) {
        this.previewRequests[entry.path] = 0
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
      HapticFeedback.warn()
      const response = await this.showTrackedDialog({ title: '移除上传记录？',
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
    HapticFeedback.warn()
    const response = await this.showTrackedDialog({
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
      if (task.status === 'waiting_server') { return progress + ' · 等待 NAS 连接（点击重试）' }
      return progress + (task.status === 'paused' ? ' · 已暂停' : ' · 排队中')
    }
    const received = task.receivedBytes <= 0 ? '0 B' : this.formatSize(task.receivedBytes)
    const transfer = task.size > 0 ? received + ' / ' + this.formatSize(task.size) : received
    switch (task.status) {
      case 'downloading':
        return transfer + ' · 下载中'
      case 'waiting_wifi':
        return transfer + ' · 等待 WiFi'
      case 'waiting_server':
        return transfer + ' · 等待 NAS 连接'
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
    HapticFeedback.warn()
    const response = await this.showTrackedDialog({
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
    this.albumConfirmationPending = false
    this.albumReselectPending = false
    this.showAlbumPicker = false
    this.showAlbumUpload = false
    this.showAlbumDetails = false
    if (this.offlineProfileTimer !== 0) { clearTimeout(this.offlineProfileTimer); this.offlineProfileTimer = 0 }
    if (this.nasRecoveryTimer !== 0) { clearTimeout(this.nasRecoveryTimer); this.nasRecoveryTimer = 0 }
    this.offlineCacheMode = false
    this.offlineProfile = null
    this.nasRecoveryPending = false
    this.cancelFileTransition()
    this.clearSearchIfPresent()
    this.closeImageViewer()
    this.closeAudioPlayer(true)
    this.closeVideoPlayer()
    await this.videoTransferManager.flush()
    await this.ensureDownloadState()
    await this.downloadQueue.setReady(false)
    await this.uploadQueue.setReady(false)
    await this.albumUpload.setReady(false)
    this.repository.logout()
    this.navigationRequestId += 1
    this.isNavigating = false
    this.screen = 'login'
    // A signed-out session must not leave another account's recycle listing
    // reachable through the back stack.
    this.recycleRequestToken += 1
    this.showRecycleBinSettings = false
    this.recycleEntries = []
    this.recycleLoading = false
    this.recycleStack = []
    this.recycleBlockedShares = []
    this.recycleScope = 'personal'
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
