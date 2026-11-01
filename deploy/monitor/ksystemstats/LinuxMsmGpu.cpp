/*
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 *
 * TB710FU patch: platform GPU support (Qualcomm Adreno / msm) for ksystemstats.
 */

#include "LinuxMsmGpu.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QTextStream>

#include <systemstats/SysFsSensor.h>

#include "debug.h"

namespace {

struct ClientStats {
    qulonglong busy = 0;
    qulonglong mem = 0;
};

/*
 * Aggregate DRM fdinfo statistics over all readable processes: engine busy
 * time (ns) and total memory (bytes) per drm client. Several fds can belong
 * to the same client (they report identical counters), keep the maximum.
 */
qulonglong scanFdInfo(QHash<QString, ClientStats> &clients)
{
    QDir proc(QStringLiteral("/proc"));
    const auto pids = proc.entryList(QStringList() << QStringLiteral("[0-9]*"), QDir::Dirs | QDir::NoDotAndDotDot);
    for (const QString &pid : pids) {
        QDir fdDir(QStringLiteral("/proc/%1/fdinfo").arg(pid));
        if (!fdDir.isReadable()) {
            continue;
        }
        const auto fds = fdDir.entryList(QDir::Files);
        for (const QString &fd : fds) {
            QFile file(fdDir.filePath(fd));
            if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
                continue;
            }
            QString driver;
            QString clientId;
            qulonglong busy = 0;
            bool busyFound = false;
            qulonglong mem = 0;
            bool memFound = false;
            QTextStream stream(&file);
            for (QString line = stream.readLine(); !line.isNull(); line = stream.readLine()) {
                if (line.startsWith(QLatin1String("drm-driver:"))) {
                    driver = line.mid(11).trimmed();
                } else if (line.startsWith(QLatin1String("drm-client-id:"))) {
                    clientId = line.mid(14).trimmed();
                } else if (line.startsWith(QLatin1String("drm-engine-"))) {
                    // e.g. "drm-engine-gpu:\t123456 ns"
                    const int colon = line.indexOf(QLatin1Char(':'));
                    const QString value = line.mid(colon + 1).trimmed();
                    const int space = value.indexOf(QLatin1Char(' '));
                    busy += value.left(space < 0 ? value.size() : space).toULongLong();
                    busyFound = true;
                } else if (line.startsWith(QLatin1String("drm-total-memory:"))) {
                    const int colon = line.indexOf(QLatin1Char(':'));
                    const QString value = line.mid(colon + 1).trimmed();
                    const int space = value.indexOf(QLatin1Char(' '));
                    mem = value.left(space < 0 ? value.size() : space).toULongLong();
                    const QString unit = space < 0 ? QString() : value.mid(space + 1).trimmed();
                    if (unit == QLatin1String("KiB")) {
                        mem *= 1024;
                    } else if (unit == QLatin1String("MiB")) {
                        mem *= 1024 * 1024;
                    }
                    memFound = true;
                }
            }
            if (clientId.isEmpty() || !busyFound) {
                continue;
            }
            const QString key = driver + QLatin1Char(':') + clientId;
            auto &entry = clients[key];
            if (busy > entry.busy) {
                entry.busy = busy;
            }
            if (memFound && mem > entry.mem) {
                entry.mem = mem;
            }
        }
    }
    qulonglong totalBusy = 0;
    for (auto it = clients.constBegin(); it != clients.constEnd(); ++it) {
        totalBusy += it->busy;
    }
    return totalBusy;
}

qulonglong systemMemoryTotal()
{
    // The GPU shares system RAM (unified memory); report MemTotal as the total.
    QFile file(QStringLiteral("/proc/meminfo"));
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return 0;
    }
    const QString line = QString::fromLocal8Bit(file.readLine());
    const int colon = line.indexOf(QLatin1Char(':'));
    if (colon < 0) {
        return 0;
    }
    return line.mid(colon + 1).simplified().toULongLong() * 1024;
}

} // namespace

LinuxMsmGpu::LinuxMsmGpu(const QString &id, const QString &name, const QString &devfreqPath)
    : GpuDevice(id, name)
    , m_devfreqPath(devfreqPath)
{
}

void LinuxMsmGpu::initialize()
{
    GpuDevice::initialize();

    m_totalVramProperty->setValue(systemMemoryTotal());

    QFile maxFreqFile(m_devfreqPath + QStringLiteral("/max_freq"));
    if (maxFreqFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
        m_coreFrequencyProperty->setMax(QString::fromLocal8Bit(maxFreqFile.readLine()).trimmed().toDouble() / 1000000.0);
    }
    m_elapsed.start();
}

void LinuxMsmGpu::makeSensors()
{
    m_nameProperty = new KSysGuard::SensorProperty(QStringLiteral("name"), this);
    m_totalVramProperty = new KSysGuard::SensorProperty(QStringLiteral("totalVram"), this);
    m_usedVramProperty = new KSysGuard::SensorProperty(QStringLiteral("usedVram"), this);
    m_usageProperty = new KSysGuard::SensorProperty(QStringLiteral("usage"), QStringLiteral("usage"), 0, this);

    auto frequency = new KSysGuard::SysFsSensor(QStringLiteral("coreFrequency"),
                                                m_devfreqPath % QStringLiteral("/cur_freq"), 0, this);
    frequency->setConvertFunction([](const QByteArray &input) {
        return input.trimmed().toDouble() / 1000000.0;
    });
    m_coreFrequencyProperty = frequency;

    // GPU temperature: first hwmon chip whose name looks like a gpu zone
    // (e.g. gpuss0_thermal on Qualcomm SoCs).
    QDir hwmonDir(QStringLiteral("/sys/class/hwmon"));
    const auto chips = hwmonDir.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot);
    for (const QFileInfo &chip : chips) {
        QFile nameFile(chip.filePath() + QStringLiteral("/name"));
        if (!nameFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
            continue;
        }
        const QString chipName = QString::fromLocal8Bit(nameFile.readLine()).trimmed();
        if (!chipName.startsWith(QLatin1String("gpu"), Qt::CaseInsensitive)) {
            continue;
        }
        if (QFile::exists(chip.filePath() + QStringLiteral("/temp1_input"))) {
            m_temperaturePath = chip.filePath() + QStringLiteral("/temp1_input");
            break;
        }
    }
    if (!m_temperaturePath.isEmpty()) {
        auto temperature = new KSysGuard::SysFsSensor(QStringLiteral("temperature"), m_temperaturePath, 0, this);
        temperature->setConvertFunction([](const QByteArray &input) {
            return input.trimmed().toDouble() / 1000.0;
        });
        m_temperatureProperty = temperature;
    } else {
        m_temperatureProperty = new KSysGuard::SensorProperty(QStringLiteral("temperature"), this);
    }

    m_memoryFrequencyProperty = new KSysGuard::SensorProperty(QStringLiteral("memoryFrequency"), this);
    m_powerProperty = new KSysGuard::SensorProperty(QStringLiteral("power"), this);
}

void LinuxMsmGpu::update()
{
    if (auto *sensor = qobject_cast<KSysGuard::SysFsSensor *>(m_coreFrequencyProperty)) {
        sensor->update();
    }
    if (auto *sensor = qobject_cast<KSysGuard::SysFsSensor *>(m_temperatureProperty)) {
        sensor->update();
    }

    QHash<QString, ClientStats> clients;
    scanFdInfo(clients);

    /*
     * Usage from per-client busy deltas: a client seen for the first time
     * contributes nothing this round, so accumulated history of a newly
     * opened context is never mistaken for current activity.
     */
    qulonglong totalDelta = 0;
    qulonglong memUsed = 0;
    QHash<QString, qulonglong> currentBusy;
    for (auto it = clients.constBegin(); it != clients.constEnd(); ++it) {
        memUsed += it.value().mem;
        currentBusy.insert(it.key(), it.value().busy);
        const auto prev = m_lastBusyPerClient.constFind(it.key());
        if (prev != m_lastBusyPerClient.constEnd() && it.value().busy > prev.value()) {
            totalDelta += it.value().busy - prev.value();
        }
    }
    m_lastBusyPerClient = std::move(currentBusy);

    const qint64 elapsedNs = m_elapsed.nsecsElapsed();
    m_elapsed.restart();
    if (elapsedNs > 0) {
        m_usageProperty->setValue(qBound(0.0, double(totalDelta) * 100.0 / double(elapsedNs), 100.0));
    }

    m_usedVramProperty->setValue(memUsed);
}

#include "moc_LinuxMsmGpu.cpp"
