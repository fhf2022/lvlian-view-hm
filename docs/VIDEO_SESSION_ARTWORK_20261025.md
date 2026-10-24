# 控制中心视频封面（2026-10-25）

VideoMediaSessionManager 现在将文件管理已有的视频缩略图解码为 PixelMap，并设置 AVMetadata.mediaImage；不再只发送标题、进度。缩略图稍后完成时可更新系统卡片，保持原有播放页海报稳定。

经用户确认，音乐与视频共用 SessionArtwork 的解码和资源清理。最长边限制 800px，FD 解码不兼容时仅回读最多 2 MiB 的压缩图片；音乐维持居中裁成正方形和至少 300px，视频保留横竖比例。每个媒体会话只持有当前系统封面，换图/关闭释放，异步结果核对会话与文件。

官方依据：DevEcoCLI 的《AVSession Kit／应用接入播控自检／基础播控》明确使用 AVMetadata.mediaImage，建议 PixelMap，并支持视频横向、纵向模板。

验证：调试构建成功；session-artwork-decode-regression 验证尺寸、比例、FD 备用读法、截断/过大图片和句柄释放；media-session-artwork-regression 验证实际视频会话发布、晚到缩略图、切换/关闭竞态和无封面路径。平板播放 Photos/Screenshots 的视频后，系统控制中心卡片已实际显示缩略图，截图保存在忽略的 temp/video-artwork/。
