# 上架华为应用市场 · 操作笔记

> 2026-09-17 整理。记录本应用（联文件 / `cn.fhf.linkfiles`）上架过程中的**每一步操作、每个坑、当前状态和待办**。
> 目的是下次（或换人）做的时候不用重新踩一遍。

---

## 一、当前状态速查

| 项 | 状态 |
|---|---|
| 应用名 | **联文件** |
| 包名 | **`cn.fhf.linkfiles`**（上架后**不能改**）|
| 版本 | 1.0.0 (code 1000000) |
| 应用图标 | 分层图标（桌面）+ `icon.png` 216×216（上架上传用）|
| 启动页 | 透明图标 + 底色对齐首页（冷启动零跳变）|
| 发布证书 / Profile | ✅ 已签发（AGC）|
| **可上传的发布包** | ✅ `build/outputs/release/ugreenlink-remote-release-signed.app` |
| 调试包（本地/云调试） | ✅ `entry/build/default/outputs/default/entry-default-signed.hap` |
| **上传 AGC** | ⏳ 待做 |
| APP 备案 / 软著 / 隐私政策 | ⏳ 未办 |
| `deviceTypes` 是否收窄为只留手机 | ⏳ 待定 |
| 审核员如何登录（无 NAS 可连） | ⏳ 待设计 |

---

## 二、环境（换机器时必须对齐）

| 项 | 必须是什么 | 为什么 |
|---|---|---|
| DevEco Studio | **26.0.0 Release（26.0.0.821）** | 见「坑 1」 |
| 工程路径 | **不能有空格**，如 `D:\code\harmony\ugreenlink-remote` | 见「坑 2」 |
| 内置 SDK | releaseType 必须是 **Release** | 同上 |

---

## 三、踩过的坑（都花了时间，别再踩）

### 坑 1 · Beta 版 IDE 打出的包不能上架

上架会报「**请使用发布版本的API开发应用申请上架**」。判据是 **IDE 内置 SDK 的 `releaseType`**，
不是 API 版本。查法：

```bash
cat entry/build/default/outputs/default/pack.info | grep releaseType
```

必须是 `"releaseType":"Release"`。

**⚠️ IDE 的「检查更新」会说"已是最新版本"——那是误报**：内置更新器只在同一通道内比版本，
**Beta 不会自动升到 Release**（两者分开发布）。必须去官网手动下载：
<https://developer.huawei.com/consumer/cn/download/deveco-studio>

### 坑 2 · 工程路径不能有空格

DevEco 只接受字母、数字、`.`、`\`、`_`、`-`。路径里只要有空格就报「**无法打开项目 路径无效**」。
（本工程原来在 `...\lvlian view\ugreenlink-remote`，因为这个报错挪走了。）

### 坑 3 · 改包名会让签名失效（且必须用户自己重做）

包名一变，原来的 Profile 就作废，构建报
`The bundleName in app.json5 does not match the bundleName in the generated SigningConfigs`。

**必须在 DevEco 里**：`File → Project Structure → Project → Signing Configs` → 重新生成签名。
（自动签名要调 AGC 接口、需要账号登录态，别人替不了。）

### 坑 4 · 签名的密码只能由 DevEco 写

`build-profile.json5` 里手写明文密码会被 hvigor 拒绝：
`The length of the storePassword or keyPassword field … is less than 32`
它要的是 **DevEco 加密后的形式**（长度 ≥32 的长串）。
→ **`signingConfigs` 只能通过 DevEco 的「签名配置」界面创建**。

### 坑 5 · DevEco 保存时会重写整个文件

在 DevEco 界面上点「应用」时，它会**重写整个 `build-profile.json5`**，
**手加的 `signingConfigs` 条目会被清掉** ✗（`products` / `applyToProducts` 手加则安全 ✓）。
→ 签名配置一律在界面里建；改完结构记得让 DevEco 重新读一次。

### 坑 6 · 对话框里新建配置必须点「应用」

只点「确定」可能**不落盘**（实测文件没变化）。点完「应用」再点「确定」。

### 坑 7 · ACL 受限权限：声明了不批 = 装不上

`ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` 属于 **ACL 受限权限**（正式名「受限开放权限」）。
官方明确：**「如果应用未申请相应的权限证书，却试图在配置文件中声明此类权限，将会导致应用安装失败」**。

**本应用已经把它删掉了** —— 因为下载落地全程走系统 Picker
（`DocumentViewPicker` + `DocumentPickerMode.DOWNLOAD`），Picker 是逐文件授权，**不需要该权限**。
→ 因此在 AGC 建 Profile 时**「受限ACL权限」不用勾** ✓ 省掉整套申请+审核。

### 坑 8 · 发布包必须在各方面"真的不是调试包"

上架报「当前软件包存在有调试信息，不允许上架发布」时的检查点：
工程级 `products[].buildOption.debuggable`、模块级 `buildOption.debuggable`、
`app.json5` 的 `debug` 字段（**三者都不要设成 true**，本工程三处都没写 ✓ 默认正确）。

**最直接的判据**：解包看 `module.json` 的 `debug` 字段
—— 调试包 `debug:true`、发布包必须 `debug:false`（`releaseType` 两者都是 Release，区分不了）。

---

## 四、发布签名与打包

### 4.1 签名材料（放仓库之外，别放工程里）

```
C:\Users\admin\.ohos\signing\lianwenjian\
├── lianwenjian-release.p12      私钥（唯一不能重新生成，务必单独备份）
├── lianwenjian-release.csr      证书请求文件
├── lianwenjian-release.cer      AGC 签发的发布证书
└── lianwenjian-release.p7b      发布 Profile（绑定 cn.fhf.linkfiles）
```

- 别名（keyAlias）与密钥库密码：**不写在本文件里**。它们只存在于
  `build-profile.json5`（本地、已被 gitignore）和你的密码管理器里。
  别名可以在 DevEco 的签名配置界面看到。
- 生成入口：DevEco → `Build → Generate Key and CSR`
- 有效期建议 ≥25 年

### 4.2 AGC 侧要办的手续

1. **证书**：`证书、APP ID和Profile → 证书 → 新增` → 类型选「**发布证书**」，上传 `.csr` → 得到 `.cer`
2. **APP ID**：`APP ID → 新建` → 应用名称「联文件」，包名 `cn.fhf.linkfiles`
   → 开放能力**一个都不勾**
3. **Profile**：`Profile → 添加` → 类型「**发布**」、绑包名 `cn.fhf.linkfiles`、选该证书
   → **「受限ACL权限」不勾** → 得到 `.p7b`

### 4.3 两套签名并存（工程已配好）

`build-profile.json5` 里：

```json5
"signingConfigs": [
  { "name": "default", ... },   // 调试材料 ~/.ohos/config/default_ugreenlink-remote_*
  { "name": "release", ... }    // 发布材料 ~/.ohos/signing/lianwenjian/lianwenjian-release.*
],
"products": [
  { "name": "default", "signingConfig": "default" },
  { "name": "release", "signingConfig": "release" }
],
"modules": [ { "name": "entry",
  "targets": [ { "name": "default", "applyToProducts": ["default", "release"] } ] } ]
```

### 4.4 打包命令

```bash
export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"
N="C:/Program Files/Huawei/DevEco Studio/tools/node/node.exe"
H="C:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js"

# 发布包（上架用）：先编 HAP，再打 .app —— 分两步，模式不能混
"$N" "$H" --mode module  -p product=release -p buildMode=release assembleHap
"$N" "$H" --mode project -p product=release -p buildMode=release assembleApp
# → build/outputs/release/ugreenlink-remote-release-signed.app

# 调试包（本地安装 / 云调试用）
"$N" "$H" --mode module -p product=default -p buildMode=debug assembleHap
# → entry/build/default/outputs/default/entry-default-signed.hap
```

**注意事项**：
- `--mode project` **没有** `assembleHap` 任务；`assembleApp` 也**不会自动先编 HAP**（会报 `No HAP found for the APP`）
- 产物自动分目录：`entry/build/release/` 与 `entry/build/default/`、`build/outputs/release/` 与 `build/outputs/default/`
- 换 IDE / 改配置后先清 `entry/build` 和 `.hvigor`，避免混用缓存

**验收判据**（每次出包都查）：

| 检查 | 发布包 | 调试包 |
|---|---|---|
| `module.json` 的 `debug` | **false** | true |
| `pack.info` 的 `releaseType` | Release | Release |
| 体积（参考） | ~1.46 MB | ~3.4 MB |

---

## 五、上传与测试

- **发布包只能用发布证书签、且 hdc 装不了**（报 `INSTALL_FAILED_APP_SOURCE_NOT_TRUSTED`）。
  发布证书的包**只能走 AGC 的邀请测试或正式上架**。
- **邀请测试也必须用发布证书** ✓（正好现在就是）。
- 本地调试 / 云调试**必须用调试包**（`debug:true`）。

### 华为「云调试」（远程真机）

官方提供，有**免费体验时长**，支持 **2in1（matebook pro）/ 平板**等形态，
可在云端远程操作真机 —— 适合**验证平板/2in1 上的实际效果**，决定 `deviceTypes` 要不要收窄。
入口在 AGC 的测试/质量类分类下。

⚠️ 两个已知坑：① release 包容易装不上，**要用调试 `.hap`**；
② 云设备 SDK 低于应用要求时报 `older sdk version in the device`（本工程 targetSdk 26）。

---

## 六、待办清单

- [ ] **上传 `.app` 到 AGC 走邀请测试**，自己装一遍跑完整流程
- [ ] 上云调试看**平板 / 2in1**效果 → 决定 `deviceTypes` 是否收窄为只留 `phone`
- [ ] 想清楚**审核员怎么登录**：本应用必须连用户自己的 NAS，审核员没有设备
      → 提交时附测试账号，或在应用里做演示模式（**这是最容易驳回的点**）
- [ ] **隐私政策**链接（AGC 提交必填）
- [ ] **实名认证 / 开发者账号**（个人开发者另需《个人开发者承诺函》）
- [ ] **APP 备案**：要填「APP 解析到的域名」，目前**没有域名** → 建议先问华为客服确认是否适用
- [ ] **电子版权认证**（10~15 工作日）：不是必须，但可用来占住「联文件」这个名字
      （AGC 会校验应用名是否已被他人软著占用）
- [ ] 应用名称必须三方一致：备案系统 / 软著证书 / AGC 上传名

---

## 七、安全提醒

- **`.p12` 是唯一不能重新生成的文件**：丢了要吊销证书重签、已发布用户全受影响。**单独备份**。
- **密码与密钥文件分开保存**（放一起等于没加密）。
- 仓库 `.gitignore` 已加入 `*.p12 / *.csr / *.cer / *.p7b / *.keystore / *.jks` 作为兜底，
  **但这是防手滑，不是主防线** —— 签名材料本身要放在仓库之外。
