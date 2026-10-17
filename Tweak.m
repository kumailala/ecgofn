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
static int  gDiagPlayers, gDiagPawns, gDiagActors, gDiagDrawn;
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
                @"[EchoMod] ESP",
                [NSString stringWithFormat:@"engine: %@  world: %@  pc: %@", eng, gDiagWorld ? @"Y" : @"n", gDiagPC ? @"Y" : @"n"],
                [NSString stringWithFormat:@"gs: %@  players: %d  pawns: %d", gDiagGameState ? @"Y" : @"n", gDiagPlayers, gDiagPawns],
                [NSString stringWithFormat:@"drawn: %d  actors: %d  cam: %d  tick: %d", gDiagDrawn, gDiagActors, gDiagCam, ++tick],
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

// Offsets come from the MobileDumper-7 SDK dump of this exact build; the one global is the
// GEngine pointer recovered from the binary. Everything is read with mach_vm_read_overwrite,
// which never faults, so a wrong value shows up in the panel instead of crashing.
//
//   GEngine (0x105817be8) -> GameViewport +0x728 -> World +0x80
//   UWorld: PersistentLevel +0x30, GameState +0x148, Levels +0x160, OwningGameInstance +0x190
//   UGameInstance::LocalPlayers +0x38 -> ULocalPlayer -> UPlayer::PlayerController +0x30
//   AGameStateBase::PlayerArray +0x330 / Num +0x338
//   ULevel::Actors +0xA0 / Num +0xA8
//   APawn::PlayerState +0x338, AActor::RootComponent +0x158, scene location +0x190
//   APlayerController::PlayerCameraManager +0x398, camera cache POV at +0x10 inside the entry

#define A_GLOBAL_ENGINE          0x105817be8ULL

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
#define OFF_CTRL_PLAYERSTATE     0x320
#define OFF_CTRL_PAWN            0x348
#define OFF_PC_ACKPAWN           0x380
#define OFF_PC_CAMMGR            0x398
#define OFF_PS_NAME              0x3B0
#define OFF_FORTPS_PLATFORM      0x768
#define OFF_ATHENA_TEAM          0xF60
#define OFF_FORTPAWN_DYING       0x824
#define OFF_FORTPAWN_DBNO        0x8C0

static const int kCamCacheOffsets[4] = { 0x390, 0x1990, 0x900, 0x1F00 };

typedef struct { float x, y, z; } FV3;

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

@interface EchoPawn : NSObject
@property (nonatomic, assign) uintptr_t pawn;
@property (nonatomic, assign) BOOL team;
@property (nonatomic, copy)   NSString *tag;
@end
@implementation EchoPawn
@end

static NSArray<EchoPawn *> *gPawns = nil;
static uintptr_t gLocalPC = 0;
static uintptr_t gLocalPawn = 0;
static uintptr_t gEngine = 0;

static void publishPawns(NSArray<EchoPawn *> *list, uintptr_t pc, uintptr_t localPawn) {
    @synchronized ([NSProcessInfo processInfo]) {
        gPawns = list;
        gLocalPC = pc;
        gLocalPawn = localPawn;
    }
}

// Slow path, runs on a background queue a few times a second: finds the local controller, the
// player list, and every pawn in the world (an actor whose PlayerState is one of the players).
static void scanPawns(void) {
    gEngine = rd_ptr(SYM(A_GLOBAL_ENGINE));
    gDiagEngine = looks_like_uobject(gEngine);
    gDiagWorld = NO; gDiagPC = NO; gDiagGameState = NO;
    gDiagPlayers = 0; gDiagPawns = 0; gDiagActors = 0;
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
                [out addObject:ep];
            }
        }
    }

    gDiagActors = actorsSeen;
    gDiagPawns = (int)out.count;
    publishPawns(out, pc, localPawn);
}

#pragma mark - 6) ESP drawing

static UIWindow        *gLabelWindow = nil;
static UIView          *gLabelRoot   = nil;
static CADisplayLink   *gLabelLink   = nil;
static CAShapeLayer    *gBoxEnemy    = nil;
static CAShapeLayer    *gBoxTeam     = nil;
static NSMutableArray<UILabel *> *gTagPool = nil;
static dispatch_source_t gScanTimer  = nil;

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

static BOOL project(FV3 w, FV3 cam, FV3 fwd, FV3 right, FV3 up, float tanHalf, float aspect,
                    CGFloat *nx, CGFloat *ny, float *depth) {
    float dx = w.x - cam.x, dy = w.y - cam.y, dz = w.z - cam.z;
    float x = dx * fwd.x + dy * fwd.y + dz * fwd.z;
    if (x < 10.0f) return NO;
    float y = dx * right.x + dy * right.y + dz * right.z;
    float z = dx * up.x + dy * up.y + dz * up.z;
    *nx = 0.5 + 0.5 * (y / (x * tanHalf));
    *ny = 0.5 - 0.5 * ((z / (x * tanHalf)) * aspect);
    *depth = x;
    return YES;
}

static void updateESP(void) {
    if (!gLabelRoot) return;
    attachScene(gLabelWindow);

    NSArray<EchoPawn *> *pawns;
    uintptr_t pc, localPawn;
    @synchronized ([NSProcessInfo processInfo]) {
        pawns = gPawns; pc = gLocalPC; localPawn = gLocalPawn;
    }
    (void)localPawn;

    UIBezierPath *enemyPath = [UIBezierPath bezierPath];
    UIBezierPath *teamPath  = [UIBezierPath bezierPath];
    NSUInteger used = 0;
    gDiagDrawn = 0;

    FV3 cam = {0,0,0}, rot = {0,0,0};
    float fov = 0;
    if (pc && pawns.count && readCamera(pc, &cam, &rot, &fov)) {
        float pr = rot.x * (float)M_PI / 180.0f, yr = rot.y * (float)M_PI / 180.0f, rr = rot.z * (float)M_PI / 180.0f;
        float sp = sinf(pr), cp = cosf(pr), sy = sinf(yr), cy = cosf(yr), sr = sinf(rr), cr = cosf(rr);
        FV3 fwd   = { cp * cy, cp * sy, sp };
        FV3 right = { sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp };
        FV3 up    = { -(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp };
        float tanHalf = tanf(fov * (float)M_PI / 360.0f);
        CGSize sz = gLabelRoot.bounds.size;
        float aspect = sz.height > 0 ? (float)(sz.width / sz.height) : 1.0f;

        for (EchoPawn *ep in pawns) {
            if (rd_u8(ep.pawn + OFF_FORTPAWN_DYING)) continue;
            uintptr_t root = rd_ptr(ep.pawn + OFF_ACTOR_ROOT);
            if (root < 0x100000000ULL) continue;
            FV3 loc;
            if (!safe_read(root + OFF_SCENE_LOCATION, &loc, sizeof loc) || !sane_vec(loc)) continue;

            FV3 top = loc, bot = loc;
            top.z += 92.0f; bot.z -= 92.0f;
            CGFloat tx, ty, bx, by; float d1, d2;
            if (!project(top, cam, fwd, right, up, tanHalf, aspect, &tx, &ty, &d1)) continue;
            if (!project(bot, cam, fwd, right, up, tanHalf, aspect, &bx, &by, &d2)) continue;

            CGFloat px = tx * sz.width, ptop = ty * sz.height, pbot = by * sz.height;
            CGFloat h = pbot - ptop;
            if (h < 4.0 || h > sz.height * 3.0) continue;
            CGFloat w = h * 0.5;
            CGFloat cx = (tx + bx) * 0.5 * sz.width;
            if (cx < -w || cx > sz.width + w || pbot < 0 || ptop > sz.height) continue;
            (void)px;

            CGRect r = CGRectMake(cx - w * 0.5, ptop, w, h);
            if (ep.team) [teamPath appendPath:[UIBezierPath bezierPathWithRect:r]];
            else         [enemyPath appendPath:[UIBezierPath bezierPathWithRect:r]];

            float dist = sqrtf((loc.x - cam.x) * (loc.x - cam.x) + (loc.y - cam.y) * (loc.y - cam.y) +
                               (loc.z - cam.z) * (loc.z - cam.z)) / 100.0f;
            UILabel *tag = tagAtIndex(used);
            tag.text = [NSString stringWithFormat:@"%@  %.0fm", ep.tag, dist];
            [tag sizeToFit];
            tag.frame = CGRectMake(cx - (tag.bounds.size.width + 8) * 0.5, ptop - tag.bounds.size.height - 3,
                                   tag.bounds.size.width + 8, tag.bounds.size.height + 2);
            tag.hidden = NO;
            used++;
        }
    }

    for (NSUInteger i = used; i < gTagPool.count; i++) gTagPool[i].hidden = YES;
    gDiagDrawn = (int)used;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    gBoxEnemy.path = enemyPath.CGPath;
    gBoxTeam.path  = teamPath.CGPath;
    [CATransaction commit];
}

@interface EchoEspTicker : NSObject
@end
@implementation EchoEspTicker
- (void)tick:(CADisplayLink *)link { updateESP(); }
@end
static EchoEspTicker *gEspTicker = nil;

static CAShapeLayer *makeBoxLayer(UIColor *c) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor   = [UIColor clearColor].CGColor;
    l.strokeColor = c.CGColor;
    l.lineWidth   = 1.5;
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

        gBoxEnemy = makeBoxLayer([UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:1.0]);
        gBoxTeam  = makeBoxLayer([UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0]);
        [gLabelRoot.layer addSublayer:gBoxEnemy];
        [gLabelRoot.layer addSublayer:gBoxTeam];

        gEspTicker = [[EchoEspTicker alloc] init];
        gLabelLink = [CADisplayLink displayLinkWithTarget:gEspTicker selector:@selector(tick:)];
        [gLabelLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

        dispatch_queue_t q = dispatch_queue_create("echomod.scan", DISPATCH_QUEUE_SERIAL);
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  300ull * NSEC_PER_MSEC, 50ull * NSEC_PER_MSEC);
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
