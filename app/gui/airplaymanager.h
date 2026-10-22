#pragma once

#include <QObject>
#include <QStringList>
#include <QSharedPointer>

namespace QMdnsEngine {
class Server;
class Browser;
class Service;
}

// Finds AirPlay receivers on the network and turns AirPlay screen
// mirroring on and off so a stream can be shown on them.
class AirPlayManager : public QObject
{
    Q_OBJECT

public:
    explicit AirPlayManager(QObject* parent = nullptr);

    Q_PROPERTY(bool isSupported READ isSupported CONSTANT)
    Q_PROPERTY(QStringList devices READ devices NOTIFY devicesChanged)
    Q_PROPERTY(bool busy READ isBusy NOTIFY busyChanged)
    Q_PROPERTY(QString connectedDevice READ connectedDevice NOTIFY connectedDeviceChanged)

    bool isSupported() const;
    QStringList devices() const;
    bool isBusy() const;
    QString connectedDevice() const;

    // Start/stop looking for AirPlay receivers on the network
    Q_INVOKABLE void startDiscovery();
    Q_INVOKABLE void stopDiscovery();

    // Starts AirPlay mirroring to the receiver. Emits connectFinished() when done.
    Q_INVOKABLE void connectDevice(QString deviceName);

    // Stops mirroring if we started it in connectDevice()
    Q_INVOKABLE void disconnectDevice();

    // Turns AirPlay back off once a pending connectDevice() finishes
    Q_INVOKABLE void cancelConnect();

    // Whether we have the OS permission needed to turn on AirPlay
    Q_INVOKABLE bool hasPermission();

    Q_INVOKABLE void openPermissionSettings();

signals:
    void devicesChanged();
    void busyChanged();
    void connectedDeviceChanged();

    // newScreenName is the name of the display that appeared for the receiver,
    // or empty if the receiver mirrors an existing display.
    void connectFinished(bool success, QString error, QString newScreenName);

private:
    void addService(const QMdnsEngine::Service& service);
    void removeService(const QMdnsEngine::Service& service);
    void setBusy(bool busy);

    QSharedPointer<QMdnsEngine::Server> m_MdnsServer;
    QMdnsEngine::Browser* m_MdnsBrowser;
    QStringList m_Devices;
    bool m_Busy;
    bool m_CancelPending;
    QString m_ConnectedDevice;
};
