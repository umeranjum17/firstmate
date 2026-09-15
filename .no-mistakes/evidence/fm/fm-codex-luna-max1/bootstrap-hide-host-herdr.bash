# Keep this bootstrap-suite environment hermetic when the host has a real /usr/bin/herdr.
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = herdr ]; then
    old_ifs=$IFS
    IFS=:
    for dir in $PATH; do
      [ -x "$dir/herdr" ] || continue
      case "$dir/herdr" in
        /usr/bin/herdr|/bin/herdr) continue ;;
      esac
      printf '%s\n' "$dir/herdr"
      IFS=$old_ifs
      return 0
    done
    IFS=$old_ifs
    return 1
  fi
  builtin command "$@"
}
