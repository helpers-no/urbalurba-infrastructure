#!/bin/bash
# test-no-bashisms-under-sh.sh — `ansible.builtin.shell` runs /bin/sh.
#
# 🔴 In uis-provision-host /bin/sh is /usr/bin/dash, where `$RANDOM` expands to
# NOTHING. `210-setup-litellm.yml` built a pod name as `apiready-$RANDOM`, so
# kubectl received `apiready-` and refused it as an invalid RFC 1123 subdomain
# — every attempt, twenty retries, then the play failed.
#
# ⚠️ `uis deploy litellm` therefore exited 3 while litellm was healthy and
# serving. The task exists to stop a deploy reporting success while the API is
# dead; what it actually did was make a working deploy report failure. 100%
# reproducible, never a race (imac, urb-agents#548).
#
# The lesson is not "$RANDOM is bad" — it is that a `shell:` task is running a
# DIFFERENT INTERPRETER than the one whose syntax people write from habit. So
# this checks the class, not the instance: a bash-only construct in a
# `shell:` block that has not declared `executable: /bin/bash`.
#
# ⚠️ Falsified: re-introducing `apiready-$RANDOM` makes this fail. A lint that
# has never been shown to fail is a lint nobody should trust.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLAYBOOKS="$REPO_ROOT/ansible/playbooks"
[[ -d "$PLAYBOOKS" ]] || PLAYBOOKS="/mnt/urbalurbadisk/ansible/playbooks"

print_test_section "no bash-only syntax in a /bin/sh task"

if [[ ! -d "$PLAYBOOKS" ]]; then
    skip_test "playbooks not present in this layout"
    print_summary
    return 0 2>/dev/null || exit 0
fi

found=$(python3 - "$PLAYBOOKS" <<'PY'
import re, glob, os, sys
BASHISMS = [
    (r'\$RANDOM',                        '$RANDOM (empty under dash)'),
    (r'\[\[',                            '[[ ]] test'),
    (r'<<<',                             'here-string <<<'),
    (r'\$\{[A-Za-z_][A-Za-z0-9_]*//',    '${var//} substitution'),
    (r'\$\{[A-Za-z_][A-Za-z0-9_]*\^\^',  '${var^^} case'),
    (r'\bdeclare -[aA]\b',               'declare -a/-A'),
    (r'\bmapfile\b',                     'mapfile'),
    (r'\bpushd\b|\bpopd\b',              'pushd/popd'),
]
out = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.yml"))):
    lines = open(f).read().split("\n")
    i = 0
    while i < len(lines):
        if re.search(r'ansible\.builtin\.shell\s*:', lines[i]):
            start, j = i, i + 1
            ind = len(lines[i]) - len(lines[i].lstrip())
            while j < len(lines) and (lines[j].strip() == "" or
                                      len(lines[j]) - len(lines[j].lstrip()) > ind):
                j += 1
            block = "\n".join(lines[start:j])
            k = j
            while k < len(lines) and not re.match(r'\s*- name:', lines[k]):
                k += 1
            if "/bin/bash" not in block and "/bin/bash" not in "\n".join(lines[j:k]):
                for pat, label in BASHISMS:
                    if re.search(pat, block):
                        out.append(f"{os.path.basename(f)}:{start+1} {label}")
            i = j
        else:
            i += 1
print("; ".join(out))
PY
)

start_test "🔴 no bash-only construct in an ansible.builtin.shell without executable: /bin/bash"
assert_empty "$found" "these run under dash and will behave differently or fail: $found"

start_test "the litellm API-readiness pod name is shell-independent"
grep -q 'apiready-{{ 999999 | random }}' "$PLAYBOOKS/210-setup-litellm.yml" 2>/dev/null && pass_test \
    || fail_test "the pod name depends on the shell again"

print_summary
