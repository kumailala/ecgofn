# Echo 3.6 (Fortnite iOS) — FPS unlock + counter + low graphics + platform HUD

**No dylib, no jailbreak.** Everything is done over USB via `pymobiledevice3` (House Arrest),
by editing the app's own writable UE4 config in its Documents container.

Target app: `com.chairentertainment.Fortnite` ("Echo 3.6") — iPad (A16), iOS 26.5.

---

## Building the dylib (GitHub Actions — no Mac needed)

You're on Windows and an iOS dylib needs the Apple toolchain, so the build runs on a macOS
GitHub runner. Workflow: `.github/workflows/build.yml`.

### One-time repo setup
The **repo root is this `echomod/` folder** (the workflow runs `./build.sh` from the repo root).
```powershell
cd "C:\Users\kumail\Documents\Default Project\echomod"
git init
git branch -M main
git add .
git commit -m "EchoMod: dylib + GitHub Actions build"
```
Create an **empty** repo on github.com (private is fine — artifacts stay private too), then:
```powershell
git remote add origin https://github.com/<your-user>/<your-repo>.git
git push -u origin main
```
The first push pops up a browser sign-in (Git Credential Manager) or asks for a **PAT**
(Classic token with `repo` scope). Nothing else to configure.

### Getting the dylib
1. Push (or **Actions → Build NEWLIB.dylib → Run workflow** to re-run on demand).
2. Wait ~1–2 min, open the green run.
3. Under **Artifacts**, download **NEWLIB.dylib** (arrives as a `.zip` — unzip to get the dylib).
4. The run's **Verify** step prints the arch (`arm64 arm64e`), the install name
   (`@executable_path/NEWLIB.dylib`) and a sha256, so you can confirm it's a real fat dylib.

### What the workflow does
`checkout → show Xcode/SDK → ./build.sh NEWLIB.dylib → verify (lipo/otool) → upload artifact`.
It triggers on pushes touching `echomod/**`, and manually via `workflow_dispatch`.

### Notes
- The dylib is **unsigned** on purpose — your sideload/injection tool re-signs the whole app
  anyway (the Echo IPA is already cracked/re-signed), and an unsigned dylib is what those tools expect.
- Keep `*.ipa` / `*.pak` out of the repo (`.gitignore` already does) — they're GBs and private.
- macOS runner minutes are free on public repos; on private they bill at 10× (a build is ~1–2 min,
  so it's negligible).
- Optional `gh` CLI shortcut instead of the website:
  `gh run watch` then `gh run download -n NEWLIB.dylib`.

---

## Why FPS was stuck at 30

The bundled pak `FortniteGame/Config/IOS/IOSEngine.ini` contains:

```ini
[/Script/IOSRuntimeSettings.IOSRuntimeSettings]
FrameRateLock=PUFRL_120
```

**`PUFRL_120` is not a real value.** The enum in the binary is
`EPowerUsageFrameRateLock` and only has:

```
EPowerUsageFrameRateLock::PUFRL_20
EPowerUsageFrameRateLock::PUFRL_30
EPowerUsageFrameRateLock::PUFRL_60
EPowerUsageFrameRateLock::PUFRL_None
```

An unparseable enum name means the property silently keeps its C++ default — which is the
**30 fps** lock. So the config *says* 120 but the game runs at 30.

UE4 loads config in layers and `Documents/FortniteGame/Saved/Config/IOS/Engine.ini` is loaded
**last (highest priority)**. Putting a *valid* value there overrides the broken pak value.

---

## What was written (the fix)

### 1. `Documents/FortniteGame/Saved/Config/IOS/Engine.ini`

```ini
[/Script/IOSRuntimeSettings.IOSRuntimeSettings]
FrameRateLock=PUFRL_60          ; valid enum -> overrides the broken PUFRL_120

[/Script/Engine.Engine]
bSmoothFrameRate=False
bUseFixedFrameRate=False

[SystemSettings]
t.MaxFPS=120
sg.ResolutionQuality=100
sg.ViewDistanceQuality=0
sg.AntiAliasingQuality=0
sg.ShadowQuality=0
sg.PostProcessQuality=0
sg.TextureQuality=0
sg.EffectsQuality=0
sg.FoliageQuality=0
```

### 2. `Documents/FortniteGame/Saved/Config/IOS/DeviceProfiles.ini`

The launcher forces `-DeviceProfile=IPhoneX`, whose parent `IOS_High` forces `sg.*=2`
(High) at every startup. The device profile is patched itself so "Low" is **persistent**
(the `[ScalabilityGroups]` keys in `GameUserSettings.ini` get dropped by the game on save —
only `sg.ResolutionQuality` survives there):

```ini
[IPhoneX DeviceProfile]
+CVars=sg.ResolutionQuality=100
+CVars=sg.ViewDistanceQuality=0
+CVars=sg.AntiAliasingQuality=0
+CVars=sg.ShadowQuality=0
+CVars=sg.PostProcessQuality=0
+CVars=sg.TextureQuality=0
+CVars=sg.EffectsQuality=0
+CVars=sg.FoliageQuality=0
```

### 3. `Documents/FortniteGame/Saved/Config/IOS/GameUserSettings.ini`

```ini
[/Script/FortniteGame.FortGameUserSettings]
UnlockConsoleFPS=True
bShowFPS=True
bMotionBlur=False
bShowGrass=False
FrameRateLimit=60.000000

[ScalabilityGroups]
sg.ResolutionQuality=100.000000
```

---

## Result

- **60 FPS** in match (was 30).
- Graphics **Low**, 3D resolution **100%**.
- FPS counter in the **lobby** (see caveat).

## Caveats

- **In-match FPS counter:** `bShowFPS` drives a UMG widget that only exists in the frontend,
  so it does nothing in a match. No-dylib workaround: the console is bound to the **`~` key**
  (`EMS/DefaultInput.ini`: `ConsoleKey=Tilde`), so with a keyboard press `~` and type `stat fps`
  for the engine's real in-match overlay. An always-on in-match counter needs the dylib overlay.
- **The game rewrites `GameUserSettings.ini` on exit**, so values it "owns" can revert. `Engine.ini`
  and `DeviceProfiles.ini` are *not* rewritten, which is why the important bits live there.
- **Low Power Mode** (`bInLowPowerMode` / `EPowerUsageFrameRateLock`) can still drag FPS down —
  keep it OFF in Settings -> Battery.
- iPad connected to a PC USB port reports `IsCharging: false` (only 3 W) — use a real charger
  to avoid battery-related limits.

## Dylib self-test (does it load at all?)

`Tweak.m` now has several independent proofs that the dylib is injected and running. Any one
of them showing up is enough; if you see none, the dylib isn't loaded (injection/re-sign problem,
not code):

1. **Startup popup** — ~1.5 s after launch a `UIAlertController` appears: *"EchoMod — dylib loaded
   OK ✅ (injection test)"* with an **OK** button. Presented on the game's top-most view
   controller (retries for a few seconds if the UI isn't up yet).
2. **FPS counter** — top-left, live number.
3. **Platform HUD** — top-right, live test text with a climbing `tick` and an `engine: ok/NO` line.
4. **Engine probe** — the `engine:` line above; `ok` means the offline symbol map resolved to real
   code addresses in the live process.

Also logs to the device console (`NSLog`):
```
[EchoMod] dylib loaded — constructor ran
[EchoMod] engine probe: base=0x... end=0x... slide=...
[EchoMod] loaded alert presented on <VC class>
```
(Use Console.app / `idevicesyslog` on the connected device to see these.)

**iOS 13+ scene handling:** a `UIWindow` with no `windowScene` is never displayed on modern iOS.
Both overlays now attach to the app's active `UIWindowScene` (and re-attach every tick if the
scene connects late), so they show on scene-based apps too.

## Platform HUD (in progress — test scaffold only)

The final goal is a standalone HUD overlay that lists the players in the lobby/match and the
**platform** each one is on, drawn **above their heads** and only while they're visible.

### Step 2 (current): overhead "platform" labels

`Tweak.m` section 5 (`#pragma mark - 5) overhead "platform" labels`) is a small label layer:

- A dedicated transparent overlay window + a pool of `UILabel`s, updated **every frame** by a
  `CADisplayLink` (so labels can track moving targets instead of stuttering at 1 Hz).
- Each label is positioned by normalized `(nx, ny)` in `0..1` — resolution independent.
- **Visibility gate:** `pointOnScreen()` hides a label the moment its point leaves the screen.
  That's the "only show when visible" rule; with real data it's the same check plus the engine's
  own occlusion/visibility result.
- The top-right panel is now a status readout: `labels: N  onscreen: M`.

**The labels currently say `"platform"` and move synthetically** (one deliberately drifts
off-screen so you can watch the gate work). That's the placeholder: the render path, the
per-frame update and the visibility gate are all real.

### The seam for real data

Everything synthetic is inside `fillTestLabels()`:

```objc
// replace this with, per visible player:
//   (nx, ny) = project(headWorldPos);  text = platform
```

### Recon findings

`FortniteClient` is **decrypted** (no `LC_ENCRYPTION_INFO_64`) and is built from
`++Fortnite+Release-3.6+Full` (UE4.19-era). Its symbol table is only 1,937 entries and holds
**only third-party exports** (PhysX, Vivox, `AVPlayer`, `GKPlayer`) — no engine symbols.

But the engine names exist as **UE reflection strings**, and the registration tables in `__DATA`
store `{ name_string_ptr, code_ptr }` pairs. Scanning those recovers
**26,420 function names with addresses** (kept in `../research/fortnite36_symbols.json`, outside
this public repo). Everything we need is in there:

```
GetPlayerPlatform          OnRep_Platform          <-- platform is a replicated PlayerState property
GetPlatformName            IsMobilePlatform / IsConsolePlatform / IsPS4Platform / IsXboxPlatform
ProjectWorldLocationToScreen                       <-- world -> screen
DeprojectScreenPositionToWorld
GetPlayerController / GetPlayerPawn / GetOwningPlayerState / GetGameState
AddActorIndicator / AreIndicatorsEnabled           <-- Fortnite's HUD actor-indicator system
GetNameplatesEnabled / SetNameplatesEnabled
```

`OnRep_Platform` is the key one: it's the **replicated-property callback**, so the client already
receives every player's platform. The data exists on-device; we just have to read it.

### Address → runtime address

The recovered addresses are preferred (unslid) VM addresses. At runtime the image is ASLR-slid:

```c
real = image_base + (symbol_addr - 0x100000000);   // 0x100000000 == __TEXT vmaddr
```

### Step 3 (current): engine address probe (SAFE)

`Tweak.m` section 6 resolves `ProjectWorldLocationToScreen` and `GetPlayerPlatform` against the
live slide, walks the main image's `LC_SEGMENT_64`s to get its mapped bounds, and reports whether
the resolved addresses land inside it. **No hooking and no dereferencing of game code**, so it
cannot crash. The top-right panel shows `engine: ok` / `engine: NO`, and `NSLog` prints:

```
[EchoMod] engine probe: base=0x... end=0x... slide=...
[EchoMod]   ProjectWorldLocationToScreen=0x...  GetPlayerPlatform=0x...  inRange=1
```

`engine: ok` proves the offline symbol map is usable on-device — the gate before any real hook.

### Two routes for real data

1. **Our own projection** — resolve the engine's `ProjectWorldLocationToScreen` and feed real
   `(nx, ny)` into `fillTestLabels()`. Caveat: projection only means "in front of the camera",
   not "not occluded", so a projection-only label would show **through walls**.
2. **Piggyback the nameplates / actor indicators** — the game already draws those at the right
   place **and only when visible**; hooking that gets positioning *and* correct visibility for free.
   This is the preferred route (it keeps the "only when visible" rule honest).

Both still need **member offsets** (World → GameState → PlayerArray → Pawn → Location, and the
PlayerState `Platform` property), which are the next RE step, plus on-device validation —
because a wrong offset is a crash, not a wrong number.

## Platform HUD (older panel notes)

**Step 1 (done): prove the overlay renders.** `Tweak.m` now builds a second overlay window
(top-right, `EchoPlatformOverlay` globals `gPlatOverlay` / `gPlatLabel`) with its own 0.5 s
timer. It currently shows **test text only**:

```
[EchoMod] platform HUD — TEST
app : com.chairentertainment.Fortnite
dev : <device model> / <iOS version>
tick: <climbing counter>
----
player1 : TEST
player2 : TEST
```

- If the panel appears **and `tick` keeps climbing**, the overlay pipeline works and real data
  can be plugged into `setPlatLines(...)`.
- If it doesn't appear, the dylib isn't loading / the launch-notification block isn't firing —
  debug that before touching platform logic.
- Rendering lives in `#pragma mark - 3) platform HUD (test scaffold)`: replace the `@[ ... ]`
  array in the timer with real `"playername : Platform"` rows.
- `setPlatLines()` takes an array of strings, one per line, and sizes the panel automatically.

Build is unchanged: `./build.sh` (needs macOS or the GitHub Action), same arm64/arm64e fat dylib.

## Reverse / reinstall

Delete the three files' added blocks (or the files) and relaunch. Local backups were kept in
`%TEMP%\opencode\` (`GameUserSettings.ini.bak`, `GameUserSettings.before_logout.ini`,
`GameUserSettings.fresh.bak`). After a reinstall the container UUID changes — re-apply with the
scripts in `%TEMP%\opencode\` (`push_overrides.py`, `apply_settings.py`).
