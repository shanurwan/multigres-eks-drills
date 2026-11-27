#!/usr/bin/env bash
# Build everything the production scenarios copy into the cluster, with Docker only:
#   bin/supafirehose  Multigres's own load tool, at a pinned commit, unmodified
#   bin/fhrec         records supafirehose's metrics stream
#   bin/authload      drives Supabase Auth like app users
#   bin/ackcheck      the acknowledged-write checker from failure-drill/
#
#   scripts/build.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
SUPAFIREHOSE_COMMIT="${SUPAFIREHOSE_COMMIT:-05edf8a}"
GO_IMAGE="${GO_IMAGE:-golang:1.27.4-alpine}"
mkdir -p "$here/bin"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone -q https://github.com/multigres/supafirehose "$work/supafirehose"
git -C "$work/supafirehose" checkout -q "$SUPAFIREHOSE_COMMIT"
docker build -q -t supafirehose:"$SUPAFIREHOSE_COMMIT" "$work/supafirehose" >/dev/null
cid="$(docker create supafirehose:"$SUPAFIREHOSE_COMMIT")"
docker cp "$cid:/app/supafirehose" "$here/bin/supafirehose" >/dev/null
docker rm "$cid" >/dev/null
cp "$work/supafirehose/init.sql" "$here/sql/supafirehose-init.sql"

build() { # <dir> <name>
  docker run --rm -v "$1:/src" -v "$here/bin:/out" -w /src -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=amd64 \
    "$GO_IMAGE" sh -c "go mod tidy && go build -trimpath -o /out/$2 ."
}
build "$here/tools/fhrec" fhrec
build "$here/tools/authload" authload
build "$here/../failure-drill/tools/ackcheck" ackcheck
ls -l "$here/bin"
