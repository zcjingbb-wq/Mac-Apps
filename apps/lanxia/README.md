# 蓝匣 2.0

蓝匣（原暂存喵）是 Apple Silicon Mac 上的菜单栏工具。点击蓝黄像素图标打开文件中转站，也可直接把文件拖到图标上。首页提供添加、搜索、ZIP 压缩、日程提醒与 Outlook 邮件入口。

## 按需开启 AI

1. 点击菜单栏图标，再点「开启 AI」。每次启动蓝匣后，AI 都默认关闭。
2. 在聊天页点「偏好设置」，为默认提供方 DeepSeek Harness 保存 DeepSeek API Key。密钥由 macOS 钥匙串保存，使用 DeepSeek API 需要网络与 API 额度。也可以切换到原有 OpenAI Codex。
3. 输入问题后点发送。附件先选取和预览，邮件摘要需确认，屏幕助手需手动选择画面和点击分析。语音转写先填入聊天草稿。
4. 使用首页「关闭 AI」或偏好设置「关闭本次运行的 AI」结束服务和当前屏幕会话。

DeepSeek 路径使用官方 [DeepSeek Harness 0.2.2-rc.5](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.2-rc.5) 与 DeepSeek API。图片附件与屏幕画面在设备端提取文字，再按操作发送文字给 DeepSeek。Codex 路径可发送所选图片。两个提供方的对话记录在本机分别保存。

暂存文件、副本、提醒、邮件缓存及对话历史位于 `~/Library/Application Support/StashCat`。旧对话记录可在那里查阅。菜单栏图标以 GBA 像素风绘制，取材自第四世代先机球。应用图标将同一像素球置于深蓝玻璃底与托盘上。

## 构建与回归

在项目内运行 `Scripts/build.sh` 构建本机签名的 App，运行 `Scripts/test.sh` 执行回归。构建过程需要下载固定版本的 Harness 与 Node.js 依赖。版本历史见 [CHANGELOG.md](CHANGELOG.md)。

如需重新生成应用图标，在项目的上级目录运行以下命令。

```sh
xcrun swiftc -parse-as-library lanxia/Sources/StatusBarIcon.swift lanxia/Scripts/make-icon.swift -o /tmp/lanxia-make-icon
/tmp/lanxia-make-icon "$PWD/lanxia"
iconutil -c icns lanxia/Resources/AppIcon.iconset -o lanxia/Resources/StashCatGlass.icns
```
