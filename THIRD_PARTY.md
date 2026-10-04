# 第三方与设计参考

WattsUp 不包含第三方依赖、第三方源码或下载的图片/字体。Swift Package 使用系统自带的 Foundation、Darwin、AppKit、SwiftUI、IOKit、CoreFoundation 与系统 IOReport 库。系统框架仍受 Apple 自身许可约束。

## 视觉方向

- **Stasis**（GPL-3.0）：桑基图形状的视觉方向参考。未读取、复制、改写或链接其源码，也未使用其素材。本项目的比例布局和 SwiftUI Path 独立实现。
- **Power Flow Lite**（MIT）：界面风格参考。未复制其代码或素材，因而本版本没有需要随附的上游代码许可。未来若实际引入代码，应在此列出文件、上游版本、修改情况与完整版权/许可声明。

## 接口与口径依据

- 公开资料中的 AppleSMC selector 2 / read-key-info 9 / read-value 5 / enumerate 8 协议说明。
- Xcode SDK 的 `mach/vm_statistics.h`、`sys/sysctl.h`、`sys/kern_memorystatus.h`、AppKit `NSWindow.h` 等系统声明。

本项目没有使用 GPL 实现，没有联网下载依赖。AppleSMC/IOReport 属于未稳定公开的接口；系统升级可能改变行为，缺失数据必须显示未知。
