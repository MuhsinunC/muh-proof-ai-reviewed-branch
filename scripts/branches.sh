#!/usr/bin/env bash
# Usage: scripts/branches.sh list | prune [--execute]
# A layer branch is deleted only after its PR has landed on the human branch. Landing is a rebase, so the branch tip
# is never an ancestor of the human branch; ancestry alone cannot tell. This applies the alpha-follow workflow's rule:
# a branch is landed when a merged PR from it has its merge commit on the human branch (the commit the human branch was advanced
# to) AND the branch still sits at that PR's head. A fold (merged into another layer: its merge commit is
# off the human branch) or a reused name (tip moved) is not landed and shows as merged-not-landed; delete those by hand
# once you have checked them. Never deletes the AI branch or the human branch; any other branch, including a former default, is eligible
# under the landed-branch checks. Looks at the last 1000
# merged PRs; a branch whose PR is older than that is left alone and shows as no-pr. A branch with an open
# PR is never deleted.
set -euo pipefail
export HUMAN_BRANCH=${HUMAN_BRANCH:-main}
export AI_BRANCH=${AI_BRANCH:-alpha}
usage() { echo 'Usage: scripts/branches.sh list | prune [--execute]' >&2; exit 2; }
case "${1:-}" in
    list) [[ $# -eq 1 ]] || usage ;;
    prune) [[ $# -eq 1 || ( $# -eq 2 && $2 == --execute ) ]] || usage ;;
    *) usage ;;
esac
git fetch --prune --quiet origin
scratch=$(mktemp -d); trap 'rm -rf -- "$scratch"' EXIT
gh pr list --state merged --limit 1000 --json headRefName,headRefOid,mergeCommit,isCrossRepository > "$scratch/merged.json"   # a file, never argv: 128 KiB cap per argument
branches=$(git for-each-ref --format='%(refname:short)' refs/remotes/origin | sed 's#^origin/##' | grep -vxF -e HEAD -e "$AI_BRANCH" -e "$HUMAN_BRANCH" || true)
printf '%s\n' "$branches" > "$scratch/branches"
# One line per branch: landed | merged-not-landed | (nothing). The same test the workflow's landing step applies.
classified=$(python3 - "$scratch/merged.json" "$scratch/branches" <<'PY'
import json, os, subprocess, sys
prs = json.load(open(sys.argv[1]))
branches = [b for b in open(sys.argv[2]).read().splitlines() if b]
human = os.environ["HUMAN_BRANCH"]
def output(*args):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE).stdout.strip()
status = {}
for p in prs:   # newest first: the newest merged PR from a name decides
    head = p["headRefName"]
    if p.get("isCrossRepository") or head not in branches or head in status:
        continue
    oid = (p.get("mergeCommit") or {}).get("oid")
    landed = (oid and output("git", "rev-parse", f"origin/{head}") == p["headRefOid"]
              and subprocess.run(["git", "merge-base", "--is-ancestor", oid, f"origin/{human}"]).returncode == 0)
    status[head] = f"landed {p['headRefOid']}" if landed else "merged-not-landed"   # the classified tip is the deletion lease
for b in branches:
    print(f"{b} {status.get(b, '')}".rstrip())
PY
)
open_heads=$(gh pr list --state open --limit 1000 --json headRefName --jq '.[].headRefName')
if [[ $1 == list ]]; then
    while read -r b s _; do
        [[ -n $b ]] || continue
        if grep -qxF "$b" <<<"$open_heads"; then s=open-pr; fi   # an open PR wins: prune spares the branch whatever its merged history says
        printf '%s %s\n' "$b" "${s:-no-pr}"
    done <<<"$classified"
    exit 0
fi
while read -r b s sha; do
    [[ $s == landed ]] || continue
    grep -qxF "$b" <<<"$open_heads" && continue        # name reused for a new open PR: keep it
    if [[ ${2:-} == --execute ]]; then   # leased on the classified tip: a branch advanced since classification is refused, as in the workflow
        git push --quiet "--force-with-lease=refs/heads/$b:$sha" origin --delete "$b" || { echo "failed to delete $b (tip moved since classification, or push refused)" >&2; exit 1; }
        echo "deleted $b"
    else echo "would delete $b"; fi
done <<<"$classified"
