#!/bin/sh
# Upload project tar to VPS and push with git + token
set -e
REPO_DIR=/tmp/PureReader_push_$$
TAR=/tmp/purereader_src.tar.gz

# Expect: GH_TOKEN exported, tar already at $TAR
mkdir -p "$REPO_DIR"
cd "$REPO_DIR"
tar xzf "$TAR"
# Ensure we are in project root
if [ -d PureReader ] && [ -f README.md ]; then
  :
elif [ -d PureReader/PureReader ]; then
  cd PureReader
else
  # find root
  ROOT=$(find . -name 'project.pbxproj' | head -1 | xargs dirname | xargs dirname)
  cd "$ROOT" || exit 1
fi

git init
git config user.email "ci@purereader.local"
git config user.name "PureReader CI"
git checkout -B main
git add -A
git commit -m "feat: AI rewrite + vector understanding + book source discovery

- AI: OpenAI-compatible client, rewrite engine, style presets, validation
- Vector: semantic chunker, embedding index (disk), hybrid context, rerank
- Memory anchors + background BookUnderstandingCoordinator
- Keychain API key; RewriteRecord history
- Book sources: Legado/iYueJi/PureReader import, CSS/regex/JSON rules
- Discovery search → TOC → batch download → shelf
- Settings: AI + book source manager; seed demo source" || true

git remote remove origin 2>/dev/null || true
git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/wynx1123/PureReader.git"
# force push full tree as main
git push -u origin main --force
# sync develop
git push origin main:develop --force
echo PUSH_OK
rm -rf "$REPO_DIR"
