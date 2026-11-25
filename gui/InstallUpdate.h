#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const MPInstallUpdateErrorDomain;

typedef NS_ERROR_ENUM(MPInstallUpdateErrorDomain, MPInstallUpdateErrorCode) {
    MPInstallUpdateDestinationNotWritable = 1,
    MPInstallUpdateInvalidBundle,
    MPInstallUpdateAttachFailed,
    MPInstallUpdateCopyFailed,
    MPInstallUpdateReplaceFailed,
    MPInstallUpdateRelaunchFailed,
    MPInstallUpdateRollbackFailed,
};

// The caller has authenticated the downloaded disk image and keeps it available until completion.
// On success the replacement is running and the caller can terminate the original process.
void MPInstallUpdate(NSURL *diskImageURL, NSString *expectedVersion, NSURL *installedAppURL,
                     void (^completion)(NSError * _Nullable error));

NS_ASSUME_NONNULL_END
