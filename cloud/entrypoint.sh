#!/bin/sh
# Starts one user's cloud machine: the user at the Mac's home path (where their volume is
# mounted, so files outlive stops), then the sessions helper and its gateway as that user.
# Env, set by the control plane: AGTERM_USER, AGTERM_HOME, AGTERM_GATEWAY_TOKEN, and optionally
# AGTERM_IDLE_STOP (seconds without clients or output before the machine stops; default 900).
set -eu
user=${AGTERM_USER:?}
home=${AGTERM_HOME:?}
case "$user" in *[!a-z0-9._-]*|'') echo "bad AGTERM_USER" >&2; exit 2 ;; esac
case "$home" in /*) ;; *) echo "bad AGTERM_HOME" >&2; exit 2 ;; esac

if ! id "$user" >/dev/null 2>&1; then
    mkdir -p "$home"
    useradd -d "$home" -M -u 1000 -s /bin/bash "$user"
fi
# A new volume: give it the usual dotfiles.
if [ ! -e "$home/.profile" ]; then
    cp -r --update=none /etc/skel/. "$home/"
fi
chown "$user:$user" "$home"

exec setpriv --reuid="$user" --regid="$user" --init-groups \
    env -i HOME="$home" USER="$user" LOGNAME="$user" SHELL=/bin/bash LANG=en_US.UTF-8 \
    PATH="$home/.local/bin:$home/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    AGTERM_GATEWAY_TOKEN="$AGTERM_GATEWAY_TOKEN" \
    /usr/local/bin/agterm-sessions --sessions-helper --socket "/tmp/agterm-$user/s.sock" --build cloud \
        --listen 0.0.0.0:8080 --idle-stop "${AGTERM_IDLE_STOP:-900}"
