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

`Tweak.m` now has **three** independent proofs that the dylib is injected and running. Any one
of them showing up is enough; if you see none, the dylib isn't loaded (injection/re-sign problem,
not code):

1. **Startup popup** — ~1.5 s after launch a `UIAlertController` appears: *"EchoMod — dylib loaded
   OK ✅ (injection test)"* with an **OK** button. Presented on the game's top-most view
   controller (retries for a few seconds if the UI isn't up yet).
2. **FPS counter** — top-left, live number.
3. **Platform HUD** — top-right, live test text with a climbing `tick`.

Also logs to the device console (`NSLog`):
```
[EchoMod] dylib loaded — constructor ran
[EchoMod] loaded alert presented on <VC class>
```
(Use Console.app / `idevicesyslog` on the connected device to see these.)

**iOS 13+ scene handling:** a `UIWindow` with no `windowScene` is never displayed on modern iOS.
Both overlays now attach to the app's active `UIWindowScene` (and re-attach every tick if the
scene connects late), so they show on scene-based apps too.

## Platform HUD (in progress — test scaffold only)

The final goal is a standalone HUD overlay that lists the players in the lobby/match and the
**platform** each one is on. That needs real per-player data, which isn't wired up yet.

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
