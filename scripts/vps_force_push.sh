#!/bin/bash
set -e
WORKDIR=/tmp/PureReader_push
TAR=/tmp/purereader_src.tar.gz

if [ -z "$GH_TOKEN" ]; then
  echo "GH_TOKEN missing"
  exit 1
fi
if [ ! -f "$TAR" ]; then
  echo "tar missing: $TAR"
  exit 1
fi

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
tar xzf "$TAR"
cd "$WORKDIR/PureReader"

echo "=== contents ==="
ls -la

# Remove any nested .git if present
rm -rf .git

git init -b main
git config --local user.email "ci@purereader.local"
git config --local user.name "PureReader CI"
git add -A
echo "=== status ==="
git status --short | head -50
echo "file count: $(git status --short | wc -l)"

git commit -m "feat: AI rewrite + vector understanding + book source discovery

- AI rewrite engine + vector index + memory anchors
- Book source discovery (Legado/iYueJi/PureReader rules)
- Settings + Keychain API key"

git remote remove origin 2>/dev/null || true
git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/wynx1123/PureReader.git"
git push -u origin main --force
git push origin main:develop --force
echo PUSH_OK
echo "commit: $(git rev-parse HEAD)"
