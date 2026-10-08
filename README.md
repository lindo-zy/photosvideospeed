# PhotosVideoSpeed (相册视频倍速)

系统相册视频倍速播放插件。仅注入 `com.apple.mobileslideshow`，支持 iOS 15–17、roothide。

## 功能

- 视频全屏播放时，左下角显示浮动倍速按钮（0.5x / 1x / 1.5x / 2x / 3x）
- 点按按钮循环切换倍速；长按按钮弹出菜单直选
- 倍速在同一 App 会话内跨视频记忆；系统播放键恢复播放后自动拦回用户倍速
- 无视频时不显示按钮，轮询自动降载（displayLink 15fps + 0.5s 兜底扫描，无视频时停止）

## 实现要点（思路参考 MobileSlideShowHook 0.0.5 逆向结论）

- **零 hook**：不 hook 任何系统类，纯轮询扫描 `AVPlayerLayer` 拿到 `AVPlayer`，直接用公开 API `rate` 变速
- 有效性过滤：`presentationSize > 1` 且 `duration > 0.25s`，排除实况照片预览/纯音频
- 音频算法：≤2x 用 `TimeDomain`（变速不变调），3x 用 `Varispeed`（音调随速度，公开 API 的上限取舍）
- 视频消失/暂停/后台时自动暂停轮询，省电

## 构建

```
make THEOS=/Users/xiao/dev/theos-roothide package FINAL=1
```

产物在 `packages/` 下（iphoneos-arm64e，roothide）。
