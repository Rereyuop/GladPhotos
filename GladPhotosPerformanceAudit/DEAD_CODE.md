# 可删除与可合并代码审计

静态引用数按 `GladPhotos/**/*.swift` 与 `Scripts/**/*.swift` 的单词级全文匹配统计；动态 SwiftUI 使用、private 符号和协议调用会造成误差，因此以下均为候选，不执行删除。

| 文件 | 符号 | 引用数 | 怀疑理由 | 删除风险 | 建议 |
|---|---:|---:|---|---|---|
| `ExternalMediaThumbnailView.swift:144-146` | `thumbnailSizing` | 1 | 仅定义，无读取；调用实际固定传 `.longestEdge` | 低 | 删除 |
| `ExternalThumbnailService.swift:119-123` | `removeAllCachedImages` | 1 | 仅定义，无调用 | 中；未来内存警告/设置页可能需要 | 保留观察 |
| `ExternalThumbnailService.swift:6-10` | `ExternalThumbnailSizing` | 5 | 三 case 中仅 `.longestEdge` 在调用点出现，service 参数全部以 `_` 忽略 | 中；可能是预留 API | 合并/收窄 |
| `PhotographyClassifier.swift:98-105` | `CoreMLPhotographyClassifier` | 2 | 空占位，`isAvailable` 永远 false，`classify` 永远 nil | 高；明确是未来模型插槽 | 保留观察 |
| `PhotographyClassifier.swift:159-165` | `modelUnavailableFallback` | 2 | 占位 fallback 与注释目标冲突，且返回错误的非摄影标签 | 中 | 合并/修正（本次不改） |
| `ExternalMediaGridView.swift:3-25` / `PhotoGridView.swift:4-27` | `ExternalMediaDaySection.make` / `PhotoDaySection.make` | 各 2 左右 | 两份过滤、按天分组、组内排序、Section 排序几乎同构 | 中；两种模型字段不同 | 合并 |
| `ExternalMediaThumbnailView.swift` / `PhotoThumbnailView.swift` | Cell 请求 token/可见性/取消逻辑 | 多处 | 两套生命周期状态机独立演进 | 高；Photos 与文件 URL 底层语义不同 | 合并共同协议，保留后端 |
| `ExternalMediaScanner.swift:231-242` / `PhotographyClassifier.swift:114-124` | ImageIO 属性读取 | 多处 | 扫描取尺寸后，识别再次打开同一文件读取属性/EXIF | 中；缓存失效需绑定修改时间 | 合并元数据缓存 |
| `ExternalFolderRecognitionStateStore.swift` / `PhotographyTagStore.swift` | 识别状态持久化 | 类型引用 4 / 多处 | 同一功能域分散在 UserDefaults、JSON、JSONL | 高；显示偏好与大记录的存储需求不同 | 合并生命周期接口 |
| `Scripts/benchmark_external_media.swift` | `ExternalMediaBenchmark` | 仅脚本入口 | 只用于合成基准，不是 XCTest；仍是当前唯一外部媒体基准 | 低（不进 app target） | 保留观察 |

## 未发现或不建议删除

- 未发现大量注释掉的旧实现；现有注释主要解释并发与性能策略。
- 未发现另一套外部文件扫描器；`ExternalMediaScanner` 是唯一主扫描实现。
- 未发现另一套外部缩略图磁盘/内存缓存；Apple 的 `PHCachingImageManager` 属于不同数据源，不应直接视为重复缓存。
- 未发现永远进入不了的系统版本兼容分支。
- `PhotographyTagMenu`、`ExternalFolderWatcher`、`ExternalFolderRecognitionStateStore`、`PhotoImageService` 等均有真实调用，不属于无引用服务。
- Xcode 工程采用 file-system synchronized group，不能用 pbxproj 中无逐文件条目判断 Swift 文件未参与编译。
