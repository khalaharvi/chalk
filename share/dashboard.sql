-- Everything the dashboard shows, as one JSON document. :'days' is the window.
-- A loop is an agent call that works on a checkpoint: continue, retry or
-- fix-review. db_ticket_summary counts loops the same way. Timestamps are
-- UTC in ISO 8601; the page shows them in the reader's time zone.
WITH r AS (
  SELECT *, kind IN ('continue', 'retry', 'fix-review') AS is_loop,
         progressed AND kind IN ('continue', 'retry') AS is_checkpoint
    FROM runs
   WHERE created_at >= now() - make_interval(days => :'days'::int)
), e AS (
  SELECT * FROM events
   WHERE created_at >= now() - make_interval(days => :'days'::int)
)
SELECT json_build_object(
  'generated_at', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  'days', :'days'::int,
  'submitted',  (SELECT count(*) FROM e WHERE kind = 'submitted'),
  'detentions', (SELECT count(*) FROM e WHERE kind = 'detention'),
  'totals', (SELECT json_build_object(
      'cost', coalesce(sum(cost_usd), 0),
      'calls', count(*),
      'loops', count(*) FILTER (WHERE is_loop),
      'checkpoints', count(*) FILTER (WHERE is_checkpoint),
      'loop_cost', coalesce(sum(cost_usd) FILTER (WHERE is_loop), 0),
      'wasted', coalesce(sum(cost_usd) FILTER (WHERE is_loop AND NOT progressed), 0),
      'tickets', count(DISTINCT (repo, ticket)),
      'input_tokens', coalesce(sum(input_tokens), 0),
      'output_tokens', coalesce(sum(output_tokens), 0),
      'cache_read_tokens', coalesce(sum(cache_read_tokens), 0),
      'cache_write_tokens', coalesce(sum(cache_write_tokens), 0),
      'denials', coalesce(sum(denials), 0),
      'loop_denials', coalesce(sum(denials) FILTER (WHERE is_loop), 0))
    FROM r),
  -- Hourly, so the page can add the hours up into the reader's own days.
  'by_hour', (SELECT coalesce(json_agg(h ORDER BY h.hour), '[]') FROM (
      SELECT to_char(date_trunc('hour', created_at AT TIME ZONE 'UTC'), 'YYYY-MM-DD"T"HH24:00:00"Z"') AS hour,
             sum(cost_usd) AS cost,
             coalesce(sum(cost_usd) FILTER (WHERE is_loop AND NOT progressed), 0) AS wasted
        FROM r GROUP BY 1) h),
  'by_kind', (SELECT coalesce(json_agg(k ORDER BY k.cost DESC), '[]') FROM (
      SELECT kind, count(*) AS calls, sum(cost_usd) AS cost,
             round(avg(cost_usd), 4) AS avg_cost, round(avg(duration_s)) AS avg_seconds
        FROM r GROUP BY kind) k),
  'by_model', (SELECT coalesce(json_agg(m ORDER BY m.cost DESC), '[]') FROM (
      SELECT model, count(*) AS loops, sum(cost_usd) AS cost,
             count(*) FILTER (WHERE is_checkpoint) AS checkpoints
        FROM r WHERE is_loop GROUP BY model) m),
  'by_prompts', (SELECT coalesce(json_agg(p ORDER BY p.first_seen), '[]') FROM (
      SELECT prompts, to_char(min(created_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS first_seen,
             count(*) AS loops, sum(cost_usd) AS cost,
             count(*) FILTER (WHERE is_checkpoint) AS checkpoints,
             count(*) FILTER (WHERE kind = 'retry') AS retries
        FROM r WHERE is_loop GROUP BY prompts) p),
  'budget', (SELECT json_build_object(
      'loops', count(*),
      'cap', max(budget_usd),
      'cap_min', min(budget_usd),
      'p50', percentile_cont(0.5) WITHIN GROUP (ORDER BY cost_usd),
      'p90', percentile_cont(0.9) WITHIN GROUP (ORDER BY cost_usd),
      'max', max(cost_usd),
      'near_cap', count(*) FILTER (WHERE cost_usd >= 0.95 * budget_usd))
    FROM r WHERE is_loop),
  'review', (SELECT json_build_object(
      'reviews', count(*) FILTER (WHERE kind = 'review'),
      'failed', count(*) FILTER (WHERE kind = 'review' AND agent_status = 'fail'),
      'cost', coalesce(sum(cost_usd) FILTER (WHERE kind = 'review'), 0),
      'fix_cost', coalesce(sum(cost_usd) FILTER (WHERE kind = 'fix-review'), 0))
    FROM r),
  'spec', (SELECT json_build_object(
      'checks', count(*),
      'failed', count(*) FILTER (WHERE agent_status = 'fail'),
      'cost', coalesce(sum(cost_usd), 0))
    FROM r WHERE kind = 'spec-check'),
  'lessons', (SELECT json_build_object(
      'with', count(*) FILTER (WHERE lessons > 0),
      'with_passed', count(*) FILTER (WHERE lessons > 0 AND progressed),
      'without', count(*) FILTER (WHERE lessons = 0),
      'without_passed', count(*) FILTER (WHERE lessons = 0 AND progressed))
    FROM r WHERE kind = 'retry'),
  -- The tests that failed in the most loops, up to ten per repository, from
  -- the failing test IDs stored with each failed loop (runs.failing_tests).
  'failing_tests', (SELECT coalesce(json_agg(f ORDER BY f.repo, f.n), '[]') FROM (
      SELECT repo, test, loops, tickets,
             to_char(last AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS last, n
        FROM (SELECT repo, t.test, count(*) AS loops, count(DISTINCT ticket) AS tickets,
                     max(created_at) AS last,
                     row_number() OVER (PARTITION BY repo
                                        ORDER BY count(*) DESC, max(created_at) DESC, t.test) AS n
                FROM r CROSS JOIN LATERAL regexp_split_to_table(r.failing_tests, E'\n') AS t(test)
               WHERE is_loop AND t.test <> ''
               GROUP BY repo, t.test) ranked
       WHERE n <= 10) f),
  -- The verdict ledger, per run (run_id): what CHALK_FP_RULES=on would have
  -- done. It detains a run at its first stopping verdict (deja_vu, repeat,
  -- no_change), so the loops after that one are what it would have saved.
  -- A run is detained when a lesson names it; fingerprinted when any of its
  -- loops has a verdict (not CHALK_FP_RULES=off); could_stop when one of
  -- those verdicts was judged by the stopping rules, that is, is not
  -- blocked or agent_error. Only those runs count towards the bar for
  -- turning the rules on: a run whose every verdict was a blocker or an
  -- agent error (such as one detained because the agent reported a
  -- blocker) holds no evidence about deja_vu, repeat or no_change, and its
  -- spend is spend no rule could save. Detained runs left out are counted
  -- apart: blocked_only, and no_verdicts for CHALK_FP_RULES=off.
  -- The kind of detention is not the test: a run detained at the loop
  -- limit or by the review can still have loops that repeat themselves.
  -- Only runs in shadow mode are counted (fp_rules shadow, or NULL from
  -- before it was recorded, when shadow was the default). A run under
  -- CHALK_FP_RULES=on already stopped at its first stop: nothing ran after
  -- it, so it would add spend with no progress and no savings, and could
  -- never show a false stop. Those runs are only counted, as stopped_on.
  'ledger', (WITH l AS (
      SELECT * FROM r WHERE is_loop AND run_id IS NOT NULL
    ), per_run AS (
      SELECT run_id, min(repo) AS repo, min(ticket) AS ticket,
             EXISTS (SELECT 1 FROM lessons ls WHERE ls.run_id = l.run_id) AS detained,
             coalesce(bool_or(verdict IS NOT NULL), false) AS fingerprinted,
             coalesce(bool_or(verdict NOT IN ('blocked', 'agent_error')), false) AS could_stop,
             coalesce(bool_or(fp_rules = 'on'), false) AS rules_on,
             min(loop) FILTER (WHERE verdict IN ('deja_vu', 'repeat', 'no_change')) AS stop_loop,
             (array_agg(verdict ORDER BY loop)
                FILTER (WHERE verdict IN ('deja_vu', 'repeat', 'no_change')))[1] AS stop_verdict,
             (array_agg(verdict ORDER BY loop DESC))[1] AS last_verdict,
             coalesce(sum(cost_usd) FILTER (WHERE NOT progressed), 0) AS no_progress_cost,
             max(created_at) AS last
        FROM l GROUP BY run_id
    ), lr AS (
      -- after_cost: the loops after the first stop. A false stop is a run
      -- that progressed after it.
      SELECT p.*,
             coalesce((SELECT sum(cost_usd) FROM l
                        WHERE l.run_id = p.run_id AND l.loop > p.stop_loop), 0) AS after_cost,
             coalesce((SELECT bool_or(progressed) FROM l
                        WHERE l.run_id = p.run_id AND l.loop > p.stop_loop), false) AS false_stop
        FROM per_run p
       WHERE NOT p.rules_on
    )
    SELECT json_build_object(
      'detained_runs', count(*) FILTER (WHERE detained AND could_stop),
      'no_progress_cost', coalesce(sum(no_progress_cost) FILTER (WHERE detained AND could_stop), 0),
      'saved', coalesce(sum(after_cost) FILTER (WHERE detained AND could_stop), 0),
      'blocked_only', count(*) FILTER (WHERE detained AND fingerprinted AND NOT could_stop),
      'blocked_only_cost', coalesce(sum(no_progress_cost)
                                      FILTER (WHERE detained AND fingerprinted AND NOT could_stop), 0),
      'no_verdicts', count(*) FILTER (WHERE detained AND NOT fingerprinted),
      'by_verdict', (SELECT coalesce(json_agg(v ORDER BY v.saved DESC), '[]') FROM (
          SELECT stop_verdict AS verdict, count(*) AS runs, sum(after_cost) AS saved
            FROM lr WHERE detained AND stop_loop IS NOT NULL GROUP BY stop_verdict) v),
      'false_stops', count(*) FILTER (WHERE false_stop),
      'false_stop_cost', coalesce(sum(after_cost) FILTER (WHERE false_stop), 0),
      'converging', count(*) FILTER (WHERE detained AND last_verdict = 'improving'),
      'stopped_on', (SELECT count(*) FROM per_run
                      WHERE rules_on AND detained AND stop_loop IS NOT NULL),
      'runs', (SELECT coalesce(json_agg(x ORDER BY x.last DESC), '[]') FROM (
          SELECT run_id, repo, ticket, detained, could_stop, stop_verdict, stop_loop, after_cost,
                 false_stop, detained AND last_verdict IS NOT DISTINCT FROM 'improving' AS converging,
                 to_char(last AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS last
            FROM lr WHERE detained OR stop_loop IS NOT NULL
           ORDER BY lr.last DESC LIMIT 50) x),
      -- Failed loops per repository, and how many of them named no tests.
      'unknown_tests', (SELECT coalesce(json_agg(u ORDER BY u.loops DESC), '[]') FROM (
          SELECT repo, count(*) AS loops, count(*) FILTER (WHERE failing IS NULL) AS unknown
            FROM l
           WHERE rubric_exit <> 0 AND agent_status = 'ok'
             AND verdict IS NOT NULL AND verdict NOT IN ('blocked', 'agent_error')
           GROUP BY repo) u))
    FROM lr),
  'tickets', (SELECT coalesce(json_agg(t ORDER BY t.last DESC), '[]') FROM (
      SELECT * FROM (
      SELECT r.repo, r.ticket, count(*) FILTER (WHERE is_loop) AS loops,
             sum(cost_usd) AS cost,
             (SELECT count(*) FROM events ev
               WHERE ev.repo = r.repo AND ev.ticket = r.ticket AND ev.kind = 'detention') AS detentions,
             -- The latest event, or, before any, whether the last call was a
             -- passing final review: then the work is done but not submitted.
             coalesce((SELECT ev.kind FROM events ev
                        WHERE ev.repo = r.repo AND ev.ticket = r.ticket
                        ORDER BY ev.id DESC LIMIT 1),
                      (SELECT 'ready' FROM (
                         SELECT kind, agent_status FROM runs lr
                          WHERE lr.repo = r.repo AND lr.ticket = r.ticket
                          ORDER BY lr.id DESC LIMIT 1) last_call
                        WHERE kind = 'review' AND agent_status = 'pass'),
                      'in progress') AS state,
             to_char(max(created_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS last
        FROM r GROUP BY r.repo, r.ticket) recent
       ORDER BY last DESC LIMIT 50) t)
);
