# 构建

所有脚本在 WSL2 Ubuntu（或任意 Debian/Ubuntu x86_64）里跑。交叉编译 aarch64，
rootfs 阶段用 qemu-user-binfmt 跑 arm64 pacman。

## 依赖

```bash
./fetch-deps.sh        # deps/ + sources/
bash wsl_setup.sh      # apt 工具链、binfmt、循环设备检查
```

`fetch-deps.sh` 拉三个上游仓库和一个内核 tarball：

| 路径 | 内容 |
| --- | --- |
| `deps/tb710fu-hyperos-steamos` | 板级支持：内核补丁、config、kShimC 补丁 |
| `deps/armadaos-freedom` | SM8650 内核补丁基线（`ba692d8`） |
| `deps/DualBootKernelPatcher` | boot_a 打包器（`2276163`） |
| `sources/linux-7.2.6.tar.xz` | 上游内核 |

`build_shim.sh` 还会自己拉 picolibc / lvgl / CrDK / dtc / inih（固定 commit）。

## 一键构建

```bash
bash wsl_build.sh all
```

或者分开：`wsl_build.sh kernel|shim|rootfs`。

| 步骤 | 脚本 | 产物 |
| --- | --- | --- |
| 内核 | `build_kernel.sh` | `Image`、dtb、`modules-7.2.6-tb710fu.tar`、initramfs（含 `nbdclient`） |
| 菜单 + 打包器 | `build_shim.sh` | `kShimC.bin`、`MultiBootKernelPatcher` |
| rootfs | `build_rootfs.sh` | `arch-nbd.img`（12 GiB，装完系统后可删） |

`wsl_build.sh` 把产物复制到仓库根目录的 `out/`，日志写到 `logs/build-<时间>/`。

## 内核补丁顺序

`build_kernel.sh` 按这个顺序打补丁：

1. `linux-7.2.6` 原始树
2. `deps/armadaos-freedom/packages/kernel/patches/series` 全部补丁 + DTS
3. `deps/tb710fu-hyperos-steamos/kernel/tb710fu-kernel-on-freedom.patch`（TB710FU 板级支持）
4. **`patches/0001-tb710fu-local.patch`** —— 本项目自己的改动：
   - `qcom_battmgr` 的 `current_inverted` 模块参数（充电显示）
   - `q6dsp-lpass-clocks` 注册期竞态（ADSP 未就绪时 `rpmsg_send` 永久阻塞）
   - DTS：ADSP/CDSP 固件名 `.mdt` → `.mbn`，去掉强制的 `tb710fu.nbd` 命令行
   - 面板驱动的 prepare/disable 日志
5. **`patches/0002..0006-media-iris-*.patch`** —— VA-API 必需的 iris 补丁
   （来自 radxa qcom-va-driver 的 `patches/`）：
   - `0002`：decode-order output 的**本机移植版**。上游 0001 打不上这套基线
     （缺 `REQUEST_SYNC_FRAME` 上下文），改由 `deploy/vaapi/port_decode_order.py`
     按锚点原地修改后 `diff` 生成；没有它 VA-API 每帧都报
     "Failed to end picture decode"
   - `0003`：更大的采集缓冲池；`0004`：去块滤波控件；`0005`：错误帧保留时间戳；
     `0006`：非显示缓冲回收
6. `arch.config` 片段 + `olddefconfig`（见下）

板级补丁是按 freedom 基线写的，7.2.6 里已经有其中一部分内容，所以
`build_kernel.sh` 用 `patch --forward` 跳过已应用的 hunk 并继续，而不是整体失败。

`patches/0001-tb710fu-local.patch` 是在 `linux-7.2.6 + 上游两个补丁` 之上用
`diff -u` 生成的，所以只能按上面的顺序应用。

## rootfs 内容

`build_rootfs.sh` 解包 ArchLinuxARM，安装基础包（KDE 在 `apps/install/desktop.sh` 里装），
然后调用 `install_payload.sh` 把 `build/rootfs/` 覆盖进系统：

- `etc/`：modprobe、udev、systemd 单元、tmpfiles、sleep/logind 配置、WirePlumber
- `usr/local/sbin/`：显示/音频/USB/触摸/NBD 相关的辅助脚本与自检

`install_payload.sh` 同时校验固件清单；缺任何一个都由 `collect_firmware.sh` 从你自己的
`super.img` 里补齐。

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `REPO` | `deps/tb710fu-hyperos-steamos` | 板级支持仓库 |
| `FREEDOM` | `deps/armadaos-freedom` | 内核补丁基线 |
| `DBKP_SRC` | `deps/DualBootKernelPatcher` | 打包器源码 |
| `SRCWIN` | `sources/` | 预下载的 tarball |
| `OUT` | `$HOME/tb710fu/out` | 构建输出（ext4 上，比 /mnt 快） |
| `ROOT_PASS` | **必填** | root 和 tb 用户的密码 |
| `TESTKEY` | `tools/testkey_rsa4096.pem` | AVB 签名密钥（AOSP testkey） |

## 单独跑

```bash
# 只重编内核
bash build_kernel.sh

# 只重新打包 boot_a
python3 -I pack_boot.py --boot stock_boot_a.img --shim out/kShimC.bin \
  --linux out/Image --dtb out/sm8650-lenovo-tb710fu-kshim.dtb \
  --out out/boot --default zui
```
