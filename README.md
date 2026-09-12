# DoubaoVoiceBridge（远控听写）

一个轻量的 macOS 菜单栏工具：在 MacBook 上用豆包语音输入法听写，并把识别文字通过 UU 远控粘贴到远端 Mac 的当前输入框。

> 本项目是非官方的个人自动化工具，与豆包、字节跳动、UU 远控或网易没有隶属、合作或授权关系。相关名称与商标归各自权利人所有。

## 使用方式

确保 UU 远控窗口处于前台，然后选择与你的豆包设置一致的方式：

### 左 Control（长按模式）

1. 按住左 `Control`（左 `⌃`）。
2. 在弹出的听写框中说话。
3. 松开左 `Control`。
4. 工具等待豆包语音输入法完成识别，然后通过 UU 剪贴板同步并在远端 Mac 当前输入框自动粘贴。

### 右 Option（免按模式）

1. 按一次右 `Option`（右 `⌥`）开始听写。
2. 在弹出的听写框中说话。
3. 再按一次右 `Option`（或按任意普通键）结束听写。
4. 工具等待豆包语音输入法完成识别，然后自动粘贴到远端 Mac。

两种快捷键都只在 UU 远控是活动窗口时接管；其它应用中完全保留原本的豆包输入法和系统快捷键行为。

## 运行要求

- macOS 13 或更高版本
- Intel 或 Apple Silicon Mac
- 已安装并启用豆包语音输入法，语音快捷键设为左 `Control`（长按模式）或右 `Option`（免按模式）
- 已安装 UU 远控，且 MacBook 与远端 Mac 可以正常连接和同步剪贴板
- 辅助功能与输入监控权限

当前实现通过 Bundle ID `com.netease.uuremote` 识别 UU 远控。如果相关应用更改 Bundle ID、快捷键或输入行为，项目可能需要同步调整。

右 `Option` 同时使用 HID event tap 和物理键盘 IOHID 监听。在本机 UU 4.39.1 环境中，event tap 路径未能可靠触发；加入 IOHID 监听后用户确认可以触发，具体原因仍待定位。IOHID fallback 会恢复物理按下/松开边沿，并复用同一套 UU 前台、组合键和合成事件规则；fallback 仅补回 tap 未收到的边沿，正常 tap 路径不会重复触发。

## 从源码构建

需要 Xcode Command Line Tools 和 Swift 5.9 或更高版本。

```bash
git clone https://github.com/shubing-lab/DoubaoVoiceBridge.git
cd DoubaoVoiceBridge
./scripts/build-app.sh
open dist
```

该仓库基于原作者 `yupeng316888-create/DoubaoVoiceBridge`，原作者许可保留。

构建脚本会生成通用二进制，并对本地生成的 `dist/远控听写.app` 做 ad-hoc 签名。把应用拖到你希望的位置后启动即可。该构建没有 Apple Developer ID 签名，也未经过公证。

首次启动时，请在“系统设置 → 隐私与安全性”中为“远控听写”开启：

- 辅助功能
- 输入监控

麦克风权限只需要授予豆包语音输入法，本工具本身不录音。

## 工作原理与安全边界

- 只在 UU 远控是活动窗口时接管左 `Control` 长按或右 `Option` 免按快捷键。
- 在本机显示一个临时文本框，让豆包语音输入法把识别结果写入其中。
- 松开左 `Control`、再次按右 `Option` 或按普通键结束听写后，等待输入法提交最终文字，再把文字暂存到系统剪贴板。
- 自动粘贴前重新确认同一个 UU 进程和同一个原聚焦窗口；焦点变化时取消操作。
- 明确发送完整的 `Command` 按下、`V` 按下、`V` 松开和 `Command` 松开事件序列，避免远端只收到字母 `V`。
- 不备份、不恢复原剪贴板；发送流程只把听写文字写入剪贴板，等待 UU 同步后自动粘贴，避免大剪贴板内容阻塞发送。

本工具不调用豆包账号或语音服务，不保存听写正文，也不包含网络请求。网络传输与剪贴板同步由豆包语音输入法和 UU 远控各自完成。

## 测试与诊断

构建脚本会自动运行内置自检和诊断。也可以单独执行：

```bash
swift run DoubaoVoiceBridge --self-test
swift run DoubaoVoiceBridge --diagnostics
```

当前内置自检覆盖左 Control 长按、右 Option 触发配置、同文本但剪贴板 generation 变化仍可发送、不同/空文本拦截、目标 PID 与 AX 窗口校验、识别文本稳定等待、延迟配置迁移、UU 同步安全下限和听写框布局。

如需在不使用麦克风、不填充或提交文字的情况下重复验证听写框和 UU 前台焦点，可运行 `swift run DoubaoVoiceBridge --manual-composer`；它会启动后延迟打开既有手动入口，仍要求 UU 处于前台或活动状态。

## License

[MIT](LICENSE)
