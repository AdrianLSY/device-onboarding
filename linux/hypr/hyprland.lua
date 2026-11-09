-- ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
-- ┃                 CachyOS Hyprland Configuration              ┃
-- ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
--
-- Hyprland 0.57 reads only this Lua file: it removed the hyprlang .conf format
-- this setup used up to 0.56, and this file is a line-for-line port of it.
-- Options: https://wiki.hypr.land/configuring/
-- Editor completion: /usr/share/hypr/stubs/hl.meta.lua
-- Check a change without applying it:
--   Hyprland --verify-config -c ~/.config/hypr/hyprland.lua

local mainMod = "ALT"

-- ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
-- ┃                            Colors                           ┃
-- ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

local white     = "rgba(ffffffff)"
local grayLight = "rgba(ccccccff)"
local gray      = "rgba(888888ff)"
local grayDark  = "rgba(444444ff)"
local black     = "rgba(000000ff)"

-- ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
-- ┃                           Programs                          ┃
-- ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

local filemanager          = "nemo"
local terminal             = "alacritty"
local screenshotFullscreen = [[grim - | swappy -f -]]
local screenshotSelection  = [[grim -g "$(slurp)" - | swappy -f -]]
local clipboard            = [[vicinae 'vicinae://launch/clipboard/history?toggle=true']]
local powermenu            = [[vicinae 'vicinae://launch/power?toggle=true']]
local applauncher          = [[vicinae toggle]]
local keepassxc            = [[vicinae 'vicinae://launch/@system7/store.vicinae.keepassxc/search?toggle=true']]
local bitwarden            = [[vicinae 'vicinae://launch/@bl4zee1g/store.vicinae.bitwarden/browse-vault?toggle=true']]
local tailscale            = [[vicinae 'vicinae://launch/@samlinville/store.raycast.tailscale?toggle=true']]
local emoji                = [[vicinae 'vicinae://launch/core/search-emojis?toggle=true']]

-- ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
-- ┃                         Environment                         ┃
-- ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
-- The third argument (true) also exports the variable to systemd and D-Bus,
-- as the old `envd` keyword did.

hl.env("HYPRCURSOR_SIZE", "24", true)
hl.env("XCURSOR_SIZE", "24", true)
hl.env("QT_CURSOR_SIZE", "24", true)
-- Kept exactly as before: hyprlang never expanded $HOME here, so the last
-- entry has always been the literal text "$HOME/.local/share".
hl.env("XDG_DATA_DIRS", "/var/lib/flatpak/exports/share:/usr/local/share:/usr/share:$HOME/.local/share", true)
hl.env("QT_QPA_PLATFORMTHEME", "qt5ct", true)
hl.env("GTK_THEME", "Adwaita:dark", true)

-- ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
-- ┃                           Monitors                          ┃
-- ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
-- https://wiki.hypr.land/configuring/core/monitors/

-- ASUS VG27A on HDMI-A-1 — 1440p @ 144Hz
hl.monitor({ output = "HDMI-A-1", mode = "2560x1440@144", position = "0x0", scale = 1 })

-- Catch-all: any connected monitor uses its preferred mode, auto-positioned
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })

-- If you need to scale things like steam etc, uncomment these lines and adjust
-- GDK_SCALE to your liking.
-- hl.config({ xwayland = { force_zero_scaling = true } })  -- Unscale XWayland
-- hl.env("GDK_SCALE", "1.25")                              -- GDK Scaling Factor

-- ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
-- ┃                          Autostart                          ┃
-- ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
-- https://wiki.hypr.land/configuring/core/autostart/
-- Runs once, when Hyprland starts (not on reload), like the old exec-once.
-- Each command goes through `sh -c` exactly as it did before.

local autostart = {
    [[swaybg -o \* -i ~/.config/hypr/wallpaper/Brisbane_cityscape_6000x4000.jpeg -m fill]],
    [[waybar &]],
    [[~/.config/hypr/scripts/screen-corners &]],
    [[fcitx5 -d &]],
    [[mako &]],
    [[nm-applet --indicator &]],
    [[bash -c "mkfifo /tmp/$HYPRLAND_INSTANCE_SIGNATURE.wob && tail -f /tmp/$HYPRLAND_INSTANCE_SIGNATURE.wob | wob & disown" &]],
    [[/usr/lib/polkit-kde-authentication-agent-1 &]],

    -- Slow app launch fix
    [[systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP &]],
    [[hash dbus-update-activation-environment 2>/dev/null &]],
    [[dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP &]],

    -- Idle configuration: the old config ran `exec-once = $idlehandler`, but
    -- $idlehandler was never defined anywhere, so it ran nothing. Left out.

    -- Wallpaper: swaybg, above.

    -- Dark mode by default
    [[gsettings set org.gnome.desktop.interface color-scheme "prefer-dark"]],

    -- Vicinae (launcher, clipboard history, power menu) starts from its systemd
    -- user service, which setup/tweak/vicinae.sh enables.

    -- Unmute USB DAC on startup
    [[sleep 1 && ~/.config/hypr/scripts/unmute-dac &]],
    [[sleep 1 && noisetorch -i &]],

    -- Start Apps (workspace assignment handled by window rules)
    [[steam &]],
    [[keepassxc &]],
    [[bitwarden-desktop &]],
    [[claude-desktop &]],
    [[chatgpt &]],
    [[cider &]],
    [[nm-applet &]],
    [[tableplus &]],
    [[blueman-applet &]],
    [[org.cryptomator.Cryptomator &]],
    [[flatpak run com.ultimaker.cura &]],
    [[flatpak run md.obsidian.Obsidian &]],
    [[flatpak run dev.deedles.Trayscale &]],
    [[flatpak run com.getpostman.Postman &]],
    [[flatpak run org.mozilla.thunderbird &]],
    [[flatpak run com.bambulab.BambuStudio &]],
    [[flatpak run com.dropbox.Client start &]],
    [[flatpak run org.localsend.localsend_app &]],
    [[~/.config/hypr/scripts/start-vivaldi &]],
    [[/opt/vivaldi/vivaldi --profile-directory=Default --app-id=magkoliahgffibhgfkmoealggombgknl &]],
    [[/opt/vivaldi/vivaldi --profile-directory=Default --app-id=hnpfjngllnobngcgfapefoaidbinmjnm &]],
    [[/opt/vivaldi/vivaldi --profile-directory=Default --app-id=pommaclcbfghclhalboakcipcmmndhcj &]],
    [[/opt/vivaldi/vivaldi --profile-directory=Default --app-id=kjbdgfilnfhdoflbpgamdcdgpehopbep &]],
}

hl.on("hyprland.start", function()
    for _, cmd in ipairs(autostart) do
        hl.exec_cmd(cmd)
    end
end)

-- ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
-- ┃                           Options                           ┃
-- ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
-- https://wiki.hypr.land/configuring/core/config-options/

hl.config({
    general = {
        -- No borders, like macOS windows
        border_size = 0,
        col = {
            active_border   = white,
            inactive_border = grayDark,
        },
        layout = "dwindle", -- master|dwindle

        snap = {
            enabled = true,
        },
    },

    group = {
        col = {
            border_active          = grayLight,
            border_inactive        = grayDark,
            border_locked_active   = gray,
            border_locked_inactive = grayDark,
        },

        groupbar = {
            font_family = "Fira Sans",
            text_color  = white,
            col = {
                active          = gray,
                inactive        = grayDark,
                locked_active   = gray,
                locked_inactive = grayDark,
            },
        },
    },

    misc = {
        font_family           = "Fira Sans",
        splash_font_family    = "Fira Sans",
        disable_hyprland_logo = true,
        col = {
            splash = white,
        },
        background_color  = black,
        enable_swallow    = true,
        swallow_regex     = [[^(cachy-browser|firefox|nautilus|nemo|thunar|btrfs-assistant.)$]],
        focus_on_activate = true,
        vrr               = 2,
    },

    -- vfr moved from misc to debug in Hyprland 0.55
    debug = {
        vfr = true,
    },

    render = {
        direct_scanout = true,
    },

    -- dwindle/master special_scale_factor = 0.8 is gone: Hyprland 0.57 no
    -- longer reads it (it only raises a deprecation notice), and nothing here
    -- opens a special workspace.
    dwindle = {
        -- pseudotile removed in Hyprland 0.55 (was non-functional)
        preserve_split = true,
    },

    master = {
        new_status = "master",
    },

    input = {
        kb_layout                   = "us",
        kb_variant                  = "mac",
        follow_mouse                = 1, -- 0|1|2|3
        float_switch_override_focus = 2,
    },

    decoration = {
        active_opacity = 1,
        -- Matches the macOS window corners. scripts/screen-corners rounds the
        -- screen with the same radius, so a window that fills the screen lines
        -- up with it.
        rounding = 12,

        blur = {
            size   = 15,
            passes = 3, -- more passes = more resource intensive.
            xray   = true,
        },

        -- A soft macOS-style drop shadow under every window, a little lower
        -- than it is wide.
        shadow = {
            enabled      = true,
            range        = 40,
            render_power = 3,
            color        = "rgba(00000066)",
            offset       = { 0, 12 },
        },
    },

    animations = {
        enabled = true,
    },

    binds = {
        allow_workspace_cycles            = true,
        workspace_back_and_forth          = false,
        workspace_center_on               = 1,
        movefocus_cycles_fullscreen       = true,
        window_direction_monitor_fallback = true,
    },
})

-- ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
-- ┃                          Animations                         ┃
-- ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
-- https://wiki.hypr.land/configuring/core/animations/

-- Disable non-layer animations
hl.animation({ leaf = "workspaces", enabled = false })
hl.animation({ leaf = "border", enabled = false })
hl.animation({ leaf = "borderangle", enabled = false })

-- Layer animations for notifications
hl.animation({ leaf = "layers", enabled = true, speed = 3, bezier = "default", style = "slide" })

-- ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
-- ┃                           Keybinds                          ┃
-- ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
-- https://wiki.hypr.land/configuring/core/binds/

local function bind(keys, dispatcher, description)
    if description then
        return hl.bind(keys, dispatcher, { description = description })
    end
    return hl.bind(keys, dispatcher)
end

bind("CTRL + Q", hl.dsp.window.close(), "Closes (not kill) current window")
bind("CTRL + SHIFT + 4", hl.dsp.exec_cmd(screenshotSelection), "Screen capture selection")
bind("CTRL + SHIFT + 3", hl.dsp.exec_cmd(screenshotFullscreen), "Screen capture full screen")
bind("SUPER + SPACE", hl.dsp.exec_cmd(applauncher), "Runs your application launcher (Cmd+Space)")
bind("CTRL + SPACE", hl.dsp.exec_cmd(filemanager), "Opens your preferred file manager")
bind("SUPER + V", hl.dsp.exec_cmd(clipboard), "Opens clipboard manager (Ctrl+V)")
bind("SUPER + K", hl.dsp.exec_cmd(keepassxc), "Opens KeePassXC search (Ctrl+K)")
bind("SUPER + J", hl.dsp.exec_cmd(bitwarden), "Opens Bitwarden vault (Ctrl+J)")
bind("SUPER + T", hl.dsp.exec_cmd(tailscale), "Opens Tailscale commands (Ctrl+T)")
bind("SUPER + E", hl.dsp.exec_cmd(emoji), "Opens emoji picker (Ctrl+E)")
bind(mainMod .. " + SPACE", hl.dsp.exec_cmd(terminal), "Opens your preferred terminal emulator")

-- Cmd+Tab → Alt+Tab → cycle windows
bind(mainMod .. " + Tab", hl.dsp.window.cycle_next())
bind(mainMod .. " + SHIFT + Tab", hl.dsp.window.cycle_next({ next = false }))

-- ======= Desktop Settings =======

bind("ALT + F1", hl.dsp.exec_cmd("killall -SIGUSR2 waybar"), "Reload/restarts Waybar")
bind(mainMod .. " + Escape", hl.dsp.exec_cmd(powermenu), "Show power menu")

-- ======= Window Actions =======

-- Resize/move window with mainMod+SHIFT + LMB/RMB and dragging
hl.bind(mainMod .. " + SHIFT + mouse:273", hl.dsp.window.resize(), { mouse = true }) -- Resize the window towards a direction
hl.bind(mainMod .. " + SHIFT + mouse:272", hl.dsp.window.drag(), { mouse = true })   -- Drag window

-- Workspaces 1-10 and 11 (on grave), then the named ones, A-Z without P.
local numbered = {
    { key = "grave", ws = 11 },
    { key = "1", ws = 1 }, { key = "2", ws = 2 }, { key = "3", ws = 3 },
    { key = "4", ws = 4 }, { key = "5", ws = 5 }, { key = "6", ws = 6 },
    { key = "7", ws = 7 }, { key = "8", ws = 8 }, { key = "9", ws = 9 },
    { key = "0", ws = 10 },
}
local lettered = {}
for letter in ("ABCDEFGHIJKLMNOQRSTUVWXYZ"):gmatch(".") do
    lettered[#lettered + 1] = letter
end

-- Each entry: the key, the workspace selector, and its label in descriptions.
local workspaceKeys = {}
for _, n in ipairs(numbered) do
    workspaceKeys[#workspaceKeys + 1] = { key = n.key, ws = n.ws, label = tostring(n.ws) }
end
for _, letter in ipairs(lettered) do
    workspaceKeys[#workspaceKeys + 1] = { key = letter, ws = "name:" .. letter, label = letter }
end

-- Move active window to a workspace with mainMod + CTRL
for _, w in ipairs(workspaceKeys) do
    bind(mainMod .. " + CTRL + " .. w.key, hl.dsp.window.move({ workspace = w.ws }),
        "Move window and switch to workspace " .. w.label)
end

-- Same as above, but doesn't switch to the workspace
for _, w in ipairs(workspaceKeys) do
    bind(mainMod .. " + SHIFT + " .. w.key, hl.dsp.window.move({ workspace = w.ws, follow = false }),
        "Move window silently to workspace " .. w.label)
end

-- ======= Workspace Actions =======

-- Switch workspaces with mainMod
for _, w in ipairs(workspaceKeys) do
    bind(mainMod .. " + " .. w.key, hl.dsp.focus({ workspace = w.ws }), "Switch to workspace " .. w.label)
end

-- ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
-- ┃                         Window rules                        ┃
-- ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
-- https://wiki.hypr.land/configuring/core/rules/window-rules/
-- All anonymous, so they apply top to bottom as the old lines did.

local function rule(match, effects)
    effects.match = match
    return hl.window_rule(effects)
end

-- Disable all animations on windows (keep only for layers/notifications)
rule({ class = ".*" }, { no_anim = true })

-- Float Necessary Windows
rule({ class = [[^(org.pulseaudio.pavucontrol)]] }, { float = true })
rule({ class = [[^()$]], title = [[^(Picture in picture)$]] }, { float = true })
rule({ class = [[^()$]], title = [[^(Save File)$]] }, { float = true })
rule({ class = [[^()$]], title = [[^(Open File)$]] }, { float = true })
rule({ class = [[^(LibreWolf)$]], title = [[^(Picture-in-Picture)$]] }, { float = true })
rule({ class = [[^(blueman-manager)$]] }, { float = true })
rule({ class = [[^(xdg-desktop-portal-gtk|xdg-desktop-portal-kde|xdg-desktop-portal-hyprland)(.*)$]] }, { float = true })
rule({ class = [[^(polkit-gnome-authentication-agent-1|hyprpolkitagent|org.org.kde.polkit-kde-authentication-agent-1)(.*)$]] }, { float = true })
rule({ class = [[^(CachyOSHello)$]] }, { float = true })
rule({ class = [[^(zenity)$]] }, { float = true })
rule({ class = [[^()$]], title = [[^(Steam - Self Updater)$]] }, { float = true })

-- Increase the opacity
rule({ class = [[^(thunar|nemo)$]] }, { opacity = "0.92" })
rule({ class = [[^(discord|armcord|webcord)$]] }, { opacity = "0.96" })
rule({ title = [[^(QQ|Telegram)$]] }, { opacity = "0.95" })
rule({ title = [[^(NetEase Cloud Music Gtk4)$]] }, { opacity = "0.95" })

-- General window rules
-- `move 25% 25%` is ported as written. Since Hyprland's rule rewrite, move
-- takes math expressions, which have no % sign, so this move has not been
-- applied since before 0.57 either; `monitor_w*0.25 monitor_h*0.25` would.
rule({ title = [[^(Picture-in-Picture)$]] }, { float = true })
rule({ title = [[^(Picture-in-Picture)$]] }, { size = { 960, 540 } })
rule({ title = [[^(Picture-in-Picture)$]] }, { move = "25% 25%" })
rule({ title = [[^(imv|mpv|danmufloat|termfloat|nemo|ncmpcpp)$]] }, { float = true })
rule({ title = [[^(imv|mpv|danmufloat|termfloat|nemo|ncmpcpp)$]] }, { move = "25% 25%" })
rule({ title = [[^(imv|mpv|danmufloat|termfloat|nemo|ncmpcpp)$]] }, { size = { 960, 540 } })
rule({ title = [[^(danmufloat)$]] }, { pin = true })
rule({ title = [[^(danmufloat|termfloat)$]] }, { rounding = 0 })
rule({ class = [[^(Alacritty)$]] }, { animation = "slide right" })
rule({ class = [[^(org.mozilla.firefox)$]] }, { no_blur = true })

-- ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
-- ┃                       Workspace rules                       ┃
-- ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
-- https://wiki.hypr.land/configuring/core/rules/workspace-rules/
-- hl.workspace_rule({ workspace = "1", default = true, monitor = priMon })
-- hl.workspace_rule({ workspace = "6", default = true, monitor = secMon })
-- hl.workspace_rule({ workspace = "r[1-5]", monitor = priMon })
-- hl.workspace_rule({ workspace = "r[6-10]", monitor = secMon })
-- Smart gaps: no outer gaps on a workspace with 1-10 tiled windows, or with a
-- maximized window.
hl.workspace_rule({ workspace = "w[tv1-10]", gaps_out = 0, gaps_in = -1 })
hl.workspace_rule({ workspace = "f[1]", gaps_out = 0, gaps_in = -1 })

-- Application workspace assignments
rule({ class = [[^(steam)$]] }, { workspace = "name:G" })
rule({ class = [[^(md.obsidian.Obsidian)$]] }, { workspace = "name:O" })
rule({ class = [[^([Cc]ider)$]] }, { workspace = "name:S" })
rule({ class = [[^(KeePassXC)$]] }, { workspace = "name:K" })
rule({ class = [[^(Bitwarden)$]] }, { workspace = "name:J" })
rule({ class = [[^(com.anthropic.Claude)$]] }, { workspace = "name:A" })
rule({ class = [[^(Chatgpt)$]] }, { workspace = "name:X" })
rule({ class = [[^(TablePlus)$]] }, { workspace = "name:D" })
rule({ class = [[^(org.localsend.localsend_app)$]] }, { workspace = "name:L" })
rule({ class = [[^(BambuStudio)$]] }, { workspace = "name:B" })
rule({ class = [[^(UltiMaker-Cura)$]] }, { workspace = "name:U" })
rule({ class = [[^(dev.deedles.Trayscale)$]] }, { workspace = "name:T" })
rule({ class = [[^(org.mozilla.thunderbird)$]] }, { workspace = "name:M" })
rule({ class = [[^(org.cryptomator.launcher.Cryptomator\$MainApp)$]] }, { workspace = "name:F" })
rule({ class = [[^(vivaldi-magkoliahgffibhgfkmoealggombgknl-Default)$]] }, { workspace = "name:Q" })
rule({ class = [[^(vivaldi-hnpfjngllnobngcgfapefoaidbinmjnm-Default)$]] }, { workspace = "name:W" })
rule({ class = [[^(vivaldi-pommaclcbfghclhalboakcipcmmndhcj-Default)$]] }, { workspace = "name:E" })
rule({ class = [[^(vivaldi-kjbdgfilnfhdoflbpgamdcdgpehopbep-Default)$]] }, { workspace = "name:R" })

-- ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
-- ┃                         Layer rules                         ┃
-- ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
-- https://wiki.hypr.land/configuring/core/rules/layer-rules/

hl.layer_rule({ match = { namespace = "negative:notifications" }, no_anim = true })
hl.layer_rule({ match = { namespace = "notifications" }, animation = "slide top" })
-- Blur behind Vicinae's translucent window. The no_anim rule above covers it too.
hl.layer_rule({ match = { namespace = "vicinae" }, blur = true, ignore_alpha = 0 })
