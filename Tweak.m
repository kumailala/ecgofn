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
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <mach/mach.h>
#include <dlfcn.h>
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
static BOOL gOptLoot = YES, gOptWeaponEsp = YES;
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
            updateScreenDiag();
            NSString *eng = gDiagEngine ? @"ok" : (gProbeInRange ? @"no-obj" : @"NO");
            setPlatLines(@[
                @"[EchoMod] tap E for menu",
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


#pragma mark - 5) engine layer (UE5 / Fortnite 43.10, everything resolved at runtime)

// The only address taken from the binary is GUObjectArray (found by following the
// "Max UObject count is invalid" string to FUObjectArray::AllocateObjectPool and the caller that
// passes the global). The name pool, every class, every property offset and the engine instance
// are discovered at runtime through the game's own reflection data and logged to
// Documents/EchoMod43_diag.txt, so a wrong guess shows up there instead of crashing.

#define A_GUOBJECTARRAY 0x1131d8780ULL
#define SYM(va) ((uintptr_t)((intptr_t)(va) + gSlide))

static BOOL  gOptBoxes = YES, gOptSkeleton = YES, gOptTags = YES;
static BOOL  gOptAimbot = YES, gOptAdsOnly = NO, gOptShowFov = YES;
static BOOL  gOptAimBody = NO;
static BOOL  gOptNoRecoil = NO, gOptNoSpread = NO, gOptTrigger = NO;
static BOOL  gOptHudLayout = NO;
static BOOL  gOptLowGfx = NO;
static BOOL  gOptVisOnly = NO;
static BOOL  gOptAutoSprint = NO;
static BOOL  gOptPeek = NO;
static float gOptSmooth = 0.35f;
static float gOptFov = 0.30f;
static int   gOptDelay = 1;

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

static int gNameStride = 2, gNameTextOff = 2;

static BOOL fname_read(int32_t idx, char *out, int cap) {
    if (!gNameBlocks || idx < 0 || cap < 2) return NO;
    uintptr_t blk = rd_ptr(gNameBlocks + 8 * (uintptr_t)((uint32_t)idx >> 16));
    if (!blk) return NO;
    uintptr_t e = blk + (uintptr_t)gNameStride * (uintptr_t)((uint32_t)idx & 0xFFFF);
    uint16_t h = 0;
    if (!safe_read(e + (uintptr_t)gNameTextOff - 2, &h, 2)) return NO;
    if (h & 1) return NO;
    int len = h >> gNameShift;
    if (len <= 0) return NO;
    if (len >= cap) len = cap - 1;
    if (!safe_read(e + (uintptr_t)gNameTextOff, out, (size_t)len)) return NO;
    out[len] = 0;
    return YES;
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
                uint16_t h; memcpy(&h, b + t - 2, 2);
                if (h & 1) continue;
                int sh = ((h >> 6) == 5) ? 6 : (((h >> 1) == 5) ? 1 : 0);
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

static BOOL poolByClass(uintptr_t cc, int classOff) {
    int32_t idxs[8];
    int ni = 0;
    for (int nk = 0x8; nk <= 0x30 && ni < 8; nk += 8) {
        if (nk == classOff) continue;
        int32_t v = rd_i32(cc + (uintptr_t)nk);
        if (v > 0) idxs[ni++] = v;
    }
    if (!ni) return NO;
    if (poolByClassIn(SYM(0x112d7f9c0ULL), SYM(0x113214000ULL), idxs, ni, NO)) return YES;
    if (poolByClassIn(SYM(0x10ebd3380ULL), SYM(0x112d7c850ULL), idxs, ni, NO)) return YES;
    static BOOL indirectTried = NO;
    if (indirectTried) return NO;
    indirectTried = YES;
    if (poolByClassIn(SYM(0x112d7f9c0ULL), SYM(0x113214000ULL), idxs, ni, YES)) return YES;
    return poolByClassIn(SYM(0x10ebd3380ULL), SYM(0x112d7c850ULL), idxs, ni, YES);
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
        gResolveLine2 = d;
        return NO;
    }
    RLOG(@"namepool: Blocks[0] slot at %p (image+0x%lx) shift %d stride %d textoff %d", (void *)gNameBlocks, (unsigned long)(gNameBlocks - gSlide), gNameShift, gNameStride, gNameTextOff);
    for (size_t k = 0; k < sizeof nameCand / sizeof nameCand[0]; k++) {
        if (nameCand[k] == gOffClass) continue;
        if (name_is(rd_i32(cc + (uintptr_t)nameCand[k]), "Class")) { gOffName = nameCand[k]; nameOk = YES; break; }
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
        NSString *on = fname_string(rd_i32(out + (uintptr_t)gOffName));
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

static int OFF_SUPER = -1, OFF_CHILD = -1, OFF_FNEXT = -1, OFF_FNAME = -1, OFF_POFF = 0x4C;

static BOOL fieldNameIs(uintptr_t f, const char *want) {
    return name_is(rd_i32(f + (uintptr_t)OFF_FNAME), want);
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
    uintptr_t st = rd_ptr(f + 0x78);
    if (!looks_like_uobject(st) || base < 0) return -1;
    int o = propOff(st, inner);
    return o < 0 ? -1 : base + o;
}

static BOOL boolMask(uintptr_t cls, const char *prop, int *off, uint8_t *mask) {
    uintptr_t f = findProp(cls, prop, NULL);
    if (!f) return NO;
    int32_t o = rd_i32(f + (uintptr_t)OFF_POFF);
    uint8_t m = rd_u8(f + 0x7A), fm = rd_u8(f + 0x7B), bo = rd_u8(f + 0x79);
    if (m == 0 || (m & (m - 1))) m = fm;
    if (m == 0 || (m & (m - 1))) m = 1;
    *off = o + bo;
    *mask = m;
    return o >= 0;
}

static BOOL probeReflection(void) {
    uintptr_t fpp = gCls[C_FPLAYERPAWN] ? gCls[C_FPLAYERPAWN] : gCls[C_PAWN];
    uintptr_t actor = gCls[C_ACTOR];
    if (!fpp || !actor) { RLOG(@"reflect: missing Actor/FortPlayerPawn class"); return NO; }

    static const int sup[] = { 0x40, 0x38, 0x48, 0x30, 0x50, 0x58, 0x60 };
    for (size_t k = 0; k < sizeof sup / sizeof sup[0] && OFF_SUPER < 0; k++) {
        uintptr_t c = fpp;
        for (int d = 0; d < 24 && looks_like_uobject(c); d++) {
            if (name_is(rd_i32(c + (uintptr_t)gOffName), "Object")) { OFF_SUPER = sup[k]; break; }
            c = rd_ptr(c + (uintptr_t)sup[k]);
        }
    }
    RLOG(@"reflect: SuperStruct +0x%x", OFF_SUPER);
    if (OFF_SUPER < 0) return NO;

    static const int co[] = { 0x50, 0x48, 0x58, 0x60, 0x68, 0x70, 0x40 };
    static const int nx[] = { 0x20, 0x18, 0x28, 0x30 };
    static const int nm[] = { 0x28, 0x20, 0x30, 0x18 };
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
            if (fname_read(rd_i32(f + (uintptr_t)nm[c]), nameb, sizeof nameb)) {
                score++;
                if (!strcmp(nameb, "RootComponent")) root = YES;
            } else break;
            f = rd_ptr(f + (uintptr_t)nx[b]);
        }
        if (root) score += 1000;
        if (score > bestScore) { bestScore = score; OFF_CHILD = co[a]; OFF_FNEXT = nx[b]; OFF_FNAME = nm[c]; }
    }
    RLOG(@"reflect: ChildProperties +0x%x Next +0x%x Name +0x%x score %d", OFF_CHILD, OFF_FNEXT, OFF_FNAME, bestScore);
    if (bestScore < 1000) return NO;

    static const int io[] = { 0x4C, 0x44, 0x48, 0x50, 0x54, 0x40 };
    int bestIo = 0x4C, bestOk = -1;
    int32_t psz = rd_i32(actor + (uintptr_t)OFF_CHILD + 8);
    for (size_t k = 0; k < sizeof io / sizeof io[0]; k++) {
        uintptr_t f = rd_ptr(actor + (uintptr_t)OFF_CHILD);
        int ok = 0;
        for (int n = 0; f && n < 300; n++) {
            int32_t o = rd_i32(f + (uintptr_t)io[k]), sz = rd_i32(f + 0x3C);
            if (o >= 0 && sz > 0 && sz < 0x10000 && (psz <= 0 || o + sz <= psz + 8)) ok++;
            f = rd_ptr(f + (uintptr_t)OFF_FNEXT);
        }
        if (ok > bestOk) { bestOk = ok; bestIo = io[k]; }
    }
    OFF_POFF = bestIo;
    RLOG(@"reflect: Offset_Internal +0x%x (ok=%d, Actor PropertiesSize=0x%x)", OFF_POFF, bestOk, psz);
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

static BOOL resolveAll(void) {
    if (!gSlide || !gImgBase) return NO;
    gResolveLine = @"resolve: objarray…";
    if (!resolveObjArray()) { flushResolveLog(); return NO; }
    gResolveLine = @"resolve: name pool…";
    gResolveLine = @"resolve: snapshot…";
    if (!snapshotObjects()) { if ([gResolveLine isEqualToString:@"resolve: snapshot…"]) gResolveLine = @"resolve: SNAPSHOT FAILED"; flushResolveLog(); return NO; }

    for (int i = 0, shown = 0; i < gSnapN && shown < 6; i++) {
        if (!gSnapObj[i]) continue;
        RLOG(@"  obj[%d]=%p class=%p name=%@", i, (void *)gSnapObj[i], (void *)gSnapCls[i], fname_string(rd_i32(gSnapObj[i] + (uintptr_t)gOffName)) ?: @"?");
        shown++;
    }

    uintptr_t classClass = 0;
    for (int32_t i = 0; i < gSnapN; i++) {
        if (gSnapObj[i] && gSnapCls[i] == gSnapObj[i]) { classClass = gSnapObj[i]; break; }
    }
    RLOG(@"classclass: %p name=%@", (void *)classClass, classClass ? fname_string(rd_i32(classClass + (uintptr_t)gOffName)) : @"-");
    if (!classClass) { gResolveLine = @"resolve: no UClass"; flushResolveLog(); return NO; }

    gCls[C_CLASS] = classClass;
    for (int32_t i = 0; i < gSnapN; i++) {
        if (!gSnapObj[i] || gSnapCls[i] != classClass) continue;
        char nb[96];
        if (!fname_read(rd_i32(gSnapObj[i] + (uintptr_t)gOffName), nb, sizeof nb)) continue;
        for (int c = 1; c < C_COUNT; c++) {
            if (!gCls[c] && !strcmp(nb, kClsNames[c])) gCls[c] = gSnapObj[i];
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

    gEngineObj = 0;
    for (int32_t i = 0; i < gSnapN; i++) {
        if (!gSnapObj[i] || gSnapCls[i] != gCls[C_FENGINE]) continue;
        NSString *n = fname_string(rd_i32(gSnapObj[i] + (uintptr_t)gOffName));
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
#define kMaxBones 700

@interface EchoBoneMap : NSObject {
@public
    int n; int idx[kMaxSel]; int link[kMaxSel];
    int head, neck, pelvis, boneCount; int *parent;
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

static BOOL refBonesAt(uintptr_t asset, int off, uintptr_t *data, int32_t *n) {
    uintptr_t a = rd_ptr(asset + (uintptr_t)off);
    int32_t c = rd_i32(asset + (uintptr_t)off + 8), m = rd_i32(asset + (uintptr_t)off + 12);
    if (a < 0x100000000ULL || (a & 7) || c < 20 || c > kMaxBones || m < c || m > c * 4 + 64) return NO;
    int32_t info[16 * 4];
    if (!safe_read(a, info, sizeof info)) return NO;
    if (info[2] != -1) return NO;
    for (int i = 0; i < 16; i++) {
        if (!fname_string(info[i * 4])) return NO;
        if (i > 0 && (info[i * 4 + 2] < 0 || info[i * 4 + 2] >= i)) return NO;
    }
    *data = a; *n = c;
    return YES;
}

static EchoBoneMap *buildBoneMap(uintptr_t mesh) {
    if (O_SKIN_ASSET < 0) return nil;
    uintptr_t asset = rd_ptr(mesh + (uintptr_t)O_SKIN_ASSET);
    if (!looks_like_uobject(asset)) return nil;
    NSNumber *key = @(asset);
    EchoBoneMap *cached = gBoneCache[key];
    if (cached) return cached->n > 0 ? cached : nil;

    uintptr_t refData = 0; int32_t N = 0;
    BOOL ok = NO;
    if (gRefBonesOff >= 0) ok = refBonesAt(asset, gRefBonesOff, &refData, &N);
    if (!ok) {
        for (int off = 0x30; off < 0x600 && !ok; off += 8) {
            if (refBonesAt(asset, off, &refData, &N)) { gRefBonesOff = off; ok = YES; RLOG(@"bones: RefSkeleton array at asset+0x%x (%d bones)", off, N); }
        }
    }
    EchoBoneMap *m = [[EchoBoneMap alloc] init];
    m->n = 0; m->head = -1; m->neck = -1; m->pelvis = -1; m->boneCount = N; m->parent = NULL;
    if (ok) {
        int32_t *info = (int32_t *)malloc((size_t)N * 16);
        if (info && safe_read(refData, info, (size_t)N * 16)) {
            int selBone[kMaxSel];
            for (int k = 0; k < kMaxSel; k++) selBone[k] = -1;
            for (int i = 0; i < N; i++) {
                NSString *nm = fname_string(info[i * 4]);
                if (!nm) continue;
                const char *lower = nm.lowercaseString.UTF8String;
                for (int k = 0; k < kMaxSel; k++)
                    if (kBoneNames[k] && selBone[k] < 0 && strcmp(lower, kBoneNames[k]) == 0) { selBone[k] = i; break; }
            }
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
        }
        free(info);
    }
    gBoneCache[key] = m;
    return m->n > 0 ? m : nil;
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
                    ep.weapon = cleanItemName(fname_string(rd_i32(wd + (uintptr_t)gOffName)));
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
    if (gOptLoot && O_PICKUP_DEF >= 0) {
        uintptr_t level = O_WORLD_LEVEL >= 0 ? rd_ptr(world + (uintptr_t)O_WORLD_LEVEL) : 0;
        if (looks_like_uobject(level)) {
            if (gLevelActorsOff < 0) gLevelActorsOff = probeLevelActors(level);
            if (gLevelActorsOff >= 0) {
                uintptr_t aData = rd_ptr(level + (uintptr_t)gLevelActorsOff);
                int32_t aNum = rd_i32(level + (uintptr_t)gLevelActorsOff + 8);
                static NSMutableDictionary<NSNumber *, NSNumber *> *lootClassCache = nil;
                if (!lootClassCache) lootClassCache = [NSMutableDictionary dictionary];
                uintptr_t chunk[2048];
                int nLoot = 0;
                if (aData && aNum > 0 && aNum < 500000) {
                    gDiagActors = aNum;
                    for (int32_t base = 0; base < aNum && nLoot < 400; base += 2048) {
                        int32_t cnt = aNum - base > 2048 ? 2048 : aNum - base;
                        if (!safe_read(aData + (uintptr_t)base * 8, chunk, (size_t)cnt * 8)) continue;
                        for (int32_t k = 0; k < cnt && nLoot < 400; k++) {
                            uintptr_t a = chunk[k];
                            if (a < 0x100000000ULL || (a & 7)) continue;
                            uintptr_t cls = rd_ptr(a + (uintptr_t)gOffClass);
                            if (cls < 0x100000000ULL) continue;
                            NSNumber *ck = @(cls);
                            NSNumber *cv = lootClassCache[ck];
                            if (!cv) {
                                NSString *cn = fname_string(rd_i32(cls + (uintptr_t)gOffName));
                                cv = @([cn hasPrefix:@"FortPickup"]);
                                lootClassCache[ck] = cv;
                            }
                            if (!cv.boolValue) continue;
                            uintptr_t def = rd_ptr(a + (uintptr_t)O_PICKUP_DEF);
                            if (!looks_like_uobject(def)) continue;
                            int tier = O_ITEM_RARITY >= 0 ? rd_u8(def + (uintptr_t)O_ITEM_RARITY) + 1 : 0;
                            if (tier < gOptLootMin + 3 || tier > 8) continue;
                            DV3 lp;
                            if (!actorLocation(a, &lp)) continue;
                            EchoLoot *lo = [[EchoLoot alloc] init];
                            lo.x = lp.x; lo.y = lp.y; lo.z = lp.z; lo.tier = tier;
                            lo.text = cleanItemName(fname_string(rd_i32(def + (uintptr_t)gOffName)));
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

typedef struct { DV3 cam, fwd, right, up; double tanHalf, aspect; } EchoView;

static BOOL project(const EchoView *v, DV3 w, CGFloat *nx, CGFloat *ny, float *depth) {
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
        int hi = bm->head;
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

static void updateESP(void) {
    if (!gLabelRoot) return;
    attachScene(gLabelWindow);

    NSArray<EchoPawn *> *pawns;
    uintptr_t pc, localPawn;
    @synchronized ([NSProcessInfo processInfo]) { pawns = gPawns; pc = gLocalPC; localPawn = gLocalPawn; }

    EchoFrame *frame = [[EchoFrame alloc] init];
    frame.eb = [UIBezierPath bezierPath];
    frame.tb = [UIBezierPath bezierPath];
    frame.ebn = [UIBezierPath bezierPath];
    frame.tbn = [UIBezierPath bezierPath];
    frame.tags = [NSMutableArray array];
    gDiagDrawn = 0; gDiagAds = NO; gDiagLock = NO;

    CGSize sz = gLabelRoot.bounds.size;
    AimCand cands[64];
    int nc = 0;
    DV3 cam = {0,0,0}, rot = {0,0,0};
    float fov = 0;
    BOOL haveCam = (pc && pawns.count && readCamera(pc, &cam, &rot, &fov));

    if (haveCam) {
        double pr = rot.x * M_PI / 180.0, yr = rot.y * M_PI / 180.0, rr = rot.z * M_PI / 180.0;
        double sp = sin(pr), cp = cos(pr), sy = sin(yr), cy = cos(yr), sr = sin(rr), cr = cos(rr);
        EchoView view;
        view.cam = cam;
        view.fwd   = (DV3){ cp * cy, cp * sy, sp };
        view.right = (DV3){ sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp };
        view.up    = (DV3){ -(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp };
        view.tanHalf = tan(fov * M_PI / 360.0);
        view.aspect = sz.height > 0 ? sz.width / sz.height : 1.0;

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

            DV3 feet  = { center.x, center.y, center.z - half };
            DV3 headW = { center.x, center.y, center.z + half * 0.80 };
            DV3 bodyW = { center.x, center.y, center.z + half * 0.25 };
            DV3 topW  = { center.x, center.y, center.z + half };

            DV3 pts[kMaxSel];
            BOOL ptOk[kMaxSel];
            memset(ptOk, 0, sizeof ptOk);
            BOOL haveBones = NO;

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
                            pts[k] = (DV3){ r.x + c2w.t[0], r.y + c2w.t[1], r.z + c2w.t[2] };
                            ptOk[k] = sane_dv(pts[k]);
                        }
                        haveBones = YES;
                        int hi = ep.bones->head, ni = ep.bones->neck, pi2 = ep.bones->pelvis;
                        if (hi >= 0 && ptOk[hi]) headW = pts[hi];
                        if (ni >= 0 && pi2 >= 0 && ptOk[ni] && ptOk[pi2])
                            bodyW = (DV3){ (pts[ni].x + pts[pi2].x) * 0.5, (pts[ni].y + pts[pi2].y) * 0.5, (pts[ni].z + pts[pi2].z) * 0.5 };
                    }
                }
            }
            if (haveBones) topW = (DV3){ headW.x, headW.y, headW.z + 16.0 };

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
            [(ep.team ? frame.tb : frame.eb) appendPath:[UIBezierPath bezierPathWithRect:boxRect]];

            if (haveBones) {
                UIBezierPath *bp = ep.team ? frame.tbn : frame.ebn;
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

            double ddx = center.x - cam.x, ddy = center.y - cam.y, ddz = center.z - cam.z;
            double dist = sqrt(ddx * ddx + ddy * ddy + ddz * ddz) / 100.0;
            EchoTag *tg = [[EchoTag alloc] init];
            tg.text = [NSString stringWithFormat:@"%@  %.0fm", ep.tag, dist];
            tg.c = CGPointMake(cx, ptop - 10);
            if (gOptTags) [frame.tags addObject:tg];
            if (gOptWeaponEsp && ep.weapon.length) {
                EchoTag *wt = [[EchoTag alloc] init];
                wt.text = ep.weapon;
                wt.color = tierColor(ep.wTier);
                wt.c = CGPointMake(cx, pbot + 18);
                [frame.tags addObject:wt];
            }

            if (!ep.team && !downed && nc < 64) {
                DV3 aim = gOptAimBody ? bodyW : headW;
                CGFloat ax, ay; float ad;
                if (project(&view, aim, &ax, &ay, &ad)) {
                    cands[nc].pawn = ep.pawn;
                    cands[nc].aim = aim;
                    cands[nc].sx = (ax - 0.5) * sz.width;
                    cands[nc].sy = (ay - 0.5) * sz.height;
                    cands[nc].onCross = CGRectContainsPoint(CGRectInset(boxRect, w * 0.15, h * 0.08), CGPointMake(sz.width * 0.5, sz.height * 0.5));
                    nc++;
                }
            }
        }

        if (gOptLoot) {
            for (EchoLoot *lo in gLoot) {
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

        BOOL ads = (O_ADS < 0) ? YES : (localPawn && pawnFlag(localPawn, O_ADS, M_ADS));
        gDiagAds = ads;
        if (gOptAimbot && (ads || !gOptAdsOnly) && looks_like_uobject(pc) && nc > 0 && O_CTRL_ROT >= 0) {
            CGFloat R = gOptFov * sz.height;
            int pick = -1;
            CGFloat bestD = 1.0e30;
            for (int i = 0; i < nc; i++) {
                CGFloat d = hypot(cands[i].sx, cands[i].sy);
                CGFloat lim = (cands[i].pawn == gAimTarget) ? R * 1.35 : R;
                if (d <= lim && d < bestD) { bestD = d; pick = i; }
            }
            if (pick >= 0) {
                gAimTarget = cands[pick].pawn;
                DV3 aim = cands[pick].aim;
                double dx = aim.x - cam.x, dy = aim.y - cam.y, dz = aim.z - cam.z;
                double yaw = atan2(dy, dx) * 180.0 / M_PI;
                double pitch = atan2(dz, sqrt(dx * dx + dy * dy)) * 180.0 / M_PI;
                DV3 cur;
                if (safe_read(pc + (uintptr_t)O_CTRL_ROT, &cur, sizeof cur) && sane_dv(cur)) {
                    double f = 1.0 - 0.97 * gOptSmooth;
                    double cp0 = wrap180(cur.x), cy0 = wrap180(cur.y);
                    DV3 nr = { cp0 + wrap180(pitch - cp0) * f, cy0 + wrap180(yaw - cy0) * f, cur.z };
                    memcpy((void *)(pc + (uintptr_t)O_CTRL_ROT), &nr, sizeof nr);
                    gDiagLock = YES;
                }
            } else {
                gAimTarget = 0;
            }
        } else {
            gAimTarget = 0;
        }
    }

    gDiagDrawn = (int)frame.tags.count;
    if (!gHistory) gHistory = [NSMutableArray array];
    [gHistory insertObject:frame atIndex:0];
    while (gHistory.count > 5) [gHistory removeLastObject];
    NSUInteger di = (NSUInteger)gOptDelay;
    if (di >= gHistory.count) di = gHistory.count - 1;
    applyFrame(gHistory[di], sz);
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
- (void)tick:(CADisplayLink *)link { updateESP(); }
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
    [d setBool:gOptHudLayout forKey:@"echo.hudlayout"];
    [d setBool:gOptLowGfx forKey:@"echo.lowgfx"];
    [d setBool:gOptVisOnly forKey:@"echo.vis"];
    [d setBool:gOptAutoSprint forKey:@"echo.sprint"];
    [d setBool:gOptDmg forKey:@"echo.dmg"];
    [d setBool:gOptAutoWeapons forKey:@"echo.autow"];
    [d setFloat:gOptDmgMul forKey:@"echo.dmgmul"];
    [d setFloat:gOptSmooth forKey:@"echo.smooth"];
    [d setFloat:gOptFov forKey:@"echo.fov"];
    [d setInteger:gOptDelay forKey:@"echo.delay"];
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
    if ([d objectForKey:@"echo.hudlayout"]) gOptHudLayout = [d boolForKey:@"echo.hudlayout"];
    if ([d objectForKey:@"echo.lowgfx"]) gOptLowGfx = [d boolForKey:@"echo.lowgfx"];
    if ([d objectForKey:@"echo.vis"]) gOptVisOnly = [d boolForKey:@"echo.vis"];
    if ([d objectForKey:@"echo.sprint"]) gOptAutoSprint = [d boolForKey:@"echo.sprint"];
    if ([d objectForKey:@"echo.dmg"]) gOptDmg = [d boolForKey:@"echo.dmg"];
    if ([d objectForKey:@"echo.autow"]) gOptAutoWeapons = [d boolForKey:@"echo.autow"];
    if ([d objectForKey:@"echo.dmgmul"]) gOptDmgMul = [d floatForKey:@"echo.dmgmul"];
    gOptSmooth = [d floatForKey:@"echo.smooth"];
    gOptFov = [d floatForKey:@"echo.fov"];
    gOptDelay = (int)[d integerForKey:@"echo.delay"];
}

@interface EchoMenuHandler : NSObject
@property (nonatomic, strong) UILabel *smoothLabel;
@property (nonatomic, strong) UILabel *fovLabel;
@property (nonatomic, strong) UILabel *dmgLabel;
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
        case 24: gOptWeaponEsp = on; break;
    }
    saveOptions();
}
- (void)slid:(UISlider *)s {
    if (s.tag == 20) { gOptSmooth = s.value; self.smoothLabel.text = [NSString stringWithFormat:@"Smoothness  %.0f%%", s.value * 100]; }
    if (s.tag == 22) { gOptDmgMul = s.value; self.dmgLabel.text = [NSString stringWithFormat:@"Damage x%d", 1 + (int)(s.value * 49.0f)]; }
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
        title.text = @"EchoMod 43"; title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:17];
        [panel addSubview:title];
        y += 32;

        addSwitch(panel, &y, @"Box ESP", gOptBoxes, 1);
        addSwitch(panel, &y, @"Skeleton ESP", gOptSkeleton, 2);
        addSwitch(panel, &y, @"Name / distance", gOptTags, 3);
        addSwitch(panel, &y, @"Aimbot", gOptAimbot, 4);
        addSwitch(panel, &y, @"Only while aiming (ADS)", gOptAdsOnly, 5);
        addSwitch(panel, &y, @"Show aim FOV circle", gOptShowFov, 6);
        addSwitch(panel, &y, @"Force low graphics (next launch)", gOptLowGfx, 11);
        addSwitch(panel, &y, @"Weapon ESP (rarity colour)", gOptWeaponEsp, 24);
        addSwitch(panel, &y, @"Loot ESP", gOptLoot, 23);
        addSegment(panel, &y, @"Loot min rarity", @[ @"Rare+", @"Epic+", @"Legendary+" ], gOptLootMin, 32);
        addSegment(panel, &y, @"Aim at", @[ @"Head", @"Body" ], gOptAimBody ? 1 : 0, 30);
        gMenuHandler.smoothLabel = addSlider(panel, &y, @"Smoothness", gOptSmooth, 20);
        gMenuHandler.fovLabel = addSlider(panel, &y, @"Aim FOV", gOptFov, 21);
        addSegment(panel, &y, @"ESP delay (frames)", @[ @"0", @"1", @"2", @"3" ], gOptDelay, 31);

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
