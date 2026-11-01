# PlaneM3U8

iOS/iPadOS 自用 m3u8 下载器：输入 m3u8 URL → 后台下载（`AVAssetDownloadURLSession`）→ 本地离线播放。无 Mac、无付费开发者账号，通过 GitHub Actions 云端构建 + AltStore/SideStore 免费签名侧载。

## 构建（云端，无需 Mac）

1. 将本仓库推送到 GitHub（私有仓库即可）。
2. Actions 自动运行 `build-ipa` 工作流，产出未签名 IPA。
3. 在运行结果的 **Artifacts** 里下载 `PlaneM3U8-ipa.zip`，解压得到 `PlaneM3U8.ipa`。

## 安装到 iPad（Windows + 免费 Apple ID）

1. Windows 安装 **iTunes 与 iCloud**（不要用 Microsoft Store 版，用苹果官网安装包）。
2. 安装 **AltServer**（https://altstore.io），iPad 通过 USB 连电脑（或同 Wi-Fi 同步）。
3. 通过 AltServer 把 AltStore 装进 iPad，然后用 AltStore 打开上面的 IPA 完成侧载；或直接安装 **SideStore**（推荐，可自动续签）。
4. iPad 上：设置 → 通用 → VPN与设备管理 → 信任你的 Apple ID。

## 限制（免费签名）

- 每 7 天需续签一次；SideStore 在电脑开机且与 iPad 同 Wi-Fi 时自动完成。
- 最多同时侧载 3 个 App。

## 技术要点

- 下载：后台 `AVAssetDownloadURLSession`，杀进程后继续；AES-128 加密流由系统自动处理。
- 产物：沙盒 `Application Support/Assets/*.movpkg`（系统私有格式，不支持导出 mp4）。
- 播放：`AVPlayer` + `VideoPlayer`，在线/离线同一套 API。
- 台账：`Documents/library.json` 记录元数据，删除时同步清理文件。
- 已放开 ATS（`NSAllowsArbitraryLoads`），支持 http 源。

## 本地修改代码

工程文件由 XcodeGen 生成（本机无需生成，CI 会执行）。在 Windows 上用 VS Code 编辑 `Sources/` 下 Swift 文件，push 后等 CI 出包即可。
