#import "InstallUpdate.h"
#import <AppKit/AppKit.h>
#include <errno.h>
#include <limits.h>
#include <mach/machine.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

NSErrorDomain const MPInstallUpdateErrorDomain = @"org.macipeak.builder.install-update";
static NSString *const BuilderIdentifier = @"org.macipeak.builder";
static NSString *const BuilderName = @"MaciPEAK Builder";

static NSError *InstallError(MPInstallUpdateErrorCode code, NSString *detail) {
    return [NSError errorWithDomain:MPInstallUpdateErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: detail}];
}

static BOOL RunTool(NSString *path, NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:NULL]) return NO;
    [task waitUntilExit];
    return task.terminationReason == NSTaskTerminationReasonExit && task.terminationStatus == 0;
}

static NSURL *NewPrivateDirectory(NSURL *parent) {
    NSString *name = [@".macipeak-update-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSURL *folder = [parent URLByAppendingPathComponent:name isDirectory:YES];
    NSDictionary *attributes = @{NSFilePosixPermissions: @0700};
    if (![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:NO
                                                attributes:attributes error:NULL]) return nil;
    return folder.URLByResolvingSymlinksInPath;
}

static BOOL ReadDirectory(NSURL *url, struct stat *info) {
    return lstat(url.fileSystemRepresentation, info) == 0 && S_ISDIR(info->st_mode);
}

static BOOL MatchesDirectory(NSURL *url, const struct stat *expected) {
    struct stat current;
    return ReadDirectory(url, &current) && current.st_dev == expected->st_dev && current.st_ino == expected->st_ino;
}

static BOOL IsMountedAt(NSURL *url) {
    struct statfs info;
    const char *mountPath = url.fileSystemRepresentation;
    char mounted[PATH_MAX];
    char requested[PATH_MAX];
    return statfs(mountPath, &info) == 0 && realpath(info.f_mntonname, mounted)
        && realpath(mountPath, requested) && strcmp(mounted, requested) == 0;
}

static NSError *CopyFromImage(NSURL *image, NSURL *stagedApp) {
    NSURL *mount = NewPrivateDirectory(NSFileManager.defaultManager.temporaryDirectory);
    if (!mount) return InstallError(MPInstallUpdateAttachFailed, @"Could not create an update mount point.");

    NSString *hdiutil = @"/usr/bin/hdiutil";
    BOOL attached = RunTool(hdiutil, @[@"attach", @"-readonly", @"-nobrowse", @"-noautoopen",
                                      @"-mountpoint", mount.path, image.path]);
    NSError *error = nil;
    if (!attached || !IsMountedAt(mount)) {
        error = InstallError(MPInstallUpdateAttachFailed, @"The update disk image could not be mounted read-only.");
    } else {
        NSURL *source = [mount URLByAppendingPathComponent:[BuilderName stringByAppendingPathExtension:@"app"]
                                              isDirectory:YES];
        struct stat sourceInfo;
        if (!ReadDirectory(source, &sourceInfo)) {
            error = InstallError(MPInstallUpdateInvalidBundle, @"The image has no MaciPEAK Builder application.");
        } else if (!RunTool(@"/usr/bin/ditto", @[source.path, stagedApp.path])) {
            error = InstallError(MPInstallUpdateCopyFailed, @"The updated app could not be copied for installation.");
        }
    }

    if (IsMountedAt(mount)
        && !RunTool(hdiutil, @[@"detach", mount.path])
        && !RunTool(hdiutil, @[@"detach", @"-force", mount.path])) {
        error = InstallError(MPInstallUpdateAttachFailed, @"The update disk image could not be detached.");
    }
    rmdir(mount.fileSystemRepresentation);
    return error;
}

static NSError *CheckStagedApp(NSURL *url, NSString *expectedVersion) {
    NSBundle *bundle = [NSBundle bundleWithURL:url];
    NSArray<NSNumber *> *architectures = bundle.executableArchitectures;
    if (![bundle.bundleIdentifier isEqualToString:BuilderIdentifier]
        || ![bundle.infoDictionary[@"CFBundleShortVersionString"] isEqual:expectedVersion]
        || ![bundle.executableURL.lastPathComponent isEqualToString:BuilderName]
        || ![architectures containsObject:@(CPU_TYPE_ARM64)]
        || ![architectures containsObject:@(CPU_TYPE_X86_64)]
        || !RunTool(@"/usr/bin/codesign", @[@"--verify", @"--deep", @"--strict", @"--all-architectures", url.path])) {
        return InstallError(MPInstallUpdateInvalidBundle, @"The updated app failed its identity, version or signature check.");
    }
    return nil;
}

static NSError *SwapError(void) {
    int failure = errno;
    if (failure == EACCES || failure == EPERM || failure == EROFS || failure == ENOTSUP) {
        return InstallError(MPInstallUpdateDestinationNotWritable, @"The current app location does not support replacement.");
    }
    return InstallError(MPInstallUpdateReplaceFailed, @"The current app could not be replaced.");
}

void MPInstallUpdate(NSURL *diskImageURL, NSString *expectedVersion, NSURL *installedAppURL,
                     void (^completion)(NSError *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *files = NSFileManager.defaultManager;
        NSURL *installed = installedAppURL.URLByResolvingSymlinksInPath;
        NSBundle *currentBundle = [NSBundle bundleWithURL:installed];
        NSString *currentVersion = currentBundle.infoDictionary[@"CFBundleShortVersionString"];
        struct stat original;
        NSError *error = nil;
        NSURL *staging = nil;
        if (![currentBundle.bundleIdentifier isEqualToString:BuilderIdentifier] || ![currentVersion isKindOfClass:NSString.class]
            || [expectedVersion compare:currentVersion options:NSNumericSearch] != NSOrderedDescending
            || !ReadDirectory(installed, &original)) {
            error = InstallError(MPInstallUpdateInvalidBundle, @"The installed builder does not match the requested update.");
        } else {
            staging = NewPrivateDirectory(installed.URLByDeletingLastPathComponent);
            if (!staging) error = InstallError(MPInstallUpdateDestinationNotWritable, @"The app's parent folder is not writable.");
        }

        NSURL *stagedApp = [staging URLByAppendingPathComponent:[BuilderName stringByAppendingPathExtension:@"app"]
                                                   isDirectory:YES];
        if (!error) error = CopyFromImage(diskImageURL, stagedApp);
        if (!error) error = CheckStagedApp(stagedApp, expectedVersion);
        struct stat replacement;
        if (!error && (!MatchesDirectory(installed, &original) || !ReadDirectory(stagedApp, &replacement))) {
            error = InstallError(MPInstallUpdateReplaceFailed, @"The installation changed while staging the update.");
        }
        if (!error && renamex_np(stagedApp.fileSystemRepresentation, installed.fileSystemRepresentation, RENAME_SWAP) != 0) {
            error = SwapError();
        }

        if (error) {
            if (staging) [files removeItemAtURL:staging error:NULL];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
            configuration.createsNewApplicationInstance = YES;
            configuration.allowsRunningApplicationSubstitution = NO;
            [[NSWorkspace sharedWorkspace] openApplicationAtURL:installed configuration:configuration
                                              completionHandler:^(NSRunningApplication *app, NSError *launchError) {
                NSError *result = nil;
                if (!app || launchError || app.processIdentifier == getpid()) {
                    if (MatchesDirectory(installed, &replacement)
                        && renamex_np(stagedApp.fileSystemRepresentation, installed.fileSystemRepresentation, RENAME_SWAP) == 0) {
                        result = InstallError(MPInstallUpdateRelaunchFailed, @"macOS could not open the updated builder. The preceding version was restored.");
                    } else {
                        NSString *detail = [@"The previous builder remains available at " stringByAppendingString:stagedApp.path];
                        result = InstallError(MPInstallUpdateRollbackFailed, detail);
                    }
                }
                if (result.code != MPInstallUpdateRollbackFailed) [files removeItemAtURL:staging error:NULL];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            }];
        });
    });
}
