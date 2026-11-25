#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MaciPEAKRelease : NSObject
@property(nonatomic, copy, readonly) NSString *version;
@property(nonatomic, copy, readonly) NSURL *downloadURL;
@property(nonatomic, copy, readonly) NSString *digest;
@property(nonatomic, readonly) unsigned long long size;
@end

// A nil result without an error means the latest release is already installed.
MaciPEAKRelease * _Nullable MaciPEAKParseLatestRelease(NSData *data, NSString *installedVersion,
                                                        NSError * _Nullable * _Nullable error);

// Completion handlers are called on the main queue.
void MaciPEAKCheckForUpdate(NSString *installedVersion,
                            void (^completion)(MaciPEAKRelease * _Nullable, NSError * _Nullable));

// On success the caller owns the temporary directory containing the image.
void MaciPEAKDownloadUpdate(MaciPEAKRelease *release,
                            void (^completion)(NSURL * _Nullable, NSError * _Nullable));

NS_ASSUME_NONNULL_END
