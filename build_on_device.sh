#!/usr/bin/env bash
# 在越狱 iOS 设备上直接编译 AppStoreVersionSpoofer 为 .deb
# 用法（NewTerm 中，先 cd 到本工程目录）：
#   bash build_on_device.sh
# 说明：脚本会按需安装/定位 Theos、拉取 iOS 12 SDK，然后 make package。
set -e

# 默认 Theos 路径（可被环境变量覆盖）
export THEOS="${THEOS:-/var/mobile/theos}"

echo "==> 步骤1：确保 Theos + 工具链就绪"
if [ ! -x "$THEOS/bin/nic.pl" ] && [ ! -d "$THEOS" ]; then
  echo "    未检测到 Theos，尝试通过包管理器安装..."
  # Procursus / Elucubratus
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y theos theos-dependencies >/dev/null 2>&1 || true
  # 若包管理器没装上，退而用官方安装脚本（需设备已装 clang/make/perl 等）
  if [ ! -d "$THEOS" ]; then
    echo "    包管理器未提供 theos，改用官方安装脚本"
    curl -fsSL https://raw.githubusercontent.com/theos/theos/main/Install.theos -o /tmp/install-theos
    bash /tmp/install-theos
    export THEOS="${THEOS:-$HOME/theos}"
  fi
else
  echo "    已检测到 Theos: $THEOS"
fi

echo "==> 步骤2：确保 iOS 12 SDK 就绪"
if [ ! -d "$THEOS/sdks/iPhoneOS12.4.sdk" ]; then
  echo "    拉取 theos/sdks 的 iPhoneOS12.4.sdk（sparse-checkout）..."
  rm -rf /tmp/theos-sdks
  git clone --filter=blob:none --sparse https://github.com/theos/sdks.git /tmp/theos-sdks
  ( cd /tmp/theos-sdks && git sparse-checkout set iPhoneOS12.4.sdk )
  mkdir -p "$THEOS/sdks"
  mv /tmp/theos-sdks/iPhoneOS12.4.sdk "$THEOS/sdks/"
  echo "    SDK 已就绪: $THEOS/sdks/iPhoneOS12.4.sdk"
else
  echo "    已存在 iOS 12 SDK"
fi

echo "==> 步骤3：编译 .deb"
export THEOS
make clean
make package FINALPACKAGE=1

echo ""
echo "✅ 编译完成。.deb 位于："
ls -1 packages/*.deb
echo "用 Filza / Sileo 打开该文件即可安装，随后重启 SpringBoard。"
