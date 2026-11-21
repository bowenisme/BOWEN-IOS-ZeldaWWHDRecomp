# iPhone / iPad 移植

基于 [ZeldaWWHDRecomp](https://github.com/ZeldaWWHDRecomp/ZeldaWWHDRecomp)，使用 UIKit、Metal、GameController 和静态 ARM64 重编译。当前为开发版本。

## 支持情况

- 构建目标：ARM64、iOS/iPadOS 17 以上、iPhone 与 iPad、横屏。
- 构建目标不等于机型验证通过。4 GiB **虚拟地址保留**不等于占用 4 GiB 物理内存；实际内存上限、固定基址分配、Metal 资源及驱动兼容性仍须逐机验证。
- 30 FPS / 60 FPS 插值。60 FPS 插值保持原版 30 Hz 游戏逻辑，不是 60 Hz 逻辑；没有 120 FPS 设置。
- iOS 60 Hz 插值在昂贵的场景过渡后会重新探测中间帧耗时；首次验证较慢时短暂重试，确认持续较慢后退避，避免每秒重复绘制慢帧。该恢复策略仍待目标 iPad 实测，不能据此声称室内帧率已经改善。
- 首次启动默认 1× 内部分辨率，已有原生画质偏好保留。原生画质根据当前窗口像素及游戏画面比例计算；iPhone 的游戏画布避开刘海及 Home 区域，iPad 保留全画布，设置和触屏按键使用安全区域。
- 触屏：左侧浮动摇杆移动、右侧滑动转镜头，动作/攻击、道具、锁定/防御与菜单支持多指组合。未保存过触屏显示偏好时默认显示按键；设置可选自动/显示/隐藏。自动模式在连接完整实体手柄后隐藏，断开后恢复。GamePad 小窗与全屏触摸按实际画面矩形路由，虚拟按键避让副屏。
- 在“航海设置 → 自定义触屏布局与键位”拖动按钮、调整大小及绑定原版按键；移动摇杆响应与镜头灵敏度可分别设为 0.5×～2×，保存在本机，可恢复默认。响应倍率不修改游戏运行速度。编辑期间屏蔽游戏输入；建议先在原版暂停菜单中编辑。
- 实体手柄复用上游 GameController 输入与游戏内图标：PlayStation 的 ○/×/△/□、L1/R1/L2/R2，Xbox 的 A/B/X/Y、LB/RB/LT/RT；其他手柄按系统报告的标签识别。无需新增映射流程。多个同时连接的手柄沿用上游“首个仍连接的手柄”图标选择策略。
- 普通游戏存档与三个完整即时存档相互独立。完整即时存档要求当前进程的线程生命周期、等待位置和调用栈与存档匹配；即使没有更新应用，退出后重开或在不同场景读档也可能被拒绝，跨启动恢复尚未验证可靠。跨构建兼容同样不保证，重要进度仍应使用游戏内存档。
- 即时存档恢复只在目标线程已退出、当前线程身份与等待位置匹配时发送原游戏 quit 消息，让线程正常结束，再重新执行全部恢复校验；不会伪造退出状态，也不会放宽其他线程的 LR、栈与等待位置检查。恢复仍受线程生命周期、场景和构建版本限制；退出后重开或在不同场景读档都可能被拒绝，重要进度应使用游戏内存档。
- iPad 光追反射已移除：设置中不再提供开关，旧偏好和启动覆盖也不能启用该路径。

## 游戏模式与分类

iOS 包同时声明 [`LSSupportsGameMode = YES`](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode) 与 `GCSupportsGameMode = YES`。后者已被 Apple [标为弃用](https://developer.apple.com/documentation/bundleresources/information-property-list/gcsupportsgamemode)，这里为兼容最低部署目标 iOS 17 上、尤其 iOS 18 的 Game Mode 识别而保留，不能替代当前 key。包还设置 `LSApplicationCategoryType = public.app-category.games`，明确标识其游戏类别；虽然 Apple 的[一般 Launch Services 参考](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html)将此键标为 macOS，Apple DTS 在[针对 iOS Game Mode 的答复](https://developer.apple.com/forums/thread/764575)中说明系统会参考它。此声明仅请求/提供游戏模式与类别信息，实际开关仍由系统和用户设置控制；玩家可在[游戏覆盖层](https://support.apple.com/105118)手动关闭此游戏的 Game Mode，应用声明不会覆盖该选择。此打包改动与游戏内进房间或对话闪退无关，也不代表该问题已修复。

本项目的 iOS 应用商店分类意图为 **Games**。正式 App Store 上架的 iOS 分类仍由 [App Store Connect 分类元数据](https://developer.apple.com/app-store/categories/)管理；本 plist 的游戏类别键不替代商店后台设置。

## 从源码构建

准备 Mac、带 iOS 17 SDK 的 Xcode、Python 3、CMake，以及自己的 Xcode 签名账号。具体设备兼容性需单独验证。

自行准备与上游支持版本一致、未经修改的 USA/EUR v0 游戏目录：

```text
game/code/cking.rpx
game/content/
game/meta/
```

先校验，再构建。游戏目录、Team ID 和 Bundle ID 都必须由构建者自行提供；脚本不会默认读取仓库中的 `game/`，也不会替你选择签名身份：

```sh
GAME_DIR="/path/to/your/original/game"
python3 ios/build.py --check-game --game "$GAME_DIR"
python3 ios/build.py --game "$GAME_DIR" --team YOUR_TEAM_ID --bundle-id org.example.wwhd
```

只编译运行时、检查源码构建链路且不使用游戏文件或签名账号时，可运行 `python3 ios/build.py --stub`。它用 stub 代码生成器，不含游戏代码；产物未签名，不能安装或游玩。正式应用构建会从 `--game` 指定目录现场生成重编译 C 源码，要求原版、未修改的 USA/EUR v0 RPX。构建输出位于 `build/ios-game/RelWithDebInfo-iphoneos/wwhd.app` 或 `build/ios-stub` 下的对应 Xcode 配置目录。`build/` 中的生成代码、Xcode 工程与缓存均为本机产物，不属于源码发布内容；已有 generated-project fallback 或旧构建缓存不证明干净源码可复现构建成功。

签名安装后，通过 Xcode 或文件共享将同版本完整游戏目录放入应用 `Documents/game`。普通存档位于 `Documents/save`；不要用重装或删除应用来处理存档兼容性问题。

后续仅修改运行时代码时，可在同一构建者的本地生成工程中增量构建。将下例的 Team ID 换成自己的值，并继续使用首次构建时的 Bundle ID：

```sh
xcodebuild -project build/ios-game/wwhd_recomp.xcodeproj -scheme wwhd \
  -configuration RelWithDebInfo -destination 'generic/platform=iOS' \
  -jobs 4 DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates build
```

已有安装如需保留存档容器，继续使用该安装的 Bundle ID。中文可由用户从[汉化项目页面](https://github.com/wmltogether/ZLD-TWW-HD-Chinese-Localization-Project)自行取得 v1.0.2 发布包，再运行 `python3 ios/prepare_chinese.py PACKAGE.zip MOD_DIRECTORY` 在本机生成内容 mod。使用时遵循该项目页面说明；汉化资源的再分发许可须另行确认。源码包不包含汉化发布包或生成的 mod，也不得修改用于重编译校验的原始 RPX。

## GamePad 提示画面与手柄体感

单屏设备在游戏控制器切换期间也显示 GamePad 小屏。原游戏 Options 内切换控制器时，iOS 输入会跟随明确的游戏切换过程；完整即时存档恢复与宿主主动切换仍保持原有优先级。宿主切到 GamePad、原游戏还处于 Pro 菜单时，旧 Pro 输入保持可操作，直到游戏完成切换。

若出现“请查看 GamePad”提示，可在本版本航海设置中将 **GamePad 屏幕**改为“小窗”或“全屏”，直接查看并触摸副屏；“自动”恢复自动显示。

**手柄陀螺仪**开关接入已有 GameController 体感与游戏 VPAD 管线，支持 GamePad 和 Pro 模式中的体感瞄准。是否可用取决于系统实际报告的旋转传感器能力（[Apple GCMotion](https://developer.apple.com/documentation/gamecontroller/gcmotion)），没有传感器的手柄继续使用普通按键。原游戏选项也须开启体感；瞄准时松开右摇杆，需要时点击“体感重新校准”并静置手柄。设置面板和后台不向游戏传递体感样本。

真实游戏切换流程、PS 手柄轴向/漂移以及复位手感仍待目标设备验证。

## 画面比例与分辨率

画面设置分为两个独立选项，可任意组合：

| 选项 | 作用 |
| --- | --- |
| 画面比例：适配屏幕 / 原始 16:9 | 改变视野和布局；保留 16:9 时按比例留黑边，不拉伸 |
| 渲染分辨率：标准（1×，省性能）/ 屏幕原生 | 决定内部像素数量；标准档放大显示，原生档以实际游戏画布计算 |

低性能机型默认使用“适配屏幕 + 标准 1×”，不必为了适配屏幕比例启用原生分辨率。例如游戏画布为 2420×1668 时，按比例适配的标准档目标约为 1280×882，原生档约为 2420×1668。原生档受渲染器 1×～4× 倍率限制，小于基础目标的画布仍会下采样显示；设置中的像素值为目标估算，不冒充实际 GPU 纹理读数。原有原生画质偏好保留。

是否能稳定 30/60 FPS 还取决于 CPU、GPU、内存及场景负载；这两档不自动降低游戏速度或改动逻辑帧率。本项目不承诺任何特定 iPhone 机型锁定 60 FPS。

## 本地检查

```sh
clang++ -std=c++20 -Wall -Wextra -Werror -UNDEBUG -Iruntime/src \
  runtime/tools/ios_portability_test.cpp -o /tmp/ios-portability-test
/tmp/ios-portability-test
python3 ios/check_source_release.py --self-test
python3 ios/check_source_release.py
python3 runtime/tools/test_ios_controls_ray_policy.py
```

普通运行不定时落盘性能 JSON。调试时使用 `WWHD_IOS_METRICS_REPORT=1` 输出 `Documents/game-runtime-report.json`，或用 `WWHD_IOS_METRICS_HISTORY=1` 额外记录历史。测试环境变量不要用于正式性能对比；截图、帧转储和光追诊断均会改变负载。

性能界面报告实测显示 FPS、输出 FPS、逻辑 Hz、CPU、Metal 命令耗时及内存。GPU 命令耗时不是硬件总利用率；温度仅使用系统热状态，不编造摄氏度。

Metal 资源更新会合并连续的 blit 操作，在绘制、重采样、读回等待及提交前结束复制批次，不调整游戏命令顺序。用 `WWHD_METAL_ENCODER_STATS=1` 查看复制请求与实际编码器数量；`WWHD_METAL_BLIT_BATCH=0` 可关闭合并作对照，两项均不修改画质或保存设置。完整格式别名同步沿用源内容版本，避免未改动的视图之间来回复制；不同 mip 数量保留原保守路径。

`python3 runtime/tools/test_metal_blit_batch.py` 使用本机 GPU 与 Metal API Validation 验证复制依赖、绘制边界、读回和分块提交；`python3 runtime/tools/test_metal_alias_sync.py` 验证别名版本更新。这些检查不替代 iPad 场景、画质和持续性能验证。

启用移动端函数复用时，管线主缓存未命中后会比较实际 Metal 描述符，包括设备/函数、顶点布局、颜色写掩码和混合、深度/模板格式等字段，仅共享成功的管线对象，保留各自的 guest 绑定元数据。哈希桶仍做完整字段相等比较，失败注入时关闭共享。日志中的 `pipeline compile submissions` 是实际创建提交数，`ready hits` 是避免重复创建的次数；原 `pipelines` 数量包含轻量逻辑记录。运行 `python3 runtime/tools/test_metal_pipeline_reuse.py` 验证描述符分离、碰撞处理与成功对象复用。

## 源码发布

保留根目录 MPL-2.0 及第三方许可和来源。修改过的 MPL 文件发布要求可参阅 [Mozilla 官方说明](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)。

公开仓库只包含移植源码、测试、构建工具和说明。ROM、密钥、用户生成的游戏 C 源码、游戏/汉化内容、完整即时存档、截图、个人签名证书和设备报告不在发布范围内。汉化的资源再分发授权须另外核查；当前仅提供用户本地准备流程。

未提供本地图标时，构建使用上游自绘帆船图（许可说明在 `android/icon/README.md`）。`ios/icons/` 的本地封面图标被忽略，不是公共构建依赖。可通过 `WWHD_IOS_ICON_DIR` 指向自己的本地图标目录。

源码发布候选应按审核过的相对路径白名单组装；`.gitignore` 和 `check_source_release.py` 都不是 ZIP 内容或 Git 历史的完整安全证明。该脚本检查 Git 跟踪文件及未忽略的新文件，不上传文件，也不替代凭据、第三方资源许可与来源审查。游戏生成代码和游戏资源不可作为公开 GitHub Release 附件。

## MetalFX 空间超分（测试版）

设置中的渲染分辨率提供标准 1×、屏幕原生、MetalFX 超分三个选项。超分可选原生目标约 60% / 65% / 70% / 75% / 80% / 85% / 90% 边长（默认 80%，约 64% 像素数量，最低 1×）渲染，先做 FXAA 边缘平滑，再重建到实际 TV 画面所在的屏幕区域；GamePad 小屏幕和宿主控件在后续合成。性能信息分别记录内部渲染尺寸与超分输出尺寸，重建输出不等于原生分辨率渲染。

运行时检测设备支持，初始化或资源创建失败会回退普通放大并显示原因；关闭时沿用原呈现路径。`WWHD_METALFX=1/0` 仅为当前测试进程覆盖超分请求，不保存用户选择。实际画质、帧率和热稳定性需在目标设备验证。

## 运行效率与设置页

设置按“画面 / 操控 / 辅助 / 存档”分类，各页保留自己的滚动位置。性能数据更新只刷新可见的 HUD / 详情；设置关闭时不查询存档或加载缩略图。

“辅助 → 游戏时长”显示累计游玩与本次游玩时长。从支持此功能的版本开始记录游戏运行后的前台真实时间，包含菜单与剧情；非活跃/后台暂停，快进不放大计时。累计秒数独立保存在本机 `ios.playTimeSeconds`，不随即时读档回退，每 30 秒及离开前台时写入；异常强退可能丢失最近约 30 秒。本次时长在重新启动应用时归零，旧版本的历史时长无法补算。

iOS 默认关闭内部高级渲染分析器，原生性能 HUD 仍独立按需采样。开发诊断可用 `WWHD_PROFILE=1` 显式开启；桌面端原有默认行为保留。Metal 的单次 draw 复用普通单 mip 纹理的预解析结果，反馈、attachment alias 和 mip-chain 情况保持保守路径。shader dirty mask 试验未显示设备净收益，已撤回并保留实验记录。

iOS 仅按当前实际绘制需要编译着色器和渲染管线，不回放历史 shader recipe 或 head-start 大包，也不继续追加该历史文件。旧缓存文件保留，游戏文件、游戏存档与即时存档不变；系统 Metal 编译缓存和当前进程内的函数复用仍可使用。此策略避免将历史记录中的数十万条配置逐步实例化为常驻 GPU/CPU 对象而耗尽移动设备内存；新场景首次遇到的着色器仍可能有编译等待。桌面端的预热行为保持原状。

呈现使用当前有效帧率对应的最小显示时长，减少 ProMotion 上的短促补帧；原游戏逻辑时钟与快进倍率保持各自的调度。开发对照可通过 `WWHD_IOS_PRESENT_DURATION=0` 使用原呈现方式。Metal 编译阶段复用同设备、同编译选项、完整 MSL 源码相同的已完成函数；故障注入不复用，`WWHD_METAL_FUNCTION_REUSE=0` 可对照。
