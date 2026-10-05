# Lesson recall: the resolved lessons most like the failure in hand, for
# the next loop's prompt. Lessons live in the lessons table in chalk-db and
# are matched there (db_recall_lessons); nothing else runs. Recall is best
# effort: a failure here never stops a run.

# memory_recall MODE QUERY [FINGERPRINT] [FIRST_ERROR]: prints up to three
# lessons as a markdown list, those for the same failure first. MODE is
#   spec     no failure yet: QUERY is the spec
#   failure  after a failed rubric: QUERY is E and T, FINGERPRINT and
#            FIRST_ERROR come from the loop's fingerprint (fp_compute)
#   text     after a loop with no fingerprint: QUERY is the failure output
# Never fails.
memory_recall() {
  db_recall_lessons "${| repo_name; }" "$1" "${2:0:4000}" "${3:-}" "${4:-}" 2>/dev/null || true
}

# Hindsight, the optional lesson index that ran as the chalk-memory
# container, was removed. `chalk memory` is kept to say how to clean up.
cmd_memory() {
  info "Hindsight lesson memory was removed from Chalk. Lessons are recalled from the"
  info "lessons table in chalk-db (the same failure first, then similar errors), so"
  info "nothing else needs to run, and CHALK_MEMORY_* settings are ignored."
  info ""
  info "If you ran it, remove its container and data with:"
  info "  docker rm -f chalk-memory && docker volume rm chalk-memory-data"
}
