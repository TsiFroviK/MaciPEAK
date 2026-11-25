#import <AppKit/AppKit.h>
#import "InstallUpdate.h"
#import "ReleaseUpdate.h"
#include <errno.h>
#include <sys/sysctl.h>
#include <unistd.h>

static NSString *L(NSString *english, NSString *russian) {
    return [NSBundle.mainBundle.preferredLocalizations.firstObject isEqualToString:@"ru"] ? russian : english;
}

static NSString *const SkippedUpdateVersion = @"SkippedUpdateVersion";
static NSString *const FormAfterUpdate = @"FormAfterUpdate";

static NSInteger nativeArchitectureIndex(void) {
    int arm64 = 0;
    size_t length = sizeof arm64;
    if (sysctlbyname("hw.optional.arm64", &arm64, &length, NULL, 0) == 0) return arm64 ? 0 : 1;
#if defined(__arm64__)
    return 0;
#else
    return 1;
#endif
}

static NSTextField *label(NSString *text, NSFont *font, NSColor *color) {
    NSTextField *view = [NSTextField labelWithString:text];
    view.font = font;
    view.textColor = color;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    return view;
}

static NSView *plainView(void) {
    NSView *view = [NSView new];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    return view;
}

static BOOL runUtility(NSString *path, NSArray<NSString *> *args) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = args;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:NULL]) return NO;
    [task waitUntilExit];
    return task.terminationStatus == 0;
}

// Preserve UTF-8 characters split by two pipe reads, e.g. a localized game path.
static NSUInteger completeUTF8Length(NSData *data) {
    const unsigned char *bytes = data.bytes;
    if (!data.length) return 0;
    NSUInteger last = data.length - 1;
    while (last && (bytes[last] & 0xc0) == 0x80) last--;
    unsigned char lead = bytes[last];
    NSUInteger width = lead >= 0xf0 ? 4 : lead >= 0xe0 ? 3 : lead >= 0xc2 ? 2 : 1;
    return data.length - last < width ? last : data.length;
}

static NSUInteger prefixToTrim(NSString *text, NSUInteger limit) {
    if (text.length <= limit) return 0;
    NSUInteger cut = text.length - limit * 3 / 4;
    NSRange newline = [text rangeOfString:@"\n" options:0
                                    range:NSMakeRange(cut, MIN((NSUInteger)2048, text.length - cut))];
    if (newline.location != NSNotFound) return NSMaxRange(newline);
    if (CFStringIsSurrogateLowCharacter([text characterAtIndex:cut])) cut++;
    return cut;
}

@interface Builder : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate, NSMenuItemValidation>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextField *folder, *status, *logTitle;
@property(nonatomic, strong) NSButton *browse, *disclosure, *build;
@property(nonatomic, strong) NSPopUpButton *architecture;
@property(nonatomic, strong) NSStackView *options;
@property(nonatomic, strong) NSTextView *log;
@property(nonatomic, strong) NSScrollView *logScroll;
@property(nonatomic, strong) NSProgressIndicator *spinner;
@property(nonatomic, strong) NSMutableString *pendingOutput;
@property(nonatomic) BOOL busy, flushQueued, skippedOutput;
@property(nonatomic) BOOL checkingUpdate, installingUpdate;
@property(nonatomic, strong) MaciPEAKRelease *pendingUpdate;
@end

@implementation Builder

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.pendingOutput = [NSMutableString string];
    [self installMenus];
    [self makeWindow];
    NSDictionary *form = [NSUserDefaults.standardUserDefaults dictionaryForKey:FormAfterUpdate];
    if (form) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:FormAfterUpdate];
        NSString *folder = form[@"folder"];
        NSInteger architecture = [form[@"architecture"] integerValue];
        if ([folder isKindOfClass:NSString.class]) self.folder.stringValue = folder;
        if (architecture >= 0 && architecture < self.architecture.numberOfItems)
            [self.architecture selectItemAtIndex:architecture];
        [self updateControls];
    }
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.folder];
    if (@available(macOS 14.0, *)) [NSApp activate];
    else [NSApp activateIgnoringOtherApps:YES];
    [self checkForUpdateManually:NO];
}

- (void)installMenus {
    NSMenu *bar = [NSMenu new];
    NSString *name = @"MaciPEAK Builder";
    NSMenuItem *appItem = [bar addItemWithTitle:name action:NULL keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:name];
    NSMenuItem *updates = [appMenu addItemWithTitle:L(@"Check for Updates…", @"Проверить обновления…")
                                           action:@selector(checkForUpdates:) keyEquivalent:@""];
    updates.target = self;
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:L(@"Quit MaciPEAK", @"Завершить MaciPEAK")
                       action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSString *edit = L(@"Edit", @"Правка");
    NSMenuItem *editItem = [bar addItemWithTitle:edit action:NULL keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:edit];
    [menu addItemWithTitle:L(@"Undo", @"Отменить") action:@selector(undo:) keyEquivalent:@"z"];
    [menu addItemWithTitle:L(@"Redo", @"Повторить") action:@selector(redo:) keyEquivalent:@"Z"];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:L(@"Cut", @"Вырезать") action:@selector(cut:) keyEquivalent:@"x"];
    [menu addItemWithTitle:L(@"Copy", @"Скопировать") action:@selector(copy:) keyEquivalent:@"c"];
    [menu addItemWithTitle:L(@"Paste", @"Вставить") action:@selector(paste:) keyEquivalent:@"v"];
    [menu addItemWithTitle:L(@"Select All", @"Выбрать всё") action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = menu;
    NSApp.mainMenu = bar;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    return !self.busy && !self.checkingUpdate && !self.window.attachedSheet;
}

- (void)checkForUpdates:(id)sender {
    [self checkForUpdateManually:YES];
}

- (void)checkForUpdateManually:(BOOL)manual {
    if (self.checkingUpdate || self.busy || self.window.attachedSheet) return;
    self.checkingUpdate = YES;
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (manual) [self.spinner startAnimation:nil];
    MaciPEAKCheckForUpdate(version, ^(MaciPEAKRelease *release, NSError *error) {
        self.checkingUpdate = NO;
        if (manual && !self.busy) [self.spinner stopAnimation:nil];
        if (error) NSLog(@"MaciPEAK update check: %@", error.localizedDescription);
        if (release) {
            if (!manual && [release.version isEqualToString:[NSUserDefaults.standardUserDefaults stringForKey:SkippedUpdateVersion]])
                return;
            self.pendingUpdate = release;
            [self presentPendingUpdate];
        } else if (manual && !self.busy && !self.window.attachedSheet) {
            [self updateNotice:error ? L(@"Couldn’t check for updates", @"Не удалось проверить обновления") :
                                       L(@"MaciPEAK Builder is up to date", @"Установлена последняя версия MaciPEAK Builder")
                       details:error ? L(@"Try again later or open GitHub Releases.", @"Повторите попытку позже или откройте релизы на GitHub.") :
                                       [NSString stringWithFormat:L(@"Installed version: %@", @"Установленная версия: %@"), version]
                       releases:error != nil];
        }
    });
}

- (void)updateNotice:(NSString *)title details:(NSString *)details releases:(BOOL)showReleases {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = details;
    [alert addButtonWithTitle:L(@"OK", @"OK")];
    if (showReleases) [alert addButtonWithTitle:L(@"Open Releases", @"Открыть релизы")];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSAlertSecondButtonReturn)
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/TsiFroviK/MaciPEAK/releases/latest"]];
    }];
}

- (void)presentPendingUpdate {
    if (self.busy || self.window.attachedSheet || !self.pendingUpdate || !self.window.isVisible) return;
    MaciPEAKRelease *release = self.pendingUpdate;
    self.pendingUpdate = nil;
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSAlert *alert = [NSAlert new];
    alert.messageText = L(@"A MaciPEAK Builder update is available", @"Доступно обновление MaciPEAK Builder");
    alert.informativeText = [NSString stringWithFormat:L(@"%@ → %@\n\nThe builder will install the update and restart.",
                                                         @"%@ → %@\n\nСборщик установит обновление и перезапустится."),
                             version, release.version];
    [alert addButtonWithTitle:L(@"Update", @"Обновить")];
    [alert addButtonWithTitle:L(@"Later", @"Позже")].keyEquivalent = @"\033";
    [alert addButtonWithTitle:L(@"Skip This Version", @"Не напоминать")];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSAlertFirstButtonReturn) [self startUpdate:release];
        if (result == NSAlertThirdButtonReturn)
            [NSUserDefaults.standardUserDefaults setObject:release.version forKey:SkippedUpdateVersion];
    }];
}

- (void)windowDidEndSheet:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{ [self presentPendingUpdate]; });
}

- (void)startUpdate:(MaciPEAKRelease *)release {
    if (self.busy) return;
    self.busy = self.installingUpdate = YES;
    [self updateControls];
    [self.spinner startAnimation:nil];
    [self showStatus:L(@"Downloading update…", @"Загрузка обновления…") color:NSColor.secondaryLabelColor];
    MaciPEAKDownloadUpdate(release, ^(NSURL *dmgURL, NSError *error) {
        if (error) {
            [self updateFailed:error];
            return;
        }
        [self showStatus:L(@"Installing update…", @"Установка обновления…") color:NSColor.secondaryLabelColor];
        NSUserDefaults *preferences = NSUserDefaults.standardUserDefaults;
        [preferences setObject:@{@"folder":self.folder.stringValue, @"architecture":@(self.architecture.indexOfSelectedItem)}
                        forKey:FormAfterUpdate];
        MPInstallUpdate(dmgURL, release.version, NSBundle.mainBundle.bundleURL, ^(NSError *installError) {
            [NSFileManager.defaultManager removeItemAtURL:dmgURL.URLByDeletingLastPathComponent error:NULL];
            if (installError) {
                [preferences removeObjectForKey:FormAfterUpdate];
                [self updateFailed:installError];
                return;
            }
            self.busy = self.installingUpdate = NO;
            [NSApp terminate:nil];
        });
    });
}

- (void)updateFailed:(NSError *)error {
    NSLog(@"MaciPEAK update installation: %@", error.localizedDescription);
    self.installingUpdate = NO;
    NSString *title = L(@"Couldn’t install the update", @"Не удалось установить обновление");
    [self finish:title success:NO];
    BOOL readOnly = [error.domain isEqualToString:MPInstallUpdateErrorDomain] &&
                    error.code == MPInstallUpdateDestinationNotWritable;
    NSString *details = readOnly ? L(@"Move MaciPEAK Builder to Applications or another folder you can write to, then try again.",
                                      @"Скопируйте MaciPEAK Builder в «Программы» или другую доступную для записи папку и повторите попытку.") :
                                   L(@"Try again or download the new version from GitHub Releases.",
                                      @"Повторите попытку или скачайте новую версию из релизов на GitHub.");
    [self updateNotice:title details:details releases:YES];
}

- (void)makeWindow {
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                       NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 820, 496) styleMask:style
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"MaciPEAK";
    self.window.releasedWhenClosed = NO;
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.titlebarAppearsTransparent = YES;
    self.window.contentMinSize = NSMakeSize(710, 445);
    self.window.delegate = self;
    NSView *root = self.window.contentView;
    NSLayoutGuide *safe = self.window.contentLayoutGuide;

    NSVisualEffectView *sidebar = [NSVisualEffectView new];
    sidebar.translatesAutoresizingMaskIntoConstraints = NO;
    sidebar.material = NSVisualEffectMaterialSidebar;
    [root addSubview:sidebar];
    NSImageView *icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [icon setAccessibilityElement:NO];
    [sidebar addSubview:icon];
    NSTextField *brand = label(@"MaciPEAK", [NSFont systemFontOfSize:21 weight:NSFontWeightSemibold], NSColor.labelColor);
    [sidebar addSubview:brand];

    NSView *body = plainView();
    [root addSubview:body];
    NSTextField *title = label(L(@"Build PEAK", @"Сборка PEAK"), [NSFont systemFontOfSize:26 weight:NSFontWeightBold], NSColor.labelColor);
    NSTextField *folderTitle = label(L(@"Windows game folder", @"Папка игры для Windows"), [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSColor.labelColor);
    self.folder = [NSTextField textFieldWithString:@""];
    self.folder.placeholderString = @"…/steamapps/common/PEAK";
    self.folder.delegate = self;
    self.folder.accessibilityLabel = folderTitle.stringValue;
    self.folder.accessibilityIdentifier = @"gameFolder";
    self.folder.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.folder setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.browse = [NSButton buttonWithTitle:L(@"Choose…", @"Выбрать…") target:self action:@selector(chooseFolder:)];
    self.browse.accessibilityIdentifier = @"chooseFolder";
    [self.browse setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *folderRow = [NSStackView stackViewWithViews:@[self.folder, self.browse]];
    folderRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    folderRow.spacing = 8;
    folderRow.alignment = NSLayoutAttributeCenterY;

    self.disclosure = [NSButton buttonWithTitle:L(@"Advanced options", @"Дополнительные параметры") target:self action:@selector(toggleOptions:)];
    self.disclosure.bordered = NO;
    self.disclosure.imagePosition = NSImageLeft;
    self.disclosure.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.disclosure.accessibilityIdentifier = @"advancedOptions";
    NSTextField *target = label(L(@"Architecture", @"Архитектура"), [NSFont systemFontOfSize:13], NSColor.labelColor);
    self.architecture = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.architecture addItemsWithTitles:@[@"Apple silicon", @"Intel", L(@"Universal", @"Универсальная")]];
    [self.architecture selectItemAtIndex:nativeArchitectureIndex()];
    self.architecture.accessibilityLabel = target.stringValue;
    self.architecture.accessibilityIdentifier = @"architecture";
    self.options = [NSStackView stackViewWithViews:@[target, self.architecture]];
    self.options.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.options.spacing = 14;
    self.options.alignment = NSLayoutAttributeCenterY;
    self.options.hidden = YES;
    [self refreshDisclosure];

    NSStackView *form = [NSStackView stackViewWithViews:@[title, folderTitle, folderRow, self.disclosure, self.options]];
    form.translatesAutoresizingMaskIntoConstraints = NO;
    form.orientation = NSUserInterfaceLayoutOrientationVertical;
    form.alignment = NSLayoutAttributeLeading;
    form.spacing = 8;
    form.detachesHiddenViews = YES;
    [form setCustomSpacing:24 afterView:title];
    [form setCustomSpacing:14 afterView:folderRow];
    [body addSubview:form];

    self.logTitle = label(L(@"Build log", @"Журнал сборки"), [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], NSColor.secondaryLabelColor);
    [body addSubview:self.logTitle];
    self.logScroll = [NSScrollView new];
    self.logScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.logScroll.hasVerticalScroller = YES;
    self.logScroll.autohidesScrollers = YES;
    self.logScroll.borderType = NSBezelBorder;
    self.log = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 60)];
    self.log.editable = NO;
    self.log.selectable = YES;
    self.log.richText = NO;
    self.log.textContainerInset = NSMakeSize(7, 6);
    self.log.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.log.verticallyResizable = YES;
    self.log.horizontallyResizable = NO;
    self.log.autoresizingMask = NSViewWidthSizable;
    self.log.textContainer.widthTracksTextView = YES;
    self.log.accessibilityLabel = self.logTitle.stringValue;
    self.log.accessibilityIdentifier = @"buildLog";
    self.logScroll.documentView = self.log;
    [body addSubview:self.logScroll];
    self.logTitle.hidden = self.logScroll.hidden = YES;

    self.spinner = [NSProgressIndicator new];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;
    [body addSubview:self.spinner];
    self.status = [NSTextField wrappingLabelWithString:L(@"Ready to build", @"Готово к сборке")];
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    self.status.font = [NSFont systemFontOfSize:12];
    self.status.textColor = NSColor.secondaryLabelColor;
    self.status.accessibilityIdentifier = @"buildStatus";
    [body addSubview:self.status];
    self.build = [NSButton buttonWithTitle:L(@"Build", @"Собрать") target:self action:@selector(startBuild:)];
    self.build.translatesAutoresizingMaskIntoConstraints = NO;
    self.build.keyEquivalent = @"\r";
    self.build.controlSize = NSControlSizeLarge;
    self.build.bezelStyle = NSBezelStyleRounded;
    self.build.accessibilityIdentifier = @"buildButton";
    [body addSubview:self.build];

    [NSLayoutConstraint activateConstraints:@[
        [sidebar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [sidebar.topAnchor constraintEqualToAnchor:root.topAnchor],
        [sidebar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [sidebar.widthAnchor constraintEqualToConstant:174],
        [icon.centerXAnchor constraintEqualToAnchor:sidebar.centerXAnchor],
        [icon.topAnchor constraintEqualToAnchor:safe.topAnchor constant:31],
        [icon.widthAnchor constraintEqualToConstant:82], [icon.heightAnchor constraintEqualToConstant:82],
        [brand.centerXAnchor constraintEqualToAnchor:sidebar.centerXAnchor],
        [brand.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:8],
        [body.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:28],
        [body.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-28],
        [body.topAnchor constraintEqualToAnchor:safe.topAnchor constant:18],
        [body.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-19],
        [form.leadingAnchor constraintEqualToAnchor:body.leadingAnchor],
        [form.trailingAnchor constraintEqualToAnchor:body.trailingAnchor],
        [form.topAnchor constraintEqualToAnchor:body.topAnchor],
        [folderRow.widthAnchor constraintEqualToAnchor:form.widthAnchor],
        [self.architecture.widthAnchor constraintGreaterThanOrEqualToConstant:154],
        [self.logTitle.leadingAnchor constraintEqualToAnchor:body.leadingAnchor],
        [self.logTitle.topAnchor constraintEqualToAnchor:form.bottomAnchor constant:18],
        [self.logScroll.leadingAnchor constraintEqualToAnchor:body.leadingAnchor],
        [self.logScroll.trailingAnchor constraintEqualToAnchor:body.trailingAnchor],
        [self.logScroll.topAnchor constraintEqualToAnchor:self.logTitle.bottomAnchor constant:6],
        [self.logScroll.bottomAnchor constraintEqualToAnchor:self.build.topAnchor constant:-15],
        [self.build.trailingAnchor constraintEqualToAnchor:body.trailingAnchor],
        [self.build.bottomAnchor constraintEqualToAnchor:body.bottomAnchor],
        [self.build.widthAnchor constraintGreaterThanOrEqualToConstant:106],
        [self.spinner.leadingAnchor constraintEqualToAnchor:body.leadingAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.build.centerYAnchor],
        [self.spinner.widthAnchor constraintEqualToConstant:16], [self.spinner.heightAnchor constraintEqualToConstant:16],
        [self.status.leadingAnchor constraintEqualToAnchor:self.spinner.trailingAnchor constant:6],
        [self.status.trailingAnchor constraintLessThanOrEqualToAnchor:self.build.leadingAnchor constant:-12],
        [self.status.centerYAnchor constraintEqualToAnchor:self.build.centerYAnchor]
    ]];
    self.window.initialFirstResponder = self.folder;
    [self updateControls];
}

- (void)refreshDisclosure {
    NSString *glyph = self.options.hidden ? @"chevron.right" : @"chevron.down";
    self.disclosure.image = [NSImage imageWithSystemSymbolName:glyph accessibilityDescription:nil];
    self.disclosure.accessibilityValue = self.options.hidden ? L(@"Collapsed", @"Свёрнуто") : L(@"Expanded", @"Развёрнуто");
}

- (void)toggleOptions:(id)sender {
    self.options.hidden = !self.options.hidden;
    [self refreshDisclosure];
}

- (NSString *)gamePath {
    NSString *text = [self.folder.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.stringByExpandingTildeInPath;
}

- (void)chooseFolder:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.title = L(@"Choose the Windows PEAK folder", @"Выберите папку Windows-версии PEAK");
    panel.prompt = L(@"Choose", @"Выбрать");
    if (self.gamePath.isAbsolutePath) panel.directoryURL = [NSURL fileURLWithPath:self.gamePath isDirectory:YES];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL.isFileURL) {
            self.folder.stringValue = panel.URL.path;
            [self updateControls];
        }
    }];
}

- (void)updateControls {
    self.folder.enabled = self.browse.enabled = self.architecture.enabled = !self.busy;
    self.build.enabled = !self.busy && self.gamePath.length > 0;
}

- (void)controlTextDidChange:(NSNotification *)notification { [self updateControls]; }

- (void)showStatus:(NSString *)text color:(NSColor *)color {
    self.status.stringValue = text;
    self.status.textColor = color;
    NSAccessibilityPostNotification(self.status, NSAccessibilityValueChangedNotification);
}

- (void)finish:(NSString *)text success:(BOOL)success {
    self.busy = NO;
    [self.spinner stopAnimation:nil];
    [self updateControls];
    [self showStatus:text color:success ? NSColor.labelColor : NSColor.systemRedColor];
    dispatch_async(dispatch_get_main_queue(), ^{ [self presentPendingUpdate]; });
}

- (void)startBuild:(id)sender {
    if (self.busy) return;
    NSString *game = self.gamePath;
    BOOL directory = NO;
    if (!game.isAbsolutePath || ![NSFileManager.defaultManager fileExistsAtPath:[game stringByAppendingPathComponent:@"PEAK_Data"] isDirectory:&directory] ||
        !directory || ![NSFileManager.defaultManager fileExistsAtPath:[game stringByAppendingPathComponent:@"PEAK.exe"]]) {
        [self showStatus:L(@"Choose the folder containing PEAK.exe and PEAK_Data.", @"Выберите папку с PEAK.exe и PEAK_Data.") color:NSColor.systemRedColor];
        [self.window makeFirstResponder:self.folder];
        return;
    }
    NSURL *script = [[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"MaciPEAK"] URLByAppendingPathComponent:@"build.sh"];
    if (![NSFileManager.defaultManager isReadableFileAtPath:script.path]) {
        [self showStatus:L(@"The bundled build.sh is missing.", @"В приложении отсутствует build.sh.") color:NSColor.systemRedColor];
        return;
    }
    NSString *arch = @[@"arm64", @"x86_64", @"universal"][self.architecture.indexOfSelectedItem];
    self.busy = YES;
    self.log.string = @"";
    self.logTitle.hidden = self.logScroll.hidden = NO;
    [self.spinner startAnimation:nil];
    [self updateControls];
    [self showStatus:L(@"Checking Apple developer tools…", @"Проверка инструментов Apple…") color:NSColor.secondaryLabelColor];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ready = runUtility(@"/usr/bin/xcode-select", @[@"-p"]) &&
                     runUtility(@"/usr/bin/xcrun", @[@"--sdk", @"macosx", @"--show-sdk-path"]) &&
                     runUtility(@"/usr/bin/xcrun", @[@"--find", @"clang"]);
        if (!ready) runUtility(@"/usr/bin/xcode-select", @[@"--install"]);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ready) {
                [self runBuild:script game:game architecture:arch];
            } else {
                NSString *message = L(@"Finish installing Apple Command Line Tools, then choose Build again.", @"Завершите установку Apple Command Line Tools и снова нажмите «Собрать».");
                [self appendLog:[message stringByAppendingString:@"\n"]];
                [self finish:message success:NO];
            }
        });
    });
}

- (void)appendLog:(NSString *)text {
    if (!text.length) return;
    NSClipView *clip = self.logScroll.contentView;
    BOOL follow = NSMaxY(clip.documentVisibleRect) >= NSHeight(self.log.bounds) - 4;
    NSTextStorage *storage = self.log.textStorage;
    NSDictionary *attributes = @{NSFontAttributeName:self.log.font, NSForegroundColorAttributeName:NSColor.textColor};
    [storage beginEditing];
    [storage appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
    NSUInteger cut = prefixToTrim(storage.string, 192 * 1024);
    if (cut) [storage deleteCharactersInRange:NSMakeRange(0, cut)];
    [storage endEditing];
    if (follow) [self.log scrollRangeToVisible:NSMakeRange(storage.length, 0)];
}

- (void)flushPendingOutput {
    NSString *content;
    BOOL skipped;
    @synchronized (self.pendingOutput) {
        content = [self.pendingOutput copy];
        [self.pendingOutput setString:@""];
        skipped = self.skippedOutput;
        self.skippedOutput = NO;
        self.flushQueued = NO;
    }
    if (skipped) {
        self.log.string = @"";
        [self appendLog:L(@"… Earlier output omitted …\n", @"… Предыдущие строки пропущены …\n")];
    }
    [self appendLog:content];
}

- (void)queueOutput:(NSString *)text {
    if (!text.length) return;
    @synchronized (self.pendingOutput) {
        [self.pendingOutput appendString:text];
        NSUInteger cut = prefixToTrim(self.pendingOutput, 96 * 1024);
        if (cut) {
            [self.pendingOutput deleteCharactersInRange:NSMakeRange(0, cut)];
            self.skippedOutput = YES;
        }
        if (self.flushQueued) return;
        self.flushQueued = YES;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self flushPendingOutput];
    });
}

- (void)runBuild:(NSURL *)script game:(NSString *)game architecture:(NSString *)arch {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[script.path, @"--game", game, @"--arch", arch];
    task.currentDirectoryURL = script.URLByDeletingLastPathComponent;
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"PYTHONUNBUFFERED"] = @"1";
    task.environment = environment;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = task.standardError = pipe.fileHandleForWriting;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        [self appendLog:[error.localizedDescription stringByAppendingString:@"\n"]];
        [self finish:L(@"Unable to start the builder.", @"Не удалось запустить сборщик.") success:NO];
        return;
    }
    [pipe.fileHandleForWriting closeFile];
    [self showStatus:L(@"Building…", @"Идёт сборка…") color:NSColor.secondaryLabelColor];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int fd = pipe.fileHandleForReading.fileDescriptor;
        unsigned char bytes[8192];
        NSMutableData *pending = [NSMutableData data];
        while (YES) {
            ssize_t count = read(fd, bytes, sizeof bytes);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) break;
            @autoreleasepool {
                [pending appendBytes:bytes length:(NSUInteger)count];
                NSUInteger size = completeUTF8Length(pending);
                if (!size) continue;
                NSString *text = [[NSString alloc] initWithBytes:pending.bytes length:size encoding:NSUTF8StringEncoding];
                if (!text) text = [[NSString alloc] initWithBytes:pending.bytes length:size encoding:NSISOLatin1StringEncoding];
                [self queueOutput:text];
                [pending replaceBytesInRange:NSMakeRange(0, size) withBytes:NULL length:0];
            }
        }
        if (pending.length) [self queueOutput:@"\uFFFD"];
        [pipe.fileHandleForReading closeFile];
        [task waitUntilExit];
        int code = task.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self flushPendingOutput];
            NSString *result = code == 0 ? L(@"Built. PEAK is available in Steam.", @"Готово. PEAK доступна в Steam.") :
                [NSString stringWithFormat:L(@"Build failed (code %d).", @"Сборка завершилась с ошибкой (код %d)."), code];
            [self finish:result success:(code == 0)];
        });
    });
}

- (BOOL)canClose {
    if (!self.busy) return YES;
    if (!self.window.attachedSheet) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = self.installingUpdate ? L(@"An update is running", @"Идёт обновление") :
                                                   L(@"A build is running", @"Идёт сборка");
        alert.informativeText = self.installingUpdate ? L(@"This window can close when the update finishes.", @"Окно можно будет закрыть после обновления.") :
                                                       L(@"This window can close when the build finishes.", @"Окно можно будет закрыть после завершения сборки.");
        [alert addButtonWithTitle:L(@"OK", @"OK")];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    }
    return NO;
}

- (BOOL)windowShouldClose:(NSWindow *)sender { return [self canClose]; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    return [self canClose] ? NSTerminateNow : NSTerminateCancel;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        __attribute__((objc_precise_lifetime)) Builder *delegate = [Builder new];
        app.delegate = delegate;
        [app run];
        (void)delegate;
    }
    return 0;
}
