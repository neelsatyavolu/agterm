#!/bin/sh
# A cloud machine for development: the Linux sessions helper and its gateway in a Docker
# container (OrbStack), listening on 127.0.0.1:7600. Like a real cloud machine, it runs as a
# user whose home is this Mac's home path, has /private/tmp, rsync and a C compiler. Writes
# AGTERM_CLOUD and AGTERM_CLOUD_TOKEN to .build/cloud-dev.env (mode 600):
#   scripts/cloud-dev.sh && set -a && . .build/cloud-dev.env && set +a
#   AGTERM_MOVE_CHECK=1 AGTERM_SELFTEST=/tmp/agt .build/debug/AgTerm
# `scripts/cloud-dev.sh stop` removes the container.
set -eu
cd "$(dirname "$0")/.."
name=agterm-cloud
docker rm -f "$name" >/dev/null 2>&1 || true
[ "${1:-}" = stop ] && exit 0

docker run --rm -v "$PWD":/src -v agterm-linux-build:/build -w /src swift:6.4-noble \
    swift build --scratch-path /build --product agterm-sessions >/dev/null
token=$(openssl rand -hex 24)
user=$(id -un)
AGTERM_GATEWAY_TOKEN=$token docker run -d --name "$name" -p 127.0.0.1:7600:7600 -e AGTERM_GATEWAY_TOKEN \
    -v agterm-linux-build:/build:ro swift:6.4-noble sh -c "
        apt-get update -qq >/dev/null && apt-get install -y -qq rsync >/dev/null 2>&1
        mkdir -p '$(dirname "$HOME")' && useradd -m -d '$HOME' -s /bin/bash '$user'
        # As on a Mac, /tmp is a link to /private/tmp: agents key conversations by the real path
        # of their folder, and moved tabs keep their paths.
        mkdir -p /private && cp -a /tmp /private/ && rm -rf /tmp && ln -s private/tmp /tmp
        exec setpriv --reuid='$user' --regid='$user' --init-groups env HOME='$HOME' USER='$user' \
            /build/debug/agterm-sessions --sessions-helper --socket /tmp/agterm-$user/s.sock --build linux --listen 0.0.0.0:7600" >/dev/null
# OrbStack accepts on the forwarded port before anything listens, so ask the container.
for _ in $(seq 1 120); do
    docker exec "$name" sh -c 'grep -q ":1DB0 00000000:0000 0A" /proc/net/tcp' 2>/dev/null && break
    sleep 1
done
umask 077
printf 'AGTERM_CLOUD=127.0.0.1:7600\nAGTERM_CLOUD_TOKEN=%s\n' "$token" > .build/cloud-dev.env
echo "cloud machine ready; settings in .build/cloud-dev.env"
