# 性能基线

## 执行状态

**未运行。** 项目没有可直接使用真实只读测试图库、且能覆盖首次/再次打开、首屏、命中率、滚动解码和识别开关差异的安全测试。现有 `Scripts/benchmark_external_media.swift` 会在临时目录生成 1,000/10,000 个硬链接合成数据；按“不创建大量合成图片冒充最终结论”的要求跳过。未打开、读取或修改任何用户图库。

## 环境记录

- 审计主机：Apple Silicon (`arm64`)
- macOS：27.0（Build 26A5353q）
- 测试设备型号：未从只读项目材料安全获得
- 测试目录图片数量与格式：未提供测试目录，未统计
- 首次打开耗时：未测
- 再次打开耗时：未测
- 首屏缩略图出现耗时：未测
- 缓存命中率：未测；当前服务未暴露 hit/miss 计数
- 滚动期间缩略图解码次数：未测；当前日志只记录每次 thumbnail 时长，不区分命中（命中直接返回且不记录）
- 峰值内存：未测
- 识别开启/关闭差异：未测

## 已有测量能力

- `PerformanceLogger` 记录 scan、grouping、thumbnail、recognition、json-write 的耗时。
- 合成 benchmark 可记录 scan、48 张首屏 decode、最多 240 张滚动代理 decode、取消恢复时间和 resident memory，但不能代表真实 HEIC/PNG、SwiftUI 布局帧时间或缓存命中率。
