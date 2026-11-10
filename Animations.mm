#import "Animations.h"
#import <QuartzCore/QuartzCore.h>

// В SDK эта функция помечена как удалённая, но в системе она есть и снимает окна синхронно (приём из Docky).
// Возвращает +1: освобождаем сами.
extern "C" CGImageRef CaptureWindowRaw(CGRect bounds, CGWindowListOption opt, CGWindowID wid, CGWindowImageOption img)
    __asm("_CGWindowListCreateImage");

extern "C" AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *wid); // закрытая, но давно стабильная функция

void TBLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Topbar.log"];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

CGWindowID WindowIDOfElement(AXUIElementRef window) {
    CGWindowID wid = 0;
    return window && _AXUIElementGetWindow(window, &wid) == kAXErrorSuccess ? wid : 0;
}

static CGFloat ScreenH(void) { return NSScreen.screens.firstObject.frame.size.height; }

// Перевод между координатами Accessibility/CoreGraphics (сверху вниз) и Cocoa (снизу вверх).
static NSRect FlipRect(CGRect r) { return NSMakeRect(r.origin.x, ScreenH() - r.origin.y - r.size.height, r.size.width, r.size.height); }

// ---------- Accessibility: мелкие помощники ----------

static NSString *AXStringAttr(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) return nil;
    if (CFGetTypeID(v) != CFStringGetTypeID()) { CFRelease(v); return nil; }
    return (__bridge_transfer NSString *)v;
}

static BOOL AXBoolAttr(AXUIElementRef el, CFStringRef attr, BOOL def) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) return def;
    BOOL r = CFGetTypeID(v) == CFBooleanGetTypeID() ? CFBooleanGetValue((CFBooleanRef)v) : def;
    CFRelease(v);
    return r;
}

static AXUIElementRef AXElementAttr(AXUIElementRef el, CFStringRef attr) { // +1 или NULL
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) return NULL;
    if (CFGetTypeID(v) != AXUIElementGetTypeID()) { CFRelease(v); return NULL; }
    return (AXUIElementRef)v;
}

// Рамка элемента в координатах Accessibility (сверху вниз).
static BOOL AXFrameAttr(AXUIElementRef el, CGRect *out) {
    CFTypeRef p = NULL, sz = NULL;
    CGPoint pos; CGSize size;
    BOOL ok = AXUIElementCopyAttributeValue(el, kAXPositionAttribute, &p) == kAXErrorSuccess && p
           && AXUIElementCopyAttributeValue(el, kAXSizeAttribute, &sz) == kAXErrorSuccess && sz
           && AXValueGetValue((AXValueRef)p, (AXValueType)kAXValueTypeCGPoint, &pos)
           && AXValueGetValue((AXValueRef)sz, (AXValueType)kAXValueTypeCGSize, &size);
    if (p) CFRelease(p);
    if (sz) CFRelease(sz);
    if (ok) *out = CGRectMake(pos.x, pos.y, size.width, size.height);
    return ok;
}

// ---------- полоса рабочих столов в Mission Control ----------
// Её рисует Dock; в дереве Accessibility у Dock это элемент с идентификатором «mc.spaces».
// Его размер меняется, когда полоса разворачивается от наведения курсора, так что панель может ехать вместе с ней.

static AXUIElementRef sStrip = NULL;
static BOOL sDumped = NO;
static CFAbsoluteTime sLastSearch = 0;

static AXUIElementRef FindStrip(AXUIElementRef el, int depth) {
    if ([AXStringAttr(el, CFSTR("AXIdentifier")) isEqualToString:@"mc.spaces"]) return (AXUIElementRef)CFRetain(el);
    if (depth <= 0) return NULL;
    CFArrayRef kids = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, (CFTypeRef *)&kids) != kAXErrorSuccess || !kids) return NULL;
    AXUIElementRef found = NULL;
    for (id k in (__bridge NSArray *)kids) {
        found = FindStrip((__bridge AXUIElementRef)k, depth - 1);
        if (found) break;
    }
    CFRelease(kids);
    return found;
}

// Если полосу не нашли, пишем в лог дерево Dock, чтобы понять, как оно устроено.
static void DumpTree(AXUIElementRef el, int depth, int indent, int *budget) {
    if ((*budget)-- <= 0) return;
    CGRect f = CGRectZero;
    AXFrameAttr(el, &f);
    TBLog(@"AX %*s%@ id=%@ frame=%@", indent * 2, "", AXStringAttr(el, kAXRoleAttribute) ?: @"?",
          AXStringAttr(el, CFSTR("AXIdentifier")) ?: @"-", NSStringFromRect(NSRectFromCGRect(f)));
    if (depth <= 0) return;
    CFArrayRef kids = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, (CFTypeRef *)&kids) != kAXErrorSuccess || !kids) return;
    for (id k in (__bridge NSArray *)kids) DumpTree((__bridge AXUIElementRef)k, depth - 1, indent + 1, budget);
    CFRelease(kids);
}

void MissionControlReset(void) {
    if (sStrip) { CFRelease(sStrip); sStrip = NULL; }
    sDumped = NO;
    sLastSearch = 0;
}

NSRect MissionControlSpacesStrip(void) {
    if (!AXIsProcessTrusted()) return NSZeroRect;
    CGRect f;
    if (sStrip && !AXFrameAttr(sStrip, &f)) { CFRelease(sStrip); sStrip = NULL; } // элемент исчез
    if (!sStrip) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - sLastSearch < 0.1) return NSZeroRect; // обход дерева не чаще 10 раз в секунду
        sLastSearch = now;
        NSRunningApplication *dock = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"].firstObject;
        if (!dock) return NSZeroRect;
        AXUIElementRef app = AXUIElementCreateApplication(dock.processIdentifier);
        AXUIElementSetMessagingTimeout(app, 0.05);
        sStrip = FindStrip(app, 5);
        if (!sStrip && !sDumped) {
            sDumped = YES;
            int budget = 80;
            TBLog(@"AX: полоса «mc.spaces» не найдена, дерево Dock:");
            DumpTree(app, 4, 0, &budget);
        }
        CFRelease(app);
        if (!sStrip || !AXFrameAttr(sStrip, &f)) return NSZeroRect;
    }
    return FlipRect(f);
}

// ---------- «джинн» ----------
// Геометрия как у настоящего джинна: края окна изгибаются S-образной кривой от ширины окна к ширине
// иконки (фаза изгиба), а затем содержимое окна скользит по этим кривым внутрь иконки (фаза втягивания).
// Окно режется на тонкие горизонтальные полосы, каждая полоса ставится между кривыми.

static const double kDuration = 0.5;  // как у системного джинна
static const double kHold = 0.15;      // «замороженный» фон держим чуть дольше: системная анимация под ним должна кончиться

static double Smooth(double x) { x = fmin(fmax(x, 0), 1); return x * x * (3 - 2 * x); }
static double EaseInOut(double p) { p = fmin(fmax(p, 0), 1); return p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2; }

typedef struct {
    NSRect W;      // окно
    CGFloat mouth; // нижний край иконки: сюда втягивается окно (Cocoa y)
    CGFloat tL, tR; // ширина «горлышка» у иконки
    CGFloat sTop, H, bendLen;
} GenieGeom;

static GenieGeom MakeGeom(NSRect W, NSRect T) {
    GenieGeom g;
    g.W = W;
    g.H = W.size.height;
    CGFloat inset = T.size.width * 0.18; // у иконок прозрачные поля: целимся в саму картинку
    g.tL = T.origin.x + inset;
    g.tR = NSMaxX(T) - inset;
    g.mouth = fmax(NSMinY(T) + T.size.height * 0.15, NSMaxY(W)); // окно не может быть выше горлышка
    g.sTop = g.mouth - NSMaxY(W);                               // расстояние от горлышка до верха окна
    g.bendLen = g.sTop + g.H * 0.6;                             // на какой длине края сходятся к иконке
    return g;
}

// x левого и правого края на расстоянии s ниже горлышка, при изгибе bend (0..1).
static void Edges(const GenieGeom &g, CGFloat s, double bend, CGFloat *l, CGFloat *r) {
    double f = (1 - Smooth(s / g.bendLen)) * bend;
    *l = NSMinX(g.W) + (g.tL - NSMinX(g.W)) * f;
    *r = NSMaxX(g.W) + (g.tR - NSMaxX(g.W)) * f;
}

// t: 0 — окно на месте, 1 — окно целиком в иконке.
static void LayoutStrips(NSArray<CALayer *> *strips, const GenieGeom &g, double t) {
    double bend = EaseInOut(t / 0.45);
    double slide = EaseInOut((t - 0.2) / 0.8);
    CGFloat d = slide * (g.sTop + g.H); // насколько содержимое уехало к горлышку
    NSUInteger n = strips.count;
    CGFloat h = g.H / n;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < n; i++) {
        CGFloat a = g.sTop + i * h - d, b = a + h; // верх и низ полосы (расстояние вниз от горлышка)
        if (b <= 0) { strips[i].hidden = YES; continue; }
        a = fmax(a, 0);
        CGFloat l, r;
        Edges(g, (a + b) / 2, bend, &l, &r);
        strips[i].hidden = NO;
        strips[i].frame = CGRectMake(l, g.mouth - b, fmax(r - l, 1), b - a + 0.5); // +0.5: без щелей между полосами
    }
    [CATransaction commit];
}

// Окно поверх всего экрана: снизу «замороженный» фон (под ним идёт системная анимация), сверху полосы окна.
// Возвращает блок отмены (убрать всё сразу).
static void (^GenieOverlay(CGImageRef window, NSRect W, NSRect T, BOOL minimize,
                           CGImageRef background, NSRect bgRect, void (^done)(void)))(void) {
    NSRect screen = NSScreen.screens.firstObject.frame;
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:screen
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    panel.level = NSStatusWindowLevel + 1;
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = NO;
    panel.ignoresMouseEvents = YES;
    panel.animationBehavior = NSWindowAnimationBehaviorNone;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary
                             | NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, screen.size.width, screen.size.height)];
    root.wantsLayer = YES;
    panel.contentView = root;

    if (background) {
        CALayer *bg = [CALayer layer];
        bg.contents = (__bridge id)background;
        bg.frame = bgRect;
        [root.layer addSublayer:bg];
    }
    NSUInteger n = (NSUInteger)fmin(fmax(W.size.height / 3, 40), 320);
    NSMutableArray<CALayer *> *strips = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        CALayer *l = [CALayer layer];
        l.contents = (__bridge id)window;
        l.contentsRect = CGRectMake(0, 1.0 - (i + 1.0) / n, 1, 1.0 / n); // i = 0 — верхняя полоса окна
        l.minificationFilter = kCAFilterTrilinear;
        [root.layer addSublayer:l];
        [strips addObject:l];
    }
    GenieGeom g = MakeGeom(W, T);
    LayoutStrips(strips, g, minimize ? 0 : 1);
    [panel orderFrontRegardless];
    [panel displayIfNeeded];
    [CATransaction flush]; // показать до того, как система начнёт свою анимацию

    __block BOOL finished = NO;
    __block NSTimer *timer = nil;
    void (^finish)(void) = ^{
        if (finished) return;
        finished = YES;
        [timer invalidate];
        [panel orderOut:nil];
        if (done) done();
    };
    NSDate *start = NSDate.date;
    timer = [NSTimer timerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *t) {
        double el = [NSDate.date timeIntervalSinceDate:start];
        double tn = fmin(el / kDuration, 1);
        LayoutStrips(strips, g, minimize ? tn : 1 - tn);
        if (el >= kDuration + kHold) finish();
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    return [finish copy];
}

// ---------- перехват сворачивания ----------

@interface MinimizeWatcher ()
- (CGEventRef)handleEvent:(CGEventRef)event type:(CGEventType)type;
- (void)windowMinimizedNotification;
@end

static CGEventRef TapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    return [(__bridge MinimizeWatcher *)refcon handleEvent:event type:type];
}

static void MinimizedCallback(AXObserverRef obs, AXUIElementRef window, CFStringRef note, void *refcon) {
    [(__bridge MinimizeWatcher *)refcon windowMinimizedNotification];
}

@implementation MinimizeWatcher {
    CFMachPortRef _tap;
    NSMutableDictionary<NSNumber *, id> *_observers;                // pid -> AXObserverRef
    NSMutableDictionary<NSNumber *, NSDictionary *> *_snapshots;     // номер окна -> @{image (CGImage), frame}
    id _pressedWindow;                                               // окно, на чьей жёлтой кнопке зажали мышь
    NSInteger _animating;
}

- (instancetype)init {
    if ((self = [super init])) {
        _observers = [NSMutableDictionary dictionary];
        _snapshots = [NSMutableDictionary dictionary];
        AXUIElementRef sys = AXUIElementCreateSystemWide();
        AXUIElementSetMessagingTimeout(sys, 0.15); // зависшее приложение не должно вешать нас и клики
        CFRelease(sys);
    }
    return self;
}

- (void)installTapIfNeeded {
    if (_tap || !AXIsProcessTrusted()) return;
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) | CGEventMaskBit(kCGEventKeyDown);
    _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask,
                            TapCallback, (__bridge void *)self);
    if (!_tap) { TBLog(@"не удалось перехватывать клики (нет права «Универсальный доступ»?)"); return; }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, _tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    TBLog(@"перехват сворачивания включён (Запись экрана=%d)", CGPreflightScreenCaptureAccess());
}

- (void)watchApps:(NSArray<NSRunningApplication *> *)apps {
    if (!AXIsProcessTrusted()) return;
    [self installTapIfNeeded];
    // Уведомление о сворачивании приходит уже после системной анимации; оно нужно, чтобы панель
    // сразу показала иконку окна, свёрнутого способом, который мы не перехватили.
    NSMutableSet *alive = [NSMutableSet set];
    for (NSRunningApplication *a in apps) {
        NSNumber *pid = @(a.processIdentifier);
        [alive addObject:pid];
        if (_observers[pid]) continue;
        AXObserverRef obs = NULL;
        if (AXObserverCreate(a.processIdentifier, MinimizedCallback, &obs) != kAXErrorSuccess) continue;
        AXUIElementRef app = AXUIElementCreateApplication(a.processIdentifier);
        AXError err = AXObserverAddNotification(obs, app, kAXWindowMiniaturizedNotification, (__bridge void *)self);
        CFRelease(app);
        if (err == kAXErrorSuccess) {
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), kCFRunLoopCommonModes);
            _observers[pid] = CFBridgingRelease(obs);
        } else {
            CFRelease(obs);
        }
    }
    for (NSNumber *pid in [_observers.allKeys copy]) {
        if (![alive containsObject:pid]) [_observers removeObjectForKey:pid];
    }
}

- (void)windowMinimizedNotification {
    if (_animating == 0 && self.didChange) self.didChange(); // во время нашей анимации панель обновится в её конце
}

// Элемент под курсором (координаты сверху вниз). +1 или NULL.
static AXUIElementRef ElementAt(CGPoint p) {
    AXUIElementRef sys = AXUIElementCreateSystemWide();
    AXUIElementRef el = NULL;
    AXUIElementCopyElementAtPosition(sys, p.x, p.y, &el);
    CFRelease(sys);
    return el;
}

// Клик по нашим же окнам (панель, меню настроек): спрашивать Accessibility у самих себя нельзя,
// мы бы ждали сами себя до таймаута.
static BOOL ClickOnOwnWindow(CGEventRef event) {
    CGWindowID wid = (CGWindowID)CGEventGetIntegerValueField(event, kCGMouseEventWindowUnderMousePointer);
    if (!wid) return NO;
    NSArray *info = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, wid));
    return [info.firstObject[(id)kCGWindowOwnerPID] intValue] == NSProcessInfo.processInfo.processIdentifier;
}

// Окно с активной жёлтой кнопкой (его вообще можно свернуть).
static BOOL CanMinimize(AXUIElementRef window) {
    if (!window || AXBoolAttr(window, kAXMinimizedAttribute, NO)) return NO;
    AXUIElementRef btn = AXElementAttr(window, kAXMinimizeButtonAttribute);
    if (!btn) return NO;
    BOOL ok = AXBoolAttr(btn, kAXEnabledAttribute, YES);
    CFRelease(btn);
    return ok;
}

static AXUIElementRef FocusedWindowOfPid(pid_t pid) { // +1 или NULL
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementRef w = AXElementAttr(app, kAXFocusedWindowAttribute);
    CFRelease(app);
    return w;
}

- (CGEventRef)handleEvent:(CGEventRef)event type:(CGEventType)type {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(_tap, true);
        return event;
    }
    if (self.suspended) return event;

    if ((type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp) && ClickOnOwnWindow(event)) {
        _pressedWindow = nil;
        return event;
    }

    if (type == kCGEventLeftMouseDown) {
        _pressedWindow = nil;
        AXUIElementRef el = ElementAt(CGEventGetLocation(event));
        if (!el) return event;
        if ([AXStringAttr(el, kAXSubroleAttribute) isEqualToString:(__bridge NSString *)kAXMinimizeButtonSubrole]) {
            AXUIElementRef w = AXElementAttr(el, kAXWindowAttribute);
            if (w) _pressedWindow = CFBridgingRelease(w);
        }
        CFRelease(el);
        return event;
    }

    if (type == kCGEventLeftMouseUp) {
        AXUIElementRef el = ElementAt(CGEventGetLocation(event));
        if (!el) { _pressedWindow = nil; return event; }
        NSString *subrole = AXStringAttr(el, kAXSubroleAttribute);
        NSString *role = AXStringAttr(el, kAXRoleAttribute);
        AXUIElementRef target = NULL;
        if (_pressedWindow && [subrole isEqualToString:(__bridge NSString *)kAXMinimizeButtonSubrole]) {
            // Отпустили на той же жёлтой кнопке: окно сейчас свернётся.
            target = AXElementAttr(el, kAXWindowAttribute);
        } else if ([role isEqualToString:(__bridge NSString *)kAXMenuItemRole]
                   && [AXStringAttr(el, kAXMenuItemCmdCharAttribute) isEqualToString:@"M"]) {
            // Пункт меню с сочетанием Cmd+M («Свернуть»).
            CFTypeRef mods = NULL;
            int m = -1;
            if (AXUIElementCopyAttributeValue(el, kAXMenuItemCmdModifiersAttribute, &mods) == kAXErrorSuccess && mods) {
                CFNumberGetValue((CFNumberRef)mods, kCFNumberIntType, &m);
                CFRelease(mods);
            }
            pid_t pid = 0;
            AXUIElementGetPid(el, &pid);
            if (m == kAXMenuItemModifierNone && AXBoolAttr(el, kAXEnabledAttribute, YES)) target = FocusedWindowOfPid(pid);
        }
        _pressedWindow = nil;
        CFRelease(el);
        if (target) {
            [self beginMinimizeOf:target];
            CFRelease(target);
        }
        return event;
    }

    if (type == kCGEventKeyDown) {
        CGEventFlags f = CGEventGetFlags(event) & (kCGEventFlagMaskCommand | kCGEventFlagMaskShift
                                                   | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate);
        if (f != kCGEventFlagMaskCommand || CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) != 46 // «M»
            || CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) return event;
        NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
        if (!front || front.processIdentifier == NSProcessInfo.processInfo.processIdentifier) return event;
        AXUIElementRef w = FocusedWindowOfPid(front.processIdentifier);
        if (w) {
            [self beginMinimizeOf:w];
            CFRelease(w);
        }
        return event;
    }
    return event;
}

// Кадр «до»: окно и всё, что под ним. Делается синхронно, пока событие ещё не дошло до приложения.
- (void)beginMinimizeOf:(AXUIElementRef)window {
    if (!CanMinimize(window)) return;
    if (!CGPreflightScreenCaptureAccess()) { TBLog(@"сворачивание без анимации: нет права «Запись экрана»"); return; }
    CGWindowID wid = WindowIDOfElement(window);
    CGRect wf;
    NSRect target = self.targetForNewIcon ? self.targetForNewIcon() : NSZeroRect;
    if (!wid || !AXFrameAttr(window, &wf) || NSIsEmptyRect(target)) return;
    NSRect W = FlipRect(wf);

    CGImageRef img = CaptureWindowRaw(CGRectNull, kCGWindowListOptionIncludingWindow, wid,
                                      kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
    // Фон: всё, что под окном, от нижнего края панели до низа экрана. Системный джинн вниз проходит
    // только здесь, а панель и строка меню остаются живыми.
    NSRect bar = self.barFrame ? self.barFrame() : NSZeroRect;
    CGFloat bgTop = fmin(NSIsEmptyRect(bar) ? NSMaxY(W) : NSMinY(bar), NSMaxY(NSScreen.screens.firstObject.frame));
    NSRect bgRect = NSMakeRect(0, 0, NSScreen.screens.firstObject.frame.size.width, bgTop);
    CGRect bgCG = CGRectMake(0, ScreenH() - bgTop, bgRect.size.width, bgTop);
    CGImageRef bg = CaptureWindowRaw(bgCG, kCGWindowListOptionOnScreenBelowWindow, wid, kCGWindowImageBestResolution);
    if (!img || !bg || CGImageGetWidth(img) < 8) {
        TBLog(@"не удалось снять окно %u (окно=%d фон=%d)", wid, img != NULL, bg != NULL);
        if (img) CGImageRelease(img);
        if (bg) CGImageRelease(bg);
        return;
    }
    _snapshots[@(wid)] = @{@"image": (__bridge id)img, @"frame": [NSValue valueWithRect:W]};
    _animating++;
    TBLog(@"сворачиваю окно %u %@ -> %@", wid, NSStringFromRect(W), NSStringFromRect(target));
    __weak MinimizeWatcher *ws = self;
    void (^cancel)(void) = GenieOverlay(img, W, target, YES, bg, bgRect, ^{
        MinimizeWatcher *s = ws;
        if (!s) return;
        s->_animating--;
        if (s.didChange) s.didChange();
    });
    CGImageRelease(img);
    CGImageRelease(bg);

    // Если окно так и не свернулось (например, у приложения Cmd+M значит другое), сразу убираем анимацию.
    id win = (__bridge id)window;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AXUIElementRef w = (__bridge AXUIElementRef)win;
        if (AXBoolAttr(w, kAXMinimizedAttribute, YES)) return;
        CGRect now;
        if (AXFrameAttr(w, &now) && CGRectEqualToRect(now, wf)) {
            TBLog(@"окно %u не свернулось, отменяю анимацию", wid);
            cancel();
        }
    });
}

- (void)restoreWindow:(AXUIElementRef)window app:(NSRunningApplication *)app fromIcon:(NSRect)icon {
    CGWindowID wid = WindowIDOfElement(window);
    NSDictionary *snap = _snapshots[@(wid)];
    CGRect wf;
    NSRect W = AXFrameAttr(window, &wf) && wf.size.width > 4 ? FlipRect(wf) : [snap[@"frame"] rectValue];
    if (snap && CGPreflightScreenCaptureAccess() && !NSIsEmptyRect(icon) && !NSIsEmptyRect(W)) {
        // Фон «до»: экран без окна. Под ним система вытащит окно снизу, а мы покажем, как оно вылетает из иконки.
        NSRect bar = self.barFrame ? self.barFrame() : NSZeroRect;
        CGFloat bgTop = NSIsEmptyRect(bar) ? NSMaxY(W) : NSMinY(bar);
        NSRect bgRect = NSMakeRect(0, 0, NSScreen.screens.firstObject.frame.size.width, bgTop);
        CGImageRef bg = CaptureWindowRaw(CGRectMake(0, ScreenH() - bgTop, bgRect.size.width, bgTop),
                                         kCGWindowListOptionOnScreenOnly, kCGNullWindowID, kCGWindowImageBestResolution);
        if (bg) {
            _animating++;
            __weak MinimizeWatcher *ws = self;
            GenieOverlay((__bridge CGImageRef)snap[@"image"], W, icon, NO, bg, bgRect, ^{
                MinimizeWatcher *s = ws;
                if (s) s->_animating--;
            });
            CGImageRelease(bg);
            TBLog(@"разворачиваю окно %u из %@", wid, NSStringFromRect(icon));
        }
    }
    [_snapshots removeObjectForKey:@(wid)];
    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute, kCFBooleanFalse);
    AXUIElementPerformAction(window, kAXRaiseAction);
    AXUIElementRef appEl = AXUIElementCreateApplication(app.processIdentifier);
    AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute, kCFBooleanTrue);
    CFRelease(appEl);
}

@end
