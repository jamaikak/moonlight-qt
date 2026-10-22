#include "airplaymirroring.h"

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QThread>

#include "SDL_compat.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

#define CONTROL_CENTER_BUNDLE_ID @"com.apple.controlcenter"
#define SCREEN_MIRRORING_EXTRA_ID "com.apple.menuextra.screenmirroring"
#define CONTROL_CENTER_EXTRA_ID "com.apple.menuextra.controlcenter"

// How long to wait for the AirPlay receiver to show up in the menu
#define DEVICE_LIST_TIMEOUT_MS 10000

// How long to wait for the receiver to accept the mirroring session
#define CONNECT_TIMEOUT_MS 20000

// Keep the element tree walk bounded in case of unexpected UI structure
#define MAX_SEARCH_DEPTH 12

#define TR(x) QCoreApplication::translate("AirPlayMirroring", x)

namespace {

// Returns a copy of a string attribute, or an empty string
QString copyStringAttribute(AXUIElementRef element, CFStringRef attribute)
{
    CFTypeRef value = nullptr;
    QString result;

    if (AXUIElementCopyAttributeValue(element, attribute, &value) == kAXErrorSuccess && value != nullptr) {
        if (CFGetTypeID(value) == CFStringGetTypeID()) {
            result = QString::fromCFString((CFStringRef)value);
        }
        CFRelease(value);
    }

    return result;
}

// Returns the integer value of an element (checkbox state), or -1
int copyIntValue(AXUIElementRef element)
{
    CFTypeRef value = nullptr;
    int result = -1;

    if (AXUIElementCopyAttributeValue(element, kAXValueAttribute, &value) == kAXErrorSuccess && value != nullptr) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result);
        }
        else if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            result = CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
        }
        CFRelease(value);
    }

    return result;
}

// Returns a retained array of child elements, or nullptr
CFArrayRef copyElementArray(AXUIElementRef element, CFStringRef attribute)
{
    CFTypeRef value = nullptr;

    if (AXUIElementCopyAttributeValue(element, attribute, &value) == kAXErrorSuccess && value != nullptr) {
        if (CFGetTypeID(value) == CFArrayGetTypeID()) {
            return (CFArrayRef)value;
        }
        CFRelease(value);
    }

    return nullptr;
}

bool supportsPress(AXUIElementRef element)
{
    CFArrayRef actions = nullptr;
    bool result = false;

    if (AXUIElementCopyActionNames(element, &actions) == kAXErrorSuccess && actions != nullptr) {
        result = CFArrayContainsValue(actions, CFRangeMake(0, CFArrayGetCount(actions)), kAXPressAction);
        CFRelease(actions);
    }

    return result;
}

bool elementMatches(AXUIElementRef element, const QString& text, bool matchIdentifier)
{
    if (matchIdentifier) {
        return copyStringAttribute(element, CFSTR("AXIdentifier")).contains(text, Qt::CaseInsensitive);
    }

    return copyStringAttribute(element, kAXTitleAttribute).contains(text, Qt::CaseInsensitive) ||
           copyStringAttribute(element, kAXDescriptionAttribute).contains(text, Qt::CaseInsensitive) ||
           copyStringAttribute(element, CFSTR("AXIdentifier")).contains(text, Qt::CaseInsensitive);
}

// Depth-first search for a pressable element matching the text. Elements that
// match but can't be pressed (like a text label) resolve to their closest
// pressable ancestor. Returns a retained element or nullptr.
AXUIElementRef findPressable(AXUIElementRef element, const QString& text, bool matchIdentifier,
                             AXUIElementRef pressableAncestor, int depth)
{
    if (depth > MAX_SEARCH_DEPTH) {
        return nullptr;
    }

    if (supportsPress(element)) {
        pressableAncestor = element;
    }

    if (elementMatches(element, text, matchIdentifier) && pressableAncestor != nullptr) {
        CFRetain(pressableAncestor);
        return pressableAncestor;
    }

    AXUIElementRef result = nullptr;
    CFArrayRef children = copyElementArray(element, kAXChildrenAttribute);
    if (children != nullptr) {
        for (CFIndex i = 0; i < CFArrayGetCount(children) && result == nullptr; i++) {
            AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
            result = findPressable(child, text, matchIdentifier, pressableAncestor, depth + 1);
        }
        CFRelease(children);
    }

    return result;
}

// Searches all of Control Center's open windows (its menu popovers)
AXUIElementRef findInWindows(AXUIElementRef app, const QString& text, bool matchIdentifier)
{
    AXUIElementRef result = nullptr;
    CFArrayRef windows = copyElementArray(app, kAXWindowsAttribute);
    if (windows != nullptr) {
        for (CFIndex i = 0; i < CFArrayGetCount(windows) && result == nullptr; i++) {
            AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
            result = findPressable(window, text, matchIdentifier, nullptr, 0);
        }
        CFRelease(windows);
    }
    return result;
}

bool hasOpenWindows(AXUIElementRef app)
{
    CFArrayRef windows = copyElementArray(app, kAXWindowsAttribute);
    bool result = windows != nullptr && CFArrayGetCount(windows) > 0;
    if (windows != nullptr) {
        CFRelease(windows);
    }
    return result;
}

// Finds a menu bar item that Control Center owns by its identifier. Returns a retained element.
AXUIElementRef findMenuExtra(AXUIElementRef app, const char* identifier)
{
    AXUIElementRef result = nullptr;
    CFArrayRef extrasBars = nullptr;

    // Control Center's items live in the "extras" menu bar
    CFTypeRef extrasBar = nullptr;
    if (AXUIElementCopyAttributeValue(app, CFSTR("AXExtrasMenuBar"), &extrasBar) != kAXErrorSuccess || extrasBar == nullptr) {
        return nullptr;
    }

    extrasBars = copyElementArray((AXUIElementRef)extrasBar, kAXChildrenAttribute);
    if (extrasBars != nullptr) {
        for (CFIndex i = 0; i < CFArrayGetCount(extrasBars) && result == nullptr; i++) {
            AXUIElementRef item = (AXUIElementRef)CFArrayGetValueAtIndex(extrasBars, i);
            if (copyStringAttribute(item, CFSTR("AXIdentifier")) == QString(identifier)) {
                CFRetain(item);
                result = item;
            }
        }
        CFRelease(extrasBars);
    }

    CFRelease(extrasBar);
    return result;
}

AXUIElementRef createControlCenterElement()
{
    @autoreleasepool {
        NSArray<NSRunningApplication*>* apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:CONTROL_CENTER_BUNDLE_ID];
        if (apps.count == 0) {
            return nullptr;
        }

        AXUIElementRef app = AXUIElementCreateApplication(apps[0].processIdentifier);
        if (app != nullptr) {
            // Don't let a busy Control Center hang us forever
            AXUIElementSetMessagingTimeout(app, 2.0f);
        }
        return app;
    }
}

// Opens the Screen Mirroring menu. Returns the retained menu bar item that
// was clicked (so it can be clicked again to close the menu), or nullptr.
AXUIElementRef openScreenMirroringMenu(AXUIElementRef app, QString& error)
{
    // Best case: Screen Mirroring has its own menu bar item
    AXUIElementRef item = findMenuExtra(app, SCREEN_MIRRORING_EXTRA_ID);
    if (item != nullptr) {
        if (AXUIElementPerformAction(item, kAXPressAction) == kAXErrorSuccess) {
            return item;
        }
        CFRelease(item);
    }

    // Otherwise, go through the Control Center menu
    item = findMenuExtra(app, CONTROL_CENTER_EXTRA_ID);
    if (item == nullptr || AXUIElementPerformAction(item, kAXPressAction) != kAXErrorSuccess) {
        if (item != nullptr) {
            CFRelease(item);
        }
        error = TR("Couldn't open Control Center");
        return nullptr;
    }

    // Wait for the Control Center menu to open and find the Screen Mirroring module
    AXUIElementRef module = nullptr;
    QElapsedTimer timer;
    timer.start();
    while (module == nullptr && timer.elapsed() < 3000) {
        QThread::msleep(100);
        module = findInWindows(app, "mirroring", true);
        if (module == nullptr) {
            module = findInWindows(app, "Screen Mirroring", false);
        }
    }

    if (module == nullptr || AXUIElementPerformAction(module, kAXPressAction) != kAXErrorSuccess) {
        if (module != nullptr) {
            CFRelease(module);
        }
        AXUIElementPerformAction(item, kAXPressAction);
        CFRelease(item);
        error = TR("Couldn't find Screen Mirroring in Control Center. Try adding Screen Mirroring to the menu bar in System Settings > Control Center.");
        return nullptr;
    }

    CFRelease(module);
    return item;
}

void closeMenu(AXUIElementRef app, AXUIElementRef menuItem)
{
    // Clicking the menu bar item again closes its menu
    if (hasOpenWindows(app)) {
        AXUIElementPerformAction(menuItem, kAXPressAction);
    }
}

uint32_t getOnlineDisplayCount()
{
    uint32_t count = 0;
    CGGetOnlineDisplayList(0, nullptr, &count);
    return count;
}

// Opens the Screen Mirroring menu, finds the device and either connects or
// disconnects it depending on what we want.
bool toggleDevice(const QString& deviceName, bool wantConnected, bool& alreadyInState, QString& error)
{
    alreadyInState = false;

    if (!AirPlayMirroring::hasPermission(true)) {
        error = TR("Moonlight needs Accessibility permission to turn on AirPlay. Allow Moonlight in System Settings > Privacy & Security > Accessibility, then try again.");
        return false;
    }

    AXUIElementRef app = createControlCenterElement();
    if (app == nullptr) {
        error = TR("Control Center is not running");
        return false;
    }

    AXUIElementRef menuItem = openScreenMirroringMenu(app, error);
    if (menuItem == nullptr) {
        CFRelease(app);
        return false;
    }

    // AirPlay receivers can take a few seconds to appear in the list
    AXUIElementRef device = nullptr;
    QElapsedTimer timer;
    timer.start();
    while (device == nullptr && timer.elapsed() < DEVICE_LIST_TIMEOUT_MS) {
        QThread::msleep(200);
        device = findInWindows(app, deviceName, false);
    }

    if (device == nullptr) {
        closeMenu(app, menuItem);
        CFRelease(menuItem);
        CFRelease(app);
        error = TR("Couldn't find \"%1\" in the Screen Mirroring menu. Make sure it's turned on and on the same network.").arg(deviceName);
        return false;
    }

    // Checkboxes tell us whether the device is already mirroring. Pressing it in
    // that state would do the opposite of what we want.
    int state = copyIntValue(device);
    if (state >= 0 && (state != 0) == wantConnected) {
        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                    "AirPlay device '%s' is already %s",
                    qPrintable(deviceName),
                    wantConnected ? "connected" : "disconnected");
        alreadyInState = true;
        closeMenu(app, menuItem);
        CFRelease(device);
        CFRelease(menuItem);
        CFRelease(app);
        return true;
    }

    uint32_t displaysBefore = getOnlineDisplayCount();
    AXError err = AXUIElementPerformAction(device, kAXPressAction);
    CFRelease(device);

    if (err != kAXErrorSuccess) {
        closeMenu(app, menuItem);
        CFRelease(menuItem);
        CFRelease(app);
        error = TR("Couldn't select \"%1\" (error %2)").arg(deviceName).arg(err);
        return false;
    }

    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                "Selected AirPlay device '%s' in Screen Mirroring menu",
                qPrintable(deviceName));

    bool ret = true;
    if (wantConnected) {
        // Wait for the AirPlay display to come online
        timer.restart();
        while (getOnlineDisplayCount() <= displaysBefore && timer.elapsed() < CONNECT_TIMEOUT_MS) {
            QThread::msleep(250);
        }

        if (getOnlineDisplayCount() <= displaysBefore) {
            error = TR("\"%1\" didn't accept the connection. If the TV is showing a code, enter it and try again.").arg(deviceName);
            ret = false;
        }
        else {
            SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                        "AirPlay display is online after %lld ms",
                        timer.elapsed());

            // Give macOS a moment to finish configuring the display
            QThread::msleep(1000);
        }
    }

    closeMenu(app, menuItem);
    CFRelease(menuItem);
    CFRelease(app);
    return ret;
}

}

bool AirPlayMirroring::isSupported()
{
    return true;
}

bool AirPlayMirroring::hasPermission(bool prompt)
{
    @autoreleasepool {
        NSDictionary* options = @{ (__bridge NSString*)kAXTrustedCheckOptionPrompt: @(prompt) };
        return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    }
}

void AirPlayMirroring::openPermissionSettings()
{
    @autoreleasepool {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    }
}

bool AirPlayMirroring::connect(const QString& deviceName, bool& alreadyConnected, QString& error)
{
    return toggleDevice(deviceName, true, alreadyConnected, error);
}

bool AirPlayMirroring::disconnect(const QString& deviceName, QString& error)
{
    bool alreadyDisconnected;
    return toggleDevice(deviceName, false, alreadyDisconnected, error);
}
