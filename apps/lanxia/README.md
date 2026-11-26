# 羽

羽（曾用名蓝匣、暂存喵）是 Apple Silicon Mac 上的菜单栏工具。鼠标在菜单栏的小翅膀图标上停留约 0.35 秒会打开文件中转站。也可点击图标打开，或直接把文件拖到图标上暂存。首页提供添加、搜索、ZIP 压缩、日程提醒与 Outlook 邮件入口。

## 悬停与全屏空间

将指针停在功能入口、选项菜单或预览按钮上，羽会在按钮上标出两秒进度，并显示即将打开的目标。移开指针或滚动可取消。两秒悬停在「偏好设置 → 操作方式」中可关闭。发送、删除、录制和权限操作请手动触发。

首页、设置和各功能共用同一主面板。在其他应用的 macOS 全屏空间也可从菜单栏打开羽。右上角的「展开主面板」将羽铺到当前屏幕的可用区域，同处可恢复紧凑大小。打开或保存文件时，系统选择器附在主面板上。

## 识图

从菜单栏首页点「识图」，选择、拖入或粘贴一张图片。羽在本机显示图片预览、尺寸、识别文字和候选标签，可一键复制文字。开启 AI 后，可以输入问题，再点「解读」将当前图片发送给 DeepSeek 或 Codex。识图页会在发送前标明接收方。

## 按需开启 AI

1. 从菜单栏打开羽，再点「开启 AI」。每次启动羽后，AI 都默认关闭。
2. 在聊天页点「偏好设置」，为默认提供方 DeepSeek Harness 保存 DeepSeek API Key。密钥由 macOS 钥匙串保存，使用 DeepSeek API 需要网络与 API 额度。也可以切换到原有 OpenAI Codex。
3. 输入问题后点发送。附件先选取和预览，邮件摘要需确认，屏幕助手需手动选择画面和点击分析。语音转写先填入聊天草稿。
4. 使用首页「关闭 AI」或偏好设置「关闭本次运行的 AI」结束服务和当前屏幕会话。

DeepSeek 路径使用官方 [DeepSeek Harness 0.2.2-rc.5](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.2-rc.5) 与 DeepSeek API。在聊天附件和屏幕助手中，DeepSeek 接收由设备提取的文字。Codex 可接收所选图片。两个提供方的对话记录在本机分别保存。

暂存文件、副本、提醒、邮件缓存及对话历史位于 `~/Library/Application Support/StashCat`。旧对话记录可在那里查阅。应用图标是座天使主题的原创像素画，菜单栏的像素小翅膀使用 macOS 模板图标自动适应菜单栏明暗。

## 构建与回归

在项目内运行 `Scripts/build.sh` 构建本机签名的 App，运行 `Scripts/test.sh` 执行回归。构建过程需要下载固定版本的 Harness 与 Node.js 依赖。版本历史见 [CHANGELOG.md](CHANGELOG.md)。

如需重新生成应用图标，在羽源码目录运行以下命令。

```sh
xcrun swiftc -parse-as-library Scripts/make-icon.swift -o /tmp/stashcat-make-icon
/tmp/stashcat-make-icon "$PWD"
iconutil -c icns Resources/AppIcon.iconset -o Resources/StashCatGlass.icns
```
