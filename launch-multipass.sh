#!/usr/bin/env bash
# launch-multipass.sh — render user-data.yaml with your SSH PUBLIC key, launch the
# Multipass dev VM, then TRANSFER your local .env into it over multipass's channel
# (secrets never enter cloud-init). Run from the repo root: ./launch-multipass.sh
#
# Overridable: VM_NAME VM_CPUS VM_MEM VM_DISK VM_RELEASE
set -euo pipefail
cd "$(dirname "$0")"

TEMPLATE=user-data.yaml
NAME="${VM_NAME:-assistant}"; CPUS="${VM_CPUS:-4}"; MEM="${VM_MEM:-8G}"
DISK="${VM_DISK:-40G}"; REL="${VM_RELEASE:-24.04}"

[ -f .env ]        || { echo "No .env — run: cp .env.example .env  and fill it."; exit 1; }
[ -f "$TEMPLATE" ] || { echo "No $TEMPLATE in $(pwd)."; exit 1; }
command -v multipass >/dev/null || { echo "multipass not installed (brew install --cask multipass)."; exit 1; }

# SSH PUBLIC key from .env — text extract, do NOT source .env (avoids executing it)
KEY="$(grep -E '^SSH_PUBLIC_KEY=' .env | head -1 | cut -d= -f2- | sed 's/^"//; s/"$//')"
case "$KEY" in ssh-*) ;; *) echo "SSH_PUBLIC_KEY missing/invalid in .env."; exit 1;; esac
case "$KEY" in *REPLACE*) echo "SSH_PUBLIC_KEY is still the placeholder — set your real key."; exit 1;; esac

# Only the PUBLIC key goes into cloud-init (public by definition). Secrets come later.
RENDERED="$(mktemp)"; trap 'rm -f "$RENDERED"' EXIT
sed "s|__SSH_PUBLIC_KEY__|$KEY|" "$TEMPLATE" > "$RENDERED"

echo "Launching '$NAME' ($CPUS vCPU / $MEM / $DISK, Ubuntu $REL)…"
# multipass launch blocks until cloud-init finishes, so the repo clone is done below.
multipass launch "$REL" --name "$NAME" --cpus "$CPUS" --memory "$MEM" --disk "$DISK" --cloud-init "$RENDERED"

echo "Transferring .env into the VM (multipass channel; not in cloud-init)…"
if ! multipass exec "$NAME" -- test -d /opt/assistant-stack; then
  echo "  !! /opt/assistant-stack not present yet (cloud-init clone may still be running)."
  echo "     Wait, then re-run: multipass transfer .env $NAME:/tmp/.env.seed &&"
  echo "       multipass exec $NAME -- sudo install -o assistant -g assistant -m600 /tmp/.env.seed /opt/assistant-stack/.env"
  exit 1
fi
multipass transfer .env "$NAME":/tmp/.env.seed
multipass exec "$NAME" -- sudo install -o assistant -g assistant -m 600 /tmp/.env.seed /opt/assistant-stack/.env
multipass exec "$NAME" -- rm -f /tmp/.env.seed

IP="$(multipass info "$NAME" 2>/dev/null | awk '/IPv4/{print $2; exit}')"
printf '\nVM up + .env in place. IPv4: %s\nNext:\n  multipass exec %s -- bash /opt/bring-up.sh\nDashboards from the Mac (after bring-up):\n  ssh -L 10254:127.0.0.1:10254 -L 3002:127.0.0.1:3002 assistant@%s\n' "${IP:-<multipass info $NAME>}" "$NAME" "${IP:-<vm-ip>}"
