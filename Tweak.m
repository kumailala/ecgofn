// NEWLIB.dylib — FPS unlock + FPS counter for Fortnite iOS 3.6 (Echo client)
// Plain Objective-C runtime hooks. No theos/Logos required.
//
// What it does:
//   1) Unlocks FPS by defeating Epic's EPowerUsageFrameRateLock path:
//        - [NSProcessInfo isLowPowerModeEnabled] -> NO
//        - [NSProcessInfo thermalState]           -> Nominal
//        - [CADisplayLink setPreferredFramesPerSecond:] -> 0 (max refresh)
//   2) Draws a real on-screen FPS counter by counting rendered frames
//        (CAMetalLayer -nextDrawable, i.e. the actual Metal present rate),
//        with a CADisplayLink fallback if the build is not on Metal.
//   3) Platform HUD (TEST SCAFFOLD): a standalone top-right overlay that currently renders
//        live test text (bundle id / device / heartbeat) to prove the overlay pipeline works,
//        before real per-player platform data is wired in.
//   4) Startup alert: a one-shot "dylib loaded OK" popup with an OK button, so you can confirm
//        injection even if the overlays never render.
//   5) Overhead labels: a per-frame layer of floating labels drawn at each player's projected
//        head position (world -> screen via the engine's own ProjectWorldLocationToScreen), so
//        they track players in 3D instead of sitting on a flat overlay. Hidden the instant they
//        leave the screen. The real data comes from section 7.
//   6) Engine address probe (SAFE): resolves offline-recovered engine function addresses against
//        the live ASLR slide and reports whether they land inside the main image. No hooking and
//        no dereferencing of game code, so it cannot crash the app. This is the gate that proves
//        our offline symbol map is usable before any real engine access is attempted.
//   7) Real player data (NO hooks): calls the engine's GetPlayerController / GetGameState directly
//        and reads memory through mach_vm_read_overwrite (which never faults on a bad address),
//        then projects each player's pawn position to screen. No inline hooking, because iOS
//        code-signing blocks patching __TEXT on a non-jailbroken app. All offsets/addresses were
//        recovered offline from the decrypted binary (research/NOTES.md).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdatomic.h>
#include <math.h>

static _Atomic int gMetalFrames   = 0;
static _Atomic int gDisplayFrames = 0;

static UILabel   *gFpsLabel  = nil;
static UIWindow  *gOverlay   = nil;
static BOOL       gUseDisplay = NO;
static BOOL       gDecided    = NO;

// platform HUD (test build: proves the overlay renders before real data is wired in)
static UILabel   *gPlatLabel  = nil;
static UIWindow  *gPlatOverlay = nil;
static const CGFloat gPlatWidth = 300.0;

// dispatch sources are ARC-managed objects: a *local* one is released when the enclosing
// block ends, so the timer never fires. Keep strong refs or the overlay never updates.
static dispatch_source_t gFpsTimer  = nil;
static dispatch_source_t gPlatTimer = nil;

// overhead "platform" labels (test scaffold; implemented in section 5, counted by the HUD panel)
@interface EchoOverheadLabel : NSObject
@property (nonatomic, strong) UILabel *view;
@property (nonatomic, copy)   NSString *text;
@property (nonatomic, assign) CGFloat nx;   // 0..1 across the screen
@property (nonatomic, assign) CGFloat ny;   // 0..1 down the screen
@end
static NSMutableArray<EchoOverheadLabel *> *gLabels = nil;

// engine address probe result (filled in by probeEngine() in section 6, shown in the HUD panel)
static BOOL gProbeInRange = NO;

// engine-data diagnostics (filled in section 7, shown in the HUD panel)
static BOOL gDiagEngine, gDiagPC, gDiagGameState;
static int  gDiagPlayers, gDiagDrawn;

#pragma mark - runtime helper

static void exchange(Class cls, SEL sel, IMP newImp, IMP *storeOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *storeOrig = method_setImplementation(m, newImp);
}

#pragma mark - 1) FPS unlock: power / thermal / display link

static BOOL (*orig_isLowPowerModeEnabled)(id, SEL);
static BOOL hook_isLowPowerModeEnabled(id self, SEL _cmd) {
    return NO;
}

static NSInteger (*orig_thermalState)(id, SEL);
static NSInteger hook_thermalState(id self, SEL _cmd) {
    return 0; // NSProcessInfoThermalStateNominal
}

static void (*orig_setPreferredFPS)(id, SEL, NSInteger);
static void hook_setPreferredFPS(id self, SEL _cmd, NSInteger v) {
    orig_setPreferredFPS(self, _cmd, 0); // 0 == maximum supported refresh rate
}

#pragma mark - 2) real render counter

static id (*orig_nextDrawable)(id, SEL);
static id hook_nextDrawable(id self, SEL _cmd) {
    atomic_fetch_add(&gMetalFrames, 1);
    return orig_nextDrawable(self, _cmd);
}

#pragma mark - overlay

@interface EchoFpsTicker : NSObject
@property (nonatomic, strong) CADisplayLink *link;
@end

@implementation EchoFpsTicker
- (void)tick:(CADisplayLink *)link { atomic_fetch_add(&gDisplayFrames, 1); }
@end

static EchoFpsTicker *gTicker = nil;

// iOS 13+ scene lifecycle: a UIWindow with no windowScene attached is never displayed.
// Grab the app's active UIWindowScene and (re)attach when needed.
static UIWindowScene *activeWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        UIApplication *app = UIApplication.sharedApplication;
        for (UIScene *s in app.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive)
                return (UIWindowScene *)s;
        }
        for (UIScene *s in app.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
        }
    }
    return nil;
}

// Safe to call from any main-queue block; no-ops on <iOS 13 or once attached.
static void attachScene(UIWindow *w) {
    if (!w) return;
    if (@available(iOS 13.0, *)) {
        if (w.windowScene) return;
        UIWindowScene *sc = activeWindowScene();
        if (sc) w.windowScene = sc;
    }
}

static void installOverlay(void) {
    if (gOverlay) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gOverlay) return;

        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel        = UIWindowLevelAlert + 1;
        w.backgroundColor    = [UIColor clearColor];
        w.userInteractionEnabled = NO;

        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        vc.view.userInteractionEnabled = NO;
        w.rootViewController = vc;

        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(12, 30, 300, 24)];
        l.textColor    = [UIColor colorWithRed:0.25 green:1.0 blue:0.45 alpha:1.0];
        l.shadowColor  = [UIColor blackColor];
        l.shadowOffset = CGSizeMake(1.0, 1.0);
        l.font         = [UIFont boldSystemFontOfSize:15.0];
        l.text         = @"FPS: --";
        [vc.view addSubview:l];

        w.hidden = NO; // NOT makeKeyAndVisible — never steal the game's key window
        attachScene(w);
        gOverlay = w;
        gFpsLabel = l;

        // fallback frame source (display refresh) in case Metal isn't used
        gTicker = [[EchoFpsTicker alloc] init];
        CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:gTicker selector:@selector(tick:)];
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        gTicker.link = dl;

        dispatch_source_t timer =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  NSEC_PER_SEC, 50ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            static int last = 0;
            attachScene(gOverlay); // self-heal if the scene connected after install
            if (!gDecided) {
                if (atomic_load(&gMetalFrames) > 0)            { gUseDisplay = NO;  gDecided = YES; }
                else if (atomic_load(&gDisplayFrames) > 30)    { gUseDisplay = YES; gDecided = YES; }
            }
            int cur = gUseDisplay ? atomic_load(&gDisplayFrames)
                                  : atomic_load(&gMetalFrames);
            int fps = cur - last;
            if (fps < 0) fps = 0;
            last = cur;
            gFpsLabel.text = [NSString stringWithFormat:@"FPS: %d%@", fps,
                              gUseDisplay ? @" (disp)" : @""];
        });
        gFpsTimer = timer;          // keep alive (see note at top)
        dispatch_resume(timer);
    });
}

#pragma mark - 3) platform HUD (test scaffold)

// Lays out the (multi-line) platform text top-right, growing downward. Fixed-width so the
// rows stay left aligned once real "player - platform" lines replace the test text.
static void setPlatLines(NSArray<NSString *> *lines) {
    if (!gPlatLabel) return;
    NSString *s = [lines componentsJoinedByString:@"\n"];
    gPlatLabel.text = s;

    CGSize max = CGSizeMake(gPlatWidth, CGFLOAT_MAX);
    CGRect r = [s boundingRectWithSize:max
                               options:NSStringDrawingUsesLineFragmentOrigin
                            attributes:@{ NSFontAttributeName: gPlatLabel.font }
                               context:nil];
    CGRect sb = [UIScreen mainScreen].bounds;
    gPlatLabel.frame = CGRectMake(sb.size.width - gPlatWidth - 12.0, 56.0,
                                  gPlatWidth, ceil(r.size.height) + 6.0);
}

static void installPlatformOverlay(void) {
    if (gPlatOverlay) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPlatOverlay) return;

        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel            = UIWindowLevelAlert + 1;
        w.backgroundColor        = [UIColor clearColor];
        w.userInteractionEnabled = NO; // never eat touches meant for the game

        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor  = [UIColor clearColor];
        vc.view.userInteractionEnabled = NO;
        w.rootViewController = vc;

        UILabel *l = [[UILabel alloc] init];
        l.numberOfLines = 0;
        l.textColor     = [UIColor colorWithRed:0.35 green:0.82 blue:1.0 alpha:1.0];
        l.shadowColor   = [UIColor blackColor];
        l.shadowOffset  = CGSizeMake(1.0, 1.0);
        l.font          = [UIFont boldSystemFontOfSize:13.0];
        [vc.view addSubview:l];

        w.hidden      = NO; // NOT makeKeyAndVisible — never steal the game's key window
        attachScene(w);
        gPlatOverlay  = w;
        gPlatLabel    = l;

        // draw something immediately so the panel is visible even before the first tick
        setPlatLines(@[ @"[EchoMod] platform HUD — TEST", @"starting…" ]);

        // heartbeat: if "tick" keeps climbing, the overlay is live and updating.
        dispatch_source_t timer =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2),
                                  NSEC_PER_SEC / 2, 50ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            static int tick = 0;
            attachScene(gPlatOverlay); // self-heal if the scene connected after install
            int onscreen = 0;
            for (EchoOverheadLabel *L in gLabels) {
                if (L.nx >= 0.0 && L.nx <= 1.0 && L.ny >= 0.0 && L.ny <= 1.0) onscreen++;
            }
            NSString *eng = gProbeInRange ? @"ok" : @"NO";
            setPlatLines(@[
                @"[EchoMod] overhead labels",
                [NSString stringWithFormat:@"engine: %@  pc: %@", eng, gDiagPC ? @"Y" : @"n"],
                [NSString stringWithFormat:@"gs: %@  players: %d  drawn: %d",
                    gDiagGameState ? @"Y" : @"n", gDiagPlayers, gDiagDrawn],
                [NSString stringWithFormat:@"onscreen: %d  tick: %d", onscreen, ++tick],
            ]);
        });
        gPlatTimer = timer;         // keep alive (see note at top)
        dispatch_resume(timer);
    });
}

#pragma mark - 4) startup "loaded" alert

// Top-most view controller across all scenes, so the alert lands on whatever the game shows.
static UIViewController *topViewController(void) {
    UIWindow *key = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (w.isKeyWindow) { key = w; break; }
            }
            if (key) break;
        }
    }
    if (!key) key = UIApplication.sharedApplication.keyWindow;
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// One-shot "the dylib is alive" popup. Retries briefly if the game's UI isn't up yet.
static void showLoadedAlert(int attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = topViewController();
        if (!top) {
            if (attempt < 5) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                               dispatch_get_main_queue(), ^{ showLoadedAlert(attempt + 1); });
            } else {
                NSLog(@"[EchoMod] no view controller to present on — overlay still active");
            }
            return;
        }

        UIAlertController *a =
            [UIAlertController alertControllerWithTitle:@"EchoMod"
                                                message:@"dylib loaded OK ✅\n(injection test)"
                                         preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
        NSLog(@"[EchoMod] loaded alert presented on %@", NSStringFromClass([top class]));
    });
}

#pragma mark - 5) overhead "platform" labels (test scaffold)

// A floating label. In the real build, (nx, ny) is the *projected* head position of a player
// (world -> screen); here it's driven by synthetic motion so the render path can be proven.
// (Interface lives up top because the HUD panel counts the labels.)
@implementation EchoOverheadLabel
@end

static void updateOverheadLabels(void);   // fwd
static void fillPlayerLabels(void);       // fwd (real player data, defined in section 7)

@interface EchoLabelTicker : NSObject
@end

@implementation EchoLabelTicker
- (void)tick:(CADisplayLink *)link { updateOverheadLabels(); }
@end

static UIWindow        *gLabelWindow = nil;
static UIView          *gLabelRoot   = nil;
static CADisplayLink   *gLabelLink   = nil;
static EchoLabelTicker *gLabelTicker = nil;
static CFTimeInterval   gLabelT0     = 0;

static BOOL pointOnScreen(CGFloat nx, CGFloat ny) {
    return nx >= 0.0 && nx <= 1.0 && ny >= 0.0 && ny <= 1.0;
}

// ---- player data source --------------------------------------------------------------
// Real labels come from section 7 (fillPlayerLabels): each player's pawn world position,
// projected to screen with the engine's own ProjectWorldLocationToScreen. If the engine
// pointers can't be resolved yet, no labels are shown (rather than fake ones).
// ---------------------------------------------------------------------------------------

static void updateOverheadLabels(void) {
    if (!gLabelRoot) return;
    attachScene(gLabelWindow);

    fillPlayerLabels();

    CGSize sz = gLabelRoot.bounds.size;
    for (EchoOverheadLabel *L in gLabels) {
        UILabel *v = L.view;
        [v sizeToFit];
        CGSize ts = v.bounds.size;
        v.frame = CGRectMake(0, 0, ts.width + 14.0, ts.height + 4.0);

        // "only when visible": drop the label the moment its point leaves the screen.
        BOOL onScreen = pointOnScreen(L.nx, L.ny);
        v.hidden = !onScreen;
        if (!onScreen) continue;

        v.center = CGPointMake(L.nx * sz.width, L.ny * sz.height);
    }
}

static void installLabelLayer(void) {
    if (gLabelWindow) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gLabelWindow) return;

        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel            = UIWindowLevelAlert + 1;
        w.backgroundColor        = [UIColor clearColor];
        w.userInteractionEnabled = NO;   // never eat touches meant for the game

        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor        = [UIColor clearColor];
        vc.view.userInteractionEnabled = NO;
        w.rootViewController = vc;

        w.hidden = NO;                   // NOT makeKeyAndVisible
        attachScene(w);
        gLabelWindow = w;
        gLabelRoot   = vc.view;
        gLabels      = [NSMutableArray array];
        gLabelT0     = CACurrentMediaTime();

        // per-frame update so labels track the world instead of stuttering at 1 Hz
        gLabelTicker = [[EchoLabelTicker alloc] init];
        gLabelLink = [CADisplayLink displayLinkWithTarget:gLabelTicker
                                                 selector:@selector(tick:)];
        [gLabelLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
}

#pragma mark - 6) engine address probe (SAFE: no hooking, no deref of game code)

// Preferred (unslid) VM addresses recovered offline from the decrypted binary by scanning the
// UE reflection registration tables in __DATA for { name_string_ptr, code_ptr } pairs.
// See research/NOTES.md (kept outside the public repo). Nothing is hooked here — we only
// resolve the runtime address and prove it lands inside the main image's mapped range.
static const uintptr_t kSym_ProjectWorldLocationToScreen = 0x100e7b304;
static const uintptr_t kSym_GetPlayerPlatform            = 0x101acf364;
static const uintptr_t kSym_OnRep_Platform               = 0x1012b7fd8;

static uintptr_t gImgBase     = 0;
static uintptr_t gImgEnd      = 0;
static intptr_t  gSlide       = 0;
static uintptr_t gProbeProj   = 0;
static uintptr_t gProbePlat   = 0;
// (gProbeInRange is declared up top, next to gLabels, because the HUD panel reads it)

// Upper bound of the main image by walking its Mach-O load commands. The header is always
// mapped, so this is safe to read; we never touch the resolved function addresses.
static void imageBounds(const struct mach_header_64 *h, uintptr_t *lo, uintptr_t *hi) {
    uintptr_t a = (uintptr_t)h, end = (uintptr_t)h;
    const struct load_command *lc = (const struct load_command *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *s = (const struct segment_command_64 *)lc;
            if (s->vmsize && s->vmaddr + s->vmsize > end) end = s->vmaddr + s->vmsize;
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    *lo = a; *hi = end;
}

static void probeEngine(void) {
    const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!h) return;
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    gSlide = slide;

    imageBounds(h, &gImgBase, &gImgEnd);
    gProbeProj = (uintptr_t)((intptr_t)kSym_ProjectWorldLocationToScreen + slide);
    gProbePlat = (uintptr_t)((intptr_t)kSym_GetPlayerPlatform + slide);
    gProbeInRange = (gProbeProj >= gImgBase && gProbeProj < gImgEnd &&
                     gProbePlat >= gImgBase && gProbePlat < gImgEnd);

    NSLog(@"[EchoMod] engine probe: base=%p end=%p slide=%ld",
          (void *)gImgBase, (void *)gImgEnd, (long)slide);
    NSLog(@"[EchoMod]   ProjectWorldLocationToScreen=%p  GetPlayerPlatform=%p  inRange=%d",
          (void *)gProbeProj, (void *)gProbePlat, (int)gProbeInRange);
}

#pragma mark - 7) real player data -> 3D overhead labels (no hooks)

// Everything here is a *direct call* to an engine function plus *safe* memory reads
// (mach_vm_read_overwrite never faults on a bad address). No inline hooking, because iOS
// code-signing blocks patching __TEXT on a non-jailbroken app.
//
// Addresses/offsets recovered offline from the decrypted binary (see research/NOTES.md):
//
//   global 0x105817be8        GEngine/GWorld (UObject; vtable slot 0x148 == UObject::GetWorld)
//   native 0x101b3f8a8        GetGameState(WorldContext) -> AGameStateBase*
//   native 0x1016d9c60        GetPlayerController(WorldContext, index) -> APlayerController*
//   native 0x101d94a08        ProjectWorldLocationToScreen(this, FVector, FVector2D*, bool)
//   native 0x102d35e60        K2_GetActorLocation(this) -> FVector (3 floats)
//
//   UWorld::GameState             +0x148
//   AGameStateBase::PlayerArray   +0x330 (Data) / +0x338 (Num)   [TArray<APlayerState*>]
//   AController::Pawn             +0x348
//   AActor location (3 floats)    +0x190

#define A_GLOBAL_ENGINE        0x105817be8ULL
#define A_NATIVE_GETGAMESTATE  0x101b3f8a8ULL
#define A_NATIVE_GETPC         0x1016d9c60ULL
#define A_NATIVE_PWLS          0x101d94a08ULL

#define OFF_WORLD_GAMESTATE    0x148
#define OFF_GS_PLAYERARRAY     0x330
#define OFF_GS_PLAYERARRAY_NUM 0x338
#define OFF_CTRL_PAWN          0x348
#define OFF_ACTOR_LOCATION     0x190

typedef struct { float x, y, z; } FV3;
typedef struct { float x, y; }   FV2;

#define SYM(va) ((uintptr_t)((intptr_t)(va) + gSlide))

// --- safe memory access ----------------------------------------------------------------

static BOOL safe_read(uintptr_t addr, void *dst, size_t n) {
    if (addr < 0x100000000ULL) return NO;
    vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(),
                                              (mach_vm_address_t)addr, (mach_vm_size_t)n,
                                              (mach_vm_address_t)(uintptr_t)dst, &got);
    return (kr == KERN_SUCCESS && got == n);
}

static uintptr_t rd_ptr(uintptr_t addr) {
    uintptr_t v = 0;
    return safe_read(addr, &v, sizeof v) ? v : 0;
}

static int32_t rd_i32(uintptr_t addr) {
    int32_t v = 0;
    return safe_read(addr, &v, sizeof v) ? v : 0;
}

// A UE UObject's first word is its vtable, which lives inside the main image.
static BOOL looks_like_uobject(uintptr_t p) {
    if (p < 0x100000000ULL || (p & 0x7)) return NO;
    uintptr_t vt = rd_ptr(p);
    return (vt >= gImgBase && vt < gImgEnd);
}

static BOOL sane_vec(FV3 v) {
    return isfinite(v.x) && isfinite(v.y) && isfinite(v.z) &&
           fabsf(v.x) < 1.0e6f && fabsf(v.y) < 1.0e6f && fabsf(v.z) < 1.0e6f;
}

// --- resolved engine entry points ------------------------------------------------------

static void *(*gfn_GetGameState)(void *)            = NULL;   // (WorldContext)
static void *(*gfn_GetPlayerController)(void *, int32_t) = NULL; // (WorldContext, index)
static BOOL  (*gfn_PWLS)(void *, FV3, FV2 *, BOOL)  = NULL;   // (this, world, out, rel)

// --- diagnostics (shown in the top-right panel) ----------------------------------------
// (the globals are declared up top, next to gProbeInRange, because the panel reads them)

static void *gEngine   = NULL;
static void *gLocalPC  = NULL;
static void *gGameState = NULL;

// Resolve the entry points once. Safe: only computes addresses + one validated global read.
static void resolveEngine(void) {
    if (!gSlide) return;
    if (!gfn_GetGameState)       gfn_GetGameState       = (void *)SYM(A_NATIVE_GETGAMESTATE);
    if (!gfn_GetPlayerController) gfn_GetPlayerController = (void *)SYM(A_NATIVE_GETPC);
    if (!gfn_PWLS)               gfn_PWLS               = (void *)SYM(A_NATIVE_PWLS);

    uintptr_t eng = rd_ptr(SYM(A_GLOBAL_ENGINE));
    if (looks_like_uobject(eng)) {
        gEngine = (void *)eng;
        gDiagEngine = YES;
    }
}

// --- the real label source -------------------------------------------------------------

static EchoOverheadLabel *labelAtIndex(NSUInteger i) {
    if (!gLabels) return nil;
    while (gLabels.count <= i) {
        EchoOverheadLabel *L = [[EchoOverheadLabel alloc] init];
        UILabel *v = [[UILabel alloc] init];
        v.text            = @"platform";
        v.font            = [UIFont boldSystemFontOfSize:13.0];
        v.textColor       = [UIColor whiteColor];
        v.textAlignment   = NSTextAlignmentCenter;
        v.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        v.layer.cornerRadius = 4.0;
        v.clipsToBounds   = YES;
        L.view = v;
        L.text = @"platform";
        if (gLabelRoot) [gLabelRoot addSubview:v];
        [gLabels addObject:L];
    }
    return gLabels[i];
}

static void fillPlayerLabels(void) {
    if (!gLabels) return;
    resolveEngine();

    gDiagPC = NO; gDiagGameState = NO; gDiagPlayers = 0; gDiagDrawn = 0;

    if (!gEngine || !gfn_GetPlayerController || !gfn_GetGameState || !gfn_PWLS) {
        for (EchoOverheadLabel *L in gLabels) L.nx = -1.0;   // hide everything
        return;
    }

    // local player controller (drives the projection)
    if (!looks_like_uobject((uintptr_t)gLocalPC)) {
        void *pc = gfn_GetPlayerController(gEngine, 0);
        if (looks_like_uobject((uintptr_t)pc)) gLocalPC = pc;
    }
    if (!looks_like_uobject((uintptr_t)gLocalPC)) {
        for (EchoOverheadLabel *L in gLabels) L.nx = -1.0;
        return;
    }
    gDiagPC = YES;

    // game state -> PlayerArray (TArray<APlayerState*>)
    void *gs = gfn_GetGameState(gEngine);
    if (!looks_like_uobject((uintptr_t)gs)) gs = NULL;
    gGameState = gs;

    uintptr_t psData = 0;
    int32_t   psNum  = 0;
    if (gs) {
        gDiagGameState = YES;
        psData = rd_ptr((uintptr_t)gs + OFF_GS_PLAYERARRAY);
        psNum  = rd_i32((uintptr_t)gs + OFF_GS_PLAYERARRAY_NUM);
    }
    if (psNum < 0) psNum = 0;
    if (psNum > 64) psNum = 64;
    gDiagPlayers = psNum;

    CGSize sz = gLabelRoot ? gLabelRoot.bounds.size : CGSizeZero;
    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale <= 0.0) scale = 1.0;

    NSUInteger used = 0;
    for (int32_t i = 0; i < psNum; i++) {
        uintptr_t ps = rd_ptr(psData + (uintptr_t)i * 8);
        if (!looks_like_uobject(ps)) continue;

        uintptr_t pawn = rd_ptr(ps + OFF_CTRL_PAWN);
        if (!looks_like_uobject(pawn)) continue;

        FV3 loc = {0, 0, 0};
        if (!safe_read(pawn + OFF_ACTOR_LOCATION, &loc, sizeof loc)) continue;
        if (!sane_vec(loc)) continue;

        loc.z += 92.0f;   // aim just above the head

        FV2 out = {0, 0};
        BOOL ok = gfn_PWLS(gLocalPC, loc, &out, NO);
        if (!ok) continue;

        CGFloat nx = (out.x / scale) / (sz.width  > 0 ? sz.width  : 1.0);
        CGFloat ny = (out.y / scale) / (sz.height > 0 ? sz.height : 1.0);
        if (!pointOnScreen(nx, ny)) continue;

        EchoOverheadLabel *L = labelAtIndex(used);
        if (!L) break;
        L.text = @"platform";
        L.nx = nx;
        L.ny = ny;
        used++;
    }

    gDiagDrawn = (int)used;
    for (NSUInteger i = used; i < gLabels.count; i++) gLabels[i].nx = -1.0;  // hide the rest
}

#pragma mark - init

__attribute__((constructor)) static void EchoModInit(void) {
    NSLog(@"[EchoMod] dylib loaded — constructor ran");

    Class pi = objc_getClass("NSProcessInfo");
    if (pi) {
        exchange(pi, @selector(isLowPowerModeEnabled),
                 (IMP)hook_isLowPowerModeEnabled, (IMP *)&orig_isLowPowerModeEnabled);
        exchange(pi, @selector(thermalState),
                 (IMP)hook_thermalState, (IMP *)&orig_thermalState);
    }

    Class dl = objc_getClass("CADisplayLink");
    if (dl) {
        exchange(dl, @selector(setPreferredFramesPerSecond:),
                 (IMP)hook_setPreferredFPS, (IMP *)&orig_setPreferredFPS);
    }

    Class ml = objc_getClass("CAMetalLayer");
    if (ml) {
        exchange(ml, @selector(nextDrawable),
                 (IMP)hook_nextDrawable, (IMP *)&orig_nextDrawable);
    }

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // Force the engine to re-evaluate its power/thermal frame-rate lock.
            NSProcessInfo *p = [NSProcessInfo processInfo];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:NSProcessInfoThermalStateDidChangeNotification object:p];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:NSProcessInfoPowerStateDidChangeNotification object:p];
            installOverlay();
            installPlatformOverlay();
            installLabelLayer();
            probeEngine();
            showLoadedAlert(0);
        });
    }];
}
