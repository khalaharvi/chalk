# Messages to the user. Errors go to stderr; `die` and its two variants are
# the only way a function ends Chalk on purpose.

# What Chalk's exit status means (docs/reference/exit-codes.md). A caller,
# such as CI or another agent, can tell "needs a person" from "Chalk
# broke" without reading the output. A signal ends Chalk with 128 + its
# number (lib/core/runtime.sh).
CHALK_EXIT_ERROR=1     # Chalk itself failed
CHALK_EXIT_USAGE=2     # the command line was wrong
CHALK_EXIT_DETAINED=3  # the run went to detention: office hours are needed
CHALK_EXIT_UNREADY=4   # nothing was attempted: the machine, repository or spec is not ready
CHALK_EXIT_PARTIAL=5   # a fleet in which some tickets were not launched

# Why Chalk ended itself, for a record of how a run ended (run_outcome).
CHALK_LAST_ERROR=""

info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { CHALK_LAST_ERROR="$*"; printf 'error: %s\n' "$*" >&2; exit "$CHALK_EXIT_ERROR"; }
# die_usage TEXT...: the command line was wrong.
die_usage() { CHALK_LAST_ERROR="$*"; printf 'error: %s\n' "$*" >&2; exit "$CHALK_EXIT_USAGE"; }
# die_unready TEXT...: a precondition is not met, so nothing was attempted
# and nothing was spent: a tool, credential, image or service is missing,
# the configuration is invalid, or the repository or spec is not in the
# state the command needs.
die_unready() { CHALK_LAST_ERROR="$*"; printf 'error: %s\n' "$*" >&2; exit "$CHALK_EXIT_UNREADY"; }
