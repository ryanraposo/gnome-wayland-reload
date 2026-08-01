#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: inspect-shell-source.sh [--list|environment|extension-system|RESOURCE]

Extract JavaScript from the versioned libshell used by the installed GNOME
Shell. RESOURCE must be an absolute gresource path. With no argument, list the
available /org/gnome/shell/ui/ JavaScript resources.
EOF
}

case "${1:-}" in
    --help|-h)
        usage
        exit 0
        ;;
esac

for command_name in gnome-shell ldd gresource awk; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "error: required command not found: $command_name" >&2
        exit 1
    }
done

shell_binary="$(command -v gnome-shell)"
shell_resource_lib="$(
    ldd "$shell_binary" |
        awk '/libshell-[0-9]+\.so/ && !found {print $3; found=1} END {if (!found) exit 1}'
)" || {
    echo "error: could not locate GNOME Shell's versioned libshell" >&2
    exit 1
}

case "${1:---list}" in
    --list)
        gresource list "$shell_resource_lib" |
            awk '/^\/org\/gnome\/shell\/ui\/.*\.js$/'
        ;;
    environment)
        gresource extract "$shell_resource_lib" /org/gnome/shell/ui/environment.js
        ;;
    extension-system)
        gresource extract "$shell_resource_lib" /org/gnome/shell/ui/extensionSystem.js
        ;;
    /*)
        gresource extract "$shell_resource_lib" "$1"
        ;;
    *)
        echo "error: expected --list, an alias, or an absolute resource path" >&2
        exit 2
        ;;
esac
