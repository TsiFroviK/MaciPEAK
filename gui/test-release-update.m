#import "ReleaseUpdate.h"
#include <stdio.h>
#include <stdlib.h>

static NSString *const diskImageName = @"MaciPEAK-Builder-macOS.dmg";
static NSString *const assetURL = @"https://github.com/TsiFroviK/MaciPEAK/releases/download/v1.0.10/MaciPEAK-Builder-macOS.dmg";
static NSString *const digest = @"fedcba98765432100123456789abcdef0123456789abcdeffedcba9876543210";

static void require(BOOL condition, NSString *scenario) {
    if (!condition) {
        fprintf(stderr, "Release update test failed: %s\n", scenario.UTF8String);
        exit(EXIT_FAILURE);
    }
}

static MaciPEAKRelease *parse(id fixture, NSString *installed, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:fixture options:0 error:NULL];
    require(data != nil, @"fixture serialization");
    return MaciPEAKParseLatestRelease(data, installed, error);
}

static void expectUnavailable(id fixture, NSString *installed, NSString *scenario) {
    NSError *error = nil;
    MaciPEAKRelease *release = parse(fixture, installed, &error);
    require(release == nil && error == nil, scenario);
}

static void expectInvalid(id fixture, NSString *scenario) {
    NSError *error = nil;
    MaciPEAKRelease *release = parse(fixture, @"1.0.9", &error);
    require(release == nil && error != nil, scenario);
}

int main(void) {
    @autoreleasepool {
        NSDictionary *diskImage = @{
            @"name": diskImageName,
            @"state": @"uploaded",
            @"browser_download_url": assetURL,
            @"size": @2187561,
            @"digest": [@"sha256:" stringByAppendingString:digest.uppercaseString],
        };
        NSDictionary *latest = @{
            @"tag_name": @"v1.0.10",
            @"draft": @NO,
            @"prerelease": @NO,
            @"assets": @[@{@"name": @"MaciPEAK-source.zip"}, diskImage],
        };

        NSError *error = nil;
        MaciPEAKRelease *available = parse(latest, @"1.0.9", &error);
        require(available != nil && error == nil, @"1.0.10 updates 1.0.9");
        require([available.version isEqualToString:@"1.0.10"], @"parsed version");
        require([available.downloadURL.absoluteString isEqualToString:assetURL], @"parsed download address");
        require([available.digest isEqualToString:digest], @"normalized SHA-256");
        require(available.size == 2187561, @"parsed download size");

        expectUnavailable(latest, @"1.0.10", @"installed version matches latest");
        expectUnavailable(latest, @"1.0.11", @"installed patch version is newer");
        expectUnavailable(latest, @"1.1.0", @"installed minor version is newer");

        for (NSString *field in @[@"draft", @"prerelease"]) {
            NSMutableDictionary *hidden = latest.mutableCopy;
            hidden[field] = @YES;
            expectUnavailable(hidden, @"1.0.9", field);
        }
        expectInvalid(@[@1, @2], @"unexpected top-level JSON type");
        expectInvalid(@{@"tag_name": @"v1.0.10"}, @"missing draft and prerelease states");
        NSMutableDictionary *malformed = latest.mutableCopy;
        malformed[@"tag_name"] = @"v1.0.10-rc.1";
        expectInvalid(malformed, @"unstable tag in a release marked stable");
        malformed[@"tag_name"] = @"v1.0.10";
        malformed[@"assets"] = NSNull.null;
        expectInvalid(malformed, @"missing assets array");

        NSDictionary *invalidAssetValues = @{
            @"name": @"Other-Builder.dmg",
            @"state": @"new",
            @"browser_download_url": @"https://github.com/Other/MaciPEAK/releases/download/v1.0.10/MaciPEAK-Builder-macOS.dmg",
            @"size": @-1,
            @"digest": [@"sha256:z" stringByAppendingString:[digest substringFromIndex:1]],
        };
        for (NSString *field in invalidAssetValues) {
            NSMutableDictionary *asset = diskImage.mutableCopy;
            asset[field] = invalidAssetValues[field];
            NSMutableDictionary *badRelease = latest.mutableCopy;
            badRelease[@"assets"] = @[asset];
            expectInvalid(badRelease, [@"invalid asset " stringByAppendingString:field]);
        }

        NSData *invalidJSON = [@"{" dataUsingEncoding:NSUTF8StringEncoding];
        require(MaciPEAKParseLatestRelease(invalidJSON, @"1.0.9", &error) == nil && error != nil,
                @"truncated JSON");
        puts("Release update parser checks passed.");
    }
    return EXIT_SUCCESS;
}
