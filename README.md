# MFan

面向 **Intel Mac（macOS 13+）** 的轻量菜单栏风扇控制工具，SwiftPM / Swift 5.8 构建。不支持 Apple Silicon（包括 Rosetta）；SMC 接口具有试验性，不声称支持全部机型。

## 功能

- 菜单栏显示风扇转速、CPU / 电池温度或限时控制倒计时，可选轮询间隔（3–30 秒）。
- 每个风扇独立调速：100 RPM 步进，"不限时"或 30–600 秒限时；可随时改转速或恢复自动，无需等待期限结束。
- 转速自动限制在硬件上下限内；没有手动模式键的旧机型通过临时提高最低转速控制，会记住并恢复原值。
- "启动设定"：记住一个风扇和转速，下次打开 MFan 后自动应用一次。"启动设定"与"取消启动设定"并排显示在对应风扇下方，样式一致。
- "规则"：触发条件可以是进程/App（如 UTM）运行、CPU 温度达到阈值，或两者同时满足（进程规则可单独设置触发温度，也可只看温度）。同一风扇上多条规则同时成立时，触发温度取最低、转速取最高；没设温度的规则在进程启动时即触发。温度触发后需回落 5°C 才释放，避免在阈值附近反复切换；读不到 CPU 温度时温度条件不会触发。温度按轮询间隔读取，触发有相应延迟。触发后把所选风扇（或全部风扇）自动设为该规则的转速（不限时，按各风扇上下限截取）。每条规则可指定"全部风扇"或某一个风扇，滑块范围随所选风扇变化。同一风扇被多条规则命中时，该风扇取最高转速；某风扇的规则结束后，该风扇回到启动设定的转速（与启动设定是同一个风扇时）；没有启动设定时才把该风扇交回系统自动控制。其他风扇不受影响。名称不区分大小写，整词匹配，可从运行中的 App 列表选择；也可手动输入命令行进程名（如 ffmpeg）。规则变化时才会触发控制，期间手动设定会保留到规则状态下次变化。
- 内置保养须知（问号按钮）：日常散热建议、清洁注意事项和电池异常提醒。

## 构建与运行

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh scripts/build-app.sh --adhoc-sign
open dist/MFan.app
```

## 工作原理

- GUI 不以 root 运行。首次控制时经一次管理员授权，启动临时 `fanctl serve` 特权服务；之后通过 `/tmp/mfan-UUID` 本地 socket 通信，不再重复授权。
- 服务有独立心跳：GUI 每 10 秒续期，60 秒清醒时间收不到心跳就恢复风扇并退出；系统休眠不消耗租期，限时期限跨休眠仍会到期。
- 正常退出、心跳超时或限时到期时，服务都会先还原自己修改过的风扇。不要强杀 `fanctl` 或删除活跃 socket，这会绕过恢复流程。

## CLI

```sh
dist/MFan.app/Contents/MacOS/fanctl status            # 风扇状态 JSON
dist/MFan.app/Contents/MacOS/fanctl set <fan> <rpm> <seconds>   # 30–600 秒，前台等待并负责恢复
dist/MFan.app/Contents/MacOS/fanctl auto [fan]        # 恢复自动，缺省为全部
```

不要同时从终端和其他工具执行控制命令。

## 开发

- `Sources/MFan`：菜单栏界面、授权与 socket 客户端。
- `Sources/FanCore`：SMC 读写、控制协议与心跳租期。
- `Sources/fanctl`：CLI 与临时特权服务。
- `Tests`：socket 通信、心跳/休眠时序、恢复重试（模拟硬件，不写真实 SMC）。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

构建与测试需串行执行（SwiftPM 构建数据库不支持并行）。更新版本前，先在旧面板恢复自动并正常退出，重新打包不会升级已运行的旧服务。

## 致谢

感谢以下开源项目提供的启发与参考：

- [Stats](https://github.com/exelban/stats)：开源 macOS 系统监控与菜单栏控制面板。
- [MacFanControl](https://github.com/achen4020/MacFanControl)：开源 macOS 风扇控制项目。
