#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --shell ]]; then
    printf '\nHyprland 0.56.2 test desktop — terminal %s\n\n' "${2:-new}"
    printf 'Alt+Up/Down: scroll focus   Alt+Enter: new terminal\n'
    printf 'Alt+S: scrolling   Alt+D: dwindle   Alt+M: master\n'
    printf 'Alt+Q: close terminal   Alt+Shift+Escape: stop test desktop\n\n'
    export PS1='nested-0.56:\w\$ '
    exec /bin/bash --noprofile --norc
fi
exec /usr/bin/kitty --config NONE --class hyprland056-demo \
    --title "Hyprland 0.56.2 — terminal ${1:-new}" \
    -o font_size=15 -o confirm_os_window_close=0 \
    "$0" --shell "${1:-new}"
