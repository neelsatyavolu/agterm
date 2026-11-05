# /etc/profile.d for cloud tabs (login shells; the helper's own environment doesn't reach them).
# The agents come with the image, which a user can't write to, so their own updaters stay off.
export DISABLE_AUTOUPDATER=1
# The 1Password service account token saved in agterm's Settings → Cloud, for op (the Mac's
# 1Password app and Touch ID aren't here).
if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && [ -r "$HOME/.agterm/op-token" ]; then
    OP_SERVICE_ACCOUNT_TOKEN=$(cat "$HOME/.agterm/op-token")
    export OP_SERVICE_ACCOUNT_TOKEN
fi
