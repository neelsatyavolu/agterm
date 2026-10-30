#!/bin/sh
# Publishes a new cloud machine image: builds it on Fly's builder under a dated tag, points the
# control plane at it, and deploys the control plane. Machines move to it the next time the
# hourly cron finds them stopped, so open tabs are never cut off.
set -eu
cd "$(dirname "$0")/.."
tag="v$(date -u +%Y%m%d%H%M)"
fly deploy . --config cloud/fly.toml --dockerfile cloud/Dockerfile --build-only --push --image-label "$tag" --remote-only
sed -i '' "s|^CLOUD_IMAGE = .*|CLOUD_IMAGE = \"registry.fly.io/agterm-cloud-machines:$tag\"|" cloud/control/wrangler.toml
(cd cloud/control && npx wrangler deploy)
echo "published $tag; commit cloud/control/wrangler.toml"
