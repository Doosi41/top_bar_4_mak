#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <initializer_list>
#include <signal.h>
#include <vector>
#import "Animations.h"

static NSString *const kDockDomain = @"com.apple.dock";

// ---------- настройки системного Dock (из них панель берёт размер, увеличение, закреплённые приложения) ----------

static id DockPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDockDomain));
}

static BOOL DockBool(NSString *key, BOOL def) {
    id v = DockPref(key);
    return v ? [v boolValue] : def;
}

// ---------- элементы панели ----------

typedef NS_ENUM(NSInteger, ItemKind) { KApp, KFolder, KMinimized, KTrash, KSeparator };

@interface Item : NSObject
@property (assign) ItemKind kind;
@property (strong) NSImage *icon;
@property (copy) NSString *tip;
@property (copy) NSString *key;
@property (assign) BOOL dot;
@property (strong) NSURL *url;
@property (strong) NSRunningApplication *app;
@property (strong) id win; // AXUIElementRef свёрнутого окна
@property (assign) CGWindowID winID;
@end
@implementation Item
@end

// Рамка поверх панели не должна перехватывать клики.
@interface PassView : NSView
@end
@implementation PassView
- (NSView *)hitTest:(NSPoint)p { return nil; }
@end

// ---------- вид с иконками: рисует их сам, чтобы сделать увеличение при наведении как в Dock ----------

static const CGFloat kPadX = 10, kPadTop = 7, kPadBottom = 11, kGap = 4, kSepSlot = 16;

@interface DockView : NSView
@property (copy) void (^onClick)(Item *item, NSPoint menuPoint);
@property (strong) NSArray<Item *> *items;
@property (assign) CGFloat tile, peak;
@property (assign) BOOL showDots;
@property (weak) NSView *bg, *border;
@property (readonly) CGFloat pillH, extraH, restWidth;
- (void)relayout;
- (NSRect)screenRectForKind:(ItemKind)kind key:(NSString *)key; // иконка в координатах экрана (для анимации)
@end

@implementation DockView {
    CGFloat _mouseX, _amount, _target;
    NSTimer *_timer;
    std::vector<NSRect> _slots, _icons;
    NSTrackingArea *_area;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (CGFloat)pillH { return _tile + kPadTop + kPadBottom; }
- (CGFloat)extraH { return (_peak - 1) * _tile; }
- (CGFloat)restWidth {
    CGFloat w = 0;
    for (Item *i in _items) w += i.kind == KSeparator ? kSepSlot : _tile + kGap;
    return w;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_area) [self removeTrackingArea:_area];
    _area = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:_area];
}

- (void)relayout {
    size_t n = _items.count;
    _slots.assign(n, NSZeroRect);
    _icons.assign(n, NSZeroRect);
    CGFloat W = self.bounds.size.width, R = 2.6 * (_tile + kGap);

    // Масштаб каждой иконки зависит от расстояния до курсора (плавный «горб», как в Dock).
    std::vector<CGFloat> sc(n, 1), slotW(n);
    CGFloat x = (W - self.restWidth) / 2, total = 0;
    for (size_t i = 0; i < n; i++) {
        BOOL sep = _items[i].kind == KSeparator;
        CGFloat rest = sep ? kSepSlot : _tile + kGap;
        CGFloat d = fabs(x + rest / 2 - _mouseX);
        if (!sep && _amount > 0 && d < R) sc[i] = 1 + (_peak - 1) * _amount * 0.5 * (1 + cos(M_PI * d / R));
        slotW[i] = sep ? kSepSlot : rest * sc[i];
        total += slotW[i];
        x += rest;
    }
    x = (W - total) / 2;
    for (size_t i = 0; i < n; i++) {
        _slots[i] = NSMakeRect(x, 0, slotW[i], self.pillH + self.extraH);
        if (_items[i].kind != KSeparator) {
            CGFloat size = _tile * sc[i];
            _icons[i] = NSMakeRect(x + (slotW[i] - size) / 2, kPadTop, size, size);
        }
        x += slotW[i];
    }
    CGFloat pillX = (W - total) / 2 - kPadX;
    NSRect pill = NSMakeRect(pillX, self.superview.bounds.size.height - self.pillH, total + 2 * kPadX, self.pillH);
    self.bg.frame = pill;
    self.border.frame = pill;
    [self setNeedsDisplay:YES];
}

- (NSRect)screenRectForKind:(ItemKind)kind key:(NSString *)key {
    for (size_t i = 0; i < _items.count && i < _icons.size(); i++) {
        Item *it = _items[i];
        if (it.kind != kind || (key && ![it.key isEqual:key])) continue;
        return [self.window convertRectToScreen:[self convertRect:_icons[i] toView:nil]];
    }
    return NSZeroRect;
}

- (void)kick {
    if (_timer) return;
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) {
        self->_amount += (self->_target - self->_amount) * 0.35;
        if (fabs(self->_target - self->_amount) < 0.01) {
            self->_amount = self->_target;
            [t invalidate];
            self->_timer = nil;
        }
        [self relayout];
    }];
}

- (NSInteger)indexAt:(NSPoint)p {
    for (size_t i = 0; i < _slots.size(); i++) if (NSPointInRect(p, _slots[i])) return (NSInteger)i;
    return -1;
}

- (void)mouseMoved:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    _mouseX = p.x;
    _target = _peak > 1 ? 1 : 0;
    NSInteger i = [self indexAt:p];
    self.toolTip = i >= 0 ? _items[i].tip : nil;
    [self kick];
    [self relayout];
}

- (void)mouseExited:(NSEvent *)e { _target = 0; [self kick]; }

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger i = [self indexAt:p];
    if (i < 0 || !self.onClick) return;
    self.onClick(_items[i], NSMakePoint(NSMidX(_slots[i]), self.pillH));
}

- (void)drawRect:(NSRect)dirty {
    for (size_t i = 0; i < _items.count && i < _icons.size(); i++) {
        Item *it = _items[i];
        if (it.kind == KSeparator) {
            CGFloat h = _tile * 0.75;
            [[NSColor colorWithWhite:1 alpha:0.3] set];
            NSRectFill(NSMakeRect(NSMidX(_slots[i]) - 0.5, kPadTop + (_tile - h) / 2, 1, h));
            continue;
        }
        [it.icon drawInRect:_icons[i] fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
            fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
    }
    if (!_showDots) return;
    [[NSColor colorWithWhite:1 alpha:0.85] set];
    for (size_t i = 0; i < _items.count && i < _slots.size(); i++) {
        if (!_items[i].dot) continue;
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(_slots[i]) - 2, self.pillH - 8, 4, 4)] fill];
    }
}

@end

// ---------- приложение ----------

@interface Bar : NSObject <NSApplicationDelegate>
@property (strong) NSPanel *panel;
@property (strong) NSVisualEffectView *bg;
@property (strong) DockView *dock;
@property (strong) MinimizeWatcher *watcher;
@property (strong) NSArray<NSRunningApplication *> *apps;
@property (copy) NSString *signature;
@property (assign) CGFloat reserveY; // нижний край панели в координатах Accessibility (сверху вниз)
@property (assign) NSRect panelRect;
@property (assign) NSRect normalFrame; // положение панели вне Mission Control
@property (assign) BOOL mcActive;
@property (strong) NSTimer *mcTimer;
@property (assign) CFAbsoluteTime mcOpenedAt;
@property (strong) NSMutableDictionary<NSNumber *, NSNumber *> *pushTries;
@property (assign) BOOL dockHidden, origAutohide, origHadDelay;
@property (strong) id origDelay;
@property (strong) NSTask *watchdog;
@end

@implementation Bar

#pragma mark - системный Dock

- (void)runTool:(NSString *)path args:(NSArray *)args {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:path];
    t.arguments = args;
    [t launchAndReturnError:nil];
    [t waitUntilExit];
}

- (void)defaults:(NSArray *)args {
    [self runTool:@"/usr/bin/defaults" args:[@[@"write", kDockDomain] arrayByAddingObjectsFromArray:args]];
}

// Команды, которые возвращают Dock как был.
- (NSString *)restoreScript {
    NSString *delay = self.origHadDelay
        ? [NSString stringWithFormat:@"/usr/bin/defaults write com.apple.dock autohide-delay -float %@", self.origDelay]
        : @"/usr/bin/defaults delete com.apple.dock autohide-delay";
    return [NSString stringWithFormat:@"%@; /usr/bin/defaults write com.apple.dock autohide -bool %@; /usr/bin/killall Dock",
        delay, self.origAutohide ? @"true" : @"false"];
}

// Как у Docky: отдельный процесс-сторож ждёт, пока панель завершится, и возвращает Dock.
// Так Dock не останется скрытым, даже если панель убьют принудительно (kill -9) или она упадёт.
- (void)startWatchdog {
    NSString *script = [NSString stringWithFormat:@"trap '' INT HUP; while /bin/kill -0 %d 2>/dev/null; do /bin/sleep 0.5; done; %@",
        NSProcessInfo.processInfo.processIdentifier, [self restoreScript]];
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    t.arguments = @[@"-c", script];
    if ([t launchAndReturnError:nil]) self.watchdog = t;
}

- (void)hideSystemDock {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDockDomain);
    NSNumber *ah = DockPref(@"autohide");
    id delay = DockPref(@"autohide-delay");
    BOOL stale = [delay isKindOfClass:NSNumber.class] && [delay doubleValue] >= 999; // остался от прошлого запуска
    self.origAutohide = stale ? NO : ah.boolValue;
    self.origHadDelay = delay != nil && !stale;
    self.origDelay = stale ? nil : delay;

    [self defaults:@[@"autohide", @"-bool", @"true"]];
    [self defaults:@[@"autohide-delay", @"-float", @"1000"]];
    [self runTool:@"/usr/bin/killall" args:@[@"Dock"]];
    self.dockHidden = YES;
    [self startWatchdog];
}

- (void)restoreSystemDock {
    if (!self.dockHidden) return;
    self.dockHidden = NO;
    [self.watchdog terminate]; // обычный выход: Dock вернём сами, сторож не нужен
    if (self.origHadDelay) {
        [self defaults:@[@"autohide-delay", @"-float", [NSString stringWithFormat:@"%@", self.origDelay]]];
    } else {
        [self runTool:@"/usr/bin/defaults" args:@[@"delete", kDockDomain, @"autohide-delay"]];
    }
    [self defaults:@[@"autohide", @"-bool", self.origAutohide ? @"true" : @"false"]];
    [self runTool:@"/usr/bin/killall" args:@[@"Dock"]];
}

- (void)applicationWillTerminate:(NSNotification *)n { [self restoreSystemDock]; }

#pragma mark - запуск

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    // Свёрнутые окна и сдвиг окон вниз работают только с правом «Универсальный доступ».
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt: @YES});

    [self hideSystemDock];
    TBLog(@" запуск: Универсальный доступ=%d, Запись экрана=%d", AXIsProcessTrusted(), CGPreflightScreenCaptureAccess());

    // Для анимации сворачивания нужен снимок окна: право «Запись экрана».
    if (!CGPreflightScreenCaptureAccess()) CGRequestScreenCaptureAccess();
    self.pushTries = [NSMutableDictionary dictionary];
    self.watcher = [MinimizeWatcher new];
    __weak Bar *ws = self;
    // Окно летит туда, где сейчас корзина: на этом месте появится иконка свёрнутого окна.
    self.watcher.targetForNewIcon = ^NSRect { return [ws.dock screenRectForKind:KTrash key:nil]; };
    self.watcher.didChange = ^{ ws.signature = nil; [ws refresh]; };
    // Анимация не закрывает панель: всё, что выше её нижнего края, остаётся живым.
    self.watcher.barFrame = ^NSRect { return [ws.panel convertRectToScreen:ws.bg.frame]; };

    self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 400, 100)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.panel.level = NSStatusWindowLevel;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                                  | NSWindowCollectionBehaviorStationary;
    self.panel.opaque = NO;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.hasShadow = NO; // окно шире «таблетки», его тень была бы прямоугольной
    self.panel.acceptsMouseMovedEvents = YES;
    self.panel.animationBehavior = NSWindowAnimationBehaviorNone;

    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 100)];
    self.panel.contentView = root;

    self.bg = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.bg.material = NSVisualEffectMaterialHUDWindow;
    self.bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.bg.state = NSVisualEffectStateActive;
    NSImage *mask = [NSImage imageWithSize:NSMakeSize(36, 36) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [NSColor.blackColor set];
        [[NSBezierPath bezierPathWithRoundedRect:r xRadius:18 yRadius:18] fill];
        return YES;
    }];
    mask.capInsets = NSEdgeInsetsMake(18, 18, 18, 18);
    mask.resizingMode = NSImageResizingModeStretch;
    self.bg.maskImage = mask;
    [root addSubview:self.bg];

    PassView *border = [[PassView alloc] initWithFrame:NSZeroRect];
    border.wantsLayer = YES;
    border.layer.cornerRadius = 18;
    border.layer.borderWidth = 0.5;
    border.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.22].CGColor;
    [root addSubview:border];

    self.dock = [[DockView alloc] initWithFrame:root.bounds];
    self.dock.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.dock.bg = self.bg;
    self.dock.border = border;
    __weak Bar *weakSelf = self;
    self.dock.onClick = ^(Item *item, NSPoint pt) { [weakSelf click:item at:pt]; };
    [root addSubview:self.dock];

    NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSNotificationName name in @[NSWorkspaceDidLaunchApplicationNotification,
                                      NSWorkspaceDidTerminateApplicationNotification,
                                      NSWorkspaceDidActivateApplicationNotification]) {
        [nc addObserver:self selector:@selector(refresh) name:name object:nil];
    }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(screenChanged)
        name:NSApplicationDidChangeScreenParametersNotification object:nil];
    // Свёрнутые окна, корзина и настройки Dock не присылают уведомлений, поэтому проверяем раз в секунду.
    [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:0.3 target:self selector:@selector(pushWindowsDown) userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:0.15 target:self selector:@selector(checkMissionControl) userInfo:nil repeats:YES];

    [self refresh];
    [self.panel orderFrontRegardless];

    // Без прав не видны свёрнутые окна и не работает анимация: говорим об этом сразу, а не молча.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self askForPermissions]; });
}

- (void)askForPermissions {
    BOOL ax = AXIsProcessTrusted(), sr = CGPreflightScreenCaptureAccess();
    if (ax && sr) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Topbar нужны два права";
    NSMutableString *text = [NSMutableString string];
    if (!ax) [text appendString:@"• «Универсальный доступ»: без него не видно свёрнутые окна и не работает сдвиг окон вниз.\n"];
    if (!sr) [text appendString:@"• «Запись экрана»: без неё нет анимации сворачивания вверх (останется системная, вниз).\n"];
    [text appendString:@"\nВключи переключатель у Topbar в настройках. После права «Запись экрана» панель нужно запустить заново."];
    alert.informativeText = text;
    if (!ax) [alert addButtonWithTitle:@"Открыть «Универсальный доступ»"];
    if (!sr) [alert addButtonWithTitle:@"Открыть «Запись экрана»"];
    [alert addButtonWithTitle:@"Позже"];
    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse r = [alert runModal];
    NSInteger idx = r - NSAlertFirstButtonReturn;
    NSString *pane = nil;
    if (!ax && idx == 0) pane = @"Privacy_Accessibility";
    else if ((!ax && idx == 1 && !sr) || (ax && idx == 0 && !sr)) pane = @"Privacy_ScreenCapture";
    if (pane) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
            [@"x-apple.systempreferences:com.apple.preference.security?" stringByAppendingString:pane]]];
    }
}

- (void)screenChanged { self.signature = nil; [self refresh]; }

#pragma mark - данные

- (NSURL *)trashURL {
    return [NSFileManager.defaultManager URLForDirectory:NSTrashDirectory inDomain:NSUserDomainMask
        appropriateForURL:nil create:NO error:nil];
}

- (BOOL)trashIsFull {
    NSArray *c = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[self trashURL]
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    return c.count > 0; // без доступа к папке считаем пустой
}

- (NSImage *)trashIcon:(BOOL)full {
    NSString *dir = @"/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/";
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:[dir stringByAppendingString:full ? @"FullTrashIcon.icns" : @"TrashIcon.icns"]];
    return img ?: [NSWorkspace.sharedWorkspace iconForFile:[self trashURL].path];
}

- (NSArray<NSDictionary *> *)minimizedWindows:(NSArray<NSRunningApplication *> *)apps {
    NSMutableArray *out = [NSMutableArray array];
    if (!AXIsProcessTrusted()) return out;
    for (NSRunningApplication *a in apps) {
        AXUIElementRef el = AXUIElementCreateApplication(a.processIdentifier);
        AXUIElementSetMessagingTimeout(el, 0.2);
        CFArrayRef wins = NULL;
        if (AXUIElementCopyAttributeValue(el, kAXWindowsAttribute, (CFTypeRef *)&wins) == kAXErrorSuccess && wins) {
            for (id w in (__bridge NSArray *)wins) {
                CFTypeRef min = NULL;
                AXUIElementRef we = (__bridge AXUIElementRef)w;
                if (AXUIElementCopyAttributeValue(we, kAXMinimizedAttribute, &min) == kAXErrorSuccess && min) {
                    BOOL isMin = CFBooleanGetValue((CFBooleanRef)min);
                    CFRelease(min);
                    if (!isMin) continue;
                    CFTypeRef t = NULL;
                    AXUIElementCopyAttributeValue(we, kAXTitleAttribute, &t);
                    NSString *title = t ? CFBridgingRelease(t) : @"";
                    [out addObject:@{@"app": a, @"win": w, @"title": title, @"wid": @(WindowIDOfElement(we))}];
                }
            }
            CFRelease(wins);
        }
        CFRelease(el);
    }
    return out;
}

#pragma mark - сборка панели из настроек Dock

- (Item *)appItem:(NSURL *)url name:(NSString *)name key:(NSString *)key running:(NSRunningApplication *)ra icon:(NSImage *)icon {
    Item *it = [Item new];
    it.kind = KApp;
    it.url = url;
    it.tip = name;
    it.key = key;
    it.dot = ra != nil;
    it.icon = icon ?: [NSWorkspace.sharedWorkspace iconForFile:url.path];
    return it;
}

- (void)refresh {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDockDomain);
    CGFloat tile = [DockPref(@"tilesize") doubleValue];
    if (tile < 16) tile = 48;
    CGFloat large = DockPref(@"largesize") ? [DockPref(@"largesize") doubleValue] : 128;
    CGFloat peak = DockBool(@"magnification", NO) ? MIN(MAX(large / tile, 1), 2.2) : 1;
    BOOL dots = DockBool(@"show-process-indicators", YES);

    NSMutableArray<NSRunningApplication *> *running = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSRunningApplication *> *byBundle = [NSMutableDictionary dictionary];
    for (NSRunningApplication *a in NSWorkspace.sharedWorkspace.runningApplications) {
        if (a.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        if (a.processIdentifier == NSProcessInfo.processInfo.processIdentifier) continue;
        [running addObject:a];
        if (a.bundleIdentifier) byBundle[a.bundleIdentifier] = a;
    }

    [self.watcher watchApps:running];

    NSMutableArray<Item *> *items = [NSMutableArray array];
    NSMutableSet *used = [NSMutableSet set];

    // Как в Dock: Finder всегда первый, дальше закреплённые приложения в твоём порядке, потом остальные запущенные.
    NSString *finderID = @"com.apple.finder";
    [items addObject:[self appItem:[NSURL fileURLWithPath:@"/System/Library/CoreServices/Finder.app"]
        name:@"Finder" key:finderID running:byBundle[finderID] icon:nil]];
    [used addObject:finderID];

    for (NSDictionary *entry in DockPref(@"persistent-apps") ?: @[]) {
        NSDictionary *td = entry[@"tile-data"];
        NSString *bid = td[@"bundle-identifier"];
        NSURL *url = [NSURL URLWithString:td[@"file-data"][@"_CFURLString"] ?: @""];
        if (!url || (bid && [used containsObject:bid]) || ![NSFileManager.defaultManager fileExistsAtPath:url.path]) continue;
        if (bid) [used addObject:bid];
        [items addObject:[self appItem:url name:td[@"file-label"] ?: url.lastPathComponent.stringByDeletingPathExtension
            key:bid ?: url.path running:bid ? byBundle[bid] : nil icon:nil]];
    }
    for (NSRunningApplication *a in running) {
        if (a.bundleIdentifier && [used containsObject:a.bundleIdentifier]) continue;
        [items addObject:[self appItem:a.bundleURL name:a.localizedName
            key:a.bundleIdentifier ?: [NSString stringWithFormat:@"pid%d", a.processIdentifier] running:a icon:a.icon]];
    }

    Item *sep = [Item new];
    sep.kind = KSeparator;
    sep.key = @"sep";
    [items addObject:sep];

    for (NSDictionary *entry in DockPref(@"persistent-others") ?: @[]) {
        NSDictionary *td = entry[@"tile-data"];
        NSURL *url = [NSURL URLWithString:td[@"file-data"][@"_CFURLString"] ?: @""];
        if (!url || ![NSFileManager.defaultManager fileExistsAtPath:url.path]) continue;
        Item *it = [Item new];
        it.kind = KFolder;
        it.url = url;
        it.key = url.path;
        it.tip = td[@"file-label"] ?: url.lastPathComponent;
        it.icon = [NSWorkspace.sharedWorkspace iconForFile:url.path];
        [items addObject:it];
    }

    for (NSDictionary *m in [self minimizedWindows:running]) {
        NSRunningApplication *a = m[@"app"];
        Item *it = [Item new];
        it.kind = KMinimized;
        it.app = a;
        it.win = m[@"win"];
        it.winID = [m[@"wid"] unsignedIntValue];
        it.key = [NSString stringWithFormat:@"min%d:%@", a.processIdentifier, m[@"title"]];
        it.tip = [m[@"title"] length] ? m[@"title"] : a.localizedName;
        it.icon = a.icon;
        [items addObject:it];
    }

    BOOL full = [self trashIsFull];
    Item *trash = [Item new];
    trash.kind = KTrash;
    trash.key = full ? @"trash-full" : @"trash";
    trash.tip = @"Корзина";
    trash.icon = [self trashIcon:full];
    [items addObject:trash];

    // Перестраиваем панель только когда что-то поменялось, чтобы не мигала.
    NSMutableString *sig = [NSMutableString stringWithFormat:@"%.1f|%.2f|%d|", tile, peak, dots];
    for (Item *it in items) [sig appendFormat:@"%@:%d;", it.key, it.dot];
    if ([sig isEqualToString:self.signature]) return;
    self.signature = sig;

    self.apps = running;
    self.dock.tile = tile;
    self.dock.peak = peak;
    self.dock.showDots = dots;
    self.dock.items = items;
    [self layoutPanel];
}

// Панель по центру сверху, чуть ниже строки меню (часы и батарея остаются на месте).
// Высота с запасом на увеличение иконок, они вырастают вниз за край «таблетки».
- (void)layoutPanel {
    DockView *d = self.dock;
    CGFloat w = d.restWidth + 2 * kPadX + (d.peak - 1) * d.tile * 3 + 40;
    CGFloat h = d.pillH + d.extraH + 4;
    NSRect vf = NSScreen.screens.firstObject.visibleFrame;
    NSRect r = NSMakeRect(NSMidX(vf) - w / 2, NSMaxY(vf) - h - 6, w, h);
    self.normalFrame = r;
    NSRect target = r;
    if (self.mcActive) target.origin.y = NSMaxY(self.panel.frame) - r.size.height; // держим верх, где он сейчас
    [self.panel setFrame:target display:YES];
    d.frame = self.panel.contentView.bounds;
    [d relayout];
    self.panelRect = r;
    self.reserveY = NSScreen.screens.firstObject.frame.size.height - (NSMaxY(r) - d.pillH) + 4;
}

// В Mission Control у процесса Dock появляются окна на весь экран (слои 18–20), в обычной работе их нет.
- (BOOL)missionControlIsOpen {
    NSRect screen = NSScreen.screens.firstObject.frame;
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    for (NSDictionary *w in list) {
        if (![w[(id)kCGWindowOwnerName] isEqual:@"Dock"] || [w[(id)kCGWindowLayer] intValue] < 18) continue;
        CGRect b;
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &b);
        if (b.size.width >= screen.size.width - 1 && b.size.height >= screen.size.height - 1) return YES;
    }
    return NO;
}

// Под полосой рабочих столов Mission Control (она занимает примерно 13,6% высоты экрана).
- (NSRect)missionControlFrame {
    NSRect screen = NSScreen.screens.firstObject.frame, r = self.normalFrame;
    r.origin.y = NSMaxY(screen) - screen.size.height * 0.136 - 6 - r.size.height;
    return r;
}

// В Mission Control панель привязана к полосе рабочих столов: сколько полоса опустилась (в том числе когда
// наводишь курсор и она разворачивается), настолько и панель, плавно, без своего таймера.
- (void)checkMissionControl {
    BOOL mc = [self missionControlIsOpen];
    if (mc == self.mcActive || self.normalFrame.size.width == 0) return;
    self.mcActive = mc;
    self.watcher.suspended = mc;
    if (mc) {
        MissionControlReset();
        self.mcOpenedAt = CFAbsoluteTimeGetCurrent();
        self.mcTimer = [NSTimer timerWithTimeInterval:1.0 / 60 target:self selector:@selector(followStrip) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:self.mcTimer forMode:NSRunLoopCommonModes];
        return;
    }
    [self.mcTimer invalidate];
    self.mcTimer = nil;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.45;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [self.panel.animator setFrame:self.normalFrame display:YES];
    }];
}

- (void)followStrip {
    NSRect screen = NSScreen.screens.firstObject.frame;
    NSRect strip = MissionControlSpacesStrip();
    CGFloat top;
    if (!NSIsEmptyRect(strip)) {
        top = NSMinY(strip) - 8; // под нижним краем полосы
    } else if (CFAbsoluteTimeGetCurrent() - self.mcOpenedAt > 0.8) {
        top = NSMaxY(screen) - screen.size.height * 0.136 - 6; // полосу прочитать не вышло: запасная высота
    } else {
        return; // полоса ещё не появилась
    }
    top = fmin(top, NSMaxY(self.normalFrame)); // выше обычного места не поднимаемся
    NSRect f = self.panel.frame;
    CGFloat target = top - f.size.height;
    f.origin.y += (target - f.origin.y) * 0.18; // сглаживание, чтобы не дёргалась вслед за полосой
    if (fabs(target - f.origin.y) < 0.3) f.origin.y = target;
    [self.panel setFrame:f display:YES];
}

// macOS не умеет резервировать место под чужую панель, поэтому сами сдвигаем вниз окна,
// чей верх заезжает под неё (как Rectangle и подобные программы).
- (void)pushWindowsDown {
    if (!AXIsProcessTrusted() || self.reserveY <= 0) return;
    if (NSEvent.pressedMouseButtons != 0) return; // не мешаем перетаскивать окно
    NSScreen *main = NSScreen.screens.firstObject;
    CGFloat screenH = main.frame.size.height;
    CGFloat topY = screenH - NSMaxY(main.visibleFrame); // верх области под строкой меню (сверху вниз)
    CGFloat panelL = NSMinX(self.panelRect), panelR = NSMaxX(self.panelRect);
    for (NSRunningApplication *a in self.apps) {
        AXUIElementRef el = AXUIElementCreateApplication(a.processIdentifier);
        AXUIElementSetMessagingTimeout(el, 0.1);
        CFArrayRef wins = NULL;
        if (AXUIElementCopyAttributeValue(el, kAXWindowsAttribute, (CFTypeRef *)&wins) == kAXErrorSuccess && wins) {
            for (id w in (__bridge NSArray *)wins) {
                AXUIElementRef we = (__bridge AXUIElementRef)w;
                CFTypeRef v = NULL;

                BOOL skip = NO;
                if (AXUIElementCopyAttributeValue(we, kAXSubroleAttribute, &v) == kAXErrorSuccess && v) {
                    skip = ![(__bridge NSString *)v isEqualToString:(__bridge NSString *)kAXStandardWindowSubrole];
                    CFRelease(v);
                }
                if (skip) continue;
                if (AXUIElementCopyAttributeValue(we, CFSTR("AXFullScreen"), &v) == kAXErrorSuccess && v) {
                    skip = CFBooleanGetValue((CFBooleanRef)v);
                    CFRelease(v);
                }
                if (skip) continue;
                if (AXUIElementCopyAttributeValue(we, kAXMinimizedAttribute, &v) == kAXErrorSuccess && v) {
                    skip = CFBooleanGetValue((CFBooleanRef)v);
                    CFRelease(v);
                }
                if (skip) continue;

                CGPoint pos; CGSize size;
                if (AXUIElementCopyAttributeValue(we, kAXPositionAttribute, &v) != kAXErrorSuccess || !v) continue;
                AXValueGetValue((AXValueRef)v, (AXValueType)kAXValueTypeCGPoint, &pos); CFRelease(v);
                if (AXUIElementCopyAttributeValue(we, kAXSizeAttribute, &v) != kAXErrorSuccess || !v) continue;
                AXValueGetValue((AXValueRef)v, (AXValueType)kAXValueTypeCGSize, &size); CFRelease(v);

                // Только окна над панелью по горизонтали и только если верх заходит под неё.
                if (pos.x + size.width <= panelL || pos.x >= panelR) continue;
                // Как делает Docky: трогаем только окна, растянутые до самого верха (кнопка «Развернуть» или
                // перетащили к краю). Остальные окна можно свободно двигать.
                if (fabs(pos.y - topY) > 3 || pos.y >= self.reserveY - 0.5) continue;
                // Приложение не даёт себя сдвинуть: после трёх попыток оставляем в покое.
                NSNumber *wkey = @(WindowIDOfElement(we));
                NSInteger tries = [self.pushTries[wkey] integerValue];
                if (tries >= 3) continue;
                self.pushTries[wkey] = @(tries + 1);

                CGPoint np = CGPointMake(pos.x, self.reserveY);
                CGSize ns = size;
                if (np.y + ns.height > screenH) ns.height = MAX(120, screenH - np.y); // не уходить за низ экрана
                AXValueRef pv = AXValueCreate((AXValueType)kAXValueTypeCGPoint, &np);
                AXUIElementSetAttributeValue(we, kAXPositionAttribute, pv); CFRelease(pv);
                if (ns.height != size.height) {
                    AXValueRef sv = AXValueCreate((AXValueType)kAXValueTypeCGSize, &ns);
                    AXUIElementSetAttributeValue(we, kAXSizeAttribute, sv); CFRelease(sv);
                }
            }
            CFRelease(wins);
        }
        CFRelease(el);
    }
}

#pragma mark - клики

- (void)openURL:(NSURL *)url {
    // activateWithOptions из фоновой программы на новых macOS игнорируется,
    // а открытие через NSWorkspace работает как клик в Dock (и запускает закрытое приложение).
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url
        configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
}

- (void)click:(Item *)it at:(NSPoint)pt {
    switch (it.kind) {
        case KApp:
            [self openURL:it.url];
            break;
        case KFolder:
            [NSWorkspace.sharedWorkspace openURL:it.url];
            break;
        case KMinimized:
            // Окно вылетает из иконки на своё место (снимок сохранён при сворачивании).
            [self.watcher restoreWindow:(__bridge AXUIElementRef)it.win app:it.app
                               fromIcon:[self.dock screenRectForKind:KMinimized key:it.key]];
            break;
        case KTrash:
            [NSWorkspace.sharedWorkspace openURL:[self trashURL]];
            break;
        case KSeparator:
            [self openSettingsAt:pt];
            break;
    }
}

#pragma mark - настройки (стандартные настройки Dock)

- (NSMenuItem *)item:(NSString *)title action:(SEL)a obj:(id)o on:(BOOL)on {
    NSMenuItem *m = [[NSMenuItem alloc] initWithTitle:title action:a keyEquivalent:@""];
    m.target = self;
    m.representedObject = o;
    m.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    return m;
}

- (void)openSettingsAt:(NSPoint)pt {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDockDomain);
    NSMenu *menu = [[NSMenu alloc] init];

    // Без этих прав не работают свёрнутые окна, сдвиг окон вниз и анимация. Права нужны тому, откуда запущена панель.
    if (!AXIsProcessTrusted()) {
        [menu addItem:[[NSMenuItem alloc] initWithTitle:@"⚠︎ Нет права «Универсальный доступ»" action:nil keyEquivalent:@""]];
    }
    if (!CGPreflightScreenCaptureAccess()) {
        [menu addItem:[[NSMenuItem alloc] initWithTitle:@"⚠︎ Нет права «Запись экрана» (анимация)" action:nil keyEquivalent:@""]];
    }
    if (menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];

    NSMenu *sizes = [[NSMenu alloc] init];
    for (NSNumber *v in @[@32, @48, @64, @80, @96, @128]) {
        [sizes addItem:[self item:[NSString stringWithFormat:@"%@", v] action:@selector(setSize:) obj:v on:NO]];
    }
    // Отметка у ближайшего к текущему размеру пункта.
    NSMenuItem *nearest = nil;
    CGFloat best = 1e9;
    for (NSMenuItem *m in sizes.itemArray) {
        CGFloat d = fabs(self.dock.tile - [m.representedObject doubleValue]);
        if (d < best) { best = d; nearest = m; }
    }
    nearest.state = NSControlStateValueOn;
    NSMenuItem *sz = [[NSMenuItem alloc] initWithTitle:@"Размер" action:nil keyEquivalent:@""];
    sz.submenu = sizes;
    [menu addItem:sz];

    [menu addItem:[self item:@"Увеличение" action:@selector(toggleDock:) obj:@"magnification"
        on:DockBool(@"magnification", NO)]];

    NSMenu *fx = [[NSMenu alloc] init];
    NSString *eff = DockPref(@"mineffect") ?: @"genie";
    [fx addItem:[self item:@"Эффект «Джинн»" action:@selector(setEffect:) obj:@"genie" on:[eff isEqual:@"genie"]]];
    [fx addItem:[self item:@"Эффект «Масштабирование»" action:@selector(setEffect:) obj:@"scale" on:[eff isEqual:@"scale"]]];
    NSMenuItem *fxi = [[NSMenuItem alloc] initWithTitle:@"Эффект сворачивания" action:nil keyEquivalent:@""];
    fxi.submenu = fx;
    [menu addItem:fxi];

    [menu addItem:[self item:@"Сворачивать окна в значок приложения" action:@selector(toggleDock:)
        obj:@"minimize-to-application" on:DockBool(@"minimize-to-application", NO)]];
    [menu addItem:[self item:@"Анимация открытия приложений" action:@selector(toggleDock:)
        obj:@"launchanim" on:DockBool(@"launchanim", YES)]];
    [menu addItem:[self item:@"Индикаторы запущенных приложений" action:@selector(toggleDock:)
        obj:@"show-process-indicators" on:DockBool(@"show-process-indicators", YES)]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self item:@"Выйти и вернуть Dock" action:@selector(quit:) obj:nil on:NO]];

    [menu popUpMenuPositioningItem:nil atLocation:pt inView:self.dock];
}

// Настройки пишутся в сам Dock и применяются после его перезапуска (он скрыт, перезапуск незаметен).
- (void)applyDock:(NSArray *)args {
    [self defaults:args];
    [self runTool:@"/usr/bin/killall" args:@[@"Dock"]];
}

- (void)setSize:(NSMenuItem *)m {
    [self applyDock:@[@"tilesize", @"-float", [NSString stringWithFormat:@"%@", m.representedObject]]];
}

- (void)setEffect:(NSMenuItem *)m {
    [self applyDock:@[@"mineffect", @"-string", m.representedObject]];
}

- (void)toggleDock:(NSMenuItem *)m {
    NSString *key = m.representedObject;
    BOOL def = [key isEqual:@"launchanim"] || [key isEqual:@"show-process-indicators"];
    [self applyDock:@[key, @"-bool", DockBool(key, def) ? @"false" : @"true"]];
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }

@end

static Bar *gBar;

int main() {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        gBar = [Bar new];
        app.delegate = gBar;

        // Ctrl+C и kill: вернуть системный Dock перед выходом.
        for (int sig : {SIGINT, SIGTERM, SIGHUP}) {
            signal(sig, SIG_IGN);
            dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(src, ^{ [gBar restoreSystemDock]; exit(0); });
            dispatch_resume(src);
            static NSMutableArray *keep; if (!keep) keep = [NSMutableArray array];
            [keep addObject:src];
        }
        [app run];
    }
    return 0;
}
