import QtQuick 2.0
import QtQuick.Controls 2.2
import QtQuick.Window 2.2

import SdlGamepadKeyNavigation 1.0
import Session 1.0
import StreamingPreferences 1.0
import AirPlayManager 1.0
import SystemProperties 1.0

Item {
    property Session session
    property string appName
    property string stageText : isResume ? qsTr("Resuming %1...").arg(appName) :
                                           qsTr("Starting %1...").arg(appName)
    property bool isResume : false
    property bool quitAfter : false

    function stageStarting(stage)
    {
        // Update the spinner text
        stageText = qsTr("Starting %1...").arg(stage)
    }

    function stageFailed(stage, errorCode, failingPorts)
    {
        // Display the error dialog after Session::exec() returns
        streamSegueErrorDialog.text = qsTr("Starting %1 failed: Error %2").arg(stage).arg(errorCode)

        if (failingPorts) {
            streamSegueErrorDialog.text += "\n\n" + qsTr("Check your firewall and port forwarding rules for port(s): %1").arg(failingPorts)
        }
    }

    function connectionStarted()
    {
        // Hide the UI contents so the user doesn't
        // see them briefly when we pop off the StackView
        stageSpinner.visible = false
        stageLabel.visible = false
        hintText.visible = false

        // Hide the window now that streaming has begun
        window.visible = false
    }

    function displayLaunchError(text)
    {
        // Display the error dialog after Session::exec() returns
        streamSegueErrorDialog.text = text
        console.error(text)
    }

    function quitStarting()
    {
        // Avoid the push transition animation
        var component = Qt.createComponent("QuitSegue.qml")
        stackView.replace(stackView.currentItem, component.createObject(stackView, {"appName": appName}), StackView.Immediate)

        // Show the Qt window again to show quit segue
        window.visible = true
    }

    function sessionFinished(portTestResult)
    {
        if (portTestResult !== 0 && portTestResult !== -1 && streamSegueErrorDialog.text) {
            streamSegueErrorDialog.text += "\n\n" + qsTr("This PC's Internet connection is blocking Moonlight. Streaming over the Internet may not work while connected to this network.")
        }

        // Re-enable GUI gamepad usage now
        SdlGamepadKeyNavigation.enable()

        // Turn off AirPlay if we turned it on for this stream
        AirPlayManager.disconnectDevice()

        // Pop the StreamSegue off the stack if this is a GUI-based app launch
        if (!quitAfter) {
            stackView.pop()
        }

        if (quitAfter && !streamSegueErrorDialog.text) {
            // If this was a CLI launch without errors, exit now
            Qt.quit()
        }
        else {
            // Show the Qt window again after streaming
            window.visible = true

            // Display any launch errors. We do this after
            // the Qt UI is visible again to prevent losing
            // focus on the dialog which would impact gamepad
            // users.
            if (streamSegueErrorDialog.text) {
                streamSegueErrorDialog.quitAfter = quitAfter
                streamSegueErrorDialog.open()
            }
        }
    }

    function sessionReadyForDeletion()
    {
        // Garbage collect the Session object since it's pretty heavyweight
        // and keeps other libraries (like SDL_TTF) around until it is deleted.
        session = null
        gc()
    }

    StackView.onDeactivating: {
        // Show the toolbar again when popped off the stack
        toolBar.visible = true

        // Re-enable GUI gamepad usage now
        SdlGamepadKeyNavigation.enable()
    }

    StackView.onActivated: {
        // Hide the toolbar before we start loading
        toolBar.visible = false

        // Hook up our signals
        session.stageStarting.connect(stageStarting)
        session.stageFailed.connect(stageFailed)
        session.connectionStarted.connect(connectionStarted)
        session.displayLaunchError.connect(displayLaunchError)
        session.quitStarting.connect(quitStarting)
        session.sessionFinished.connect(sessionFinished)
        session.readyForDeletion.connect(sessionReadyForDeletion)

        // Ensure the SystemProperties async thread is finished,
        // since it may currently be using the SDL video subsystem
        SystemProperties.waitForAsyncLoad()

        // Let the user pick where to show the stream (an AirPlay receiver or
        // another display) before we start. When we can turn on AirPlay for
        // the user, we offer this even with a single display.
        if (!quitAfter &&
                StreamingPreferences.streamDisplayMode === StreamingPreferences.SDM_ASK &&
                SystemProperties.hasDesktopEnvironment &&
                (Qt.application.screens.length > 1 || AirPlayManager.isSupported)) {
            displayPickerDialog.open()
        }
        else {
            // Kick off the stream
            streamLoader.active = true
        }
    }

    function startOnScreen(screenName, audioDevice)
    {
        session.setTargetScreen(screenName)
        session.setAudioOutputDevice(audioDevice)
        displayPickerDialog.streamStarting = true
        displayPickerDialog.close()

        // Kick off the stream
        streamLoader.active = true
    }

    Connections {
        target: AirPlayManager

        onConnectFinished: {
            var deviceName = displayPickerDialog.pendingAirPlayDevice
            if (deviceName === "") {
                // Not ours, or the picker was cancelled while we were connecting
                return
            }

            displayPickerDialog.pendingAirPlayDevice = ""
            if (success) {
                // If the receiver became a separate display, newScreenName puts the
                // stream there. Otherwise the receiver mirrors this screen.
                startOnScreen(newScreenName, deviceName)
            }
            else {
                displayPickerDialog.errorText = error
            }
        }
    }

    NavigableDialog {
        id: displayPickerDialog
        property bool streamStarting: false
        property string pendingAirPlayDevice: ""
        property string errorText: ""

        title: qsTr("Stream to display")
        standardButtons: Dialog.Cancel

        onOpened: {
            streamStarting = false
            pendingAirPlayDevice = ""
            errorText = ""
            AirPlayManager.startDiscovery()
            if (displayRepeater.count > 0) {
                displayRepeater.itemAt(0).forceActiveFocus()
            }
        }

        onClosed: {
            AirPlayManager.stopDiscovery()

            // Cancelling the picker cancels the stream
            if (!streamStarting) {
                if (pendingAirPlayDevice !== "") {
                    AirPlayManager.cancelConnect()
                }
                pendingAirPlayDevice = ""
                stackView.pop()
            }
        }

        Column {
            spacing: 10

            Label {
                width: 400
                text: qsTr("Choose where the stream should be shown. This computer's keyboard, mouse, and gamepads will keep controlling the stream.")
                wrapMode: Text.Wrap
            }

            Repeater {
                id: displayRepeater

                // Qt.application.screens updates live, so displays connected
                // while this dialog is open show up immediately.
                model: Qt.application.screens

                Button {
                    width: 400
                    enabled: !AirPlayManager.busy
                    text: {
                        var label = modelData.name + " (" + modelData.width + "x" + modelData.height + ")"
                        if (window.screen && modelData.name === window.screen.name) {
                            label += " - " + qsTr("this screen")
                        }
                        return label
                    }

                    onClicked: startOnScreen(modelData.name, "")
                    Keys.onReturnPressed: clicked()
                    Keys.onEnterPressed: clicked()
                    KeyNavigation.down: index + 1 < displayRepeater.count ?
                                            displayRepeater.itemAt(index + 1) : airPlayRepeater.itemAt(0)
                    KeyNavigation.up: index > 0 ? displayRepeater.itemAt(index - 1) : null
                }
            }

            Label {
                width: 400
                visible: AirPlayManager.isSupported
                text: qsTr("AirPlay")
                font.bold: true
            }

            Repeater {
                id: airPlayRepeater
                model: AirPlayManager.isSupported ? AirPlayManager.devices : []

                Button {
                    width: 400
                    enabled: !AirPlayManager.busy
                    text: modelData

                    onClicked: {
                        displayPickerDialog.errorText = ""
                        displayPickerDialog.pendingAirPlayDevice = modelData
                        AirPlayManager.connectDevice(modelData)
                    }
                    Keys.onReturnPressed: clicked()
                    Keys.onEnterPressed: clicked()
                    KeyNavigation.down: airPlayRepeater.itemAt(index + 1)
                    KeyNavigation.up: index > 0 ? airPlayRepeater.itemAt(index - 1) :
                                                  displayRepeater.itemAt(displayRepeater.count - 1)
                }
            }

            Row {
                spacing: 10
                visible: AirPlayManager.isSupported && (AirPlayManager.busy || airPlayRepeater.count === 0)

                BusyIndicator {
                    running: parent.visible
                    height: 30
                    width: 30
                }

                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 360
                    wrapMode: Text.Wrap
                    text: AirPlayManager.busy ?
                              qsTr("Turning on AirPlay to %1...").arg(displayPickerDialog.pendingAirPlayDevice) :
                              qsTr("Looking for AirPlay devices...")
                }
            }

            Label {
                width: 400
                visible: displayPickerDialog.errorText !== ""
                text: displayPickerDialog.errorText
                color: "red"
                wrapMode: Text.Wrap
            }

            Button {
                visible: AirPlayManager.isSupported && displayPickerDialog.errorText !== "" && !AirPlayManager.hasPermission()
                text: qsTr("Open Accessibility settings")
                onClicked: AirPlayManager.openPermissionSettings()
            }

            Label {
                width: 400
                visible: AirPlayManager.isSupported
                text: qsTr("Moonlight turns on AirPlay screen mirroring for you and turns it off when the stream ends. The first time, macOS will ask you to allow Moonlight under Accessibility.")
                wrapMode: Text.Wrap
                font.pointSize: 10
            }
        }
    }

    Timer {
        id: startSessionTimer
        onTriggered: {
            // Garbage collect QML stuff before we start streaming,
            // since we'll probably be streaming for a while and we
            // won't be able to GC during the stream.
            gc()

            // Run the streaming session to completion
            session.start()
        }
    }

    Loader {
        id: streamLoader
        active: false
        asynchronous: true

        onLoaded: {
            // Set the hint text. We do this here rather than
            // in the hintText control itself to synchronize
            // with Session.exec() which requires no concurrent
            // gamepad usage.
            hintText.text = qsTr("Tip:") + " " + qsTr("Press %1 to disconnect your session").arg(SdlGamepadKeyNavigation.getConnectedGamepads() > 0 ?
                                                  qsTr("Start+Select+L1+R1") : qsTr("Ctrl+Alt+Shift+Q"))

            // Stop GUI gamepad usage now
            SdlGamepadKeyNavigation.disable()

            // Initialize the session and probe for host/client capabilities
            if (!session.initialize(window)) {
                sessionFinished(0);
                sessionReadyForDeletion();
                return;
            }

            // This spinner is shown only after session.initialize() has completed
            // to prevent active animations from running during decoder probing,
            // which causes re-entrant event loop livelocks with libdecor-gtk.
            stageSpinner.visible = true

            // Don't wait unless we have toasts to display
            startSessionTimer.interval = 0

            // Display the toasts together in a vertical centered arrangement
            var yOffset = 0
            for (var i = 0; i < session.launchWarnings.length; i++) {
                var text = session.launchWarnings[i]
                console.warn(text)

                // Show the tooltip for 3 seconds
                var toast = Qt.createQmlObject('import QtQuick.Controls 2.2; ToolTip {}', parent, '')
                toast.timeout = 3000
                toast.text = text
                toast.y += yOffset
                toast.visible = true

                // Offset the next toast below the previous one
                yOffset = toast.y + toast.padding + toast.height

                // Allow an extra 500 ms for the tooltip's fade-out animation to finish
                startSessionTimer.interval = toast.timeout + 500;
            }

            // Start the timer to wait for toasts (or start the session immediately)
            startSessionTimer.start()
        }

        sourceComponent: Item {}
    }

    Row {
        anchors.centerIn: parent
        spacing: 5

        BusyIndicator {
            id: stageSpinner
            running: visible
            visible: false
        }

        Label {
            id: stageLabel
            height: stageSpinner.height
            text: stageText
            font.pointSize: 20
            verticalAlignment: Text.AlignVCenter

            wrapMode: Text.Wrap
        }
    }

    Label {
        id: hintText
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 50
        anchors.horizontalCenter: parent.horizontalCenter
        font.pointSize: 18
        verticalAlignment: Text.AlignVCenter

        wrapMode: Text.Wrap
    }
}
