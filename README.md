# PhotosVideoSpeed (相册视频倍速)

系统相册视频倍速播放插件。仅注入 `com.apple.mobileslideshow`，支持 iOS 15–17、roothide。

## 功能

- 视频全屏播放时，左下角显示浮动倍速按钮（0.5x / 1x / 1.5x / 2x / 3x）
- 点按按钮循环切换倍速；长按按钮弹出菜单直选
- 倍速在同一 App 会话内跨视频记忆；系统播放键恢复播放后自动拦回用户倍速
- 无视频时不显示按钮，轮询自动降载（displayLink 15fps + 0.5s 兜底扫描，无视频时停止）

## 实现要点（思路参考 MobileSlideShowHook 0.0.5 逆向结论）

- **零 hook**：不 hook 任何系统类，纯轮询扫描 `AVPlayerLayer` 拿到 `AVPlayer`，直接用公开 API `rate` 变速
- 检测当前可见的主视频播放层，计入父层裁剪与透明度；兼容竖屏窗口内的横屏视频，不再只按窗口面积的 35% 过滤
- 暂停、首次加载或尚未获得尺寸/时长时也可显示面板；时长加载前禁用进度拖动，视频切换时重新绑定播放器及当前播放项
- 音频算法：≤2x 用 `TimeDomain`（变速不变调），3x 用 `Varispeed`（音调随速度，公开 API 的上限取舍）
- 视频消失/暂停/后台时自动暂停轮询，省电

## 构建

```
./build.sh
```

一键产出 iOS 16 / iOS 17 两个平台的 deb（`packages/ios16/`、`packages/ios17/`），双平台完成后自动推进 control 版本号。

产物为 iphoneos-arm64e（roothide）。

## 回归验证

在 macOS 上运行 `./tests/run-tests.sh`。测试直接执行生产检测函数，并提取管理器原方法验证视频切换、缓存层裁剪、横屏视频、未加载元数据，以及过期的动画/拖动回调。

这些测试使用真实 CALayer 几何与测试播放器、UIKit 调度替身；iOS 相册中的连续翻页、倍速操作和面板位置仍需真机验证。
