#include "airplaymanager.h"
#include "streaming/airplay/airplaymirroring.h"

#include <QGuiApplication>
#include <QScreen>
#include <QThread>
#include <QSet>

#include <qmdnsengine/server.h>
#include <qmdnsengine/browser.h>
#include <qmdnsengine/service.h>

#include "SDL_compat.h"

AirPlayManager::AirPlayManager(QObject* parent)
    : QObject(parent),
      m_MdnsBrowser(nullptr),
      m_Busy(false),
      m_CancelPending(false)
{
}

bool AirPlayManager::isSupported() const
{
    return AirPlayMirroring::isSupported();
}

QStringList AirPlayManager::devices() const
{
    return m_Devices;
}

bool AirPlayManager::isBusy() const
{
    return m_Busy;
}

QString AirPlayManager::connectedDevice() const
{
    return m_ConnectedDevice;
}

void AirPlayManager::setBusy(bool busy)
{
    if (m_Busy != busy) {
        m_Busy = busy;
        emit busyChanged();
    }
}

void AirPlayManager::startDiscovery()
{
    if (!isSupported() || m_MdnsBrowser != nullptr) {
        return;
    }

    m_MdnsServer.reset(new QMdnsEngine::Server());
    m_MdnsBrowser = new QMdnsEngine::Browser(m_MdnsServer.data(), "_airplay._tcp.local.", nullptr, this);
    connect(m_MdnsBrowser, &QMdnsEngine::Browser::serviceAdded,
            this, &AirPlayManager::addService);
    connect(m_MdnsBrowser, &QMdnsEngine::Browser::serviceRemoved,
            this, &AirPlayManager::removeService);
}

void AirPlayManager::stopDiscovery()
{
    delete m_MdnsBrowser;
    m_MdnsBrowser = nullptr;
    m_MdnsServer.reset();

    if (!m_Devices.isEmpty()) {
        m_Devices.clear();
        emit devicesChanged();
    }
}

void AirPlayManager::addService(const QMdnsEngine::Service& service)
{
    // The instance name is what macOS shows in the Screen Mirroring menu
    QString name = QString::fromUtf8(service.name());
    if (name.isEmpty() || m_Devices.contains(name)) {
        return;
    }

    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                "Found AirPlay receiver: %s",
                qPrintable(name));

    m_Devices.append(name);
    m_Devices.sort(Qt::CaseInsensitive);
    emit devicesChanged();
}

void AirPlayManager::removeService(const QMdnsEngine::Service& service)
{
    if (m_Devices.removeAll(QString::fromUtf8(service.name())) > 0) {
        emit devicesChanged();
    }
}

void AirPlayManager::connectDevice(QString deviceName)
{
    if (m_Busy) {
        return;
    }

    setBusy(true);
    m_CancelPending = false;

    QSet<QString> screensBefore;
    for (QScreen* screen : QGuiApplication::screens()) {
        screensBefore.insert(screen->name());
    }

    // Operating Control Center takes a few seconds, so don't block the UI
    QThread* thread = QThread::create([this, deviceName, screensBefore]() {
        bool alreadyConnected = false;
        QString error;
        bool success = AirPlayMirroring::connect(deviceName, alreadyConnected, error);

        QMetaObject::invokeMethod(this, [this, deviceName, screensBefore, success, alreadyConnected, error]() {
            QString newScreenName;

            if (success) {
                // If we turned AirPlay on, we'll turn it off again when the stream ends.
                // We leave it alone if the user already had it running.
                m_ConnectedDevice = alreadyConnected ? QString() : deviceName;
                emit connectedDeviceChanged();

                // If the receiver became a separate display, the stream should go there
                for (QScreen* screen : QGuiApplication::screens()) {
                    if (!screensBefore.contains(screen->name())) {
                        newScreenName = screen->name();
                        break;
                    }
                }
            }
            else {
                SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                            "Failed to start AirPlay to '%s': %s",
                            qPrintable(deviceName),
                            qPrintable(error));
            }

            setBusy(false);

            if (m_CancelPending) {
                m_CancelPending = false;
                disconnectDevice();
                return;
            }

            emit connectFinished(success, error, newScreenName);
        }, Qt::QueuedConnection);
    });

    connect(thread, &QThread::finished, thread, &QObject::deleteLater);
    thread->start();
}

void AirPlayManager::disconnectDevice()
{
    if (m_ConnectedDevice.isEmpty()) {
        return;
    }

    QString deviceName = m_ConnectedDevice;
    m_ConnectedDevice.clear();
    emit connectedDeviceChanged();

    QThread* thread = QThread::create([deviceName]() {
        QString error;
        if (!AirPlayMirroring::disconnect(deviceName, error)) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "Failed to stop AirPlay to '%s': %s",
                        qPrintable(deviceName),
                        qPrintable(error));
        }
    });

    connect(thread, &QThread::finished, thread, &QObject::deleteLater);
    thread->start();
}

void AirPlayManager::cancelConnect()
{
    if (m_Busy) {
        m_CancelPending = true;
    }
}

bool AirPlayManager::hasPermission()
{
    return AirPlayMirroring::hasPermission(false);
}

void AirPlayManager::openPermissionSettings()
{
    AirPlayMirroring::openPermissionSettings();
}
