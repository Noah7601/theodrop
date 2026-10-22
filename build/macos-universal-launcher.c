// Universal (arm64 + x86_64) trampoline for TheoDrop.app.
//
// A self-contained .NET application cannot be merged into one universal binary: the runtime ships
// architecture-specific managed assemblies (System.Private.CoreLib and friends) next to the native
// libraries, and lipo only merges Mach-O files. The bundle therefore keeps a complete payload per
// architecture in Contents/MacOS/arm64 and Contents/MacOS/x64, and this trampoline - the only truly
// universal binary - starts the payload that matches the slice macOS chose for it.
//
// CFProcessPath is exported before the exec so CoreFoundation still resolves TheoDrop.app as the
// main bundle (Finder services, the Dock icon and the application name depend on it).
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__aarch64__) || defined(__arm64__)
#define THEODROP_SLICE "arm64"
#else
#define THEODROP_SLICE "x64"
#endif

int main(int argc, char **argv) {
    char self[PATH_MAX];
    uint32_t size = (uint32_t)sizeof(self);
    if (_NSGetExecutablePath(self, &size) != 0) {
        fprintf(stderr, "TheoDrop: cannot determine the executable path.\n");
        return 1;
    }

    char resolved[PATH_MAX];
    if (realpath(self, resolved) == NULL) {
        fprintf(stderr, "TheoDrop: cannot resolve %s: %s\n", self, strerror(errno));
        return 1;
    }

    char directory[PATH_MAX];
    char name[PATH_MAX];
    snprintf(directory, sizeof(directory), "%s", resolved);
    snprintf(name, sizeof(name), "%s", resolved);

    char target[PATH_MAX];
    if (snprintf(target, sizeof(target), "%s/%s/%s", dirname(directory), THEODROP_SLICE, basename(name)) >= (int)sizeof(target)) {
        fprintf(stderr, "TheoDrop: the application path is too long.\n");
        return 1;
    }

    setenv("CFProcessPath", self, 1);
    execv(target, argv);
    fprintf(stderr, "TheoDrop: cannot start %s: %s\n", target, strerror(errno));
    return 127;
}
