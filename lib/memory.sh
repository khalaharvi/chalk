# Lesson recall: the resolved lessons most like the failure in hand, for
# the next loop's prompt. Lessons live in the lessons table in chalk-db and
# are matched there (db_recall_lessons). Recall is best effort: a failure
# here never stops a run.
#
# The ladder: the same failure (exact fingerprint), then similar errors
# (lexical). With a decider (CHALK_DECIDER shadow or on) and enough
# resolved lessons, two more steps follow: lessons whose failure means the
# same (semantic, Postgres 17), and the decider's rerank of the candidates
# (decider_recall). In shadow mode those only record what they would have
# chosen; the prompt gets what the first two steps found.

# memory_recall MODE QUERY [FINGERPRINT] [FIRST_ERROR] -> REPLY: up to three
# lessons as a markdown list, those for the same failure first; empty when
# none match. MODE is
#   spec     no failure yet: QUERY is the spec
#   failure  after a failed rubric: QUERY is E and T, FINGERPRINT and
#            FIRST_ERROR come from the loop's fingerprint (fp_compute)
#   text     after a loop with no fingerprint: QUERY is the failure output
# A value function, so that the decider's calls spend this loop's budget.
memory_recall() {
  local repo query="${2:0:4000}" lessons reranked=""
  repo="${| repo_name; }"
  lessons="$(db_recall_lessons "$repo" "$1" "$query" "${3:-}" "${4:-}" 2>/dev/null || true)"
  if [[ ${CHALK_DECIDER:-off} != off ]] && decider_recall reranked "$repo" "$1" "$query" "${3:-}" "${4:-}"; then
    lessons="$reranked"
  fi
  REPLY="$lessons"
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
