// Thin wrapper to compile ggml-metal.m with -fno-objc-arc in its own SPM target,
// avoiding conflicts with CoreML files that require ARC.
//
// ggml-metal.m uses SWIFTPM_MODULE_BUNDLE to find the metallib resource.
// Since the resource lives in the whisper target's bundle, we define
// SWIFTPM_MODULE_BUNDLE to locate that bundle by name.
#import <Foundation/Foundation.h>

#define SWIFTPM_MODULE_BUNDLE ggml_metal_find_whisper_bundle()

static inline NSBundle * _Nonnull ggml_metal_find_whisper_bundle(void) {
    // SPM resource bundles are named "{package}_{target}.bundle"
    NSBundle *main = [NSBundle mainBundle];
    NSString *path = [main pathForResource:@"whisper.spm_whisper" ofType:@"bundle"];
    if (path) {
        NSBundle *b = [NSBundle bundleWithPath:path];
        if (b) return b;
    }
    return main;
}

#include "../whisper/ggml-metal.m"
