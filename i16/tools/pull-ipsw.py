#!/usr/bin/env python3
"""pull-ipsw.py —— 从一个 IPSW 里取出单个文件，不下载其余 6 GB。

来源：改写自 hackios-xnu-kernel 的 sysimage/fetch-from-ipsw.py（MIT）。
那个脚本只认死一个 URL、只能取一个写死的成员；这里把 URL 和成员都变成参数，
并加了 --list，因为「IPSW 里到底有没有这个文件、路径是什么」本身就是要查的事。

为什么要它：i16 的目标是「在 iOS 12 上实现 iOS 16」。这里面有一类东西不是代码
能补的，是**资源**——最典型的是 SF Symbols：它不是 API，是随系统安装的字形。
12.2 里没有这套字形，所以 systemImageNamed: 无解。但 iOS 16.5 的 IPSW 里有，
按需取出即可。同理，dyld shared cache 里有 16.5 全部框架的二进制和导出符号，
那是「16 比 12 多了什么」的施工图。

用法:
    pull-ipsw.py list <ipsw-url> [通配符]
    pull-ipsw.py get  <ipsw-url> <成员路径> <输出文件>

例:
    pull-ipsw.py list https://.../iPad_16.5.ipsw 'CoreGlyphs'
    pull-ipsw.py get  https://.../iPad_16.5.ipsw \\
        System/Library/CoreServices/CoreGlyphs.bundle/Info.plist ./Info.plist

IPSW 是 ZIP64，目录在文件尾部。这个脚本只读尾部 64 KB 拿到中央目录，
再用 Range 请求取目标成员本身。未压缩的成员支持断点续传。
"""
import fnmatch
import http.client
import os
import struct
import sys
import time
import urllib.request
import zlib

ATTEMPTS = 20
CHUNK = 1 << 20


def remote_size(url):
    req = urllib.request.Request(url, method='HEAD')
    with urllib.request.urlopen(req, timeout=60) as r:
        return int(r.headers['Content-Length'])


def fetch(url, start, end):
    req = urllib.request.Request(url, headers={'Range': 'bytes=%d-%d' % (start, end)})
    return urllib.request.urlopen(req, timeout=120)


def directory(url, size):
    """遍历 (name, method, csize, usize, data_offset_of_zipfile). 只有中央目录在内存里。"""
    tail = fetch(url, size - 65536, size - 1).read()
    at = tail.rfind(b'PK\x06\x06')
    if at < 0:
        sys.exit('不是 ZIP64 归档：文件尾部找不到中央目录结束记录')
    cd_size, cd_offset = struct.unpack('<QQ', tail[at + 40:at + 56])
    cd = fetch(url, cd_offset, cd_offset + cd_size - 1).read()

    p = 0
    while cd[p:p + 4] == b'PK\x01\x02':
        method, = struct.unpack('<H', cd[p + 10:p + 12])
        csize, usize, nl, el, cl = struct.unpack('<IIHHH', cd[p + 20:p + 34])
        offset, = struct.unpack('<I', cd[p + 42:p + 46])
        name = cd[p + 46:p + 46 + nl].decode('utf-8', 'replace')
        extra = cd[p + 46 + nl:p + 46 + nl + el]
        # ZIP64：三个 32 位字段为 0xFFFFFFFF 时，真值在 extra 的 tag=1 里，按顺序排
        q = 0
        while q + 4 <= len(extra):
            tag, length = struct.unpack('<HH', extra[q:q + 4])
            if tag == 1:
                n = length // 8
                vals = list(struct.unpack('<' + 'Q' * n, extra[q + 4:q + 4 + n * 8]))
                if usize == 0xFFFFFFFF and vals:
                    usize = vals.pop(0)
                if csize == 0xFFFFFFFF and vals:
                    csize = vals.pop(0)
                if offset == 0xFFFFFFFF and vals:
                    offset = vals.pop(0)
            q += 4 + length
        yield name, method, csize, usize, offset
        p += 46 + nl + el + cl


def local_data_offset(url, offset):
    """中央目录给的是本地头的位置，真正的数据在它后面（名字 + extra 变长）。"""
    header = fetch(url, offset, offset + 29).read()
    nl, el = struct.unpack('<HH', header[26:30])
    return offset + 30 + nl + el


def download(url, data, method, csize, output):
    if method == 0:
        have = os.path.getsize(output) if os.path.exists(output) else 0
        if have > csize:
            have = 0
        if have < csize:
            mode = 'ab' if have else 'wb'
            with fetch(url, data + have, data + csize - 1) as s, open(output, mode) as o:
                while True:
                    chunk = s.read(CHUNK)
                    if not chunk:
                        break
                    o.write(chunk)
        return os.path.getsize(output)

    inflater = zlib.decompressobj(-15)
    written = 0
    with fetch(url, data, data + csize - 1) as s, open(output, 'wb') as o:
        while True:
            chunk = s.read(CHUNK)
            if not chunk:
                break
            body = inflater.decompress(chunk)
            o.write(body)
            written += len(body)
        tail = inflater.flush()
        o.write(tail)
        written += len(tail)
    return written


def human(n):
    for unit in ('B', 'KB', 'MB', 'GB'):
        if n < 1024 or unit == 'GB':
            return '%.1f %s' % (n, unit) if unit != 'B' else '%d B' % n
        n /= 1024.0


def cmd_list(url, pattern):
    size = remote_size(url)
    print('IPSW %s  (%s)' % (human(size), url.split('/')[-1]))
    hits = 0
    for name, method, csize, usize, offset in directory(url, size):
        if pattern and not fnmatch.fnmatch(name, pattern) and pattern.lower() not in name.lower():
            continue
        hits += 1
        print('  %10s  %s%s' % (human(usize), name,
                                '  [stored]' if method == 0 else ''))
    print('共 %d 项' % hits)
    if not hits:
        print('没有匹配。去掉通配符再列一次，或者换一个更短的关键词。')
        return 1
    return 0


def cmd_get(url, member, output):
    size = remote_size(url)
    for name, method, csize, usize, offset in directory(url, size):
        if name != member:
            continue
        if method not in (0, 8):
            sys.exit('%s：压缩方式 %d 不支持' % (member, method))
        data = local_data_offset(url, offset)
        written = -1
        for attempt in range(1, ATTEMPTS + 1):
            try:
                written = download(url, data, method, csize, output)
            except (OSError, http.client.HTTPException, zlib.error) as e:
                print('  中断：%s' % e, file=sys.stderr)
            if written == usize:
                break
            print('  重试 %d/%d' % (attempt, ATTEMPTS), file=sys.stderr)
            time.sleep(5)
        print('%s → %s（%s，期望 %s）' % (member, output, human(written), human(usize)))
        return 0 if written == usize else 1
    sys.exit('%s：归档里没有这一项。先跑 list 看看确切路径。' % member)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__.strip().split('\n\n')[1])
    cmd = sys.argv[1]
    if cmd == 'list':
        url = sys.argv[2]
        return cmd_list(url, sys.argv[3] if len(sys.argv) > 3 else None)
    if cmd == 'get':
        if len(sys.argv) < 5:
            sys.exit('用法: pull-ipsw.py get <url> <成员路径> <输出文件>')
        return cmd_get(sys.argv[2], sys.argv[3], sys.argv[4])
    sys.exit('未知子命令 %r，只认 list / get' % cmd)


if __name__ == '__main__':
    sys.exit(main())
