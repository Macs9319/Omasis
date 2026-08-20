#!/bin/bash
# Fetches the community Omarchy plugin registry (the same data that backs
# omarchyplugins.com) and flattens it into a single array Panel.qml can
# render directly, with no further JSON traversal needed client-side.
set -euo pipefail

REGISTRY_URL="https://raw.githubusercontent.com/HANCORE-linux/omarchy-plugin-marketplace/main/registry.json"

cmd="${1:-poll}"

case "$cmd" in
poll)
  raw=$(curl -fsS --max-time 10 "$REGISTRY_URL")
  jq -c '
    (.retiredPluginIds // []) as $retired
    | (.sources // []) as $sources
    | [
        $sources[]
        | . as $src
        | if $src.type == "suite" then
            $src.catalog as $c
            | {
                id: $c.id,
                name: $c.name,
                description: ($c.description // ""),
                author: ($c.author // ""),
                category: ($c.category // "Other"),
                tags: ($c.tags // []),
                accent: ($c.accent // null),
                initials: ($c.initials // null),
                kind: ($c.kind // "Suite"),
                status: ($c.status // null),
                repo: $src.repo,
                installType: "manual",
                installCommand: ($c.installCommand // ("git clone " + $src.repo)),
                installNote: ($c.installNote // null),
                securityOutcome: ($src.automatedSecurityBaseline.outcome // null),
                maintainerReviewed: (($src.maintainerVerificationReview // null) != null)
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
                category: ($p.category // "Other"),
                tags: ($p.tags // []),
                accent: ($p.accent // null),
                initials: ($p.initials // null),
                kind: null,
                status: null,
                repo: $src.repo,
                installType: (
                  if ($p.installation.mode? // "") == "manual" then "manual"
                  elif $pluginCount > 1 then "manual"
                  else "direct"
                  end
                ),
                installCommand: null,
                installNote: ($p.installation.note? // (if $pluginCount > 1 then "This repository hosts multiple plugins; automatic install is not supported for it yet." else null end)),
                securityOutcome: ($src.automatedSecurityBaseline.outcome // null),
                maintainerReviewed: (($src.maintainerVerificationReview // null) != null)
              }
          else empty
          end
      ]
    | map(select(.id as $id | ($retired | index($id)) == null))
  ' <<< "$raw"
  ;;
*)
  echo "usage: omasis.sh {poll}" >&2
  exit 1
  ;;
esac
