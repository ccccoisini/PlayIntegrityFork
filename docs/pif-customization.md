# PlayIntegrityFix 定制说明（inject-s-auto1）

基于 `KOWX712/PlayIntegrityFix` 的 **inject-s v4.7-1**（inject_s 分支）定制，目标是
**"安装即可使用"**：刷入模块后无需任何手工配置，指纹自动生成/保鲜，并与 TEESimulator-RS
自动对齐 security patch。

## 一、定制内容

### 1. 安装时自动配置（`module/customize.sh` 追加块）

- **启用 TrickyStore 同步标志**：`touch /data/adb/tricky_store/pif_auto_security_patch`
  —— autopif.sh 生成新指纹后会自动调用 `security_patch.sh`，把指纹的 `SECURITY_PATCH`
  写入 `/data/adb/tricky_store/security_patch.txt`（TEESimulator 的证书链补丁级来源）。
- **立即生成新指纹**（best effort）：执行 `sh $MODPATH/autopif.sh`，输出留在
  `$MODPATH/autopif_install.log`。离线安装时失败不中断，回落到模块自带的 pif.prop，
  并由 service.sh 在下次开机重试。
- KSU/APatch 环境自动把 `/data/adb/ksu/bin`、`/data/adb/ap/bin` 加入 PATH（busybox 所需）。

### 2. 开机自动保鲜（`module/service.sh` 追加块）

- 新增 `pif_fingerprint_stale <file> [days=35]`（`common_func.sh` 逻辑内联在 service.sh）：
  从 `FINGERPRINT=` 行解析构建日期（Canary 构建号里的 `YYMMDD`，如 `ZP11.260821.010` →
  `2026-08-21`），换算天数，超过 **35 天**（Canary 约 6 周过期）判为过期。
- 开机（`sys.boot_completed=1` 后）：
  - `/data/adb/pif.prop` 不存在 **或** 指纹过期 → 重跑 `autopif.sh`；
  - 每次结果（成功/失败/无需刷新）追加记录到 `$MODPATH/autopif_boot.log`；
  - 重新激活 TrickyStore 同步标志（幂等）。
- autopif.sh 自身会在成功后 **kill GMS + Play Store**，新指纹即时生效，无需重启整机。
- 离线开机：保留现有配置不动，下次开机重试。

### 3. 运行时配置优先级（上游既有逻辑，未改动）

`/data/adb/pif.prop`（autopif 生成的"当前指纹"）优先于模块目录内的 `pif.prop`（出厂回落），
见 `zygisk/src/main/cpp/zygisk.cpp:24-25,125-128`。

### 4. 去除上游自动更新（`module/module.prop`）

删除了 `updateJson=...@inject_s/update.json` 行——避免 root 管理器的更新器把定制版静默
替换为上游原版（定制内容会丢失）。如需恢复上游更新，把该行加回即可。

### 5. 版本标识

`version=v4.7-1-inject-s-auto1`，`versionCode=472`。

## 二、与 TEESimulator-RS 的配合

| 组件 | 职责 |
|---|---|
| PlayIntegrityFix (inject) | GMS / Play Store 进程内伪造 Build 字段（FINGERPRINT、SECURITY_PATCH 等） |
| TEESimulator-RS (tricky_store) | keystore2 硬件证明层：keybox 伪造证书链 + 补丁级注入 |

两层必须一致，否则服务端评估判红（已在真机验证）。本定制通过 `pif_auto_security_patch`
标志 + `security_patch.sh` 自动保持一致：

- `security_patch.txt` 内容形如：
  ```
  system=202610
  boot=2026-09-05
  vendor=2026-09-05
  ```
  （TEESimulator 同时接受 `YYYY-MM-DD` / `YYYYMMDD` / `YYYYMM`，见其
  `AndroidDeviceUtils.parsePatchLevelValue`。）

## 三、编译

```sh
cd PlayIntegrityFix
git submodule update --init --recursive            # Dobby + local_cxa_atexit_finalize_impl
export JAVA_HOME=~/toolchain/jdk-21.0.12.1+1
export ANDROID_HOME=~/android-sdk                  # 需 NDK 29.x + cmake ≥ 3.30.5
./gradlew --no-daemon :zygisk:assembleRelease copyZygiskFiles zip
# 产物：out/PlayIntegrityFix.zip
```

注意：该工程用 **NDK 29.x**（与 TEESimulator 的 27.3 不同，两者可并存）与
**cmake ≥ 3.30.5**（`sdkmanager "cmake;3.31.1"`）。
Gradle 发行版若下载失败，可手工放置到 `~/.gradle/wrapper/dists/gradle-9.7.1-bin/<hash>/`。

## 四、验收清单

1. 刷入后（或重启后）`/data/adb/pif.prop` 存在且 `FINGERPRINT` 为近期 Canary；
2. `$MODPATH/autopif_boot.log` 有 `fingerprint current/refreshed` 记录；
3. `/data/adb/tricky_store/security_patch.txt` 与指纹的 `SECURITY_PATCH` 一致；
4. `logcat | grep "D PIF"` 出现 `Set 'FINGERPRINT' to ...`（注入生效）；
5. `gr.nikolasspyr.integritycheck` → `MEETS_DEVICE_INTEGRITY ✓`
   （BASIC ✗ 为 Android 13+ 移除 legacy 判定后的预期现象）。

## 五、真机验收记录（2026-10-01，172.16.0.170，全新安装）

环境：模块全部卸载后重新安装（TEESimulator-RS v6.0.1-265 + 本定制版 PIF auto1），
配置目录全清（`/data/adb/tricky_store`、`/data/adb/pif.prop` 删除后由安装流程重建）。

| 验收项 | 结果 |
|---|---|
| 两模块 `ksud module install` 后处于激活状态 | ✅（PIF 需手工解压同步，见下） |
| 安装时指纹自动生成（customize.sh 块） | ✅（离线时按设计回落，开机重试成功） |
| 开机指纹保鲜（service.sh 块，35 天阈值） | ✅ 日志记录 `refreshing fingerprint (missing or stale)` → 换到新设备指纹 |
| security_patch.txt 自动对齐（security_patch.sh 修复后） | ✅ `system/boot/vendor = 指纹 SECURITY_PATCH` |
| PIF 注入生效（`D PIF: Set 'FINGERPRINT'...`） | ✅ |
| TEESimulator 守护进程 + 拦截器注册 | ✅ |
| KeyAttestation 硬件证明层 | ✅ 全绿（Google root ✓、Bootloader locked ✓、链签名校验通过） |

**设备侧部署注意**：该 KernelSU 环境的 `ksud module install` 对"覆盖安装/带 update 标记"的场景
只写入 `module.prop` 并置 `modules/<id>/update` 标记（modules_update 为空 → 重启时会被判为删除）。
可靠做法：`unzip -o pif.zip -d /data/adb/modules/playintegrityfix/ && rm -f .../update` 后重启。

**判定时效性说明**：MEETS_DEVICE_INTEGRITY 曾在 frankel_beta 指纹上稳定通过（同日更早时段），
随后在配置完全一致的情况下转为全红（felix/frankel/lynx 三个新 Canary 均红）。autopif 生成的
Canary 指纹是公共资源，会被 Google 持续批量封禁（上游 osm0sis README 明示 "public mass-used
ones may get banned at any time"）；数据中心出口 IP 信誉同样影响评估。这与两层模块的配置无关——
出现全红时先用 `autopif.sh` 换新指纹、间隔数分钟重测，持续全红属 Google 侧风控漂移，需等待或
更换出口。

## 六、全红根因定位与修复（2026-10-01 第二次）

**症状**：`gr.nikolasspyr.integritycheck` 三项全红；raw JSON 显示
`deviceIntegrity` 无 `deviceRecognitionVerdict`，`appRecognitionVerdict` /
`appLicensingVerdict` / `playProtectVerdict` 全为 `UNEVALUATED`
（Google 判定"设备不可信"后直接拒绝评估，而不是评估后给低分）。
换指纹（canary 260821 / canary 260717 / stable CP3A.260905.009）、
对齐三层 patch、系统级 resetprop 伪造 ro.build.* 均无效。

**根因**：TEESimulator-RS **v6.0.1-265** 对"带 attestation challenge 的普通证明请求"
走 PATCH 路径（转交真实硬件），而本机 k85v1_64 只有软件 Keymaster 4.1 →
KeyAttestation 显示 `Attestation: Version: Keymaster 4.1 / Security level: Software`。
Android 13+ 的 MEETS_DEVICE_INTEGRITY 要求硬件级（TEE）证明，因此 Google 直接不评估。
（上游 v6.0.1-280 起才修复 "device-property attestation 的旧门控探测真实 TEE、
拒绝 GMS Play Integrity 硬件路径"；v6.0.1-282 起 AUTO+challenge 改走 FORGE 路径。）

**修复**：
1. 升级 TEESimulator-RS：`ksud module install TEESimulator-RS-v6.0.1-282-Release.zip` + 重启。
   升级后 KeyAttestation 变为 `Version: KeyMint 2.0 / Security level: TrustedEnvironment`
   （NativeCertGen 合成 4 张证书链，Google root ✓、RoT locked/Verified ✓、
   OS/vendor/boot patch = 202609/20260905/20260905 与指纹一致）。
2. 修复本仓库 `module/security_patch.sh` 的 resetprop 门槛：原判断
   `resetprop --help | grep -q "compact"/"rebuild"` 在 KernelSU 的 resetprop 帮助文本中
   永远匹配不到（且帮助输出走 stderr，会泄漏到安装日志），导致换指纹后不重启时
   `ro.build.version.security_patch` / `ro.vendor.build.security_patch` 保持旧值，
   形成 GMS(Java Build) / 原生 props / TEESimulator attestation 三层 patch 不一致。
   改为 `command -v resetprop` 存在即执行 `-n` 写入，`-c` 缓存刷新尽力而为。

**修复后验收（2026-10-01 11:27 / 11:38，stable `google/husky/husky:17/CP3A.260905.009/16091614`）**：

| 项 | 结果 |
|---|---|
| MEETS_DEVICE_INTEGRITY | ✅ Pass（JSON: `deviceRecognitionVerdict=["MEETS_DEVICE_INTEGRITY"]`，`appRecognitionVerdict=PLAY_RECOGNIZED`） |
| MEETS_BASIC_INTEGRITY | ✗（与第五节验收记录相同的预期现象） |
| MEETS_STRONG_INTEGRITY | ✗（需未吊销 keybox / StrongBox，本环境不具备） |
| appLicensingVerdict / playProtectVerdict | `UNEVALUATED`（设备未登录 Google 账号，Accounts: 0） |

**修订第五节结论**：当时的"指纹被批量封禁 / 数据中心 IP 风控漂移"判断并非本次全红的根因；
根因即上述证明安全级别问题。指纹封禁、出口 IP 仍是真实存在的次级风险，
但排查顺序应为：先看 KeyAttestation 的 `Security level` 是否为 TEE，再看 raw JSON 是否 UNEVALUATED。

## 七、默认指纹改为 stable，安装即通过（2026-10-01）

- `module/pif.prop` 默认改为已验证的 stable 指纹
  `google/husky/husky:17/CP3A.260905.009/16091614:user/release-keys`（Pixel 8 Pro，
  SECURITY_PATCH=2026-09-05），不再随安装拉取随机 Pixel Canary。
- `customize.sh`：安装时把 shipped pif.prop 写入 `/data/adb/pif.prop`（仅当缺失或当前为
  `:CANARY/` 指纹时覆盖；已有的非 canary 配置保留），随后立即执行 `security_patch.sh`
  完成三层 patch 对齐；`autopif.sh` 保留为手动刷新入口。
- `service.sh`：开机先用 shipped 默认补齐缺失的 `/data/adb/pif.prop`；35 天过期刷新仅对
  **canary** 指纹生效，stable 指纹永不被自动替换。
- 验收（2026-10-01 17:26–17:28 EDT）：删除 `/data/adb/pif.prop` 模拟全新安装 → 开机日志
  `[+] seeded /data/adb/pif.prop from shipped stable fingerprint` → 三层 patch=2026-09-05 →
  `MEETS_DEVICE_INTEGRITY` ✓（与第六节相同的配套要求：TEESimulator-RS ≥ v6.0.1-572 /
  上游 307 线，硬件级证明）。
