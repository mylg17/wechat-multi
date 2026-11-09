# 微信多开 for macOS

在 macOS 上无限多开微信（WeChat）的脚本 —— 单文件、免安装、不注入、不修改微信本体。

实测环境：微信 4.1.11 / macOS 26.6（其他版本理论兼容，欢迎提 issue 反馈）。

> 微信 4.x 收紧了多开限制，网上流传的老办法基本都失效了：
> `open -n` 拉起的第二个进程约 10 秒后被单实例守护终止；
> 只克隆改名（WeChat2.app）同样只多活 10 秒；
> Automator/nohup 等老方案一律无效。本脚本采用「克隆 + 改 Bundle ID + 重签名」方案，
> 已在本机实测稳定双开。

## 使用方法

```bash
# 下载
git clone https://github.com/mylg17/wechat-multi.git
cd wechat-multi

# 授权执行
chmod +x wechat-multi.sh

# 多开 1 个微信（默认）
./wechat-multi.sh

# 多开 3 个
./wechat-multi.sh 3

# 查看当前正在运行的微信实例数
./wechat-multi.sh -s

# 清理克隆出来的副本应用
./wechat-multi.sh -c
```

首次运行会克隆并重签名（约需几十秒），之后复用已有副本，秒开。启动后每个实例弹出独立登录窗口，分别扫码即可同时在线。

## 工作原理

微信 4.x 的单实例检测 **keyed on Bundle ID + 代码签名**，并且是延迟校验（启动约 10 秒后复查）——这就是为什么只改路径的克隆副本会在 11 秒左右「闪退」。

本脚本对每个新实例：

1. 用 APFS `clonefile` 克隆一份副本（`WeChat2.app`、`WeChat3.app` …，秒级完成、实际净增磁盘占用接近 0，`du`/Finder 显示的 1.2G 是逻辑大小）
2. 改写副本的 `CFBundleIdentifier`（`com.tencent.xinWeChat2` / `3` / …）——单实例检测从此不再把它认成本体
3. ad-hoc 重签名（`codesign --force --deep --sign -`，改 Info.plist 会破坏原签名，必须重签）
4. 启动后等 15 秒核对进程数确实 +1 且稳定存活，才报告成功

所有改动只发生在副本上，微信本体始终原封不动。

微信升级后（副本版本落后于本体），脚本会自动删除旧副本并按新版重建。

## 注意事项

**副本的数据是独立的**
副本 Bundle ID 不同，所以 macOS 沙盒给它分配了独立的数据容器（`~/Library/Containers/com.tencent.xinWeChat2` …）。每个实例都是全新微信，各自扫码各自的账号，聊天记录互不混、互不通——对双开两个不同账号来说更干净，但**同一账号的记录不会同步显示在多个实例里**。

**首次运行可能弹出安全提示**
个别系统配置下，ad-hoc 签名的应用首次启动会被拦。若发生，到「系统设置 → 隐私与安全性」点「仍要打开」即可（副本继承本体属性、不带隔离标记，多数机器不会遇到）。

**副本图标与本体相同**
Dock 里多个微信图标长得一样，鼠标悬停或 ⌘Tab 可区分。

**会封号吗？**
多开本身是 macOS 系统层面的能力，脚本不注入、不碰微信进程内部。但因第三方方式多开导致账号被限制的风险需自行承担，请遵守微信软件许可及服务协议。

**支持企业微信吗？**
不支持。思路相同（改 Bundle ID + 重签），可自行改造，未做验证。

## 环境要求

- **macOS 12 (Monterey) 及以上** —— 这是微信 4.x 本身的最低系统要求，装不了微信 4.x 的系统本方案无从谈起（10.13~11 上的微信 3.x 用 `open -n` 即可多开，无需本脚本）
- 已安装官方微信客户端
- Xcode 命令行工具（重签名用，系统一般自带；缺了跑 `xcode-select --install`）

## 参考

思路与社区方案一致，特别参考：

- [DualWeChat（macOS 微信双开工具）](https://github.com/MaiwulanjiangMaiming/DualWeChat)
- [新版本微信 macOS 最新多开方法 (4.0+) - 设计笔记](https://www.shejibiji.com/archives/9859)
- [mac 微信 v4 以上客户端多开教程 - CSDN](https://blog.csdn.net/qq_36278221/article/details/155978981)

## License

[MIT](LICENSE)
