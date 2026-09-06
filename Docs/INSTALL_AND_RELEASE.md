# 真机安装、测试与 App Store 上架

## 安装到自己的 iPhone

1. 使用已经安装好的 Xcode 26.6（iOS 26.5 SDK）。该版本满足当前 TestFlight 和 App Store 上传工具要求。
2. 在 Mac 上打开 `TianTianCheckIn.xcodeproj`。
3. 用数据线连接 iPhone，首次连接时在手机上选择“信任此电脑”。也可在首次配对后启用无线调试。
4. iPhone 打开“设置 → 隐私与安全性 → 开发者模式”，按提示重启并确认。
5. Xcode 打开“Settings → Accounts”，确认 Apple ID 已登录且开发者团队可见。
6. 选择项目中的 `TianTianCheckIn` Target，进入“Signing & Capabilities”：
   - 勾选 `Automatically manage signing`；
   - Team 选择你的开发者团队；
   - 将 Bundle Identifier 改成你账号下唯一的反向域名，例如 `com.yourname.tiantiandaka`。
7. Xcode 顶部运行设备选择已连接的 iPhone，点击运行按钮或按 `⌘R`。
8. 首次打开 App，按实际使用顺序允许摄像头、麦克风和“添加到照片”权限。

## 建议真机验收清单

- 分别完成一次竖屏和横屏 60 秒录像，检查成片方向、清晰度和声音。
- 在 10、5、4、3、2、1 秒时确认播报没有漏报或重复。
- 快速计次并撤销，检查屏幕及成片中的次数变化。
- 关闭计时、计次、录像、现场声音和播报，逐项验证组合行为。
- 拒绝三类权限后检查错误提示；录像权限拒绝时返回设置并使用纯计时计次。
- 接听电话、切换蓝牙耳机、锁屏和存储空间不足时检查恢复与提示。
- 预览后分别测试保存、重新录制和放弃，确认系统相册及临时文件行为。

## TestFlight 测试

1. 使用 Xcode 26.6 或更高版本重新编译并跑完测试。
2. 在 App Store Connect 创建 App 记录，选择正式 Bundle ID 和应用名称。
3. 在 Xcode 选择 `Any iOS Device (arm64)`，执行“Product → Archive”。
4. Organizer 中选择归档，点击“Distribute App → App Store Connect → Upload”。
5. App Store Connect 的 TestFlight 页面等待构建处理完成。当前工程已声明不使用非豁免加密，仍以后台实际提示为准。
6. 先添加内部测试员；需要外部测试时创建测试组并提交 Beta App Review。
7. 收集至少两代 iPhone、横竖屏和不同权限组合的结果，再进入正式发布。

## App Store 正式上架

1. 确定唯一 App Store 名称，建议使用“天天打卡·体测训练记录”；桌面显示名仍为“天天打卡”。
2. 完成 App 信息：副标题、描述、关键词、支持 URL、隐私政策 URL、年龄分级、类别和版权信息。
3. 在 App Privacy 中按当前实现申报“不收集数据”，并提供可公开访问的隐私政策 URL；如果以后加入云端、账号或第三方 SDK，需要重新评估申报。
4. 使用真实但不包含可识别学生信息的演示素材制作 6.7 英寸和 6.5 英寸 iPhone 截图。
5. 填写版本信息，选择已经上传并通过处理的构建，完成出口合规和内容版权问题。
6. 若在中国大陆提供 App，按 App Store Connect 要求补齐适用的 ICP 备案号，并确保备案主体/元数据与工信部记录一致；尚未备案时可先不勾选中国大陆发布地区。
7. 提交 App Review；审核通过后选择手动发布或自动发布。

## 上架前仍需准备

- 可公开访问的支持网页和隐私政策网页。
- 最终 Bundle ID、SKU、开发者显示名称和版权主体。
- App Store 截图、描述、关键词及审核备注。
- 如果将产品直接定位为 11 岁以下儿童使用，需要重新评估 Kids Category、家长门和未成年人隐私要求。
