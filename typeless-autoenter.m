/**
 * [INPUT]:  macOS Cocoa (NSStatusItem, NSVisualEffectView), CoreGraphics CGEvent, libproc
 * [OUTPUT]: 菜单栏守护程序 — 检测 Typeless / Wispr Flow 输入结束后自动模拟 Enter/Tab，带毛玻璃 HUD 反馈
 * [POS]:    Typeless-AutoEnter 的核心程序（菜单栏版本，取代 CLI 版 .c）
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/* ================================================================
 *  Typeless AutoEnter — Menu Bar App
 *
 *  菜单栏 ↩ 图标 + 毛玻璃 HUD 通知
 *  可切换监听 Typeless 或 Wispr Flow
 *  CGEvent Tap 监听 → PID 过滤 → 500ms 延迟 → 模拟 Enter/Tab
 *  Ctrl+Shift+` 显示当前 Enter/Tab 状态
 *  SIGUSR1 / 菜单栏点击 切换开关
 * ================================================================ */

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Carbon/Carbon.h>   /* kVK_Return, kVK_Tab, kVK_ANSI_Grave, kVK_ANSI_V */
#import <libproc.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>

/* ================================================================
 *  全局状态
 * ================================================================ */

static volatile int g_enter_enabled = 1;
static volatile int g_tab_enabled = 0;

typedef enum {
    MonitorTargetTypeless = 0,
    MonitorTargetWisprFlow = 1
} MonitorTarget;

#define kMonitorTargetDefaultsKey @"monitorTarget"
static volatile MonitorTarget g_monitor_target = MonitorTargetTypeless;

#define MAX_PIDS 16
static pid_t g_target_pids[MAX_PIDS];
static int   g_target_pid_count = 0;

static CFRunLoopTimerRef g_action_timer = NULL;
static CFMachPortRef     g_tap = NULL;
static const CFTimeInterval DELAY_SEC = 0.5;

static const char *monitor_target_proc_needle(MonitorTarget target) {
    switch (target) {
        case MonitorTargetWisprFlow: return "Wispr Flow";
        case MonitorTargetTypeless:
        default:                     return "Typeless";
    }
}

static NSString *monitor_target_display_name(MonitorTarget target) {
    switch (target) {
        case MonitorTargetWisprFlow: return @"Wispr Flow";
        case MonitorTargetTypeless:
        default:                     return @"Typeless";
    }
}

/* 快捷键回调用的 toggle block */
static void (^g_toggle_enter_block)(void) = nil;
static void (^g_toggle_tab_block)(void) = nil;
static void (^g_show_status_block)(void) = nil;
static volatile int g_ui_lang_en = 0;  /* 0=中文(默认), 1=English */

static inline NSString *L(NSString *zh, NSString *en) {
    return g_ui_lang_en ? en : zh;
}

static void set_ui_lang_from_token(const char *token) {
    if (!token || !*token) return;
    if (strcasecmp(token, "en") == 0 || strcasecmp(token, "english") == 0) {
        g_ui_lang_en = 1;
        return;
    }
    if (strcasecmp(token, "zh") == 0 || strcasecmp(token, "cn") == 0 ||
        strcasecmp(token, "zh-cn") == 0 || strcasecmp(token, "chinese") == 0) {
        g_ui_lang_en = 0;
    }
}

static void init_ui_lang(int argc, const char *argv[]) {
    /* 默认中文，允许环境变量和启动参数覆盖 */
    g_ui_lang_en = 0;

    const char *env = getenv("TYPELESS_UI_LANG");
    set_ui_lang_from_token(env);

    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (!arg) continue;

        if (strcmp(arg, "--lang") == 0 && i + 1 < argc) {
            set_ui_lang_from_token(argv[++i]);
            continue;
        }
        if (strncmp(arg, "--lang=", 7) == 0) {
            set_ui_lang_from_token(arg + 7);
            continue;
        }
        if (strncmp(arg, "--ui-lang=", 10) == 0) {
            set_ui_lang_from_token(arg + 10);
            continue;
        }
    }
}

/* ================================================================
 *  PID 扫描: 找到当前监听目标的所有进程（后台线程执行）
 *
 *  proc_name() 是系统调用，进程数上千时阻塞可达百毫秒。
 *  主线程同时承载 CGEvent Tap 回调（active tap，系统等待返回），
 *  在主线程做 PID 扫描 = 冻结全局键盘输入。
 *  方案：后台扫描，结果写入临时数组，完成后原子交换到主线程。
 * ================================================================ */

static void refresh_target_pids(void) {
    MonitorTarget target = g_monitor_target;
    const char *needle = monitor_target_proc_needle(target);

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
                strstr(name, needle) != NULL) {
                tmp[tmp_count++] = pids[i];
            }
        }
        free(pids);

        /* 回主线程原子交换 — event_callback 永远看到一致的快照 */
        dispatch_async(dispatch_get_main_queue(), ^{
            /* 扫描期间若用户已切换目标，丢弃过期结果 */
            if (g_monitor_target != target) {
                free(tmp);
                return;
            }
            memcpy(g_target_pids, tmp, tmp_count * sizeof(pid_t));
            g_target_pid_count = tmp_count;
            free(tmp);
        });
    });
}

static int is_target_pid(pid_t pid) {
    for (int i = 0; i < g_target_pid_count; i++)
        if (g_target_pids[i] == pid) return 1;
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
     * Ctrl+Shift+`     -> 仅显示当前状态（基于物理键位，输入法无关）
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

    if (ctrl_shift_only && keycode == kVK_ANSI_Grave) {
        if (g_show_status_block)
            dispatch_async(dispatch_get_main_queue(), g_show_status_block);
        return NULL;   /* 吞掉，不传给应用 */
    }

    /* Typeless / Wispr Flow 检测 */
    if (!g_enter_enabled && !g_tab_enabled) return event;

    pid_t src = (pid_t)CGEventGetIntegerValueField(
        event, kCGEventSourceUnixProcessID
    );
    if (is_target_pid(src)) {
        /* 两者均通过 Cmd+V 粘贴文字上屏 */
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
@property (nonatomic, strong) NSMenuItem   *monitorHeaderItem;
@property (nonatomic, strong) NSMenuItem   *monitorTypelessItem;
@property (nonatomic, strong) NSMenuItem   *monitorWisprFlowItem;
@property (nonatomic, strong) NSMenuItem   *languageItem;
@property (nonatomic, strong) NSMenuItem   *quitItem;
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

    [self loadPersistedMonitorTarget];
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
    g_show_status_block = ^{ [weakSelf showStatus:nil]; };

    refresh_target_pids();
    NSLog(@"[autoenter] running (pid %d, enter=1, tab=0, ui=%s, target=%s)",
          getpid(),
          g_ui_lang_en ? "en" : "zh",
          monitor_target_proc_needle(g_monitor_target));
}

- (void)applicationWillTerminate:(NSNotification *)n {
    (void)n;
    unlink("/tmp/typeless-autoenter.pid");
}

/* ---- 菜单栏 ---- */

- (void)setupStatusBar {
    self.statusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:NSVariableStatusItemLength];

    self.statusItem.button.title = @"";

    NSMenu *menu = [[NSMenu alloc] init];

    self.toggleEnterItem = [[NSMenuItem alloc]
        initWithTitle:@""
               action:@selector(toggleEnter:)
        keyEquivalent:@""];
    self.toggleEnterItem.target = self;
    self.toggleEnterItem.state  = NSControlStateValueOn;
    [menu addItem:self.toggleEnterItem];

    self.toggleTabItem = [[NSMenuItem alloc]
        initWithTitle:@""
               action:@selector(toggleTab:)
        keyEquivalent:@""];
    self.toggleTabItem.target = self;
    self.toggleTabItem.state  = NSControlStateValueOff;
    [menu addItem:self.toggleTabItem];

    [menu addItem:[NSMenuItem separatorItem]];

    self.monitorHeaderItem = [[NSMenuItem alloc]
        initWithTitle:@""
               action:nil
        keyEquivalent:@""];
    self.monitorHeaderItem.enabled = NO;
    [menu addItem:self.monitorHeaderItem];

    self.monitorTypelessItem = [[NSMenuItem alloc]
        initWithTitle:@"Typeless"
               action:@selector(selectMonitorTypeless:)
        keyEquivalent:@""];
    self.monitorTypelessItem.target = self;
    [menu addItem:self.monitorTypelessItem];

    self.monitorWisprFlowItem = [[NSMenuItem alloc]
        initWithTitle:@"Wispr Flow"
               action:@selector(selectMonitorWisprFlow:)
        keyEquivalent:@""];
    self.monitorWisprFlowItem.target = self;
    [menu addItem:self.monitorWisprFlowItem];

    [menu addItem:[NSMenuItem separatorItem]];

    self.languageItem = [[NSMenuItem alloc]
        initWithTitle:@""
               action:@selector(toggleUILanguage:)
        keyEquivalent:@""];
    self.languageItem.target = self;
    [menu addItem:self.languageItem];

    [menu addItem:[NSMenuItem separatorItem]];

    self.quitItem = [[NSMenuItem alloc]
        initWithTitle:@""
               action:@selector(quit:)
        keyEquivalent:@"q"];
    self.quitItem.target = self;
    [menu addItem:self.quitItem];

    self.statusItem.menu = menu;
    [self refreshLocalizedTexts];
    [self refreshMenuAndIcon];
}

/* ---- 毛玻璃 HUD ---- */

- (void)setupHUD {
    CGFloat w = 220, h = 96;
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
    self.hudIcon.frame     = NSMakeRect(0, 38, w, 40);
    [blur addSubview:self.hudIcon];

    self.hudLabel = [NSTextField labelWithString:@""];
    self.hudLabel.font      = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.hudLabel.textColor = [NSColor secondaryLabelColor];
    self.hudLabel.alignment = NSTextAlignmentCenter;
    self.hudLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.hudLabel.frame     = NSMakeRect(8, 12, w - 16, 22);
    [blur addSubview:self.hudLabel];
}

- (void)presentHUD {
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

- (void)showHUDWithIcon:(NSString *)icon label:(NSString *)label enabled:(BOOL)enabled {
    NSString *displayIcon = icon ?: @"↩";
    NSColor *singleColor = enabled
        ? [NSColor labelColor]
        : [NSColor tertiaryLabelColor];
    self.hudIcon.stringValue = displayIcon;
    self.hudIcon.textColor = singleColor;
    self.hudIcon.alignment = NSTextAlignmentCenter;
    self.hudLabel.stringValue = label ?: @"";
    [self presentHUD];
}

- (NSAttributedString *)hudStatusIconAttributedTitle {
    NSString *icon = @"↩  ⇥";
    NSMutableAttributedString *attr =
        [[NSMutableAttributedString alloc] initWithString:icon];
    NSFont *font = self.hudIcon.font ?:
        [NSFont systemFontOfSize:32 weight:NSFontWeightLight];
    NSColor *enabledColor = [NSColor labelColor];
    NSColor *disabledColor = [NSColor tertiaryLabelColor];
    NSMutableParagraphStyle *centerStyle = [[NSMutableParagraphStyle alloc] init];
    centerStyle.alignment = NSTextAlignmentCenter;

    [attr addAttribute:NSFontAttributeName
                 value:font
                 range:NSMakeRange(0, icon.length)];
    [attr addAttribute:NSParagraphStyleAttributeName
                 value:centerStyle
                 range:NSMakeRange(0, icon.length)];
    [attr addAttribute:NSForegroundColorAttributeName
                 value:(g_enter_enabled ? enabledColor : disabledColor)
                 range:NSMakeRange(0, 1)];
    [attr addAttribute:NSForegroundColorAttributeName
                 value:(g_tab_enabled ? enabledColor : disabledColor)
                 range:NSMakeRange(icon.length - 1, 1)];
    return attr;
}

/* ---- 切换 ---- */

- (void)refreshLocalizedTexts {
    self.toggleEnterItem.title = L(@"自动回车", @"AutoEnter");
    self.toggleTabItem.title   = L(@"自动 Tab", @"AutoTab");
    self.monitorHeaderItem.title = L(@"监听应用", @"Monitor App");
    self.monitorTypelessItem.title = @"Typeless";
    self.monitorWisprFlowItem.title = @"Wispr Flow";
    self.languageItem.title    = g_ui_lang_en
        ? @"UI Language: English"
        : @"界面语言：中文";
    self.quitItem.title        = L(@"退出", @"Quit");
}

- (NSString *)statusSummaryText {
    NSString *enter = g_enter_enabled ? L(@"开启", @"ON") : L(@"关闭", @"OFF");
    NSString *tab   = g_tab_enabled   ? L(@"开启", @"ON") : L(@"关闭", @"OFF");
    return [NSString stringWithFormat:@"Enter: %@    Tab: %@", enter, tab];
}

/* ================================================================
 *  状态栏 Tab 图标绘制（你要改的主要区域）
 *
 *  这个函数只影响 macOS 顶部状态栏里的 Tab 图标，不影响毛玻璃 HUD。
 *
 *  调参顺序建议：
 *  1) 先调粗细: shaftStroke / headStroke
 *  2) 再调形状: startX / endX / backX / headHalf
 *  3) 最后调位置: midY + baseline offset + attachment.bounds.x(与 Enter 的间距)
 * ================================================================ */
- (NSAttributedString *)statusBarTabGlyphWithColor:(NSColor *)color {
    /* 画布尺寸（Tab 图标自身大小） */
    /* width/height 变大=图标整体更大；变小=整体更小 */
    const CGFloat width = 13.8;
    const CGFloat height = 11.6;

    /* 线宽控制 */
    /* shaftStroke: 尾巴横线粗细 */
    /* headStroke : 箭头与竖线粗细 */
    const CGFloat shaftStroke = 1.42;  /* 提升到更接近 Enter 的视觉粗细 */
    const CGFloat headStroke = 1.24;   /* 箭头与竖线同步加粗 */

    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
    [img lockFocus];
    [color setStroke];

    /* 几何参数（决定 Tab 外形） */
    /* midY    : 整个 Tab 在画布内的垂直位置，+ 往上，- 往下 */
    /* startX  : 尾巴起点；值越大，尾巴越短 */
    /* endX    : 右端终点；值越大，整体越长 */
    /* backX   : 箭头回收点；值越小，箭头头越长 */
    /* headHalf: 箭头半高；值越大，箭头/竖线越高 */
    CGFloat midY = 5.5;      /* 0.5 对齐，减少抗锯齿导致的忽粗忽细 */
    CGFloat startX = 1.8;    /* 尾巴再短一点 */
    CGFloat endX = 11.5;     /* 整体略缩小，更贴近 Enter 体量 */
    CGFloat backX = 9.2;     /* 箭头头部再长一点 */
    CGFloat headHalf = 2.25; /* 稍微增加箭头头部高度 */

    NSBezierPath *shaft = [NSBezierPath bezierPath];
    shaft.lineWidth = shaftStroke;
    shaft.lineCapStyle = NSLineCapStyleRound;
    [shaft moveToPoint:NSMakePoint(startX, midY)];
    [shaft lineToPoint:NSMakePoint(endX, midY)];
    [shaft stroke];

    NSBezierPath *head = [NSBezierPath bezierPath];
    head.lineWidth = headStroke;
    head.lineCapStyle = NSLineCapStyleRound;
    head.lineJoinStyle = NSLineJoinStyleRound;
    [head moveToPoint:NSMakePoint(backX, midY - headHalf)];
    [head lineToPoint:NSMakePoint(endX, midY)];
    [head lineToPoint:NSMakePoint(backX, midY + headHalf)];
    [head stroke];

    NSBezierPath *cap = [NSBezierPath bezierPath];
    cap.lineWidth = headStroke;
    cap.lineCapStyle = NSLineCapStyleRound;
    /* 竖线与箭头头部同高 */
    [cap moveToPoint:NSMakePoint(endX, midY - headHalf)];
    [cap lineToPoint:NSMakePoint(endX, midY + headHalf)];
    [cap stroke];

    [img unlockFocus];

    NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
    attachment.image = img;
    /* attachment.bounds.x = 与 Enter 图标的水平间距（最常改） */
    /* x 更大(如 0.2) => Enter/Tab 更远；x 更小(如 -0.8) => 更近 */
    /* y 通常保持 0，避免状态栏垂直抖动 */
    attachment.bounds = NSMakeRect(-0.2, 0.0, width, height);
    NSMutableAttributedString *tab =
        [[NSMutableAttributedString alloc]
            initWithAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    [tab addAttribute:NSBaselineOffsetAttributeName
                /* baseline offset: Tab 相对 Enter 的垂直微调 */
                /* 更负(如 -1.0) => Tab 更往下；更大(如 -0.3) => Tab 更往上 */
                value:@(-0.7)   /* 当前值: Tab 单独下移 0.3 */
                range:NSMakeRange(0, tab.length)];
    return tab;
}

/* ================================================================
 *  状态栏 Enter + Tab 组合（你要改的第二个区域）
 *
 *  - Enter / Tab 都用字体符号渲染（统一风格）
 *  - 亮暗逻辑：enterColor/tabColor 分别由各自开关控制
 * ================================================================ */
- (NSAttributedString *)statusBarIconAttributedTitle {
    NSColor *enabledColor = [NSColor labelColor];
    NSColor *disabledColor = [NSColor systemGrayColor];
    NSColor *enterColor = g_enter_enabled ? enabledColor : disabledColor;
    NSColor *tabColor = g_tab_enabled ? enabledColor : disabledColor;

    /* Enter 图标字体。你觉得 Enter 太大/太小，就改这里 */
    NSFont *enterFont = [NSFont monospacedSystemFontOfSize:15 weight:NSFontWeightMedium];
    NSMutableAttributedString *attr =
        [[NSMutableAttributedString alloc]
            initWithString:@"↩"
                attributes:@{
                    NSFontAttributeName: enterFont,
                    NSForegroundColorAttributeName: enterColor
                }];

    /* Tab 改为符号渲染：和 Enter 一样稳定，不受自绘抗锯齿影响 */
    NSFont *tabFont = [NSFont monospacedSystemFontOfSize:15 weight:NSFontWeightMedium];
    [attr appendAttributedString:[[NSAttributedString alloc]
        initWithString:@" "
            attributes:@{ NSFontAttributeName: enterFont }]];

    NSMutableAttributedString *tabAttr =
        [[NSMutableAttributedString alloc]
            initWithString:@"⇥"
                attributes:@{
                    NSFontAttributeName: tabFont,
                    NSForegroundColorAttributeName: tabColor
                }];
    [tabAttr addAttribute:NSBaselineOffsetAttributeName
                    value:@(0.2)   /* 微调: 相比上一版下移约 0.2px 体感 */
                    range:NSMakeRange(0, tabAttr.length)];
    [attr appendAttributedString:tabAttr];

    return attr;
}

- (void)refreshMenuAndIcon {
    /* 每次开关变化后都会走这里，把新图标刷新到顶部状态栏 */
    self.toggleEnterItem.state = g_enter_enabled
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.toggleTabItem.state = g_tab_enabled
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.monitorTypelessItem.state =
        (g_monitor_target == MonitorTargetTypeless)
            ? NSControlStateValueOn : NSControlStateValueOff;
    self.monitorWisprFlowItem.state =
        (g_monitor_target == MonitorTargetWisprFlow)
            ? NSControlStateValueOn : NSControlStateValueOff;

    self.statusItem.button.title = @"";
    self.statusItem.button.attributedTitle = [self statusBarIconAttributedTitle];
    self.statusItem.button.alphaValue = 1.0;
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
                    label:g_enter_enabled
                        ? L(@"自动回车 已开启", @"AutoEnter ON")
                        : L(@"自动回车 已关闭", @"AutoEnter OFF")
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
                    label:g_tab_enabled
                        ? L(@"自动 Tab 已开启", @"AutoTab ON")
                        : L(@"自动 Tab 已关闭", @"AutoTab OFF")
                  enabled:g_tab_enabled];
    NSLog(@"[autoenter] tab %s", g_tab_enabled ? "ENABLED" : "DISABLED");
}

- (void)toggleUILanguage:(id)sender {
    (void)sender;
    g_ui_lang_en = !g_ui_lang_en;
    [self refreshLocalizedTexts];
    [self refreshMenuAndIcon];
    [self showHUDWithIcon:@"文  A"
                    label:g_ui_lang_en
                        ? @"UI switched to English"
                        : @"界面已切换为中文"
                  enabled:YES];
    NSLog(@"[autoenter] ui language -> %s", g_ui_lang_en ? "en" : "zh");
}

- (void)loadPersistedMonitorTarget {
    NSInteger saved = [[NSUserDefaults standardUserDefaults]
        integerForKey:kMonitorTargetDefaultsKey];
    if (saved == MonitorTargetWisprFlow) {
        g_monitor_target = MonitorTargetWisprFlow;
    } else {
        g_monitor_target = MonitorTargetTypeless;
    }
}

- (void)persistMonitorTarget {
    [[NSUserDefaults standardUserDefaults]
        setInteger:(NSInteger)g_monitor_target
            forKey:kMonitorTargetDefaultsKey];
}

- (void)applyMonitorTarget:(MonitorTarget)target {
    if (g_monitor_target == target) return;

    g_monitor_target = target;
    g_target_pid_count = 0;
    cancel_action_timer();
    [self persistMonitorTarget];
    [self refreshMenuAndIcon];
    refresh_target_pids();

    NSString *name = monitor_target_display_name(target);
    [self showHUDWithIcon:@"◎"
                    label:[NSString stringWithFormat:
                        L(@"监听 %@", @"Monitoring %@"), name]
                  enabled:YES];
    NSLog(@"[autoenter] monitor target -> %s",
          monitor_target_proc_needle(target));
}

- (void)selectMonitorTypeless:(id)sender {
    (void)sender;
    [self applyMonitorTarget:MonitorTargetTypeless];
}

- (void)selectMonitorWisprFlow:(id)sender {
    (void)sender;
    [self applyMonitorTarget:MonitorTargetWisprFlow];
}

- (void)showStatus:(id)sender {
    (void)sender;
    self.hudIcon.attributedStringValue = [self hudStatusIconAttributedTitle];
    self.hudLabel.stringValue = [self statusSummaryText];
    [self presentHUD];
    NSLog(@"[autoenter] status enter=%d tab=%d", g_enter_enabled, g_tab_enabled);
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
        NSString *path = [[NSBundle mainBundle] executablePath] ?:
            L(@"(未知路径)", @"(unknown path)");
        open_accessibility_settings();
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = L(
            @"Typeless AutoEnter 需要辅助功能权限",
            @"Typeless AutoEnter needs Accessibility permission"
        );
        if (g_ui_lang_en) {
            alert.informativeText = [NSString stringWithFormat:
                @"Tried opening: System Settings > Privacy & Security > Accessibility\n\n"
                @"Click +, add and enable this app binary:\n%@\n\n"
                @"If it already exists in the list, remove it with - first, then re-add.\n\n"
                @"After granting permission, launch TypelessAutoEnter.app again.", path];
        } else {
            alert.informativeText = [NSString stringWithFormat:
                @"已尝试自动打开：系统设置 → 隐私与安全性 → 辅助功能\n\n"
                @"点击 + 号，添加以下程序并启用：\n%@\n\n"
                @"如果列表中已存在，请先用 - 号移除，再重新添加。\n"
                @"授权完成后，请关闭并重新打开一次 App。", path];
        }
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
            refresh_target_pids();
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
    init_ui_lang(argc, argv);
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *del   = [[AppDelegate alloc] init];
        app.delegate = del;
        [app run];
    }
    return 0;
}
