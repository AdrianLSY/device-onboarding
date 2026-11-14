function update --description 'Refresh mirrors, update pacman/AUR/flatpak/user-local tools/asdf/firmware, then cleanup'
    # linux/setup in the repo this file lives in: ~/.config/fish links into it,
    # and path resolve follows that link.
    set -l setup (path resolve (status dirname)/../../setup)

    sudo cachyos-rate-mirrors
    sudo reflector --latest 20 --sort rate --protocol https --save /etc/pacman.d/mirrorlist
    sudo pacman -Sy --noconfirm archlinux-keyring cachyos-keyring
    sudo pacman -Syyu --noconfirm
    PATH=/usr/bin:/bin yay -Sua --noconfirm --answerclean All --answerdiff None --answeredit None
    # The AUR packages linux/setup/yay lists that a CachyOS repo also builds:
    # -Sua skips them, so take the AUR's build when it is newer than the repo's.
    bash $setup/yay/.aur-upgrade.sh
    flatpak update -y
    # Tools no package manager tracks: linux/setup/app's installers (claude,
    # uv, zed, pulumi, ...) and asdf's runtimes, each to its latest release.
    bash $setup/app/.setup.sh
    bash $setup/asdf/.setup.sh
    # uv's one tool, graphify, stays as graphify.sh pins it: no `uv tool upgrade`,
    # which would also move its dependencies.
    if command -q fwupdmgr
        sudo fwupdmgr refresh --force; or true
        sudo fwupdmgr update -y; or true
    end
    set -l orphans (pacman -Qtdq 2>/dev/null)
    if test -n "$orphans"
        sudo pacman -Rns --noconfirm $orphans
    end
    sudo rm -rf /var/cache/pacman/pkg/download-*
    sudo paccache -rk2
    sudo paccache -ruk0
    yay -Sc --noconfirm
    flatpak uninstall --unused -y
end
