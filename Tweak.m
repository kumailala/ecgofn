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
            NSString *eng = gDiagEngine ? @"ok" : (gProbeInRange ? @"no-obj" : @"NO");
            setPlatLines(@[
                @"[EchoMod] ESP + aim",
                [NSString stringWithFormat:@"engine: %@  world: %@  pc: %@", eng, gDiagWorld ? @"Y" : @"n", gDiagPC ? @"Y" : @"n"],
                [NSString stringWithFormat:@"gs: %@  players: %d  pawns: %d  bones: %d", gDiagGameState ? @"Y" : @"n", gDiagPlayers, gDiagPawns, gDiagBones],
                [NSString stringWithFormat:@"drawn: %d  cam: %d  ads: %@  lock: %@", gDiagDrawn, gDiagCam, gDiagAds ? @"Y" : @"n", gDiagLock ? @"Y" : @"n"],
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

#pragma mark - 5) engine walk (memory only, no engine calls)

// Offsets come from the MobileDumper-7 SDK dump of this exact build; the two addresses are the
// GEngine pointer and the GNames slot recovered from the binary / dumper. Everything is read
// with mach_vm_read_overwrite, which never faults, so a wrong value shows up in the panel
// instead of crashing.

#define A_GLOBAL_ENGINE          0x105817be8ULL
#define A_GLOBAL_GNAMES          0x10550E5C0ULL

#define OFF_ENGINE_GAMEVIEWPORT  0x728
#define OFF_VIEWPORT_WORLD       0x80
#define OFF_WORLD_PERSISTENT     0x30
#define OFF_WORLD_GAMESTATE      0x148
#define OFF_WORLD_LEVELS         0x160
#define OFF_WORLD_GAMEINSTANCE   0x190
#define OFF_GI_LOCALPLAYERS      0x38
#define OFF_PLAYER_PC            0x30
#define OFF_GS_PLAYERARRAY       0x330
#define OFF_LEVEL_ACTORS         0xA0
#define OFF_PAWN_PLAYERSTATE     0x338
#define OFF_ACTOR_ROOT           0x158
#define OFF_SCENE_LOCATION       0x190
#define OFF_SCENE_C2W            0x180
#define OFF_CTRL_PLAYERSTATE     0x320
#define OFF_CTRL_PAWN            0x348
#define OFF_CTRL_ROTATION        0x368
#define OFF_PC_ACKPAWN           0x380
#define OFF_PC_CAMMGR            0x398
#define OFF_CHAR_MESH            0x378
#define OFF_SKINNED_SKELMESH     0x678
#define OFF_PS_NAME              0x3B0
#define OFF_FORTPS_PLATFORM      0x768
#define OFF_ATHENA_TEAM          0xF60
#define OFF_FORTPAWN_DYING       0x824
#define OFF_FORTPAWN_DBNO        0x8C0
#define OFF_FORTPLAYERPAWN_ADS   0x117A

static const int kCamCacheOffsets[4] = { 0x390, 0x1990, 0x900, 0x1F00 };

static const BOOL    kAimbotEnabled = YES;
static const float   kAimSmooth     = 0.55f;
static const BOOL    kSkeletonEnabled = YES;

typedef struct { float x, y, z; } FV3;
typedef struct { float q[4]; float t[3]; float tp; float s[3]; float sp; } FXform;

#define SYM(va) ((uintptr_t)((intptr_t)(va) + gSlide))

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

static uintptr_t rd_ptr(uintptr_t addr) {
    uintptr_t v = 0;
    return safe_read(addr, &v, sizeof v) ? v : 0;
}

static int32_t rd_i32(uintptr_t addr) {
    int32_t v = 0;
    return safe_read(addr, &v, sizeof v) ? v : 0;
}

static uint8_t rd_u8(uintptr_t addr) {
    uint8_t v = 0;
    return safe_read(addr, &v, sizeof v) ? v : 0;
}

static float rd_f32(uintptr_t addr) {
    float v = 0;
    return safe_read(addr, &v, sizeof v) ? v : 0;
}

static BOOL looks_like_uobject(uintptr_t p) {
    if (p < 0x100000000ULL || (p & 0x7)) return NO;
    uintptr_t vt = rd_ptr(p);
    return (vt >= gImgBase && vt < gImgEnd);
}

static BOOL sane_vec(FV3 v) {
    return isfinite(v.x) && isfinite(v.y) && isfinite(v.z) &&
           fabsf(v.x) < 2.0e6f && fabsf(v.y) < 2.0e6f && fabsf(v.z) < 2.0e6f;
}

static NSString *read_fstring(uintptr_t addr) {
    uintptr_t data = rd_ptr(addr);
    int32_t num = rd_i32(addr + 8);
    if (!data || num <= 1 || num > 48) return nil;
    unichar buf[48];
    if (!safe_read(data, buf, (size_t)(num - 1) * sizeof(unichar))) return nil;
    return [NSString stringWithCharacters:buf length:(NSUInteger)(num - 1)];
}

static uintptr_t gNamesObj = 0;

static NSString *fname_string(int32_t idx) {
    if (idx <= 0 || idx > 4000000 || !gNamesObj) return nil;
    uintptr_t chunk = rd_ptr(gNamesObj + 8 * (uintptr_t)(idx >> 14));
    if (!chunk) return nil;
    uintptr_t entry = rd_ptr(chunk + 8 * (uintptr_t)(idx & 0x3FFF));
    if (!entry) return nil;
    if (rd_i32(entry) & 1) return nil;
    char buf[65];
    memset(buf, 0, sizeof buf);
    const size_t tries[4] = { 64, 32, 16, 8 };
    BOOL ok = NO;
    for (int i = 0; i < 4 && !ok; i++) ok = safe_read(entry + 0x10, buf, tries[i]);
    if (!ok) return nil;
    buf[64] = 0;
    return [NSString stringWithUTF8String:buf];
}

static FV3 qrot(const float *q, FV3 v) {
    float x = q[0], y = q[1], z = q[2], w = q[3];
    FV3 t = { 2.0f * (y * v.z - z * v.y), 2.0f * (z * v.x - x * v.z), 2.0f * (x * v.y - y * v.x) };
    FV3 r = { v.x + w * t.x + (y * t.z - z * t.y),
              v.y + w * t.y + (z * t.x - x * t.z),
              v.z + w * t.z + (x * t.y - y * t.x) };
    return r;
}

static BOOL looks_like_xform(const FXform *x) {
    float qq = x->q[0] * x->q[0] + x->q[1] * x->q[1] + x->q[2] * x->q[2] + x->q[3] * x->q[3];
    if (!(qq > 0.95f && qq < 1.05f)) return NO;
    for (int i = 0; i < 3; i++) {
        if (!isfinite(x->t[i]) || fabsf(x->t[i]) > 5000.0f) return NO;
        if (!isfinite(x->s[i]) || fabsf(x->s[i]) < 0.01f || fabsf(x->s[i]) > 10.0f) return NO;
    }
    return YES;
}

#define kMaxSel 24

@interface EchoBoneMap : NSObject {
@public
    int n;
    int idx[kMaxSel];
    int link[kMaxSel];
    int head;
    int boneCount;
}
@end
@implementation EchoBoneMap
@end

@interface EchoPawn : NSObject
@property (nonatomic, assign) uintptr_t pawn;
@property (nonatomic, assign) BOOL team;
@property (nonatomic, copy)   NSString *tag;
@property (nonatomic, strong) EchoBoneMap *bones;
@end
@implementation EchoPawn
@end

static NSArray<EchoPawn *> *gPawns = nil;
static uintptr_t gLocalPC = 0;
static uintptr_t gLocalPawn = 0;
static uintptr_t gEngine = 0;
static int gCSOffs[2] = { -1, -1 };
static int gCSCount = 0;
static NSMutableDictionary<NSNumber *, EchoBoneMap *> *gBoneCache = nil;

static const char *kBoneNames[kMaxSel] = {
    "head", "neck_01", "spine_05", "spine_04", "spine_03", "spine_02", "spine_01", "pelvis",
    "clavicle_l", "upperarm_l", "lowerarm_l", "hand_l",
    "clavicle_r", "upperarm_r", "lowerarm_r", "hand_r",
    "thigh_l", "calf_l", "foot_l",
    "thigh_r", "calf_r", "foot_r",
    NULL, NULL
};

static void publishPawns(NSArray<EchoPawn *> *list, uintptr_t pc, uintptr_t localPawn) {
    @synchronized ([NSProcessInfo processInfo]) {
        gPawns = list;
        gLocalPC = pc;
        gLocalPawn = localPawn;
    }
}

static void discoverComponentSpace(uintptr_t mesh) {
    if (gCSCount > 0) return;
    int found[16];
    int nf = 0;
    FXform probe[6];
    for (int off = 0x680; off <= 0xCC0 && nf < 16; off += 8) {
        uintptr_t data = rd_ptr(mesh + (uintptr_t)off);
        int32_t num = rd_i32(mesh + (uintptr_t)off + 8);
        int32_t mx = rd_i32(mesh + (uintptr_t)off + 12);
        if (data < 0x100000000ULL || (data & 0xF) || num < 30 || num > 600 || mx < num || mx > 2000) continue;
        if (!safe_read(data, probe, sizeof probe)) continue;
        BOOL ok = YES;
        for (int i = 0; i < 6; i++) if (!looks_like_xform(&probe[i])) { ok = NO; break; }
        if (!ok) continue;

        FXform *all = (FXform *)malloc((size_t)num * sizeof(FXform));
        if (!all) continue;
        float maxZ = 0.0f;
        if (safe_read(data, all, (size_t)num * sizeof(FXform))) {
            for (int i = 0; i < num; i++) if (all[i].t[2] > maxZ) maxZ = all[i].t[2];
        }
        free(all);
        if (maxZ > 130.0f && maxZ < 260.0f) found[nf++] = off;
    }
    if (nf == 0) return;

    int pick = 0;
    for (int i = 0; i + 1 < nf; i++) {
        if (found[i + 1] == found[i] + 16) { gCSOffs[0] = found[i]; gCSOffs[1] = found[i + 1]; gCSCount = 2; return; }
    }
    gCSOffs[0] = found[pick];
    gCSCount = 1;
}

static uintptr_t componentSpaceArray(uintptr_t mesh, int32_t *num) {
    if (gCSCount == 0) return 0;
    int which = 0;
    if (gCSCount == 2) {
        int32_t r = rd_i32(mesh + (uintptr_t)gCSOffs[1] + 16 + 4);
        which = (r == 1) ? 1 : 0;
    }
    uintptr_t base = mesh + (uintptr_t)gCSOffs[which];
    *num = rd_i32(base + 8);
    return rd_ptr(base);
}

static EchoBoneMap *buildBoneMap(uintptr_t mesh) {
    uintptr_t skel = rd_ptr(mesh + OFF_SKINNED_SKELMESH);
    if (!looks_like_uobject(skel)) return nil;
    NSNumber *key = @(skel);
    EchoBoneMap *cached = gBoneCache[key];
    if (cached) return cached->n > 0 ? cached : nil;

    int32_t N = 0;
    if (!componentSpaceArray(mesh, &N) || N < 30 || N > 600) return nil;

    uintptr_t refData = 0;
    for (int off = 0x40; off <= 0x2F8 && !refData; off += 8) {
        uintptr_t data = rd_ptr(skel + (uintptr_t)off);
        int32_t num = rd_i32(skel + (uintptr_t)off + 8);
        if (num != N || data < 0x100000000ULL || (data & 3)) continue;
        int32_t probe[3 * 24];
        if (!safe_read(data, probe, sizeof probe)) continue;
        BOOL ok = (probe[2] == -1);
        for (int i = 1; i < 24 && ok; i++) {
            int32_t nameIdx = probe[i * 3];
            int32_t parent = probe[i * 3 + 2];
            if (parent < 0 || parent >= i || nameIdx <= 0 || nameIdx > 4000000) ok = NO;
        }
        if (ok) refData = data;
    }
    EchoBoneMap *m = [[EchoBoneMap alloc] init];
    m->n = 0; m->head = -1; m->boneCount = N;

    if (refData) {
        int32_t *info = (int32_t *)malloc((size_t)N * 12);
        if (info && safe_read(refData, info, (size_t)N * 12)) {
            int selBone[kMaxSel];
            for (int k = 0; k < kMaxSel; k++) selBone[k] = -1;
            for (int i = 0; i < N; i++) {
                NSString *nm = fname_string(info[i * 3]);
                if (!nm) continue;
                NSString *lower = nm.lowercaseString;
                for (int k = 0; k < kMaxSel; k++) {
                    if (kBoneNames[k] && selBone[k] < 0 && strcmp(lower.UTF8String, kBoneNames[k]) == 0) { selBone[k] = i; break; }
                }
            }
            int count = 0;
            for (int k = 0; k < kMaxSel; k++) {
                if (selBone[k] < 0) continue;
                m->idx[count] = selBone[k];
                if (k == 0) m->head = count;
                count++;
            }
            for (int a = 0; a < count; a++) {
                m->link[a] = -1;
                int p = info[m->idx[a] * 3 + 2];
                int guard = 0;
                while (p >= 0 && guard++ < 64) {
                    int found = -1;
                    for (int b = 0; b < count; b++) if (m->idx[b] == p) { found = b; break; }
                    if (found >= 0) { m->link[a] = found; break; }
                    p = info[p * 3 + 2];
                }
            }
            m->n = (count >= 8) ? count : 0;
        }
        if (info) free(info);
    }
    gBoneCache[key] = m;
    return m->n > 0 ? m : nil;
}

// Slow path, runs on a background queue a few times a second: finds the local controller, the
// player list, and every pawn in the world (an actor whose PlayerState is one of the players).
static void scanPawns(void) {
    gEngine = rd_ptr(SYM(A_GLOBAL_ENGINE));
    gNamesObj = rd_ptr(SYM(A_GLOBAL_GNAMES));
    if (!gBoneCache) gBoneCache = [NSMutableDictionary dictionary];
    gDiagEngine = looks_like_uobject(gEngine);
    gDiagWorld = NO; gDiagPC = NO; gDiagGameState = NO;
    gDiagPlayers = 0; gDiagPawns = 0; gDiagActors = 0; gDiagBones = 0;
    if (!gDiagEngine) { publishPawns(nil, 0, 0); return; }

    uintptr_t vp = rd_ptr(gEngine + OFF_ENGINE_GAMEVIEWPORT);
    uintptr_t world = looks_like_uobject(vp) ? rd_ptr(vp + OFF_VIEWPORT_WORLD) : 0;
    if (!looks_like_uobject(world)) { publishPawns(nil, 0, 0); return; }
    gDiagWorld = YES;

    uintptr_t pc = 0;
    uintptr_t gi = rd_ptr(world + OFF_WORLD_GAMEINSTANCE);
    if (looks_like_uobject(gi)) {
        uintptr_t lpData = rd_ptr(gi + OFF_GI_LOCALPLAYERS);
        uintptr_t lp = lpData ? rd_ptr(lpData) : 0;
        if (looks_like_uobject(lp)) pc = rd_ptr(lp + OFF_PLAYER_PC);
    }
    if (!looks_like_uobject(pc)) { publishPawns(nil, 0, 0); return; }
    gDiagPC = YES;

    uintptr_t localPawn = rd_ptr(pc + OFF_PC_ACKPAWN);
    if (!localPawn) localPawn = rd_ptr(pc + OFF_CTRL_PAWN);
    uintptr_t localPS = rd_ptr(pc + OFF_CTRL_PLAYERSTATE);
    int localTeam = looks_like_uobject(localPS) ? rd_u8(localPS + OFF_ATHENA_TEAM) : -1;

    uintptr_t gs = rd_ptr(world + OFF_WORLD_GAMESTATE);
    if (!looks_like_uobject(gs)) { publishPawns(nil, pc, localPawn); return; }
    gDiagGameState = YES;

    uintptr_t psData = rd_ptr(gs + OFF_GS_PLAYERARRAY);
    int32_t psNum = rd_i32(gs + OFF_GS_PLAYERARRAY + 8);
    if (psNum < 0) psNum = 0;
    if (psNum > 128) psNum = 128;
    gDiagPlayers = psNum;
    if (!psData || psNum == 0) { publishPawns(@[], pc, localPawn); return; }

    uintptr_t players[128];
    int nPlayers = 0;
    for (int i = 0; i < psNum; i++) {
        uintptr_t ps = rd_ptr(psData + (uintptr_t)i * 8);
        if (ps) players[nPlayers++] = ps;
    }

    uintptr_t levels[64];
    int nLevels = 0;
    uintptr_t persistent = rd_ptr(world + OFF_WORLD_PERSISTENT);
    if (persistent) levels[nLevels++] = persistent;
    uintptr_t lvData = rd_ptr(world + OFF_WORLD_LEVELS);
    int32_t lvNum = rd_i32(world + OFF_WORLD_LEVELS + 8);
    if (lvNum > 60) lvNum = 60;
    for (int i = 0; lvData && i < lvNum; i++) {
        uintptr_t l = rd_ptr(lvData + (uintptr_t)i * 8);
        BOOL dup = NO;
        for (int j = 0; j < nLevels; j++) if (levels[j] == l) dup = YES;
        if (l && !dup && nLevels < 64) levels[nLevels++] = l;
    }

    NSMutableArray<EchoPawn *> *out = [NSMutableArray array];
    uintptr_t chunk[2048];
    int actorsSeen = 0;

    for (int li = 0; li < nLevels; li++) {
        uintptr_t aData = rd_ptr(levels[li] + OFF_LEVEL_ACTORS);
        int32_t aNum = rd_i32(levels[li] + OFF_LEVEL_ACTORS + 8);
        if (!aData || aNum <= 0 || aNum > 400000) continue;

        for (int32_t base = 0; base < aNum; base += 2048) {
            int32_t cnt = aNum - base;
            if (cnt > 2048) cnt = 2048;
            if (!safe_read(aData + (uintptr_t)base * 8, chunk, (size_t)cnt * 8)) continue;
            actorsSeen += cnt;

            for (int32_t k = 0; k < cnt; k++) {
                uintptr_t a = chunk[k];
                if (a < 0x100000000ULL || (a & 7)) continue;
                uintptr_t ps = rd_ptr(a + OFF_PAWN_PLAYERSTATE);
                if (!ps) continue;
                BOOL isPlayer = NO;
                for (int p = 0; p < nPlayers; p++) if (players[p] == ps) { isPlayer = YES; break; }
                if (!isPlayer || a == localPawn) continue;

                EchoPawn *ep = [[EchoPawn alloc] init];
                ep.pawn = a;
                int team = rd_u8(ps + OFF_ATHENA_TEAM);
                ep.team = (localTeam > 0 && team == localTeam);
                NSString *name = read_fstring(ps + OFF_PS_NAME);
                NSString *plat = read_fstring(ps + OFF_FORTPS_PLATFORM);
                if (name.length && plat.length) ep.tag = [NSString stringWithFormat:@"%@ [%@]", name, plat];
                else if (name.length) ep.tag = name;
                else if (plat.length) ep.tag = [NSString stringWithFormat:@"[%@]", plat];
                else ep.tag = @"player";

                if (kSkeletonEnabled) {
                    uintptr_t mesh = rd_ptr(a + OFF_CHAR_MESH);
                    if (looks_like_uobject(mesh)) {
                        discoverComponentSpace(mesh);
                        ep.bones = buildBoneMap(mesh);
                        if (ep.bones) gDiagBones++;
                    }
                }
                [out addObject:ep];
            }
        }
    }

    gDiagActors = actorsSeen;
    gDiagPawns = (int)out.count;
    publishPawns(out, pc, localPawn);
}

#pragma mark - 6) ESP drawing + aimbot

static UIWindow        *gLabelWindow = nil;
static UIView          *gLabelRoot   = nil;
static CADisplayLink   *gLabelLink   = nil;
static CAShapeLayer    *gBoxEnemy    = nil;
static CAShapeLayer    *gBoxTeam     = nil;
static CAShapeLayer    *gBoneEnemy   = nil;
static CAShapeLayer    *gBoneTeam    = nil;
static NSMutableArray<UILabel *> *gTagPool = nil;
static NSMutableArray<NSString *> *gTagText = nil;
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

static BOOL readCamera(uintptr_t pc, FV3 *loc, FV3 *rot, float *fov) {
    uintptr_t cm = rd_ptr(pc + OFF_PC_CAMMGR);
    if (cm < 0x100000000ULL) return NO;

    float bestTs = -1.0f;
    int best = -1;
    for (int i = 0; i < 4; i++) {
        uintptr_t e = cm + (uintptr_t)kCamCacheOffsets[i];
        float ts = rd_f32(e);
        float f = rd_f32(e + 0x10 + 0x18);
        if (!isfinite(ts) || ts < 0.0f || f < 20.0f || f > 170.0f) continue;
        if (ts > bestTs) { bestTs = ts; best = i; }
    }
    if (best < 0) return NO;
    gDiagCam = best;

    uintptr_t pov = cm + (uintptr_t)kCamCacheOffsets[best] + 0x10;
    if (!safe_read(pov, loc, sizeof *loc)) return NO;
    if (!safe_read(pov + 0xC, rot, sizeof *rot)) return NO;
    *fov = rd_f32(pov + 0x18);
    return sane_vec(*loc);
}

typedef struct { FV3 cam, fwd, right, up; float tanHalf, aspect; } EchoView;

static BOOL project(const EchoView *v, FV3 w, CGFloat *nx, CGFloat *ny, float *depth) {
    float dx = w.x - v->cam.x, dy = w.y - v->cam.y, dz = w.z - v->cam.z;
    float x = dx * v->fwd.x + dy * v->fwd.y + dz * v->fwd.z;
    if (x < 10.0f) return NO;
    float y = dx * v->right.x + dy * v->right.y + dz * v->right.z;
    float z = dx * v->up.x + dy * v->up.y + dz * v->up.z;
    *nx = 0.5 + 0.5 * (y / (x * v->tanHalf));
    *ny = 0.5 - 0.5 * ((z / (x * v->tanHalf)) * v->aspect);
    *depth = x;
    return YES;
}

static float wrap180(float a) {
    while (a > 180.0f) a -= 360.0f;
    while (a < -180.0f) a += 360.0f;
    return a;
}

static void updateESP(void) {
    if (!gLabelRoot) return;
    attachScene(gLabelWindow);

    NSArray<EchoPawn *> *pawns;
    uintptr_t pc, localPawn;
    @synchronized ([NSProcessInfo processInfo]) {
        pawns = gPawns; pc = gLocalPC; localPawn = gLocalPawn;
    }

    UIBezierPath *enemyBox  = [UIBezierPath bezierPath];
    UIBezierPath *teamBox   = [UIBezierPath bezierPath];
    UIBezierPath *enemyBone = [UIBezierPath bezierPath];
    UIBezierPath *teamBone  = [UIBezierPath bezierPath];
    NSUInteger used = 0;
    gDiagDrawn = 0;
    gDiagAds = NO;
    gDiagLock = NO;

    FV3 cam = {0,0,0}, rot = {0,0,0};
    float fov = 0;
    if (pc && pawns.count && readCamera(pc, &cam, &rot, &fov)) {
        float pr = rot.x * (float)M_PI / 180.0f, yr = rot.y * (float)M_PI / 180.0f, rr = rot.z * (float)M_PI / 180.0f;
        float sp = sinf(pr), cp = cosf(pr), sy = sinf(yr), cy = cosf(yr), sr = sinf(rr), cr = cosf(rr);
        CGSize sz = gLabelRoot.bounds.size;
        EchoView view;
        view.cam = cam;
        view.fwd   = (FV3){ cp * cy, cp * sy, sp };
        view.right = (FV3){ sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp };
        view.up    = (FV3){ -(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp };
        view.tanHalf = tanf(fov * (float)M_PI / 360.0f);
        view.aspect = sz.height > 0 ? (float)(sz.width / sz.height) : 1.0f;

        uintptr_t bestPawn = 0;
        FV3 bestAim = {0,0,0};
        float bestDist = 1.0e30f;
        BOOL keepLock = NO;
        FV3 lockAim = {0,0,0};

        for (EchoPawn *ep in pawns) {
            if (rd_u8(ep.pawn + OFF_FORTPAWN_DYING)) continue;
            BOOL downed = rd_u8(ep.pawn + OFF_FORTPAWN_DBNO) != 0;

            uintptr_t mesh = rd_ptr(ep.pawn + OFF_CHAR_MESH);
            FXform c2w;
            FV3 feet;
            BOOL haveMesh = (mesh >= 0x100000000ULL) && safe_read(mesh + OFF_SCENE_C2W, &c2w, sizeof c2w) &&
                            looks_like_xform(&c2w);
            if (haveMesh) {
                feet = (FV3){ c2w.t[0], c2w.t[1], c2w.t[2] };
            } else {
                uintptr_t root = rd_ptr(ep.pawn + OFF_ACTOR_ROOT);
                if (root < 0x100000000ULL) continue;
                if (!safe_read(root + OFF_SCENE_LOCATION, &feet, sizeof feet)) continue;
                feet.z -= 88.0f;
            }
            if (!sane_vec(feet)) continue;

            FV3 headW = { feet.x, feet.y, feet.z + 166.0f };
            FV3 pts[kMaxSel];
            BOOL ptOk[kMaxSel];
            memset(ptOk, 0, sizeof ptOk);
            BOOL haveBones = NO;

            if (kSkeletonEnabled && ep.bones && haveMesh) {
                int32_t bn = 0;
                uintptr_t arr = componentSpaceArray(mesh, &bn);
                if (arr && bn == ep.bones->boneCount) {
                    FXform *bt = (FXform *)malloc((size_t)bn * sizeof(FXform));
                    if (bt && safe_read(arr, bt, (size_t)bn * sizeof(FXform))) {
                        for (int k = 0; k < ep.bones->n; k++) {
                            const FXform *b = &bt[ep.bones->idx[k]];
                            FV3 lp = { b->t[0] * c2w.s[0], b->t[1] * c2w.s[1], b->t[2] * c2w.s[2] };
                            FV3 r = qrot(c2w.q, lp);
                            pts[k] = (FV3){ r.x + c2w.t[0], r.y + c2w.t[1], r.z + c2w.t[2] };
                            ptOk[k] = sane_vec(pts[k]);
                        }
                        haveBones = YES;
                        int hi = ep.bones->head;
                        if (hi >= 0 && ptOk[hi]) headW = pts[hi];
                    }
                    if (bt) free(bt);
                }
            }

            FV3 topW = haveBones ? (FV3){ headW.x, headW.y, headW.z + 16.0f } : (FV3){ feet.x, feet.y, feet.z + 178.0f };
            CGFloat tx, ty, bx, by; float d1, d2;
            if (!project(&view, topW, &tx, &ty, &d1)) continue;
            if (!project(&view, feet, &bx, &by, &d2)) continue;

            CGFloat ptop = ty * sz.height, pbot = by * sz.height;
            CGFloat h = pbot - ptop;
            if (h < 4.0 || h > sz.height * 3.0) continue;
            CGFloat w = h * 0.5;
            CGFloat cx = (tx + bx) * 0.5 * sz.width;
            if (cx < -w || cx > sz.width + w || pbot < 0 || ptop > sz.height) continue;

            CGRect r = CGRectMake(cx - w * 0.5, ptop, w, h);
            UIBezierPath *bp = ep.team ? teamBox : enemyBox;
            [bp appendPath:[UIBezierPath bezierPathWithRect:r]];

            if (haveBones) {
                UIBezierPath *sp2 = ep.team ? teamBone : enemyBone;
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
                    [sp2 moveToPoint:scr[k]];
                    [sp2 addLineToPoint:scr[l]];
                }
            }

            float ddx = feet.x - cam.x, ddy = feet.y - cam.y, ddz = feet.z - cam.z;
            float dist = sqrtf(ddx * ddx + ddy * ddy + ddz * ddz) / 100.0f;
            NSString *text = [NSString stringWithFormat:@"%@  %.0fm", ep.tag, dist];
            UILabel *tag = tagAtIndex(used);
            if (![gTagText[used] isEqualToString:text]) {
                gTagText[used] = text;
                tag.text = text;
                [tag sizeToFit];
                CGSize ts = tag.bounds.size;
                tag.bounds = CGRectMake(0, 0, ts.width + 8, ts.height + 2);
            }
            tag.center = CGPointMake(cx, ptop - tag.bounds.size.height * 0.5 - 3);
            tag.hidden = NO;
            used++;

            if (!ep.team && !downed) {
                float adx = headW.x - cam.x, ady = headW.y - cam.y, adz = headW.z - cam.z;
                float ad = sqrtf(adx * adx + ady * ady + adz * adz);
                if (ep.pawn == gAimTarget) { keepLock = YES; lockAim = headW; }
                if (ad < bestDist && tx > -0.05 && tx < 1.05 && ty > -0.05 && ty < 1.05) {
                    bestDist = ad; bestPawn = ep.pawn; bestAim = headW;
                }
            }
        }

        BOOL ads = localPawn && rd_u8(localPawn + OFF_FORTPLAYERPAWN_ADS) != 0;
        gDiagAds = ads;
        if (kAimbotEnabled && ads && looks_like_uobject(pc)) {
            FV3 aim = lockAim;
            if (!keepLock) { gAimTarget = bestPawn; aim = bestAim; }
            if (gAimTarget) {
                float dx = aim.x - cam.x, dy = aim.y - cam.y, dz = aim.z - cam.z;
                float yaw = atan2f(dy, dx) * 180.0f / (float)M_PI;
                float pitch = atan2f(dz, sqrtf(dx * dx + dy * dy)) * 180.0f / (float)M_PI;
                FV3 cur;
                if (safe_read(pc + OFF_CTRL_ROTATION, &cur, sizeof cur) && sane_vec(cur)) {
                    float cp0 = wrap180(cur.x), cy0 = wrap180(cur.y);
                    FV3 nr = { cp0 + wrap180(pitch - cp0) * kAimSmooth,
                               cy0 + wrap180(yaw - cy0) * kAimSmooth,
                               cur.z };
                    memcpy((void *)(pc + OFF_CTRL_ROTATION), &nr, sizeof nr);
                    gDiagLock = YES;
                }
            }
        } else {
            gAimTarget = 0;
        }
    }

    for (NSUInteger i = used; i < gTagPool.count; i++) gTagPool[i].hidden = YES;
    gDiagDrawn = (int)used;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    gBoxEnemy.path  = enemyBox.CGPath;
    gBoxTeam.path   = teamBox.CGPath;
    gBoneEnemy.path = enemyBone.CGPath;
    gBoneTeam.path  = teamBone.CGPath;
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
        [gLabelRoot.layer addSublayer:gBoxEnemy];
        [gLabelRoot.layer addSublayer:gBoxTeam];
        [gLabelRoot.layer addSublayer:gBoneEnemy];
        [gLabelRoot.layer addSublayer:gBoneTeam];

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

#pragma mark - 7) image bounds / slide

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
            probeEngine();
            installOverlay();
            installPlatformOverlay();
            installLabelLayer();
            showLoadedAlert(0);
        });
    }];
}
