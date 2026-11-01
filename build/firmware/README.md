# Firmware

This directory is filled by `collect_firmware.sh` from **your own** device's `super.img`.
The blobs are not redistributable, so the repository ships an empty directory.

```bash
sudo apt-get install -y simg2img erofs-utils
bash ../collect_firmware.sh /path/to/super.img .
```

Expected layout matches `/usr/lib/firmware`:

```
qcom/sm8650/xiaoxin/gt/   adsp/cdsp .mbn + _dtb + *.jsn + gen70900_*.mbn
novatek/                  novatek_nt36532_fw.bin
awinic/  aw882xx_acf.bin
ath12k/WCN7850/hw2.0/     amss.bin board-2.bin m3.bin
qca/                      hmtbtfw20.tlv hmtnv20.bin
qcom/sm8650/Lenovo-TB710FU-tplg.bin
```

`install_payload.sh` refuses to finish if any required file is missing, so a silent
"no Wi-Fi/no audio" image is not possible.
