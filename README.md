# MFan

面向 **macOS 13+、Intel Mac、Swift 5.8 / SwiftPM** 的原生 SwiftUI 风扇控制界面。SMC 接口具有试验性，机型和固件差异可能导致读取或控制失败；不声称支持全部 Intel Mac。

**不支持 Apple Silicon（包括 Rosetta）和无风扇机型。不能替代硬件热保护。无需关闭 SIP；请保持系统安全机制开启。** 不安装开机自启或永久常驻 root 服务；风扇控制时会按需启动一个受限、自动超时的临时 root 服务。

## 项目结构

- `Sources/MFan`：菜单栏界面、后台只读轮询、管理员授权、socket 客户端与独立心跳。
- `Sources/FanCore`：SMC 读写、控制协议与支持休眠的心跳租期。
- `Sources/fanctl`：独立 CLI 和临时控制服务，保存本会话的风扇恢复状态。
- `Tests`：命令队列、socket 通信、模拟硬件及模拟休眠/心跳测试，不写真实 SMC。
- `scripts/build-app.sh`：release 构建及 `.app` 打包，可选 ad-hoc 签名。

GUI 仅使用以下公开接口读取数据，不直接写 SMC：

```swift
public struct FanSnapshot: Codable, Identifiable {
    public var id: Int
    public var currentRPM: Double
    public var minimumRPM: Double
    public var maximumRPM: Double
    public var targetRPM: Double?
    public var isManual: Bool?
}

public final class SMCClient {
    public init() throws
    public func fans() throws -> [FanSnapshot]
}
```

## 构建与运行

在 Intel Mac 上安装支持 macOS 13 部署目标的 Xcode，确认 `swift --version`。在项目根目录运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh scripts/build-app.sh --adhoc-sign
open dist/MFan.app
```

可选本地 ad-hoc 签名：

```sh
sh scripts/build-app.sh --adhoc-sign
```

脚本分别执行 `swift build -c release --arch x86_64 --product MFan` 和 `--product fanctl`，从 SwiftPM 获取产物目录，打包到：

```text
dist/MFan.app/
  Contents/
    Info.plist           # LSMinimumSystemVersion = 13.0
    MacOS/
      MFan
      fanctl
```

成功打包会替换已有的 `dist/MFan.app`。这是菜单栏托盘应用，不显示普通主窗口，也不会显示 Dock 图标；点击菜单栏风扇图标即可控制。更新应用前，请先等正在运行的 CLI 会话结束，再退出旧应用。ad-hoc 签名只用于本地完整性检查，不是 Developer ID 签名或 Apple 公证，也不保证通过 Gatekeeper。不要对来源不可信的应用进行管理员授权。

## 读取与控制

- 轮询间隔可在菜单底部选择（3/5/10/15/30 秒，默认 5 秒），保存到用户偏好并即时生效；切换后立即重新读取。SMC 读取始终在后台串行队列执行，读取中不会堆叠。
- 菜单栏图标旁的文字可选显示风扇转速、CPU 温度、电池温度或倒计时，设置保存在用户偏好；电池温度使用电池图标，机型未提供电池温度时显示 `--°`。CPU 温度按 CPU Die、CPU Proximity、CPU Core 的顺序选择可用传感器。倒计时模式在限时控制期间显示剩余秒数，并临时按 1Hz 更新；控制到期或没有活动倒计时后，在风扇转速与 CPU 温度之间按当前选择的轮询间隔轮换（缺少 CPU 温度传感器时显示 `--°`）。轮询间隔设置重启后仍生效。支持显示 CPU、GPU、散热器、内存、电池等实际存在的传感器。不同 Intel 机型的传感器键不同，缺失传感器会跳过，不会伪造数据，也不会因此阻断风扇读数。失败显示实际错误并清除显示中的旧风扇读数。
- 空风扇列表明确提示没有报告风扇；读取失败时不推断为无风扇型号。
- RPM 控件使用 100 RPM 步进并限制在整数上下限内；服务将有限数值请求夹到原最低转速…硬件最大转速，不再用瞬时实测转速抬高目标。实测转速稍高于上限（例如上限 6200，读到 6250）不会阻止设定。无效硬件范围、NaN/Infinity 仍拒绝。没有 `F<n>Md` 的机型只能调整最低转速，系统仍可调得更高；服务始终保存首次设定前的最低值，后续可降低自己的临时最低值但不会低于原值。GUI 通过服务响应同步这个原下限，避免滑块被临时最低值锁住。
- 期限可选择“不限时”或 30–600 秒（30 秒步进）。首次点击“设定”或“恢复自动”时，以独立 `/usr/bin/osascript` 子进程运行 `do shell script … with administrator privileges`，在后台启动当前 app `Contents/MacOS` 内的临时 `fanctl serve`。路径及参数经过 shell 引用，并对 AppleScript 字符串转义；不通过 PATH 查找 CLI。
- GUI 本身不以 root 身份运行。第一次执行风扇设定或恢复自动时，通过一次 `osascript` 管理员授权在后台启动受限的 `fanctl serve` 本地 Unix socket 服务；之后本次运行期间的控制请求复用该服务，不再每次弹授权。socket 使用短随机路径 `/tmp/mfan-UUID`（避免 macOS Unix socket 路径长度限制）。服务接受 `ping`、`heartbeat`、`set`、`auto`、`shutdown` 请求；60 秒清醒时间内未收到明确的 `heartbeat` 就尝试恢复风扇并退出。当前本地 socket 通信没有代码签名身份校验，不应当作已完成安全审计的系统特权 Helper。授权服务不可用时显示错误，不会静默降级为未经授权的 SMC 写入。
- GUI 服务协议中的 `seconds = 0` 表示不限时（独立 CLI `fanctl set` 仍只接受 30–600 秒）：保持手动目标转速或临时提高后的最低转速，直到恢复自动、MFan 正常退出或心跳超时才尝试恢复。普通 30–600 秒会话由服务后台计时恢复；写入成功立即返回，GUI 只在授权/请求期间短暂 busy，不等待整个期限。可随时恢复自动或重新设定更低的转速；同一风扇的新设定替换旧期限，不限时取消旧期限，恢复自动取消计时。不同风扇独立计时。成功回复仅表示设定完成，不表示期限结束或已恢复。
- 界面显示请求的期限。**等待授权的时间不计入 CLI 期限**；当前 AppleScript 子进程接口无法通知 GUI 精确的 CLI 启动时刻，因此不显示虚假的倒计时或保证恢复时间。
- 限时或不限时控制中均可通过已授权服务恢复自动；服务会还原自己保存的原最低转速。独立 CLI 的 `auto` 无法恢复其他进程保存的最低值。服务退出后，下次主动控制才重新请求授权；心跳失败不会自动弹授权或重放控制命令。
- “启动设定”会将当前风扇和 RPM 保存在当前用户偏好中；下次打开 MFan 并成功读到风扇后自动应用一次不限时设定。它不是登录项，不会在后台单独启动 MFan；可用“取消启动设定”清除。命令正常返回后立即请求刷新；GUI 不把“命令正常返回”等同于已验证硬件恢复。

### CLI 约定

| 命令 | 行为 |
| --- | --- |
| `fanctl status` | 输出风扇状态 JSON；GUI 不调用此命令，而是使用 FanCore 只读 API |
| `fanctl set <fan ID> <RPM> <seconds>` | 需要 root；seconds 为 30–600；将请求夹到硬件上下限；独立 CLI 仍在前台等待期限并负责恢复（不用于 GUI 控制）；有 `F<n>Md` 键时使用手动目标转速；没有该键时暂时提高 `F<n>Mn`，期限结束恢复原最低值（系统仍自动调速） |
| `fanctl auto` | 需要 root；无参数时处理全部风扇，或指定 `fanctl auto <fan ID>`。有 `F<n>Md` 时写 0 恢复自动；没有该键时不写 SMC，报告该风扇由系统自动调速。它不恢复 `F<n>Mn`；限时 `set` 会话负责恢复自己保存的原最低值 |

可在没有其他控制会话时查看 CLI 状态：

```sh
dist/MFan.app/Contents/MacOS/fanctl status
```

**不要同时从终端、另一应用实例或其他风扇工具执行控制命令。** GUI busy 锁仅保护本实例；跨进程互斥需要 CLI / 后端实现，特别是防止 `auto` 与存活的 `set` 会话冲突。

### 心跳与系统休眠

- 心跳独立于 SMC 轮询，每 10 秒发送一次；不依赖菜单是否展开或风扇读取成功。每次最多一个在途心跳，连接/响应超时约 3 秒，不积压任务。连接服务期间申请允许系统空闲休眠的 activity，避免隐藏的菜单栏应用因 App Nap 延迟心跳；不会阻止正常休眠。
- 服务启动后即开始 60 秒租期，只有有效 `heartbeat` 续期；`ping`、控制命令、连接及无效请求均不续期。
- 心跳使用 `mach_absolute_time` 的清醒时间，休眠不消耗租期，也不受修改系统日期影响。通过与 `mach_continuous_time` 比较检测休眠，唤醒后至少留 30 秒宽限，面板收到唤醒通知立即发送心跳。不会为了心跳唤醒电脑。
- 限时设定的期限则包含休眠：若休眠期间到期，服务在唤醒后尝试恢复。不限时设定不会仅因正常休眠就退出；唤醒后面板仍失联才按心跳期限退出。
- 限时到期恢复失败时写日志，并通过后续心跳响应向面板报告（通常 10 秒内）；保留原恢复值，每 5 秒清醒时间再尝试一次；期间拒绝该风扇的新 `set`，但仍接受心跳、`auto` 和 `shutdown`。心跳超时仍会尝试恢复并退出，不因硬件持续报错而无限常驻。
- 以上时序已做模拟时钟与本地 socket 测试；仍需在目标机实测整机休眠/唤醒。系统杀进程或 SMC 拒绝写入时无法保证恢复，失败会写入服务日志。

## 退出与安全边界

通过面板正常退出会发送 `shutdown`，服务先尝试恢复自己修改过的风扇再退出。GUI 崩溃、强退或卡死时，由仍存活的服务在心跳超时后尝试恢复并退出。不要强杀 `fanctl` 或直接删除活跃 socket：这会绕过恢复流程。独立 CLI 限时会话不使用面板心跳。

期限恢复依赖后端正确实现和 CLI 持续运行；强制杀进程、崩溃、系统异常或硬件拒绝操作时，不能承诺按时恢复。若会话报错，请核对状态；确认原 CLI 已退出后可通过“恢复自动控制”重新授权恢复。持续异常应停止使用并排查机型兼容性，不应关闭 SIP 或绕过硬件保护。

此工具只显示 SMC 提供的内部温度，不根据温度自动制定散热策略，也不提供热安全保证。提高转速也不意味着设备在任何负载下都安全。

## 验证说明

运行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` 可验证命令队列、socket 通信、心跳续租/超时、模拟休眠、恢复失败重试及 socket 清理。构建与测试应串行执行，避免 SwiftPM 构建数据库冲突。这些测试使用模拟硬件，不能证明具体机型支持或真实授权/休眠流程可靠；仍需在目标 Intel Mac 上实测。

更新旧版时先通过旧面板恢复并退出，再启动 `dist/MFan.app`；不要直接强杀保存着原最低转速的服务。使用 `ps -axww | grep '[f]anctl.*serve'` 检查实际服务命令，新版应使用 `/tmp/mfan-UUID`，而不是过长的 `/var/folders/.../control-UUID.sock`。已启动的旧进程不会因为重新打包而自动升级。
