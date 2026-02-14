/* ================================================================
 *  Typeless AutoEnter — Menu Bar App
 *
 *  菜单栏 ↩ 图标 + 毛玻璃 HUD 通知
 *  CGEvent Tap 监听 → PID 过滤 → 500ms 延迟 → 模拟 Enter
 *  SIGUSR1 / 菜单栏点击 切换开关
 * ================================================================ */

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Carbon/Carbon.h>   /* kVK_Return, kVK_ANSI_V */
#import <libproc.h>
#include <signal.h>

/* ================================================================
 *  全局状态
 * ================================================================ */

static volatile int g_enabled = 1;

#define MAX_PIDS 16
static pid_t g_typeless_pids[MAX_PIDS];
static int   g_typeless_pid_count = 0;

static CFRunLoopTimerRef g_enter_timer = NULL;
static CFMachPortRef     g_tap = NULL;
static const CFTimeInterval DELAY_SEC = 0.5;

/* 快捷键回调用的 toggle block */
static void (^g_toggle_block)(void) = nil;

/* ================================================================
 *  PID 扫描: 找到所有 Typeless 进程
 * ================================================================ */

static void refresh_typeless_pids(void) {
    int buf_size = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (buf_size <= 0) return;

    pid_t *pids = malloc(buf_size);
    if (!pids) return;

    int count = proc_listpids(PROC_ALL_PIDS, 0, pids, buf_size) / (int)sizeof(pid_t);

    g_typeless_pid_count = 0;
    for (int i = 0; i < count && g_typeless_pid_count < MAX_PIDS; i++) {
        if (pids[i] == 0) continue;
        char name[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_name(pids[i], name, sizeof(name)) > 0 &&
            strstr(name, "Typeless") != NULL) {
            g_typeless_pids[g_typeless_pid_count++] = pids[i];
        }
    }
    free(pids);

}

static int is_typeless_pid(pid_t pid) {
    for (int i = 0; i < g_typeless_pid_count; i++)
        if (g_typeless_pids[i] == pid) return 1;
    return 0;
}

/* ================================================================
 *  模拟 Enter 键
 * ================================================================ */

static void post_enter(void) {
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, kVK_Return, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(NULL, kVK_Return, false);
    if (!down || !up) { if (down) CFRelease(down); if (up) CFRelease(up); return; }
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
}

/* ================================================================
 *  500ms 延迟触发
 * ================================================================ */

static void timer_fired(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    if (g_enabled) post_enter();
    if (g_enter_timer) { CFRelease(g_enter_timer); g_enter_timer = NULL; }
}

static void reset_timer(void) {
    if (g_enter_timer) {
        CFRunLoopTimerInvalidate(g_enter_timer);
        CFRelease(g_enter_timer);
        g_enter_timer = NULL;
    }
    g_enter_timer = CFRunLoopTimerCreate(
        kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + DELAY_SEC,
        0, 0, 0, timer_fired, NULL
    );
    CFRunLoopAddTimer(CFRunLoopGetMain(), g_enter_timer, kCFRunLoopCommonModes);
}

/* ================================================================
 *  CGEvent Tap 回调
 * ================================================================ */

static CGEventRef event_callback(
    CGEventTapProxy proxy, CGEventType type,
    CGEventRef event, void *refcon
) {
    (void)proxy; (void)refcon;

    /* 系统禁用 tap 时重新启用 */
    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        if (g_tap) CGEventTapEnable(g_tap, true);
        return event;
    }

    if (type != kCGEventKeyDown) return event;

    /* 快捷键: Ctrl+Shift+Enter → 切换开关，吞掉按键 */
    CGKeyCode keycode = (CGKeyCode)CGEventGetIntegerValueField(
        event, kCGKeyboardEventKeycode
    );
    CGEventFlags flags = CGEventGetFlags(event);

    if (keycode == kVK_Return &&
        (flags & kCGEventFlagMaskControl) &&
        (flags & kCGEventFlagMaskShift) &&
        !(flags & kCGEventFlagMaskCommand) &&
        !(flags & kCGEventFlagMaskAlternate)) {
        if (g_toggle_block)
            dispatch_async(dispatch_get_main_queue(), g_toggle_block);
        return NULL;   /* 吞掉，不传给应用 */
    }

    /* Typeless 检测 */
    if (!g_enabled) return event;

    pid_t src = (pid_t)CGEventGetIntegerValueField(
        event, kCGEventSourceUnixProcessID
    );
    if (is_typeless_pid(src)) {
        /* Typeless 通过 Cmd+V 粘贴文字上屏 */
        /* 只在检测到 Cmd+V (keycode 0x09) 时启动定时器 */
        if (keycode == kVK_ANSI_V && (flags & kCGEventFlagMaskCommand))
            reset_timer();
    }

    return event;
}

/* ================================================================
 *  HUD 窗口 — 不抢焦点
 * ================================================================ */

@interface HUDWindow : NSWindow
@end

@implementation HUDWindow
- (BOOL)canBecomeKeyWindow  { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

/* ================================================================
 *  App Delegate
 * ================================================================ */

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem   *toggleItem;
@property (nonatomic, strong) HUDWindow    *hudWindow;
@property (nonatomic, strong) NSTextField  *hudIcon;
@property (nonatomic, strong) NSTextField  *hudLabel;
@property (nonatomic, strong) NSTimer      *hudDismissTimer;
@property (nonatomic, strong) NSTimer      *pidRefreshTimer;
@property (nonatomic)         dispatch_source_t sigSource;
@end

@implementation AppDelegate

/* ---- 启动 ---- */

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    (void)n;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    [self setupStatusBar];
    [self setupHUD];
    [self setupEventTap];
    [self setupPIDRefresh];
    [self setupSignalHandler];
    [self writePIDFile];

    /* 注册快捷键回调 */
    __weak typeof(self) weakSelf = self;
    g_toggle_block = ^{ [weakSelf toggle:nil]; };

    refresh_typeless_pids();
    /* ready */
}

- (void)applicationWillTerminate:(NSNotification *)n {
    (void)n;
    unlink("/tmp/typeless-autoenter.pid");
}

/* ---- 菜单栏 ---- */

- (void)setupStatusBar {
    self.statusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:NSVariableStatusItemLength];

    self.statusItem.button.title = @"↩";
    self.statusItem.button.font =
        [NSFont monospacedSystemFontOfSize:15 weight:NSFontWeightMedium];

    NSMenu *menu = [[NSMenu alloc] init];

    self.toggleItem = [[NSMenuItem alloc]
        initWithTitle:@"AutoEnter"
               action:@selector(toggle:)
        keyEquivalent:@""];
    self.toggleItem.target = self;
    self.toggleItem.state  = NSControlStateValueOn;
    [menu addItem:self.toggleItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"Quit"
               action:@selector(quit:)
        keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];

    self.statusItem.menu = menu;
}

/* ---- 毛玻璃 HUD ---- */

- (void)setupHUD {
    CGFloat w = 160, h = 90;
    NSRect frame = NSMakeRect(0, 0, w, h);

    self.hudWindow = [[HUDWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:YES];
    self.hudWindow.backgroundColor    = [NSColor clearColor];
    self.hudWindow.opaque             = NO;
    self.hudWindow.level              = NSStatusWindowLevel;
    self.hudWindow.ignoresMouseEvents = YES;
    self.hudWindow.hasShadow          = YES;
    self.hudWindow.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorStationary;

    NSVisualEffectView *blur =
        [[NSVisualEffectView alloc] initWithFrame:frame];
    blur.material     = NSVisualEffectMaterialHUDWindow;
    blur.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    blur.state        = NSVisualEffectStateActive;
    blur.maskImage = [NSImage imageWithSize:frame.size flipped:NO
        drawingHandler:^BOOL(NSRect rect) {
            [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:18 yRadius:18] fill];
            return YES;
        }];
    self.hudWindow.contentView = blur;

    self.hudIcon = [NSTextField labelWithString:@"↩"];
    self.hudIcon.font      = [NSFont systemFontOfSize:32 weight:NSFontWeightLight];
    self.hudIcon.textColor = [NSColor labelColor];
    self.hudIcon.alignment = NSTextAlignmentCenter;
    self.hudIcon.frame     = NSMakeRect(0, 32, w, 44);
    [blur addSubview:self.hudIcon];

    self.hudLabel = [NSTextField labelWithString:@""];
    self.hudLabel.font      = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    self.hudLabel.textColor = [NSColor secondaryLabelColor];
    self.hudLabel.alignment = NSTextAlignmentCenter;
    self.hudLabel.frame     = NSMakeRect(0, 10, w, 22);
    [blur addSubview:self.hudLabel];
}

- (void)showHUD {
    self.hudLabel.stringValue = g_enabled ? @"ON" : @"OFF";
    self.hudIcon.textColor = g_enabled
        ? [NSColor labelColor]
        : [NSColor tertiaryLabelColor];

    /* 居中 */
    NSRect sf = [NSScreen mainScreen].visibleFrame;
    NSRect wf = self.hudWindow.frame;
    [self.hudWindow setFrameOrigin:NSMakePoint(
        NSMidX(sf) - wf.size.width  / 2,
        NSMidY(sf) - wf.size.height / 2
    )];

    self.hudWindow.alphaValue = 1.0;
    [self.hudWindow orderFrontRegardless];

    /* 1.2s 后淡出 */
    [self.hudDismissTimer invalidate];
    __weak typeof(self) weak = self;
    self.hudDismissTimer = [NSTimer scheduledTimerWithTimeInterval:1.2
        repeats:NO block:^(NSTimer *t) {
            (void)t;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
                ctx.duration = 0.4;
                weak.hudWindow.animator.alphaValue = 0.0;
            } completionHandler:^{
                [weak.hudWindow orderOut:nil];
            }];
        }];
}

/* ---- 切换 ---- */

- (void)toggle:(id)sender {
    (void)sender;
    g_enabled = !g_enabled;

    /* 关闭时取消待发 Enter */
    if (!g_enabled && g_enter_timer) {
        CFRunLoopTimerInvalidate(g_enter_timer);
        CFRelease(g_enter_timer);
        g_enter_timer = NULL;
    }

    self.toggleItem.state = g_enabled
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.statusItem.button.alphaValue = g_enabled ? 1.0 : 0.3;

    [self showHUD];
    /* no logging — keep /tmp clean */
}

- (void)quit:(id)sender {
    (void)sender;
    /* 先让 launchd 停止管理，否则 KeepAlive 会自动重启 */
    system("launchctl unload ~/Library/LaunchAgents/com.user.typeless-autoenter.plist 2>/dev/null");
    [NSApp terminate:nil];
}

/* ---- CGEvent Tap 初始化 ---- */

- (void)setupEventTap {
    g_tap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        CGEventMaskBit(kCGEventKeyDown),
        event_callback, NULL
    );

    if (!g_tap) {
        NSString *path = [[NSBundle mainBundle] executablePath] ?: @"(unknown)";
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText     = @"Typeless AutoEnter needs Accessibility permission";
        alert.informativeText = [NSString stringWithFormat:
            @"Go to: System Settings > Privacy & Security > Accessibility\n\n"
            @"Click +, add and enable this binary:\n%@\n\n"
            @"If it already exists in the list, remove it with - first, then re-add.", path];
        alert.alertStyle = NSAlertStyleCritical;
        [alert runModal];
        system("launchctl unload ~/Library/LaunchAgents/com.user.typeless-autoenter.plist 2>/dev/null");
        [NSApp terminate:nil];
        return;
    }

    CFRunLoopSourceRef src =
        CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(g_tap, true);
    CFRelease(src);
}

/* ---- 定时刷新 PID ---- */

- (void)setupPIDRefresh {
    self.pidRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
        repeats:YES block:^(NSTimer *t) {
            (void)t;
            refresh_typeless_pids();
        }];
}

/* ---- SIGUSR1 信号 (toggle.sh 兼容) ---- */

- (void)setupSignalHandler {
    signal(SIGUSR1, SIG_IGN);
    dispatch_source_t sig = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue()
    );
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(sig, ^{ [weak toggle:nil]; });
    dispatch_resume(sig);
    self.sigSource = sig;
}

/* ---- PID 文件 ---- */

- (void)writePIDFile {
    FILE *f = fopen("/tmp/typeless-autoenter.pid", "w");
    if (f) { fprintf(f, "%d\n", getpid()); fclose(f); }
}

@end

/* ================================================================
 *  main
 * ================================================================ */

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *del   = [[AppDelegate alloc] init];
        app.delegate = del;
        [app run];
    }
    return 0;
}
