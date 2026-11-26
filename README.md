# quick video

Android 优先的自用多源视频播放器。首页有片名搜索、继续观看和直链入口。播放器支持按集选择线路并沿用播放进度。内置一段 30 秒的离线样片，提供两个清晰度，首次启动即可试播。

## Windows 上打包

需要 Flutter 3.32 或更新的稳定版、已由 `flutter doctor -v` 识别的 Android SDK，以及 Python 3.10 或更新版。在解压后的项目目录运行：

```powershell
py -3 setup_android.py
flutter analyze
flutter build apk --release
```

APK 输出在 `build/app/outputs/flutter-apk/app-release.apk`。连接开启 USB 调试的 Android 7.0 或以上手机后，也可以运行 `flutter run`。首次打开后，进入「播放测试片 → 第 1 集」，播放几秒再切换高清和流畅，检查进度是否衔接。

如果 Flutter 提示 `Build failed due to use of deleted Android v1 embedding.`，在项目根目录运行最新版的 `py -3 setup_android.py`，再重新打包。脚本会创建缺失的 Android 工程，或将已有主 Manifest 的 embedding 标记修复为 v2。

## 接入自用来源

测试服务在本机启动，不需要安装 Python 包：

```powershell
py -3 server/app.py
```

手机通过 USB 连接时，在另一窗口运行 `adb reverse tcp:8765 tcp:8765`，然后在 App 的「来源设置」填 `http://127.0.0.1:8765`。点击搜索会读取两个服务端测试来源，同一剧集会显示两条线路。断开 USB 后可以改用自己的 HTTPS 服务地址。

复制 `server/sources.example.json` 为 `server/sources.local.json`，按实际来源修改，并用 `py -3 server/app.py --config server/sources.local.json` 启动。服务需要能访问目录和 HTML 页面，手机需要能访问实际媒体地址。

| 接入方式 | 来源配置 |
| --- | --- |
| 本地 JSON 配置 | 写入 `items` 数组。用 `url` 指向媒体，或用 `pageUrl` 指向播放器网页。 |
| 远程 JSON 目录 | 来源写 `"type": "json"` 与 `"url": "https://…/catalog.json"`。远程文件内容为与 `items` 同格式的数组。 |
| 扩展 M3U 目录 | 来源写 `"type": "m3u"` 与 `"url": "https://…/playlist.m3u"`。每个频道或条目作为单独视频。 |
| MP4 或 HLS 直链 | 可直接在手机点「打开视频链接」，无需启动服务。 |

JSON 来源示例：

```json
[
  {
    "id": "source-a",
    "name": "我的来源 A",
    "items": [
      {
        "id": "s01e01",
        "title": "示例系列",
        "year": "2026",
        "kind": "剧集",
        "workId": "example-series-s1",
        "episode": "第 1 集",
        "episodeId": "1",
        "pageUrl": "https://example.com/watch/1"
      }
    ]
  }
]
```

- 每个来源的 `id` 以及同一来源内的条目 `id` 都要唯一。跨来源的同一季用相同的 `workId`。同一集使用相同的 `episodeId`。
- 网页解析读取 HTML 中的 `<video>`、其子元素 `<source>` 以及 `og:video` 元数据。依赖 JavaScript 动态生成播放器的站点需要单独适配。
- 播放时才解析网页。视频由手机直接播放，服务只返回媒体位置。远程目录最多缓存两分钟。
- 来源配置由服务管理员维护。服务默认绑定回环地址，供本机和 ADB 反向连接使用。

## 接入 TVBox 点播配置

在已有 QuickVideo 工程上升级时，将本包的 `lib/`、`server/` 和 `setup_android.py` 中的文件更新到你的工程。已有的 `android/` 目录、包名和本地来源配置可以保留。重启来源服务后，用新版 APK 访问 TVBox 剧集详情。

先检查接口能否导入，把示例地址替换为自己的配置链接：

```powershell
py -3 server/app.py --inspect-tvbox --tvbox "https://你的配置地址/config.json"
```

检查有可搜索 CMS 源后，启动服务。多个配置可以重复传 `--tvbox`：

```powershell
py -3 server/app.py --tvbox "https://你的配置地址/config.json"
```

配置在服务启动时自动获取，修改订阅后重启服务刷新。App 中「来源设置」继续填 QuickVideo 自己的服务地址。USB 连接时运行 `adb reverse tcp:8765 tcp:8765`，填写 `http://127.0.0.1:8765`。服务启动时输出导入数量和来源名单。

- 支持含 `sites` 的 TVBox JSON 对象，以及 `type: 0`（XML CMS）和 `type: 1`（JSON CMS）HTTP(S) 接口。网址可以没有 `.json` 后缀。
- 搜索时按关键词查询各 CMS。打开详情时加载剧集，点击播放时重新获取地址。同一作品中编号相同的剧集可以切换线路。
- 仅使用 CMS 直接提供的 HTTP(S) MP4 或 HLS 链接。CSP/JAR、JS/drpy、`type: 4`、`parses`、直播和加密配置当前不支持。需要解析网页、请求鉴权或专用请求头的线路可能无法播放。HTTP 媒体链接还取决于手机的网络安全配置。
- 只有部分接口失败时，其余来源的结果仍可用。导入数量为零时，检查订阅是否全部为脚本源，或链接是否返回了 HTML 导航页。
