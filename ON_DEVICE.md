# 仅用 iOS 设备编译本插件（On-Device Theos）

> 适用：已越狱的 iOS 12.2 设备（unc0ver / Chimera / checkra1n+Procursus / Odyssey 等均可）。
> 目标：不借助任何 Mac / Linux / Windows 工具链，直接在手机上 `make package` 产出 `.deb`。

## 两种「只用 iOS」的路线

### 路线 A：在手机上直接编译（最推荐，.deb 直接出在手机里）
1. 在 Cydia / Sileo 安装：
   - **NewTerm 2**（终端，repo: https://repo.chariz.com 或 BigBoss）
   - **Theos + 工具链**：
     - 若是 Procursus/Elucubratus（checkra1n/Odyssey/Taurine）：直接装 `theos` 与 `theos-dependencies`
     - 若是 Electra/Chimera 等传统 bootstrap：装 `Theos` + `LLVM+Clang` + `iOS Toolchain`（BigBoss）
2. 把本工程文件夹传到手机：用 **Filza**（iCloud / SMB / WebDAV）或 **Working Copy** 克隆你的 GitHub 仓库。
3. 打开 NewTerm，进入工程目录，运行 `bash build_on_device.sh`。
4. 脚本会自动装/找 Theos、拉 iOS 12 SDK、编译，最后打印 `.deb` 路径（在 `packages/`）。
5. 用 Filza / Sileo 打开该 `.deb` 安装，重启 SpringBoard 即可。

### 路线 B：用 GitHub Actions 在云端编译（手机只负责取结果）
适合不想在手机上装工具链的用户。
1. iOS 上装 **Working Copy**（免费 git 客户端）并登录 GitHub。
2. 在 GitHub App 新建一个空仓库。
3. 用 Working Copy 把本工程推上去（或在任意能上网的电脑推也行）。
4. 仓库里的 `.github/workflows/build.yml` 会自动编译，完成后在 Actions → Artifacts 下载 `.deb`。
5. 手机打开下载的 `.deb` 安装。

> 路线 B 不需要手机有 Theos，但需要你能把工程推到 GitHub（Working Copy 即可完成）。

## 常见问题
- **`make: command not found`** → 工具链没装全，确认装了 `theos-dependencies` 或 `iOS Toolchain`。
- **SDK 找不到** → 脚本会自动 sparse-checkout `iPhoneOS12.4.sdk`；若失败多为网络问题，重跑脚本即可。
- **编译报 Private Framework 头文件缺失** → 确认用的是 theos/sdks（含私有头），而非苹果官方 SDK。
- 手机存储空间建议留 1GB 以上（Theos + SDK 较大）。
