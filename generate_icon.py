#!/usr/bin/env python3
# 生成 App 图标：蓝色渐变背景 + 居中白色圆环（代表"版本切换"），四角透明圆角。
import struct, zlib, math, os

def make_png(path, size):
    w = h = size
    cx = cy = size / 2.0
    ring_r = size * 0.30
    ring_w = size * 0.06
    corner = size * 0.22

    raw = bytearray()
    for y in range(h):
        raw.append(0)  # 每行前缀：filter = 0
        for x in range(w):
            t = y / (h - 1)
            r8 = int(0x2B + (0x1E - 0x2B) * t)
            g8 = int(0x6C + (0x4F - 0x6C) * t)
            b8 = int(0xFF + (0xD6 - 0xFF) * t)

            d = math.hypot(x - cx, y - cy)
            if abs(d - ring_r) < ring_w:
                edge = (ring_w - abs(d - ring_r)) / ring_w
                blend = max(0.0, min(1.0, edge))
                rr = int(255 * blend + r8 * (1 - blend))
                gg = int(255 * blend + g8 * (1 - blend))
                bb = int(255 * blend + b8 * (1 - blend))
            else:
                rr, gg, bb = r8, g8, b8

            a = 255
            nx = min(x, w - 1 - x)
            ny = min(y, h - 1 - y)
            if nx < corner and ny < corner:
                if math.hypot(corner - nx - 1, corner - ny - 1) > corner:
                    a = 0

            raw += bytes((rr, gg, bb, a))

    def chunk(typ, data):
        body = typ + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    idat = zlib.compress(bytes(raw), 9)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    print("wrote", path, len(png), "bytes")

here = os.path.dirname(os.path.abspath(__file__))
make_png(os.path.join(here, "Icon.png"), 60)
make_png(os.path.join(here, "Icon@2x.png"), 120)
