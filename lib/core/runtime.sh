# The shell runtime every other file relies on.

need() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not installed (see: chalk doctor)"
  done
}
