#!/bin/zsh
# Publish a new version: ./release.sh 1.2.0 "what changed"
# Bumps VERSION, builds + signs + notarizes (ship.sh), pushes, and creates a GitHub release with
# NagaControl.zip. Installed copies pick it up via the in-app updater.
set -euo pipefail
cd "$(dirname "$0")"
V=${1:?version}; NOTES=${2:-"Naga Control $V"}
[[ -z "$(git status --porcelain -- Sources Resources build.sh)" ]] || { echo "commit your changes first"; exit 1; }
echo "$V" > VERSION
git add VERSION && git commit -qm "v$V" && git tag -f "v$V"
./ship.sh
rm -f build/NagaControl.zip
ditto -c -k --sequesterRsrc --keepParent "build/Naga Control.app" build/NagaControl.zip
git push -q origin HEAD --tags
gh release create "v$V" build/NagaControl.zip --repo MattMaximo/NagaControl --title "Naga Control $V" --notes "$NOTES"
echo RELEASE-OK v$V
