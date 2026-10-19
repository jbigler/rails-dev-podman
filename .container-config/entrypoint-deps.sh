#!/bin/sh
# deps@ one-shot: bring gems and node_modules in line with this worktree's
# Gemfile/package.json, then exit. rails@ Requires= this unit, and because it
# does not RemainAfterExit, every rails start runs it again -- so `mise run
# restart` after a Gemfile change is what installs the new gems.
#
# This is the only worktree container that fetches packages. rails@ used to do
# it in entrypoint-app.sh, which put registry access in the same container that
# runs (and hot-reloads) whatever code is in the worktree.
#
# Both checks below are offline, so an unchanged worktree starts rails without
# touching the network.
set -eu
cd /app

if bundle check >/dev/null 2>&1; then
  echo "deps: gems up to date"
else
  bundle install
fi

# bin/dev installs foreman on its own when it is missing. Doing it here keeps
# that fetch out of rails@. Same check bin/dev makes, so bin/dev then skips it.
gem list foreman -i --silent || gem install foreman --no-document

# npm has no offline "already satisfied" check like `bundle check`, so record
# what the last successful install was for. The node version is part of it: an
# .nvmrc bump means a new image, and native modules must be rebuilt for it.
stamp=node_modules/.deps-stamp
want="$({ node --version; cat package.json package-lock.json 2>/dev/null; } | sha256sum | cut -d' ' -f1)"
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
  echo "deps: node_modules up to date"
else
  npm install --no-audit --no-fund
  printf '%s\n' "$want" > "$stamp"
fi
