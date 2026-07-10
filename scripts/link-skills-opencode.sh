#!/usr/bin/env bash
set -euo pipefail

# Links all promoted skills from mattpocock/skills into the opencode skill
# directory (~/.config/opencode/skills) and syncs the permission config in
# opencode.jsonc to match the Matt Pocock user-invoked / model-invoked
# dividing line. Source of truth is .claude-plugin/plugin.json, which mirrors
# the top-level README — both must list a skill for it to count as promoted
# (per repo CLAUDE.md).
#
# Each entry is a symlink into this repo, so `git pull` keeps installed skills
# current. Re-run after adding, removing, or renaming a promoted skill.
#
# Intentionally a separate script from link-skills.sh: that one is dev-only
# for the maintainers of the mattpocock/skills repo and is not to be modified
# (per its own header comment).

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/.config/opencode/skills"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.jsonc"
PLUGIN_JSON="$REPO/.claude-plugin/plugin.json"

if [ ! -f "$PLUGIN_JSON" ]; then
  echo "error: $PLUGIN_JSON not found" >&2
  exit 1
fi

# Read promoted skill paths from plugin.json. Each entry is relative to REPO
# (e.g. "./skills/engineering/ask-matt").
mapfile -t promoted < <(jq -r '.skills[]' "$PLUGIN_JSON")

# Classify each promoted skill by its SKILL.md frontmatter:
#   disable-model-invocation: true  -> user-invoked (deny in opencode)
#   (absent)                        -> model-invoked (allow, falls through "*")
user_invoked=()
for rel in "${promoted[@]}"; do
  src="$REPO/${rel#./}"
  name="$(basename "$src")"
  skill_md="$src/SKILL.md"
  if [ -f "$skill_md" ] && grep -q '^disable-model-invocation: true' "$skill_md"; then
    user_invoked+=("$name")
  fi
done

mkdir -p "$DEST"

linked=0
skipped=0
for rel in "${promoted[@]}"; do
  src="$REPO/${rel#./}"
  name="$(basename "$src")"
  target="$DEST/$name"

  if [ ! -d "$src" ]; then
    echo "skip $name: source missing at $src" >&2
    skipped=$((skipped + 1))
    continue
  fi

  # If target exists and is a real directory, blow it away; if it's a stale
  # symlink, recreate it.
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    rm -rf "$target"
  fi

  ln -sfn "$src" "$target"
  echo "linked $name -> $src"
  linked=$((linked + 1))
done

# Clean up stale symlinks in $DEST that point into this repo but are no
# longer in plugin.json. Only touches symlinks — never real directories.
cleaned=0
for entry in "$DEST"/*; do
  [ -L "$entry" ] || continue
  target="$(readlink -f "$entry")"
  case "$target" in
    "$REPO"/*) ;;
    *) continue ;;
  esac
  name="$(basename "$entry")"
  still_promoted=0
  for rel in "${promoted[@]}"; do
    if [ "$(basename "${rel#./}")" = "$name" ]; then
      still_promoted=1
      break
    fi
  done
  if [ "$still_promoted" -eq 0 ]; then
    rm -f "$entry"
    echo "removed stale $name (no longer in plugin.json)"
    cleaned=$((cleaned + 1))
  fi
done

# Sync permission.skill in opencode.jsonc to match the dividing line.
#   "*"           -> "allow"   (default: anything not listed loads freely)
#   user-invoked  -> "deny"    (hidden from the model; user can still type it)
#   model-invoked -> no entry  (covered by "*": "allow")
#
# Writes are atomic: build in a temp file, validate, then mv. If the existing
# config has comments or isn't valid JSON, warn and skip — never destroy it.
patch_opencode_config() {
  local tmp
  tmp="$(mktemp)"

  local skill_perm
  skill_perm=$(jq -n '{"*": "allow"}')
  for s in "${user_invoked[@]}"; do
    skill_perm=$(printf '%s' "$skill_perm" | jq --arg s "$s" '. + {($s): "deny"}')
  done

  if [ ! -f "$OPENCODE_CONFIG" ]; then
    mkdir -p "$(dirname "$OPENCODE_CONFIG")"
    if jq -n --argjson sp "$skill_perm" '{permission: {skill: $sp}}' > "$OPENCODE_CONFIG"; then
      echo "wrote $OPENCODE_CONFIG (created; permission.skill: ${#user_invoked[@]} denied)"
    else
      echo "warning: failed to create $OPENCODE_CONFIG" >&2
    fi
    rm -f "$tmp"
    return
  fi

  if ! jq . "$OPENCODE_CONFIG" > /dev/null 2>&1; then
    echo "warning: $OPENCODE_CONFIG is not valid JSON (comments?), skipping permission sync" >&2
    echo "         strip comments and re-run, or edit permission.skill by hand" >&2
    rm -f "$tmp"
    return
  fi

  if jq --argjson sp "$skill_perm" \
       '.permission = (.permission // {}) | .permission.skill = $sp' \
       "$OPENCODE_CONFIG" > "$tmp"; then
    if jq . "$tmp" > /dev/null 2>&1; then
      mv "$tmp" "$OPENCODE_CONFIG"
      echo "patched $OPENCODE_CONFIG (permission.skill: ${#user_invoked[@]} user-invoked denied)"
    else
      echo "warning: patched config failed validation, keeping original $OPENCODE_CONFIG" >&2
      rm -f "$tmp"
    fi
  else
    echo "warning: failed to patch $OPENCODE_CONFIG" >&2
    rm -f "$tmp"
  fi
}

# Permission sync is best-effort: a failure here must not roll back the
# symlink work above.
patch_opencode_config || true

echo
echo "done. linked=$linked skipped=$skipped cleaned=$cleaned user_invoked=${#user_invoked[@]} dest=$DEST"
