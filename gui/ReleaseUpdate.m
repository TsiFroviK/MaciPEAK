#import "ReleaseUpdate.h"
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

static NSString *const releaseAPI = @"https://api.github.com/repos/TsiFroviK/MaciPEAK/releases/latest";
static NSString *const assetName = @"MaciPEAK-Builder-macOS.dmg";
static const NSUInteger maximumReleaseSize = 256 * 1024 * 1024;

typedef NS_ENUM(NSInteger, ReleaseErrorCode) {
    ReleaseErrorMetadata = 1,
    ReleaseErrorResponse,
    ReleaseErrorIntegrity
};

static NSError *releaseError(ReleaseErrorCode code, NSString *description) {
    return [NSError errorWithDomain:@"org.macipeak.builder.release" code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

@interface MaciPEAKRelease ()
@property(nonatomic, copy, readwrite) NSString *version;
@property(nonatomic, copy, readwrite) NSURL *downloadURL;
@property(nonatomic, copy, readwrite) NSString *digest;
@property(nonatomic, readwrite) unsigned long long size;
@end

@implementation MaciPEAKRelease
@end

static NSArray<NSNumber *> *versionComponents(NSString *version) {
    if (![version isKindOfClass:NSString.class]) return nil;
    NSArray<NSString *> *components = [version componentsSeparatedByString:@"."];
    if (components.count != 3) return nil;
    NSCharacterSet *nonDigits = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    NSMutableArray<NSNumber *> *numbers = [NSMutableArray arrayWithCapacity:3];
    for (NSString *component in components) {
        if (!component.length || component.length > 9 ||
            (component.length > 1 && [component hasPrefix:@"0"]) ||
            [component rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return nil;
        [numbers addObject:@(component.integerValue)];
    }
    return numbers;
}

static BOOL isNewer(NSArray<NSNumber *> *available, NSArray<NSNumber *> *installed) {
    for (NSUInteger i = 0; i < available.count; i++) {
        NSComparisonResult order = [available[i] compare:installed[i]];
        if (order != NSOrderedSame) return order == NSOrderedDescending;
    }
    return NO;
}

static MaciPEAKRelease *invalidRelease(NSError **error, NSString *description) {
    if (error) *error = releaseError(ReleaseErrorMetadata, description);
    return nil;
}

static BOOL isBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

MaciPEAKRelease *MaciPEAKParseLatestRelease(NSData *data, NSString *installedVersion, NSError **error) {
    if (error) *error = nil;
    NSArray<NSNumber *> *installed = versionComponents(installedVersion);
    if (!installed) return invalidRelease(error, @"The installed builder version is invalid.");

    NSDictionary *release = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![release isKindOfClass:NSDictionary.class] || !isBoolean(release[@"draft"]) ||
        !isBoolean(release[@"prerelease"])) {
        return invalidRelease(error, @"GitHub returned incomplete release information.");
    }
    if ([release[@"draft"] boolValue] || [release[@"prerelease"] boolValue]) return nil;

    NSString *tag = release[@"tag_name"];
    if (![tag isKindOfClass:NSString.class] || ![tag hasPrefix:@"v"]) {
        return invalidRelease(error, @"The latest release has an invalid version tag.");
    }
    NSString *version = [tag substringFromIndex:1];
    NSArray<NSNumber *> *available = versionComponents(version);
    if (!available) return invalidRelease(error, @"The latest release has an invalid version tag.");
    if (!isNewer(available, installed)) return nil;

    NSArray *assets = release[@"assets"];
    if (![assets isKindOfClass:NSArray.class]) return invalidRelease(error, @"The release has no download list.");
    NSString *assetURL = [NSString stringWithFormat:
                          @"https://github.com/TsiFroviK/MaciPEAK/releases/download/%@/%@", tag, assetName];
    for (NSDictionary *asset in assets) {
        if (![asset isKindOfClass:NSDictionary.class] || ![assetName isEqual:asset[@"name"]]) continue;
        if (![@"uploaded" isEqual:asset[@"state"]] || ![assetURL isEqual:asset[@"browser_download_url"]]) {
            return invalidRelease(error, @"The release disk image has an unexpected download address.");
        }

        NSNumber *size = asset[@"size"];
        if (![size isKindOfClass:NSNumber.class] || isBoolean(size) ||
            size.unsignedLongLongValue == 0 || size.unsignedLongLongValue > maximumReleaseSize ||
            ![size isEqualToNumber:@(size.unsignedLongLongValue)]) {
            return invalidRelease(error, @"The release disk image has an invalid size.");
        }

        NSString *digest = asset[@"digest"];
        if (![digest isKindOfClass:NSString.class] || digest.length != 71 || ![digest hasPrefix:@"sha256:"]) {
            return invalidRelease(error, @"The release disk image is missing its SHA-256 checksum.");
        }
        digest = [digest substringFromIndex:7].lowercaseString;
        NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
        if ([digest rangeOfCharacterFromSet:nonHex].location != NSNotFound) {
            return invalidRelease(error, @"The release disk image has an invalid SHA-256 checksum.");
        }

        MaciPEAKRelease *update = [MaciPEAKRelease new];
        update.version = version;
        update.downloadURL = [NSURL URLWithString:assetURL];
        update.digest = digest;
        update.size = size.unsignedLongLongValue;
        return update;
    }
    return invalidRelease(error, @"The release does not include the MaciPEAK disk image.");
}

static NSURLSessionConfiguration *releaseSessionConfiguration(NSTimeInterval resourceTimeout) {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 20;
    configuration.timeoutIntervalForResource = resourceTimeout;
    return configuration;
}

void MaciPEAKCheckForUpdate(NSString *installedVersion, void (^completion)(MaciPEAKRelease *, NSError *)) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:releaseAPI]];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"MaciPEAK-Builder" forHTTPHeaderField:@"User-Agent"];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:releaseSessionConfiguration(35)];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        MaciPEAKRelease *release = nil;
        NSError *error = networkError;
        if (!error) {
            if (![http isKindOfClass:NSHTTPURLResponse.class] || http.statusCode != 200 ||
                ![releaseAPI isEqualToString:response.URL.absoluteString] || !data.length || data.length > 1024 * 1024) {
                error = releaseError(ReleaseErrorResponse, @"GitHub did not return release information.");
            } else {
                release = MaciPEAKParseLatestRelease(data, installedVersion, &error);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(release, error); });
    }] resume];
    [session finishTasksAndInvalidate];
}

static BOOL allowedDownloadURL(NSURL *url) {
    return [url.scheme isEqualToString:@"https"] && !url.user && !url.password && (!url.port || url.port.integerValue == 443) &&
           ([url.host isEqualToString:@"github.com"] || [url.host isEqualToString:@"release-assets.githubusercontent.com"]);
}

static NSURL *temporaryDirectory(NSError **error) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"macipeak-update.XXXXXXXX"];
    char *directory = strdup(path.fileSystemRepresentation);
    if (!directory) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
        return nil;
    }
    NSURL *url = nil;
    if (mkdtemp(directory)) {
        url = [NSURL fileURLWithFileSystemRepresentation:directory isDirectory:YES relativeToURL:nil];
    } else if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    free(directory);
    return url;
}

static NSURL *verifiedImage(MaciPEAKRelease *release, NSURL *location, NSError **error) {
    NSNumber *size = nil;
    if (![location getResourceValue:&size forKey:NSURLFileSizeKey error:error]) return nil;
    if (size.unsignedLongLongValue != release.size) {
        *error = releaseError(ReleaseErrorIntegrity, @"The downloaded disk image has an unexpected size.");
        return nil;
    }

    NSData *image = [NSData dataWithContentsOfURL:location options:NSDataReadingMappedIfSafe error:error];
    if (!image) return nil;
    unsigned char checksum[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(image.bytes, (CC_LONG)image.length, checksum);
    NSMutableString *actual = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < sizeof checksum; i++) [actual appendFormat:@"%02x", (unsigned int)checksum[i]];
    if (![actual isEqualToString:release.digest]) {
        *error = releaseError(ReleaseErrorIntegrity, @"The downloaded disk image failed SHA-256 verification.");
        return nil;
    }

    NSURL *directory = temporaryDirectory(error);
    if (!directory) return nil;
    NSURL *imageURL = [directory URLByAppendingPathComponent:assetName];
    if ([NSFileManager.defaultManager moveItemAtURL:location toURL:imageURL error:error]) return imageURL;
    [NSFileManager.defaultManager removeItemAtURL:directory error:NULL];
    return nil;
}

@interface ReleaseDownload : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, strong) MaciPEAKRelease *update;
@property(nonatomic, copy) void (^completion)(NSURL *, NSError *);
@property(nonatomic, strong) NSURL *result;
@property(nonatomic, strong) NSError *failure;
@end

@implementation ReleaseDownload

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(allowedDownloadURL(request.URL) ? request : nil);
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
      didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)total
 totalBytesExpectedToWrite:(int64_t)expected {
    if (total > (int64_t)self.update.size || expected > (int64_t)self.update.size) {
        self.failure = releaseError(ReleaseErrorIntegrity, @"The download exceeds the published disk image size.");
        [task cancel];
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
 didFinishDownloadingToURL:(NSURL *)location {
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
    if (self.failure) return;
    if (![response isKindOfClass:NSHTTPURLResponse.class] || response.statusCode != 200 || !allowedDownloadURL(response.URL)) {
        self.failure = releaseError(ReleaseErrorResponse, @"GitHub did not serve the release disk image.");
        return;
    }
    NSError *error = nil;
    self.result = verifiedImage(self.update, location, &error);
    self.failure = error;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)networkError {
    NSError *error = self.failure ?: networkError;
    NSURL *result = self.result;
    if (!result && !error) error = releaseError(ReleaseErrorResponse, @"The disk image download ended early.");
    if (error && result) {
        [NSFileManager.defaultManager removeItemAtURL:result.URLByDeletingLastPathComponent error:NULL];
        result = nil;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ self.completion(result, error); });
    [session finishTasksAndInvalidate];
}

@end

void MaciPEAKDownloadUpdate(MaciPEAKRelease *release, void (^completion)(NSURL *, NSError *)) {
    ReleaseDownload *download = [ReleaseDownload new];
    download.update = release;
    download.completion = completion;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:releaseSessionConfiguration(240)
                                                         delegate:download delegateQueue:nil];
    [[session downloadTaskWithURL:release.downloadURL] resume];
}
