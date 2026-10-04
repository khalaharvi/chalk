# Messages to the user. Errors go to stderr; `die` is the only way a
# function ends Chalk on purpose.

info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
