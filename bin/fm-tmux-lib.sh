#!/usr/bin/env bash
# alias shim (slice S3, deleted by slice S10): still called by live homes,
# watchers, panes, generated per-lane extensions, and persisted records that
# resolved this path before the rename. Executed it runs the renamed script;
# sourced it loads the renamed library, because a library reached through its
# old path must not exec a shell.
set -u
_jg_alias_dir=$(dirname "${BASH_SOURCE[0]}")
_jg_alias_new="$_jg_alias_dir/jg-tmux-lib.sh"
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  . "$_jg_alias_new"
else
  exec "$_jg_alias_new" "$@"
fi
