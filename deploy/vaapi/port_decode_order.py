#!/usr/bin/env python3
"""Apply the decode-order-output port to the qcom/iris driver in place.

This is the TB710FU port of radxa qcom-va-driver's kernel patch
"0001-media-iris-support-decode-order-output-on-HFI-gen2.patch". The upstream
patch does not apply to the 7.2.6-tb710fu base (it lacks the REQUEST_SYNC_FRAME
context), so the same edits are made with exact-anchor replacements instead.
Every anchor must match exactly once; the script aborts otherwise.

VA-API clients decode synchronously, one picture per Submit: without
HFI_PROP_DECODE_ORDER_OUTPUT the firmware only hands back frames in display
order and every VA-API decode ends in "Failed to end picture decode".

Usage:
    python3 port_decode_order.py [iris-driver-dir]
    (default: /root/tb710fu/build/linux-7.2.6/drivers/media/platform/qcom/iris)

Run this BEFORE applying the remaining upstream iris patches
(build/patches/0003..0006-media-iris-*.patch).
"""

import sys

DEFAULT = "/root/tb710fu/build/linux-7.2.6/drivers/media/platform/qcom/iris/"
base = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
if not base.endswith("/"):
    base += "/"


def edit(fn, subs):
    p = base + fn
    s = open(p).read()
    for old, new in subs:
        n = s.count(old)
        assert n == 1, f"{fn}: anchor not unique ({n}): {old[:70]!r}"
        s = s.replace(old, new)
    open(p, "w").write(s)
    print(f"OK {fn}")


CAPS = (
    "\t{\n"
    "\t\t.cap_id = DISPLAY_DELAY_ENABLE,\n"
    "\t\t.min = 0,\n"
    "\t\t.max = 1,\n"
    "\t\t.step_or_mask = 1,\n"
    "\t\t.value = 0,\n"
    "\t\t.hfi_id = HFI_PROP_DECODE_ORDER_OUTPUT,\n"
    "\t\t.flags = CAP_FLAG_INPUT_PORT,\n"
    "\t},\n"
    "\t{\n"
    "\t\t.cap_id = DISPLAY_DELAY,\n"
    "\t\t.min = 0,\n"
    "\t\t.max = 0,\n"
    "\t\t.step_or_mask = 1,\n"
    "\t\t.value = 0,\n"
    "\t},\n"
)

FN = (
    "static int iris_hfi_gen2_set_decode_order_output(struct iris_inst *inst, u32 plane)\n"
    "{\n"
    "\tstruct platform_inst_fw_cap *cap = &inst->fw_caps[DISPLAY_DELAY_ENABLE];\n"
    "\tu32 decode_order = cap->value;\n"
    "\n"
    "\t/* Leave the firmware default unchanged unless userspace sets the control. */\n"
    "\tif (!(cap->flags & CAP_FLAG_CLIENT_SET))\n"
    "\t\treturn 0;\n"
    "\n"
    "\treturn iris_hfi_gen2_session_set_property(inst,\n"
    "\t\t\t\t\t\t  HFI_PROP_DECODE_ORDER_OUTPUT,\n"
    "\t\t\t\t\t\t  HFI_HOST_FLAGS_NONE,\n"
    "\t\t\t\t\t\t  HFI_PORT_BITSTREAM,\n"
    "\t\t\t\t\t\t  HFI_PAYLOAD_U32,\n"
    "\t\t\t\t\t\t  &decode_order, sizeof(decode_order));\n"
    "}\n"
)

edit("iris_ctrls.c", [
    ("\tcase V4L2_CID_MPEG_VIDEO_HEVC_HIER_CODING_L5_BR:\n"
     "\t\treturn LAYER5_BITRATE_HEVC;\n"
     "\tdefault:",
     "\tcase V4L2_CID_MPEG_VIDEO_HEVC_HIER_CODING_L5_BR:\n"
     "\t\treturn LAYER5_BITRATE_HEVC;\n"
     "\tcase V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY_ENABLE:\n"
     "\t\treturn DISPLAY_DELAY_ENABLE;\n"
     "\tcase V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY:\n"
     "\t\treturn DISPLAY_DELAY;\n"
     "\tdefault:"),
    ("\tcase LAYER5_BITRATE_HEVC:\n"
     "\t\treturn V4L2_CID_MPEG_VIDEO_HEVC_HIER_CODING_L5_BR;\n"
     "\tdefault:",
     "\tcase LAYER5_BITRATE_HEVC:\n"
     "\t\treturn V4L2_CID_MPEG_VIDEO_HEVC_HIER_CODING_L5_BR;\n"
     "\tcase DISPLAY_DELAY_ENABLE:\n"
     "\t\treturn V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY_ENABLE;\n"
     "\tcase DISPLAY_DELAY:\n"
     "\t\treturn V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY;\n"
     "\tdefault:"),
])

edit("iris_platform_common.h", [
    ("\tLAYER5_BITRATE_HEVC,\n\tINST_FW_CAP_MAX,",
     "\tLAYER5_BITRATE_HEVC,\n\tDISPLAY_DELAY_ENABLE,\n\tDISPLAY_DELAY,\n\tINST_FW_CAP_MAX,"),
])

edit("iris_hfi_gen2_defines.h", [
    ("#define HFI_PROP_SIGNAL_COLOR_INFO\t\t0x03000155\n",
     "#define HFI_PROP_SIGNAL_COLOR_INFO\t\t0x03000155\n"
     "#define HFI_PROP_DECODE_ORDER_OUTPUT\t\t0x0300015b\n"),
])

edit("iris_hfi_gen2.c", [
    ("static const struct platform_inst_fw_cap inst_fw_cap_sm8550_dec[] = {\n",
     "static const struct platform_inst_fw_cap inst_fw_cap_sm8550_dec[] = {\n" + CAPS),
    ("static const u32 sm8550_vdec_input_config_params_default[] = {\n",
     "static const u32 sm8550_vdec_input_config_params_default[] = {\n\tHFI_PROP_DECODE_ORDER_OUTPUT,\n"),
    ("static const u32 sm8550_vdec_input_config_param_hevc[] = {\n",
     "static const u32 sm8550_vdec_input_config_param_hevc[] = {\n\tHFI_PROP_DECODE_ORDER_OUTPUT,\n"),
    ("static const u32 sm8550_vdec_input_config_param_vp9[] = {\n",
     "static const u32 sm8550_vdec_input_config_param_vp9[] = {\n\tHFI_PROP_DECODE_ORDER_OUTPUT,\n"),
    ("static const u32 sm8550_vdec_input_config_param_av1[] = {\n",
     "static const u32 sm8550_vdec_input_config_param_av1[] = {\n\tHFI_PROP_DECODE_ORDER_OUTPUT,\n"),
])

edit("iris_hfi_gen2_command.c", [
    ("\t\t\t\t\t\t  &super_block,\n\t\t\t\t\t\t  sizeof(u32));\n}\n",
     "\t\t\t\t\t\t  &super_block,\n\t\t\t\t\t\t  sizeof(u32));\n}\n\n" + FN + "\n"),
    ("\t\t{HFI_PROP_AV1_SUPER_BLOCK_ENABLED,    iris_hfi_gen2_set_super_block            },\n",
     "\t\t{HFI_PROP_AV1_SUPER_BLOCK_ENABLED,    iris_hfi_gen2_set_super_block            },\n"
     "\t\t{HFI_PROP_DECODE_ORDER_OUTPUT,        iris_hfi_gen2_set_decode_order_output    },\n"),
])

print("all edits done")
