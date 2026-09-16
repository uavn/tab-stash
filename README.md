# TabStash

A Cmd+Tab replacement for macOS that shows **only the apps with windows on the current
Space**. Written in Swift, builds without Xcode.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5-orange)

## Download

Every push builds the app on CI: open the
[Actions](https://github.com/uavn/tab-stash/actions) tab, pick a run and download the
**TabStash** artifact. Tagged versions (`v1.0` and so on) also appear under
[Releases](https://github.com/uavn/tab-stash/releases).

CI builds are signed ad-hoc, not notarized, so macOS quarantines them:

```sh
xattr -dr com.apple.quarantine TabStash.app
```

Because an ad-hoc signature changes with every build, the Accessibility grant has to be
given again after each download. Building locally with `./make-cert.sh` avoids that.

## Build

```sh
./build.sh
open build/TabStash.app
```

The app lives in the menu bar and needs Accessibility access
(System Settings → Privacy & Security → Accessibility) to take over Cmd+Tab.

## Keys

| Keys | Action |
|---|---|
| Cmd+Tab | open the switcher / next app |
| Cmd+Shift+Tab, arrows | previous / move through the list |
| release Cmd | activate the selection |
| Esc | close without switching |
| Cmd+Q, Cmd+H | quit / hide the selected app |

## Settings

Menu bar icon → "Settings…":

- **Show only apps from the current Space** — off lists every Space, like the system switcher.
- **Group all windows of an app** — off gives each window its own entry.
- **Show minimized and hidden apps** — dimmed entries; picking one brings the window back.
- **Order** — recently used, name, or window order.
- **Appearance** and **Glass** — follow the system, or pin light/dark and how solid the panel is.
- **App list** — every app the switcher has shown; uncheck one to hide it for good.

## Notes

Window and Space detection leans on private SkyLight calls, window focus on the
technique AltTab and yabai use. [NOTES.md](NOTES.md) explains how it works, what macOS 27
changed, and what had to be given up.

## License

GPL-3.0 — see [LICENSE](LICENSE).
