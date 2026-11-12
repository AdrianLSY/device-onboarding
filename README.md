# Device Onbording

My personal dotfiles for **macOS, Linux, and Windows**, plus a `setup.sh`
bootstrap that provisions a fresh machine (packages + system tweaks) and deploys
these configs.

The repo lives at an **external** path (e.g. `~/.dotfiles`), **not** at
`~/.config`. On macOS/Linux it deploys config *into* `~/.config` by per-app
**symlink** (`~/.config/<app>` → `~/.dotfiles/<tier>/<app>`), so editing through
the symlink is still editing the repo. Windows has no single `~/.config`, so it
deploys by an explicit manifest to per-app targets (see below).

## Layout

Content is split into OS **tiers**; the OS is chosen at runtime via `uname`:

- `macos/` — the macOS machine: `zsh/`, `zed/`, `ghostty/`, `aerospace/`,
  `vivaldi/`, `bin/` (`ssh-keypick`, `via-macro`), `micro/`, `starship.toml`, and
  its own `setup/` (`brew`, `tweak`).
- `linux/` — the Linux (Arch/CachyOS) machine: `fish/`, `hypr/`, `waybar/`,
  `alacritty/`, `mako/`, `vicinae/`, `swaylock/`, `nvim/`, `btop/`, `tmux/`, `gtk-*`,
  `qt5ct/`, `qt6ct/`, `zed/`, `micro/`, `pipewire/`, `vivaldi-css/`,
  `vivaldi-stable.conf`, `mimeapps.list`, `bin/` (a
  symlink to `../macos/bin`, so both tiers share `ssh-keypick` and `via-macro`), and its own
  `setup/` (`pacman`, `yay`, `flatpak`, `app`, `asdf`, `tweak`).
- `windows/` — the native-Windows (Git Bash/MSYS) machine: its `setup/`
  (`winget`, `tweak`) and a `.links` deploy manifest. Selected when `uname -s`
  reports `MINGW*`/`MSYS*`/`CYGWIN*` (WSL reports `Linux` → the `linux` tier).
  Ships with cascade + deploy plumbing and a full `winget` package set; no app
  configs yet.
- `lib/link.sh` — the shared symlink helper (bootstrap code, not config).
- Repo meta at the root (`setup.sh`, `README.md`, `CLAUDE.md`, `.gitignore`, …)
  is never symlinked into `~/.config`.

There is no `common/` tier: genuinely-shared config (`micro/`, and `zed/` with a
per-tier `settings.json`) is duplicated into both tiers by design. Shared code is
not duplicated: `linux/bin` links to `macos/bin`, and the Linux tweaks
`bitwarden-server.sh`, `graphify.sh`, `pre-commit.sh` and `ssh-keypick.sh` run
the macOS scripts of the same name.

## Bootstrap

Clone anywhere and run `setup.sh` — there is no in-place mode; it always deploys
by symlink.

```sh
git clone https://github.com/AdrianLSY/config.git ~/.dotfiles
~/.dotfiles/setup.sh
```

`setup.sh`:

1. **Refuses to run as root** — never `sudo ./setup.sh`.
2. **Detects the OS** via `uname -s` and selects the `macos`, `linux`, or
   `windows` tier (errors on anything else).
3. On Windows, runs a **preflight** (before any change): errors out if `winget`
   is missing or a native symlink can't be created (Developer Mode off).
4. Runs a **repo-scoped, mode-preserving** `chmod u+rwX` (never touches
   `~/.config` or `.git`, and never flips git-tracked file modes — a bootstrap
   leaves `git status` clean).
5. On macOS, **ensures Command Line Tools** (git + clang, which Homebrew needs).
6. **Deploys the tier's configs** — macOS/Linux symlink each app dir into
   `~/.config` via backup-then-link (skipping the reserved `setup/`); Windows
   links each app to its manifest destination (`windows/.links`).
7. Runs the tier's `setup/.setup.sh` cascade (macOS: `brew` → `tweak`; Linux:
   `pacman` → `yay` → `flatpak` → `app` → `asdf` → `tweak`; Windows: `winget` →
   `tweak`), then exits with the cascade's true status. The runners provision
   what a fresh machine lacks: the macOS runner puts brew on `PATH` for the
   tweak phase (a first run from a stock terminal works end-to-end), the
   flatpak runner adds the `flathub` remote, and the asdf runner creates
   `~/.tool-versions`.

### Backup-then-link (safe on a machine with an existing `~/.config`)

For each app dir/file in the tier, `setup.sh`:

- **leaves it alone** if `~/.config/<app>` is already the correct symlink (no-op);
- **backs it up** to `<app>.bak.<timestamp>` if a real dir/file or a different
  symlink is in the way, then creates the symlink;
- **creates the symlink** if nothing is there.

Nothing is ever overwritten without a timestamped backup, and **unmanaged
`~/.config` entries** (`gh/`, `uv/`, `raycast/`, …) are never touched. Re-running
is idempotent. To roll back an app: remove its symlink and restore the `.bak.<ts>`.

The same rule extends to the tweaks: the macOS zsh tweak backs up a
pre-existing `~/.zshrc`/`~/.zprofile` to `<file>.bak.<timestamp>` instead of
deleting it, and a re-run of the whole bootstrap makes zero changes — no new
backups, no package reinstalls, and a clean `git status` in the repo.

### Prerequisites

- **macOS** — Command Line Tools (git + clang); `setup.sh` installs them for you;
  if the automated install stalls, run `xcode-select --install` and re-run.
- **Linux** — a working `pacman` (CachyOS/Arch base) is assumed; the bootstrap
  installs `yay` and the rest.
- **Windows** — install **Git for Windows** (Git Bash) and the **`winget`
  client** (App Installer / Windows Package Manager), and enable **Developer
  Mode** (Settings → Privacy & security → For developers) so native symlinks can
  be created without elevation. Then clone to `~/.dotfiles` and run
  `./setup.sh` **from Git Bash**. The preflight verifies these before any change.

### BetterDisplay Pro color mode (macOS)

The bootstrap installs BetterDisplay, but its Pro license and display settings
live in the app's user profile. In the BetterDisplay menu, expand the controls
for each external display, select **8-bit RGB Full Range** under **Color Mode**,
then enable **Configuration Protection → Color Mode**. Keep BetterDisplay set to
start at login so its Pro
protection can restore the selected mode after sleep or reconnect. These app
settings replace the former 15-second RGB LaunchAgent.

The selected mode must be available for the display's current resolution and
refresh rate. BetterDisplay's [CLI guide](https://github.com/waydabber/BetterDisplay/wiki/Integration-features,-CLI)
documents how to inspect the available connection modes when troubleshooting.

### Power, locking and charging (macOS)

`macos/setup/tweak/power-policy.sh` installs the `com.adrian.power-policy`
LaunchAgent. It keeps the Mac running with network access according to this
truth table, agreed on 9 November 2026 with Raycast Coffee's **Prevent display
sleep** on. The configured window is macOS's own display sleep and system sleep
setting for the current power source.

| # | External monitor(s) | Coffee | Power | Lid | Mac state | Mac screen | Monitor screens | Lock |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | connected | on | charger | open | stay awake | stay on | stay on | don't lock |
| 2 | connected | on | charger | closed | stay awake | stay off | stay on | don't lock |
| 3 | connected | on | battery | open | stay awake | stay on | stay on | don't lock |
| 4 | connected | on | battery | closed | stay awake | stay off | stay on | don't lock |
| 5 | connected | off | charger | open | stay awake | turn off after configured window | turn off after configured window | the moment the screen / monitor turns off |
| 6 | connected | off | charger | closed | stay awake | stay off | turn off after configured window | the moment the screen / monitor turns off |
| 7 | connected | off | battery | open | sleep after configured window | turn off after configured window | turn off after configured window | the moment the screen / monitor turns off |
| 8 | connected | off | battery | closed | sleep after configured window | stay off | turn off after configured window | the moment the screen / monitor turns off |
| 9 | none | on | charger | open | stay awake | stay on | none | don't lock |
| 10 | none | on | charger | closed | stay awake | stay off | none | lock |
| 11 | none | on | battery | open | stay awake | stay on | none | don't lock |
| 12 | none | on | battery | closed | stay awake | stay off | none | lock |
| 13 | none | off | charger | open | stay awake | turn off after configured window | none | the moment the screen / monitor turns off |
| 14 | none | off | charger | closed | stay awake | stay off | none | lock |
| 15 | none | off | battery | open | sleep after configured window | turn off after configured window | none | the moment the screen / monitor turns off |
| 16 | none | off | battery | closed | sleep | stay off | none | lock |

Events:

- Plugging in a monitor turns that monitor on.
- Pressing Escape on the lock screen turns the screens off; apps keep running.
  In rows 7 and 8 the Mac then sleeps, as it does when the monitor turns off
  from idle.
- Unplugging the monitor while the lid is closed acts like closing the lid
  (rows 10, 12, 14 or 16).
- Turning Coffee on while the lid is already closed does not lock.
- Unlocking after a lid-close lock does not lock again.

Raycast Coffee remains the manual override. The controller recognizes a live
`/usr/bin/caffeinate` process belonging to the logged-in user; another app that
starts the same command also counts as an override. A connected external monitor
takes priority over lid-close locking, with Coffee either on or off and even
when the hub does not provide charging power. Opening or closing the lid while
docked preserves the active session and monitor output.

Without an external monitor, Coffee on makes an observed open-to-closed lid
transition lock the session and blank the displays while apps and networking
keep running. Turning Coffee on while the lid is already closed does not
interrupt the current session, and unlocking after a lid-close lock does not
cause repeated locking. With Coffee off, closing the lid on a charger locks the
session and blanks the displays while apps keep running, as with Coffee on; on
battery it locks and sleeps. Physical AC power keeps the Mac awake with the lid
open or closed.
A temporary macOS headless “Generic Display” placeholder does not count as a
connected monitor; normal USB/DisplayLink and mirrored monitors remain eligible.
Disconnecting the monitor while the lid is closed restores the undocked
Coffee-dependent rule. Power changes, Coffee toggles and controller restarts
preserve an active docked session.

Docked on battery with Coffee off (rows 7 and 8), the controller keeps the Mac
awake while the monitor is on, so closing the lid never sleeps it. Once the
monitor turns off, which locks the session, the controller lets the Mac sleep,
whatever turned it off: macOS's idle display sleep, Escape on the lock screen,
a hot corner or `pmset displaysleepnow`. With the lid closed it releases the
sleep block and requests sleep. With the lid open it releases the block and
leaves the moment to macOS's battery sleep setting, as in row 15. Keyboard or
mouse input after the screen goes off, or the monitor turning back on,
restores the block, so a key press that wakes a closed Mac keeps it awake. In
every other row, Escape only turns the screens off. The controller still runs
no inactivity timer of its own.

The hub's charging input drops for about a second roughly every 11 seconds, so
the controller counts the charger as gone only after 30 continuous seconds on
battery, and as back at once. A short drop never flips the sleep block or
sleeps a closed Mac; unplugging does after 30 seconds. The same 30 seconds apply
when the controller starts on battery.

Attaching a newly online external display makes one native display-wake request;
display sleep itself never triggers another wake. On the lock screen, Escape
turns displays off while apps and networking continue. Keyboard or mouse input
wakes the displays; normal authentication still applies. Escape is not remapped
inside applications. Unknown hubs may require macOS accessory approval before
their display, keyboard or mouse can work. Waking from full system sleep also
requires the hub/connection to generate a native hardware wake; the user agent
cannot execute while the CPU is asleep.

In **Raycast Settings → Coffee**, turn **Prevent display sleep** on, leave
**Prevent system sleep** on and leave **Prevent system sleep on AC power** off.
With Coffee on, the displays stay awake when the Mac is docked, or undocked
with the lid open, and macOS no longer locks or sleeps the display on idle.
Undocked with Coffee on, closing the lid still locks once and blanks the
displays, and Escape on the lock screen still blanks them: neither depends on
Coffee's display setting. With Coffee off, macOS owns idle display sleep and
locking, and the table above says when the Mac sleeps.
The controller does not run an independent inactivity timer.

Configure **AlDente → Settings → Battery Care** as follows:

- **Charge Limit: 80%** (or the limit you choose later).
- Keep native macOS charge control enabled on supported macOS versions.
- **Sleep Behavior: Continue like before.** The power controller owns sleep;
  AlDente's other sleep modes conflict with this policy.
- **Sailing Mode: off**, so charging targets the selected limit rather than a
  lower sailing threshold.
- **Automatic Discharge: off**, so AlDente does not imitate unplugging.
- Keep Heat Protection enabled; it can pause charging while the battery is hot.

AlDente owns the charge limit independently of the lid policy. This Mac has
native charge control enabled and an active macOS 80% charge-limit policy;
the sleep controller does not change charging settings. The Mac stays
awake on AC with the lid open or closed, or with Coffee on; on battery with
Coffee off it sleeps as the table above describes. macOS can occasionally force a full
charge for battery calibration;
[AlDente cannot prevent that system override](https://apphousekitchen.com/macbook-charges-to-100-despite-charge-limit/).

The installer requires **Lock Screen → Require password … Immediately** and
the existing narrow administrator permission for these exact commands:
`sudo -n /usr/bin/pmset disablesleep 0` and `… disablesleep 1`. It reuses the
permission installed by Vorssaint's closed-lid feature without adding sudo
access. Keep Vorssaint's own Keep Awake feature off so only one controller
writes the sleep setting. If either permission is absent, the installer stops
with instructions; it does not silently weaken permissions or password policy.

To install or refresh just this policy, run:

```sh
bash macos/setup/tweak/power-policy.sh
```

The executable is copied outside the repo to
`~/Library/Application Support/device-power-policy/power-policy` so launchd can
run it when the repo is under Documents. `--status` prints current sensors and
the desired power state from this instant's readings, without the 30-second
charger settle or the docked screen-off rule; `--check` checks prerequisites without changing them;
`--once --dry-run` previews actions. Logs are in
`~/Library/Logs/device-power-policy.log`. Starting the agent with the lid
already closed preserves an active docked session. A physical charger/lid test is still needed
after setup; a dry run does not prove a real sleep/wake transition.

### Launcher, clipboard history and power menu (Linux)

[Vicinae](https://docs.vicinae.com), a Raycast-like launcher that runs many
Raycast extensions, does all three; the Mac keeps Raycast. Its server runs as
the `vicinae.service` user unit, which the `vicinae.sh` tweak enables, and
Hyprland binds the keys:

| Keys | Opens |
| --- | --- |
| Cmd+Space (Super+Space) | The launcher |
| Ctrl+V (keyd sends it as Super+V) | Clipboard history |
| Ctrl+K (keyd sends it as Super+K) | KeePassXC: search the database |
| Ctrl+J (keyd sends it as Super+J) | Bitwarden: browse the vault, through rbw |
| Ctrl+T (keyd sends it as Super+T) | Tailscale: devices, connect, exit node and its other commands |
| Ctrl+E (keyd sends it as Super+E) | Emoji picker |
| Alt+Escape, or a click on the Waybar logo | Power commands, such as lock, suspend, log out, reboot and power off |

keyd sends only the physical Ctrl key's K, J, T, E and V as Super, so Cmd+K,
Cmd+T and the rest still reach apps as Ctrl (new tab, address bar, and so on),
and Ctrl+Alt or Ctrl+Shift with those letters reaches them unchanged.

The repo's settings are in `linux/vicinae/base.jsonc`. Changes made in Vicinae's
settings window (Ctrl+,) are written to `linux/vicinae/settings.json` and take
precedence. The `mac-black` theme, black and white like Waybar, is linked into
`~/.local/share/vicinae/themes` by the same tweak, because Vicinae loads themes
only from there. Raycast extensions install from Vicinae's
"Raycast Store" command (simpler ones work best), and Vicinae's own from its
"Store" command; both land in `~/.local/share/vicinae`, outside the repo.

The `vicinae-extensions.sh` tweak installs the three extensions behind those
keys the same way, unless they are already there:

- **KeePassXC**, from Vicinae's store, runs `keepassxc-cli` on
  `~/Dropbox/Keychain.kdbx`, set in `base.jsonc`. It asks for the database
  password on first use and then never locks, by choice. Until it locks, the
  database password and the extension's full export of the database (every
  entry's password, notes and TOTP secret) sit **unencrypted** in Vicinae's
  local storage, `~/.local/share/vicinae/vicinae.db`, and are never cleared
  while it never locks. Only processes running as your user can read it (the
  folder is mode 700). To have them cleared, set `lockAfterInactivity` in
  `base.jsonc` to a number of minutes. The first open shows "Something went
  wrong when accessing the database (exit code: 1)" before the unlock form,
  which is a bug in the extension, and the form submits with Ctrl+Enter. The
  database needs no key file.
- **Bitwarden (rbw)**, from Vicinae's store, runs
  [rbw](https://github.com/doy/rbw), a Bitwarden CLI that keeps the unlocked
  vault in an agent. The `rbw.sh` tweak points it at `https://vault.rooftop.my`
  as `adrian@rooftop.my`, the account the desktop app uses. Run `rbw login`
  once in a terminal; after that the extension offers to unlock, and rbw asks
  for the master password in a pinentry window and locks again after an hour.
- **Tailscale**, from Raycast's store (Vicinae's has none), runs
  `/usr/bin/tailscale`, set in `base.jsonc`. Connecting, disconnecting and
  picking an exit node need no sudo, because `app/tailscale.sh` makes you the
  operator.

The emoji picker is built into Vicinae.

### Mac-style keys (Linux)

keyd (`linux/setup/tweak/keyd/default.conf`) makes Cmd (Super) act as Ctrl, so
Cmd+C and Cmd+V copy and paste. A terminal would read Cmd+C as an interrupt, so
in Alacritty only, `keyd-application-mapper` (run by the
`keyd-application-mapper` user unit, set up by the tweak of the same name) sends
Cmd+C as Ctrl+Shift+C, which copies. Physical Ctrl+C still interrupts, and
other apps are unchanged. Its per-app bindings are in
`linux/setup/tweak/keyd/app.conf`. The tweak adds you to the `keyd` group with
`sudo`; the group applies at the next login, and until then the unit's `newgrp`
stands in for it. keyd leaves Vicinae's virtual keyboard alone (an exclusion in
`[ids]`), so what Vicinae types isn't remapped: its pasted Ctrl+V would otherwise
arrive as Super+V.

Never open keyd's socket (`/var/run/keyd.socket`) by hand: keyd 2.6.0 hangs,
with every keyboard dead, when a client connects and closes without sending a
whole message. Use the `keyd` command, and recover with
`sudo systemctl restart keyd` (from SSH, or after replugging the keyboard).

### VIA macro converter (macOS and Linux)

`macos/bin/via-macro` turns text on the clipboard into VIA macro text that the
FNK X V81PL keyboard plays correctly, and puts the result back on the
clipboard. Its macro player drops plain punctuation, ignores a second tap of a key
tapped a moment before, and swallows one character after a key release, so the
script writes every character other than a letter or digit as an explicit press
and release.
It prints only the character and byte counts, saves nothing, and stops, leaving
the clipboard unchanged, if the text is already VIA macro text (`--force` converts
it anyway).

Both tiers deploy it to `~/.config/bin/via-macro`, which is not on `PATH`. Copy
the plain text, run it, then paste into a slot in VIA's Macros tab:

```sh
python3 ~/.config/bin/via-macro
```

It needs only Python 3 and the platform's clipboard tool: `pbpaste` and `pbcopy`
on macOS, `wl-paste` and `wl-copy` (wl-clipboard) on Wayland, `xclip` or `xsel`
on X11. With none installed it says so and exits. Windows does not deploy it (the
tier ships no app configs), but it also reads the clipboard through `powershell`
or `pwsh`, so it runs from a clone with `python macos/bin/via-macro`.

## Adding things

- **Package:** create `<tier>/setup/<pkgmgr>/<pkg>.sh` (macOS `brew`; Linux
  `pacman`/`yay`/`flatpak`/`asdf`/`app`; Windows `winget`). For name-based
  managers **the filename minus `.sh` must equal the skip-check identifier** —
  the package leaf name for brew/pacman/yay (e.g. `aws-cli-v2.sh` to match
  `pacman -Q aws-cli-v2`), the full dotted winget id for winget
  (e.g. `Mozilla.Firefox.sh`).
- **System tweak:** create `<tier>/setup/tweak/<name>.sh`. Runs every bootstrap,
  so make it idempotent.
- **New app config:** create `<app>/` under the relevant tier. On macOS/Linux no
  `.gitignore` edits are needed — the conventional deny-list tracks it, and it's
  symlinked into `~/.config` automatically. On Windows, also add a
  `windows/.links` line mapping the app to its destination (Windows configs are
  not auto-deployed by directory).

## Runtime state & secrets

Because config dirs are whole-dir symlinks, anything an app **writes** into its
config dir (e.g. zsh's self-compiled `.zshrc.zwc`, `.zsh_history`, micro's
`backups/`) lands in the repo tree — so those runtime/generated paths are
gitignored. `.gitignore` is a conventional deny-list (everything tracked by
default; cruft, logs, and runtime state ignored).

A **gitleaks pre-commit hook** (`.pre-commit-config.yaml`, installed by the
bootstrap) scans every staged change and blocks commits containing secrets.

Tracked shell scripts (`*.sh`, `setup.sh`) and the Windows manifest
(`windows/.links`) are pinned to **LF** line endings via `.gitattributes`, so
they keep working under bash — including Git Bash on Windows — regardless of
your local `core.autocrlf` setting.

## Branches

A **single branch** carries all machines; the OS is selected at runtime by
`setup.sh`. (This replaced the old branch-per-machine model.)
