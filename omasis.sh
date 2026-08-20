#!/bin/bash
# Fetches the community Omarchy plugin registry (the same data that backs
# omarchyplugins.com) and flattens it into a single array Panel.qml can
# render directly, with no further JSON traversal needed client-side.
#
# The registry is a public, community-editable JSON file (PRs from anyone),
# so every field it supplies is untrusted input, not just "third-party
# data we happen to display". Two things matter here beyond plain parsing:
#   - `repo` is later handed to `git clone` (via `omarchy plugin add`) for
#     "direct" entries. Git supports transport schemes like `ext::` that
#     execute arbitrary shell commands, so `repoSafe` allowlists plain
#     `https://github.com/<owner>/<repo>` URLs only; anything else is
#     forced to `installType: "manual"` regardless of what the registry
#     claims, so Panel.qml never passes it to git.
#   - `securityOutcome` is clamped to the known enum instead of passed
#     through verbatim, so a crafted registry entry can't spoof a
#     security badge with arbitrary text.
set -euo pipefail

REGISTRY_URL="https://raw.githubusercontent.com/HANCORE-linux/omarchy-plugin-marketplace/main/registry.json"

cmd="${1:-poll}"

case "$cmd" in
poll)
  raw=$(curl -fsS --max-time 10 "$REGISTRY_URL")
  jq -c '
    def repoOk: test("^https://github\\.com/[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*(\\.git)?/?$");
    def safeTags: if (. | type) == "array" then [.[] | select(type == "string")] else [] end;
    def safeOutcome: if . == "passed" or . == "needs-fixes" or . == "review-required" then . else null end;
    # category ends up as a bar-widget Button label (qs.Ui Button), which
    # Panel.qml has no way to force into plain-text mode from the outside:
    # unlike the Text elements it owns directly, that shared component
    # default rich-text autodetection is out of reach. Stripping anything
    # outside plain word and punctuation characters here, at the source,
    # closes that off regardless of how it is eventually rendered.
    def safeLabel: if (. | type) == "string" then (gsub("[^A-Za-z0-9 &/_.-]"; "") | .[0:40] | if length == 0 then "Other" else . end) else "Other" end;

    (.retiredPluginIds // []) as $retired
    | (.sources // []) as $sources
    | [
        $sources[]
        | . as $src
        | (($src.repo // "") | repoOk) as $repoSafe
        | (($src.automatedSecurityBaseline.outcome // null) | safeOutcome) as $securityOutcome
        | (($src.maintainerVerificationReview // null) != null) as $maintainerReviewed
        | if $src.type == "suite" then
            $src.catalog as $c
            | {
                id: $c.id,
                name: $c.name,
                description: ($c.description // ""),
                author: ($c.author // ""),
                category: ($c.category // "Other" | safeLabel),
                tags: ($c.tags // [] | safeTags),
                accent: ($c.accent // null),
                initials: ($c.initials // null),
                kind: ($c.kind // "Suite"),
                status: ($c.status // null),
                repo: $src.repo,
                repoSafe: $repoSafe,
                installType: "manual",
                installCommand: ($c.installCommand // ("git clone " + ($src.repo // ""))),
                installNote: ($c.installNote // null),
                securityOutcome: $securityOutcome,
                maintainerReviewed: $maintainerReviewed
              }
          elif $src.type == "plugin-source" then
            ($src.plugins // {}) as $plugins
            | ($plugins | length) as $pluginCount
            | $plugins
            | to_entries[]
            | . as $entry
            | $entry.value as $p
            | {
                id: $entry.key,
                name: null,
                description: null,
                author: null,
                category: ($p.category // "Other" | safeLabel),
                tags: ($p.tags // [] | safeTags),
                accent: ($p.accent // null),
                initials: ($p.initials // null),
                kind: null,
                status: null,
                repo: $src.repo,
                repoSafe: $repoSafe,
                installType: (
                  if ($repoSafe | not) then "manual"
                  elif ($p.installation.mode? // "") == "manual" then "manual"
                  elif $pluginCount > 1 then "manual"
                  else "direct"
                  end
                ),
                installCommand: null,
                installNote: ($p.installation.note? // (if $pluginCount > 1 then "This repository hosts multiple plugins; automatic install is not supported for it yet." else null end)),
                securityOutcome: $securityOutcome,
                maintainerReviewed: $maintainerReviewed
              }
          else empty
          end
      ]
    | map(select(.id != null and (.id | type) == "string" and (.id | length) > 0 and (.id | length) < 200))
    | map(select(.id as $id | ($retired | index($id)) == null))
  ' <<< "$raw"
  ;;
*)
  echo "usage: omasis.sh {poll}" >&2
  exit 1
  ;;
esac
