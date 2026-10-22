#!/usr/bin/env python3
"""Make ANGLE's Metal backend survive iOS 12.2 -- four capability probes.

ANGLE asks Metal what the device can do with selectors that arrived with iOS 13
and later, and sends them unguarded. On iOS 12.2 the message does not resolve:
the Objective-C runtime raises NSInvalidArgumentException, C++ unwinding has no
handler, and the process aborts. The crash report names only
DisplayMtl::supportsEitherGPUFamily -- nothing about Metal, nothing about a
missing selector -- and the app dies with zero frames drawn:

    Exception Type: EXC_CRASH (SIGABRT)        Triggered by Thread: GLThread
    __ZN3egl10InitializeEPNS_6ThreadEPNS_7DisplayEPiS4_
    __ZN2rx10DisplayMtl18initializeFeaturesEv
    __ZNK2rx10DisplayMtl23supportsEitherGPUFamilyEhh

Four probes are affected, all during initialisation:

  mtl_utils.mm   SupportsAppleGPUFamily        -supportsFamily:              (13)
  DisplayMtl.mm  supportsShaderBarycentricCoordinates
                                               -supportsShaderBarycentricCoordinates:
                                                                             (14)
  DisplayMtl.mm  supports32BitFloatFiltering   -supports32BitFloatFiltering
  DisplayMtl.mm  pull-model interpolation      -supportsPullModelInterpolation

Each is answered the way 12.2 can answer it: the GPU family question falls back
to -supportsFeatureSet: (iOS 8, same meaning for Apple1..Apple4, which is every
family this hardware can be), and the optional capabilities answer false when
the selector is absent -- which is what ANGLE already does for a device that
lacks them. Nothing changes on iOS 13 and later: the selector is there and the
original call is the one that runs.

Selector lookup is sel_registerName() from <objc/runtime.h> rather than
NSSelectorFromString(), so these files do not gain a Foundation dependency for
one string.

Run with the ANGLE source tree as the argument; idempotent, and it fails loudly
rather than shipping an unpatched dylib.
"""
import os
import sys

MARK = "husk: ios12"
INCLUDE = "#include <objc/runtime.h>  // " + MARK + " -- sel_registerName\n"

MTL_UTILS_OLD = """bool SupportsAppleGPUFamily(id<MTLDevice> device, uint8_t appleFamily)
{
    MTLGPUFamily family;
"""

MTL_UTILS_NEW = """bool SupportsAppleGPUFamily(id<MTLDevice> device, uint8_t appleFamily)
{
    // husk: ios12 -- -supportsFamily: is iOS 13, and sending it here raises
    // NSInvalidArgumentException from the middle of feature detection, which
    // aborts the process before a frame is drawn. -supportsFeatureSet: is iOS 8
    // and answers the same question for Apple1..Apple4, which is every family
    // this hardware can be; Apple5 and later are iOS 13 devices anyway.
    if (![device respondsToSelector:sel_registerName("supportsFamily:")])
    {
        MTLFeatureSet featureSet;
        switch (appleFamily)
        {
            case 1:
                featureSet = MTLFeatureSet_iOS_GPUFamily1_v1;
                break;
            case 2:
                featureSet = MTLFeatureSet_iOS_GPUFamily2_v1;
                break;
            case 3:
                featureSet = MTLFeatureSet_iOS_GPUFamily3_v1;
                break;
            case 4:
                featureSet = MTLFeatureSet_iOS_GPUFamily4_v1;
                break;
            default:
                return false;
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        return [device supportsFeatureSet:featureSet];
#pragma clang diagnostic pop
    }

    MTLGPUFamily family;
"""

DISPLAY_PATCHES = [
    # 32-bit float filtering: absent on 12.2 (it arrived with iOS 12.0 hardware
    # families ANGLE asks about only when the selector exists).
    (
        "    return [mMetalDevice supports32BitFloatFiltering];\n",
        """    // husk: ios12 -- answered false when the device does not implement it, which
    // is what ANGLE does for any device that lacks the capability.
    if (![mMetalDevice respondsToSelector:sel_registerName("supports32BitFloatFiltering")])
    {
        return false;
    }
    return [mMetalDevice supports32BitFloatFiltering];
""",
    ),
    # Barycentric coordinates: iOS 14.
    (
        "    return [mMetalDevice supportsShaderBarycentricCoordinates];\n",
        """    // husk: ios12 -- -supportsShaderBarycentricCoordinates: is iOS 14; querying
    // it on 12.2 throws. No barycentrics, no feature that needs them.
    if (![mMetalDevice respondsToSelector:sel_registerName("supportsShaderBarycentricCoordinates")])
    {
        return false;
    }
    return [mMetalDevice supportsShaderBarycentricCoordinates];
""",
    ),
    # Pull-model interpolation.
    (
        "    if ([mMetalDevice supportsPullModelInterpolation])\n",
        """    // husk: ios12 -- -supportsPullModelInterpolation is not on 12.2 either.
    if ([mMetalDevice respondsToSelector:sel_registerName("supportsPullModelInterpolation")] &&
        [mMetalDevice supportsPullModelInterpolation])
""",
    ),
]

FILES = [
    ("mtl_utils.mm", "#include <TargetConditionals.h>\n", [(MTL_UTILS_OLD, MTL_UTILS_NEW)]),
    ("DisplayMtl.mm", "#include <sys/param.h>\n", DISPLAY_PATCHES),
]


def patch(directory, name, anchor, replacements):
    path = os.path.join(directory, "src/libANGLE/renderer/metal", name)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if MARK in text:
        print("    %s already patched" % name)
        return
    if text.count(anchor) != 1:
        raise SystemExit("patch_angle_ios12: %s: expected one %r to hang the include on"
                         % (name, anchor))
    text = text.replace(anchor, anchor + INCLUDE)
    for old, new in replacements:
        if text.count(old) != 1:
            raise SystemExit(
                "patch_angle_ios12: %s holds %d copies of the text this expects once:\n%s"
                % (name, text.count(old), old))
        text = text.replace(old, new)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("    %s patched (%d probes)" % (name, len(replacements)))


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_angle_ios12.py <ANGLE source tree>")
    for name, anchor, replacements in FILES:
        patch(sys.argv[1], name, anchor, replacements)


if __name__ == "__main__":
    main()
