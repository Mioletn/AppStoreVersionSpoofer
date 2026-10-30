#!/usr/bin/env python3
"""
mklc.py —— 生成 UILaunchImages 用的启动图。

为什么需要这个：iOS 判断一个 app 能不能全屏跑，靠的是"有没有 launch storyboard
或 launch image"。两者都没有时，在 iPad 上会退化成 iPhone 兼容模式 —— 屏幕中间
一块 375x667 的窗口，四周黑边。i16 第一版就撞上了这个，截图是 750x1334。

Theos 不编译 storyboard（要 ibtool），而 storyboardc 里的 nib 是 keyed archive，
手写不现实。所以走老路：UILaunchImages。这个 API 在 iOS 12 上是完整支持的。

图就是纯白。启动图在这里只起"声明支持全屏"的作用，不需要有内容 ——
UI 会在几十毫秒内接管。

用法: python _probe/i16/tools/mklc.py
"""
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "Resources"))

# (逻辑尺寸 点, 后缀名)。iPad 全系 + 两个 iPhone 尺寸，防止以后换设备还得改。
SPECS = [
    ((834, 1194), "iPadPro11"),    # iPad Pro 11" / iPad8,1 —— 当前这台
    ((1024, 1366), "iPadPro12"),   # iPad Pro 12.9"
    ((834, 1112), "iPadPro10"),    # iPad Pro 10.5"
    ((768, 1024), "iPad97"),       # iPad 9.7"
    ((414, 896), "iPhone11ProMax"),
    ((375, 812), "iPhoneX"),
]


def solid_png(path, w, h, rgb=(255, 255, 255)):
    """手写一张纯色 PNG。不引 Pillow —— 只为这点事装个依赖不值得。"""
    row = b"\x00" + bytes(rgb) * w          # 每行首字节是 filter type 0
    raw = row * h
    def chunk(tag, data):
        body = tag + data
        return (struct.pack(">I", len(data)) + body +
                struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)   # 8bit, truecolor
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) +
           chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)
    return len(png)


def main():
    os.makedirs(OUT, exist_ok=True)
    total = 0
    for (pt_w, pt_h), tag in SPECS:
        # 竖屏和横屏各一张：Info.plist 里两条 UILaunchImages 各自引用，
        # 尺寸对调。共用同一张图会让系统按名字找错文件。
        for suffix, (w, h) in (("", (pt_w, pt_h)), ("-L", (pt_h, pt_w))):
            name = "LaunchImage-%s%s@2x.png" % (tag, suffix)
            size = solid_png(os.path.join(OUT, name), w * 2, h * 2)
            total += size
            print("%-30s %4dx%-4d 点 -> %4dx%-4d px  %6d 字节"
                  % (name, w, h, w * 2, h * 2, size))
    print("\n共 %d 字节，输出目录 %s" % (total, OUT))


main()
