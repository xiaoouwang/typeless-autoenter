/**
 * [INPUT]:  macOS Cocoa (NSStatusItem, NSVisualEffectView), CoreGraphics CGEvent, libproc
 * [OUTPUT]: 菜单栏守护程序 — 检测 Typeless 输入结束后自动模拟 Enter/Tab，带毛玻璃 HUD 反馈
 * [POS]:    Typeless-AutoEnter 的核心程序（菜单栏版本，取代 CLI 版 .c）
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/* ================================================================
 *  Typeless AutoEnter — Menu Bar App
 *
 *  菜单栏 ↩ 图标 + 毛玻璃 HUD 通知
 *  CGEvent Tap 监听 → PID 过滤 → 500ms 延迟 → 模拟 Enter/Tab
 *  SIGUSR1 / 菜单栏点击 切换开关
 * ================================================================ */

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Carbon/Carbon.h>   /* kVK_Return, kVK_Tab, kVK_ANSI_V */
#import <libproc.h>
#include <signal.h>

/* ================================================================
 *  全局状态
 * ================================================================ */

static volatile int g_enter_enabled = 1;
static volatile int g_tab_enabled = 0;

#define MAX_PIDS 16
static pid_t g_typeless_pids[MAX_PIDS];
static int   g_typeless_pid_count = 0;

static CFRunLoopTimerRef g_action_timer = NULL;
static CFMachPortRef     g_tap = NULL;
static const CFTimeInterval DELAY_SEC = 0.5;

/* 快捷键回调用的 toggle block */
static void (^g_toggle_enter_block)(void) = nil;
static void (^g_toggle_tab_block)(void) = nil;

/* ================================================================
 *  PID 扫描: 找到所有 Typeless 进程（后台线程执行）
 *
 *  proc_name() 是系统调用，进程数上千时阻塞可达百毫秒。
 *  主线程同时承载 CGEvent Tap 回调（active tap，系统等待返回），
 *  在主线程做 PID 扫描 = 冻结全局键盘输入。
 *  方案：后台扫描，结果写入临时数组，完成后原子交换到主线程。
 * ================================================================ */

static void refresh_typeless_pids(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int buf_size = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
        if (buf_size <= 0) return;

        pid_t *pids = malloc(buf_size);
        if (!pids) return;

        int count = proc_listpids(PROC_ALL_PIDS, 0, pids, buf_size)
                    / (int)sizeof(pid_t);

        /* 写入 heap 临时数组，不碰全局状态 */
        pid_t *tmp = malloc(MAX_PIDS * sizeof(pid_t));
        if (!tmp) { free(pids); return; }
        __block int tmp_count = 0;
        for (int i = 0; i < count && tmp_count < MAX_PIDS; i++) {
            if (pids[i] == 0) continue;
            char name[256];
            if (proc_name(pids[i], name, sizeof(name)) > 0 &&
                strstr(name, "Typeless") != NULL) {
                tmp[tmp_count++] = pids[i];
            }
        }
        free(pids);

        /* 回主线程原子交换 — event_callback 永远看到一致的快照 */
        dispatch_async(dispatch_get_main_queue(), ^{
            memcpy(g_typeless_pids, tmp, tmp_count * sizeof(pid_t));
            g_typeless_pid_count = tmp_count;
            free(tmp);
        });
    });
}

static int is_typeless_pid(pid_t pid) {
    for (int i = 0; i < g_typeless_pid_count; i++)
        if (g_typeless_pids[i] == pid) return 1;
    return 0;
}

/* ================================================================
 *  模拟按键（强制无修饰键，避免误触发 Cmd+Tab）
 * ================================================================ */

static void post_key(CGKeyCode keycode) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStatePrivate);
    if (!src) return;

    CGEventRef down = CGEventCreateKeyboardEvent(src, keycode, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(src, keycode, false);
    if (!down || !up) {
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        CFRelease(src);
        return;
    }

    /* 清空 flags，彻底阻断外部 Cmd/Shift/Ctrl 状态污染 */
    CGEventSetFlags(down, 0);
    CGEventSetFlags(up, 0);

    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
    CFRelease(src);
}

static void post_enter(void) { post_key(kVK_Return); }
static void post_tab(void)   { post_key(kVK_Tab); }

/* ================================================================
 *  500ms 延迟触发
 * ================================================================ */

static void timer_fired(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    if (g_enter_enabled) post_enter();
    if (g_tab_enabled)   post_tab();
    if (g_action_timer) { CFRelease(g_action_timer); g_action_timer = NULL; }
}

static void cancel_action_timer(void) {
    if (!g_action_timer) return;
    CFRunLoopTimerInvalidate(g_action_timer);
    CFRelease(g_action_timer);
    g_action_timer = NULL;
}

static void reset_timer(void) {
    cancel_action_timer();
    g_action_timer = CFRunLoopTimerCreate(
        kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + DELAY_SEC,
        0, 0, 0, timer_fired, NULL
    );
    CFRunLoopAddTimer(CFRunLoopGetMain(), g_action_timer, kCFRunLoopCommonModes);
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

    /* 快捷键:
     * Ctrl+Shift+Enter -> 切换 AutoEnter
     * Ctrl+Shift+Tab   -> 切换 AutoTab
     * 命中后吞掉按键，不传给应用
     */
    CGKeyCode keycode = (CGKeyCode)CGEventGetIntegerValueField(
        event, kCGKeyboardEventKeycode
    );
    CGEventFlags flags = CGEventGetFlags(event);
    int ctrl_shift_only =
        (flags & kCGEventFlagMaskControl) &&
        (flags & kCGEventFlagMaskShift) &&
        !(flags & kCGEventFlagMaskCommand) &&
        !(flags & kCGEventFlagMaskAlternate);

    if (ctrl_shift_only && keycode == kVK_Return) {
        if (g_toggle_enter_block)
            dispatch_async(dispatch_get_main_queue(), g_toggle_enter_block);
        return NULL;   /* 吞掉，不传给应用 */
    }

    if (ctrl_shift_only && keycode == kVK_Tab) {
        if (g_toggle_tab_block)
            dispatch_async(dispatch_get_main_queue(), g_toggle_tab_block);
        return NULL;   /* 吞掉，不传给应用 */
    }

    /* Typeless 检测 */
    if (!g_enter_enabled && !g_tab_enabled) return event;

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

static void open_accessibility_settings(void) {
    NSArray<NSString *> *urls = @[
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        @"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        @"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        @"x-apple.systempreferences:"
    ];

    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
    for (NSString *raw in urls) {
        NSURL *url = [NSURL URLWithString:raw];
        if (!url) continue;
        if ([workspace openURL:url]) {
            NSLog(@"[autoenter] opened settings url: %@", raw);
            return;
        }
    }

    /* 兜底: 无法跳转隐私页时至少拉起系统设置 */
    system("open \"/System/Applications/System Settings.app\" >/dev/null 2>&1 || "
           "open \"/System/Applications/System Preferences.app\" >/dev/null 2>&1");
    NSLog(@"[autoenter] fallback opened system settings");
}

/* ================================================================
 *  App Delegate
 * ================================================================ */

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem   *toggleEnterItem;
@property (nonatomic, strong) NSMenuItem   *toggleTabItem;
@property (nonatomic, strong) HUDWindow    *hudWindow;
@property (nonatomic, strong) NSTextField  *hudIcon;
@property (nonatomic, strong) NSTextField  *hudLabel;
@property (nonatomic, strong) NSTimer      *hudDismissTimer;
@property (nonatomic, strong) NSTimer      *pidRefreshTimer;
@property (nonatomic)         dispatch_source_t sigSource;
@end

@implementation AppDelegate

static inline BOOL has_enabled_action(void) {
    return (g_enter_enabled || g_tab_enabled) ? YES : NO;
}

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
    g_toggle_enter_block = ^{ [weakSelf toggleEnter:nil]; };
    g_toggle_tab_block = ^{ [weakSelf toggleTab:nil]; };

    refresh_typeless_pids();
    NSLog(@"[autoenter] running (pid %d, enter=1, tab=0)", getpid());
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

    self.toggleEnterItem = [[NSMenuItem alloc]
        initWithTitle:@"AutoEnter"
               action:@selector(toggleEnter:)
        keyEquivalent:@""];
    self.toggleEnterItem.target = self;
    self.toggleEnterItem.state  = NSControlStateValueOn;
    [menu addItem:self.toggleEnterItem];

    self.toggleTabItem = [[NSMenuItem alloc]
        initWithTitle:@"AutoTab"
               action:@selector(toggleTab:)
        keyEquivalent:@""];
    self.toggleTabItem.target = self;
    self.toggleTabItem.state  = NSControlStateValueOff;
    [menu addItem:self.toggleTabItem];

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

- (void)showHUDWithIcon:(NSString *)icon label:(NSString *)label enabled:(BOOL)enabled {
    self.hudIcon.stringValue = icon ?: @"↩";
    self.hudLabel.stringValue = label ?: @"";
    self.hudIcon.textColor = enabled
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

- (void)refreshMenuAndIcon {
    self.toggleEnterItem.state = g_enter_enabled
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.toggleTabItem.state = g_tab_enabled
        ? NSControlStateValueOn : NSControlStateValueOff;

    if (g_enter_enabled && g_tab_enabled) {
        self.statusItem.button.title = @"↩⇥";
    } else if (g_enter_enabled) {
        self.statusItem.button.title = @"↩";
    } else if (g_tab_enabled) {
        self.statusItem.button.title = @"⇥";
    } else {
        self.statusItem.button.title = @"↩";
    }
    self.statusItem.button.alphaValue = has_enabled_action() ? 1.0 : 0.3;
}

- (void)toggleEnter:(id)sender {
    (void)sender;
    g_enter_enabled = !g_enter_enabled;

    /* 两个功能都关闭时取消待发动作 */
    if (!has_enabled_action()) {
        cancel_action_timer();
    }

    [self refreshMenuAndIcon];
    [self showHUDWithIcon:@"↩"
                    label:g_enter_enabled ? @"AutoEnter ON" : @"AutoEnter OFF"
                  enabled:g_enter_enabled];
    NSLog(@"[autoenter] enter %s", g_enter_enabled ? "ENABLED" : "DISABLED");
}

- (void)toggleTab:(id)sender {
    (void)sender;
    g_tab_enabled = !g_tab_enabled;

    if (!has_enabled_action()) {
        cancel_action_timer();
    }

    [self refreshMenuAndIcon];
    [self showHUDWithIcon:@"⇥"
                    label:g_tab_enabled ? @"AutoTab ON" : @"AutoTab OFF"
                  enabled:g_tab_enabled];
    NSLog(@"[autoenter] tab %s", g_tab_enabled ? "ENABLED" : "DISABLED");
}

/* 保留原入口，兼容菜单历史 action 和 SIGUSR1 */
- (void)toggle:(id)sender {
    [self toggleEnter:sender];
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
        NSString *path = [[NSBundle mainBundle] executablePath] ?: @"(unknown path)";
        open_accessibility_settings();
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText     = @"Typeless AutoEnter needs Accessibility permission";
        alert.informativeText = [NSString stringWithFormat:
            @"Tried opening: System Settings > Privacy & Security > Accessibility\n\n"
            @"Click +, add and enable this app binary:\n%@\n\n"
            @"If it already exists in the list, remove it with - first, then re-add.\n\n"
            @"After granting permission, launch TypelessAutoEnter.app again.", path];
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

/* ---- SIGUSR1 信号 (toggle.sh 兼容，切换 AutoEnter) ---- */

- (void)setupSignalHandler {
    signal(SIGUSR1, SIG_IGN);
    dispatch_source_t sig = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue()
    );
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(sig, ^{ [weak toggleEnter:nil]; });
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
