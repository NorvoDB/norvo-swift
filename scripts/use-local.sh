#!/usr/bin/env bash
# Links Artifacts/ to a local database build, for NORVO_LOCAL=1. Usage: scripts/use-local.sh [../database]
set -euo pipefail
cd "$(dirname "$0")/.."
db=$(cd "${1:-$([ -d ../database ] && echo ../database || echo ../NorvoDB)}" && pwd)
"$db/scripts/build-xcframework.sh" >/dev/null
"$db/scripts/build-artifactbundle.sh" >/dev/null
mkdir -p Artifacts
ln -sfn "$db/target/apple/CNorvoLite.xcframework" Artifacts/CNorvoLite.xcframework
ln -sfn "$db/target/apple/norvo.artifactbundle" Artifacts/norvo.artifactbundle
