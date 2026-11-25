#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>

static void findDisplayLayer(CALayer *layer, CAMetalLayer **largest) {
    if (!layer || layer.hidden) return;
    if ([layer isKindOfClass:CAMetalLayer.class]) {
        CAMetalLayer *metal = (CAMetalLayer *)layer;
        CGSize size = metal.drawableSize;
        CGSize previous = (*largest).drawableSize;
        if (metal.device && size.width * size.height > previous.width * previous.height)
            *largest = metal;
    }
    for (CALayer *child in layer.sublayers)
        findDisplayLayer(child, largest);
}

int macipeak_apply_display_sync(int enabled) {
    if (![NSThread isMainThread]) return 0;
    NSWindow *window = NSApp.mainWindow ?: NSApp.keyWindow;
    if (!window.visible) return 0;
    CAMetalLayer *display = nil;
    findDisplayLayer(window.contentView.layer, &display);
    if (!display) return 0;
    BOOL sync = enabled != 0;
    if (display.displaySyncEnabled != sync)
        display.displaySyncEnabled = sync;
    return display.displaySyncEnabled == sync;
}
