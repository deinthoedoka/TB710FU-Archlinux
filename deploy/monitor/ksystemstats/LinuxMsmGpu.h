/*
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 *
 * TB710FU patch: platform GPU support (Qualcomm Adreno / msm) for ksystemstats.
 * Usage comes from DRM fdinfo (per-client engine busy), frequency from devfreq,
 * temperature from the gpuss hwmon zones.
 */

#pragma once

#include "GpuDevice.h"

#include <QElapsedTimer>
#include <QHash>

class LinuxMsmGpu : public GpuDevice
{
    Q_OBJECT

public:
    LinuxMsmGpu(const QString &id, const QString &name, const QString &devfreqPath);
    ~LinuxMsmGpu() override = default;

    void initialize() override;
    void update() override;

protected:
    void makeSensors() override;

private:
    QString m_devfreqPath;
    QString m_temperaturePath;
    QElapsedTimer m_elapsed;
    QHash<QString, qulonglong> m_lastBusyPerClient;
};
