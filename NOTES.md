# TabStash internals

A Cmd+Tab replacement for macOS that shows **only the apps with windows on the
current Space** (each desktop gets its own list). Written in Swift, builds
without Xcode.

## Build

```sh
./make-cert.sh        # once: creates a local signing identity (see "Signing")
./build.sh
open build/TabStash.app
```

Only the Command Line Tools are required (`xcode-select --install`).
The result is `build/TabStash.app`.

## First launch

1. TabStash lives in the menu bar (tile with a ⇥ arrow); there is no Dock icon.
2. macOS asks for **Accessibility** access. Enable TabStash in
   System Settings → Privacy & Security → Accessibility. The app notices the grant
   by itself and starts intercepting Cmd+Tab; no relaunch needed.
3. "Launch at Login" is in the menu.

If the Accessibility list already contains a TabStash entry from an earlier,
differently signed build, the grant does not match. Remove the entry with the "−"
button and add the app again (or run `tccutil reset Accessibility dev.artem.tabstash`
and relaunch).

Activating a window that lives on this Space never changes the Space: the switcher focuses the window that lives
here straight through the window server (`_SLPSSetFrontProcessWithOptions` +
`SLPSPostEventRecordTo`, the AltTab/yabai technique), so the Dock never sees an
activation and cannot jump to another Space where the app also has windows. Picking a
window that is on another Space does the opposite: it activates the app the ordinary
way, so macOS follows you there. A minimized window, or an app hidden with Cmd+H, is
brought back the same way: Accessibility lists nothing for such an app until it is
active again, so the window is unminimized right after activating, with two retries.

## The switcher

Laid out like the system Cmd+Tab: a row of 112-pt icons, the highlighted one on a
rounded tile, and only its name spelled out underneath. The background is Liquid Glass
(`NSGlassEffectView`), which exists in macOS 26 and later but not in the Command Line
Tools SDK, so it is created through the Objective-C runtime and falls back to
`NSVisualEffectView` on older systems.

The panel follows the system appearance; Settings can pin it to Light or Dark. The
glass follows System Settings → Appearance → Liquid Glass: the clear look when the tint
amount there is 0, tinted otherwise. `defaults write dev.artem.tabstash glassStyle
-int 0|1` pins one of the two looks; `defaults delete` returns to following the system.

The blur behind the panel belongs to the system and cannot be switched off, so "clear"
means a less solid backdrop: Settings offers Frosted, Light and Clear. Only the backdrop
fades, the icons on top stay solid.

Icons are ordered by recent use: the app in front first, then the one before it, so a
single Cmd+Tab goes back and forth between two apps. With windows listed separately each
window counts on its own, so a second window you never touch sinks behind everything you
do use instead of following the window of the same app. Switching by mouse counts too:
the window an app is activated with is recorded. Settings offers Name and Window order
instead.

## Keys

| Keys | Action |
|---|---|
| Cmd+Tab | open the switcher / next app |
| Cmd+Shift+Tab, arrow keys | previous / move through the list |
| release Cmd | activate the selected app |
| Esc | close without switching |
| Cmd+Q (while open) | quit the selected app |
| Cmd+H (while open) | hide the selected app |

## Settings

Menu bar → "Settings…" (Cmd+, while the menu is open):

- **Glass.** How solid the panel background is: Frosted, Light or Clear.
- **Show minimized and hidden apps.** When off, an app whose windows on this Space are
  all minimized (or that is hidden with Cmd+H) is left out. When on, such apps appear
  with a dimmed icon and selecting one restores its window.
- **Show only apps from the current Space.** On by default. Off lists apps from every
  Space, like the system Cmd+Tab. A window on another Space counts as present, not as
  minimized, so this works whatever "Show minimized" is set to.
- **Group all windows of an app into one entry.** On by default. Off gives each window
  its own entry, captioned with the window title (read from the window list, or from
  Accessibility when macOS withholds titles without Screen Recording access).
- **Apps in the switcher.** Regular apps with a window on this Space, plus menu-bar apps
  (TabStash itself included) while one of their windows is open, on this Space or
  another one.
  The list in Settings collects every app the switcher has shown, so an app stays
  there after you quit it, plus anything already hidden. Unchecking an app
  hides it from the switcher permanently (a blacklist). "Add App…" lets you pick any
  .app from /Applications, even one that is not running.

The settings window also has a "Buy me a coffee" button, which opens
<https://www.buymeacoffee.com/artbonvic>.

Settings are stored in UserDefaults under `dev.artem.tabstash`.

## How Space membership is detected

Primary path: private SkyLight functions (`CGSCopyManagedDisplaySpaces`,
`CGSCopySpacesForWindows`) loaded with `dlsym`. They answer precisely, including
minimized windows and hidden apps. If Apple removes them, the app falls back to the
public API (`kCGWindowIsOnscreen`), where minimized windows are not counted.

A window that is not on screen only counts when the app also reports it through
Accessibility. Apps keep internal windows that look real in the window list (Chrome has
several), and they would otherwise appear as extra entries. Accessibility answers about
the Space in front only, so the confirmed window IDs of each app are remembered and
reused when looking at it from another Space; an app that has never answered keeps all
its windows.

Check detection without Accessibility access:

```sh
build/TabStash.app/Contents/MacOS/TabStash --list
```

Ask the app itself what it sees (its own Accessibility and Screen Recording rights,
which a binary started from a terminal does not have) and read the report:

```sh
open build/TabStash.app --args --dump
cat ~/Library/Logs/TabStash-dump.txt
```

Open the settings window at launch:

```sh
open build/TabStash.app --args --settings
```

## Signing

macOS ties the Accessibility grant to the app's code signature. Ad-hoc signatures
change with every build, so the grant would have to be redone each time. `make-cert.sh`
creates a self-signed identity "TabStash Dev" in the login keychain (it does not
need to be trusted), and `build.sh` signs with it automatically. Another certificate
can be used with `SIGN_IDENTITY="Name" ./build.sh`.

## Limitations

- Private APIs may change in future macOS versions.
- A fullscreen app occupies its own Space, so on that Space the switcher shows only it,
  which matches Mission Control.
