#pragma once

#include <QString>

// Drives the operating system's own AirPlay screen mirroring, so the
// stream can be shown on an AirPlay receiver (Apple TV, Roku, smart TVs)
// without the user opening Control Center themselves.
//
// macOS has no public API to start AirPlay screen mirroring, so this is
// done through the Accessibility API by operating Control Center's
// Screen Mirroring menu on the user's behalf.
namespace AirPlayMirroring
{
    // Whether automatic AirPlay mirroring is available on this platform
    bool isSupported();

    // Whether we're allowed to use the Accessibility API. If prompt is true,
    // macOS will ask the user to grant Moonlight permission when needed.
    bool hasPermission(bool prompt);

    // Opens the Accessibility pane of System Settings
    void openPermissionSettings();

    // Starts mirroring to the AirPlay receiver with the given name. Blocks
    // until mirroring has started or failed, so call this off the main thread.
    // If the receiver was already in use, alreadyConnected is set to true.
    bool connect(const QString& deviceName, bool& alreadyConnected, QString& error);

    // Stops mirroring to the AirPlay receiver with the given name. Blocks.
    bool disconnect(const QString& deviceName, QString& error);
}
