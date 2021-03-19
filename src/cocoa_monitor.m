//========================================================================
// GLFW 3.4 macOS - www.glfw.org
//------------------------------------------------------------------------
// Copyright (c) 2002-2006 Marcus Geelnard
// Copyright (c) 2006-2019 Camilla Löwy <elmindreda@glfw.org>
//
// This software is provided 'as-is', without any express or implied
// warranty. In no event will the authors be held liable for any damages
// arising from the use of this software.
//
// Permission is granted to anyone to use this software for any purpose,
// including commercial applications, and to alter it and redistribute it
// freely, subject to the following restrictions:
//
// 1. The origin of this software must not be misrepresented; you must not
//    claim that you wrote the original software. If you use this software
//    in a product, an acknowledgment in the product documentation would
//    be appreciated but is not required.
//
// 2. Altered source versions must be plainly marked as such, and must not
//    be misrepresented as being the original software.
//
// 3. This notice may not be removed or altered from any source
//    distribution.
//
//========================================================================
// It is fine to use C99 in this file because it will not be built with VS
//========================================================================

#include "internal.h"

#include <stdlib.h>
#include <limits.h>
#include <math.h>

#include <IOKit/graphics/IOGraphicsLib.h>
#include <ApplicationServices/ApplicationServices.h>


// Get the name of the specified display, or NULL
//
static char* getMonitorName(CGDirectDisplayID displayID, NSScreen* screen)
{
    // IOKit doesn't work on Apple Silicon anymore
    // Luckily, 10.15 introduced -[NSScreen localizedName].
    // Use it if available, and fall back to IOKit otherwise.
    if (screen)
    {
        if ([screen respondsToSelector:@selector(localizedName)])
        {
            NSString* name = [screen valueForKey:@"localizedName"];
            if (name)
                return _glfw_strdup([name UTF8String]);
        }
    }
    io_iterator_t it;
    io_service_t service;
    CFDictionaryRef info;

    if (IOServiceGetMatchingServices(kIOMasterPortDefault,
                                     IOServiceMatching("IODisplayConnect"),
                                     &it) != 0)
    {
        // This may happen if a desktop Mac is running headless
        return NULL;
    }

    while ((service = IOIteratorNext(it)) != 0)
    {
        info = IODisplayCreateInfoDictionary(service,
                                             kIODisplayOnlyPreferredName);

        CFNumberRef vendorIDRef =
            CFDictionaryGetValue(info, CFSTR(kDisplayVendorID));
        CFNumberRef productIDRef =
            CFDictionaryGetValue(info, CFSTR(kDisplayProductID));
        if (!vendorIDRef || !productIDRef)
        {
            CFRelease(info);
            continue;
        }

        unsigned int vendorID, productID;
        CFNumberGetValue(vendorIDRef, kCFNumberIntType, &vendorID);
        CFNumberGetValue(productIDRef, kCFNumberIntType, &productID);

        if (CGDisplayVendorNumber(displayID) == vendorID &&
            CGDisplayModelNumber(displayID) == productID)
        {
            // Info dictionary is used and freed below
            break;
        }

        CFRelease(info);
    }

    IOObjectRelease(it);

    if (!service)
    {
        _glfwInputError(GLFW_PLATFORM_ERROR,
                        "Cocoa: Failed to find service port for display");
        return NULL;
    }

    CFDictionaryRef names =
        CFDictionaryGetValue(info, CFSTR(kDisplayProductName));

    CFStringRef nameRef;

    if (!names || !CFDictionaryGetValueIfPresent(names, CFSTR("en_US"),
                                                 (const void**) &nameRef))
    {
        // This may happen if a desktop Mac is running headless
        CFRelease(info);
        return NULL;
    }

    const CFIndex size =
        CFStringGetMaximumSizeForEncoding(CFStringGetLength(nameRef),
                                          kCFStringEncodingUTF8);
    char* name = calloc(size + 1, 1);
    CFStringGetCString(nameRef, name, size, kCFStringEncodingUTF8);

    CFRelease(info);
    return name;
}


// Check whether the display mode should be included in enumeration
//
static GLFWbool modeIsGood(CGDisplayModeRef mode)
{
    uint32_t flags = CGDisplayModeGetIOFlags(mode);

    if (!(flags & kDisplayModeValidFlag) || !(flags & kDisplayModeSafeFlag))
        return GLFW_FALSE;
    if (flags & kDisplayModeInterlacedFlag)
        return GLFW_FALSE;
    if (flags & kDisplayModeStretchedFlag)
        return GLFW_FALSE;

#if MAC_OS_X_VERSION_MAX_ALLOWED <= 101100
    CFStringRef format = CGDisplayModeCopyPixelEncoding(mode);
    if (CFStringCompare(format, CFSTR(IO16BitDirectPixels), 0) &&
        CFStringCompare(format, CFSTR(IO32BitDirectPixels), 0))
    {
        CFRelease(format);
        return GLFW_FALSE;
    }

    CFRelease(format);
#endif /* MAC_OS_X_VERSION_MAX_ALLOWED */
    return GLFW_TRUE;
}

// Convert Core Graphics display mode to GLFW video mode
//
static GLFWvidmode vidmodeFromCGDisplayMode(CGDisplayModeRef mode,
                                            double fallbackRefreshRate)
{
    GLFWvidmode result;
    result.width = (int) CGDisplayModeGetWidth(mode);
    result.height = (int) CGDisplayModeGetHeight(mode);
    result.refreshRate = (int) round(CGDisplayModeGetRefreshRate(mode));

    if (result.refreshRate == 0)
        result.refreshRate = (int) round(fallbackRefreshRate);

#if MAC_OS_X_VERSION_MAX_ALLOWED <= 101100
    CFStringRef format = CGDisplayModeCopyPixelEncoding(mode);
    if (CFStringCompare(format, CFSTR(IO16BitDirectPixels), 0) == 0)
    {
        result.redBits = 5;
        result.greenBits = 5;
        result.blueBits = 5;
    }
    else
#endif /* MAC_OS_X_VERSION_MAX_ALLOWED */
    {
        result.redBits = 8;
        result.greenBits = 8;
        result.blueBits = 8;
    }

#if MAC_OS_X_VERSION_MAX_ALLOWED <= 101100
    CFRelease(format);
#endif /* MAC_OS_X_VERSION_MAX_ALLOWED */
    return result;
}

// Starts reservation for display fading
//
static CGDisplayFadeReservationToken beginFadeReservation(void)
{
    CGDisplayFadeReservationToken token = kCGDisplayFadeReservationInvalidToken;

    if (CGAcquireDisplayFadeReservation(5, &token) == kCGErrorSuccess)
    {
        CGDisplayFade(token, 0.3,
                      kCGDisplayBlendNormal,
                      kCGDisplayBlendSolidColor,
                      0.0, 0.0, 0.0,
                      TRUE);
    }

    return token;
}

// Ends reservation for display fading
//
static void endFadeReservation(CGDisplayFadeReservationToken token)
{
    if (token != kCGDisplayFadeReservationInvalidToken)
    {
        CGDisplayFade(token, 0.5,
                      kCGDisplayBlendSolidColor,
                      kCGDisplayBlendNormal,
                      0.0, 0.0, 0.0,
                      FALSE);
        CGReleaseDisplayFadeReservation(token);
    }
}

// Finds and caches the NSScreen corresponding to the specified monitor
//
static GLFWbool refreshMonitorScreen(_GLFWmonitor* monitor)
{
    if (monitor->ns.screen)
        return GLFW_TRUE;

    for (NSScreen* screen in [NSScreen screens])
    {
        NSNumber* displayID = [screen deviceDescription][@"NSScreenNumber"];

        // HACK: Compare unit numbers instead of display IDs to work around
        //       display replacement on machines with automatic graphics
        //       switching
        if (monitor->ns.unitNumber == CGDisplayUnitNumber([displayID unsignedIntValue]))
        {
            monitor->ns.screen = screen;
            return GLFW_TRUE;
        }
    }

    _glfwInputError(GLFW_PLATFORM_ERROR, "Cocoa: Failed to find a screen for monitor");
    return GLFW_FALSE;
}

// Returns the display refresh rate queried from the I/O registry
//
static double getFallbackRefreshRate(CGDirectDisplayID displayID)
{
    double refreshRate = 60.0;

    io_iterator_t it;
    io_service_t service;

    if (IOServiceGetMatchingServices(kIOMasterPortDefault,
                                     IOServiceMatching("IOFramebuffer"),
                                     &it) != 0)
    {
        return refreshRate;
    }

    while ((service = IOIteratorNext(it)) != 0)
    {
        const CFNumberRef indexRef =
            IORegistryEntryCreateCFProperty(service,
                                            CFSTR("IOFramebufferOpenGLIndex"),
                                            kCFAllocatorDefault,
                                            kNilOptions);
        if (!indexRef)
            continue;

        uint32_t index = 0;
        CFNumberGetValue(indexRef, kCFNumberIntType, &index);
        CFRelease(indexRef);

        if (CGOpenGLDisplayMaskToDisplayID(1 << index) != displayID)
            continue;

        const CFNumberRef clockRef =
            IORegistryEntryCreateCFProperty(service,
                                            CFSTR("IOFBCurrentPixelClock"),
                                            kCFAllocatorDefault,
                                            kNilOptions);
        const CFNumberRef countRef =
            IORegistryEntryCreateCFProperty(service,
                                            CFSTR("IOFBCurrentPixelCount"),
                                            kCFAllocatorDefault,
                                            kNilOptions);
        if (!clockRef || !countRef)
            break;

        uint32_t clock = 0, count = 0;
        CFNumberGetValue(clockRef, kCFNumberIntType, &clock);
        CFNumberGetValue(countRef, kCFNumberIntType, &count);
        CFRelease(clockRef);
        CFRelease(countRef);

        if (clock > 0 && count > 0)
            refreshRate = clock / (double) count;

        break;
    }

    IOObjectRelease(it);
    return refreshRate;
}


//////////////////////////////////////////////////////////////////////////
//////                       GLFW internal API                      //////
//////////////////////////////////////////////////////////////////////////

// Poll for changes in the set of connected monitors
//
void _glfwPollMonitorsNS(void)
{
    uint32_t displayCount;
    CGGetOnlineDisplayList(0, NULL, &displayCount);
    CGDirectDisplayID* displays = calloc(displayCount, sizeof(CGDirectDisplayID));
    CGGetOnlineDisplayList(displayCount, displays, &displayCount);

    for (int i = 0;  i < _glfw.monitorCount;  i++)
        _glfw.monitors[i]->ns.screen = nil;

    _GLFWmonitor** disconnected = NULL;
    uint32_t disconnectedCount = _glfw.monitorCount;
    if (disconnectedCount)
    {
        disconnected = calloc(_glfw.monitorCount, sizeof(_GLFWmonitor*));
        memcpy(disconnected,
               _glfw.monitors,
               _glfw.monitorCount * sizeof(_GLFWmonitor*));
    }

    for (uint32_t i = 0;  i < displayCount;  i++)
    {
        if (CGDisplayIsAsleep(displays[i]))
            continue;

        const uint32_t unitNumber = CGDisplayUnitNumber(displays[i]);
        NSScreen* screen = nil;

        for (screen in [NSScreen screens])
        {
            NSNumber* screenNumber = [screen deviceDescription][@"NSScreenNumber"];

            // HACK: Compare unit numbers instead of display IDs to work around
            //       display replacement on machines with automatic graphics
            //       switching
            if (CGDisplayUnitNumber([screenNumber unsignedIntValue]) == unitNumber)
                break;
        }

        // HACK: Compare unit numbers instead of display IDs to work around
        //       display replacement on machines with automatic graphics
        //       switching
        uint32_t j;
        for (j = 0;  j < disconnectedCount;  j++)
        {
            if (disconnected[j] && disconnected[j]->ns.unitNumber == unitNumber)
            {
                _glfwInputMonitor(disconnected[j], 3, GLFW_DONT_CARE);
                disconnected[j]->ns.screen = screen;
                disconnected[j] = NULL;
                break;
            }
        }

        if (j < disconnectedCount)
            continue;

        const CGSize size = CGDisplayScreenSize(displays[i]);
        char* name = getMonitorName(displays[i], screen);
        if (!name)
            name = _glfw_strdup("Unknown");

        _GLFWmonitor* monitor = _glfwAllocMonitor(name, size.width, size.height);
        monitor->ns.displayID  = displays[i];
        monitor->ns.unitNumber = unitNumber;
        monitor->ns.screen     = screen;

        free(name);

        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displays[i]);
        if (CGDisplayModeGetRefreshRate(mode) == 0.0)
            monitor->ns.fallbackRefreshRate = getFallbackRefreshRate(displays[i]);
        CGDisplayModeRelease(mode);

        _glfwInputMonitor(monitor, GLFW_CONNECTED, _GLFW_INSERT_LAST);
    }

    for (uint32_t i = 0;  i < disconnectedCount;  i++)
    {
        if (disconnected[i])
            _glfwInputMonitor(disconnected[i], GLFW_DISCONNECTED, 0);
    }

    free(disconnected);
    free(displays);
}

// Change the current video mode
//
void _glfwSetVideoModeNS(_GLFWmonitor* monitor, const GLFWvidmode* desired)
{
    GLFWvidmode current;
    _glfwPlatformGetVideoMode(monitor, &current);

    const GLFWvidmode* best = _glfwChooseVideoMode(monitor, desired);
    if (_glfwCompareVideoModes(&current, best) == 0)
        return;

    CFArrayRef modes = CGDisplayCopyAllDisplayModes(monitor->ns.displayID, NULL);
    const CFIndex count = CFArrayGetCount(modes);
    CGDisplayModeRef native = NULL;

    for (CFIndex i = 0;  i < count;  i++)
    {
        CGDisplayModeRef dm = (CGDisplayModeRef) CFArrayGetValueAtIndex(modes, i);
        if (!modeIsGood(dm))
            continue;

        const GLFWvidmode mode =
            vidmodeFromCGDisplayMode(dm, monitor->ns.fallbackRefreshRate);
        if (_glfwCompareVideoModes(best, &mode) == 0)
        {
            native = dm;
            break;
        }
    }

    if (native)
    {
        if (monitor->ns.previousMode == NULL)
            monitor->ns.previousMode = CGDisplayCopyDisplayMode(monitor->ns.displayID);

        CGDisplayFadeReservationToken token = beginFadeReservation();
        CGDisplaySetDisplayMode(monitor->ns.displayID, native, NULL);
        endFadeReservation(token);
    }

    CFRelease(modes);
}

// Restore the previously saved (original) video mode
//
void _glfwRestoreVideoModeNS(_GLFWmonitor* monitor)
{
    if (monitor->ns.previousMode)
    {
        CGDisplayFadeReservationToken token = beginFadeReservation();
        CGDisplaySetDisplayMode(monitor->ns.displayID,
                                monitor->ns.previousMode, NULL);
        endFadeReservation(token);

        CGDisplayModeRelease(monitor->ns.previousMode);
        monitor->ns.previousMode = NULL;
    }
}


//////////////////////////////////////////////////////////////////////////
//////                       GLFW platform API                      //////
//////////////////////////////////////////////////////////////////////////

void _glfwPlatformFreeMonitor(_GLFWmonitor* monitor)
{
}

void _glfwPlatformGetMonitorPos(_GLFWmonitor* monitor, int* xpos, int* ypos)
{
    @autoreleasepool {

    const CGRect bounds = CGDisplayBounds(monitor->ns.displayID);

    if (xpos)
        *xpos = (int) bounds.origin.x;
    if (ypos)
        *ypos = (int) bounds.origin.y;

    } // autoreleasepool
}

void _glfwPlatformGetMonitorContentScale(_GLFWmonitor* monitor,
                                         float* xscale, float* yscale)
{
    @autoreleasepool {

    if (!refreshMonitorScreen(monitor))
        return;

    const NSRect points = [monitor->ns.screen frame];
    const NSRect pixels = [monitor->ns.screen convertRectToBacking:points];

    if (xscale)
        *xscale = (float) (pixels.size.width / points.size.width);
    if (yscale)
        *yscale = (float) (pixels.size.height / points.size.height);

    } // autoreleasepool
}

void _glfwPlatformGetMonitorWorkarea(_GLFWmonitor* monitor,
                                     int* xpos, int* ypos,
                                     int* width, int* height)
{
    @autoreleasepool {

    if (!refreshMonitorScreen(monitor))
        return;

    const NSRect frameRect = [monitor->ns.screen visibleFrame];

    if (xpos)
        *xpos = frameRect.origin.x;
    if (ypos)
        *ypos = _glfwTransformYNS(frameRect.origin.y + frameRect.size.height - 1);
    if (width)
        *width = frameRect.size.width;
    if (height)
        *height = frameRect.size.height;

    } // autoreleasepool
}

GLFWvidmode* _glfwPlatformGetVideoModes(_GLFWmonitor* monitor, int* count)
{
    @autoreleasepool {

    *count = 0;

    CFArrayRef modes = CGDisplayCopyAllDisplayModes(monitor->ns.displayID, NULL);
    const CFIndex found = CFArrayGetCount(modes);
    GLFWvidmode* result = calloc(found, sizeof(GLFWvidmode));

    for (CFIndex i = 0;  i < found;  i++)
    {
        CGDisplayModeRef dm = (CGDisplayModeRef) CFArrayGetValueAtIndex(modes, i);
        if (!modeIsGood(dm))
            continue;

        const GLFWvidmode mode =
            vidmodeFromCGDisplayMode(dm, monitor->ns.fallbackRefreshRate);
        CFIndex j;

        for (j = 0;  j < *count;  j++)
        {
            if (_glfwCompareVideoModes(result + j, &mode) == 0)
                break;
        }

        // Skip duplicate modes
        if (i < *count)
            continue;

        (*count)++;
        result[*count - 1] = mode;
    }

    CFRelease(modes);
    return result;

    } // autoreleasepool
}

void _glfwPlatformGetVideoMode(_GLFWmonitor* monitor, GLFWvidmode *mode)
{
    @autoreleasepool {

    CGDisplayModeRef native = CGDisplayCopyDisplayMode(monitor->ns.displayID);
    *mode = vidmodeFromCGDisplayMode(native, monitor->ns.fallbackRefreshRate);
    CGDisplayModeRelease(native);

    } // autoreleasepool
}

GLFWbool _glfwPlatformGetGammaRamp(_GLFWmonitor* monitor, GLFWgammaramp* ramp)
{
    @autoreleasepool {

    uint32_t size = CGDisplayGammaTableCapacity(monitor->ns.displayID);
    CGGammaValue* values = calloc(size * 3, sizeof(CGGammaValue));

    CGGetDisplayTransferByTable(monitor->ns.displayID,
                                size,
                                values,
                                values + size,
                                values + size * 2,
                                &size);

    _glfwAllocGammaArrays(ramp, size);

    for (uint32_t i = 0; i < size; i++)
    {
        ramp->red[i]   = (unsigned short) (values[i] * 65535);
        ramp->green[i] = (unsigned short) (values[i + size] * 65535);
        ramp->blue[i]  = (unsigned short) (values[i + size * 2] * 65535);
    }

    free(values);
    return GLFW_TRUE;

    } // autoreleasepool
}

void _glfwPlatformForceVideoMode(_GLFWmonitor* monitor, const GLFWvidmode* desired)
{
    _glfwSetVideoModeNS(monitor, desired);
    monitor->ns.previousMode = NULL;
}

void _glfwPlatformSetGammaRamp(_GLFWmonitor* monitor, const GLFWgammaramp* ramp)
{
    @autoreleasepool {

    CGGammaValue* values = calloc(ramp->size * 3, sizeof(CGGammaValue));

    for (unsigned int i = 0;  i < ramp->size;  i++)
    {
        values[i]                  = ramp->red[i] / 65535.f;
        values[i + ramp->size]     = ramp->green[i] / 65535.f;
        values[i + ramp->size * 2] = ramp->blue[i] / 65535.f;
    }

    CGSetDisplayTransferByTable(monitor->ns.displayID,
                                ramp->size,
                                values,
                                values + ramp->size,
                                values + ramp->size * 2);

    free(values);

    } // autoreleasepool
}

//////////////////////////////////////////////////////////////////////////
//////                        GLFW native API                       //////
//////////////////////////////////////////////////////////////////////////

GLFWAPI CGDirectDisplayID glfwGetCocoaMonitor(GLFWmonitor* handle)
{
    _GLFWmonitor* monitor = (_GLFWmonitor*) handle;
    _GLFW_REQUIRE_INIT_OR_RETURN(kCGNullDirectDisplay);
    return monitor->ns.displayID;
}

// This ONLY works on x86_64
GLFWAPI unsigned char* glfwGetCocoaDisplayEDID(GLFWmonitor* handle)
{
    _GLFWmonitor* monitor = (_GLFWmonitor*) handle;
    CGDirectDisplayID displayID = monitor->ns.displayID;
    io_iterator_t it;
    io_service_t service;
    CFDictionaryRef info;

    if (IOServiceGetMatchingServices(kIOMasterPortDefault,
                                     IOServiceMatching("IODisplayConnect"),
                                     &it) != 0)
    {
        // This may happen if a desktop Mac is running headless
        return NULL;
    }

    while ((service = IOIteratorNext(it)) != 0)
    {
        info = IODisplayCreateInfoDictionary(service,
                                             kIODisplayOnlyPreferredName);

        CFNumberRef vendorIDRef =
            CFDictionaryGetValue(info, CFSTR(kDisplayVendorID));
        CFNumberRef productIDRef =
            CFDictionaryGetValue(info, CFSTR(kDisplayProductID));
        if (!vendorIDRef || !productIDRef)
        {
            CFRelease(info);
            continue;
        }

        unsigned int vendorID, productID;
        CFNumberGetValue(vendorIDRef, kCFNumberIntType, &vendorID);
        CFNumberGetValue(productIDRef, kCFNumberIntType, &productID);

        if (CGDisplayVendorNumber(displayID) == vendorID &&
            CGDisplayModelNumber(displayID) == productID)
        {
            // Info dictionary is used and freed below
            break;
        }

        CFRelease(info);
    }

    IOObjectRelease(it);

    if (!service)
    {
        // _glfwInputError(GLFW_PLATFORM_ERROR,
        //                 "Cocoa: Failed to find service port for display");
        return NULL;
    }

    CFDataRef edid =
        CFDictionaryGetValue(info, CFSTR(kIODisplayEDIDKey));

    size_t len = CFDataGetLength(edid);
    unsigned char* out = calloc(len, 1);
    memcpy(out, CFDataGetBytePtr(edid), len);
    CFRelease(info);
    return out;
}

// This ONLY works on arm64
GLFWAPI bool glfwGetM1DisplayParams(GLFWmonitor* handle, char * name, char * serial, uint32_t * product_id, uint32_t * numeric_serial){
    _GLFWmonitor* monitor = (_GLFWmonitor*) handle;
    CGDirectDisplayID displayID = monitor->ns.displayID;
    io_iterator_t it;
    io_service_t service;
    bool ret = false;
    strcpy(serial, "");
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOMobileFramebuffer"),&it) != 0)
    {
        return NULL;
    }
    while ((service = IOIteratorNext(it)) != 0)
    {
         //NSLog(@"DisplayID props -> VID=%x PID=%x UN=%d SN=%x", CGDisplayVendorNumber(displayID), CGDisplayModelNumber(displayID), CGDisplayUnitNumber(displayID), CGDisplaySerialNumber(displayID));
        CFMutableDictionaryRef props;
        kern_return_t t = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, kNilOptions);
        if (t == KERN_SUCCESS) {
            CFDictionaryRef dispAttributes = CFDictionaryGetValue(props, CFSTR("DisplayAttributes"));
            if (dispAttributes != NULL) {
                CFDictionaryRef prodAttributes = CFDictionaryGetValue(dispAttributes, CFSTR("ProductAttributes"));
                if (prodAttributes != NULL) {
                    uint32_t uint_val;
                    CFNumberRef ref = CFDictionaryGetValue(prodAttributes, CFSTR("ProductID"));
                    if (!ref) continue;
                    if (CFNumberGetValue(ref, kCFNumberSInt32Type, &uint_val) && uint_val==CGDisplayModelNumber(displayID)) *product_id = uint_val;
                    else {
                        CFRelease(ref);
                        continue;
                    }
                    ref = CFDictionaryGetValue(prodAttributes, CFSTR("LegacyManufacturerID"));
                    if (!ref) continue;
                    if (CFNumberGetValue(ref, kCFNumberSInt32Type, &uint_val) && uint_val==CGDisplayVendorNumber(displayID));
                    else {
                        CFRelease(ref);
                        continue;
                    }
                    ref = CFDictionaryGetValue(prodAttributes, CFSTR("SerialNumber"));
                    if (!ref) continue;
                    if (CFNumberGetValue(ref, kCFNumberSInt32Type, &uint_val) && uint_val==CGDisplaySerialNumber(displayID)) *numeric_serial = uint_val;
                    else {
                        CFRelease(ref);
                        continue;
                    }
                    CFRelease(ref);
                    CFStringRef strRef = CFDictionaryGetValue(prodAttributes, CFSTR("ProductName"));
                    if (!strRef) continue;
                    if (CFStringGetCString(strRef, name, 14, kCFStringEncodingUTF8)) ret = true;
                    else {
                        CFRelease(strRef);
                        continue;
                    }
                    strRef = CFDictionaryGetValue(prodAttributes, CFSTR("AlphanumericSerialNumber"));
                    if (!strRef) continue;
                    CFStringGetCString(strRef, serial, 14, kCFStringEncodingUTF8);
                    CFRelease(strRef);
                } else {
                    continue;
                }
            } else {
                continue;
            }
        }
    }
    IOObjectRelease(it);
    return ret;
}   
