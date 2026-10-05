-- chalk share: the counts that `chalk share` (lib/share.sh) adds to the
-- report card's (share/dashboard.sql), as one JSON document. :'days' is the
-- window. Only counts leave this query, each under a label written here:
-- no column a person or a repository wrote (repository, ticket, branch,
-- signature, note, lesson, question, test names, errors) is selected, and
-- a column Chalk writes from a fixed set is still mapped onto that set, so
-- anything unexpected in it reads as 'other'. share/share.jq then keeps
-- only what its allow-list names.
WITH r AS (
  SELECT *, kind IN ('continue', 'retry', 'fix-review') AS is_loop
    FROM runs
   WHERE created_at >= now() - make_interval(days => :'days'::int)
), l AS (
  SELECT * FROM lessons
   WHERE created_at >= now() - make_interval(days => :'days'::int)
), e AS (
  SELECT * FROM events
   WHERE created_at >= now() - make_interval(days => :'days'::int)
), d AS (
  SELECT * FROM decisions
   WHERE created_at >= now() - make_interval(days => :'days'::int)
)
SELECT json_build_object(
  'runs', (SELECT count(DISTINCT run_id) FROM r),
  'repositories', (SELECT count(DISTINCT repo) FROM r),
  -- How each loop's agent call ended: ok, blocked, or any CLI error.
  'agent', (SELECT json_build_object(
      'ok', count(*) FILTER (WHERE agent_status = 'ok'),
      'blocked', count(*) FILTER (WHERE agent_status = 'blocked'),
      'error', count(*) FILTER (WHERE agent_status NOT IN ('ok', 'blocked')),
      'turns', coalesce(sum(turns), 0))
    FROM r WHERE is_loop),
  -- Loops by verdict (lib/fingerprint.sh); none for a loop that progressed
  -- or was not fingerprinted.
  'verdicts', (SELECT coalesce(json_object_agg(v, n), '{}') FROM (
      SELECT CASE WHEN verdict IS NULL THEN 'none'
                  WHEN verdict IN ('blocked', 'agent_error', 'first', 'deja_vu', 'repeat',
                                   'no_change', 'improving', 'spinning', 'other') THEN verdict
                  ELSE 'other' END AS v, count(*) AS n
        FROM r WHERE is_loop GROUP BY 1) x),
  -- Loops by CHALK_FP_RULES; unrecorded for loops from before it was.
  'fp_rules', (SELECT coalesce(json_object_agg(v, n), '{}') FROM (
      SELECT CASE WHEN fp_rules IS NULL THEN 'unrecorded'
                  WHEN fp_rules IN ('off', 'shadow', 'on') THEN fp_rules
                  ELSE 'other' END AS v, count(*) AS n
        FROM r WHERE is_loop GROUP BY 1) x),
  -- Ticket milestones.
  'events', (SELECT coalesce(json_object_agg(v, n), '{}') FROM (
      SELECT CASE WHEN kind IN ('detention', 'submitted', 'spec_blocked', 'ready') THEN kind
                  ELSE 'other' END AS v, count(*) AS n
        FROM e GROUP BY 1) x),
  -- Detentions by why, read from the start of the reason run_detain
  -- (lib/run.sh) puts first in the signature. Only the label is kept.
  'detentions_by_reason', (SELECT coalesce(json_object_agg(v, n), '{}') FROM (
      SELECT CASE WHEN signature LIKE 'agent reported a blocker%' THEN 'blocked'
                  WHEN signature LIKE 'loop limit of %' THEN 'loop_limit'
                  WHEN signature LIKE 'final review still finds problems%' THEN 'review'
                  WHEN signature LIKE 'deja\_vu: %' THEN 'deja_vu'
                  WHEN signature LIKE 'repeat: %' THEN 'repeat'
                  WHEN signature LIKE 'no\_change: %' THEN 'no_change'
                  WHEN signature LIKE 'stuck: %' THEN 'stuck'
                  WHEN signature LIKE 'rubric failed%' THEN 'failed'
                  WHEN signature LIKE 'agent stopped early%' THEN 'agent_error'
                  WHEN signature LIKE 'rubric passed but no checkpoint%' THEN 'no_checkpoint'
                  ELSE 'other' END AS v, count(*) AS n
        FROM l GROUP BY 1) x),
  -- Office hours: detentions resolved, how many notes became a lesson,
  -- and where those lessons are recalled.
  'lessons', (SELECT json_build_object(
      'opened', count(*),
      'resolved', count(*) FILTER (WHERE resolution IS NOT NULL),
      'distilled', count(*) FILTER (WHERE lesson IS NOT NULL),
      'scope_repo', count(*) FILTER (WHERE resolution IS NOT NULL AND scope = 'repo'),
      'scope_general', count(*) FILTER (WHERE resolution IS NOT NULL AND scope = 'general'),
      'fingerprinted', count(*) FILTER (WHERE fingerprint IS NOT NULL))
    FROM l),
  -- The decider's questions by the mode they were asked in.
  'decider_modes', (SELECT coalesce(json_object_agg(v, n), '{}') FROM (
      SELECT CASE WHEN mode IN ('shadow', 'on') THEN mode ELSE 'other' END AS v, count(*) AS n
        FROM d GROUP BY 1) x)
);
