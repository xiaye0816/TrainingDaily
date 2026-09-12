# 自动识别现场诊断

训练设置中开启“保存识别诊断”后，App 会在本机保存最近 3 次自动识别现场，最长保留 7 天。数据不会上传，也不会进入 Git 仓库。

每次现场包含：

- `video.mov`：与训练记录一致的完整成片；
- `pose.ndjson`：Vision 输出的所有人物关键点、置信度及主体选择结果；
- `events.ndjson`：识别状态、自动计次、手动补计、镜头、缩放和生成结果；
- `frame-*.jpg`：每秒一张低分辨率现场帧，用于快速核对关键点与人物位置；
- `manifest.json`：设备、系统、App 版本和本次完整配置。

连接 iPhone 后，可用以下方式从数据容器复制（替换设备标识和目标目录）：

```sh
xcrun devicectl device copy from \
  --device <DEVICE_IDENTIFIER> \
  --domain-type appDataContainer \
  --domain-identifier com.shaoguoqing.tiantiandaka \
  --source 'Library/Application Support/TianTianCheckInDiagnostics' \
  --destination /path/to/TrainingDailyDiagnostics
```

提取完成后，可以对同一现场离线运行 Apple Vision、MediaPipe Pose 和姿态时序模型，按同一人工标注比较漏计、误计、单帧耗时和持续发热，再决定默认引擎。儿童现场素材不得提交到 GitHub。
