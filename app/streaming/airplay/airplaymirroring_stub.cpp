#include "airplaymirroring.h"

#include <QCoreApplication>

bool AirPlayMirroring::isSupported()
{
    return false;
}

bool AirPlayMirroring::hasPermission(bool)
{
    return false;
}

void AirPlayMirroring::openPermissionSettings()
{
}

bool AirPlayMirroring::connect(const QString&, bool& alreadyConnected, QString& error)
{
    alreadyConnected = false;
    error = QCoreApplication::translate("AirPlayMirroring", "AirPlay is only supported on macOS");
    return false;
}

bool AirPlayMirroring::disconnect(const QString&, QString& error)
{
    error = QCoreApplication::translate("AirPlayMirroring", "AirPlay is only supported on macOS");
    return false;
}
