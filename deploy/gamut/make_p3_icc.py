#!/usr/bin/env python3
"""生成一个最小的 Display P3 ICC v2 矩阵/TRC 特性文件。

用途：KWin 6.8 的 SDR 色彩管理会读取 ICC 的色度（primaries）作为
"显示器原生色域"，把 sRGB 内容转换过去。这块平板约 98% DCI-P3，
用 Display P3 (D65) 描述它，桌面颜色就不会过饱和。

不依赖 lcms2 Python 绑定，直接按 ICC 规范写二进制；生成后用
transicc / KWin 校验。
"""
import datetime
import struct
import sys

# Display P3 (D65) 的 D50 适配矩阵（ICC 里 XYZ 必须相对 D50），
# 数值取自标准 Display P3 特性文件，三列相加正好等于 D50 白点。
R_XYZ = (0.515121, 0.241195, -0.001052)
G_XYZ = (0.291977, 0.692245, 0.041885)
B_XYZ = (0.157104, 0.066574, 0.784073)
D50 = (0.964203, 1.000000, 0.824905)

# Bradford D65 -> D50
CHAD = (
    1.0478112, 0.0228866, -0.0501270,
    0.0295424, 0.9904844, -0.0170491,
    -0.0092345, 0.0150436, 0.7521316,
)


def s15f16(value):
    return struct.pack(">i", int(round(value * 65536.0)))


def xyz_tag(values):
    return b"XYZ " + b"\0" * 4 + b"".join(s15f16(v) for v in values)


def text_desc(text):
    data = text.encode("ascii") + b"\0"
    data += b"\0" * ((4 - len(data) % 4) % 4)
    out = b"desc" + b"\0" * 4 + struct.pack(">I", len(text) + 1) + data
    out += struct.pack(">I", 0)          # Unicode language code
    out += struct.pack(">I", 0)          # Unicode count
    out += struct.pack(">H", 0)          # ScriptCode code
    out += struct.pack(">B", 0)          # ScriptCode count
    out += b"\0" * 67                    # ScriptCode string
    return out


def text_cprt(text):
    data = text.encode("ascii") + b"\0"
    return b"text" + b"\0" * 4 + data


def curve_gamma(gamma):
    return b"curv" + b"\0" * 4 + struct.pack(">I", 1) + struct.pack(">H", int(round(gamma * 256)))


def chad_tag():
    return b"sf32" + b"\0" * 4 + b"".join(s15f16(v) for v in CHAD)


def build(description):
    tags = [
        (b"desc", text_desc(description)),
        (b"cprt", text_cprt("Public domain, generated for TB710FU")),
        (b"wtpt", xyz_tag(D50)),
        (b"chad", chad_tag()),
        (b"rXYZ", xyz_tag(R_XYZ)),
        (b"gXYZ", xyz_tag(G_XYZ)),
        (b"bXYZ", xyz_tag(B_XYZ)),
        (b"rTRC", curve_gamma(2.2)),
        (b"gTRC", curve_gamma(2.2)),
        (b"bTRC", curve_gamma(2.2)),
    ]
    tags.sort(key=lambda item: item[0])
    table_size = 4 + len(tags) * 12
    offset = 128 + table_size
    offsets = []
    for sig, data in tags:
        offsets.append((sig, offset, len(data)))
        offset += len(data)
        offset += (4 - offset % 4) % 4
    total = offset

    now = datetime.datetime.now()
    header = bytearray()
    header += struct.pack(">I", total)
    header += b"lcms"
    header += struct.pack(">I", 0x02100000)   # ICC v2.1
    header += b"mntr"
    header += b"RGB "
    header += b"XYZ "
    header += struct.pack(">HHHHHH", now.year, now.month, now.day,
                          now.hour, now.minute, now.second)
    header += b"acsp"
    header += struct.pack(">I", 0)            # platform
    header += struct.pack(">I", 0)            # flags
    header += struct.pack(">I", 0)            # manufacturer
    header += struct.pack(">I", 0)            # model
    header += struct.pack(">Q", 0)            # attributes
    header += struct.pack(">I", 0)            # rendering intent
    header += b"".join(s15f16(v) for v in D50)
    header += struct.pack(">I", 0)            # creator
    header += b"\0" * 16                      # profile id
    header += b"\0" * 28                      # reserved
    assert len(header) == 128, len(header)

    body = struct.pack(">I", len(tags))
    for sig, off, size in offsets:
        body += sig + struct.pack(">I", off) + struct.pack(">I", size)
    for _, data in tags:
        body += data
        body += b"\0" * ((4 - len(body) % 4) % 4)
    blob = bytes(header) + body
    assert len(blob) == total, (len(blob), total)
    return blob


def main():
    if len(sys.argv) != 2:
        print("用法: make_p3_icc.py <输出路径.icc>")
        return 2
    data = build("Display P3 (TB710FU, 98% DCI-P3 approx)")
    with open(sys.argv[1], "wb") as f:
        f.write(data)
    print("已写入 %s（%d 字节）" % (sys.argv[1], len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
