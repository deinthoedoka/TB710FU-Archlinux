/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Power-transition notifier for the Lenovo TB710FU NT36532 panel.
 *
 * The panel and the Novatek touch controller are separate devices, but the
 * touch firmware cannot survive the DSI reset performed while the panel is
 * powered down.  The panel driver calls this chain before it turns the panel
 * off and after it has brought it back, so the touch driver can put the
 * controller into deep sleep and wake it again without re-flashing its
 * firmware.
 */

#ifndef __LINUX_NT36532_PANEL_H
#define __LINUX_NT36532_PANEL_H

#include <linux/kconfig.h>
#include <linux/notifier.h>

enum nt36532_panel_event {
	NT36532_PANEL_POWER_OFF = 0,
	NT36532_PANEL_POWER_ON,
};

#if IS_ENABLED(CONFIG_DRM_PANEL_NT36532_WQHD_DUAL_DSI)
int nt36532_panel_register_notifier(struct notifier_block *nb);
void nt36532_panel_unregister_notifier(struct notifier_block *nb);
#else
static inline int nt36532_panel_register_notifier(struct notifier_block *nb)
{
	return -ENODEV;
}

static inline void nt36532_panel_unregister_notifier(struct notifier_block *nb)
{
}
#endif

#endif /* __LINUX_NT36532_PANEL_H */
