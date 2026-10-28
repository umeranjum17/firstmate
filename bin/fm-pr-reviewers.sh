#!/usr/bin/env bash
# alias shim (slice S3, deleted by slice S10): still called by live homes,
# watchers, panes, generated per-lane extensions, and persisted records that
# resolved this path before the rename. Executed it runs the renamed script;
# sourced it loads the renamed library, because a library reached through its
# old path must not exec a shell.
set -u
_jg_alias_dir=${BASH_SOURCE[0]%/*}
[ "$_jg_alias_dir" != "${BASH_SOURCE[0]}" ] || _jg_alias_dir=.
_jg_alias_new="$_jg_alias_dir/jg-pr-reviewers.sh"
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  # shellcheck source=/dev/null
  . "$_jg_alias_new"
  if declare -F jg_compat_function_aliases >/dev/null 2>&1; then jg_compat_function_aliases; fi
else
  exec "$_jg_alias_new" "$@"
fi
