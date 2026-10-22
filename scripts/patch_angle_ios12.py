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

# MTLCompileOptions asked for a property 12.2 does not have. The message is sent
# on an ANGLE worker thread (CompileMslTask -> CreateMslShaderLib ->
# LibraryCache::getOrCompileShaderLibrary -> CreateShaderLibrary), so the
# exception is raised with no handler above it and the process aborts while
# compiling the first shader -- the console shows a run that simply stops.
SHADER_LIBRARY_PATCH = (
    "        // Mark all positions in VS with attribute invariant as non-optimizable\n"
    "        options.get().preserveInvariance = usesInvariance;\n",
    """        // husk: ios12 -- -setPreserveInvariance: is not on 12.2's
        // MTLCompileOptions, so sending it raises NSInvalidArgumentException on
        // this worker thread and abort() ends the process before the first
        // frame. Without it invariant vertex outputs may be optimised; the
        // alternative is not compiling a shader at all.
        if ([options.get() respondsToSelector:sel_registerName("setPreserveInvariance:")])
        {
            options.get().preserveInvariance = usesInvariance;
        }
""",
)

# -hasUnifiedMemory is iOS 13. It is consulted for every buffer's storage mode,
# so it is the next selector that would abort the process after the shader one.
CONTEXT_DEVICE_PATCH = (
    "bool ContextDevice::hasUnifiedMemory() const\n"
    "{\n"
    "    return [get() hasUnifiedMemory];\n"
    "}\n",
    """bool ContextDevice::hasUnifiedMemory() const
{
    // husk: ios12 -- -hasUnifiedMemory is iOS 13. Every Apple GPU this can run
    // on shares memory with the CPU, which is also the answer the selector
    // gives on 13 and later, so that is the fallback.
    if (![get() respondsToSelector:sel_registerName("hasUnifiedMemory")])
    {
        return true;
    }
    return [get() hasUnifiedMemory];
}
""",
)

# Per-render-pass properties. These are not probes: they run while encoding, so
# one missing selector ends the run before anything is drawn. Both arrived with
# iOS 13 and both are read on every pass.
RASTERIZATION_RATE_MAP_PATCH = (
    """RenderCommandEncoder &RenderCommandEncoder::setRasterizationRateMap(id<MTLRasterizationRateMap> map)
{
    if (map != mCachedRenderPassDescObjC.get().rasterizationRateMap)
    {
        mCachedRenderPassDescObjC.get().rasterizationRateMap = map;
    }

    return *this;
}
""",
    """RenderCommandEncoder &RenderCommandEncoder::setRasterizationRateMap(id<MTLRasterizationRateMap> map)
{
    // husk: ios12 -- MTLRenderPassDescriptor gained -rasterizationRateMap in
    // iOS 13, and reset() calls this with nil for every encoder, so the first
    // render pass of the first frame died on an unrecognized selector. Without
    // the property there is no rate map to carry anyway.
    id<MTLRenderPassDescriptor> desc = mCachedRenderPassDescObjC.get();
    if (![desc respondsToSelector:sel_registerName("rasterizationRateMap")])
    {
        return *this;
    }
    if (map != desc.rasterizationRateMap)
    {
        desc.rasterizationRateMap = map;
    }

    return *this;
}
""",
)

MEMORY_BARRIER_PATCH = (
    """inline void MemoryBarrierCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    MTLBarrierScope scope  = stream->fetch<MTLBarrierScope>();
    MTLRenderStages after  = stream->fetch<MTLRenderStages>();
    MTLRenderStages before = stream->fetch<MTLRenderStages>();
    [encoder memoryBarrierWithScope:scope afterStages:after beforeStages:before];
}
""",
    """inline void MemoryBarrierCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    MTLBarrierScope scope  = stream->fetch<MTLBarrierScope>();
    MTLRenderStages after  = stream->fetch<MTLRenderStages>();
    MTLRenderStages before = stream->fetch<MTLRenderStages>();
    // husk: ios12 -- -memoryBarrierWithScope:afterStages:beforeStages: is
    // API_UNAVAILABLE(ios) even in today's SDK; Apple's iOS answer is the
    // resource form used just below. So the message is never implemented on
    // this device and sending it aborts the process. A glMemoryBarrier that
    // cannot be expressed is dropped instead of fatal -- the pass still draws,
    // possibly with the ordering the app was trying to force.
    if ([encoder respondsToSelector:sel_registerName(
                                    "memoryBarrierWithScope:afterStages:beforeStages:")])
    {
        [encoder memoryBarrierWithScope:scope afterStages:after beforeStages:before];
    }
}
""",
)

STORE_ACTION_OPTIONS_PATCH = (
    """    dst.loadAction         = src.loadAction;
    dst.storeAction        = src.storeAction;
    dst.storeActionOptions = src.storeActionOptions;
""",
    """    dst.loadAction         = src.loadAction;
    dst.storeAction        = src.storeAction;
    // husk: ios12 -- MTLStoreActionOptions on an attachment descriptor is iOS
    // 13. The descriptor is rebuilt for every render pass, so leaving this
    // unguarded ends the run on the first pass with an unrecognized selector.
    if ([dst respondsToSelector:sel_registerName("setStoreActionOptions:")])
    {
        dst.storeActionOptions = src.storeActionOptions;
    }
""",
)

SWIZZLE_VIEW_PATCH = (
    """        set(angle::adoptObjCPtr([original->get() newTextureViewWithPixelFormat:pixelFormat
                                                                   textureType:textureType
                                                                        levels:levels
                                                                        slices:slices
                                                                       swizzle:swizzle]));
""",
    """        // husk: ios12 -- the swizzle: form is iOS 13. Without it the view is
        // still created; on 12.2 the channel order simply stays as the source
        // texture has it.
        id<MTLTexture> swizzleSource = original->get();
        if ([swizzleSource respondsToSelector:sel_registerName(
                                               "newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:")])
        {
            set(angle::adoptObjCPtr([swizzleSource newTextureViewWithPixelFormat:pixelFormat
                                                                     textureType:textureType
                                                                          levels:levels
                                                                          slices:slices
                                                                         swizzle:swizzle]));
        }
        else
        {
            set(angle::adoptObjCPtr([swizzleSource newTextureViewWithPixelFormat:pixelFormat
                                                                     textureType:textureType
                                                                          levels:levels
                                                                          slices:slices]));
        }
""",
)

FILES = [
    ("mtl_utils.mm", "#include <TargetConditionals.h>\n",
     [(MTL_UTILS_OLD, MTL_UTILS_NEW), SHADER_LIBRARY_PATCH]),
    ("DisplayMtl.mm", "#include <sys/param.h>\n", DISPLAY_PATCHES),
    ("mtl_context_device.mm", '#include "libANGLE/renderer/metal/mtl_context_device.h"\n',
     [CONTEXT_DEVICE_PATCH]),
    ("mtl_command_buffer.mm", "#include <type_traits>\n",
     [RASTERIZATION_RATE_MAP_PATCH, MEMORY_BARRIER_PATCH]),
    ("mtl_state_cache.mm", "#include <sstream>\n", [STORE_ACTION_OPTIONS_PATCH]),
    ("mtl_resources.mm", "#include <TargetConditionals.h>\n", [SWIZZLE_VIEW_PATCH]),
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
