#define main MaciPEAKBuilderMain
#import "Builder.m"
#undef main
#include <stdio.h>
#include <stdlib.h>

static void requireLabel(NSString *actual, NSString *expected) {
    if ([actual isEqualToString:expected]) return;
    fprintf(stderr, "Expected '%s', got '%s'.\n", expected.UTF8String, (actual ?: @"(missing)").UTF8String);
    exit(EXIT_FAILURE);
}

static BOOL hasLabel(NSView *view, NSString *expected) {
    if ([view isKindOfClass:NSTextField.class] && [((NSTextField *)view).stringValue isEqualToString:expected])
        return YES;
    for (NSView *child in view.subviews) {
        if (hasLabel(child, expected)) return YES;
    }
    return NO;
}

int main(void) {
    @autoreleasepool {
        NSString *language = [NSUserDefaults.standardUserDefaults stringForKey:@"MPExpectedLanguage"];
        BOOL russian = [language isEqualToString:@"ru"];
        if (!russian && ![language isEqualToString:@"en"]) {
            fputs("Pass -AppleLanguages '(en)' -MPExpectedLanguage en, or use ru for both.\n", stderr);
            return EXIT_FAILURE;
        }
        requireLabel(NSBundle.mainBundle.preferredLocalizations.firstObject, language);

        [NSApplication sharedApplication];
        Builder *builder = [Builder new];
        [builder installMenus];
        [builder makeWindow];

        NSMenu *menu = [NSApp.mainMenu itemAtIndex:0].submenu;
        NSInteger updateIndex = [menu indexOfItemWithTarget:builder andAction:@selector(checkForUpdates:)];
        NSMenuItem *check = updateIndex >= 0 ? [menu itemAtIndex:updateIndex] : nil;
        requireLabel(check.title, russian ? @"Проверить обновления…" : @"Check for Updates…");
        requireLabel(builder.browse.title, russian ? @"Выбрать…" : @"Choose…");
        requireLabel(builder.build.title, russian ? @"Собрать" : @"Build");
        requireLabel(builder.disclosure.title, russian ? @"Дополнительные параметры" : @"Advanced options");
        requireLabel([builder.architecture itemAtIndex:2].title, russian ? @"Универсальная" : @"Universal");
        if (!hasLabel(builder.window.contentView, russian ? @"Сборка PEAK" : @"Build PEAK")) {
            fputs("Missing localized builder window title.\n", stderr);
            return EXIT_FAILURE;
        }

        printf("MaciPEAK Builder interface language verified (%s).\n", language.UTF8String);
    }
    return EXIT_SUCCESS;
}
