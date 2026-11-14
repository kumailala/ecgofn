// NEWLIB.dylib — Fortnite iOS 43.10 (UE5) build: FPS unlock, ESP, aimbot. Everything is resolved at runtime.
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
#import <Metal/Metal.h>
#include <os/lock.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <strings.h>
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

// engine-data diagnostics (filled by the scanner, shown in the HUD panel)
static uintptr_t gImgBase = 0;
static uintptr_t gImgEnd  = 0;
static intptr_t  gSlide   = 0;
static BOOL gProbeInRange = NO;
static BOOL gDiagEngine, gDiagWorld, gDiagPC, gDiagGameState;
static int  gDiagPlayers, gDiagPawns, gDiagActors, gDiagDrawn, gDiagBones;
static BOOL gDiagAds, gDiagLock;
static int  gDiagCam = -1;
static NSString *gBoneDiag = @"bones: not tried";
static int gDiagBs = 0;
static NSString *gScreenDiagA = @"";
static NSString *gScreenDiagB = @"";
static void updateScreenDiag(void);
static int gDiagVis, gDiagTraces, gDiagBlocked;
static float gDiagLastT;
static int gDiagRet;
static BOOL gRetAlive;
static BOOL gOptSilent = NO, gOptSilentFlick = NO, gOptBulletTp = YES;
static BOOL gOptDmg = NO, gOptAutoWeapons = NO;
static float gOptDmgMul = 0.1f;
static BOOL gOptLoot = YES, gOptWeaponEsp = YES, gOptChest = YES;
static int gOptLootMin = 2;
static BOOL gSilHave = NO;
static float gSilPos[3];
static CFTimeInterval gSilTime = 0;
static int gSilState = 0, gSilCalls = 0, gSilApplied = 0, gSilIfs = 0, gSilArrs = 0;
static uintptr_t gHudCtx = 0, gHudCtxClass = 0;
static BOOL gFiring = NO;
static NSString *gResolveLine = @"resolve: pending";
static NSString *gResolveLine2 = @"";

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

static __weak id gCurDrawable = nil;
static id (*orig_nextDrawable)(id, SEL);
static id hook_nextDrawable(id self, SEL _cmd) {
    atomic_fetch_add(&gMetalFrames, 1);
    id d = orig_nextDrawable(self, _cmd);
    gCurDrawable = d;
    return d;
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

static void RLOG(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
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
        l.text         = @"";
        l.hidden       = YES;
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
            static int fpsTick = 0;
            if (++fpsTick % 30 == 0) RLOG(@"fps: %d%@", fps, gUseDisplay ? @" (disp)" : @"");
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
    static int platTick = 0;
    if (++platTick % 40 == 1) RLOG(@"status: %@", [s stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);
    gPlatLabel.text = @"";
    gPlatLabel.hidden = YES;
    return;

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
        setPlatLines(@[ @"sniga — made by kumailala", @"starting…" ]);

        // heartbeat: if "tick" keeps climbing, the overlay is live and updating.
        dispatch_source_t timer =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2),
                                  NSEC_PER_SEC / 2, 50ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            static int tick = 0;
            attachScene(gPlatOverlay); // self-heal if the scene connected after install
            updateScreenDiag();
            NSString *eng = gDiagEngine ? @"ok" : (gProbeInRange ? @"no-obj" : @"NO");
            setPlatLines(@[
                @"sniga — made by kumailala · tap E for menu",
                [NSString stringWithFormat:@"engine: %@  world: %@  pc: %@", eng, gDiagWorld ? @"Y" : @"n", gDiagPC ? @"Y" : @"n"],
                [NSString stringWithFormat:@"gs: %@  players: %d  pawns: %d  bones: %d", gDiagGameState ? @"Y" : @"n", gDiagPlayers, gDiagPawns, gDiagBones],
                gResolveLine,
                gResolveLine2,
                gScreenDiagA,
                gScreenDiagB,
                [NSString stringWithFormat:@"actors: %d  tick: %d", gDiagActors, ++tick],
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
            [UIAlertController alertControllerWithTitle:@"sniga"
                                                message:@"made by kumailala"
                                         preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
        NSLog(@"[EchoMod] loaded alert presented on %@", NSStringFromClass([top class]));
    });
}


#pragma mark - 5) engine layer (UE5 / Fortnite 43.10, everything resolved at runtime)

// The only address taken from the binary is GUObjectArray (found by following the
// "Max UObject count is invalid" string to FUObjectArray::AllocateObjectPool and the caller that
// passes the global). The name pool, every class, every property offset and the engine instance
// are discovered at runtime through the game's own reflection data and logged to
// Documents/EchoMod43_diag.txt, so a wrong guess shows up there instead of crashing.

#define A_GUOBJECTARRAY 0x1131d8780ULL
#define SYM(va) ((uintptr_t)((intptr_t)(va) + gSlide))

static BOOL  gOptBoxes = YES, gOptSkeleton = YES, gOptTags = YES;
static BOOL  gOptAimbot = YES, gOptAdsOnly = YES, gOptShowFov = YES;
static BOOL  gOptAimBody = NO;
static BOOL  gOptNoRecoil = NO, gOptNoSpread = NO, gOptTrigger = NO;
static float gOptTrigDelay = 0.15f;
static int   gTrigFires = 0, gTrigCand = 0, gTrigLos = 0;
static BOOL  gOptHudLayout = NO;
static BOOL  gOptLowGfx = NO;
static BOOL  gOptVisOnly = NO;
static BOOL  gOptAutoSprint = NO;
static BOOL  gOptPeek = NO;
static float gOptSmooth = 0.35f;
static float gOptFov = 0.30f;
static int   gOptDelay = 1;
static float gOptLagF = 1.0f;
static BOOL  gOptEngineDraw = YES;
static volatile CFTimeInterval gEngDrawLast = 0;
static void installEngineHook(void);
static _Atomic int gCapCount = 0;

typedef struct { double x, y, z; } DV3;
typedef struct { double q[4]; double t[3]; double tp; double s[3]; double sp; } DXf;

typedef kern_return_t (*MvReadFn)(vm_map_t, mach_vm_address_t, mach_vm_size_t,
                                  mach_vm_address_t, mach_vm_size_t *);
static MvReadFn gMvRead = NULL;

static BOOL safe_read(uintptr_t addr, void *dst, size_t n) {
    if (addr < 0x100000000ULL) return NO;
    if (!gMvRead) {
        gMvRead = (MvReadFn)dlsym(RTLD_DEFAULT, "mach_vm_read_overwrite");
        if (!gMvRead) return NO;
    }
    mach_vm_size_t got = 0;
    kern_return_t kr = gMvRead(mach_task_self(), (mach_vm_address_t)addr,
                               (mach_vm_size_t)n, (mach_vm_address_t)(uintptr_t)dst, &got);
    return (kr == KERN_SUCCESS && got == n);
}

static uintptr_t rd_ptr(uintptr_t a) { uintptr_t v = 0; return safe_read(a, &v, sizeof v) ? v : 0; }
static int32_t   rd_i32(uintptr_t a) { int32_t v = 0; return safe_read(a, &v, sizeof v) ? v : 0; }
static uint8_t   rd_u8(uintptr_t a)  { uint8_t v = 0; return safe_read(a, &v, sizeof v) ? v : 0; }
static float     rd_f32(uintptr_t a) { float v = 0; return safe_read(a, &v, sizeof v) ? v : 0; }
static double    rd_f64(uintptr_t a) { double v = 0; return safe_read(a, &v, sizeof v) ? v : 0; }

static void wr_bytes(uintptr_t addr, const void *src, size_t n) {
    uint8_t probe[32];
    if (n > sizeof probe || !safe_read(addr, probe, n)) return;
    memcpy((void *)addr, src, n);
}

static BOOL looks_like_uobject(uintptr_t p) {
    if (p < 0x100000000ULL || (p & 0x7)) return NO;
    uintptr_t vt = rd_ptr(p);
    return (vt >= gImgBase && vt < gImgEnd);
}

static BOOL sane_dv(DV3 v) {
    return isfinite(v.x) && isfinite(v.y) && isfinite(v.z) &&
           fabs(v.x) < 4.0e6 && fabs(v.y) < 4.0e6 && fabs(v.z) < 4.0e6;
}

static NSString *read_fstring(uintptr_t addr) {
    uintptr_t data = rd_ptr(addr);
    int32_t num = rd_i32(addr + 8);
    if (!data || num <= 1 || num > 48) return nil;
    unichar buf[48];
    if (!safe_read(data, buf, (size_t)(num - 1) * sizeof(unichar))) return nil;
    return [NSString stringWithCharacters:buf length:(NSUInteger)(num - 1)];
}

static DV3 qrot(const double *q, DV3 v) {
    double x = q[0], y = q[1], z = q[2], w = q[3];
    DV3 t = { 2.0 * (y * v.z - z * v.y), 2.0 * (z * v.x - x * v.z), 2.0 * (x * v.y - y * v.x) };
    DV3 r = { v.x + w * t.x + (y * t.z - z * t.y),
              v.y + w * t.y + (z * t.x - x * t.z),
              v.z + w * t.z + (x * t.y - y * t.x) };
    return r;
}

static BOOL looks_like_xform(const DXf *x) {
    double qq = x->q[0] * x->q[0] + x->q[1] * x->q[1] + x->q[2] * x->q[2] + x->q[3] * x->q[3];
    if (!(qq > 0.95 && qq < 1.05)) return NO;
    for (int i = 0; i < 3; i++) {
        if (!isfinite(x->t[i]) || fabs(x->t[i]) > 100000.0) return NO;
        if (!isfinite(x->s[i]) || fabs(x->s[i]) < 0.01 || fabs(x->s[i]) > 10.0) return NO;
    }
    return YES;
}

#pragma mark 5.1 resolver log

static NSMutableString *gRes = nil;
static void RLOG(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void RLOG(NSString *fmt, ...) {
    if (!gRes) gRes = [NSMutableString string];
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [gRes appendString:s];
    [gRes appendString:@"\n"];
    NSLog(@"[EchoMod43] %@", s);
}

static void flushResolveLog(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!dir || !gRes) return;
    [gRes writeToFile:[dir stringByAppendingPathComponent:@"EchoMod43_diag.txt"]
           atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark 5.2 FName pool

static uintptr_t gNameBlocks = 0;
static int gNameShift = 6;

static int gNameStride = 2, gNameTextOff = 2, gNameIdxAdd = 0;
static uintptr_t gNameBlobs = 0;
static intptr_t gNameBlobDelta = 0;
static uintptr_t gNameBlobAbs = 0;
static uintptr_t gNameBlobTab = 0;
static int32_t rd_i32(uintptr_t a);
static int32_t fnidx(uintptr_t a) { return rd_i32(a + (uintptr_t)gNameIdxAdd); }

static BOOL fname_read(int32_t idx, char *out, int cap) {
    if (!gNameBlocks || cap < 2) return NO;
    for (int hop = 0; hop < 3; hop++) {
        if (idx < 0) return NO;
        uintptr_t blk = rd_ptr(gNameBlocks + 8 * (uintptr_t)((uint32_t)idx >> 16));
        if (!blk) return NO;
        uintptr_t e = blk + (uintptr_t)gNameStride * (uintptr_t)((uint32_t)idx & 0xFFFF);
        uint16_t h = 0;
        if (!safe_read(e, &h, 2)) return NO;
        int len = (h >> gNameShift) & 0x3FF;
        if (len == 0) {
            int32_t alias = 0;
            if (!safe_read(e + 6, &alias, 4) || alias == idx) return NO;
            idx = alias;
            continue;
        }
        if (h & (gNameShift == 5 ? 0x8000 : 1)) return NO;
        if (len >= cap) len = cap - 1;
        if (gNameBlobTab || gNameBlobs || gNameBlobDelta || gNameBlobAbs) {
            uint16_t hi16 = 0, lo16 = 0;
            if (!safe_read(e + 2, &hi16, 2) || !safe_read(e + 4, &lo16, 2)) return NO;
            uintptr_t blob;
            if (gNameBlobTab) {
                if (hi16 >= 0x7000) return NO;
                uintptr_t st = rd_ptr(gNameBlobTab + 8 * (uintptr_t)hi16);
                uint64_t probe = 0;
                if (!st || !safe_read(st, &probe, 8)) return NO;
                char tmp[1100];
                ((void (*)(char *, const void *, uint32_t))SYM(0x1006d55a4ULL))(tmp, (const void *)(e + 2), (uint32_t)len);
                memcpy(out, tmp, (size_t)len);
                out[len] = 0;
                return YES;
            } else blob = gNameBlobAbs ? gNameBlobAbs
                                : (gNameBlobDelta ? (uintptr_t)((intptr_t)blk + gNameBlobDelta)
                                                  : rd_ptr(gNameBlobs + 8 * (uintptr_t)((uint32_t)idx >> 16)));
            if (!blob) return NO;
            if (!safe_read(blob + (((uintptr_t)hi16 << 16) | lo16), out, (size_t)len)) return NO;
            out[len] = 0;
            return YES;
        }
        if (!safe_read(e + (uintptr_t)gNameTextOff, out, (size_t)len)) return NO;
        out[len] = 0;
        return YES;
    }
    return NO;
}

static NSString *fname_string(int32_t idx) {
    char b[96];
    if (!fname_read(idx, b, sizeof b)) return nil;
    return [NSString stringWithUTF8String:b];
}

static BOOL name_is(int32_t idx, const char *want) {
    char b[96];
    return fname_read(idx, b, sizeof b) && strcmp(b, want) == 0;
}

static BOOL bytes_are_name(const uint8_t *b, int n) {
    for (int i = 0; i < n; i++) {
        uint8_t c = b[i];
        if (!(c == '_' || c == '/' || c == '.' || (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return NO;
    }
    return YES;
}

static BOOL poolCandidate(uintptr_t v) {
    uint8_t b[32];
    if (!safe_read(v, b, sizeof b)) return NO;
    uint16_t h; memcpy(&h, b, 2);
    int sh = ((h >> 6) == 4) ? 6 : (((h >> 1) == 4 || (h >> 1) == 4) ? 1 : 0);
    if (!sh) return NO;
    if (h & 1) return NO;
    if (memcmp(b + 2, "None", 4) != 0) return NO;
    uint16_t h2; memcpy(&h2, b + 6, 2);
    int l2 = h2 >> sh;
    if (l2 <= 0 || l2 > 20 || (h2 & 1) || 8 + l2 > 32) return NO;
    if (!bytes_are_name(b + 8, l2)) return NO;
    gNameShift = sh;
    return YES;
}

static BOOL scanForNamePool(uintptr_t lo, uintptr_t hi) {
    const size_t slab = 1 << 20;
    uint64_t *buf = (uint64_t *)malloc(slab);
    if (!buf) return NO;
    BOOL found = NO;
    for (uintptr_t a = lo; a < hi && !found; a += slab) {
        size_t n = hi - a < slab ? hi - a : slab;
        if (!safe_read(a, buf, n)) {
            size_t good = 0;
            for (size_t off = 0; off < n; off += 16384) {
                size_t m = n - off < 16384 ? n - off : 16384;
                if (!safe_read(a + off, (uint8_t *)buf + off, m)) memset((uint8_t *)buf + off, 0, m);
                else good += m;
            }
            if (!good) continue;
        }
        for (size_t i = 0; i + 1 <= n / 8; i++) {
            uint64_t v = buf[i];
            if (v < 0x100000000ULL || v > 0x0000FFFFFFFFFFFFULL || (v & 7)) continue;
            if (v >= gImgBase && v < gImgEnd) continue;
            if (poolCandidate((uintptr_t)v)) {
                uintptr_t slot = a + i * 8;
                uintptr_t b1 = rd_ptr(slot + 8);
                if (b1 != 0 && b1 < 0x100000000ULL) continue;
                gNameBlocks = slot;
                found = YES;
                break;
            }
        }
    }
    free(buf);
    return found;
}

static BOOL poolTestBlock(uintptr_t v, uintptr_t slotForBi0, const int32_t *idxs, int ni, int levelBi) {
    (void)levelBi;
    static const int strides[] = { 2, 4, 8 };
    for (int k = 0; k < ni; k++) {
        uint32_t bi = (uint32_t)idxs[k] >> 16;
        if (bi > 64) continue;
        for (int si = 0; si < 3; si++) {
            uint8_t b[24];
            if (!safe_read(v + (uintptr_t)strides[si] * (uintptr_t)((uint32_t)idxs[k] & 0xFFFF), b, sizeof b)) continue;
            for (int t = 2; t <= 12; t += 2) {
                if (memcmp(b + t, "Class", 5) != 0) continue;
                uint16_t h; memcpy(&h, b, 2);
                int sh = (((h >> 5) & 0x3FF) == 5 && !(h & 0x8000)) ? 5 : ((((h >> 6) & 0x3FF) == 5 && !(h & 1)) ? 6 : 0);
                if (!sh) continue;
                gNameShift = sh; gNameStride = strides[si]; gNameTextOff = t;
                gNameBlocks = slotForBi0 - 8 * (uintptr_t)bi;
                return YES;
            }
        }
    }
    return NO;
}

static BOOL poolByClassIn(uintptr_t lo, uintptr_t hi, const int32_t *idxs, int ni, BOOL indirect) {
    const size_t slab = 1 << 20;
    uint64_t *buf = (uint64_t *)malloc(slab);
    if (!buf) return NO;
    BOOL found = NO;
    for (uintptr_t a = lo; a < hi && !found; a += slab) {
        size_t n = hi - a < slab ? hi - a : slab;
        if (!safe_read(a, buf, n)) {
            size_t good = 0;
            for (size_t off = 0; off < n; off += 16384) {
                size_t m = n - off < 16384 ? n - off : 16384;
                if (!safe_read(a + off, (uint8_t *)buf + off, m)) memset((uint8_t *)buf + off, 0, m);
                else good += m;
            }
            if (!good) continue;
        }
        for (size_t i = 0; i < n / 8 && !found; i++) {
            uint64_t v = buf[i];
            if (v < 0x100000000ULL || v > 0x0000FFFFFFFFFFFFULL) continue;
            if (v >= gImgBase && v < gImgEnd) continue;
            if (!indirect) {
                if (poolTestBlock((uintptr_t)v, a + i * 8, idxs, ni, 0)) found = YES;
            } else {
                uint64_t w[24];
                if (!safe_read((uintptr_t)v, w, sizeof w)) continue;
                for (int j = 0; j < 24 && !found; j++) {
                    if (w[j] < 0x100000000ULL || w[j] > 0x0000FFFFFFFFFFFFULL || (w[j] >= gImgBase && w[j] < gImgEnd)) continue;
                    if (poolTestBlock((uintptr_t)w[j], (uintptr_t)v + (uintptr_t)j * 8, idxs, ni, 1)) found = YES;
                }
            }
        }
    }
    free(buf);
    return found;
}

#define A_NAMEPOOL_BLOCKS 0x11317f190ULL

static NSString *gPoolDiag = @"";

static BOOL findBlobSlot(uintptr_t lo, uintptr_t hi) {
    const size_t slab = 1 << 20;
    uint64_t *buf = (uint64_t *)malloc(slab);
    if (!buf) return NO;
    BOOL found = NO;
    for (uintptr_t a = lo; a < hi && !found; a += slab) {
        size_t n = hi - a < slab ? hi - a : slab;
        if (!safe_read(a, buf, n)) {
            size_t good = 0;
            for (size_t off = 0; off < n; off += 16384) {
                size_t m = n - off < 16384 ? n - off : 16384;
                if (!safe_read(a + off, (uint8_t *)buf + off, m)) memset((uint8_t *)buf + off, 0, m);
                else good += m;
            }
            if (!good) continue;
        }
        for (size_t i = 0; i < n / 8 && !found; i++) {
            uint64_t v = buf[i];
            if (v < 0x100000000ULL || v > 0x0000FFFFFFFFFFFFULL) continue;
            if (v >= gImgBase && v < gImgEnd) continue;
            char t[16];
            if (!safe_read((uintptr_t)v, t, 16)) continue;
            if (memcmp(t, "NoneByteProperty", 16) == 0) { gNameBlobs = a + i * 8; found = YES; }
        }
    }
    free(buf);
    return found;
}

static uintptr_t gBlobCands[24];
static int gBlobCandN = 0;
static BOOL gBlobScanned = NO;

typedef struct { uintptr_t a, n, d; } VmReg;
static int vmregCmp(const void *x, const void *y) {
    const VmReg *p = (const VmReg *)x, *q = (const VmReg *)y;
    return p->d < q->d ? -1 : (p->d > q->d ? 1 : 0);
}

static void findBlobByRegions(uintptr_t nearAddr) {
    gBlobScanned = YES;
    gBlobCandN = 0;
    const int maxRegs = 8192;
    VmReg *regs = (VmReg *)malloc(sizeof(VmReg) * (size_t)maxRegs);
    if (!regs) return;
    int nr = 0;
    vm_address_t addr = 0;
    for (int guard = 0; guard < 200000 && nr < maxRegs; guard++) {
        vm_size_t sz = 0;
        vm_region_basic_info_data_64_t bi;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &addr, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&bi, &cnt, &obj) != KERN_SUCCESS) break;
        uintptr_t a = (uintptr_t)addr, e = a + (uintptr_t)sz;
        addr += sz;
        if (!(bi.protection & VM_PROT_READ) || sz < 0x10000) continue;
        if (a >= gImgBase && e <= gImgEnd) continue;
        if (sz > 0x20000000) {
            vm_region_extended_info_data_t ex;
            mach_msg_type_number_t c2 = VM_REGION_EXTENDED_INFO_COUNT;
            vm_address_t a2 = (vm_address_t)a; vm_size_t s2 = 0; mach_port_t o2 = MACH_PORT_NULL;
            if (vm_region_64(mach_task_self(), &a2, &s2, VM_REGION_EXTENDED_INFO, (vm_region_info_t)&ex, &c2, &o2) == KERN_SUCCESS) {
                if ((uint64_t)ex.pages_resident * 16384ULL < (uint64_t)sz / 4) continue;
            } else continue;
        }
        regs[nr].a = a; regs[nr].n = (uintptr_t)sz;
        uintptr_t d = nearAddr >= a ? (nearAddr < e ? 0 : nearAddr - e) : a - nearAddr;
        regs[nr].d = d;
        nr++;
    }
    qsort(regs, (size_t)nr, sizeof(VmReg), vmregCmp);
    const size_t chunk = 0x400000;
    uint8_t *buf = (uint8_t *)malloc(chunk + 32);
    double t0 = CACurrentMediaTime();
    size_t scanned = 0;
    for (int i = 0; buf && i < nr && gBlobCandN < 20; i++) {
        if (CACurrentMediaTime() - t0 > 40.0 || scanned > 0x100000000ULL) break;
        for (uintptr_t off = 0; off < regs[i].n && gBlobCandN < 20; off += chunk) {
            size_t n = regs[i].n - off < chunk + 16 ? regs[i].n - off : chunk + 16;
            if (!safe_read(regs[i].a + off, buf, n)) {
                size_t good = 0;
                for (size_t o2 = 0; o2 < n; o2 += 0x4000) {
                    size_t m = n - o2 < 0x4000 ? n - o2 : 0x4000;
                    if (safe_read(regs[i].a + off + o2, buf + o2, m)) good += m; else memset(buf + o2, 0, m);
                }
                if (!good) continue;
            }
            scanned += n;
            const uint8_t *p = buf, *end = buf + n;
            while (p + 16 <= end) {
                const uint8_t *f = (const uint8_t *)memmem(p, (size_t)(end - p), "NoneByteProperty", 16);
                if (!f) break;
                gBlobCands[gBlobCandN++] = regs[i].a + off + (uintptr_t)(f - buf);
                if (gBlobCandN >= 20) break;
                p = f + 1;
            }
        }
    }
    RLOG(@"namepool: region scan %d regions, %zu MB, %d blob candidates, %.1fs", nr, scanned >> 20, gBlobCandN, CACurrentMediaTime() - t0);
    for (int i = 0; i < gBlobCandN && i < 6; i++) RLOG(@"namepool:  cand %d = %p", i, (void *)gBlobCands[i]);
    free(buf);
    free(regs);
}

static BOOL classNameOK(uintptr_t cc, int classOff) {
    for (int add = 0; add <= 4; add += 4) {
        for (int nk = 0x8; nk <= 0x30; nk += 8) {
            if (nk == classOff) continue;
            int32_t idx = rd_i32(cc + (uintptr_t)nk + (uintptr_t)add);
            if (idx <= 0) continue;
            if (name_is(idx, "Class")) {
                gNameIdxAdd = add;
                RLOG(@"namepool: static slot %p ok (Class name idx %x at obj+0x%x+%d)", (void *)gNameBlocks, idx, nk, add);
                return YES;
            }
        }
    }
    return NO;
}

static BOOL poolStatic(uintptr_t cc, int classOff) {
    uintptr_t saved = gNameBlocks;
    gNameBlocks = SYM(A_NAMEPOOL_BLOCKS);
    gNameShift = 5; gNameStride = 2; gNameTextOff = 2;
    if (!gNameBlobs) {
        uintptr_t pool = SYM(0x11317f0c0ULL);
        if (!findBlobSlot(pool, pool + 0x27000)) findBlobSlot(SYM(0x112d7f9c0ULL), SYM(0x113214000ULL));
        RLOG(@"namepool: text blob table slot %p (image+0x%lx), blob0 %p, entries blk0 %p", (void *)gNameBlobs, gNameBlobs ? (unsigned long)(gNameBlobs - gSlide) : 0UL, (void *)(gNameBlobs ? rd_ptr(gNameBlobs) : 0), (void *)rd_ptr(gNameBlocks));
    }
    gNameBlobTab = SYM(0x10ebfb318ULL);
    if (classNameOK(cc, classOff)) { RLOG(@"namepool: text blob table at %p ok", (void *)gNameBlobTab); return YES; }
    RLOG(@"namepool: blob table %p slot0 %p did not resolve Class", (void *)gNameBlobTab, (void *)rd_ptr(gNameBlobTab));
    gNameBlobTab = 0;
    if (classNameOK(cc, classOff)) return YES;
    if (!gNameBlobs && !gBlobScanned) findBlobByRegions(rd_ptr(gNameBlocks));
    for (int ci = 0; ci < gBlobCandN; ci++) {
        gNameBlobAbs = gBlobCands[ci];
        if (classNameOK(cc, classOff)) {
            RLOG(@"namepool: text blob = %p (image+0x%lx)", (void *)gNameBlobAbs, (unsigned long)(gNameBlobAbs - gSlide));
            return YES;
        }
    }
    gNameBlobAbs = 0;
    NSMutableString *dg = [NSMutableString string];
    for (int b = 0; b < 4; b++) {
        uintptr_t blk = rd_ptr(gNameBlocks + 8 * (uintptr_t)b);
        if (!blk) break;
        uint8_t *buf = (uint8_t *)malloc(131072);
        if (!buf) break;
        if (safe_read(blk, buf, 131072)) {
            if (b == 0) {
                [dg appendString:@"b0:"];
                for (int q = 0; q < 24; q++) [dg appendFormat:@"%02x", buf[q]];
                RLOG(@"namepool: block0 first bytes %@", dg);
            }
            int found = 0;
            for (int pos = 2; pos + 5 <= 131072 && found < 6; pos += 2) {
                if (memcmp(buf + pos, "Class", 5) != 0) continue;
                uint16_t h; memcpy(&h, buf + pos - 2, 2);
                if (((h >> 5) & 0x3FF) != 5) continue;
                uint32_t X = ((uint32_t)b << 16) | (uint32_t)((pos - 2) / 2);
                [dg appendFormat:@" C@%x", X];
                RLOG(@"namepool: 'Class' text entry at idx %x (block %d offset 0x%x)", X, b, pos - 2);
                found++;
                for (int add = 0; add <= 4; add += 4) {
                    for (int nk = 0x8; nk <= 0x30; nk += 8) {
                        if (nk == classOff) continue;
                        if ((uint32_t)rd_i32(cc + (uintptr_t)nk + (uintptr_t)add) == X) {
                            gNameIdxAdd = add;
                            free(buf);
                            RLOG(@"namepool: matched via scan, name idx at obj+0x%x+%d", nk, add);
                            return YES;
                        }
                    }
                }
            }
        }
        free(buf);
    }
    gPoolDiag = dg;
    gNameBlocks = saved;
    return NO;
}

static BOOL poolByClass(uintptr_t cc, int classOff) {
    if (poolStatic(cc, classOff)) return YES;
    int32_t idxs[8];
    int ni = 0;
    for (int nk = 0x8; nk <= 0x30 && ni < 8; nk += 8) {
        if (nk == classOff) continue;
        int32_t v = rd_i32(cc + (uintptr_t)nk);
        if (v > 0) idxs[ni++] = v;
    }
    if (!ni) return NO;
    return poolByClassIn(SYM(0x112d7f9c0ULL), SYM(0x113214000ULL), idxs, ni, NO);
}

static BOOL findNamePool(void) {
    if (gNameBlocks) return YES;
    if (scanForNamePool(SYM(0x112d7f9c0ULL), SYM(0x113214000ULL))) return YES;
    return scanForNamePool(SYM(0x10ebd3380ULL), SYM(0x112d7c850ULL));
}

#pragma mark 5.3 object array

static uintptr_t gOAChunks = 0;
static uintptr_t *gSnapObj = NULL, *gSnapCls = NULL;
static int32_t gSnapN = 0;

static int gOffClass = 0x8, gOffName = 0x10, gOffOuter = 0x18;

static uintptr_t decodeItem(const uint8_t *it) {
    uint64_t a; uint32_t b;
    memcpy(&a, it, 8); memcpy(&b, it + 0x10, 4);
    return (uintptr_t)(((a & 0x3fff00000000ULL) | b) << 3);
}

static BOOL resolveObjArray(void) {
    uintptr_t base = SYM(A_GUOBJECTARRAY);
    for (int off = 0x20; off <= 0xA0; off += 8) {
        uintptr_t p = rd_ptr(base + off);
        if (p < 0x100000000ULL) continue;
        uintptr_t c0 = rd_ptr(p);
        if (c0 < 0x100000000ULL) continue;
        int good = 0;
        uint8_t items[64 * 0x18];
        if (!safe_read(c0, items, sizeof items)) continue;
        for (int j = 0; j < 64; j++) {
            if (looks_like_uobject(decodeItem(items + j * 0x18))) good++;
        }
        if (good < 2) continue;
        gOAChunks = p;
        RLOG(@"objarray: base=%p chunks@+0x%x max=%d num=%d(+0x40) good=%d", (void *)base, off, rd_i32(base + 0x3C), rd_i32(base + 0x40), good);
        return YES;
    }
    RLOG(@"objarray: FAILED, dump +0x20..0xA0 (img %p..%p slide %lx):", (void *)gImgBase, (void *)gImgEnd, (long)gSlide);
    for (int off = 0x20; off <= 0xA0; off += 8) RLOG(@"  +0x%x = %p", off, (void *)rd_ptr(base + off));
    gResolveLine2 = [NSString stringWithFormat:@"base %p sl %lx img %p-%p v3c %d v40 %d v48 %p v50 %p", (void *)base, (long)gSlide, (void *)gImgBase, (void *)gImgEnd, rd_i32(base + 0x3C), rd_i32(base + 0x40), (void *)rd_ptr(base + 0x48), (void *)rd_ptr(base + 0x50)];
    uintptr_t p48 = rd_ptr(base + 0x48), c = p48 ? rd_ptr(p48) : 0, o0 = c ? rd_ptr(c) : 0;
    gResolveLine = [NSString stringWithFormat:@"resolve: OBJARRAY FAILED c0 %p o0 %p vt %p", (void *)c, (void *)o0, (void *)(o0 ? rd_ptr(o0) : 0)];
    return NO;
}

static BOOL snapshotObjects(void) {
    uintptr_t base = SYM(A_GUOBJECTARRAY);
    int32_t num = rd_i32(base + 0x40), max = rd_i32(base + 0x3C);
    int32_t lim = (num > 0 && num <= max) ? num : max;
    if (lim <= 0 || lim > 6000000) { RLOG(@"snapshot: bad count num=%d max=%d", num, max); return NO; }
    free(gSnapObj); free(gSnapCls);
    gSnapObj = (uintptr_t *)calloc((size_t)lim, sizeof(uintptr_t));
    gSnapCls = (uintptr_t *)calloc((size_t)lim, sizeof(uintptr_t));
    uint8_t *buf = (uint8_t *)malloc(65536 * 0x18);
    if (!gSnapObj || !gSnapCls || !buf) { free(buf); return NO; }
    for (int32_t c = 0; (int64_t)c * 65536 < lim; c++) {
        uintptr_t chunk = rd_ptr(gOAChunks + 8 * (uintptr_t)c);
        if (!chunk) continue;
        int32_t cnt = lim - c * 65536;
        if (cnt > 65536) cnt = 65536;
        if (!safe_read(chunk, buf, (size_t)cnt * 0x18)) continue;
        for (int32_t j = 0; j < cnt; j++) {
            uintptr_t o = decodeItem(buf + (size_t)j * 0x18);
            if (o >= 0x100000000ULL && !(o & 7)) gSnapObj[c * 65536 + j] = o;
        }
    }
    free(buf);
    gSnapN = lim;
    static const int clsCand[] = { 0x8, 0x10, 0x18, 0x20, 0x28 };
    BOOL layoutOk = NO;
    for (int pass = 0; pass < 2 && !layoutOk; pass++) {
        int32_t upto = pass == 0 ? (lim < 40000 ? lim : 40000) : lim;
        for (size_t k = 0; k < sizeof clsCand / sizeof clsCand[0] && !layoutOk; k++) {
            for (int32_t i = 0; i < upto; i++) {
                uintptr_t o = gSnapObj[i];
                if (o && looks_like_uobject(o) && rd_ptr(o + (uintptr_t)clsCand[k]) == o) {
                    gOffClass = clsCand[k]; layoutOk = YES;
                    RLOG(@"layout: UClass self-class found, ClassPrivate at obj+0x%x (index %d)", gOffClass, i);
                    break;
                }
            }
        }
    }
    if (!layoutOk) { RLOG(@"layout: no self-class object found"); gResolveLine = @"resolve: NO CLASS LAYOUT"; return NO; }
    uintptr_t cc = 0;
    for (int32_t i = 0; i < lim && !cc; i++) if (gSnapObj[i] && rd_ptr(gSnapObj[i] + (uintptr_t)gOffClass) == gSnapObj[i]) cc = gSnapObj[i];
    static const int nameCand[] = { 0x8, 0x10, 0x18, 0x20, 0x28, 0x30 };
    BOOL nameOk = NO;
    if (!gNameBlocks && !poolByClass(cc, gOffClass)) {
        RLOG(@"namepool: not found via Class entry; Class object %p dump:", (void *)cc);
        NSMutableString *d = [NSMutableString stringWithFormat:@"cc %p:", (void *)cc];
        for (int off = 0; off < 0x38; off += 8) { RLOG(@"  +0x%x = %p", off, (void *)rd_ptr(cc + (uintptr_t)off)); [d appendFormat:@" %lx", (unsigned long)rd_ptr(cc + (uintptr_t)off)]; }
        gResolveLine = @"resolve: NAMEPOOL FAILED";
        {
            uintptr_t blk0 = rd_ptr(SYM(A_NAMEPOOL_BLOCKS));
            int32_t i20 = rd_i32(cc + 0x20);
            uint8_t eb[16] = {0};
            safe_read(blk0 + 2 * (uintptr_t)(i20 & 0xFFFF), eb, sizeof eb);
            NSMutableString *x = [NSMutableString stringWithFormat:@"blk0 %p idx %x e:", (void *)blk0, i20];
            for (int q = 0; q < 16; q++) [x appendFormat:@"%02x", eb[q]];
            RLOG(@"namepool diag: %@ | %@", x, gPoolDiag);
            gResolveLine2 = [NSString stringWithFormat:@"%@ | %@ | cc20 %lx", x, gPoolDiag, (unsigned long)rd_ptr(cc + 0x20)];
        }
        return NO;
    }
    RLOG(@"namepool: Blocks[0] slot at %p (image+0x%lx) shift %d stride %d textoff %d", (void *)gNameBlocks, (unsigned long)(gNameBlocks - gSlide), gNameShift, gNameStride, gNameTextOff);
    for (size_t k = 0; k < sizeof nameCand / sizeof nameCand[0]; k++) {
        if (nameCand[k] == gOffClass) continue;
        if (name_is(fnidx(cc + (uintptr_t)nameCand[k]), "Class")) { gOffName = nameCand[k]; nameOk = YES; break; }
    }
    RLOG(@"layout: FName at obj+0x%x ok=%d", gOffName, (int)nameOk);
    if (!nameOk) {
        RLOG(@"layout: dump of Class object %p:", (void *)cc);
        for (int off = 0; off < 0x40; off += 8) RLOG(@"  +0x%x = %p", off, (void *)rd_ptr(cc + (uintptr_t)off));
        gResolveLine = @"resolve: NO NAME OFFSET";
        return NO;
    }
    for (size_t k = 0; k < sizeof nameCand / sizeof nameCand[0]; k++) {
        int nk = nameCand[k];
        if (nk == gOffClass || nk == gOffName) continue;
        uintptr_t out = rd_ptr(cc + (uintptr_t)nk);
        if (!looks_like_uobject(out)) continue;
        NSString *on = fname_string(fnidx(out + (uintptr_t)gOffName));
        if ([on hasPrefix:@"/Script/"]) { gOffOuter = nk; RLOG(@"layout: Outer at obj+0x%x (%@)", nk, on); break; }
    }
    int valid = 0;
    for (int32_t i = 0; i < lim; i++) {
        if (gSnapObj[i]) { gSnapCls[i] = rd_ptr(gSnapObj[i] + (uintptr_t)gOffClass); valid++; }
    }
    RLOG(@"snapshot: %d slots, %d objects", lim, valid);
    return valid > 1000;
}

#pragma mark 5.4 reflection

enum {
    C_CLASS, C_ACTOR, C_PAWN, C_CHARACTER, C_CONTROLLER, C_PC, C_PS, C_GSB, C_WORLD, C_GI,
    C_PLAYER, C_VIEWPORT, C_SCENE, C_CAPSULE, C_PCM, C_LEVEL, C_FPAWN, C_FPLAYERPAWN,
    C_FPS, C_FPSA, C_FPC, C_FPICKUP, C_FWEAPON, C_FENGINE, C_FITEMDEF, C_SKINNED, C_COUNT
};
static const char *kClsNames[C_COUNT] = {
    "Class", "Actor", "Pawn", "Character", "Controller", "PlayerController", "PlayerState", "GameStateBase",
    "World", "GameInstance", "Player", "GameViewportClient", "SceneComponent", "CapsuleComponent",
    "PlayerCameraManager", "Level", "FortPawn", "FortPlayerPawn", "FortPlayerState", "FortPlayerStateAthena",
    "FortPlayerController", "FortPickup", "FortWeapon", "FortEngine", "FortItemDefinition", "SkinnedMeshComponent"
};
static uintptr_t gCls[C_COUNT];

static int OFF_SUPER = -1, OFF_CHILD = -1, OFF_FNEXT = -1, OFF_FNAME = -1, OFF_POFF = 0x4C, gPropShift = 0;

static BOOL fieldNameIs(uintptr_t f, const char *want) {
    return name_is(fnidx(f + (uintptr_t)OFF_FNAME), want);
}

static uintptr_t findProp(uintptr_t cls, const char *prop, uintptr_t *ownerOut) {
    for (int depth = 0; depth < 24 && looks_like_uobject(cls); depth++) {
        uintptr_t f = rd_ptr(cls + (uintptr_t)OFF_CHILD);
        for (int n = 0; f && n < 4000; n++) {
            if (fieldNameIs(f, prop)) { if (ownerOut) *ownerOut = cls; return f; }
            f = rd_ptr(f + (uintptr_t)OFF_FNEXT);
        }
        cls = rd_ptr(cls + (uintptr_t)OFF_SUPER);
    }
    return 0;
}

static int propOff(uintptr_t cls, const char *prop) {
    uintptr_t f = findProp(cls, prop, NULL);
    if (!f) return -1;
    int32_t o = rd_i32(f + (uintptr_t)OFF_POFF);
    return (o >= 0 && o < 0x100000) ? o : -1;
}

static int propOffTry(const int *classIdx, int n, const char *prop) {
    for (int i = 0; i < n; i++) {
        if (!gCls[classIdx[i]]) continue;
        int o = propOff(gCls[classIdx[i]], prop);
        if (o >= 0) return o;
    }
    return -1;
}

static int structHop(uintptr_t cls, const char *outer, const char *inner) {
    uintptr_t f = findProp(cls, outer, NULL);
    if (!f) return -1;
    int32_t base = rd_i32(f + (uintptr_t)OFF_POFF);
    uintptr_t st = 0;
    const int stOff[] = { 0x78 + gPropShift, 0x80 + gPropShift, 0x78, 0x80, 0x70, 0x88 };
    for (size_t k = 0; k < sizeof stOff / sizeof stOff[0]; k++) {
        uintptr_t cand = rd_ptr(f + (uintptr_t)stOff[k]);
        if (!looks_like_uobject(cand)) continue;
        uintptr_t sc = rd_ptr(cand + (uintptr_t)gOffClass);
        if (looks_like_uobject(sc) && name_is(fnidx(sc + (uintptr_t)gOffName), "ScriptStruct")) { st = cand; break; }
    }
    if (!st || base < 0) return -1;
    int o = propOff(st, inner);
    return o < 0 ? -1 : base + o;
}

static void metalNote(NSString *s);
static BOOL boolMask(uintptr_t cls, const char *prop, int *off, uint8_t *mask) {
    uintptr_t f = findProp(cls, prop, NULL);
    if (!f) return NO;
    int32_t o = rd_i32(f + (uintptr_t)OFF_POFF);
    if (o < 0 || o > 0x100000) return NO;
    int infOff = -1; uint8_t infMask = 0;
    {
        uintptr_t owner = 0;
        findProp(cls, prop, &owner);
        if (owner) {
            int rank = 0, hits = 0;
            uintptr_t q = rd_ptr(owner + (uintptr_t)OFF_CHILD);
            for (int n = 0; q && n < 4000; n++) {
                int32_t qo = rd_i32(q + (uintptr_t)OFF_POFF);
                if (fieldNameIs(q, prop)) { hits = 1; break; }
                if (qo == o) rank++; else rank = 0;
                q = rd_ptr(q + (uintptr_t)OFF_FNEXT);
            }
            if (hits && rank < 8) { infOff = o; infMask = (uint8_t)(1u << rank); }
        }
    }
    int scanOff = -1; uint8_t scanMask = 0; int scanPos = -1;
    for (int pos = 0x60; pos <= 0xA0; pos++) {
        uint8_t b4[4];
        if (!safe_read(f + (uintptr_t)pos, b4, 4)) continue;
        if (b4[0] == 1 && b4[1] < 8 && b4[2] && !(b4[2] & (b4[2] - 1)) && b4[3] == b4[2]) {
            scanOff = o + b4[1]; scanMask = b4[2]; scanPos = pos; break;
        }
    }
    uint8_t dump[0x30];
    NSMutableString *hx = [NSMutableString string];
    if (safe_read(f + 0x60, dump, sizeof dump)) for (int i = 0; i < 0x30; i++) [hx appendFormat:@"%02x", dump[i]];
    metalNote([NSString stringWithFormat:@"bool %s: off 0x%x inferred 0x%x/0x%x scan %d/0x%x @0x%x raw+0x60 %@", prop, o, infOff, infMask, scanOff, scanMask, scanPos, hx]);
    BOOL preferScan = (strcmp(prop, "bIsDBNO") == 0);
    if (preferScan && scanOff >= 0) { *off = scanOff; *mask = scanMask; return YES; }
    if (infOff >= 0) { *off = infOff; *mask = infMask; return YES; }
    if (scanOff >= 0) { *off = scanOff; *mask = scanMask; return YES; }
    return NO;
}

static BOOL probeReflection(void) {
    uintptr_t fpp = gCls[C_FPLAYERPAWN] ? gCls[C_FPLAYERPAWN] : gCls[C_PAWN];
    uintptr_t actor = gCls[C_ACTOR];
    if (!fpp || !actor) { RLOG(@"reflect: missing Actor/FortPlayerPawn class"); return NO; }

    static const int sup[] = { 0x40, 0x38, 0x48, 0x30, 0x50, 0x58, 0x60, 0x28, 0x68, 0x70, 0x78, 0x80, 0x88, 0x90 };
    for (size_t k = 0; k < sizeof sup / sizeof sup[0] && OFF_SUPER < 0; k++) {
        uintptr_t c = fpp;
        for (int d = 0; d < 24 && looks_like_uobject(c); d++) {
            if (name_is(fnidx(c + (uintptr_t)gOffName), "Object")) { OFF_SUPER = sup[k]; break; }
            c = rd_ptr(c + (uintptr_t)sup[k]);
        }
    }
    RLOG(@"reflect: SuperStruct +0x%x", OFF_SUPER);
    if (OFF_SUPER < 0) return NO;

    static const int co[] = { 0x50, 0x48, 0x58, 0x60, 0x68, 0x70, 0x40, 0x78, 0x80, 0x88, 0x90, 0x38, 0x30, 0x28 };
    static const int nx[] = { 0x20, 0x18, 0x28, 0x30, 0x38, 0x40, 0x10, 0x08 };
    static const int nm[] = { 0x28, 0x20, 0x30, 0x18, 0x38, 0x40, 0x10, 0x08 };
    int bestScore = 0;
    for (size_t a = 0; a < sizeof co / sizeof co[0]; a++)
    for (size_t b = 0; b < sizeof nx / sizeof nx[0]; b++)
    for (size_t c = 0; c < sizeof nm / sizeof nm[0]; c++) {
        uintptr_t f = rd_ptr(actor + (uintptr_t)co[a]);
        int score = 0;
        BOOL root = NO;
        for (int n = 0; f && n < 600; n++) {
            if (f < 0x100000000ULL || (f & 7)) break;
            char nameb[96];
            if (fname_read(fnidx(f + (uintptr_t)nm[c]), nameb, sizeof nameb)) {
                score++;
                if (!strcmp(nameb, "RootComponent")) root = YES;
            } else break;
            f = rd_ptr(f + (uintptr_t)nx[b]);
        }
        if (root) score += 1000;
        if (score > bestScore) { bestScore = score; OFF_CHILD = co[a]; OFF_FNEXT = nx[b]; OFF_FNAME = nm[c]; }
    }
    RLOG(@"reflect: ChildProperties +0x%x Next +0x%x Name +0x%x score %d", OFF_CHILD, OFF_FNEXT, OFF_FNAME, bestScore);
    if (bestScore < 1000) {
        for (int off = 0x28; off <= 0x90; off += 8) RLOG(@"reflect: Actor +0x%x = %p", off, (void *)rd_ptr(actor + (uintptr_t)off));
        uintptr_t f0 = rd_ptr(actor + 0x50);
        if (f0 >= 0x100000000ULL) for (int off = 0; off <= 0x50; off += 8) RLOG(@"reflect: Actor.child0 +0x%x = %p", off, (void *)rd_ptr(f0 + (uintptr_t)off));
        return NO;
    }

    int bestIo = 0x4C, bestOk = -1;
    int32_t psz = 0;
    for (int po = 0x40; po <= 0x90; po += 4) {
        int32_t v = rd_i32(actor + (uintptr_t)po);
        if (v >= 0x200 && v <= 0x4000 && !(v & 7)) { psz = v; break; }
    }
    for (int io = 0x38; io <= 0x70; io += 4) {
        uintptr_t f = rd_ptr(actor + (uintptr_t)OFF_CHILD);
        int okUp = 0, okDown = 0, total = 0, changes = 0;
        int32_t prevUp = -1, prevDown = 0x7fffffff, last = -1;
        for (int n = 0; f && n < 300; n++) {
            int32_t o = rd_i32(f + (uintptr_t)io);
            total++;
            BOOL inr = o >= 0 && o < 0x100000 && (psz <= 0 || o < psz);
            if (inr && o >= prevUp) { okUp++; prevUp = o; }
            if (inr && o <= prevDown) { okDown++; prevDown = o; }
            if (o != last) changes++;
            last = o;
            f = rd_ptr(f + (uintptr_t)OFF_FNEXT);
        }
        int ok = okUp > okDown ? okUp : okDown;
        int score = (total && changes >= 8) ? (ok * 100 / total) * 1000 + (io == 0x4C ? 500 : 0) + changes : 0;
        if (score > bestOk) { bestOk = score; bestIo = io; }
    }
    OFF_POFF = bestIo;
    gPropShift = OFF_POFF - 0x4C;
    RLOG(@"reflect: Offset_Internal +0x%x (score=%d, Actor PropertiesSize=0x%x)", OFF_POFF, bestOk, psz);
    return YES;
}

// resolved property offsets
static int O_ENGINE_VIEWPORT = -1, O_VIEWPORT_WORLD = -1, O_WORLD_GAMESTATE = -1, O_WORLD_LEVEL = -1, O_WORLD_GI = -1;
static int O_GI_LOCALPLAYERS = -1, O_PLAYER_PC = -1, O_PC_ACKPAWN = -1, O_PC_CAMMGR = -1, O_CTRL_ROT = -1;
static int O_CTRL_PS = -1, O_PAWN_PS = -1, O_GS_PLAYERS = -1, O_PS_PAWN = -1, O_PS_NAME = -1, O_PS_TEAM = -1, O_PS_PLATFORM = -1;
static int O_ACTOR_ROOT = -1, O_SCENE_RELLOC = -1, O_CAPSULE_HH = -1, O_CHAR_MESH = -1, O_CHAR_CAPSULE = -1;
static int O_CAMCACHE = -1, O_FPAWN_WEAPON = -1, O_WEAPON_DATA = -1, O_ITEM_RARITY = -1, O_PICKUP_DEF = -1, O_SKIN_ASSET = -1;
static int O_DYING = -1, O_DBNO = -1, O_ADS = -1;
static uint8_t M_DYING = 1, M_DBNO = 1, M_ADS = 1;

static uintptr_t gEngineObj = 0;

static void dumpSdk(uintptr_t classClass) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!dir) return;
    NSString *path = [dir stringByAppendingPathComponent:@"EchoMod43_sdk.txt"];
    FILE *f = fopen(path.UTF8String, "w");
    if (!f) return;
    uintptr_t scriptStruct = 0;
    for (int32_t i = 0; i < gSnapN && !scriptStruct; i++) {
        if (gSnapObj[i] && gSnapCls[i] == classClass && name_is(fnidx(gSnapObj[i] + (uintptr_t)gOffName), "ScriptStruct")) scriptStruct = gSnapObj[i];
    }
    fprintf(f, "# Fortnite 43.10 SDK dump by EchoMod43\n# image slide %lx, GUObjectArray image+0x%llx\n# offsets: ClassPrivate obj+0x%x Name obj+0x%x Outer obj+0x%x; SuperStruct +0x%x ChildProperties +0x%x FField Next +0x%x Name +0x%x; Offset_Internal +0x%x\n\n",
            (long)gSlide, (unsigned long long)A_GUOBJECTARRAY, gOffClass, gOffName, gOffOuter, OFF_SUPER, OFF_CHILD, OFF_FNEXT, OFF_FNAME, OFF_POFF);
    int structs = 0, props = 0;
    for (int32_t i = 0; i < gSnapN; i++) {
        uintptr_t o = gSnapObj[i];
        if (!o) continue;
        BOOL isClass = gSnapCls[i] == classClass;
        BOOL isStruct = scriptStruct && gSnapCls[i] == scriptStruct;
        if (!isClass && !isStruct) continue;
        char nm[160], sup[160], pk[160];
        if (!fname_read(fnidx(o + (uintptr_t)gOffName), nm, sizeof nm)) continue;
        sup[0] = 0; pk[0] = 0;
        uintptr_t su = rd_ptr(o + (uintptr_t)OFF_SUPER);
        if (looks_like_uobject(su)) fname_read(fnidx(su + (uintptr_t)gOffName), sup, sizeof sup);
        uintptr_t ou = rd_ptr(o + (uintptr_t)gOffOuter);
        if (looks_like_uobject(ou)) fname_read(fnidx(ou + (uintptr_t)gOffName), pk, sizeof pk);
        fprintf(f, "%s %s%s%s : %s // size 0x%x obj %lx\n", isClass ? "class" : "struct", pk, pk[0] ? "." : "", nm, sup[0] ? sup : "-",
                rd_i32(o + (uintptr_t)OFF_CHILD + 8), (unsigned long)(o - gSlide));
        structs++;
        uintptr_t p = rd_ptr(o + (uintptr_t)OFF_CHILD);
        for (int n = 0; p && n < 3000; n++) {
            char pn[160], tn[96];
            if (!fname_read(fnidx(p + (uintptr_t)OFF_FNAME), pn, sizeof pn)) break;
            tn[0] = 0;
            uintptr_t fc = rd_ptr(p + 0x8);
            if (fc >= 0x100000000ULL) fname_read(fnidx(fc), tn, sizeof tn);
            fprintf(f, "  +0x%04x %-28s %s[%d] size %d\n", rd_i32(p + (uintptr_t)OFF_POFF), pn, tn[0] ? tn : "?", rd_i32(p + (uintptr_t)(0x38 + gPropShift)), rd_i32(p + (uintptr_t)(0x3C + gPropShift)));
            props++;
            p = rd_ptr(p + (uintptr_t)OFF_FNEXT);
        }
        fprintf(f, "\n");
    }
    fprintf(f, "# %d structs/classes, %d properties\n", structs, props);
    fclose(f);
    RLOG(@"sdk dump: %d structs, %d properties -> EchoMod43_sdk.txt", structs, props);
}

static BOOL resolveAll(void) {
    if (!gSlide || !gImgBase) return NO;
    gResolveLine = @"resolve: objarray…";
    if (!resolveObjArray()) { flushResolveLog(); return NO; }
    gResolveLine = @"resolve: name pool…";
    gResolveLine = @"resolve: snapshot…";
    if (!snapshotObjects()) { if ([gResolveLine isEqualToString:@"resolve: snapshot…"]) gResolveLine = @"resolve: SNAPSHOT FAILED"; flushResolveLog(); return NO; }

    for (int i = 0, shown = 0; i < gSnapN && shown < 6; i++) {
        if (!gSnapObj[i]) continue;
        RLOG(@"  obj[%d]=%p class=%p name=%@", i, (void *)gSnapObj[i], (void *)gSnapCls[i], fname_string(fnidx(gSnapObj[i] + (uintptr_t)gOffName)) ?: @"?");
        shown++;
    }

    uintptr_t classClass = 0;
    for (int32_t i = 0; i < gSnapN; i++) {
        if (gSnapObj[i] && gSnapCls[i] == gSnapObj[i]) { classClass = gSnapObj[i]; break; }
    }
    RLOG(@"classclass: %p name=%@", (void *)classClass, classClass ? fname_string(fnidx(classClass + (uintptr_t)gOffName)) : @"-");
    if (!classClass) { gResolveLine = @"resolve: no UClass"; flushResolveLog(); return NO; }

    gCls[C_CLASS] = classClass;
    for (int32_t i = 0; i < gSnapN; i++) {
        if (!gSnapObj[i] || gSnapCls[i] != classClass) continue;
        char nb[96];
        if (!fname_read(fnidx(gSnapObj[i] + (uintptr_t)gOffName), nb, sizeof nb)) continue;
        for (int c = 1; c < C_COUNT; c++) {
            if (!gCls[c] && !strcasecmp(nb, kClsNames[c])) gCls[c] = gSnapObj[i];
        }
    }
    int missing = 0;
    for (int c = 0; c < C_COUNT; c++) {
        if (!gCls[c]) { RLOG(@"class MISSING: %s", kClsNames[c]); missing++; }
    }
    RLOG(@"classes: %d/%d found", C_COUNT - missing, C_COUNT);

    gResolveLine = @"resolve: reflection…";
    if (!probeReflection()) { gResolveLine = @"resolve: REFLECTION FAILED"; flushResolveLog(); return NO; }

    #define P(var, cls, name) do { var = propOff(gCls[cls], name); RLOG(@"  %-18s %-22s -> %d (0x%x)", kClsNames[cls], name, var, var < 0 ? 0 : var); } while (0)
    P(O_ENGINE_VIEWPORT, C_FENGINE, "GameViewport");
    P(O_VIEWPORT_WORLD, C_VIEWPORT, "World");
    P(O_WORLD_GAMESTATE, C_WORLD, "GameState");
    P(O_WORLD_LEVEL, C_WORLD, "PersistentLevel");
    P(O_WORLD_GI, C_WORLD, "OwningGameInstance");
    P(O_GI_LOCALPLAYERS, C_GI, "LocalPlayers");
    P(O_PLAYER_PC, C_PLAYER, "PlayerController");
    P(O_PC_ACKPAWN, C_PC, "AcknowledgedPawn");
    P(O_PC_CAMMGR, C_PC, "PlayerCameraManager");
    P(O_CTRL_ROT, C_CONTROLLER, "ControlRotation");
    P(O_CTRL_PS, C_CONTROLLER, "PlayerState");
    P(O_PAWN_PS, C_PAWN, "PlayerState");
    P(O_GS_PLAYERS, C_GSB, "PlayerArray");
    P(O_PS_PAWN, C_PS, "PawnPrivate");
    P(O_PS_NAME, C_PS, "PlayerNamePrivate");
    P(O_PS_TEAM, C_FPSA, "TeamIndex");
    P(O_PS_PLATFORM, C_FPS, "Platform");
    P(O_ACTOR_ROOT, C_ACTOR, "RootComponent");
    P(O_SCENE_RELLOC, C_SCENE, "RelativeLocation");
    P(O_CAPSULE_HH, C_CAPSULE, "CapsuleHalfHeight");
    P(O_CHAR_MESH, C_CHARACTER, "Mesh");
    P(O_CHAR_CAPSULE, C_CHARACTER, "CapsuleComponent");
    P(O_CAMCACHE, C_PCM, "CameraCachePrivate");
    P(O_FPAWN_WEAPON, C_FPAWN, "CurrentWeapon");
    P(O_WEAPON_DATA, C_FWEAPON, "WeaponData");
    P(O_ITEM_RARITY, C_FITEMDEF, "Rarity");
    P(O_SKIN_ASSET, C_SKINNED, "SkinnedAsset");
    O_PICKUP_DEF = structHop(gCls[C_FPICKUP], "PrimaryPickupItemEntry", "ItemDefinition");
    RLOG(@"  FortPickup PrimaryPickupItemEntry.ItemDefinition -> %d", O_PICKUP_DEF);
    BOOL b1 = boolMask(gCls[C_FPAWN], "bIsDying", &O_DYING, &M_DYING);
    BOOL b2 = boolMask(gCls[C_FPAWN], "bIsDBNO", &O_DBNO, &M_DBNO);
    BOOL b3 = boolMask(gCls[C_FPLAYERPAWN], "bIsTargeting", &O_ADS, &M_ADS);
    if (!b1) O_DYING = -1;
    if (!b2) O_DBNO = -1;
    if (!b3) O_ADS = -1;
    RLOG(@"  bools: dying=%d/0x%x dbno=%d/0x%x ads=%d/0x%x", O_DYING, M_DYING, O_DBNO, M_DBNO, O_ADS, M_ADS);
    #undef P

    static BOOL dumped = NO;
    if (!dumped) { dumped = YES; dumpSdk(classClass); }

    gEngineObj = 0;
    for (int32_t i = 0; i < gSnapN; i++) {
        if (!gSnapObj[i] || gSnapCls[i] != gCls[C_FENGINE]) continue;
        NSString *n = fname_string(fnidx(gSnapObj[i] + (uintptr_t)gOffName));
        if (n && ![n hasPrefix:@"Default__"]) { gEngineObj = gSnapObj[i]; break; }
    }
    RLOG(@"engine instance: %p", (void *)gEngineObj);

    free(gSnapObj); free(gSnapCls); gSnapObj = gSnapCls = NULL; gSnapN = 0;
    BOOL ok = gEngineObj && O_ENGINE_VIEWPORT >= 0 && O_VIEWPORT_WORLD >= 0 && O_WORLD_GI >= 0 &&
              O_GI_LOCALPLAYERS >= 0 && O_PLAYER_PC >= 0 && O_GS_PLAYERS >= 0 && O_PS_PAWN >= 0 && O_ACTOR_ROOT >= 0;
    gResolveLine = ok ? @"resolve: OK" : @"resolve: INCOMPLETE (see EchoMod43_diag.txt)";
    flushResolveLog();
    return ok;
}

#pragma mark 5.5 pawn data

static const char *kBoneNames[24] = {
    "head", "neck_01", "spine_05", "spine_04", "spine_03", "spine_02", "spine_01", "pelvis",
    "clavicle_l", "upperarm_l", "lowerarm_l", "hand_l",
    "clavicle_r", "upperarm_r", "lowerarm_r", "hand_r",
    "thigh_l", "calf_l", "foot_l",
    "thigh_r", "calf_r", "foot_r", NULL, NULL
};
#define kMaxSel 24
#define kMaxBones 1600

@interface EchoBoneMap : NSObject {
@public
    int n; int idx[kMaxSel]; int link[kMaxSel];
    int head, neck, pelvis, boneCount; int *parent;
    int rIdx[16];
}
@end
@implementation EchoBoneMap
@end

@interface EchoPawn : NSObject
@property (nonatomic, assign) uintptr_t pawn;
@property (nonatomic, assign) BOOL team;
@property (nonatomic, copy)   NSString *tag;
@property (nonatomic, strong) EchoBoneMap *bones;
@property (nonatomic, copy)   NSString *weapon;
@property (nonatomic, assign) int wTier;
@end
@implementation EchoPawn
@end

@interface EchoLoot : NSObject
@property (nonatomic, assign) double x, y, z;
@property (nonatomic, copy)   NSString *text;
@property (nonatomic, assign) int tier;
@end
@implementation EchoLoot
@end

static NSArray<EchoLoot *> *gLoot = nil;
static NSArray<EchoPawn *> *gPawns = nil;
static uintptr_t gLocalPC = 0, gLocalPawn = 0, gEngine = 0;
static NSMutableDictionary<NSNumber *, EchoBoneMap *> *gBoneCache = nil;
static DXf gLocalBones[kMaxBones];

static UIColor *tierColor(int t) {
    switch (t) {
        case 1: return [UIColor colorWithWhite:0.75 alpha:1];
        case 2: return [UIColor colorWithRed:0.3 green:0.9 blue:0.3 alpha:1];
        case 3: return [UIColor colorWithRed:0.35 green:0.6 blue:1.0 alpha:1];
        case 4: return [UIColor colorWithRed:0.75 green:0.4 blue:1.0 alpha:1];
        case 5: return [UIColor colorWithRed:1.0 green:0.6 blue:0.1 alpha:1];
        case 6: return [UIColor colorWithRed:1.0 green:0.85 blue:0.2 alpha:1];
        default: return [UIColor whiteColor];
    }
}

static NSString *cleanItemName(NSString *raw) {
    if (!raw.length) return @"";
    static NSSet *drop = nil;
    if (!drop) drop = [NSSet setWithArray:@[ @"WID", @"Athena", @"Ore", @"C", @"UC", @"R", @"VR", @"SR", @"UR", @"Harvest", @"Standard", @"Default", @"Consumable", @"AGID", @"Ammo", @"Primary", @"Pickup" ]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *t in [raw componentsSeparatedByString:@"_"]) {
        if (!t.length || [drop containsObject:t]) continue;
        if (t.length == 3 && [t hasPrefix:@"T"] && isdigit([t characterAtIndex:1])) continue;
        [out addObject:t];
    }
    return out.count ? [out componentsJoinedByString:@" "] : raw;
}

static void publishPawns(NSArray<EchoPawn *> *list, uintptr_t pc, uintptr_t localPawn) {
    @synchronized ([NSProcessInfo processInfo]) { gPawns = list; gLocalPC = pc; gLocalPawn = localPawn; }
}

static int gRefBonesOff = -1;

static void metalNote(NSString *s);
static int gRefStride = 0;
static int gRefParentOff = 8;
static int gBmFail[4];

static BOOL refBonesAt(uintptr_t asset, int off, uintptr_t *data, int32_t *n) {
    uintptr_t a = rd_ptr(asset + (uintptr_t)off);
    int32_t c = rd_i32(asset + (uintptr_t)off + 8), m = rd_i32(asset + (uintptr_t)off + 12);
    if (a < 0x100000000ULL || (a & 3) || c < 20 || c > kMaxBones || m < c || m > c * 4 + 64) return NO;
    static const int strides[] = { 8, 12, 16, 20, 24, 28, 32, 36, 40 };
    for (int si = 0; si < 9; si++) {
        int st = gRefStride ? gRefStride : strides[si];
        uint8_t raw[40 * 16];
        if (safe_read(a, raw, (size_t)st * 16)) {
            BOOL good = YES;
            for (int i = 0; i < 16 && good; i++) {
                int32_t nm, par;
                memcpy(&nm, raw + (size_t)i * (size_t)st, 4);
                memcpy(&par, raw + (size_t)i * (size_t)st + (size_t)(st == 8 ? 4 : 8), 4);
                if (i == 0 && par != -1) good = NO;
                else if (i > 0 && (par < 0 || par >= i)) good = NO;
                else if (!fname_string(nm)) good = NO;
            }
            if (good) {
                if (!gRefStride) metalNote([NSString stringWithFormat:@"bones: reference skeleton at asset+0x%x, %d bones, entry stride %d", off, c, st]);
                gRefStride = st;
                gRefParentOff = (st == 8 ? 4 : 8);
                *data = a; *n = c;
                return YES;
            }
        }
        if (gRefStride) break;
    }
    return NO;
}

static void bonesDiag(uintptr_t asset) {
    static int logged = 0;
    if (logged >= 2) return;
    logged++;
    NSMutableString *m = [NSMutableString stringWithFormat:@"bones: no reference skeleton found in asset %p (class %@)", (void *)asset, fname_string(fnidx(rd_ptr(asset + (uintptr_t)gOffClass) + (uintptr_t)gOffName)) ?: @"?"];
    int shown = 0;
    for (int off = 0x30; off < 0x600 && shown < 8; off += 8) {
        uintptr_t a = rd_ptr(asset + (uintptr_t)off);
        int32_t c = rd_i32(asset + (uintptr_t)off + 8), mx = rd_i32(asset + (uintptr_t)off + 12);
        if (a < 0x100000000ULL || c < 8 || c > 5000 || mx < c) continue;
        uint8_t raw[48];
        if (!safe_read(a, raw, sizeof raw)) continue;
        NSMutableString *h = [NSMutableString string];
        for (int i = 0; i < 48; i++) [h appendFormat:@"%02x", raw[i]];
        [m appendFormat:@"\n  +0x%x count %d max %d data %@", off, c, mx, h];
        shown++;
    }
    metalNote(m);
}

static EchoBoneMap *buildBoneMap(uintptr_t mesh) {
    if (O_SKIN_ASSET < 0) return nil;
    uintptr_t asset = rd_ptr(mesh + (uintptr_t)O_SKIN_ASSET);
    if (!looks_like_uobject(asset)) return nil;
    NSNumber *key = @(asset);
    EchoBoneMap *cached = gBoneCache[key];
    if (cached) return (cached->n > 0 || cached->rIdx[0] >= 0) ? cached : nil;

    uintptr_t refData = 0; int32_t N = 0;
    BOOL ok = NO;
    if (gRefBonesOff >= 0) ok = refBonesAt(asset, gRefBonesOff, &refData, &N);
    if (!ok) {
        int bestOff = -1, bestN = 0;
        uintptr_t bestData = 0;
        for (int off = 0x30; off < 0x600; off += 8) {
            uintptr_t d = 0; int32_t cn = 0;
            if (refBonesAt(asset, off, &d, &cn) && cn > bestN) { bestN = cn; bestOff = off; bestData = d; }
        }
        if (bestOff >= 0) {
            ok = YES; refData = bestData; N = bestN; gRefBonesOff = bestOff;
            metalNote([NSString stringWithFormat:@"bones: using skeleton array at asset+0x%x with %d bones", bestOff, bestN]);
        }
    }
    if (!ok) { gBmFail[0]++; bonesDiag(asset); }
    EchoBoneMap *m = [[EchoBoneMap alloc] init];
    m->n = 0; m->head = -1; m->neck = -1; m->pelvis = -1; m->boneCount = N; m->parent = NULL;
    for (int k = 0; k < 16; k++) m->rIdx[k] = -1;
    if (ok) {
        int32_t *info = (int32_t *)calloc((size_t)N * 4, sizeof(int32_t));
        uint8_t *rawb = (uint8_t *)malloc((size_t)N * (size_t)(gRefStride ? gRefStride : 16));
        BOOL rd = NO;
        if (info && rawb && gRefStride && safe_read(refData, rawb, (size_t)N * (size_t)gRefStride)) {
            for (int q = 0; q < N; q++) {
                memcpy(&info[q * 4], rawb + (size_t)q * (size_t)gRefStride, 4);
                memcpy(&info[q * 4 + 2], rawb + (size_t)q * (size_t)gRefStride + (size_t)gRefParentOff, 4);
            }
            rd = YES;
        }
        free(rawb);
        if (rd) {
            int selBone[kMaxSel];
            int rFallL = -1, rFallR = -1;
            for (int k = 0; k < kMaxSel; k++) selBone[k] = -1;
            for (int i = 0; i < N; i++) {
                NSString *nm = fname_string(info[i * 4]);
                if (!nm) continue;
                const char *lower = nm.lowercaseString.UTF8String;
                for (int k = 0; k < kMaxSel; k++)
                    if (kBoneNames[k] && selBone[k] < 0 && strcmp(lower, kBoneNames[k]) == 0) { selBone[k] = i; break; }
                static const char *kRaax[15] = { "head", "neck_01", "pelvis", "upperarm_l", "lowerarm_l", "hand_l", "upperarm_r", "lowerarm_r", "hand_r", "thigh_l", "calf_l", "ik_foot_l", "thigh_r", "calf_r", "ik_foot_r" };
                for (int k = 0; k < 15; k++)
                    if (m->rIdx[k] < 0 && strcmp(lower, kRaax[k]) == 0) { m->rIdx[k] = i; break; }
                if (strcmp(lower, "foot_l") == 0) rFallL = i;
                if (strcmp(lower, "foot_r") == 0) rFallR = i;
            }
            if (m->rIdx[11] < 0) m->rIdx[11] = rFallL;
            if (m->rIdx[14] < 0) m->rIdx[14] = rFallR;
            if (m->rIdx[11] < 0) m->rIdx[11] = m->rIdx[10];
            if (m->rIdx[14] < 0) m->rIdx[14] = m->rIdx[13];
            m->parent = (int *)malloc((size_t)N * sizeof(int));
            for (int i = 0; i < N; i++) m->parent[i] = info[i * 4 + 2];
            int count = 0;
            for (int k = 0; k < kMaxSel; k++) {
                if (selBone[k] < 0) continue;
                m->idx[count] = selBone[k];
                if (k == 0) m->head = count;
                if (k == 1) m->neck = count;
                if (k == 7) m->pelvis = count;
                count++;
            }
            for (int a = 0; a < count; a++) {
                m->link[a] = -1;
                int bi = m->idx[a], p = m->parent[bi];
                for (int guard = 0; guard < 64 && p >= 0; guard++) {
                    int found = -1;
                    for (int b = 0; b < count; b++) if (m->idx[b] == p) { found = b; break; }
                    if (found >= 0) { m->link[a] = found; break; }
                    p = m->parent[p];
                }
            }
            m->n = count;
            if (count == 0) {
                static int lg = 0;
                if (lg++ < 2) {
                    NSMutableString *q = [NSMutableString stringWithFormat:@"bones: none of the wanted bones matched; first names of %d:", N];
                    for (int i = 0; i < N && i < 40; i++) { NSString *nm = fname_string(info[i * 4]); [q appendFormat:@" %@", nm ?: @"?"]; }
                    metalNote(q);
                }
            }
        }
        free(info);
    }
    gBoneCache[key] = m;
    return (m->n > 0 || m->rIdx[0] >= 0) ? m : nil;
}

#pragma mark 5.6 scan thread

static BOOL gResolved = NO, gResolving = NO;
static CFTimeInterval gLastResolveTry = 0;
static int gLevelActorsOff = -1;
static float gCamTime = 0;

static int probeLevelActors(uintptr_t level) {
    for (int off = 0x70; off < 0x300; off += 8) {
        uintptr_t arr = rd_ptr(level + (uintptr_t)off);
        int32_t num = rd_i32(level + (uintptr_t)off + 8), mx = rd_i32(level + (uintptr_t)off + 12);
        if (arr < 0x100000000ULL || num < 50 || num > 500000 || mx < num) continue;
        uintptr_t el[8];
        if (!safe_read(arr, el, sizeof el)) continue;
        int good = 0;
        for (int i = 0; i < 8; i++) if (looks_like_uobject(el[i]) && rd_ptr(el[i] + (uintptr_t)gOffOuter) == level) good++;
        if (good >= 4) { RLOG(@"level: Actors array at Level+0x%x (num %d)", off, num); return off; }
    }
    return -1;
}

static BOOL actorLocation(uintptr_t actor, DV3 *out) {
    uintptr_t root = rd_ptr(actor + (uintptr_t)O_ACTOR_ROOT);
    if (root < 0x100000000ULL) return NO;
    return safe_read(root + (uintptr_t)O_SCENE_RELLOC, out, sizeof *out) && sane_dv(*out);
}

static BOOL pawnFlag(uintptr_t pawn, int off, uint8_t mask) {
    return off >= 0 && (rd_u8(pawn + (uintptr_t)off) & mask) != 0;
}

static void scanPawns(void) {
    if (!gResolved) {
        CFTimeInterval now = CACurrentMediaTime();
        static CFTimeInterval firstTry = 0;
        if (!firstTry) firstTry = now;
        if (gResolving || now - gLastResolveTry < 6.0 || now - firstTry < 15.0) { publishPawns(nil, 0, 0); return; }
        static int attempts = 0;
        if (attempts >= 5) { publishPawns(nil, 0, 0); return; }
        attempts++;
        gResolving = YES; gLastResolveTry = now;
        gResolved = resolveAll();
        gResolving = NO;
        if (gResolved) installEngineHook();
        if (!gResolved) { publishPawns(nil, 0, 0); return; }
    }
    if (!gBoneCache) gBoneCache = [NSMutableDictionary dictionary];
    gEngine = gEngineObj;
    gDiagEngine = looks_like_uobject(gEngine);
    gDiagWorld = NO; gDiagPC = NO; gDiagGameState = NO;
    gDiagPlayers = 0; gDiagPawns = 0; gDiagActors = 0; gDiagBones = 0;
    if (!gDiagEngine) { publishPawns(nil, 0, 0); return; }

    uintptr_t vp = rd_ptr(gEngine + (uintptr_t)O_ENGINE_VIEWPORT);
    uintptr_t world = looks_like_uobject(vp) ? rd_ptr(vp + (uintptr_t)O_VIEWPORT_WORLD) : 0;
    if (!looks_like_uobject(world)) { publishPawns(nil, 0, 0); return; }
    gDiagWorld = YES;

    uintptr_t pc = 0;
    uintptr_t gi = rd_ptr(world + (uintptr_t)O_WORLD_GI);
    if (looks_like_uobject(gi)) {
        uintptr_t lpData = rd_ptr(gi + (uintptr_t)O_GI_LOCALPLAYERS);
        uintptr_t lp = lpData ? rd_ptr(lpData) : 0;
        if (looks_like_uobject(lp)) pc = rd_ptr(lp + (uintptr_t)O_PLAYER_PC);
    }
    if (!looks_like_uobject(pc)) { publishPawns(nil, 0, 0); return; }
    gDiagPC = YES;

    uintptr_t localPawn = O_PC_ACKPAWN >= 0 ? rd_ptr(pc + (uintptr_t)O_PC_ACKPAWN) : 0;
    uintptr_t localPS = O_CTRL_PS >= 0 ? rd_ptr(pc + (uintptr_t)O_CTRL_PS) : 0;
    int localTeam = (looks_like_uobject(localPS) && O_PS_TEAM >= 0) ? rd_u8(localPS + (uintptr_t)O_PS_TEAM) : -1;

    uintptr_t gs = rd_ptr(world + (uintptr_t)O_WORLD_GAMESTATE);
    if (!looks_like_uobject(gs)) { publishPawns(nil, pc, localPawn); return; }
    gDiagGameState = YES;

    uintptr_t psData = rd_ptr(gs + (uintptr_t)O_GS_PLAYERS);
    int32_t psNum = rd_i32(gs + (uintptr_t)O_GS_PLAYERS + 8);
    if (psNum < 0) psNum = 0;
    if (psNum > 128) psNum = 128;
    gDiagPlayers = psNum;

    NSMutableArray<EchoPawn *> *out = [NSMutableArray array];
    for (int i = 0; psData && i < psNum; i++) {
        uintptr_t ps = rd_ptr(psData + (uintptr_t)i * 8);
        if (!looks_like_uobject(ps)) continue;
        uintptr_t a = rd_ptr(ps + (uintptr_t)O_PS_PAWN);
        if (!looks_like_uobject(a) || a == localPawn) continue;

        EchoPawn *ep = [[EchoPawn alloc] init];
        ep.pawn = a;
        int team = O_PS_TEAM >= 0 ? rd_u8(ps + (uintptr_t)O_PS_TEAM) : -2;
        ep.team = (localTeam > 0 && team == localTeam);
        NSString *name = O_PS_NAME >= 0 ? read_fstring(ps + (uintptr_t)O_PS_NAME) : nil;
        NSString *plat = O_PS_PLATFORM >= 0 ? read_fstring(ps + (uintptr_t)O_PS_PLATFORM) : nil;
        if (name.length && plat.length) ep.tag = [NSString stringWithFormat:@"%@ [%@]", name, plat];
        else if (name.length) ep.tag = name;
        else if (plat.length) ep.tag = [NSString stringWithFormat:@"[%@]", plat];
        else ep.tag = @"player";

        if (O_FPAWN_WEAPON >= 0 && O_WEAPON_DATA >= 0) {
            uintptr_t pw = rd_ptr(a + (uintptr_t)O_FPAWN_WEAPON);
            if (looks_like_uobject(pw)) {
                uintptr_t wd = rd_ptr(pw + (uintptr_t)O_WEAPON_DATA);
                if (looks_like_uobject(wd)) {
                    ep.weapon = cleanItemName(fname_string(fnidx(wd + (uintptr_t)gOffName)));
                    ep.wTier = O_ITEM_RARITY >= 0 ? rd_u8(wd + (uintptr_t)O_ITEM_RARITY) + 1 : 0;
                }
            }
        }
        uintptr_t mesh = O_CHAR_MESH >= 0 ? rd_ptr(a + (uintptr_t)O_CHAR_MESH) : 0;
        if (looks_like_uobject(mesh)) {
            ep.bones = buildBoneMap(mesh);
            if (ep.bones) gDiagBones++;
        }
        [out addObject:ep];
    }
    gDiagPawns = (int)out.count;

    NSMutableArray<EchoLoot *> *lootOut = [NSMutableArray array];
    if ((gOptLoot && O_PICKUP_DEF >= 0) || gOptChest) {
        uintptr_t level = O_WORLD_LEVEL >= 0 ? rd_ptr(world + (uintptr_t)O_WORLD_LEVEL) : 0;
        if (looks_like_uobject(level)) {
            if (gLevelActorsOff < 0) gLevelActorsOff = probeLevelActors(level);
            if (gLevelActorsOff >= 0) {
                uintptr_t aData = rd_ptr(level + (uintptr_t)gLevelActorsOff);
                int32_t aNum = rd_i32(level + (uintptr_t)gLevelActorsOff + 8);
                static NSMutableDictionary<NSNumber *, NSNumber *> *lootClassCache = nil;
                if (!lootClassCache) lootClassCache = [NSMutableDictionary dictionary];
                uintptr_t chunk[2048];
                int nLoot = 0, nChest = 0;
                static NSMutableDictionary<NSNumber *, NSNumber *> *searchedCache = nil;
                if (!searchedCache) searchedCache = [NSMutableDictionary dictionary];
                if (aData && aNum > 0 && aNum < 500000) {
                    gDiagActors = aNum;
                    for (int32_t base = 0; base < aNum && (nLoot < 400 || nChest < 400); base += 2048) {
                        int32_t cnt = aNum - base > 2048 ? 2048 : aNum - base;
                        if (!safe_read(aData + (uintptr_t)base * 8, chunk, (size_t)cnt * 8)) continue;
                        for (int32_t k = 0; k < cnt && (nLoot < 400 || nChest < 400); k++) {
                            uintptr_t a = chunk[k];
                            if (a < 0x100000000ULL || (a & 7)) continue;
                            uintptr_t cls = rd_ptr(a + (uintptr_t)gOffClass);
                            if (cls < 0x100000000ULL) continue;
                            NSNumber *ck = @(cls);
                            NSNumber *cv = lootClassCache[ck];
                            if (!cv) {
                                NSString *cn = fname_string(fnidx(cls + (uintptr_t)gOffName));
                                NSString *lcn = cn.lowercaseString;
                                int kind = 0;
                                if ([cn hasPrefix:@"FortPickup"]) kind = 1;
                                else if ([lcn containsString:@"tiered_chest"]) kind = 2;
                                else if ([lcn containsString:@"tiered_ammo"]) kind = 3;
                                else if ([lcn containsString:@"llama"] || [lcn containsString:@"supplydrop"]) kind = 4;
                                else if ([lcn containsString:@"cannon"] && ![lcn hasPrefix:@"fortweapon"] && ![lcn containsString:@"ball"] && ![lcn containsString:@"projectile"] && ![lcn containsString:@"ability"] && ![lcn containsString:@"component"]) kind = 5;
                                cv = @(kind);
                                lootClassCache[ck] = cv;
                            }
                            int kind = cv.intValue;
                            if (!kind) continue;
                            if (kind != 1) {
                                if (!gOptChest || nChest >= 400) continue;
                                NSNumber *sv = searchedCache[ck];
                                if (!sv) {
                                    int so = -1; uint8_t sm = 1;
                                    sv = boolMask(cls, "bAlreadySearched", &so, &sm) ? @((so << 8) | sm) : @(-1);
                                    searchedCache[ck] = sv;
                                }
                                if (sv.intValue >= 0 && (rd_u8(a + (uintptr_t)(sv.intValue >> 8)) & (uint8_t)(sv.intValue & 0xff))) continue;
                                DV3 cl;
                                if (!actorLocation(a, &cl)) continue;
                                EchoLoot *co = [[EchoLoot alloc] init];
                                co.x = cl.x; co.y = cl.y; co.z = cl.z; co.tier = -kind;
                                co.text = kind == 2 ? @"CHEST" : (kind == 3 ? @"AMMO" : (kind == 4 ? @"LLAMA" : @"CANNON"));
                                [lootOut addObject:co];
                                nChest++;
                                continue;
                            }
                            if (!(gOptLoot && O_PICKUP_DEF >= 0) || nLoot >= 400) continue;
                            uintptr_t def = rd_ptr(a + (uintptr_t)O_PICKUP_DEF);
                            if (!looks_like_uobject(def)) continue;
                            int tier = O_ITEM_RARITY >= 0 ? rd_u8(def + (uintptr_t)O_ITEM_RARITY) + 1 : 0;
                            if (tier < gOptLootMin + 3 || tier > 8) continue;
                            DV3 lp;
                            if (!actorLocation(a, &lp)) continue;
                            EchoLoot *lo = [[EchoLoot alloc] init];
                            lo.x = lp.x; lo.y = lp.y; lo.z = lp.z; lo.tier = tier;
                            lo.text = cleanItemName(fname_string(fnidx(def + (uintptr_t)gOffName)));
                            [lootOut addObject:lo];
                            nLoot++;
                        }
                    }
                }
            }
        }
    }
    gLoot = lootOut;
    publishPawns(out, pc, localPawn);
    gResolveLine2 = [NSString stringWithFormat:@"cam: %@  roots: %d  skelOff: 0x%x  c2w: 0x%x  reloff: 0x%x  lvl: 0x%x",
                     gDiagCam >= 0 ? @"Y" : @"n", gDiagPawns, 0, 0, gRefBonesOff < 0 ? 0 : gRefBonesOff, gLevelActorsOff < 0 ? 0 : gLevelActorsOff];
}



@interface EchoTag : NSObject
@property (nonatomic, copy)   NSString *text;
@property (nonatomic, assign) CGPoint c;
@property (nonatomic, strong) UIColor *color;
@end
@implementation EchoTag
@end

@interface EchoFrame : NSObject
@property (nonatomic, strong) UIBezierPath *eb;
@property (nonatomic, strong) UIBezierPath *tb;
@property (nonatomic, strong) UIBezierPath *ebn;
@property (nonatomic, strong) UIBezierPath *tbn;
@property (nonatomic, strong) NSMutableArray<EchoTag *> *tags;
@end
@implementation EchoFrame
@end

static UIWindow        *gLabelWindow = nil;
static UIView          *gLabelRoot   = nil;
static CADisplayLink   *gLabelLink   = nil;
static CAShapeLayer    *gBoxEnemy    = nil;
static CAShapeLayer    *gBoxTeam     = nil;
static CAShapeLayer    *gBoneEnemy   = nil;
static CAShapeLayer    *gBoneTeam    = nil;
static CAShapeLayer    *gFovRing     = nil;
static NSMutableArray<UILabel *> *gTagPool = nil;
static NSMutableArray<NSString *> *gTagText = nil;
static NSMutableArray<EchoFrame *> *gHistory = nil;
static dispatch_source_t gScanTimer  = nil;
static uintptr_t gAimTarget = 0;

static UILabel *tagAtIndex(NSUInteger i) {
    while (gTagPool.count <= i) {
        UILabel *v = [[UILabel alloc] init];
        v.font            = [UIFont boldSystemFontOfSize:11.0];
        v.textColor       = [UIColor whiteColor];
        v.textAlignment   = NSTextAlignmentCenter;
        v.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
        v.layer.cornerRadius = 3.0;
        v.clipsToBounds   = YES;
        v.hidden          = YES;
        [gLabelRoot addSubview:v];
        [gTagPool addObject:v];
        [gTagText addObject:@""];
    }
    return gTagPool[i];
}

#pragma mark 6.1 camera + projection (doubles, UE5 large world coordinates)

static int gCamEntryOff = -1;

static BOOL camEntryAt(uintptr_t e, DV3 *loc, DV3 *rot, float *fov, float *ts) {
    float t = rd_f32(e);
    if (!isfinite(t) || t < 0.0f || t > 1.0e8f) return NO;
    uintptr_t pov = e + 8;
    float f = rd_f32(pov + 0x30);
    if (!isfinite(f) || f < 20.0f || f > 170.0f) return NO;
    DV3 l, r;
    if (!safe_read(pov, &l, sizeof l) || !safe_read(pov + 0x18, &r, sizeof r)) return NO;
    if (!sane_dv(l) || !sane_dv(r) || fabs(r.x) > 360.0 || fabs(r.y) > 720.0 || fabs(r.z) > 720.0) return NO;
    if (fabs(l.x) + fabs(l.y) + fabs(l.z) < 1.0) return NO;
    *loc = l; *rot = r; *fov = f; *ts = t;
    return YES;
}

static BOOL readCamera(uintptr_t pc, DV3 *loc, DV3 *rot, float *fov) {
    if (O_PC_CAMMGR < 0) return NO;
    uintptr_t cm = rd_ptr(pc + (uintptr_t)O_PC_CAMMGR);
    if (cm < 0x100000000ULL) return NO;
    float ts = 0;
    if (gCamEntryOff >= 0 && camEntryAt(cm + (uintptr_t)gCamEntryOff, loc, rot, fov, &ts)) { gCamTime = ts; return YES; }
    if (O_CAMCACHE >= 0 && camEntryAt(cm + (uintptr_t)O_CAMCACHE, loc, rot, fov, &ts)) { gCamEntryOff = O_CAMCACHE; gDiagCam = 1; gCamTime = ts; return YES; }
    float best = -1.0f;
    int bestOff = -1;
    for (int off = 0x100; off < 0x3000; off += 8) {
        DV3 l, r; float f, t;
        if (camEntryAt(cm + (uintptr_t)off, &l, &r, &f, &t) && t > best) { best = t; bestOff = off; }
    }
    if (bestOff < 0) return NO;
    gCamEntryOff = bestOff; gDiagCam = 2;
    RLOG(@"camera: entry found by scan at CameraManager+0x%x (reflected: 0x%x)", bestOff, O_CAMCACHE);
    return camEntryAt(cm + (uintptr_t)bestOff, loc, rot, fov, &ts);
}

typedef struct { DV3 cam, fwd, right, up; double tanHalf, aspect; const double *vp; } EchoView;
static __thread const double *tVP = NULL;

static BOOL project(const EchoView *v, DV3 w, CGFloat *nx, CGFloat *ny, float *depth) {
    if (v->vp) {
        const double *m = v->vp;
        double X = w.x * m[0] + w.y * m[4] + w.z * m[8] + m[12];
        double Y = w.x * m[1] + w.y * m[5] + w.z * m[9] + m[13];
        double W = w.x * m[3] + w.y * m[7] + w.z * m[11] + m[15];
        if (!(W > 1.0)) return NO;
        *nx = 0.5 + 0.5 * (X / W);
        *ny = 0.5 - 0.5 * (Y / W);
        *depth = (float)W;
        return YES;
    }
    double dx = w.x - v->cam.x, dy = w.y - v->cam.y, dz = w.z - v->cam.z;
    double x = dx * v->fwd.x + dy * v->fwd.y + dz * v->fwd.z;
    if (x < 10.0) return NO;
    double y = dx * v->right.x + dy * v->right.y + dz * v->right.z;
    double z = dx * v->up.x + dy * v->up.y + dz * v->up.z;
    *nx = 0.5 + 0.5 * (y / (x * v->tanHalf));
    *ny = 0.5 - 0.5 * ((z / (x * v->tanHalf)) * v->aspect);
    *depth = (float)x;
    return YES;
}

static double wrap180(double a) {
    while (a > 180.0) a -= 360.0;
    while (a < -180.0) a += 360.0;
    return a;
}

typedef struct { uintptr_t pawn; DV3 aim; CGFloat sx, sy; BOOL onCross; } AimCand;

#pragma mark 6.2 skeleton arrays

static int gSkelOff = -1;
static BOOL gSkelDirect = NO;
static int gSkelCands = 0;
static int gC2WOff = -1;

static BOOL skelArrayAt(uintptr_t mesh, int off, int boneCount, uintptr_t *arr, int32_t *n) {
    uintptr_t a = rd_ptr(mesh + (uintptr_t)off);
    int32_t c = rd_i32(mesh + (uintptr_t)off + 8), m = rd_i32(mesh + (uintptr_t)off + 12);
    if (a < 0x100000000ULL || (a & 7) || c < 20 || c > kMaxBones || m < c || m > c * 4 + 64) return NO;
    if (c != boneCount && !(c > boneCount - 8 && c < boneCount)) return NO;
    DXf x0;
    if (!safe_read(a, &x0, sizeof x0) || !looks_like_xform(&x0)) return NO;
    *arr = a; *n = c;
    return YES;
}

static BOOL findSkelArray(uintptr_t mesh, EchoBoneMap *bm, uintptr_t *arr, int32_t *n, BOOL *direct) {
    int bc = bm->boneCount;
    if (gSkelOff >= 0 && skelArrayAt(mesh, gSkelOff, bc, arr, n)) { *direct = gSkelDirect; return YES; }
    if (gSkelOff >= 0 && gSkelOff + 16 < 0x1000 && skelArrayAt(mesh, gSkelOff + 16, bc, arr, n)) { *direct = gSkelDirect; return YES; }
    static CFTimeInterval lastScan = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastScan < 0.5) return NO;
    lastScan = now;
    int bestOff = -1;
    BOOL bestDirect = NO;
    int found = 0;
    for (int off = 0x400; off < 0x1000; off += 8) {
        uintptr_t a; int32_t c;
        if (!skelArrayAt(mesh, off, bc, &a, &c)) continue;
        found++;
        BOOL dir = NO;
        int hi = (bm->head >= 0) ? bm->idx[bm->head] : -1;
        if (hi >= 0 && hi < c) {
            DXf hx;
            if (safe_read(a + (uintptr_t)hi * sizeof(DXf), &hx, sizeof hx)) dir = fabs(hx.t[2]) > 60.0;
        }
        if (bestOff < 0 || (dir && !bestDirect)) { bestOff = off; bestDirect = dir; }
    }
    gSkelCands = found;
    if (bestOff < 0) return NO;
    gSkelOff = bestOff; gSkelDirect = bestDirect;
    RLOG(@"skeleton: transform array at mesh+0x%x direct=%d (%d candidates)", bestOff, (int)bestDirect, found);
    return skelArrayAt(mesh, bestOff, bc, arr, n) ? (*direct = bestDirect, YES) : NO;
}

static BOOL readC2W(uintptr_t mesh, DV3 nearPt, DXf *out) {
    if (gC2WOff >= 0) {
        if (safe_read(mesh + (uintptr_t)gC2WOff, out, sizeof *out) && looks_like_xform(out)) return YES;
    }
    for (int off = 0x100; off < 0x500; off += 16) {
        DXf x;
        if (!safe_read(mesh + (uintptr_t)off, &x, sizeof x) || !looks_like_xform(&x)) continue;
        double dx = x.t[0] - nearPt.x, dy = x.t[1] - nearPt.y, dz = x.t[2] - nearPt.z;
        if (sqrt(dx * dx + dy * dy + dz * dz) > 300.0) continue;
        gC2WOff = off;
        RLOG(@"skeleton: ComponentToWorld at mesh+0x%x", off);
        *out = x;
        return YES;
    }
    return NO;
}

static void applyFrame(EchoFrame *f, CGSize sz);

@interface EchoSnapPawn : NSObject {
@public
    uintptr_t pawn;
    BOOL team, downed, haveBones;
    DV3 feet, top, head, body;
    DV3 pts[kMaxSel];
    BOOL ptOk[kMaxSel];
    EchoPawn *meta;
}
@end
@implementation EchoSnapPawn
@end

@interface EchoSnap : NSObject {
@public
    CFTimeInterval t;
    DV3 cam, rot;
    float fov;
    NSArray<EchoSnapPawn *> *pawns;
    NSArray<EchoLoot *> *loot;
    int seq;
}
@end
@implementation EchoSnap
@end

static double gFrameDt = 1.0 / 60.0;
typedef struct { int seq; float v[9]; } CamRec;
static CamRec gCamRing[32];
static _Atomic int gCamSeq = 0;
static inline int gCamSeq_load(void) { return atomic_load(&gCamSeq); }
static NSMutableArray<EchoSnap *> *gSnaps = nil;
static NSObject *gSnapLock = nil;
static CGSize gScreenSz = {0, 0};

static EchoView makeView(DV3 cam, DV3 rot, float fov, CGSize sz) {
    double pr = rot.x * M_PI / 180.0, yr = rot.y * M_PI / 180.0, rr = rot.z * M_PI / 180.0;
    double sp = sin(pr), cp = cos(pr), sy = sin(yr), cy = cos(yr), sr = sin(rr), cr = cos(rr);
    EchoView view;
    view.cam = cam;
    view.fwd   = (DV3){ cp * cy, cp * sy, sp };
    view.right = (DV3){ sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp };
    view.up    = (DV3){ -(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp };
    view.tanHalf = tan(fov * M_PI / 360.0);
    view.aspect = sz.height > 0 ? sz.width / sz.height : 1.0;
    view.vp = tVP;
    return view;
}

static inline DV3 lerpV(DV3 a, DV3 b, double t) {
    return (DV3){ a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t };
}

static inline DV3 lerpRot(DV3 a, DV3 b, double t) {
    return (DV3){ a.x + wrap180(b.x - a.x) * t, a.y + wrap180(b.y - a.y) * t, a.z + wrap180(b.z - a.z) * t };
}

static EchoSnap *captureSnap(NSArray<EchoPawn *> *pawns, DV3 cam, DV3 rot, float fov, CFTimeInterval t) {
    EchoSnap *s = [[EchoSnap alloc] init];
    s->t = t; s->cam = cam; s->rot = rot; s->fov = fov;
    NSMutableArray<EchoSnapPawn *> *list = [NSMutableArray arrayWithCapacity:pawns.count];
    for (EchoPawn *ep in pawns) {
        if (pawnFlag(ep.pawn, O_DYING, M_DYING)) continue;
        BOOL downed = pawnFlag(ep.pawn, O_DBNO, M_DBNO);

        DV3 center = {0,0,0};
        double half = 0.0;
        BOOL haveCap = NO;
        uintptr_t cap = O_CHAR_CAPSULE >= 0 ? rd_ptr(ep.pawn + (uintptr_t)O_CHAR_CAPSULE) : 0;
        if (cap >= 0x100000000ULL && O_CAPSULE_HH >= 0 && O_SCENE_RELLOC >= 0) {
            half = rd_f32(cap + (uintptr_t)O_CAPSULE_HH);
            if (half > 20.0 && half < 140.0 &&
                safe_read(cap + (uintptr_t)O_SCENE_RELLOC, &center, sizeof center) && sane_dv(center)) haveCap = YES;
        }
        if (!haveCap) {
            if (!actorLocation(ep.pawn, &center)) continue;
            half = 88.0;
        }

        EchoSnapPawn *sp = [[EchoSnapPawn alloc] init];
        sp->pawn = ep.pawn; sp->meta = ep; sp->team = ep.team; sp->downed = downed;
        sp->feet = (DV3){ center.x, center.y, center.z - half };
        sp->head = (DV3){ center.x, center.y, center.z + half * 0.80 };
        sp->body = (DV3){ center.x, center.y, center.z + half * 0.25 };
        sp->top  = (DV3){ center.x, center.y, center.z + half };
        memset(sp->ptOk, 0, sizeof sp->ptOk);
        sp->haveBones = NO;

        if ((gOptSkeleton || gOptAimbot) && ep.bones && ep.bones->parent && O_CHAR_MESH >= 0) {
            uintptr_t mesh = rd_ptr(ep.pawn + (uintptr_t)O_CHAR_MESH);
            DXf c2w;
            if (mesh >= 0x100000000ULL && readC2W(mesh, center, &c2w)) {
                uintptr_t arr = 0;
                int32_t bn = 0;
                BOOL direct = NO;
                findSkelArray(mesh, ep.bones, &arr, &bn, &direct);
                if (bn > ep.bones->boneCount) bn = ep.bones->boneCount;
                if (arr >= 0x100000000ULL && bn > 20 && bn <= kMaxBones &&
                    safe_read(arr, gLocalBones, (size_t)bn * sizeof(DXf)) && looks_like_xform(&gLocalBones[0])) {
                    static DXf comp[kMaxBones];
                    for (int i = 0; i < bn; i++) {
                        const DXf *l = &gLocalBones[i];
                        int pi = ep.bones->parent[i];
                        DXf *c = &comp[i];
                        if (direct || pi < 0 || pi >= i) {
                            *c = *l;
                        } else {
                            const DXf *pc2 = &comp[pi];
                            DV3 lt = { l->t[0] * pc2->s[0], l->t[1] * pc2->s[1], l->t[2] * pc2->s[2] };
                            DV3 rt = qrot(pc2->q, lt);
                            c->t[0] = pc2->t[0] + rt.x; c->t[1] = pc2->t[1] + rt.y; c->t[2] = pc2->t[2] + rt.z;
                            double ax = pc2->q[0], ay = pc2->q[1], az = pc2->q[2], aw = pc2->q[3];
                            double bx = l->q[0], by2 = l->q[1], bz = l->q[2], bw = l->q[3];
                            c->q[0] = aw * bx + ax * bw + ay * bz - az * by2;
                            c->q[1] = aw * by2 - ax * bz + ay * bw + az * bx;
                            c->q[2] = aw * bz + ax * by2 - ay * bx + az * bw;
                            c->q[3] = aw * bw - ax * bx - ay * by2 - az * bz;
                            c->s[0] = pc2->s[0] * l->s[0]; c->s[1] = pc2->s[1] * l->s[1]; c->s[2] = pc2->s[2] * l->s[2];
                        }
                    }
                    for (int k = 0; k < ep.bones->n; k++) {
                        int bi = ep.bones->idx[k];
                        if (bi >= bn) continue;
                        const DXf *c = &comp[bi];
                        DV3 lp = { c->t[0] * c2w.s[0], c->t[1] * c2w.s[1], c->t[2] * c2w.s[2] };
                        DV3 r = qrot(c2w.q, lp);
                        sp->pts[k] = (DV3){ r.x + c2w.t[0], r.y + c2w.t[1], r.z + c2w.t[2] };
                        sp->ptOk[k] = sane_dv(sp->pts[k]);
                    }
                    sp->haveBones = YES;
                    int hi = ep.bones->head, ni = ep.bones->neck, pi2 = ep.bones->pelvis;
                    if (hi >= 0 && sp->ptOk[hi]) sp->head = sp->pts[hi];
                    if (ni >= 0 && pi2 >= 0 && sp->ptOk[ni] && sp->ptOk[pi2])
                        sp->body = (DV3){ (sp->pts[ni].x + sp->pts[pi2].x) * 0.5, (sp->pts[ni].y + sp->pts[pi2].y) * 0.5, (sp->pts[ni].z + sp->pts[pi2].z) * 0.5 };
                }
            }
        }
        if (sp->haveBones) sp->top = (DV3){ sp->head.x, sp->head.y, sp->head.z + 16.0 };
        [list addObject:sp];
    }
    s->pawns = list;
    s->loot = gLoot;
    return s;
}

static void aimStep(EchoSnap *s, uintptr_t pc, uintptr_t localPawn) {
    if (!gOptAimbot || !looks_like_uobject(pc) || O_CTRL_ROT < 0 || gScreenSz.width < 10) { gAimTarget = 0; gDiagLock = NO; return; }
    BOOL ads = (O_ADS < 0) ? YES : (localPawn && pawnFlag(localPawn, O_ADS, M_ADS));
    gDiagAds = ads;
    if (!(ads || !gOptAdsOnly)) { gAimTarget = 0; gDiagLock = NO; return; }
    CGSize sz = gScreenSz;
    EchoView view = makeView(s->cam, s->rot, s->fov, sz);
    CGFloat R = gOptFov * sz.height;
    int pick = -1;
    CGFloat bestD = 1.0e30;
    DV3 pickAim = {0,0,0};
    uintptr_t pickPawn = 0;
    for (EchoSnapPawn *sp in s->pawns) {
        if (sp->team || sp->downed) continue;
        DV3 aim = gOptAimBody ? sp->body : sp->head;
        CGFloat ax, ay; float ad;
        if (!project(&view, aim, &ax, &ay, &ad)) continue;
        CGFloat d = hypot((ax - 0.5) * sz.width, (ay - 0.5) * sz.height);
        CGFloat lim = (sp->pawn == gAimTarget) ? R * 1.35 : R;
        if (d <= lim && d < bestD) { bestD = d; pick = 1; pickAim = aim; pickPawn = sp->pawn; }
    }
    if (pick < 0) { gAimTarget = 0; gDiagLock = NO; return; }
    gAimTarget = pickPawn;
    double dx = pickAim.x - s->cam.x, dy = pickAim.y - s->cam.y, dz = pickAim.z - s->cam.z;
    double yaw = atan2(dy, dx) * 180.0 / M_PI;
    double pitch = atan2(dz, sqrt(dx * dx + dy * dy)) * 180.0 / M_PI;
    DV3 cur;
    if (!(safe_read(pc + (uintptr_t)O_CTRL_ROT, &cur, sizeof cur) && sane_dv(cur))) return;
    static CFTimeInterval lastAim = 0;
    CFTimeInterval now = CACurrentMediaTime();
    double dt = lastAim > 0 ? now - lastAim : 1.0 / 60.0;
    lastAim = now;
    if (dt < 0.001) dt = 0.001;
    if (dt > 0.05) dt = 0.05;
    double f120 = 1.0 - 0.97 * gOptSmooth;
    double f = 1.0 - pow(1.0 - f120, dt * 120.0);
    double cp0 = wrap180(cur.x), cy0 = wrap180(cur.y);
    DV3 nr = { cp0 + wrap180(pitch - cp0) * f, cy0 + wrap180(yaw - cy0) * f, cur.z };
    memcpy((void *)(pc + (uintptr_t)O_CTRL_ROT), &nr, sizeof nr);
    gDiagLock = YES;
}

static BOOL readCameraStable(uintptr_t pc, DV3 *loc, DV3 *rot, float *fov, float *ts) {
    for (int tries = 0; tries < 4; tries++) {
        DV3 l1, r1, l2, r2; float f1, f2;
        if (!readCamera(pc, &l1, &r1, &f1)) return NO;
        float t1 = gCamTime;
        if (!readCamera(pc, &l2, &r2, &f2)) return NO;
        if (memcmp(&l1, &l2, sizeof l1) == 0 && memcmp(&r1, &r2, sizeof r1) == 0 && t1 == gCamTime) {
            *loc = l1; *rot = r1; *fov = f1; *ts = t1;
            return YES;
        }
    }
    return NO;
}

static void samplerMain(void) {
    [NSThread setThreadPriority:1.0];
    DV3 lastCam = {0,0,0}, lastRot = {0,0,0};
    float lastTs = -1.0f;
    CFTimeInterval lastCap = 0, lastTsTime = 0;
    NSArray<EchoPawn *> *lastPawns = nil;
    for (;;) {
        @autoreleasepool {
            if (!gResolved) { usleep(100000); continue; }
            if (CACurrentMediaTime() - gEngDrawLast < 0.5) { usleep(20000); continue; }
            NSArray<EchoPawn *> *pawns; uintptr_t pc, lp;
            @synchronized ([NSProcessInfo processInfo]) { pawns = gPawns; pc = gLocalPC; lp = gLocalPawn; }
            if (!pc || !pawns.count) {
                @synchronized (gSnapLock) { [gSnaps removeAllObjects]; }
                gAimTarget = 0;
                usleep(30000);
                continue;
            }
            DV3 cam, rot; float fov, ts;
            if (!readCameraStable(pc, &cam, &rot, &fov, &ts)) { usleep(4000); continue; }
            CFTimeInterval now = CACurrentMediaTime();
            BOOL changed = ts != lastTs || memcmp(&cam, &lastCam, sizeof cam) != 0 || memcmp(&rot, &lastRot, sizeof rot) != 0;
            if (!changed && pawns == lastPawns && now - lastCap < 0.1) { usleep(1000); continue; }
            if (ts != lastTs) {
                double dtf = now - lastTsTime;
                if (lastTsTime > 0 && dtf > 0.004 && dtf < 0.06) gFrameDt = gFrameDt * 0.9 + dtf * 0.1;
                lastTsTime = now;
            }
            lastCam = cam; lastRot = rot; lastTs = ts; lastCap = now; lastPawns = pawns;
            atomic_fetch_add(&gCapCount, 1);
            EchoSnap *s = captureSnap(pawns, cam, rot, fov, now);
            {
                int sq = atomic_fetch_add(&gCamSeq, 1) + 1;
                s->seq = sq;
                EchoView vw = makeView(cam, rot, fov, CGSizeMake(1, 1));
                CamRec *rc = &gCamRing[sq & 31];
                rc->seq = 0;
                rc->v[0] = (float)vw.fwd.x;   rc->v[1] = (float)vw.fwd.y;   rc->v[2] = (float)vw.fwd.z;
                rc->v[3] = (float)vw.right.x; rc->v[4] = (float)vw.right.y; rc->v[5] = (float)vw.right.z;
                rc->v[6] = (float)vw.up.x;    rc->v[7] = (float)vw.up.y;    rc->v[8] = (float)vw.up.z;
                rc->seq = sq;
            }
            @synchronized (gSnapLock) {
                [gSnaps addObject:s];
                while (gSnaps.count > 160 || (gSnaps.count > 2 && now - gSnaps[0]->t > 1.0)) [gSnaps removeObjectAtIndex:0];
            }
            aimStep(s, pc, lp);
            usleep(500);
        }
    }
}

static void renderSnap(EchoFrame *frame, EchoSnap *A, EchoSnap *B, double alpha, CGSize sz) {
    DV3 cam = lerpV(A->cam, B->cam, alpha);
    DV3 rot = lerpRot(A->rot, B->rot, alpha);
    float fov = A->fov + (B->fov - A->fov) * (float)alpha;
    EchoView view = makeView(cam, rot, fov, sz);

    for (EchoSnapPawn *pb in B->pawns) {
        EchoSnapPawn *pa = nil;
        if (A != B) {
            for (EchoSnapPawn *c in A->pawns) if (c->pawn == pb->pawn) { pa = c; break; }
            if (pa) {
                double dx = pa->feet.x - pb->feet.x, dy = pa->feet.y - pb->feet.y, dz = pa->feet.z - pb->feet.z;
                if (dx * dx + dy * dy + dz * dz > 1500.0 * 1500.0) pa = nil;
            }
        }
        DV3 feet = pb->feet, topW = pb->top, headW = pb->head, bodyW = pb->body;
        (void)headW; (void)bodyW;
        DV3 pts[kMaxSel];
        BOOL ptOk[kMaxSel];
        memcpy(pts, pb->pts, sizeof pts);
        memcpy(ptOk, pb->ptOk, sizeof ptOk);
        if (pa) {
            feet = lerpV(pa->feet, pb->feet, alpha);
            topW = lerpV(pa->top, pb->top, alpha);
            if (pa->haveBones && pb->haveBones) {
                for (int k = 0; k < kMaxSel; k++) {
                    if (pa->ptOk[k] && pb->ptOk[k]) pts[k] = lerpV(pa->pts[k], pb->pts[k], alpha);
                }
            }
        }

        CGFloat tx, ty, bx, by; float d1, d2;
        if (!project(&view, topW, &tx, &ty, &d1)) continue;
        if (!project(&view, feet, &bx, &by, &d2)) continue;

        CGFloat ptop = ty * sz.height, pbot = by * sz.height;
        CGFloat h = pbot - ptop;
        if (h < 4.0 || h > sz.height * 3.0) continue;
        CGFloat w = h * 0.5;
        CGFloat cx = (tx + bx) * 0.5 * sz.width;
        if (cx < -w || cx > sz.width + w || pbot < 0 || ptop > sz.height) continue;

        CGRect boxRect = CGRectMake(cx - w * 0.5, ptop, w, h);
        [(pb->team ? frame.tb : frame.eb) appendPath:[UIBezierPath bezierPathWithRect:boxRect]];

        EchoPawn *ep = pb->meta;
        if (pb->haveBones && ep.bones) {
            UIBezierPath *bp = pb->team ? frame.tbn : frame.ebn;
            CGPoint scr[kMaxSel];
            BOOL scrOk[kMaxSel];
            for (int k = 0; k < ep.bones->n; k++) {
                CGFloat px, py; float dd;
                scrOk[k] = ptOk[k] && project(&view, pts[k], &px, &py, &dd);
                if (scrOk[k]) scr[k] = CGPointMake(px * sz.width, py * sz.height);
            }
            for (int k = 0; k < ep.bones->n; k++) {
                int l = ep.bones->link[k];
                if (l < 0 || !scrOk[k] || !scrOk[l]) continue;
                [bp moveToPoint:scr[k]];
                [bp addLineToPoint:scr[l]];
            }
        }

        double ddx = feet.x - cam.x, ddy = feet.y - cam.y, ddz = feet.z - cam.z;
        double dist = sqrt(ddx * ddx + ddy * ddy + ddz * ddz) / 100.0;
        if (gOptTags) {
            EchoTag *tg = [[EchoTag alloc] init];
            tg.text = [NSString stringWithFormat:@"%@  %.0fm", ep.tag, dist];
            tg.c = CGPointMake(cx, ptop - 10);
            [frame.tags addObject:tg];
        }
        if (gOptWeaponEsp && ep.weapon.length) {
            EchoTag *wt = [[EchoTag alloc] init];
            wt.text = ep.weapon;
            wt.color = tierColor(ep.wTier);
            wt.c = CGPointMake(cx, pbot + 18);
            [frame.tags addObject:wt];
        }
    }

    if (gOptLoot) {
        for (EchoLoot *lo in B->loot) {
            DV3 lp = { lo.x, lo.y, lo.z };
            CGFloat lx, ly; float ld;
            if (!project(&view, lp, &lx, &ly, &ld)) continue;
            double ddx = lp.x - cam.x, ddy = lp.y - cam.y, ddz = lp.z - cam.z;
            double dm = sqrt(ddx * ddx + ddy * ddy + ddz * ddz) / 100.0;
            if (dm > 250.0) continue;
            EchoTag *lt = [[EchoTag alloc] init];
            lt.text = [NSString stringWithFormat:@"%@  %.0fm", lo.text, dm];
            lt.color = tierColor(lo.tier);
            lt.c = CGPointMake(lx * sz.width, ly * sz.height);
            [frame.tags addObject:lt];
        }
    }
}

static EchoFrame *emptyFrame(void) {
    EchoFrame *frame = [[EchoFrame alloc] init];
    frame.eb = [UIBezierPath bezierPath];
    frame.tb = [UIBezierPath bezierPath];
    frame.ebn = [UIBezierPath bezierPath];
    frame.tbn = [UIBezierPath bezierPath];
    frame.tags = [NSMutableArray array];
    return frame;
}

static EchoFrame *frameForTime(double T, CFTimeInterval ref, CGSize sz) {
    EchoFrame *frame = emptyFrame();
    NSArray<EchoSnap *> *snaps;
    @synchronized (gSnapLock) { snaps = [gSnaps copy]; }
    if (!snaps.count) return frame;
    EchoSnap *newest = snaps.lastObject;
    if (ref - newest->t > 0.6) return frame;
    EchoSnap *A = newest, *B = newest;
    double alpha = 1.0;
    if (T >= newest->t) {
        for (NSInteger i = (NSInteger)snaps.count - 2; i >= 0; i--) {
            A = snaps[(NSUInteger)i];
            if (A->t <= newest->t - 0.030) break;
        }
        double span = newest->t - A->t;
        if (A != newest && span > 0.004 && span < 0.25) {
            double tt = T > newest->t + 0.07 ? newest->t + 0.07 : T;
            alpha = (tt - A->t) / span;
        } else {
            A = newest; alpha = 1.0;
        }
    } else {
        EchoSnap *oldest = snaps.firstObject;
        if (T <= oldest->t) {
            A = B = oldest;
        } else {
            for (NSInteger i = (NSInteger)snaps.count - 1; i >= 1; i--) {
                if (snaps[(NSUInteger)i - 1]->t <= T) {
                    A = snaps[(NSUInteger)i - 1]; B = snaps[(NSUInteger)i];
                    double span = B->t - A->t;
                    alpha = span > 1e-6 ? (T - A->t) / span : 1.0;
                    if (alpha < 0.0) alpha = 0.0;
                    if (alpha > 1.0) alpha = 1.0;
                    if (span > 0.25) alpha = 1.0;
                    break;
                }
            }
        }
    }
    renderSnap(frame, A, B, alpha, sz);
    return frame;
}

static EchoFrame *frameForTicks(float lagTicks, CFTimeInterval ref, CGSize sz) {
    EchoFrame *frame = emptyFrame();
    NSArray<EchoSnap *> *snaps;
    @synchronized (gSnapLock) { snaps = [gSnaps copy]; }
    if (!snaps.count) return frame;
    EchoSnap *newest = snaps.lastObject;
    if (ref - newest->t > 0.6) return frame;
    double pos = (double)snaps.count - 1.0 - (double)lagTicks;
    if (pos < 0.0) pos = 0.0;
    NSInteger i0 = (NSInteger)floor(pos);
    double a = pos - (double)i0;
    EchoSnap *S0 = snaps[(NSUInteger)i0];
    EchoSnap *S1 = (NSUInteger)(i0 + 1) < snaps.count ? snaps[(NSUInteger)(i0 + 1)] : S0;
    renderSnap(frame, S0, S1, a, sz);
    return frame;
}

static CFTimeInterval gMetalLastDraw = 0;

static void drawTick(CADisplayLink *link) {
    if (!gLabelRoot) return;
    attachScene(gLabelWindow);
    CGSize sz = gLabelRoot.bounds.size;
    gScreenSz = sz;
    CFTimeInterval now = CACurrentMediaTime();
    EchoFrame *frame;
    if (now - gMetalLastDraw < 0.5 || now - gEngDrawLast < 0.5) {
        frame = emptyFrame();
    } else {
        CFTimeInterval shown = (link.targetTimestamp > 0 ? link.targetTimestamp : now) + (link.duration > 0 ? link.duration : 1.0 / 60.0);
        frame = frameForTime(shown, shown, sz);
        gDiagDrawn = (int)frame.tags.count;
    }
    applyFrame(frame, sz);
}

#pragma mark 6.3 in-frame Metal overlay

static void metalNote(NSString *s);
#pragma mark 6.4 GPU view matching (find the exact camera the renderer used)

typedef struct { int stage, index, pos, strided, kind, neg, hits; int lagHist[8]; } GVote;
static GVote gVotes[256];
static int gVoteN = 0;
static os_unfair_lock gVoteLock = OS_UNFAIR_LOCK_INIT;
static volatile int gGpuMode = 0;
static CFTimeInterval gGpuStart = 0;
static int gGpuCalls = 0;
static GVote gLock;
static volatile int gGpuSeq = -1;
static volatile double gGpuStamp = 0;
static double gLagEma = 1.0;
static int gStatCalls[2][32];
static int gStatMax[2][32];
static int gBulkCalls = 0;
static const void *gLastBufData[2][32];
static size_t gLastBufLen[2][32];

static inline BOOL near3(float a, float b, float c, const float *v, float sgn) {
    const float tol = 1.5e-3f;
    return fabsf(a - sgn * v[0]) < tol && fabsf(b - sgn * v[1]) < tol && fabsf(c - sgn * v[2]) < tol;
}

static void gpuVote(int stage, int index, int pos, int strided, int kind, int neg, int back) {
    os_unfair_lock_lock(&gVoteLock);
    int k = -1;
    for (int i = 0; i < gVoteN; i++) {
        GVote *g = &gVotes[i];
        if (g->stage == stage && g->index == index && g->pos == pos && g->strided == strided && g->kind == kind && g->neg == neg) { k = i; break; }
    }
    if (k < 0 && gVoteN < 256) {
        k = gVoteN++;
        memset(&gVotes[k], 0, sizeof gVotes[k]);
        gVotes[k].stage = stage; gVotes[k].index = index; gVotes[k].pos = pos;
        gVotes[k].strided = strided; gVotes[k].kind = kind; gVotes[k].neg = neg;
    }
    if (k >= 0) { gVotes[k].hits++; if (back >= 0 && back < 8) gVotes[k].lagHist[back]++; }
    os_unfair_lock_unlock(&gVoteLock);
}

static void gpuDiscover(int stage, int index, const void *data, size_t len) {
    size_t nf = len / 4;
    if (nf < 12) return;
    const float *f = (const float *)data;
    int head = gCamSeq_load();
    const int NB = 4;
    CamRec *recs[NB];
    int ok = 0;
    for (int back = 0; back < NB; back++) {
        int sq = head - back;
        recs[back] = NULL;
        if (sq <= 0) continue;
        CamRec *r = &gCamRing[sq & 31];
        if (r->seq == sq) { recs[back] = r; ok++; }
    }
    if (ok < NB) return;
    for (size_t p = 0; p + 2 < nf; p++) {
        float a = f[p];
        if (!(a > -1.0001f && a < 1.0001f)) continue;
        float b = f[p + 1], c = f[p + 2];
        BOOL haveS = (p + 8 < nf);
        float b2 = haveS ? f[p + 4] : 0.0f, c2 = haveS ? f[p + 8] : 0.0f;
        for (int kind = 0; kind < 3; kind++) {
            int hitsC[2] = { 0, 0 }, hitsS[2] = { 0, 0 };
            int lastC[2] = { -1, -1 }, lastS[2] = { -1, -1 };
            for (int back = 0; back < NB; back++) {
                const float *v = &recs[back]->v[kind * 3];
                if (near3(a, b, c, v, 1.0f)) { hitsC[0]++; lastC[0] = back; }
                else if (near3(a, b, c, v, -1.0f)) { hitsC[1]++; lastC[1] = back; }
                if (haveS) {
                    if (near3(a, b2, c2, v, 1.0f)) { hitsS[0]++; lastS[0] = back; }
                    else if (near3(a, b2, c2, v, -1.0f)) { hitsS[1]++; lastS[1] = back; }
                }
            }
            for (int ng = 0; ng < 2; ng++) {
                if (hitsC[ng] == 1) gpuVote(stage, index, (int)p, 0, kind, ng, lastC[ng]);
                if (hitsS[ng] == 1) gpuVote(stage, index, (int)p, 1, kind, ng, lastS[ng]);
            }
        }
    }
}

static void gpuMatchLocked(const void *data, size_t len) {
    const float *f = (const float *)data;
    size_t need = (size_t)gLock.pos + (gLock.strided ? 9 : 3);
    if (len < need * 4) return;
    float t0 = f[gLock.pos], t1, t2;
    if (gLock.strided) { t1 = f[gLock.pos + 4]; t2 = f[gLock.pos + 8]; } else { t1 = f[gLock.pos + 1]; t2 = f[gLock.pos + 2]; }
    float sgn = gLock.neg ? -1.0f : 1.0f;
    int head = gCamSeq_load();
    float bestE = 1e9f, secondE = 1e9f;
    int bestSeq = -1;
    for (int back = 0; back < 24; back++) {
        int sq = head - back;
        if (sq <= 0) break;
        CamRec *r = &gCamRing[sq & 31];
        if (r->seq != sq) continue;
        const float *v = &r->v[gLock.kind * 3];
        float e = fmaxf(fabsf(t0 - sgn * v[0]), fmaxf(fabsf(t1 - sgn * v[1]), fabsf(t2 - sgn * v[2])));
        if (e < bestE) { secondE = bestE; bestE = e; bestSeq = sq; }
        else if (e < secondE) secondE = e;
    }
    if (bestSeq < 0 || bestE > 2.0e-3f) return;
    if (secondE > bestE * 4.0f + 2.0e-4f) {
        gLagEma = gLagEma * 0.95 + (double)(head - bestSeq) * 0.05;
    } else {
        bestSeq = head - (int)floor(gLagEma + 0.5);
        if (bestSeq <= 0) return;
    }
    gGpuSeq = bestSeq;
    gGpuStamp = CACurrentMediaTime();
}

static inline void gpuInspect(int stage, int index, const void *data, size_t len) {
    int mode = gGpuMode;
    if (mode == 1) {
        if (len < 64 || len > 16384 || !data) return;
        gStatCalls[stage][index & 31]++;
        if (len > gStatMax[stage][index & 31]) gStatMax[stage][index & 31] = (int)len;
        if ((++gGpuCalls & 7) != 0) return;
        gpuDiscover(stage, index, data, len);
    } else if (mode == 2) {
        if (stage != gLock.stage || index != gLock.index || !data) return;
        gpuMatchLocked(data, len);
    }
}

static inline void gpuBuf(int stage, int index, id buf, NSUInteger off) {
    if (index < 0 || index > 31) return;
    int mode = gGpuMode;
    if (mode == 0 || mode == 3) return;
    if (mode == 2 && (stage != gLock.stage || index != gLock.index)) {
        return;
    }
    id<MTLBuffer> b = (id<MTLBuffer>)buf;
    if (!b) return;
    const uint8_t *base = (const uint8_t *)b.contents;
    if (!base || off >= b.length) return;
    size_t len = (size_t)(b.length - off);
    if (len > 16384) len = 16384;
    gLastBufData[stage][index] = base;
    gLastBufLen[stage][index] = (size_t)(b.length);
    gpuInspect(stage, index, base + off, len);
}

static void gpuFinalize(void) {
    os_unfair_lock_lock(&gVoteLock);
    int best = -1;
    for (int i = 0; i < gVoteN; i++) if (best < 0 || gVotes[i].hits > gVotes[best].hits) best = i;
    NSMutableString *m = [NSMutableString stringWithFormat:@"gpu discovery: %d candidate slots, calls %d, bulk-setter calls %d", gVoteN, gGpuCalls, gBulkCalls];
    for (int st = 0; st < 2; st++) for (int ix = 0; ix < 32; ix++) if (gStatCalls[st][ix] > 0) [m appendFormat:@"\n  bound stage %d idx %d: %d calls, max %d bytes", st, ix, gStatCalls[st][ix], gStatMax[st][ix]];
    int shown = 0;
    for (int pass = 0; pass < 5; pass++) {
        int bi = -1;
        for (int i = 0; i < gVoteN; i++) {
            if (gVotes[i].hits < 0) continue;
            if (bi < 0 || gVotes[i].hits > gVotes[bi].hits) bi = i;
        }
        if (bi < 0) break;
        GVote *g = &gVotes[bi];
        [m appendFormat:@"\n  stage %d idx %d pos %d strided %d kind %d neg %d hits %d lag[%d %d %d %d]", g->stage, g->index, g->pos, g->strided, g->kind, g->neg, g->hits, g->lagHist[0], g->lagHist[1], g->lagHist[2], g->lagHist[3]];
        if (pass == 0) best = bi;
        g->hits = -g->hits;
        shown++;
    }
    for (int i = 0; i < gVoteN; i++) if (gVotes[i].hits < 0) gVotes[i].hits = -gVotes[i].hits;
    if (best >= 0 && gVotes[best].hits >= 12) {
        gLock = gVotes[best];
        gGpuMode = 2;
        [m appendString:@"\n  -> LOCKED"];
    } else {
        gGpuMode = 3;
        [m appendString:@"\n  -> nothing found, using lag slider"];
    }
    os_unfair_lock_unlock(&gVoteLock);
    metalNote(m);
}


typedef struct { float p[2]; float uv[2]; float c[4]; } EVert;

enum { kGlyphW = 14, kGlyphH = 26, kGlyphCols = 18, kAtlasW = 256, kAtlasH = 160, kMaxVerts = 24000, kRing = 6 };

static id<MTLDevice> gMDev = nil;
static id<MTLRenderPipelineState> gMPSO = nil;
static id<MTLTexture> gMAtlas = nil;
static id<MTLBuffer> gMBufs[kRing];
static int gMBufIdx = 0;
static MTLPixelFormat gMFmt = MTLPixelFormatInvalid;
static int gMFailures = 0;
static BOOL gMReady = NO;
static BOOL gSawPresentSel = NO;
static int gMDraws = 0;
static NSObject *gMNoteLock = nil;
static char kMarkKey;

static void metalNote(NSString *s) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!dir) return;
    if (!gMNoteLock) gMNoteLock = [[NSObject alloc] init];
    static NSMutableString *log = nil;
    @synchronized (gMNoteLock) {
        if (!log) log = [NSMutableString string];
        [log appendFormat:@"%@\n", s];
        [log writeToFile:[dir stringByAppendingPathComponent:@"EchoMod43_metal.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static id<MTLTexture> buildAtlas(id<MTLDevice> dev) {
    size_t W = kAtlasW, H = kAtlasH;
    uint8_t *px = (uint8_t *)calloc(W * H * 4, 1);
    if (!px) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(px); return nil; }
    CGContextTranslateCTM(ctx, 0, (CGFloat)H);
    CGContextScaleCTM(ctx, 1, -1);
    UIGraphicsPushContext(ctx);
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillRect(ctx, CGRectMake((CGFloat)W - 8, (CGFloat)H - 8, 8, 8));
    UIFont *font = nil;
    if (@available(iOS 13.0, *)) font = [UIFont monospacedSystemFontOfSize:20 weight:UIFontWeightBold];
    if (!font) font = [UIFont boldSystemFontOfSize:20];
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor whiteColor] };
    for (int ch = 32; ch < 127; ch++) {
        int i = ch - 32, col = i % kGlyphCols, row = i / kGlyphCols;
        NSString *s = [NSString stringWithFormat:@"%c", ch];
        [s drawAtPoint:CGPointMake(col * kGlyphW + 0.5, row * kGlyphH) withAttributes:attrs];
    }
    UIGraphicsPopContext();
    CGContextRelease(ctx);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    [t replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:px bytesPerRow:W * 4];
    free(px);
    return t;
}

static BOOL ensureMetal(id<MTLTexture> tex) {
    if (gMReady && gMFmt == tex.pixelFormat) return YES;
    if (gMFailures >= 3) return NO;
    id<MTLDevice> dev = tex.device;
    NSString *src =
        @"#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "struct VIn { float2 p; float2 uv; float4 c; };\n"
        "struct VOut { float4 pos [[position]]; float2 uv; float4 c; };\n"
        "vertex VOut vmain(uint vid [[vertex_id]], constant VIn *v [[buffer(0)]]) {\n"
        "  VOut o; o.pos = float4(v[vid].p, 0.0, 1.0); o.uv = v[vid].uv; o.c = v[vid].c; return o; }\n"
        "fragment float4 fmain(VOut in [[stage_in]], texture2d<float> t [[texture(0)]]) {\n"
        "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
        "  float a = t.sample(s, in.uv).a;\n"
        "  return float4(in.c.rgb, in.c.a * a); }\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
    if (!lib) { gMFailures++; metalNote([NSString stringWithFormat:@"library failed: %@", err]); return NO; }
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = [lib newFunctionWithName:@"vmain"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fmain"];
    pd.colorAttachments[0].pixelFormat = tex.pixelFormat;
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!pso) { gMFailures++; metalNote([NSString stringWithFormat:@"pipeline failed (fmt %d): %@", (int)tex.pixelFormat, err]); return NO; }
    if (!gMAtlas || gMDev != dev) {
        gMAtlas = buildAtlas(dev);
        for (int i = 0; i < kRing; i++) gMBufs[i] = [dev newBufferWithLength:(NSUInteger)kMaxVerts * sizeof(EVert) options:MTLResourceStorageModeShared];
    }
    if (!gMAtlas || !gMBufs[0]) { gMFailures++; metalNote(@"atlas/buffer failed"); return NO; }
    gMDev = dev; gMPSO = pso; gMFmt = tex.pixelFormat; gMReady = YES;
    metalNote([NSString stringWithFormat:@"pipeline ready fmt %d tex %lux%lu", (int)gMFmt, (unsigned long)tex.width, (unsigned long)tex.height]);
    return YES;
}

typedef struct { EVert *v; int n; CGSize sz; } VCtx;

static inline void vtx(VCtx *c, double x, double y, float u, float vv, const float *col) {
    if (c->n >= kMaxVerts) return;
    EVert *e = &c->v[c->n++];
    e->p[0] = (float)(x / c->sz.width * 2.0 - 1.0);
    e->p[1] = (float)(1.0 - y / c->sz.height * 2.0);
    e->uv[0] = u; e->uv[1] = vv;
    memcpy(e->c, col, sizeof e->c);
}

static void vquad(VCtx *c, double x0, double y0, double x1, double y1, double x2, double y2, double x3, double y3,
                  float u0, float v0, float u1, float v1, const float *col) {
    vtx(c, x0, y0, u0, v0, col); vtx(c, x1, y1, u1, v0, col); vtx(c, x2, y2, u1, v1, col);
    vtx(c, x0, y0, u0, v0, col); vtx(c, x2, y2, u1, v1, col); vtx(c, x3, y3, u0, v1, col);
}

static void vline(VCtx *c, double ax, double ay, double bx, double by, double w, const float *col) {
    double dx = bx - ax, dy = by - ay, len = sqrt(dx * dx + dy * dy);
    if (len < 0.01) return;
    double px = -dy / len * w * 0.5, py = dx / len * w * 0.5;
    float uS = (float)(kAtlasW - 4) / kAtlasW, vS = (float)(kAtlasH - 4) / kAtlasH;
    vquad(c, ax + px, ay + py, bx + px, by + py, bx - px, by - py, ax - px, ay - py, uS, vS, uS, vS, col);
}

static void vrect(VCtx *c, double x, double y, double w, double h, const float *col) {
    float uS = (float)(kAtlasW - 4) / kAtlasW, vS = (float)(kAtlasH - 4) / kAtlasH;
    vquad(c, x, y, x + w, y, x + w, y + h, x, y + h, uS, vS, uS, vS, col);
}

typedef struct { VCtx *c; CGPoint cur, start; double w; float col[4]; } PathCtx;

static void pathApplier(void *info, const CGPathElement *e) {
    PathCtx *p = (PathCtx *)info;
    switch (e->type) {
        case kCGPathElementMoveToPoint: p->cur = p->start = e->points[0]; break;
        case kCGPathElementAddLineToPoint:
            vline(p->c, p->cur.x, p->cur.y, e->points[0].x, e->points[0].y, p->w, p->col);
            p->cur = e->points[0];
            break;
        case kCGPathElementCloseSubpath:
            vline(p->c, p->cur.x, p->cur.y, p->start.x, p->start.y, p->w, p->col);
            p->cur = p->start;
            break;
        default: break;
    }
}

static void vpath(VCtx *c, UIBezierPath *bp, double w, float r, float g, float b, float a) {
    PathCtx p; p.c = c; p.cur = p.start = CGPointZero; p.w = w;
    p.col[0] = r; p.col[1] = g; p.col[2] = b; p.col[3] = a;
    CGPathApply(bp.CGPath, &p, pathApplier);
}

static void vtext(VCtx *c, NSString *s, double cx, double bottom, UIColor *color) {
    const char *u = s.UTF8String;
    if (!u) return;
    int n = (int)strlen(u);
    if (n > 48) n = 48;
    if (!n) return;
    const double cw = 7.0, ch = 13.0;
    double total = n * cw, x0 = cx - total * 0.5, top = bottom - ch - 2.0;
    float bg[4] = { 0, 0, 0, 0.5f };
    vrect(c, x0 - 4.0, top - 1.0, total + 8.0, ch + 3.0, bg);
    CGFloat r = 1, g = 1, b = 1, a = 1;
    if (color) [color getRed:&r green:&g blue:&b alpha:&a];
    float col[4] = { (float)r, (float)g, (float)b, (float)a };
    for (int i = 0; i < n; i++) {
        int chv = (unsigned char)u[i];
        if (chv < 32 || chv > 126) chv = '?';
        int idx = chv - 32, cc = idx % kGlyphCols, rr = idx / kGlyphCols;
        float u0 = (float)(cc * kGlyphW) / kAtlasW, v0 = (float)(rr * kGlyphH) / kAtlasH;
        float u1 = u0 + (float)kGlyphW / kAtlasW, v1 = v0 + (float)kGlyphH / kAtlasH;
        double x = x0 + i * cw;
        vquad(c, x, top, x + cw, top, x + cw, top + ch, x, top + ch, u0, v0, u1, v1, col);
    }
}

static int buildVerts(EchoFrame *f, CGSize sz, EVert *out) {
    VCtx c; c.v = out; c.n = 0; c.sz = sz;
    if (gOptBoxes) {
        vpath(&c, f.tb, 1.5, 0.2f, 1.0f, 0.4f, 1.0f);
        vpath(&c, f.eb, 1.5, 1.0f, 0.2f, 0.2f, 1.0f);
    }
    if (gOptSkeleton) {
        vpath(&c, f.tbn, 1.2, 0.4f, 1.0f, 1.0f, 1.0f);
        vpath(&c, f.ebn, 1.2, 1.0f, 0.9f, 0.2f, 1.0f);
    }
    if (gOptAimbot && gOptShowFov) {
        double r = gOptFov * sz.height, cx = sz.width * 0.5, cy = sz.height * 0.5;
        float col[4] = { 1, 1, 1, 0.5f };
        for (int i = 0; i < 64; i++) {
            double a0 = i * 2.0 * M_PI / 64.0, a1 = (i + 1) * 2.0 * M_PI / 64.0;
            vline(&c, cx + cos(a0) * r, cy + sin(a0) * r, cx + cos(a1) * r, cy + sin(a1) * r, 1.0, col);
        }
    }
    for (EchoTag *t in f.tags) vtext(&c, t.text, t.c.x, t.c.y, t.color);
    return c.n;
}


static EchoFrame *frameForSeq(int seq, CFTimeInterval ref, CGSize sz) {
    NSArray<EchoSnap *> *snaps;
    @synchronized (gSnapLock) { snaps = [gSnaps copy]; }
    for (NSInteger i = (NSInteger)snaps.count - 1; i >= 0; i--) {
        EchoSnap *S = snaps[(NSUInteger)i];
        if (S->seq == seq) {
            EchoFrame *frame = emptyFrame();
            if (ref - snaps.lastObject->t > 0.6) return frame;
            renderSnap(frame, S, S, 1.0, sz);
            return frame;
        }
        if (S->seq < seq) break;
    }
    return nil;
}

static BOOL camMoving(void) {
    int head = gCamSeq_load();
    CamRec *a = &gCamRing[head & 31], *b = &gCamRing[(head - 8) & 31];
    if (a->seq != head || b->seq != head - 8) return NO;
    float d = a->v[0] * b->v[0] + a->v[1] * b->v[1] + a->v[2] * b->v[2];
    return d < 0.9995f;
}

static void metalDraw(id<MTLCommandBuffer> cb, id<CAMetalDrawable> dr) {
    if (CACurrentMediaTime() - gEngDrawLast < 0.5) return;
    id<MTLTexture> tex = dr.texture;
    if (!tex || !(tex.usage & MTLTextureUsageRenderTarget) || tex.sampleCount != 1) return;
    if (!ensureMetal(tex)) return;
    CGSize sz = gScreenSz;
    if (sz.width < 10 || sz.height < 10) return;
    CFTimeInterval now = CACurrentMediaTime();
    float li = gOptLagF < 0.0f ? 0.0f : (gOptLagF > 3.0f ? 3.0f : gOptLagF);
    if (gGpuMode == 0 && gMDraws > 150 && camMoving()) { gGpuStart = now; gGpuMode = 1; metalNote(@"gpu view discovery started"); }
    if (gGpuMode == 1 && now - gGpuStart > 7.0) gpuFinalize();
    if (gGpuMode == 2) {
        static int sinceLock = 0, exactSince = 0;
        sinceLock++;
        if (gGpuSeq > 0 && now - gGpuStamp < 0.05) exactSince++;
        if (sinceLock == 900) {
            metalNote([NSString stringWithFormat:@"lock check: %d/%d draws had an exact match", exactSince, sinceLock]);
            if (exactSince * 2 < sinceLock) { gGpuMode = 3; metalNote(@"lock rejected, using lag slider"); }
        }
    }
    EchoFrame *f = nil;
    BOOL exact = NO;
    if (gGpuMode == 2) {
        int gs = gGpuSeq;
        if (gs > 0 && now - gGpuStamp < 0.05) { f = frameForSeq(gs, now, sz); exact = (f != nil); }
    }
    if (!f) f = frameForTicks(li, now, sz);
    static int exactN = 0, totalN = 0;
    totalN++; if (exact) exactN++;
    gMBufIdx = (gMBufIdx + 1) % kRing;
    id<MTLBuffer> buf = gMBufs[gMBufIdx];
    int n = buildVerts(f, sz, (EVert *)buf.contents);
    gDiagDrawn = (int)f.tags.count;
    gMetalLastDraw = now;
    if (n <= 0) return;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tex;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    if (!enc) return;
    [enc setRenderPipelineState:gMPSO];
    [enc setVertexBuffer:buf offset:0 atIndex:0];
    [enc setFragmentTexture:gMAtlas atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)n];
    [enc endEncoding];
    gMDraws++;
    if (gMDraws == 1 || gMDraws % 600 == 0)
        metalNote([NSString stringWithFormat:@"draw #%d verts %d tags %d lag %.2f ticks caps %d exact %d/%d lagEma %.2f mode %d", gMDraws, n, (int)f.tags.count, li, atomic_load(&gCapCount), exactN, totalN, gLagEma, gGpuMode]);
}

static void metalMark(id cb, id drawable) {
    objc_setAssociatedObject(cb, &kMarkKey, drawable ?: (id)[NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void metalOnCommit(id cb) {
    id mk = objc_getAssociatedObject(cb, &kMarkKey);
    if (!mk) return;
    objc_setAssociatedObject(cb, &kMarkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id dr = [mk conformsToProtocol:@protocol(CAMetalDrawable)] ? mk : gCurDrawable;
    if (!dr) return;
    if (gMFailures >= 3) return;
    @try {
        metalDraw((id<MTLCommandBuffer>)cb, (id<CAMetalDrawable>)dr);
    } @catch (NSException *ex) {
        gMFailures++;
        metalNote([NSString stringWithFormat:@"exception: %@", ex]);
    }
}

static void hookMetalClass(Class c) {
    static NSMutableSet *done = nil;
    if (!done) done = [NSMutableSet set];
    NSString *cn = NSStringFromClass(c);
    if ([done containsObject:cn]) return;
    [done addObject:cn];

    Method mc = class_getInstanceMethod(c, @selector(commit));
    if (mc) {
        IMP o = method_getImplementation(mc);
        IMP n = imp_implementationWithBlock(^(id s) {
            metalOnCommit(s);
            ((void (*)(id, SEL))o)(s, @selector(commit));
        });
        class_replaceMethod(c, @selector(commit), n, method_getTypeEncoding(mc));
    }
    Method m1 = class_getInstanceMethod(c, @selector(presentDrawable:));
    if (m1) {
        IMP o = method_getImplementation(m1);
        IMP n = imp_implementationWithBlock(^(id s, id d) {
            gSawPresentSel = YES; metalMark(s, d);
            ((void (*)(id, SEL, id))o)(s, @selector(presentDrawable:), d);
        });
        class_replaceMethod(c, @selector(presentDrawable:), n, method_getTypeEncoding(m1));
    }
    Method m2 = class_getInstanceMethod(c, @selector(presentDrawable:atTime:));
    if (m2) {
        IMP o = method_getImplementation(m2);
        IMP n = imp_implementationWithBlock(^(id s, id d, CFTimeInterval t) {
            gSawPresentSel = YES; metalMark(s, d);
            ((void (*)(id, SEL, id, CFTimeInterval))o)(s, @selector(presentDrawable:atTime:), d, t);
        });
        class_replaceMethod(c, @selector(presentDrawable:atTime:), n, method_getTypeEncoding(m2));
    }
    Method m3 = class_getInstanceMethod(c, @selector(presentDrawable:afterMinimumDuration:));
    if (m3) {
        IMP o = method_getImplementation(m3);
        IMP n = imp_implementationWithBlock(^(id s, id d, CFTimeInterval t) {
            gSawPresentSel = YES; metalMark(s, d);
            ((void (*)(id, SEL, id, CFTimeInterval))o)(s, @selector(presentDrawable:afterMinimumDuration:), d, t);
        });
        class_replaceMethod(c, @selector(presentDrawable:afterMinimumDuration:), n, method_getTypeEncoding(m3));
    }
    Method m4 = class_getInstanceMethod(c, @selector(addScheduledHandler:));
    if (m4) {
        IMP o = method_getImplementation(m4);
        IMP n = imp_implementationWithBlock(^(id s, id blk) {
            if (!gSawPresentSel && gCurDrawable) metalMark(s, nil);
            ((void (*)(id, SEL, id))o)(s, @selector(addScheduledHandler:), blk);
        });
        class_replaceMethod(c, @selector(addScheduledHandler:), n, method_getTypeEncoding(m4));
    }
}

static void hookEncoderClass(Class c) {
    static NSMutableSet *done = nil;
    if (!done) done = [NSMutableSet set];
    NSString *cn = NSStringFromClass(c);
    if ([done containsObject:cn]) return;
    [done addObject:cn];
    for (int st = 0; st < 2; st++) {
        SEL sb = st == 0 ? @selector(setVertexBuffer:offset:atIndex:) : @selector(setFragmentBuffer:offset:atIndex:);
        Method m = class_getInstanceMethod(c, sb);
        if (m) {
            IMP o = method_getImplementation(m);
            int stage = st;
            IMP n = imp_implementationWithBlock(^(id s, id b, NSUInteger off, NSUInteger idx) {
                gpuBuf(stage, (int)idx, b, off);
                ((void (*)(id, SEL, id, NSUInteger, NSUInteger))o)(s, sb, b, off, idx);
            });
            class_replaceMethod(c, sb, n, method_getTypeEncoding(m));
        }
        SEL sy = st == 0 ? @selector(setVertexBytes:length:atIndex:) : @selector(setFragmentBytes:length:atIndex:);
        Method m2 = class_getInstanceMethod(c, sy);
        if (m2) {
            IMP o = method_getImplementation(m2);
            int stage = st;
            IMP n = imp_implementationWithBlock(^(id s, const void *bytes, NSUInteger len, NSUInteger idx) {
                if (gGpuMode == 1 || gGpuMode == 2) gpuInspect(stage, (int)idx, bytes, (size_t)len);
                ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))o)(s, sy, bytes, len, idx);
            });
            class_replaceMethod(c, sy, n, method_getTypeEncoding(m2));
        }
        SEL sbulk = st == 0 ? @selector(setVertexBuffers:offsets:withRange:) : @selector(setFragmentBuffers:offsets:withRange:);
        Method mb = class_getInstanceMethod(c, sbulk);
        if (mb) {
            IMP o = method_getImplementation(mb);
            int stage = st;
            IMP n = imp_implementationWithBlock(^(id s, const __unsafe_unretained id *bufs, const NSUInteger *offs, NSRange rg) {
                if (gGpuMode == 1 || gGpuMode == 2) {
                    gBulkCalls++;
                    for (NSUInteger i = 0; i < rg.length && i < 31; i++) if (bufs[i]) gpuBuf(stage, (int)(rg.location + i), bufs[i], offs[i]);
                }
                ((void (*)(id, SEL, const __unsafe_unretained id *, const NSUInteger *, NSRange))o)(s, sbulk, bufs, offs, rg);
            });
            class_replaceMethod(c, sbulk, n, method_getTypeEncoding(mb));
        }
        SEL so = st == 0 ? @selector(setVertexBufferOffset:atIndex:) : @selector(setFragmentBufferOffset:atIndex:);
        Method m3 = class_getInstanceMethod(c, so);
        if (m3) {
            IMP o = method_getImplementation(m3);
            int stage = st;
            IMP n = imp_implementationWithBlock(^(id s, NSUInteger off, NSUInteger idx) {
                if ((gGpuMode == 1 || gGpuMode == 2) && idx < 32 && gLastBufData[stage][idx] && off < gLastBufLen[stage][idx]) {
                    size_t len = gLastBufLen[stage][idx] - (size_t)off;
                    if (len > 16384) len = 16384;
                    gpuInspect(stage, (int)idx, (const uint8_t *)gLastBufData[stage][idx] + off, len);
                }
                ((void (*)(id, SEL, NSUInteger, NSUInteger))o)(s, so, off, idx);
            });
            class_replaceMethod(c, so, n, method_getTypeEncoding(m3));
        }
    }
}

static void installMetalHooks(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) return;
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb1 = [q commandBuffer];
    id<MTLCommandBuffer> cb2 = [q commandBufferWithUnretainedReferences];
    Class c1 = object_getClass(cb1), c2 = object_getClass(cb2);
    hookMetalClass(c1);
    if (c2 != c1 && class_getSuperclass(c2) != c1) hookMetalClass(c2);
    metalNote([NSString stringWithFormat:@"hooked command buffer classes: %@ %@", NSStringFromClass(c1), NSStringFromClass(c2)]);
    @try {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = t;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionDontCare;
        id<MTLRenderCommandEncoder> enc = [cb1 renderCommandEncoderWithDescriptor:rp];
        Class ec = object_getClass(enc);
        [enc endEncoding];
        hookEncoderClass(ec);
        id<MTLCommandBuffer> cb3 = [q commandBuffer];
        id<MTLParallelRenderCommandEncoder> pe = [cb3 parallelRenderCommandEncoderWithDescriptor:rp];
        id<MTLRenderCommandEncoder> sub = [pe renderCommandEncoder];
        Class sc = object_getClass(sub);
        [sub endEncoding];
        [pe endEncoding];
        if (sc != ec) hookEncoderClass(sc);
        metalNote([NSString stringWithFormat:@"hooked encoder classes: %@ %@", NSStringFromClass(ec), NSStringFromClass(sc)]);
    } @catch (NSException *ex) {
        metalNote([NSString stringWithFormat:@"encoder hook exception: %@", ex]);
    }
}

#pragma mark 6.5 engine canvas draw (same method as Raax: hook the viewport's DrawTransition, draw with the game's own canvas)

typedef struct { float r, g, b, a; } FLC;
typedef void (*DrawLineFn)(void *, double, double, double, double, float, float, float, float, FLC);
typedef void (*DTFn)(void *, void *);

static void **gDTSlot = NULL;
static DTFn gDTOrig = NULL;
static int gDTBad = 0;
static int gDTFrames = 0;
static uintptr_t gCanvasCls = 0;
static BOOL gDTHooked = NO;

static inline void engLine(void *cv, double ax, double ay, double bx, double by, float th, const float *c) {
    ((DrawLineFn)SYM(0x105672764ULL))(cv, ax, ay, bx, by, th, 0.0f, 0.0f, 0.0f, (FLC){ c[0], c[1], c[2], c[3] });
}

static const char *strokeGlyph(int ch) {
    if (ch >= 'a' && ch <= 'z') ch -= 32;
    switch (ch) {
        case '0': return "00 20 24 04 00";
        case '1': return "01 10 14 / 04 24";
        case '2': return "00 20 22 02 04 24";
        case '3': return "00 20 24 04 / 02 22";
        case '4': return "00 02 22 / 20 24";
        case '5': return "20 00 02 22 24 04";
        case '6': return "20 00 04 24 22 02";
        case '7': return "00 20 14";
        case '8': return "00 20 24 04 00 / 02 22";
        case '9': return "22 02 00 20 24 04";
        case 'A': return "04 00 20 24 / 02 22";
        case 'B': return "00 04 24 22 02 / 00 20 22";
        case 'C': return "20 00 04 24";
        case 'D': return "00 04 23 21 10 00";
        case 'E': return "20 00 04 24 / 02 12";
        case 'F': return "20 00 04 / 02 12";
        case 'G': return "20 00 04 24 22 12";
        case 'H': return "00 04 / 20 24 / 02 22";
        case 'I': return "00 20 / 10 14 / 04 24";
        case 'J': return "20 24 04 02";
        case 'K': return "00 04 / 20 02 24";
        case 'L': return "00 04 24";
        case 'M': return "04 00 12 20 24";
        case 'N': return "04 00 24 20";
        case 'O': return "00 20 24 04 00";
        case 'P': return "04 00 20 22 02";
        case 'Q': return "00 20 24 04 00 / 12 24";
        case 'R': return "04 00 20 22 02 / 12 24";
        case 'S': return "20 00 02 22 24 04";
        case 'T': return "00 20 / 10 14";
        case 'U': return "00 04 24 20";
        case 'V': return "00 14 20";
        case 'W': return "00 04 12 24 20";
        case 'X': return "00 24 / 20 04";
        case 'Y': return "00 12 20 / 12 14";
        case 'Z': return "00 20 04 24";
        case '.': return "13 14";
        case '-': return "02 22";
        case '_': return "04 24";
        case ':': return "11 12 / 13 14";
        case '[': return "20 10 14 24";
        case ']': return "00 10 14 04";
        case '/': return "24 00";
        case '%': return "00 11 / 13 24";
        default: return NULL;
    }
}

static void engText(void *cv, NSString *s, double cx, double bottom, double u, double th, const float *col) {
    const char *t = s.UTF8String;
    if (!t) return;
    int n = (int)strlen(t);
    if (n > 40) n = 40;
    double adv = 3.6 * u, total = n * adv;
    double x0 = cx - total * 0.5, y0 = bottom - 4.0 * u - 3.0;
    for (int i = 0; i < n; i++) {
        const char *g = strokeGlyph((unsigned char)t[i]);
        if (!g) continue;
        double gx = x0 + i * adv;
        double px = 0, py = 0;
        BOOL pen = NO;
        const char *p = g;
        while (*p) {
            if (*p == ' ') { p++; continue; }
            if (*p == '/') { pen = NO; p++; continue; }
            if (p[0] >= '0' && p[0] <= '9' && p[1] >= '0' && p[1] <= '9') {
                double x = gx + (p[0] - '0') * u, y = y0 + (p[1] - '0') * u;
                if (pen) engLine(cv, px, py, x, y, (float)th, col);
                px = x; py = y; pen = YES;
                p += 2;
                continue;
            }
            p++;
        }
    }
}

typedef struct { void *cv; double th; float col[4]; } EngPathCtx;
typedef struct { void *cv; double th; float col[4]; CGPoint cur, start; } EngPath;

static void engPathApplier(void *info, const CGPathElement *e) {
    EngPath *p = (EngPath *)info;
    switch (e->type) {
        case kCGPathElementMoveToPoint: p->cur = p->start = e->points[0]; break;
        case kCGPathElementAddLineToPoint:
            engLine(p->cv, p->cur.x, p->cur.y, e->points[0].x, e->points[0].y, (float)p->th, p->col);
            p->cur = e->points[0];
            break;
        case kCGPathElementCloseSubpath:
            engLine(p->cv, p->cur.x, p->cur.y, p->start.x, p->start.y, (float)p->th, p->col);
            p->cur = p->start;
            break;
        default: break;
    }
}

static void engPath(void *cv, UIBezierPath *bp, double th, float r, float g, float b, float a) {
    EngPath p; p.cv = cv; p.th = th; p.cur = p.start = CGPointZero;
    p.col[0] = r; p.col[1] = g; p.col[2] = b; p.col[3] = a;
    CGPathApply(bp.CGPath, &p, engPathApplier);
}

static int gVPOff = -1;
static BOOL gVPDbl = NO;
static int gVPTries = 0;
static double gVPm[16];

static BOOL vpRead(void *cv, int off, BOOL dbl, double *o) {
    if (dbl) return safe_read((uintptr_t)cv + (uintptr_t)off, o, 128);
    float f[16];
    if (!safe_read((uintptr_t)cv + (uintptr_t)off, f, 64)) return NO;
    for (int i = 0; i < 16; i++) o[i] = f[i];
    return YES;
}

static inline BOOL vpEval(const double *m, DV3 p, double *x, double *y, double *w) {
    *x = p.x * m[0] + p.y * m[4] + p.z * m[8] + m[12];
    *y = p.x * m[1] + p.y * m[5] + p.z * m[9] + m[13];
    *w = p.x * m[3] + p.y * m[7] + p.z * m[11] + m[15];
    return isfinite(*x) && isfinite(*y) && isfinite(*w);
}

static void vpProbe(void *cv, DV3 cam, DV3 rot, float fov) {
    EchoView bv = makeView(cam, rot, fov, CGSizeMake(16, 9));
    DV3 P0 = { cam.x + bv.fwd.x * 1000.0, cam.y + bv.fwd.y * 1000.0, cam.z + bv.fwd.z * 1000.0 };
    DV3 P1 = { P0.x + bv.right.x * 100.0, P0.y + bv.right.y * 100.0, P0.z + bv.right.z * 100.0 };
    DV3 P2 = { P0.x + bv.up.x * 100.0, P0.y + bv.up.y * 100.0, P0.z + bv.up.z * 100.0 };
    for (int pass = 0; pass < 2; pass++) {
        BOOL dbl = pass == 1;
        for (int off = 0x48; off < 0x900; off += 8) {
            double m[16];
            if (!vpRead(cv, off, dbl, m)) continue;
            double x0, y0, w0, x1, y1, w1, x2, y2, w2;
            if (!vpEval(m, P0, &x0, &y0, &w0) || !vpEval(m, P1, &x1, &y1, &w1) || !vpEval(m, P2, &x2, &y2, &w2)) continue;
            if (w0 < 200.0 || w0 > 5000.0 || w1 < 200.0 || w2 < 200.0) continue;
            double a0 = x0 / w0, b0 = y0 / w0, a1 = x1 / w1, b2 = y2 / w2;
            if (fabs(a0) > 0.03 || fabs(b0) > 0.03) continue;
            if (!(a1 - a0 > 0.01 && a1 - a0 < 1.5)) continue;
            double dy = b2 - b0;
            if (!(fabs(dy) > 0.01 && fabs(dy) < 2.5)) continue;
            gVPOff = off; gVPDbl = dbl;
            metalNote([NSString stringWithFormat:@"engine VP matrix found at canvas+0x%x (%s) w0 %.0f", off, dbl ? "double" : "float", w0]);
            return;
        }
    }
}

typedef struct { DV3 w[16]; } RaaxBones;

static int gRbFail[8];
static int gRbOk = 0;
static BOOL raaxBones(EchoPawn *ep, RaaxBones *out) {
    if (!ep.bones || !ep.bones->parent || O_CHAR_MESH < 0) { gRbFail[0]++; return NO; }
    uintptr_t mesh = rd_ptr(ep.pawn + (uintptr_t)O_CHAR_MESH);
    if (mesh < 0x100000000ULL) { gRbFail[1]++; return NO; }
    DV3 center;
    if (!actorLocation(ep.pawn, &center)) { gRbFail[2]++; return NO; }
    DXf c2w;
    if (!readC2W(mesh, center, &c2w)) { gRbFail[3]++; return NO; }
    uintptr_t arr = 0;
    int32_t bn = 0;
    BOOL direct = NO;
    findSkelArray(mesh, ep.bones, &arr, &bn, &direct);
    if (bn > ep.bones->boneCount) bn = ep.bones->boneCount;
    if (arr < 0x100000000ULL || bn <= 20 || bn > kMaxBones) { gRbFail[4]++; return NO; }
    if (!safe_read(arr, gLocalBones, (size_t)bn * sizeof(DXf)) || !looks_like_xform(&gLocalBones[0])) { gRbFail[5]++; return NO; }
    static DXf comp[kMaxBones];
    for (int i = 0; i < bn; i++) {
        const DXf *l = &gLocalBones[i];
        int pi = ep.bones->parent[i];
        DXf *c = &comp[i];
        if (direct || pi < 0 || pi >= i) {
            *c = *l;
        } else {
            const DXf *pc2 = &comp[pi];
            DV3 lt = { l->t[0] * pc2->s[0], l->t[1] * pc2->s[1], l->t[2] * pc2->s[2] };
            DV3 rt = qrot(pc2->q, lt);
            c->t[0] = pc2->t[0] + rt.x; c->t[1] = pc2->t[1] + rt.y; c->t[2] = pc2->t[2] + rt.z;
            double ax = pc2->q[0], ay = pc2->q[1], az = pc2->q[2], aw = pc2->q[3];
            double bx = l->q[0], by2 = l->q[1], bz = l->q[2], bw = l->q[3];
            c->q[0] = aw * bx + ax * bw + ay * bz - az * by2;
            c->q[1] = aw * by2 - ax * bz + ay * bw + az * bx;
            c->q[2] = aw * bz + ax * by2 - ay * bx + az * bw;
            c->q[3] = aw * bw - ax * bx - ay * by2 - az * bz;
            c->s[0] = pc2->s[0] * l->s[0]; c->s[1] = pc2->s[1] * l->s[1]; c->s[2] = pc2->s[2] * l->s[2];
        }
    }
    for (int k = 0; k < 15; k++) {
        int bi = ep.bones->rIdx[k];
        if (bi < 0 || bi >= bn) {
            gRbFail[6]++;
            static int logged = 0;
            if (logged < 3) { logged++; metalNote([NSString stringWithFormat:@"bones: slot %d missing/out of range (bone idx %d, array %d, skeleton %d)", k, bi, bn, ep.bones->boneCount]); }
            return NO;
        }
        const DXf *c = &comp[bi];
        DV3 lp = { c->t[0] * c2w.s[0], c->t[1] * c2w.s[1], c->t[2] * c2w.s[2] };
        DV3 r = qrot(c2w.q, lp);
        out->w[k] = (DV3){ r.x + c2w.t[0], r.y + c2w.t[1], r.z + c2w.t[2] };
        if (!sane_dv(out->w[k])) { gRbFail[7]++; return NO; }
    }
    gRbOk++;
    out->w[15] = (DV3){ (out->w[3].x + out->w[6].x) * 0.5, (out->w[3].y + out->w[6].y) * 0.5, (out->w[3].z + out->w[6].z) * 0.5 };
    return YES;
}

static const int kRaaxPairs[15][2] = {
    {0, 1}, {1, 15}, {15, 2}, {15, 3}, {3, 4}, {4, 5}, {15, 6}, {6, 7}, {7, 8}, {2, 9}, {9, 10}, {10, 11}, {2, 12}, {12, 13}, {13, 14}
};

static void engFillBox(void *cv, double x0, double y0, double x1, double y1, float a) {
    float col[4] = { 0, 0, 0, a };
    double w = x1 - x0;
    if (w < 1.0) return;
    engLine(cv, (x0 + x1) * 0.5, y0, (x0 + x1) * 0.5, y1, (float)w, col);
}

static void engCornerBox(void *cv, double x0, double y0, double x1, double y1, double th, const float *col) {
    double lw = (x1 - x0) / 4.0, lh = (y1 - y0) / 4.0;
    engLine(cv, x0, y0, x0 + lw, y0, (float)th, col); engLine(cv, x0, y0, x0, y0 + lh, (float)th, col);
    engLine(cv, x1, y0, x1 - lw, y0, (float)th, col); engLine(cv, x1, y0, x1, y0 + lh, (float)th, col);
    engLine(cv, x1, y1, x1 - lw, y1, (float)th, col); engLine(cv, x1, y1, x1, y1 - lh, (float)th, col);
    engLine(cv, x0, y1, x0 + lw, y1, (float)th, col); engLine(cv, x0, y1, x0, y1 - lh, (float)th, col);
}

static void engCircle(void *cv, double cx, double cy, double r, int seg, double th, const float *col) {
    for (int i = 0; i < seg; i++) {
        double a0 = i * 2.0 * M_PI / seg, a1 = (i + 1) * 2.0 * M_PI / seg;
        engLine(cv, cx + cos(a0) * r, cy + sin(a0) * r, cx + cos(a1) * r, cy + sin(a1) * r, (float)th, col);
    }
}

static uintptr_t gAimPawn = 0;
static int gAimApplied = 0, gAimTargetFrames = 0, gDrawnPlayers = 0, gDbgAds = 0, gDbgAdsFlag = 0;
static int gDbgTargetingFrames = 0, gDbgCand = 0, gDbgInFov = 0, gDbgDownedSkip = 0, gDbnoSeen = 0, gDbnoSet = 0;
static double gDbgFov = 0, gDbgBase = 0;
static double gAimScreenX = 0, gAimScreenY = 0;

static void engineEspFrame(void *cv) {
    int sx = rd_i32((uintptr_t)cv + 0x40), sy = rd_i32((uintptr_t)cv + 0x44);
    if (sx < 200 || sy < 200 || sx > 8000 || sy > 8000) return;
    NSArray<EchoPawn *> *pawns; uintptr_t pc, lp;
    @synchronized ([NSProcessInfo processInfo]) { pawns = gPawns; pc = gLocalPC; lp = gLocalPawn; }
    if (!pc || !pawns.count) { gAimPawn = 0; return; }
    CGSize sz = CGSizeMake(sx, sy);
    gScreenSz = sz;
    DV3 cam, rot; float fov, ts;
    if (!readCameraStable(pc, &cam, &rot, &fov, &ts)) return;
    CFTimeInterval now = CACurrentMediaTime();

    if (gVPOff < 0 && gVPTries < 400) { gVPTries++; vpProbe(cv, cam, rot, fov); }
    const double *vpm = NULL;
    if (gVPOff >= 0 && vpRead(cv, gVPOff, gVPDbl, gVPm)) vpm = gVPm;
    tVP = vpm;
    EchoView view = makeView(cam, rot, fov, sz);
    tVP = NULL;

    double sc = sx / 1000.0;
    if (sc < 1.0) sc = 1.0;
    const float cPrimary[4] = { 1.0f, 0.0f, 0.0f, 1.0f };
    const float cSecondary[4] = { 0.0f, 0.47f, 1.0f, 1.0f };
    double fovRad = fov * M_PI / 180.0;
    double ppd = sx / ((2.0 * tan(0.5 * fovRad)) * 180.0 / M_PI);
    double fovDeg = gOptFov * 60.0;
    double dzDeg = fmin(0.6, fovDeg * 0.05);
    double smoothS = 1.0 + gOptSmooth * 30.0;
    static CFTimeInterval lastT = 0;
    double elapsed = lastT > 0 ? now - lastT : 1.0 / 60.0;
    lastT = now;
    if (elapsed < 0.002) elapsed = 0.002;
    if (elapsed > 0.1) elapsed = 0.1;
    double effSmooth = 1.0 + (smoothS - 1.0) * ((1.0 / 60.0) / elapsed);
    if (effSmooth < 1.0) effSmooth = 1.0;

    static double fovBase = 0;
    if (fov > fovBase) fovBase = fov; else fovBase -= 0.4 * elapsed;
    if (fovBase < fov) fovBase = fov;
    BOOL adsFlag = (O_ADS >= 0) && lp && pawnFlag(lp, O_ADS, M_ADS);
    static BOOL lastAdsFlag = NO;
    static int adsEdges = 0;
    if (adsFlag != lastAdsFlag) {
        lastAdsFlag = adsFlag;
        if (adsEdges++ < 30) metalNote([NSString stringWithFormat:@"aim: ADS flag %@ (fov %.1f)", adsFlag ? @"ON" : @"off", fov]);
    }
    BOOL ads = adsFlag;
    gDbgAds = ads; gDbgAdsFlag = adsFlag; gDbgFov = fov; gDbgBase = fovBase;
    BOOL targeting = gOptAimbot && (ads || !gOptAdsOnly);
    if (targeting) gDbgTargetingFrames++;
    int aimSlot = gOptAimBody ? 15 : 0;

    uintptr_t bestPawn = 0;
    double bestMetric = 1e30, bestPix = 0, bestDeg = 0, bestDist = 0, bestSX = 0, bestSY = 0;
    DV3 bestPos = {0, 0, 0};
    BOOL bestDead = NO, curStillValid = NO;
    uintptr_t curPawn = gAimPawn;
    double curMetric = 0, curPix = 0, curDeg = 0, curSX = 0, curSY = 0;
    DV3 curPos = {0, 0, 0};

    CGFloat cx0 = sx * 0.5, cy0 = sy * 0.5;
    uintptr_t trigCand = 0;
    double trigBest = 1e30;

    for (EchoPawn *ep in pawns) {
        if (pawnFlag(ep.pawn, O_DYING, M_DYING)) continue;
        if (ep.team) continue;
        BOOL downedRaw = pawnFlag(ep.pawn, O_DBNO, M_DBNO);
        gDbnoSeen++; if (downedRaw) gDbnoSet++;
        if (gDbnoSeen > 4000) { gDbnoSeen /= 2; gDbnoSet /= 2; }
        BOOL dbnoInvalid = (gDbnoSeen > 60 && gDbnoSet * 2 > gDbnoSeen);
        BOOL downed = downedRaw && !dbnoInvalid;
        DV3 root;
        if (!actorLocation(ep.pawn, &root)) continue;
        double ddx = root.x - cam.x, ddy = root.y - cam.y, ddz = root.z - cam.z;
        double distM = sqrt(ddx * ddx + ddy * ddy + ddz * ddz) / 100.0;
        if (distM >= 300.0) continue;

        RaaxBones rb;
        BOOL haveB = raaxBones(ep, &rb);
        DV3 corners[8];
        if (haveB) {
            double minX = 1e30, maxX = -1e30, minY = 1e30, maxY = -1e30, minZ = 1e30, maxZ = -1e30;
            for (int i = 0; i < 16; i++) {
                DV3 b = rb.w[i];
                if (b.x < minX) minX = b.x; if (b.x > maxX) maxX = b.x;
                if (b.y < minY) minY = b.y; if (b.y > maxY) maxY = b.y;
                if (b.z < minZ) minZ = b.z; if (b.z > maxZ) maxZ = b.z;
            }
            double hm = (maxX - minX) * 0.2, vm = (maxY - minY) * 0.2, dm = (maxZ - minZ) * 0.125;
            corners[0] = (DV3){ minX - hm, minY - vm, maxZ + dm };
            corners[1] = (DV3){ maxX + hm, minY - vm, maxZ + dm };
            corners[2] = (DV3){ minX - hm, maxY + vm, maxZ + dm };
            corners[3] = (DV3){ maxX + hm, maxY + vm, maxZ + dm };
            corners[4] = (DV3){ minX - hm, minY - vm, minZ - dm };
            corners[5] = (DV3){ maxX + hm, minY - vm, minZ - dm };
            corners[6] = (DV3){ minX - hm, maxY + vm, minZ - dm };
            corners[7] = (DV3){ maxX + hm, maxY + vm, minZ - dm };
        } else {
            for (int i = 0; i < 8; i++)
                corners[i] = (DV3){ root.x + ((i & 1) ? 40.0 : -40.0), root.y + ((i & 2) ? 40.0 : -40.0), root.z + ((i & 4) ? 100.0 : -100.0) };
        }
        double bx0 = 1e30, by0 = 1e30, bx1 = -1e30, by1 = -1e30;
        BOOL cornersOk = YES;
        for (int i = 0; i < 8; i++) {
            CGFloat nx, ny; float dp;
            if (!project(&view, corners[i], &nx, &ny, &dp)) { cornersOk = NO; break; }
            double px = nx * sx, py = ny * sy;
            if (px < bx0) bx0 = px; if (px > bx1) bx1 = px;
            if (py < by0) by0 = py; if (py > by1) by1 = py;
        }
        BOOL onScreen = cornersOk && !(bx1 < 0 || bx0 > sx || by1 < 0 || by0 > sy);
        double bw = bx1 - bx0, bh = by1 - by0;
        if (onScreen && bw > 2.0 && bh > 2.0 && bw < sx * 4.0 && bh < sy * 4.0) {
            gDrawnPlayers++;
            if (gOptTrigger && !downed) {
                double mx = bw * 0.14, my = bh * 0.10;
                if (cx0 >= bx0 + mx && cx0 <= bx1 - mx && cy0 >= by0 + my && cy0 <= by1 - my) {
                    double dd = distM;
                    if (dd < trigBest) { trigBest = dd; trigCand = ep.pawn; }
                }
            }
            if (gOptBoxes) {
                engCornerBox(cv, bx0, by0, bx1, by1, 2.0 * sc, cPrimary);
            }
            if (gOptSkeleton && haveB) {
                CGPoint scr[16]; BOOL sok[16];
                for (int i = 0; i < 16; i++) {
                    CGFloat nx, ny; float dp;
                    sok[i] = project(&view, rb.w[i], &nx, &ny, &dp);
                    if (sok[i]) scr[i] = CGPointMake(nx * sx, ny * sy);
                }
                for (int i = 0; i < 15; i++) {
                    int a = kRaaxPairs[i][0], b = kRaaxPairs[i][1];
                    if (sok[a] && sok[b]) engLine(cv, scr[a].x, scr[a].y, scr[b].x, scr[b].y, (float)(1.0 * sc), cSecondary);
                }
            }
            double midX = (bx0 + bx1) * 0.5;
            double fh = 16.0 * sc;
            if (gOptTags && ep.tag.length) {
                engText(cv, ep.tag, midX, by0 - 2.0, 2.6 * sc, 1.1 * sc, cPrimary);
            }
            double bottomY = by1 + 2.0 + fh;
            if (gOptWeaponEsp && ep.weapon.length) {
                CGFloat r = 1, g = 1, b = 1, a = 1;
                [tierColor(ep.wTier) getRed:&r green:&g blue:&b alpha:&a];
                float wc[4] = { (float)r, (float)g, (float)b, 1.0f };
                engText(cv, ep.weapon, midX, bottomY, 2.6 * sc, 1.1 * sc, wc);
                bottomY += 2.0 + fh;
            }
            if (gOptTags) {
                NSString *d = [NSString stringWithFormat:@"%d m", (int)distM];
                engText(cv, d, midX, bottomY, 2.6 * sc, 1.1 * sc, cPrimary);
            }
        }

        if (targeting && downedRaw && downed) gDbgDownedSkip++;
        if (targeting && !downed) {
            gDbgCand++;
            DV3 tp;
            if (haveB) {
                DV3 a0 = rb.w[aimSlot], a1 = gOptAimBody ? rb.w[2] : rb.w[1];
                double lerpK = gOptAimBody ? 0.30 : 0.35;
                tp = (DV3){ a0.x + (a1.x - a0.x) * lerpK, a0.y + (a1.y - a0.y) * lerpK, a0.z + (a1.z - a0.z) * lerpK };
            } else {
                tp = (DV3){ root.x, root.y, root.z + (gOptAimBody ? 25.0 : 62.0) };
            }
            CGFloat nx, ny; float dp;
            BOOL pOk = project(&view, tp, &nx, &ny, &dp);
            double scx = pOk ? nx * sx : -1.0, scy = pOk ? ny * sy : -1.0;
            double dx = tp.x - cam.x, dy = tp.y - cam.y, dz = tp.z - cam.z;
            double aimYaw = atan2(dy, dx) * 180.0 / M_PI;
            double aimPitch = atan2(dz, sqrt(dx * dx + dy * dy)) * 180.0 / M_PI;
            double dl = sqrt(dx * dx + dy * dy + dz * dz);
            double dotv = dl > 1e-6 ? (dx * view.fwd.x + dy * view.fwd.y + dz * view.fwd.z) / dl : 1.0;
            if (dotv > 1.0) dotv = 1.0; if (dotv < -1.0) dotv = -1.0;
            double degDist = acos(dotv) * 180.0 / M_PI;
            double pixDist = hypot(scx - cx0, scy - cy0);
            double metric = degDist + distM * 0.25;
            BOOL onS = pOk && scx >= 0 && scx <= sx && scy >= 0 && scy <= sy;
            BOOL inFov = onS ? (pixDist <= fovDeg * ppd) : (degDist <= fovDeg);
            if (inFov) {
                gDbgInFov++;
                if (ep.pawn == curPawn) { curStillValid = YES; curMetric = metric; curPix = onS ? pixDist : 1e9; curDeg = degDist; curSX = scx; curSY = scy; curPos = (DV3){ aimYaw, aimPitch, onS ? 1.0 : 0.0 }; }
                if (metric < bestMetric) {
                    bestMetric = metric; bestPawn = ep.pawn; bestPix = onS ? pixDist : 1e9; bestDeg = degDist; bestSX = scx; bestSY = scy;
                    bestPos = (DV3){ aimYaw, aimPitch, onS ? 1.0 : 0.0 };
                }
            }
        }
        (void)bestDead; (void)bestDist;
    }

    if (gOptLoot || gOptChest) {
        NSArray<EchoLoot *> *lootNow = gLoot;
        int drawnLoot = 0;
        for (EchoLoot *lo in lootNow) {
            if (drawnLoot >= 140) break;
            BOOL isChest = lo.tier < 0;
            if (isChest ? !gOptChest : !gOptLoot) continue;
            double ddx = lo.x - cam.x, ddy = lo.y - cam.y, ddz = lo.z - cam.z;
            double dm = sqrt(ddx * ddx + ddy * ddy + ddz * ddz) / 100.0;
            if (dm > (isChest ? 250.0 : 150.0) || dm < 0.5) continue;
            CGFloat nx, ny; float dp;
            if (!project(&view, (DV3){ lo.x, lo.y, lo.z }, &nx, &ny, &dp)) continue;
            double px = nx * sx, py = ny * sy;
            if (px < 0 || px > sx || py < 0 || py > sy) continue;
            float col[4] = { 1, 1, 1, 1 };
            if (lo.tier == -2) { col[0] = 1.0f; col[1] = 0.85f; col[2] = 0.2f; }
            else if (lo.tier == -3) { col[0] = 0.7f; col[1] = 0.7f; col[2] = 0.7f; }
            else if (lo.tier == -4) { col[0] = 0.3f; col[1] = 1.0f; col[2] = 1.0f; }
            else if (lo.tier == -5) { col[0] = 1.0f; col[1] = 0.45f; col[2] = 0.1f; }
            else { CGFloat r = 1, g = 1, b = 1, a2 = 1; [tierColor(lo.tier) getRed:&r green:&g blue:&b alpha:&a2]; col[0] = (float)r; col[1] = (float)g; col[2] = (float)b; }
            double arm = 4.0 * sc;
            engLine(cv, px - arm, py, px + arm, py, (float)(1.5 * sc), col);
            engLine(cv, px, py - arm, px, py + arm, (float)(1.5 * sc), col);
            NSString *lt = [NSString stringWithFormat:@"%@ %dm", lo.text, (int)dm];
            engText(cv, lt, px, py - arm - 1.0, 2.2 * sc, 1.0 * sc, col);
            drawnLoot++;
        }
    }

    if (gOptAimbot && gOptShowFov) {
        float white[4] = { 1, 1, 1, 1 }, red[4] = { 1, 0, 0, 1 };
        engCircle(cv, cx0, cy0, fovDeg * ppd, 64, 1.0 * sc, white);
        engCircle(cv, cx0, cy0, dzDeg * ppd, 32, 1.0 * sc, red);
    }

    uintptr_t useTarget = 0;
    double aY = 0, aP = 0, tPix = 0, tSX = 0, tSY = 0;
    if (curStillValid && curPawn) {
        useTarget = curPawn; aY = curPos.x; aP = curPos.y; tPix = curPix; tSX = curSX; tSY = curSY;
    }
    if (!useTarget || !(targeting && true)) {
        if (bestPawn) { useTarget = bestPawn; aY = bestPos.x; aP = bestPos.y; tPix = bestPix; tSX = bestSX; tSY = bestSY; }
    }
    if (curStillValid && bestPawn && bestPawn != curPawn && bestMetric < curMetric - 1e-9 && !targeting) {
        useTarget = bestPawn; aY = bestPos.x; aP = bestPos.y; tPix = bestPix; tSX = bestSX; tSY = bestSY;
    }
    gAimPawn = targeting ? useTarget : (bestPawn ? bestPawn : 0);
    (void)bestDeg; (void)curDeg;

    if (useTarget && gOptAimbot && gOptShowFov && tSX >= 0 && tSY >= 0) {
        float lc[4] = { 1, 0, 0, 1 };
        engLine(cv, cx0, cy0, tSX, tSY, (float)(1.0 * sc), lc);
    }

    if (useTarget) gAimTargetFrames++;
    static double aimSign = 1.0, lastRP = 0, lastRY = 0, lastNP = 0, lastNY = 0;
    static double accNom = 0, accObs = 0;
    static int accN = 0, weakWin = 0;
    static BOOL directMode = NO, lastApplied = NO;
    BOOL appliedNow = NO;
    if (useTarget && targeting && looks_like_uobject(pc)) {
        static BOOL wasDead = NO;
        BOOL inDead = (tPix <= dzDeg * ppd * (wasDead ? 1.8 : 1.0));
        wasDead = inDead;
        if (lastApplied) {
            double obsP = wrap180(rot.x - lastRP), obsY = wrap180(rot.y - lastRY);
            BOOL useYaw = fabs(lastNY) > fabs(lastNP);
            double nomV = useYaw ? lastNY : lastNP, obsV = useYaw ? obsY : obsP;
            if (!directMode && fabs(nomV) > 0.3) {
                accNom += fabs(nomV);
                accObs += obsV * (nomV > 0 ? 1.0 : -1.0);
                if (++accN >= 40) {
                    double ratio = accObs / accNom;
                    if (ratio < -0.25) {
                        aimSign = -aimSign; weakWin = 0;
                        metalNote(@"aim: response was inverted, flipped input sign");
                    } else if (ratio < 0.12) {
                        if (++weakWin == 2) metalNote(@"aim: input response looks weak (not switching)");
                    } else weakWin = 0;
                    accNom = accObs = 0; accN = 0;
                }
            }
        }
        if (!inDead) {
            double dP = wrap180(aP - wrap180(rot.x)), dY = wrap180(aY - wrap180(rot.y));
            if (directMode && O_CTRL_ROT >= 0) {
                DV3 cur;
                if (safe_read(pc + (uintptr_t)O_CTRL_ROT, &cur, sizeof cur) && sane_dv(cur)) {
                    double cP = wrap180(aP - wrap180(cur.x)) / effSmooth, cY = wrap180(aY - wrap180(cur.y)) / effSmooth;
                    DV3 nr = { cur.x + cP, cur.y + cY, cur.z };
                    memcpy((void *)(pc + (uintptr_t)O_CTRL_ROT), &nr, sizeof nr);
                    appliedNow = YES; gAimApplied++; gDiagLock = YES;
                }
            } else {
                if (lastApplied) {
                    double obsP2 = wrap180(rot.x - lastRP), obsY2 = wrap180(rot.y - lastRY);
                    double pendP = lastNP - obsP2, pendY = lastNY - obsY2;
                    if (pendP * lastNP < 0) pendP = 0; else if (fabs(pendP) > fabs(lastNP)) pendP = lastNP;
                    if (pendY * lastNY < 0) pendY = 0; else if (fabs(pendY) > fabs(lastNY)) pendY = lastNY;
                    dP -= pendP; dY -= pendY;
                }
                dP /= effSmooth; dY /= effSmooth;
                lastRP = rot.x; lastRY = rot.y; lastNP = dP; lastNY = dY;
                float yawScale = 0, pitchScale = 0;
                safe_read(pc + 0x4c0, &yawScale, 4);
                safe_read(pc + 0x4c4, &pitchScale, 4);
                if (!(fabsf(yawScale) > 1e-4f) || !isfinite(yawScale)) yawScale = 1.0f;
                if (!(fabsf(pitchScale) > 1e-4f) || !isfinite(pitchScale)) pitchScale = 1.0f;
                void **vt = (void **)rd_ptr(pc);
                uintptr_t fPitch = vt ? rd_ptr((uintptr_t)&vt[420]) : 0;
                uintptr_t fYaw = vt ? rd_ptr((uintptr_t)&vt[421]) : 0;
                if (fPitch >= gImgBase && fPitch < gImgEnd && fYaw >= gImgBase && fYaw < gImgEnd) {
                    ((void (*)(void *, float))fPitch)((void *)pc, (float)(aimSign * dP / pitchScale));
                    ((void (*)(void *, float))fYaw)((void *)pc, (float)(aimSign * dY / yawScale));
                    appliedNow = YES; gAimApplied++; gDiagLock = YES;
                }
            }
        } else {
            gDiagLock = NO;
        }
    } else {
        gDiagLock = NO;
    }
    lastApplied = appliedNow;

    {
        static uintptr_t trigPawn = 0;
        static CFTimeInterval trigSeen = 0, trigLast = 0;
        static BOOL losWarned = NO;
        if (gOptTrigger && trigCand && lp && looks_like_uobject(pc)) {
            gTrigCand++;
            if (trigPawn != trigCand) { trigPawn = trigCand; trigSeen = now; }
            BOOL los = NO;
            void **pvt = (void **)rd_ptr(pc);
            uintptr_t fLos = pvt ? rd_ptr((uintptr_t)&pvt[237]) : 0;
            if (fLos >= gImgBase && fLos < gImgEnd) {
                los = (((BOOL (*)(void *, void *, double, double, double, BOOL))fLos)((void *)pc, (void *)trigCand, 0.0, 0.0, 0.0, YES) & 1) != 0;
            } else if (!losWarned) { losWarned = YES; metalNote(@"trigger: line-of-sight function not found, trigger disabled"); }
            if (los) gTrigLos++;
            if (los && (now - trigSeen) >= (double)gOptTrigDelay * 0.3 && (now - trigLast) >= 0.035) {
                void **lvt = (void **)rd_ptr(lp);
                uintptr_t fStart = lvt ? rd_ptr((uintptr_t)&lvt[233]) : 0;
                uintptr_t fStop = lvt ? rd_ptr((uintptr_t)&lvt[477]) : 0;
                if (fStart >= gImgBase && fStart < gImgEnd && fStop >= gImgBase && fStop < gImgEnd) {
                    ((void (*)(void *, uint8_t))fStart)((void *)lp, 0);
                    ((void (*)(void *, uint8_t))fStop)((void *)lp, 0);
                    trigLast = now;
                    gTrigFires++;
                    if (gTrigFires <= 3 || gTrigFires % 100 == 0) metalNote([NSString stringWithFormat:@"trigger: fire #%d (cand %d, los %d)", gTrigFires, gTrigCand, gTrigLos]);
                }
            }
        } else {
            trigPawn = 0;
        }
    }

    gEngDrawLast = now;
}

static BOOL looksCanvas(void *cv) {
    uintptr_t o = (uintptr_t)cv;
    if (!looks_like_uobject(o)) return NO;
    uintptr_t cls = rd_ptr(o + (uintptr_t)gOffClass);
    if (cls && cls == gCanvasCls) return YES;
    NSString *n = fname_string(fnidx(cls + (uintptr_t)gOffName));
    if (n && [n.lowercaseString containsString:@"canvas"]) { gCanvasCls = cls; return YES; }
    return NO;
}

static void h_DrawTransition(void *self, void *canvas) {
    if (looksCanvas(canvas)) {
        gDTBad = 0;
        if (gOptEngineDraw) {
            @autoreleasepool { engineEspFrame(canvas); }
        }
        gDTFrames++;
        if (gDTFrames == 1 || gDTFrames % 900 == 0)
            metalNote([NSString stringWithFormat:@"engine draw: frame %d canvas %p players drawn %d aim target frames %d applied %d vp %d ads %d (flag %d) fov %.1f base %.1f | bones ok %d fail nobones %d nomesh %d noloc %d c2w %d skel %d xform %d slot %d sane %d | aim: enabled %d targetingFrames %d candidates %d inFov %d downedSkips %d dbnoSet %d/%d fovDeg %.1f | skelOff %d direct %d", gDTFrames, canvas, gDrawnPlayers, gAimTargetFrames, gAimApplied, gVPOff, gDbgAds, gDbgAdsFlag, gDbgFov, gDbgBase, gRbOk, gRbFail[0], gRbFail[1], gRbFail[2], gRbFail[3], gRbFail[4], gRbFail[5], gRbFail[6], gRbFail[7], (int)gOptAimbot, gDbgTargetingFrames, gDbgCand, gDbgInFov, gDbgDownedSkip, gDbnoSet, gDbnoSeen, gOptFov * 60.0, gSkelOff, (int)gSkelDirect]);
    } else if (++gDTBad > 40 && gDTSlot) {
        *gDTSlot = (void *)gDTOrig;
        gDTSlot = NULL;
        metalNote(@"engine draw: slot was not DrawTransition, restored");
    }
    gDTOrig(self, canvas);
}

static void installEngineHook(void) {
    if (gDTHooked) return;
    gDTHooked = YES;
    uintptr_t vp = gEngineObj ? rd_ptr(gEngineObj + (uintptr_t)O_ENGINE_VIEWPORT) : 0;
    if (!looks_like_uobject(vp)) { metalNote(@"engine hook: no viewport object"); return; }
    void **vt = (void **)rd_ptr(vp);
    if (!vt) { metalNote(@"engine hook: no vtable"); return; }
    int giOff = propOff(gCls[C_VIEWPORT], "GameInstance");
    int supOff = giOff >= 0 ? giOff + 8 : 0x80;
    NSMutableString *m = [NSMutableString stringWithFormat:@"engine hook: viewport %p vtable %p (image+0x%lx) flag offset 0x%x", (void *)vp, vt, (unsigned long)((uintptr_t)vt - gSlide), supOff];
    int pick = -1;
    for (int i = 0x20; i < 0xA0; i++) {
        uintptr_t fn = rd_ptr((uintptr_t)&vt[i]);
        if (fn < gImgBase || fn >= gImgEnd) break;
        uint32_t code[48];
        if (!safe_read(fn, code, sizeof code)) continue;
        for (int k = 0; k < 6; k++) {
            uint32_t w = code[k];
            if ((w & 0xFFC00000u) == 0x39400000u && (int)((w >> 10) & 0xFFF) == supOff && ((w >> 5) & 31) == 0) {
                [m appendFormat:@"\n  candidate slot %d fn image+0x%lx (word %d)", i, (unsigned long)(fn - gSlide), k];
                if (pick < 0) pick = i;
                break;
            }
        }
    }
    if (pick < 0) { metalNote([m stringByAppendingString:@"\n  no DrawTransition candidate"]); return; }
    vm_address_t page = (vm_address_t)((uintptr_t)&vt[pick] & ~(uintptr_t)0x3FFF);
    kern_return_t kr = vm_protect(mach_task_self(), page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) { metalNote([m stringByAppendingFormat:@"\n  vm_protect failed %d", kr]); return; }
    gDTOrig = (DTFn)vt[pick];
    gDTSlot = &vt[pick];
    vt[pick] = (void *)h_DrawTransition;
    [m appendFormat:@"\n  hooked slot %d", pick];
    metalNote(m);
}

static void applyFrame(EchoFrame *f, CGSize sz) {
    for (NSUInteger i = 0; i < gTagPool.count; i++) gTagPool[i].hidden = YES;
    {
        NSUInteger i = 0;
        for (EchoTag *t in f.tags) {
            UILabel *tag = tagAtIndex(i);
            if (![gTagText[i] isEqualToString:t.text]) {
                gTagText[i] = t.text;
                tag.text = t.text;
                [tag sizeToFit];
                CGSize ts = tag.bounds.size;
                tag.bounds = CGRectMake(0, 0, ts.width + 8, ts.height + 2);
            }
            tag.textColor = t.color ?: [UIColor whiteColor];
            tag.center = CGPointMake(t.c.x, t.c.y - tag.bounds.size.height * 0.5);
            tag.hidden = NO;
            i++;
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    gBoxEnemy.path  = gOptBoxes ? f.eb.CGPath : nil;
    gBoxTeam.path   = gOptBoxes ? f.tb.CGPath : nil;
    gBoneEnemy.path = gOptSkeleton ? f.ebn.CGPath : nil;
    gBoneTeam.path  = gOptSkeleton ? f.tbn.CGPath : nil;
    gFovRing.hidden = !(gOptAimbot && gOptShowFov);
    CGFloat r = gOptFov * sz.height;
    gFovRing.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(sz.width * 0.5 - r, sz.height * 0.5 - r, r * 2, r * 2)].CGPath;
    [CATransaction commit];
}

@interface EchoEspTicker : NSObject
@end
@implementation EchoEspTicker
- (void)tick:(CADisplayLink *)link { drawTick(link); }
@end
static EchoEspTicker *gEspTicker = nil;

static CAShapeLayer *makeShapeLayer(UIColor *c, CGFloat width) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor   = [UIColor clearColor].CGColor;
    l.strokeColor = c.CGColor;
    l.lineWidth   = width;
    l.lineCap     = kCALineCapRound;
    return l;
}

static void installLabelLayer(void) {
    if (gLabelWindow) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gLabelWindow) return;

        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel            = UIWindowLevelAlert + 1;
        w.backgroundColor        = [UIColor clearColor];
        w.userInteractionEnabled = NO;

        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor        = [UIColor clearColor];
        vc.view.userInteractionEnabled = NO;
        w.rootViewController = vc;

        w.hidden = NO;
        attachScene(w);
        gLabelWindow = w;
        gLabelRoot   = vc.view;
        gTagPool     = [NSMutableArray array];
        gTagText     = [NSMutableArray array];

        gBoxEnemy  = makeShapeLayer([UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:1.0], 1.5);
        gBoxTeam   = makeShapeLayer([UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0], 1.5);
        gBoneEnemy = makeShapeLayer([UIColor colorWithRed:1.0 green:0.9 blue:0.2 alpha:1.0], 1.2);
        gBoneTeam  = makeShapeLayer([UIColor colorWithRed:0.4 green:1.0 blue:1.0 alpha:1.0], 1.2);
        gFovRing   = makeShapeLayer([UIColor colorWithWhite:1.0 alpha:0.5], 1.0);
        [gLabelRoot.layer addSublayer:gBoxEnemy];
        [gLabelRoot.layer addSublayer:gBoxTeam];
        [gLabelRoot.layer addSublayer:gBoneEnemy];
        [gLabelRoot.layer addSublayer:gBoneTeam];
        [gLabelRoot.layer addSublayer:gFovRing];

        gEspTicker = [[EchoEspTicker alloc] init];
        gLabelLink = [CADisplayLink displayLinkWithTarget:gEspTicker selector:@selector(tick:)];
        if (@available(iOS 15.0, *)) {
            gLabelLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
        }
        [gLabelLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

        installMetalHooks();
        gSnapLock = [[NSObject alloc] init];
        gSnaps = [NSMutableArray array];
        gScreenSz = [UIScreen mainScreen].bounds.size;
        NSThread *samp = [[NSThread alloc] initWithBlock:^{ samplerMain(); }];
        samp.name = @"echomod.sampler";
        samp.qualityOfService = NSQualityOfServiceUserInteractive;
        [samp start];

        dispatch_queue_t q = dispatch_queue_create("echomod.scan", DISPATCH_QUEUE_SERIAL);
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  250ull * NSEC_PER_MSEC, 50ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(t, ^{ scanPawns(); });
        gScanTimer = t;
        dispatch_resume(t);
    });
}

#pragma mark - 7) floating menu

@interface EchoPassWindow : UIWindow
@end
@implementation EchoPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

static EchoPassWindow *gMenuWindow = nil;
static UIView *gMenuPanel = nil;
static UIView *gMenuButton = nil;

static void saveOptions(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:gOptBoxes forKey:@"echo.boxes"];
    [d setBool:gOptSkeleton forKey:@"echo.skel"];
    [d setBool:gOptTags forKey:@"echo.tags"];
    [d setBool:gOptAimbot forKey:@"echo.aim"];
    [d setBool:gOptAdsOnly forKey:@"echo.ads"];
    [d setBool:gOptShowFov forKey:@"echo.fovring"];
    [d setBool:gOptAimBody forKey:@"echo.body"];
    [d setBool:gOptNoRecoil forKey:@"echo.norecoil"];
    [d setBool:gOptNoSpread forKey:@"echo.nospread"];
    [d setBool:gOptTrigger forKey:@"echo.trigger"];
    [d setBool:gOptChest forKey:@"echo.chest"];
    [d setFloat:gOptTrigDelay forKey:@"echo.trigdelay"];
    [d setBool:gOptHudLayout forKey:@"echo.hudlayout"];
    [d setBool:gOptLowGfx forKey:@"echo.lowgfx"];
    [d setBool:gOptVisOnly forKey:@"echo.vis"];
    [d setBool:gOptAutoSprint forKey:@"echo.sprint"];
    [d setBool:gOptDmg forKey:@"echo.dmg"];
    [d setBool:gOptAutoWeapons forKey:@"echo.autow"];
    [d setFloat:gOptDmgMul forKey:@"echo.dmgmul"];
    [d setFloat:gOptSmooth forKey:@"echo.smooth"];
    [d setFloat:gOptFov forKey:@"echo.fov"];
    [d setFloat:gOptLagF forKey:@"echo.lagf"];
}

static void loadOptions(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:@"echo.smooth"]) return;
    gOptBoxes = [d boolForKey:@"echo.boxes"];
    gOptSkeleton = [d boolForKey:@"echo.skel"];
    gOptTags = [d boolForKey:@"echo.tags"];
    gOptAimbot = [d boolForKey:@"echo.aim"];
    gOptAdsOnly = [d boolForKey:@"echo.ads"];
    gOptShowFov = [d boolForKey:@"echo.fovring"];
    gOptAimBody = [d boolForKey:@"echo.body"];
    gOptNoRecoil = [d boolForKey:@"echo.norecoil"];
    gOptNoSpread = [d boolForKey:@"echo.nospread"];
    gOptTrigger = [d boolForKey:@"echo.trigger"];
    if ([d objectForKey:@"echo.chest"]) gOptChest = [d boolForKey:@"echo.chest"];
    if ([d objectForKey:@"echo.trigdelay"]) gOptTrigDelay = [d floatForKey:@"echo.trigdelay"];
    if ([d objectForKey:@"echo.hudlayout"]) gOptHudLayout = [d boolForKey:@"echo.hudlayout"];
    if ([d objectForKey:@"echo.lowgfx"]) gOptLowGfx = [d boolForKey:@"echo.lowgfx"];
    if ([d objectForKey:@"echo.vis"]) gOptVisOnly = [d boolForKey:@"echo.vis"];
    if ([d objectForKey:@"echo.sprint"]) gOptAutoSprint = [d boolForKey:@"echo.sprint"];
    if ([d objectForKey:@"echo.dmg"]) gOptDmg = [d boolForKey:@"echo.dmg"];
    if ([d objectForKey:@"echo.autow"]) gOptAutoWeapons = [d boolForKey:@"echo.autow"];
    if ([d objectForKey:@"echo.dmgmul"]) gOptDmgMul = [d floatForKey:@"echo.dmgmul"];
    gOptSmooth = [d floatForKey:@"echo.smooth"];
    gOptFov = [d floatForKey:@"echo.fov"];
    if ([d objectForKey:@"echo.lagf"]) gOptLagF = [d floatForKey:@"echo.lagf"];
}

@interface EchoMenuHandler : NSObject
@property (nonatomic, strong) UILabel *smoothLabel;
@property (nonatomic, strong) UILabel *fovLabel;
@property (nonatomic, strong) UILabel *dmgLabel;
@property (nonatomic, strong) UILabel *lagLabel;
@property (nonatomic, strong) UILabel *trigLabel;
@end
@implementation EchoMenuHandler
- (void)toggled:(UISwitch *)s {
    BOOL on = s.isOn;
    switch (s.tag) {
        case 1: gOptBoxes = on; break;
        case 2: gOptSkeleton = on; break;
        case 3: gOptTags = on; break;
        case 4: gOptAimbot = on; break;
        case 5: gOptAdsOnly = on; break;
        case 6: gOptShowFov = on; break;
        case 7: gOptNoRecoil = on; break;
        case 8: gOptNoSpread = on; break;
        case 9: gOptTrigger = on; break;
        case 10: gOptHudLayout = on; break;
        case 11: gOptLowGfx = on; break;
        case 12: gOptVisOnly = on; break;
        case 13: gOptAutoSprint = on; break;
        case 14: gOptPeek = on; break;
        case 15: gOptSilent = on; break;
        case 16: gOptSilentFlick = on; break;
        case 17: gOptBulletTp = on; break;
        case 18: gOptDmg = on; break;
        case 19: gOptAutoWeapons = on; break;
        case 23: gOptLoot = on; break;
        case 34: gOptChest = on; break;
        case 24: gOptWeaponEsp = on; break;
        case 25: gOptEngineDraw = on; break;
    }
    saveOptions();
}
- (void)slid:(UISlider *)s {
    if (s.tag == 20) { gOptSmooth = s.value; self.smoothLabel.text = [NSString stringWithFormat:@"Smoothness  %.0f%%", s.value * 100]; }
    if (s.tag == 22) { gOptDmgMul = s.value; self.dmgLabel.text = [NSString stringWithFormat:@"Damage x%d", 1 + (int)(s.value * 49.0f)]; }
    if (s.tag == 23) { gOptLagF = s.value * 3.0f; self.lagLabel.text = [NSString stringWithFormat:@"ESP lag  %.2f game ticks", gOptLagF]; }
    if (s.tag == 33) { gOptTrigDelay = s.value; self.trigLabel.text = [NSString stringWithFormat:@"Trigger delay  %.0f ms", s.value * 300.0f]; }
    if (s.tag == 21) { gOptFov = s.value; self.fovLabel.text = [NSString stringWithFormat:@"Aim FOV  %.0f%%", s.value * 100]; }
    saveOptions();
}
- (void)picked:(UISegmentedControl *)s {
    if (s.tag == 30) gOptAimBody = (s.selectedSegmentIndex == 1);
    if (s.tag == 32) gOptLootMin = (int)s.selectedSegmentIndex;
    if (s.tag == 31) gOptDelay = (int)s.selectedSegmentIndex;
    saveOptions();
}
- (void)tapped:(UITapGestureRecognizer *)g {
    gMenuPanel.hidden = !gMenuPanel.hidden;
}
- (void)panned:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:gMenuWindow];
    gMenuButton.center = CGPointMake(gMenuButton.center.x + t.x, gMenuButton.center.y + t.y);
    [g setTranslation:CGPointZero inView:gMenuWindow];
    CGRect b = gMenuButton.frame;
    CGRect pf = gMenuPanel.frame;
    pf.origin = CGPointMake(MIN(MAX(b.origin.x - pf.size.width - 8, 4), gMenuWindow.bounds.size.width - pf.size.width - 4),
                            MIN(MAX(b.origin.y, 4), gMenuWindow.bounds.size.height - pf.size.height - 4));
    gMenuPanel.frame = pf;
}
@end

static EchoMenuHandler *gMenuHandler = nil;

static void addSwitch(UIView *parent, CGFloat *y, NSString *title, BOOL on, NSInteger tag) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, *y, 170, 31)];
    l.text = title; l.textColor = [UIColor whiteColor]; l.font = [UIFont systemFontOfSize:14];
    [parent addSubview:l];
    UISwitch *s = [[UISwitch alloc] init];
    s.on = on; s.tag = tag;
    s.transform = CGAffineTransformMakeScale(0.8, 0.8);
    s.center = CGPointMake(parent.bounds.size.width - 14 - 25, *y + 15.5);
    [s addTarget:gMenuHandler action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
    [parent addSubview:s];
    *y += 34;
}

static UILabel *addSlider(UIView *parent, CGFloat *y, NSString *title, float v, NSInteger tag) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, *y, parent.bounds.size.width - 28, 20)];
    l.text = [NSString stringWithFormat:@"%@  %.0f%%", title, v * 100];
    l.textColor = [UIColor whiteColor]; l.font = [UIFont systemFontOfSize:13];
    [parent addSubview:l];
    UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(14, *y + 20, parent.bounds.size.width - 28, 28)];
    s.minimumValue = 0.0f; s.maximumValue = 1.0f; s.value = v; s.tag = tag;
    [s addTarget:gMenuHandler action:@selector(slid:) forControlEvents:UIControlEventValueChanged];
    [parent addSubview:s];
    *y += 52;
    return l;
}

static void addSegment(UIView *parent, CGFloat *y, NSString *title, NSArray *items, NSInteger sel, NSInteger tag) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, *y, parent.bounds.size.width - 28, 20)];
    l.text = title; l.textColor = [UIColor whiteColor]; l.font = [UIFont systemFontOfSize:13];
    [parent addSubview:l];
    UISegmentedControl *s = [[UISegmentedControl alloc] initWithItems:items];
    s.frame = CGRectMake(14, *y + 22, parent.bounds.size.width - 28, 28);
    s.selectedSegmentIndex = sel; s.tag = tag;
    [s addTarget:gMenuHandler action:@selector(picked:) forControlEvents:UIControlEventValueChanged];
    [parent addSubview:s];
    *y += 58;
}

static void installMenu(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gMenuWindow) return;
        loadOptions();

        EchoPassWindow *w = [[EchoPassWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel     = UIWindowLevelAlert + 2;
        w.backgroundColor = [UIColor clearColor];
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        w.rootViewController = vc;
        w.hidden = NO;
        attachScene(w);
        gMenuWindow = w;
        gMenuHandler = [[EchoMenuHandler alloc] init];

        CGSize ss = w.bounds.size;
        UIView *btn = [[UIView alloc] initWithFrame:CGRectMake(ss.width - 66, 110, 46, 46)];
        btn.backgroundColor = [UIColor colorWithRed:0.1 green:0.45 blue:1.0 alpha:0.85];
        btn.layer.cornerRadius = 23;
        btn.layer.borderColor = [UIColor whiteColor].CGColor;
        btn.layer.borderWidth = 1.5;
        UILabel *bl = [[UILabel alloc] initWithFrame:btn.bounds];
        bl.text = @"E"; bl.textAlignment = NSTextAlignmentCenter;
        bl.textColor = [UIColor whiteColor]; bl.font = [UIFont boldSystemFontOfSize:20];
        [btn addSubview:bl];
        [btn addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:gMenuHandler action:@selector(tapped:)]];
        [btn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gMenuHandler action:@selector(panned:)]];
        [vc.view addSubview:btn];
        gMenuButton = btn;

        CGFloat pw = 270;
        UIScrollView *panel = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, pw, 100)];
        panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
        panel.layer.cornerRadius = 14;
        panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
        panel.layer.borderWidth = 1.0;

        CGFloat y = 10;
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, y, pw - 28, 24)];
        title.text = @"sniga  ·  made by kumailala"; title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:17];
        [panel addSubview:title];
        y += 32;

        addSwitch(panel, &y, @"Engine draw (exact lock, no delay)", gOptEngineDraw, 25);
        addSwitch(panel, &y, @"Box ESP", gOptBoxes, 1);
        addSwitch(panel, &y, @"Skeleton ESP", gOptSkeleton, 2);
        addSwitch(panel, &y, @"Name / distance", gOptTags, 3);
        addSwitch(panel, &y, @"Aimbot", gOptAimbot, 4);
        addSwitch(panel, &y, @"Only while aiming (ADS)", gOptAdsOnly, 5);
        addSwitch(panel, &y, @"Show aim FOV circle", gOptShowFov, 6);
        addSwitch(panel, &y, @"Trigger bot (fires on enemy in crosshair)", gOptTrigger, 9);
        addSwitch(panel, &y, @"Force low graphics (next launch)", gOptLowGfx, 11);
        addSwitch(panel, &y, @"Weapon ESP (rarity colour)", gOptWeaponEsp, 24);
        addSwitch(panel, &y, @"Loot ESP", gOptLoot, 23);
        addSwitch(panel, &y, @"Chest / ammo / llama / cannon ESP", gOptChest, 34);
        addSegment(panel, &y, @"Loot min rarity", @[ @"Rare+", @"Epic+", @"Legendary+" ], gOptLootMin, 32);
        addSegment(panel, &y, @"Aim at", @[ @"Head", @"Body" ], gOptAimBody ? 1 : 0, 30);
        gMenuHandler.smoothLabel = addSlider(panel, &y, @"Smoothness", gOptSmooth, 20);
        gMenuHandler.fovLabel = addSlider(panel, &y, @"Aim FOV", gOptFov, 21);
        gMenuHandler.trigLabel = addSlider(panel, &y, @"Trigger delay", gOptTrigDelay, 33);
        gMenuHandler.trigLabel.text = [NSString stringWithFormat:@"Trigger delay  %.0f ms", gOptTrigDelay * 300.0f];
        gMenuHandler.lagLabel = addSlider(panel, &y, @"ESP lag", gOptLagF / 3.0f, 23);
        gMenuHandler.lagLabel.text = [NSString stringWithFormat:@"ESP lag  %.2f game ticks", gOptLagF];

        panel.contentSize = CGSizeMake(pw, y + 8);
        CGFloat ph = MIN(y + 8, ss.height - 40);
        CGRect b = btn.frame;
        panel.frame = CGRectMake(MIN(MAX(b.origin.x - pw - 8, 4), ss.width - pw - 4), MIN(MAX(b.origin.y, 4), ss.height - ph - 4), pw, ph);
        panel.hidden = YES;
        [vc.view addSubview:panel];
        gMenuPanel = panel;
    });
}

#pragma mark - 8) image bounds / slide

static void probeEngine(void) {
    const struct mach_header_64 *h = NULL;
    intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header_64 *c = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (c && c->filetype == MH_EXECUTE) { h = c; slide = _dyld_get_image_vmaddr_slide(i); break; }
    }
    if (!h) return;
    gSlide = slide;

    uintptr_t hi = (uintptr_t)h;
    const struct load_command *lc = (const struct load_command *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *s = (const struct segment_command_64 *)lc;
            if (s->vmsize && strcmp(s->segname, "__PAGEZERO") != 0) {
                uintptr_t end = (uintptr_t)((intptr_t)(s->vmaddr + s->vmsize) + slide);
                if (end > hi) hi = end;
            }
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    gImgBase = (uintptr_t)h;
    gImgEnd  = hi;
    gProbeInRange = (gImgEnd > gImgBase);

    NSLog(@"[EchoMod] image base=%p end=%p slide=%ld", (void *)gImgBase, (void *)gImgEnd, (long)slide);
}



#pragma mark - 8b) fullscreen diagnostics + fix

static UIView *findMetalView(UIView *v) {
    if ([v.layer isKindOfClass:[CAMetalLayer class]]) return v;
    for (UIView *sub in v.subviews) {
        UIView *r = findMetalView(sub);
        if (r) return r;
    }
    return nil;
}

static void updateScreenDiag(void) {
    static CFTimeInterval lastFix = 0;
    UIScreen *sc = UIScreen.mainScreen;
    CGRect b = sc.bounds, nb = sc.nativeBounds;
    gScreenDiagA = [NSString stringWithFormat:@"scr %.0fx%.0f nat %.0fx%.0f x%.1f", b.size.width, b.size.height, nb.size.width, nb.size.height, sc.scale];

    UIWindow *gw = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scn in UIApplication.sharedApplication.connectedScenes) {
            if (![scn isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scn).windows) {
                if (w == gOverlay || w == gPlatOverlay || w == gLabelWindow || w == gMenuWindow) continue;
                if (!gw || w.windowLevel < gw.windowLevel) gw = w;
            }
        }
    }
    if (!gw) { gScreenDiagB = @"win: none"; return; }

    UIView *root = gw.rootViewController.view ?: gw;
    UIView *mv = findMetalView(root);
    CGSize dr = CGSizeZero;
    if (mv) dr = ((CAMetalLayer *)mv.layer).drawableSize;
    gScreenDiagB = [NSString stringWithFormat:@"win %.0fx%.0f root %.0fx%.0f mv %.0fx%.0f dr %.0fx%.0f",
                    gw.frame.size.width, gw.frame.size.height, root.frame.size.width, root.frame.size.height,
                    mv ? mv.frame.size.width : 0, mv ? mv.frame.size.height : 0, dr.width, dr.height];

    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastFix < 2.0) return;
    lastFix = now;
    if (!CGRectEqualToRect(gw.frame, b)) gw.frame = b;
    if (root != gw && !CGRectEqualToRect(root.frame, gw.bounds)) root.frame = gw.bounds;
    if (mv && mv != root && !CGRectEqualToRect(mv.frame, root.bounds)) mv.frame = root.bounds;
}

#pragma mark - 9) force low graphics (config files, applied before the engine reads them)

static void forceLowGraphics(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL low = ([d objectForKey:@"echo.lowgfx"] && [d boolForKey:@"echo.lowgfx"]);

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) return;
    NSString *dir = [docs stringByAppendingPathComponent:@"FortniteGame/Saved/Config/IOS"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dir2 = [docs stringByAppendingPathComponent:@"Saved/Config/IOS"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir2 withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *ctl =
        @"[/Script/IOSRuntimeSettings.IOSRuntimeSettings]\n"
        @"bAllowControllers=True\n"
        @"bGameSupportsMultipleActiveControllers=True\n\n";

    NSString *engine = ctl;
    if (low) {
        engine = [ctl stringByAppendingString:
            @"[/Script/IOSRuntimeSettings.IOSRuntimeSettings]\n"
            @"FrameRateLock=PUFRL_60\n\n"
            @"[/Script/Engine.Engine]\n"
            @"bSmoothFrameRate=False\n"
            @"bUseFixedFrameRate=False\n\n"
            @"[SystemSettings]\n"
            @"t.MaxFPS=120\n"
            @"sg.ResolutionQuality=100\n"
            @"sg.ViewDistanceQuality=0\n"
            @"sg.AntiAliasingQuality=0\n"
            @"sg.ShadowQuality=0\n"
            @"sg.PostProcessQuality=0\n"
            @"sg.TextureQuality=0\n"
            @"sg.EffectsQuality=0\n"
            @"sg.FoliageQuality=0\n"];
    }
    NSString *profiles = low ?
        @"[IPhoneX DeviceProfile]\n"
        @"+CVars=sg.ResolutionQuality=100\n"
        @"+CVars=sg.ViewDistanceQuality=0\n"
        @"+CVars=sg.AntiAliasingQuality=0\n"
        @"+CVars=sg.ShadowQuality=0\n"
        @"+CVars=sg.PostProcessQuality=0\n"
        @"+CVars=sg.TextureQuality=0\n"
        @"+CVars=sg.EffectsQuality=0\n"
        @"+CVars=sg.FoliageQuality=0\n" : @"";
    for (NSString *dd in @[ dir, dir2 ]) {
        [engine writeToFile:[dd stringByAppendingPathComponent:@"Engine.ini"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [ctl writeToFile:[dd stringByAppendingPathComponent:@"Game.ini"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [ctl writeToFile:[dd stringByAppendingPathComponent:@"Input.ini"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [profiles writeToFile:[dd stringByAppendingPathComponent:@"DeviceProfiles.ini"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

#pragma mark - init

__attribute__((constructor)) static void EchoModInit(void) {
    NSLog(@"[EchoMod] dylib loaded — constructor ran");
    forceLowGraphics();

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
            probeEngine();
            installOverlay();
            installPlatformOverlay();
            installLabelLayer();
            installMenu();
            showLoadedAlert(0);
        });
    }];
}
