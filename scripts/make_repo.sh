#!/usr/bin/env bash
# 生成 Cydia / Sileo 可添加的「代码源」（repo）。
# 用法：在仓库根目录执行 ./scripts/make_repo.sh
# 依赖：theos（用于 make package）、dpkg-scanpackages、gzip、bzip2
set -euo pipefail

export THEOS="${THEOS:-$HOME/theos}"

echo "==> 编译 .deb"
make clean
make package FINALPACKAGE=1

REPO_DIR="repo"
DEBS_DIR="$REPO_DIR/debs"
mkdir -p "$DEBS_DIR"
cp packages/*.deb "$DEBS_DIR/"

cd "$REPO_DIR"

echo "==> 生成 Packages"
dpkg-scanpackages debs /dev/null > Packages
gzip -kf Packages
bzip2 -kf Packages

echo "==> 生成 Release"
cat > Release <<EOF
Origin: AppStoreVersionSpoofer Repo
Label: AppStoreVersionSpoofer
Suite: stable
Version: 1.0
Architectures: iphoneos-arm64
Components: main
Description: Personal research repo for AppStoreVersionSpoofer tweak (iOS 12.2)
EOF

echo "==> 完成。将本 repo/ 目录整体托管到任意 HTTPS 空间，"
echo "    在 Cydia / Sileo 中添加该目录 URL 即可作为代码源使用。"
