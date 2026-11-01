# maidong-a19 build workspace

- 源码主体来自 https://github.com/ktv668899/maidong-ktv （master@0d055e6），
  以 `maidong-src.tar.gz` 单包存放，构建前由 workflow 解包。
- 目的：在 GitHub Actions 上编译并适配 Android 4.4 / API 19。
- 构建触发：推送到本分支（workflow: `.github/workflows/build-a19.yml`）。
- 签名：workflow 动态生成测试 keystore，与官方发布签名不同。
