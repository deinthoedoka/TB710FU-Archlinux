/*
 * SPDX-FileCopyrightText: 2020 Arjen Hiemstra <ahiemstra@heimr.nl>
 *
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 *
 * TB710FU patch: additionally discover platform GPUs (Qualcomm Adreno etc.)
 * through the devfreq subsystem and expose them via the fdinfo based
 * LinuxMsmGpu device.
 */

#include "LinuxBackend.h"

#include <KLocalizedString>

#include <libudev.h>

#include <processcore/gpu_utils.h>

#include "LinuxAmdGpu.h"
#include "LinuxIntelGpu.h"
#include "LinuxMsmGpu.h"
#include "LinuxNvidiaGpu.h"
#ifdef HAVE_XE_DRM_H
#include "LinuxXeGpu.h"
#endif
#include "debug.h"

// Vendor ID strings, as used in sysfs
static const char *amdVendor = "0x1002";
static const char *intelVendor = "0x8086";
static const char *nvidiaVendor = "0x10de";
// PCI Device class strings
static const char *VGAController =      "0x030000";
static const char *threeDController =   "0x030200";
static const char *displayController =  "0x038000";

static bool isXeDriver(udev_device *pciDevice)
{
    const char *driver = udev_device_get_driver(pciDevice);
    return driver && strcmp(driver, "xe") == 0;
}

LinuxBackend::LinuxBackend(QObject *parent)
    : GpuBackend(parent)
{
}

void LinuxBackend::start()
{
    if (!m_udev) {
        m_udev = udev_new();
    }

    auto enumerate = udev_enumerate_new(m_udev);

    udev_enumerate_add_match_subsystem(enumerate, "pci");
    udev_enumerate_add_match_sysattr(enumerate, "class", VGAController);
    udev_enumerate_add_match_sysattr(enumerate, "class", threeDController);
    udev_enumerate_add_match_sysattr(enumerate, "class", displayController);
    udev_enumerate_scan_devices(enumerate);

    auto devices = udev_enumerate_get_list_entry(enumerate);
    int gpuNumber = 0;
    for (auto entry = devices; entry; entry = udev_list_entry_get_next(entry)) {
        auto path = udev_list_entry_get_name(entry);
        auto pciDevice = udev_device_new_from_syspath(m_udev, path);

        auto vendor = QByteArray(udev_device_get_sysattr_value(pciDevice, "vendor"));
        auto gpuId = QStringLiteral("gpu%1").arg(gpuNumber);

        QString gpuName = KSysGuard::gpuName(pciDevice, gpuNumber);

        GpuDevice *gpu = nullptr;
        if (isXeDriver(pciDevice)) {
#ifdef HAVE_XE_DRM_H
            gpu = new LinuxXeGpu{gpuId, gpuName, pciDevice};
#else
            qCWarning(KSYSTEMSTATS_GPU) << "Found Xe GPU but ksystemstats compiled without Xe support";
            udev_device_unref(pciDevice);
            continue;
#endif
        } else if (vendor == amdVendor) {
            gpu = new LinuxAmdGpu{gpuId, gpuName, pciDevice};
        } else if (vendor == nvidiaVendor) {
            gpu = new LinuxNvidiaGpu{gpuId, gpuName, pciDevice};
        } else if (vendor == intelVendor) {
            gpu = new LinuxIntelGpu{gpuId, gpuName, pciDevice};
        }

        if (!gpu) {
            qCDebug(KSYSTEMSTATS_GPU) << "Found unsupported GPU:" << path;
            udev_device_unref(pciDevice);
            continue;
        }

        gpu->initialize();
        m_devices.append(gpu);
        Q_EMIT deviceAdded(gpu);
        gpuNumber++;

        udev_device_unref(pciDevice);
    }

    udev_enumerate_unref(enumerate);

    // Platform GPUs (e.g. Qualcomm Adreno) have no PCI entry but do have a
    // devfreq device. Discover them via the devfreq subsystem; the parent of
    // the devfreq device is the GPU platform device.
    auto devfreqEnumerate = udev_enumerate_new(m_udev);
    udev_enumerate_add_match_subsystem(devfreqEnumerate, "devfreq");
    udev_enumerate_add_match_sysname(devfreqEnumerate, "*gpu");
    udev_enumerate_scan_devices(devfreqEnumerate);

    auto devfreqDevices = udev_enumerate_get_list_entry(devfreqEnumerate);
    for (auto entry = devfreqDevices; entry; entry = udev_list_entry_get_next(entry)) {
        auto path = udev_list_entry_get_name(entry);
        auto devfreqDevice = udev_device_new_from_syspath(m_udev, path);

        auto platformDevice = udev_device_get_parent(devfreqDevice);
        if (!platformDevice || qstrcmp(udev_device_get_subsystem(platformDevice), "platform") != 0) {
            udev_device_unref(devfreqDevice);
            continue;
        }

        auto driverName = QByteArray(udev_device_get_driver(platformDevice));
        if (driverName.isEmpty()) {
            udev_device_unref(devfreqDevice);
            continue;
        }

        QString gpuName;
        if (driverName == "adreno") {
            gpuName = QStringLiteral("Adreno GPU");
        } else if (driverName == "panfrost") {
            gpuName = QStringLiteral("Mali GPU (Panfrost)");
        } else if (driverName == "panthor") {
            gpuName = QStringLiteral("Mali GPU (Panthor)");
        } else {
            gpuName = QString::fromLocal8Bit(driverName) % QStringLiteral(" GPU");
        }

        auto gpuId = QStringLiteral("gpu%1").arg(gpuNumber);

        auto gpu = new LinuxMsmGpu{gpuId, gpuName, QString::fromLocal8Bit(udev_device_get_syspath(devfreqDevice))};
        gpu->initialize();
        m_devices.append(gpu);
        Q_EMIT deviceAdded(gpu);
        gpuNumber++;

        udev_device_unref(devfreqDevice);
    }

    udev_enumerate_unref(devfreqEnumerate);
}

void LinuxBackend::stop()
{
    qDeleteAll(m_devices);
    udev_unref(m_udev);
}

void LinuxBackend::update()
{
    for (auto device : std::as_const(m_devices)) {
        device->update();
    }
}

int LinuxBackend::deviceCount()
{
    return m_devices.count();
}

#include "moc_LinuxBackend.cpp"
