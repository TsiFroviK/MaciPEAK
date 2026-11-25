#import "InstallUpdate.h"
#import <AppKit/AppKit.h>
#include <stdio.h>
#include <stdlib.h>

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "%s\n", (message ?: @"The test fixture operation failed.").UTF8String);
        exit(EXIT_FAILURE);
    }
}

static void Run(NSString *path, NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    NSError *error = nil;
    BOOL launched = [task launchAndReturnError:&error];
    Check(launched, [NSString stringWithFormat:@"%@: %@", path, error]);
    [task waitUntilExit];
    Check(task.terminationStatus == 0, [NSString stringWithFormat:@"%@ exited with %d", path, task.terminationStatus]);
}

static NSURL *InfoFile(NSURL *app) {
    return [app URLByAppendingPathComponent:@"Contents/Info.plist"];
}

static NSString *Version(NSURL *app) {
    return [NSDictionary dictionaryWithContentsOfURL:InfoFile(app) error:NULL][@"CFBundleShortVersionString"];
}

static NSRunningApplication *FindFixtureApp(NSURL *fixture) {
    NSString *path = fixture.URLByResolvingSymlinksInPath.path;
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"org.macipeak.builder"]) {
        if (!app.terminated && [app.bundleURL.URLByResolvingSymlinksInPath.path isEqualToString:path]) return app;
    }
    return nil;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Check(argc == 4, @"Usage: test-install-update IMAGE.dmg MOUNTED_APP.app WRITABLE_DIRECTORY");
        NSURL *originalImage = [NSURL fileURLWithFileSystemRepresentation:argv[1] isDirectory:NO relativeToURL:nil];
        NSURL *releaseApp = [NSURL fileURLWithFileSystemRepresentation:argv[2] isDirectory:YES relativeToURL:nil];
        NSURL *scratch = [NSURL fileURLWithFileSystemRepresentation:argv[3] isDirectory:YES relativeToURL:nil];
        NSURL *work = [scratch URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        NSURL *fixture = [work URLByAppendingPathComponent:@"MaciPEAK Builder.app" isDirectory:YES];
        NSURL *image = [work URLByAppendingPathComponent:@"update.dmg" isDirectory:NO];
        NSFileManager *files = NSFileManager.defaultManager;
        NSError *error = nil;
        BOOL created = [files createDirectoryAtURL:work withIntermediateDirectories:NO attributes:nil error:&error];
        Check(created, error.description);
        // Copy the image so hdiutil requests a new mount instead of reusing the caller's mount.
        BOOL copied = [files copyItemAtURL:originalImage toURL:image error:&error];
        Check(copied, error.description);
        Run(@"/usr/bin/ditto", @[releaseApp.path, fixture.path]);
        NSString *current = @"1.0.1";
        NSString *next = Version(releaseApp);
        Check([next compare:current options:NSNumericSearch] == NSOrderedDescending, @"The fixture needs a newer release image.");
        NSURL *plist = InfoFile(fixture);
        NSMutableDictionary *info = [[NSDictionary dictionaryWithContentsOfURL:plist error:&error] mutableCopy];
        Check(info != nil, error.description);
        info[@"CFBundleShortVersionString"] = current;
        info[@"CFBundleVersion"] = @"2";
        BOOL written = [info writeToURL:plist error:&error];
        Check(written, error.description);
        Run(@"/usr/bin/codesign", @[@"--force", @"--sign", @"-", fixture.path]);

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [FindFixtureApp(fixture) forceTerminate];
            Check(NO, @"Timed out while testing the installer.");
        });
        MPInstallUpdate(image, @"999999999.0.0", fixture, ^(NSError *rejected) {
            Check([rejected.domain isEqualToString:MPInstallUpdateErrorDomain]
                  && rejected.code == MPInstallUpdateInvalidBundle,
                  [NSString stringWithFormat:@"An update with the wrong version must fail: %@", rejected]);
            Check([Version(fixture) isEqualToString:current], @"Rejection changed the installed app.");
            Check(!FindFixtureApp(fixture), @"Rejection relaunched the installed app.");
            MPInstallUpdate(image, next, fixture, ^(NSError *failed) {
                Check(!failed, failed.description);
                Check([Version(fixture) isEqualToString:next], @"The installed app did not change to the release version.");
                NSRunningApplication *launched = FindFixtureApp(fixture);
                Check(launched != nil, @"Launch Services did not start the replacement.");
                [launched forceTerminate];
                Run(@"/usr/bin/codesign", @[@"--verify", @"--deep", @"--strict", @"--all-architectures", fixture.path]);
                Check([files removeItemAtURL:work error:NULL], @"The test fixture could not be removed.");
                printf("Rejected a wrong-version image, then installed and relaunched %s.\n", next.UTF8String);
                exit(EXIT_SUCCESS);
            });
        });
        [NSApp run];
        return EXIT_FAILURE;
    }
}
