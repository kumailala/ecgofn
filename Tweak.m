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
static NSString *gBoneDiag = @"bones: not tried";
static int gDiagBs = 0;
static NSString *gScreenDiagA = @"";
static NSString *gScreenDiagB = @"";
static void updateScreenDiag(void);
static BOOL gFiring = NO;

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
                [NSString stringWithFormat:@"drawn: %d  cam: %d  ads: %@  lock: %@  fire: %@", gDiagDrawn, gDiagCam, gDiagAds ? @"Y" : @"n", gDiagLock ? @"Y" : @"n", gFiring ? @"Y" : @"n"],
                [NSString stringWithFormat:@"%@  bs: %d", gBoneDiag, gDiagBs],
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

#pragma mark - 5) engine walk (memory only, no engine calls)

// Offsets come from the MobileDumper-7 SDK dump of this exact build; the two addresses are the
// GEngine pointer and the GNames slot. Everything is read with mach_vm_read_overwrite, which
// never faults, so a wrong value shows up in the panel instead of crashing.

#define A_GLOBAL_ENGINE          0x105817be8ULL
#define A_GLOBAL_GNAMES          0x10550E5C0ULL
#define A_GLOBAL_GOBJECTS        0x1058213B8ULL
#define OFF_RUNTIMEOPT_HUDLAYOUT 0x2B8

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
#define OFF_CHAR_CAPSULE         0x388
#define OFF_CAPSULE_HALFHEIGHT   0x670
#define OFF_SKINNED_SKELMESH     0x678
#define OFF_SKELMESH_REFBONES    0x138
#define OFF_SKELCOMP_BONESPACE   0x840
#define OFF_PAWN_CURRENTWEAPON   0x7D0
#define OFF_WEAPON_DATA          0x368
#define A_FIRE_START             0x10219b908ULL
#define A_FIRE_STOP              0x1017c6e84ULL
#define OFF_WEAPONDEF_STATHANDLE 0x508
#define OFF_DATATABLE_ROWMAP     0x30
#define OFF_PS_NAME              0x3B0
#define OFF_FORTPS_PLATFORM      0x768
#define OFF_ATHENA_TEAM          0xF60
#define OFF_FORTPAWN_DYING       0x824
#define OFF_FORTPAWN_DBNO        0x8C0
#define OFF_FORTPLAYERPAWN_ADS   0x117A

static const int kCamCacheOffsets[4] = { 0x390, 0x1990, 0x900, 0x1F00 };

static BOOL  gOptBoxes = YES, gOptSkeleton = YES, gOptTags = YES;
static BOOL  gOptAimbot = YES, gOptAdsOnly = YES, gOptShowFov = YES;
static BOOL  gOptAimBody = NO;
static BOOL  gOptNoRecoil = NO, gOptNoSpread = NO, gOptTrigger = NO;
static BOOL  gOptHudLayout = YES;
static BOOL  gOptLowGfx = YES;
static float gOptSmooth = 0.35f;
static float gOptFov = 0.30f;
static int   gOptDelay = 1;

typedef struct { float x, y, z; } FV3;
typedef struct { float q[4]; float t[3]; float tp; float s[3]; float sp; } FXform;
typedef struct { float q[4]; float t[3]; float s[3]; } CompBone;
static FXform gLocalBones[700];
static CompBone gCompBones[700];

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
        if (!isfinite(x->t[i]) || fabsf(x->t[i]) > 100000.0f) return NO;
        if (!isfinite(x->s[i]) || fabsf(x->s[i]) < 0.01f || fabsf(x->s[i]) > 10.0f) return NO;
    }
    return YES;
}

#define kMaxSel 24
#define kMaxBones 700

@interface EchoBoneMap : NSObject {
@public
    int n;
    int idx[kMaxSel];
    int link[kMaxSel];
    int head;
    int neck;
    int pelvis;
    int boneCount;
    int *parent;
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
static NSMutableDictionary<NSNumber *, EchoBoneMap *> *gBoneCache = nil;
static CFTimeInterval gLastDiagWrite = 0;
static int gDiagWrites = 0;

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

static void writeDiagFile(NSString *text) {
    CFTimeInterval now = CACurrentMediaTime();
    if (gDiagWrites >= 4 || (gDiagWrites > 0 && now - gLastDiagWrite < 15.0)) return;
    gDiagWrites++;
    gLastDiagWrite = now;
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!dir) return;
    [text writeToFile:[dir stringByAppendingPathComponent:@"EchoMod_bones.txt"]
           atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static EchoBoneMap *buildBoneMap(uintptr_t mesh, EchoPawn *ep) {
    uintptr_t skel = rd_ptr(mesh + OFF_SKINNED_SKELMESH);
    if (!looks_like_uobject(skel)) { gBoneDiag = @"bones: no skeletal mesh"; return nil; }
    NSNumber *key = @(skel);
    EchoBoneMap *cached = gBoneCache[key];
    if (cached) return cached->n > 0 ? cached : nil;

    uintptr_t refData = rd_ptr(skel + OFF_SKELMESH_REFBONES);
    int32_t N = rd_i32(skel + OFF_SKELMESH_REFBONES + 8);
    NSMutableString *diag = [NSMutableString stringWithFormat:@"skel=%p refData=%p N=%d\n", (void *)skel, (void *)refData, N];

    EchoBoneMap *m = [[EchoBoneMap alloc] init];
    m->n = 0; m->head = -1; m->neck = -1; m->pelvis = -1; m->boneCount = N; m->parent = NULL;

    if (refData > 0x100000000ULL && N >= 20 && N <= kMaxBones) {
        int32_t *info = (int32_t *)malloc((size_t)N * 16);
        if (info && safe_read(refData, info, (size_t)N * 16)) {
            int selBone[kMaxSel];
            for (int k = 0; k < kMaxSel; k++) selBone[k] = -1;
            int named = 0;
            for (int i = 0; i < N; i++) {
                NSString *nm = fname_string(info[i * 4]);
                if (!nm) continue;
                named++;
                if (i < 12) [diag appendFormat:@"bone[%d]=%@ parent=%d\n", i, nm, info[i * 4 + 2]];
                const char *lower = nm.lowercaseString.UTF8String;
                for (int k = 0; k < kMaxSel; k++) {
                    if (kBoneNames[k] && selBone[k] < 0 && strcmp(lower, kBoneNames[k]) == 0) { selBone[k] = i; break; }
                }
            }
            [diag appendFormat:@"named=%d\n", named];
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
                int p = m->parent[m->idx[a]];
                int guard = 0;
                while (p >= 0 && p < N && guard++ < 64) {
                    int found = -1;
                    for (int b = 0; b < count; b++) if (m->idx[b] == p) { found = b; break; }
                    if (found >= 0) { m->link[a] = found; break; }
                    p = m->parent[p];
                }
            }
            m->n = (count >= 8) ? count : 0;
            [diag appendFormat:@"selected=%d\n", count];
        }
        if (info) free(info);
    }

    gBoneDiag = [NSString stringWithFormat:@"bones: sel=%d N=%d", m->n, N];
    if (m->n == 0) writeDiagFile(diag);
    gBoneCache[key] = m;
    return m->n > 0 ? m : nil;
}


#pragma mark - 5b) weapon mods (stat table rows + autofire flags)

typedef struct { uintptr_t row; float orig[16]; BOOL has; } StatBackup;
static StatBackup gStatBackups[64];
static int gStatBackupCount = 0;

static const int kSpreadOffs[] = { 0x134, 0x138 };
static const int kRecoilOffs[] = { 0x1A8, 0x1AC, 0x1B0, 0x1B8, 0x1BC, 0x1C0, 0x1D8, 0x1DC, 0x1E0, 0x1EC, 0x1F0, 0x1FC, 0x200 };

static void wr_bytes(uintptr_t addr, const void *src, size_t n) {
    uint8_t probe[16];
    if (n > sizeof probe || !safe_read(addr, probe, n)) return;
    memcpy((void *)addr, src, n);
}

static uintptr_t findStatRow(uintptr_t weaponData) {
    uintptr_t table = rd_ptr(weaponData + OFF_WEAPONDEF_STATHANDLE);
    if (!looks_like_uobject(table)) return 0;
    uint64_t rowName = 0;
    if (!safe_read(weaponData + OFF_WEAPONDEF_STATHANDLE + 8, &rowName, 8) || rowName == 0) return 0;
    uintptr_t data = rd_ptr(table + OFF_DATATABLE_ROWMAP);
    int32_t num = rd_i32(table + OFF_DATATABLE_ROWMAP + 8);
    if (data < 0x100000000ULL || num <= 0 || num > 20000) return 0;
    uint8_t buf[24 * 256];
    for (int32_t base = 0; base < num; base += 256) {
        int32_t cnt = num - base;
        if (cnt > 256) cnt = 256;
        if (!safe_read(data + (uintptr_t)base * 24, buf, (size_t)cnt * 24)) continue;
        for (int32_t i = 0; i < cnt; i++) {
            uint64_t key; uintptr_t val;
            memcpy(&key, buf + i * 24, 8);
            memcpy(&val, buf + i * 24 + 8, 8);
            if (key == rowName && val > 0x100000000ULL) return val;
        }
    }
    return 0;
}

static StatBackup *backupFor(uintptr_t row) {
    for (int i = 0; i < gStatBackupCount; i++) if (gStatBackups[i].row == row) return &gStatBackups[i];
    if (gStatBackupCount >= 64) return NULL;
    StatBackup *b = &gStatBackups[gStatBackupCount++];
    b->row = row; b->has = NO;
    return b;
}

static void applyOffs(uintptr_t row, StatBackup *bk, const int *offs, int count, int slot0, BOOL zero) {
    for (int i = 0; i < count; i++) {
        float cur = 0;
        if (!safe_read(row + (uintptr_t)offs[i], &cur, 4) || !isfinite(cur)) continue;
        if (zero) {
            if (cur != 0.0f) { bk->orig[slot0 + i] = cur; bk->has = YES; float z = 0.0f; wr_bytes(row + (uintptr_t)offs[i], &z, 4); }
        } else if (bk->has && cur == 0.0f && bk->orig[slot0 + i] != 0.0f) {
            float o = bk->orig[slot0 + i];
            wr_bytes(row + (uintptr_t)offs[i], &o, 4);
        }
    }
}

static void applyWeaponMods(uintptr_t pc, uintptr_t localPawn) {
    uintptr_t weapon = looks_like_uobject(localPawn) ? rd_ptr(localPawn + OFF_PAWN_CURRENTWEAPON) : 0;
    if (!looks_like_uobject(weapon)) return;
    uintptr_t wdata = rd_ptr(weapon + OFF_WEAPON_DATA);

    if (looks_like_uobject(wdata)) {
        static uintptr_t lastW = 0, lastRow = 0;
        uintptr_t row = (wdata == lastW && lastRow) ? lastRow : findStatRow(wdata);
        lastW = wdata; lastRow = row;
        if (row) {
            float clip = 0;
            safe_read(row + 0x104, &clip, 4);
            int32_t clipInt = rd_i32(row + 0x104);
            if (clipInt >= 0 && clipInt < 2000) {
                StatBackup *bk = backupFor(row);
                if (bk) {
                    applyOffs(row, bk, kSpreadOffs, 2, 0, gOptNoSpread);
                    applyOffs(row, bk, kRecoilOffs, 13, 2, gOptNoRecoil);
                }
            }
            (void)clip;
        }
    }

}


#pragma mark - 5c) HUD layout tool flag

static uintptr_t gRuntimeOpts = 0;
static uint8_t gHudFlagOrig = 0;
static BOOL gHudFlagSaved = NO;

static BOOL objectNamed(uintptr_t obj, const char *want) {
    if (obj < 0x100000000ULL || (obj & 7)) return NO;
    NSString *n = fname_string(rd_i32(obj + 0x18));
    return n && strcmp(n.UTF8String, want) == 0;
}

static uintptr_t findGObject(const char *want, int32_t hint) {
    uintptr_t arr = SYM(A_GLOBAL_GOBJECTS);
    uintptr_t items = rd_ptr(arr + 0x10);
    int32_t num = rd_i32(arr + 0x1C);
    if (items < 0x100000000ULL || num <= 0 || num > 2000000) return 0;
    int32_t lo = hint - 4000, hi = hint + 4000;
    if (lo < 0) lo = 0;
    if (hi > num) hi = num;
    for (int pass = 0; pass < 2; pass++) {
        int32_t a = pass == 0 ? lo : 0, b = pass == 0 ? hi : num;
        for (int32_t i = a; i < b; i++) {
            uintptr_t obj = rd_ptr(items + (uintptr_t)i * 0x18);
            if (objectNamed(obj, want)) return obj;
        }
    }
    return 0;
}

static void applyHudLayoutFlag(void) {
    if (!gRuntimeOpts || !objectNamed(gRuntimeOpts, "Default__FortRuntimeOptions")) {
        gRuntimeOpts = 0;
        if (!gOptHudLayout) return;
        gRuntimeOpts = findGObject("Default__FortRuntimeOptions", 0x12004);
        if (!gRuntimeOpts) return;
        gHudFlagSaved = NO;
    }
    uintptr_t flag = gRuntimeOpts + OFF_RUNTIMEOPT_HUDLAYOUT;
    if (!gHudFlagSaved) { gHudFlagOrig = rd_u8(flag); gHudFlagSaved = YES; }
    uint8_t v = gOptHudLayout ? 1 : gHudFlagOrig;
    if (rd_u8(flag) != v) wr_bytes(flag, &v, 1);
}

// Slow path, runs on a background queue a few times a second: finds the local controller, the
// player list, and every pawn in the world (an actor whose PlayerState is one of the players).
static void scanPawns(void) {
    gEngine = rd_ptr(SYM(A_GLOBAL_ENGINE));
    gNamesObj = rd_ptr(SYM(A_GLOBAL_GNAMES));
    if (!gBoneCache) gBoneCache = [NSMutableDictionary dictionary];
    gDiagEngine = looks_like_uobject(gEngine);
    if (gDiagEngine) applyHudLayoutFlag();
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

                uintptr_t mesh = rd_ptr(a + OFF_CHAR_MESH);
                if (looks_like_uobject(mesh)) {
                    ep.bones = buildBoneMap(mesh, ep);
                    if (ep.bones) gDiagBones++;
                }
                [out addObject:ep];
            }
        }
    }

    gDiagActors = actorsSeen;
    gDiagPawns = (int)out.count;
    publishPawns(out, pc, localPawn);
    applyWeaponMods(pc, localPawn);
}

#pragma mark - 6) ESP drawing + aimbot

@interface EchoTag : NSObject
@property (nonatomic, copy)   NSString *text;
@property (nonatomic, assign) CGPoint c;
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

typedef struct { uintptr_t pawn; FV3 aim; CGFloat sx, sy; BOOL onCross; } AimCand;

static void applyFrame(EchoFrame *f, CGSize sz) {
    for (NSUInteger i = 0; i < gTagPool.count; i++) gTagPool[i].hidden = YES;
    if (gOptTags) {
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

typedef void (*FireFn)(void *);

static void setFire(BOOL want, uintptr_t pc) {
    if (want == gFiring) return;
    if (want) {
        if (!looks_like_uobject(pc)) return;
        ((FireFn)SYM(A_FIRE_START))((void *)pc);
        gFiring = YES;
    } else {
        if (looks_like_uobject(pc)) ((FireFn)SYM(A_FIRE_STOP))((void *)pc);
        gFiring = NO;
    }
}

static void updateESP(void) {
    if (!gLabelRoot) return;
    attachScene(gLabelWindow);

    NSArray<EchoPawn *> *pawns;
    uintptr_t pc, localPawn;
    @synchronized ([NSProcessInfo processInfo]) {
        pawns = gPawns; pc = gLocalPC; localPawn = gLocalPawn;
    }

    EchoFrame *frame = [[EchoFrame alloc] init];
    frame.eb = [UIBezierPath bezierPath];
    frame.tb = [UIBezierPath bezierPath];
    frame.ebn = [UIBezierPath bezierPath];
    frame.tbn = [UIBezierPath bezierPath];
    frame.tags = [NSMutableArray array];
    gDiagDrawn = 0;
    gDiagAds = NO;
    gDiagLock = NO;

    CGSize sz = gLabelRoot.bounds.size;
    AimCand cands[64];
    int nc = 0;
    FV3 cam = {0,0,0}, rot = {0,0,0};
    float fov = 0;
    BOOL haveCam = (pc && pawns.count && readCamera(pc, &cam, &rot, &fov));
    BOOL wantFire = NO;

    if (haveCam) {
        float pr = rot.x * (float)M_PI / 180.0f, yr = rot.y * (float)M_PI / 180.0f, rr = rot.z * (float)M_PI / 180.0f;
        float sp = sinf(pr), cp = cosf(pr), sy = sinf(yr), cy = cosf(yr), sr = sinf(rr), cr = cosf(rr);
        EchoView view;
        view.cam = cam;
        view.fwd   = (FV3){ cp * cy, cp * sy, sp };
        view.right = (FV3){ sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp };
        view.up    = (FV3){ -(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp };
        view.tanHalf = tanf(fov * (float)M_PI / 360.0f);
        view.aspect = sz.height > 0 ? (float)(sz.width / sz.height) : 1.0f;

        for (EchoPawn *ep in pawns) {
            if (rd_u8(ep.pawn + OFF_FORTPAWN_DYING)) continue;
            BOOL downed = rd_u8(ep.pawn + OFF_FORTPAWN_DBNO) != 0;

            FV3 center = {0,0,0};
            float half = 0.0f;
            BOOL haveCap = NO;
            uintptr_t cap = rd_ptr(ep.pawn + OFF_CHAR_CAPSULE);
            if (cap >= 0x100000000ULL) {
                half = rd_f32(cap + OFF_CAPSULE_HALFHEIGHT);
                if (half > 20.0f && half < 140.0f &&
                    safe_read(cap + OFF_SCENE_LOCATION, &center, sizeof center) && sane_vec(center)) haveCap = YES;
            }
            if (!haveCap) {
                uintptr_t root = rd_ptr(ep.pawn + OFF_ACTOR_ROOT);
                if (root < 0x100000000ULL || !safe_read(root + OFF_SCENE_LOCATION, &center, sizeof center) || !sane_vec(center)) continue;
                half = 88.0f;
            }

            FV3 feet  = { center.x, center.y, center.z - half };
            FV3 headW = { center.x, center.y, center.z + half * 0.80f };
            FV3 bodyW = { center.x, center.y, center.z + half * 0.25f };
            FV3 topW  = { center.x, center.y, center.z + half };

            FV3 pts[kMaxSel];
            BOOL ptOk[kMaxSel];
            memset(ptOk, 0, sizeof ptOk);
            BOOL haveBones = NO;

            if ((gOptSkeleton || gOptAimbot) && ep.bones && ep.bones->parent) {
                uintptr_t mesh = rd_ptr(ep.pawn + OFF_CHAR_MESH);
                FXform c2w;
                if (mesh >= 0x100000000ULL && safe_read(mesh + OFF_SCENE_C2W, &c2w, sizeof c2w) && looks_like_xform(&c2w)) {
                    uintptr_t arr = rd_ptr(mesh + OFF_SKELCOMP_BONESPACE);
                    int32_t bn = rd_i32(mesh + OFF_SKELCOMP_BONESPACE + 8);
                    gDiagBs = bn;
                    if (bn > ep.bones->boneCount) bn = ep.bones->boneCount;
                    if (arr >= 0x100000000ULL && bn > 20 && bn <= kMaxBones &&
                        safe_read(arr, gLocalBones, (size_t)bn * sizeof(FXform)) && looks_like_xform(&gLocalBones[0])) {
                        for (int i = 0; i < bn; i++) {
                            const FXform *l = &gLocalBones[i];
                            int pi = ep.bones->parent[i];
                            CompBone *c = &gCompBones[i];
                            if (pi < 0 || pi >= i) {
                                memcpy(c->q, l->q, sizeof c->q);
                                memcpy(c->t, l->t, sizeof c->t);
                                memcpy(c->s, l->s, sizeof c->s);
                            } else {
                                const CompBone *pc2 = &gCompBones[pi];
                                FV3 lt = { l->t[0] * pc2->s[0], l->t[1] * pc2->s[1], l->t[2] * pc2->s[2] };
                                FV3 rt = qrot(pc2->q, lt);
                                c->t[0] = pc2->t[0] + rt.x; c->t[1] = pc2->t[1] + rt.y; c->t[2] = pc2->t[2] + rt.z;
                                float ax = pc2->q[0], ay = pc2->q[1], az = pc2->q[2], aw = pc2->q[3];
                                float bx = l->q[0], by2 = l->q[1], bz = l->q[2], bw = l->q[3];
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
                            const CompBone *c = &gCompBones[bi];
                            FV3 lp = { c->t[0] * c2w.s[0], c->t[1] * c2w.s[1], c->t[2] * c2w.s[2] };
                            FV3 r = qrot(c2w.q, lp);
                            pts[k] = (FV3){ r.x + c2w.t[0], r.y + c2w.t[1], r.z + c2w.t[2] };
                            ptOk[k] = sane_vec(pts[k]);
                        }
                        haveBones = YES;
                        int hi = ep.bones->head, ni = ep.bones->neck, pi2 = ep.bones->pelvis;
                        if (hi >= 0 && ptOk[hi]) headW = pts[hi];
                        if (ni >= 0 && pi2 >= 0 && ptOk[ni] && ptOk[pi2]) {
                            bodyW = (FV3){ (pts[ni].x + pts[pi2].x) * 0.5f, (pts[ni].y + pts[pi2].y) * 0.5f, (pts[ni].z + pts[pi2].z) * 0.5f };
                        }
                    }
                }
            }

            if (haveBones) topW = (FV3){ headW.x, headW.y, headW.z + 16.0f };

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

            float ddx = center.x - cam.x, ddy = center.y - cam.y, ddz = center.z - cam.z;
            float dist = sqrtf(ddx * ddx + ddy * ddy + ddz * ddz) / 100.0f;
            EchoTag *tg = [[EchoTag alloc] init];
            tg.text = [NSString stringWithFormat:@"%@  %.0fm", ep.tag, dist];
            tg.c = CGPointMake(cx, ptop - 10);
            [frame.tags addObject:tg];

            if (!ep.team && !downed && nc < 64) {
                FV3 aim = gOptAimBody ? bodyW : headW;
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

        if (gOptTrigger) {
            for (int i = 0; i < nc; i++) if (cands[i].onCross) { wantFire = YES; break; }
        }
        BOOL ads = localPawn && rd_u8(localPawn + OFF_FORTPLAYERPAWN_ADS) != 0;
        gDiagAds = ads;
        if (gOptAimbot && (ads || !gOptAdsOnly) && looks_like_uobject(pc) && nc > 0) {
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
                FV3 aim = cands[pick].aim;
                float dx = aim.x - cam.x, dy = aim.y - cam.y, dz = aim.z - cam.z;
                float yaw = atan2f(dy, dx) * 180.0f / (float)M_PI;
                float pitch = atan2f(dz, sqrtf(dx * dx + dy * dy)) * 180.0f / (float)M_PI;
                FV3 cur;
                if (safe_read(pc + OFF_CTRL_ROTATION, &cur, sizeof cur) && sane_vec(cur)) {
                    float f = 1.0f - 0.97f * gOptSmooth;
                    float cp0 = wrap180(cur.x), cy0 = wrap180(cur.y);
                    FV3 nr = { cp0 + wrap180(pitch - cp0) * f, cy0 + wrap180(yaw - cy0) * f, cur.z };
                    memcpy((void *)(pc + OFF_CTRL_ROTATION), &nr, sizeof nr);
                    gDiagLock = YES;
                }
            } else {
                gAimTarget = 0;
            }
        } else {
            gAimTarget = 0;
        }
    }

    setFire(wantFire && gOptTrigger, pc);
    gDiagDrawn = (int)frame.tags.count;
    if (!gHistory) gHistory = [NSMutableArray array];
    [gHistory insertObject:frame atIndex:0];
    while (gHistory.count > 5) [gHistory removeLastObject];
    NSUInteger di = (NSUInteger)gOptDelay;
    if (di >= gHistory.count) di = gHistory.count - 1;
    applyFrame(gHistory[di], sz);
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
    gOptSmooth = [d floatForKey:@"echo.smooth"];
    gOptFov = [d floatForKey:@"echo.fov"];
    gOptDelay = (int)[d integerForKey:@"echo.delay"];
}

@interface EchoMenuHandler : NSObject
@property (nonatomic, strong) UILabel *smoothLabel;
@property (nonatomic, strong) UILabel *fovLabel;
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
    }
    saveOptions();
}
- (void)slid:(UISlider *)s {
    if (s.tag == 20) { gOptSmooth = s.value; self.smoothLabel.text = [NSString stringWithFormat:@"Smoothness  %.0f%%", s.value * 100]; }
    if (s.tag == 21) { gOptFov = s.value; self.fovLabel.text = [NSString stringWithFormat:@"Aim FOV  %.0f%%", s.value * 100]; }
    saveOptions();
}
- (void)picked:(UISegmentedControl *)s {
    if (s.tag == 30) gOptAimBody = (s.selectedSegmentIndex == 1);
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
        title.text = @"EchoMod"; title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:17];
        [panel addSubview:title];
        y += 32;

        addSwitch(panel, &y, @"Box ESP", gOptBoxes, 1);
        addSwitch(panel, &y, @"Skeleton ESP", gOptSkeleton, 2);
        addSwitch(panel, &y, @"Name / distance", gOptTags, 3);
        addSwitch(panel, &y, @"Aimbot", gOptAimbot, 4);
        addSwitch(panel, &y, @"Only while aiming (ADS)", gOptAdsOnly, 5);
        addSwitch(panel, &y, @"Show aim FOV circle", gOptShowFov, 6);
        addSwitch(panel, &y, @"No recoil", gOptNoRecoil, 7);
        addSwitch(panel, &y, @"No spread", gOptNoSpread, 8);
        addSwitch(panel, &y, @"Trigger bot (auto shoot)", gOptTrigger, 9);
        addSwitch(panel, &y, @"Enable HUD layout tool", gOptHudLayout, 10);
        addSwitch(panel, &y, @"Force low graphics (next launch)", gOptLowGfx, 11);
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
    if ([d objectForKey:@"echo.lowgfx"] && ![d boolForKey:@"echo.lowgfx"]) return;

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) return;
    NSString *dir = [docs stringByAppendingPathComponent:@"FortniteGame/Saved/Config/IOS"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *engine =
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
        @"sg.FoliageQuality=0\n";
    NSString *profiles =
        @"[IPhoneX DeviceProfile]\n"
        @"+CVars=sg.ResolutionQuality=100\n"
        @"+CVars=sg.ViewDistanceQuality=0\n"
        @"+CVars=sg.AntiAliasingQuality=0\n"
        @"+CVars=sg.ShadowQuality=0\n"
        @"+CVars=sg.PostProcessQuality=0\n"
        @"+CVars=sg.TextureQuality=0\n"
        @"+CVars=sg.EffectsQuality=0\n"
        @"+CVars=sg.FoliageQuality=0\n";
    [engine writeToFile:[dir stringByAppendingPathComponent:@"Engine.ini"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [profiles writeToFile:[dir stringByAppendingPathComponent:@"DeviceProfiles.ini"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
