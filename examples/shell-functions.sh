gext-recycle() {
    local uuid="${1:?usage: gext-recycle UUID}"
    local skill_home="${GNOME_WAYLAND_RELOAD_HOME:-$HOME/.agents/skills/gnome-wayland-reload}"
    "$skill_home/scripts/recycle-extension.sh" "$uuid"
}

gext-devkit() {
    local skill_home="${GNOME_WAYLAND_RELOAD_HOME:-$HOME/.agents/skills/gnome-wayland-reload}"
    "$skill_home/scripts/dev-shell.sh" "$@"
}

gext-logs() {
    local uuid="${1:-}"
    if [ -n "$uuid" ]; then
        journalctl -f -o cat /usr/bin/gnome-shell |
            grep --line-buffered -i -- "$uuid"
    else
        journalctl -f -o cat /usr/bin/gnome-shell
    fi
}
