#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

export PATH="$ROOT/bin:$PATH"

require_command jq
require_command lua
require_command python3

jq empty "$ROOT/config/magikos/shell.json"
pass "default shell.json is valid JSON"

jq -e '.version == 1 and (.bar.layout.left | type == "array") and (.bar.layout.center | type == "array") and (.bar.layout.right | type == "array")' "$ROOT/config/magikos/shell.json" >/dev/null
pass "default shell.json has versioned bar layout"

# Pinning the whole row made this fail every time an unrelated widget moved,
# so assert the adjacency the name is about and let the rest of the row change.
jq -e '
  def ids: map(.id // .);
  (.bar.layout.center | ids) as $ids |
  ($ids | index("magikos.weather")) as $weather |
  ($ids | index("magikos.system-update")) as $update |
  $weather != null and $update == $weather + 1
' "$ROOT/config/magikos/shell.json" >/dev/null
pass "default center layout keeps update next to weather"

jq -e '
  (.bar.centerAnchor // "") as $anchor |
  any(.bar.layout.center[]; (.id // .) == $anchor)
' "$ROOT/config/magikos/shell.json" >/dev/null
pass "default center anchor exists in center layout"

jq -e '
  any(.bar.layout.center[]; (.id // .) == "magikos.clock" and (.formatAlt // "") == "d MMMM \u0027W\u0027ww yyyy")
' "$ROOT/config/magikos/shell.json" >/dev/null
pass "default clock date format has no leading zero"

ROOT="$ROOT" python3 <<'PY'
import json
import os
import sys
from pathlib import Path

root = Path(os.environ["ROOT"])
config = json.loads((root / "config/magikos/shell.json").read_text())
manifests = {}
for manifest_path in (root / "shell/plugins").glob("**/*.manifest.json"):
  data = json.loads(manifest_path.read_text())
  manifests[data.get("id", "")] = (manifest_path, data)
for manifest_path in (root / "shell/plugins").glob("**/manifest.json"):
  data = json.loads(manifest_path.read_text())
  manifests[data.get("id", "")] = (manifest_path, data)

entries = []
for section in ("left", "center", "right"):
  entries.extend(config["bar"]["layout"][section])

missing = []
bad = []
for entry in entries:
  widget_id = entry["id"] if isinstance(entry, dict) else str(entry)
  if not widget_id.startswith("magikos."):
    continue

  row = manifests.get(widget_id)
  if row is None:
    missing.append(widget_id)
    continue
  manifest_path, manifest = row

  if "bar-widget" not in manifest.get("kinds", []):
    bad.append(f"{widget_id}: missing bar-widget kind")
  entry_point = manifest.get("entryPoints", {}).get("barWidget")
  if not entry_point:
    bad.append(f"{widget_id}: missing barWidget entry point")
  elif not (manifest_path.parent / entry_point).exists():
    bad.append(f"{widget_id}: missing {entry_point}")

if missing or bad:
  for item in missing:
    print(f"missing manifest for {item}", file=sys.stderr)
  for item in bad:
    print(item, file=sys.stderr)
  sys.exit(1)
PY
pass "default bar widget ids resolve to manifests and entry points"

ROOT="$ROOT" python3 <<'PY'
import os
import sys
from pathlib import Path

root = Path(os.environ["ROOT"])
home = Path.home()
pkgs_candidates = [
  root.parent / "magikos-pkgs/pkgbuilds",
  root.parent / "magikos/magikos-pkgs/pkgbuilds",
  root.parent.parent / "magikos-pkgs/pkgbuilds",
  root.parent / "omacom/magikos-pkgs/pkgbuilds",
  root.parent.parent / "omacom/magikos-pkgs/pkgbuilds",
  home / "Work/omacom/magikos-pkgs/pkgbuilds",
]
# Checkouts differ per machine, so allow an explicit pointer at the sibling repo.
# Accepts either the magikos-pkgs checkout or its pkgbuilds/ directory.
override = os.environ.get("MAGIKOS_PKGS_PATH")
if override:
  pkgs_candidates = [Path(override) / "pkgbuilds", Path(override)] + pkgs_candidates
pkgs_root = next((path for path in pkgs_candidates if path.exists()), None)
if pkgs_root is None:
  print("not ok - magikos-pkgs checkout found for PKGBUILD coverage", file=sys.stderr)
  print(
    "looked in:\n  " + "\n  ".join(str(path) for path in pkgs_candidates) +
    "\nset MAGIKOS_PKGS_PATH to the magikos-pkgs checkout",
    file=sys.stderr,
  )
  sys.exit(1)
settings_pkgbuild_path = pkgs_root / "magikos-settings/PKGBUILD"
magikos_pkgbuild_path = pkgs_root / "magikos/PKGBUILD"
if not settings_pkgbuild_path.exists():
  settings_pkgbuild_path = pkgs_root / "magikos-settings-dev/PKGBUILD"
if not magikos_pkgbuild_path.exists():
  magikos_pkgbuild_path = pkgs_root / "magikos-dev/PKGBUILD"
pkgbuild = settings_pkgbuild_path.read_text()
magikos_pkgbuild = magikos_pkgbuild_path.read_text()
errors = []
package_defaults = [
  ("default/uwsm/env.d/10-magikos", "/usr/share/uwsm/env.d/10-magikos", "uwsm/env"),
  ("default/uwsm/default", None, "uwsm/default"),
  ("default/environment.d/10-magikos-fcitx.conf", "/usr/lib/environment.d/10-magikos-fcitx.conf", "environment.d/fcitx.conf"),
  ("default/environment.d/10-magikos.conf", "/usr/lib/environment.d/10-magikos.conf", "environment.d/magikos.conf"),
  ("default/fontconfig/conf.avail/50-magikos.conf", "/usr/share/fontconfig/conf.avail/50-magikos.conf", "fontconfig/fonts.conf"),
  ("default/applications/mimeapps.list", "/usr/share/applications/mimeapps.list", "mimeapps.list"),
  ("etc/fastfetch/config.jsonc", "/etc/fastfetch/config.jsonc", "fastfetch/config.jsonc"),
  ("default/systemd/user/bt-agent.service", "/usr/lib/systemd/user/bt-agent.service", "systemd/user/bt-agent.service"),
  ("default/systemd/user/magikos-sleep-lock.service", "/usr/lib/systemd/user/magikos-sleep-lock.service", "systemd/user/magikos-sleep-lock.service"),
  ("default/systemd/user/magikos-recover-internal-monitor.service", "/usr/lib/systemd/user/magikos-recover-internal-monitor.service", "systemd/user/magikos-recover-internal-monitor.service"),
  ("default/systemd/user/magikos-migrate-notify.service", "/usr/lib/systemd/user/magikos-migrate-notify.service", "systemd/user/magikos-migrate-notify.service"),
  ("default/systemd/user/magikos-tailscale-receive.service", "/usr/lib/systemd/user/magikos-tailscale-receive.service", "systemd/user/magikos-tailscale-receive.service"),
  ("default/systemd/user/magikos-fcitx5.service", "/usr/lib/systemd/user/magikos-fcitx5.service", "systemd/user/magikos-fcitx5.service"),
  ("default/systemd/user/magikos-crash-watch.service", "/usr/lib/systemd/user/magikos-crash-watch.service", "systemd/user/magikos-crash-watch.service"),
  ("default/systemd/zram-generator.conf.d/90-magikos.conf", "/usr/lib/systemd/zram-generator.conf.d/90-magikos.conf", "systemd/zram-generator.conf.d/90-magikos.conf"),
  ("default/fonts/magikos/magikos.ttf", "/usr/share/fonts/magikos/magikos.ttf", "magikos.ttf"),
  ("default/snapper/root", "/etc/snapper/config-templates/magikos", "snapper/root"),
]

for source, destination, legacy in package_defaults:
  if not (root / source).exists():
    errors.append(f"missing package default source: {source}")
  if (root / "config" / legacy).exists():
    errors.append(f"legacy path still in config/: {legacy}")
  if destination and (source not in pkgbuild or destination not in pkgbuild):
    errors.append(f"PKGBUILD does not explicitly install {source} -> {destination}")

# Existing users have an absolute wants symlink to the old unit path, and the
# migration that repoints it only runs for users who run an update -- the
# opposite of who the notifier is for. Dropping this alias strands them.
notify_alias = 'ln -sfn magikos-migrate-notify.service "$pkgdir/usr/lib/systemd/user/magikos-update-user-notify.service"'
if notify_alias not in pkgbuild:
  errors.append(
    "PKGBUILD does not ship the magikos-update-user-notify.service compatibility "
    "alias, so users who have not run migration 1785095882 lose the login notifier"
  )

alpm_hooks = [
  "00-magikos-update-guard.hook",
]
for hook in alpm_hooks:
  source = f"default/libalpm/hooks/{hook}"
  destination = f"/usr/share/libalpm/hooks/{hook}"
  if not (root / source).exists():
    errors.append(f"missing package default source: {source}")
  if source not in magikos_pkgbuild or destination not in magikos_pkgbuild:
    errors.append(f"magikos PKGBUILD does not install {source} -> {destination}")

if errors:
  print("\n".join(errors), file=sys.stderr)
  sys.exit(1)
PY
pass "package-owned defaults live outside config"

TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/home/.config/magikos"

ipc_mock_bin="$TMPDIR/ipc-mock"
mkdir -p "$ipc_mock_bin"
cat >"$ipc_mock_bin/magikos-shell" <<'SH'
#!/bin/bash
set -euo pipefail

mkdir -p "$HOME/.local/state/magikos"
printf '%s\n' "$*" >>"$HOME/.local/state/magikos/shell-ipc-calls"
printf 'ok\n'
SH
chmod +x "$ipc_mock_bin/magikos-shell"
export PATH="$ipc_mock_bin:$PATH"

cat >"$TMPDIR/home/.config/magikos/shell.json" <<'JSON'
{
  "version": 1,
  "bar": {
    "layout": {
      "left": [{ "id": "magikos.menu" }, { "id": "magikos.workspaces" }, { "id": "magikos.active-window" }],
      "center": [{ "id": "magikos.clock" }, { "id": "magikos.weather" }, { "id": "magikos.system-update" }, { "id": "magikos.tailscale" }],
      "right": [{ "id": "magikos.tray" }, { "id": "magikos.microphone" }, { "id": "magikos.bluetooth" }]
    }
  },
  "plugins": []
}
JSON

mkdir -p "$TMPDIR/home/.config/magikos/plugins/local.demo-bar"
cat >"$TMPDIR/home/.config/magikos/plugins/local.demo-bar/manifest.json" <<'JSON'
{
  "schemaVersion": 1,
  "id": "local.demo-bar",
  "name": "Demo bar",
  "version": "1.0.0",
  "author": "Test",
  "description": "Replacement bar for config tests",
  "kinds": ["bar"],
  "entryPoints": { "bar": "Bar.qml" }
}
JSON
touch "$TMPDIR/home/.config/magikos/plugins/local.demo-bar/Bar.qml"

if HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" magikos-bar use local.nonexistent-bar 2>/dev/null; then
  fail "bar use accepted an unknown bar option"
fi
pass "bar use rejects an unknown bar option"

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" magikos-bar use local.demo-bar
jq -e '.bar.id == "local.demo-bar"' "$TMPDIR/home/.config/magikos/shell.json" >/dev/null
pass "shell config selects a bar option"

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" magikos-bar reset
jq -e '.bar.id == null' "$TMPDIR/home/.config/magikos/shell.json" >/dev/null
pass "shell config resets to built-in bar option"

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" magikos-bar move magikos.active-window right
grep -Fqx 'shell moveBarWidget magikos.active-window {"section":"right"}' \
  "$TMPDIR/home/.local/state/magikos/shell-ipc-calls"
pass "bar move accepts a positional target section"

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" magikos-bar move magikos.active-window left
grep -Fqx 'shell moveBarWidget magikos.active-window {"section":"left"}' \
  "$TMPDIR/home/.local/state/magikos/shell-ipc-calls"
pass "bar move can restore a widget with positional syntax"

if HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" magikos-bar move magikos.active-window left --section right 2>/dev/null; then
  fail "bar move accepted positional and flagged target sections"
fi
pass "bar move rejects conflicting target section syntax"

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" magikos-bar position bottom
jq -e '
  .bar.position == "bottom" and
  .plugins == []
' "$TMPDIR/home/.config/magikos/shell.json" >/dev/null
pass "shell config sets bar position"

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" magikos-bar transparent true
jq -e '
  .bar.transparent == true and
  .bar.position == "bottom" and
  .plugins == []
' "$TMPDIR/home/.config/magikos/shell.json" >/dev/null
pass "shell config sets bar transparency"

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" magikos-bar transparent toggle
jq -e '.bar.transparent == false' "$TMPDIR/home/.config/magikos/shell.json" >/dev/null
pass "shell config toggles bar transparency"

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" magikos-bar set magikos.bluetooth enabled false --json
grep -Fqx 'shell setBarWidget magikos.bluetooth enabled false {}' \
  "$TMPDIR/home/.local/state/magikos/shell-ipc-calls"
pass "bar set accepts false JSON values"

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" magikos-bar set magikos.bluetooth optional null --json
grep -Fqx 'shell setBarWidget magikos.bluetooth optional null {}' \
  "$TMPDIR/home/.local/state/magikos/shell-ipc-calls"
pass "bar set accepts null JSON values"

if HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" magikos-bar set magikos.bluetooth broken '{' --json 2>/dev/null; then
  fail "bar set accepted malformed JSON"
fi
pass "bar set rejects malformed JSON"

if HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" magikos-bar set magikos.bluetooth broken 'false null' --json 2>/dev/null; then
  fail "bar set accepted multiple JSON values"
fi
pass "bar set rejects multiple JSON values"

mock_bin="$TMPDIR/mock-bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/magikos-refresh-config" <<'SH'
#!/bin/bash
set -euo pipefail

relative_path="${1:-}"
[[ -n $relative_path ]] || exit 1
mkdir -p "$HOME/.config/$(dirname "$relative_path")"
cp "$MAGIKOS_PATH/config/$relative_path" "$HOME/.config/$relative_path"
SH

cat >"$mock_bin/magikos-restart-shell" <<'SH'
#!/bin/bash
set -euo pipefail

mkdir -p "$HOME/.local/state/magikos"
touch "$HOME/.local/state/magikos/restart-shell-called"
SH

cat >"$mock_bin/magikos-shell" <<'SH'
#!/bin/bash
[[ ${MAGIKOS_TEST_SHELL_DOWN:-0} == "1" ]] && exit 1
printf 'ok\n'
SH

cat >"$mock_bin/magikos-installed-service-dropbox" <<'SH'
#!/bin/bash
set -euo pipefail

[[ ${MAGIKOS_TEST_DROPBOX:-0} == "1" ]]
SH

cat >"$mock_bin/magikos-installed-service-tailscale" <<'SH'
#!/bin/bash
set -euo pipefail

[[ ${MAGIKOS_TEST_TAILSCALE:-0} == "1" ]]
SH

chmod +x "$mock_bin"/*
mock_path="$mock_bin:$ROOT/bin:$PATH"

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" PATH="$mock_path" MAGIKOS_TEST_DROPBOX=0 MAGIKOS_TEST_TAILSCALE=0 magikos-bar defaults
jq -e --slurpfile defaults "$ROOT/config/magikos/shell.json" '
  .bar == $defaults[0].bar and
  .plugins == []
' "$TMPDIR/home/.config/magikos/shell.json" >/dev/null
pass "bar defaults restores the stock bar"

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" PATH="$mock_path" MAGIKOS_TEST_DROPBOX=1 MAGIKOS_TEST_TAILSCALE=1 magikos-bar defaults
jq -e '
  def ids: map(.id // .);
  (.bar.layout.right | ids) as $right |
  ($right | index("magikos.tray")) as $tray |
  ($right | index("magikos.tailscale") == $tray + 1) and
  ($right | index("magikos.dropbox") == $tray + 2) and
  (.bar.layout.center | ids | index("magikos.tailscale") == null)
' "$TMPDIR/home/.config/magikos/shell.json" >/dev/null
pass "bar defaults places plugins for running optional services"

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" PATH="$mock_path" \
  MAGIKOS_TEST_SHELL_DOWN=1 MAGIKOS_TEST_DROPBOX=1 MAGIKOS_TEST_TAILSCALE=1 \
  magikos-bar defaults
jq -e '
  def ids: map(.id // .);
  (.bar.layout.right | ids) as $right |
  ($right | index("magikos.tray")) as $tray |
  ($right | index("magikos.tailscale") == $tray + 1) and
  ($right | index("magikos.dropbox") == $tray + 2) and
  (.bar.layout.center | ids | index("magikos.tailscale") == null)
' "$TMPDIR/home/.config/magikos/shell.json" >/dev/null
pass "bar defaults places service widgets without a running shell"

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" PATH="$mock_path" MAGIKOS_TEST_DROPBOX=0 MAGIKOS_TEST_TAILSCALE=0 magikos-refresh-shell
jq -e '
  def ids: map(.id // .);
  ([.bar.layout.left, .bar.layout.center, .bar.layout.right] | map(ids) | add) as $all |
  ($all | index("magikos.dropbox") == null) and
  ($all | index("magikos.tailscale") == null)
' "$TMPDIR/home/.config/magikos/shell.json" >/dev/null
pass "shell refresh keeps optional service widgets absent when services are unavailable"

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" PATH="$mock_path" MAGIKOS_TEST_DROPBOX=1 MAGIKOS_TEST_TAILSCALE=1 magikos-refresh-shell
jq -e '
  def ids: map(.id // .);
  (.bar.layout.right | ids) as $right |
  ($right | index("magikos.tray")) as $tray |
  ($right | index("magikos.tailscale") == $tray + 1) and
  ($right | index("magikos.dropbox") == $tray + 2) and
  (.bar.layout.center | ids | index("magikos.tailscale") == null)
' "$TMPDIR/home/.config/magikos/shell.json" >/dev/null
[[ -f $TMPDIR/home/.local/state/magikos/restart-shell-called ]] || fail "shell refresh restarts shell"
pass "shell refresh places optional service widgets when services are available"

clock_migration=$(grep -rl 'Remove leading zero from bar clock date' "$ROOT/migrations" | head -n 1 || true)
[[ -n $clock_migration ]] || fail "clock date format user migration exists"

cat >"$TMPDIR/home/.config/magikos/shell.json" <<'JSON'
{
  "version": 1,
  "bar": {
    "layout": {
      "left": [],
      "center": [
        { "id": "magikos.clock", "formatAlt": "dd MMMM 'W'ww yyyy" },
        { "id": "magikos.weather" }
      ],
      "right": [
        { "id": "local.clock", "formatAlt": "dd MMMM 'W'ww yyyy" }
      ]
    }
  },
  "plugins": []
}
JSON

HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" bash "$clock_migration"

jq -e '
  .bar.layout.center[0].formatAlt == "d MMMM \u0027W\u0027ww yyyy" and
  .bar.layout.right[0].formatAlt == "dd MMMM \u0027W\u0027ww yyyy"
' "$TMPDIR/home/.config/magikos/shell.json" >/dev/null
pass "clock date format migration removes leading zero from clock"

before=$(sha256sum "$TMPDIR/home/.config/magikos/shell.json" | awk '{print $1}')
HOME="$TMPDIR/home" MAGIKOS_PATH="$ROOT" bash "$clock_migration"
after=$(sha256sum "$TMPDIR/home/.config/magikos/shell.json" | awk '{print $1}')
[[ $before == "$after" ]] || fail "clock date format migration is idempotent"
pass "clock date format migration is idempotent"
