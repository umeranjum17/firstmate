#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  eval "[ -n \"\${$_jg_new+set}\" ]" && continue
  eval "_jg_val=\${_jg_old}"
  export "$_jg_new=$_jg_val"
done
unset _jg_old _jg_new _jg_val 2>/dev/null || true
# Print the newest data/*retro*/report.md across the main home and known sibling
# firstmate homes (secondmates.md and ~/.treehouse/firstmate-*/*/firstmate), by
# mtime. No output when none exist. Usage: newest-retro-report.sh <main-home>
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo 'usage: newest-retro-report.sh <main-home>' >&2
  exit 2
fi
main=$(cd "$1" && pwd -P)
treehouse=${JG_TREEHOUSE:-$HOME/.treehouse}

datas=
add_data() {
  local d=$1 resolved
  [ -d "$d" ] || return 0
  resolved=$(cd "$d" && pwd -P)
  case $'\n'"$datas"$'\n' in
    *$'\n'"$resolved"$'\n'*) return 0 ;;
  esac
  datas=${datas:+$datas$'\n'}$resolved
}

add_data "$main/data"
if [ -f "$main/data/secondmates.md" ]; then
  while IFS= read -r hp; do
    [ -n "$hp" ] && add_data "$hp/data"
  done < <(sed -n 's/.*(home: \([^;]*\);.*/\1/p' "$main/data/secondmates.md")
fi
if [ -d "$treehouse" ]; then
  for hp in "$treehouse"/firstmate-*/*/firstmate; do
    [ -d "$hp" ] && add_data "$hp/data"
  done
fi

newest=
newest_m=0
while IFS= read -r data; do
  [ -n "$data" ] || continue
  for report in "$data"/*retro*/report.md; do
    [ -f "$report" ] || continue
    m=$(stat -c %Y "$report")
    if [ -z "$newest" ] || [ "$m" -gt "$newest_m" ]; then
      newest=$report
      newest_m=$m
    fi
  done
done <<<"$datas"

[ -n "$newest" ] && printf '%s\n' "$newest"
exit 0
