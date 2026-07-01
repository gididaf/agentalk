# agentalk /agentalk skill installer. Run in one call:
#   curl -fsSL {{BRIDGE_URL}}/skill.sh | sh
# Writes the skill to ~/.claude/skills/agentalk/SKILL.md so `/agentalk` is
# available (and auto-loads when you pair). Idempotent; overwrites in place.

set -e

_agentalk_skill_dir="${HOME}/.claude/skills/agentalk"
mkdir -p "$_agentalk_skill_dir"

# Fetch the skill body to a temp file first, then move into place, so a failed
# or truncated download never leaves a half-written SKILL.md.
_agentalk_tmp="$(mktemp)"
curl -fsSL '{{BRIDGE_URL}}/skill.md' -o "$_agentalk_tmp"
[ -s "$_agentalk_tmp" ] || { echo "ERROR: agentalk skill download was empty" >&2; rm -f "$_agentalk_tmp"; exit 1; }
mv "$_agentalk_tmp" "$_agentalk_skill_dir/SKILL.md"

echo "agentalk skill installed at $_agentalk_skill_dir/SKILL.md"
echo "In a running Claude Code session it hot-loads right away — type /agentalk to use it."
echo "(If ~/.claude/skills did not exist before now, restart the session once so the new directory is watched.)"
