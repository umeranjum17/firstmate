#!/usr/bin/env bash
# alias shim (slice S3, deleted by slice S10): still called by live homes,
# watchers, panes, generated per-lane extensions, and persisted records that
# resolved this path before the rename. Executed it runs the renamed script;
# sourced it loads the renamed library, because a library reached through its
# old path must not exec a shell.
set -u
_jg_alias_dir=${BASH_SOURCE[0]%/*}
[ "$_jg_alias_dir" != "${BASH_SOURCE[0]}" ] || _jg_alias_dir=.
_jg_alias_new="$_jg_alias_dir/jg-backlog-receive.sh"
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  # shellcheck source=/dev/null
  . "$_jg_alias_new"
  # A library that does not load the compatibility layer itself still owes an
  # old caller its old function names.
  if ! declare -F jg_compat_function_aliases >/dev/null 2>&1 && [ -r "$_jg_alias_dir/jg-compat.sh" ]; then
    # shellcheck source=bin/jg-compat.sh
    . "$_jg_alias_dir/jg-compat.sh"
  fi
  if declare -F jg_compat_function_aliases >/dev/null 2>&1; then jg_compat_function_aliases; fi
else
  # An old caller may run a library as `bash <old path>`, and the renamed
  # library need not be executable.
  [ -x "$_jg_alias_new" ] || exec bash "$_jg_alias_new" "$@"
  exec "$_jg_alias_new" "$@"
fi
