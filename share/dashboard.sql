-- Everything the dashboard shows, as one JSON document. :'days' is the window.
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
  'generated_at', to_char(now(), 'YYYY-MM-DD HH24:MI'),
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
      'denials', coalesce(sum(denials), 0))
    FROM r),
  'by_day', (SELECT coalesce(json_agg(d ORDER BY d.day), '[]') FROM (
      SELECT to_char(created_at, 'YYYY-MM-DD') AS day, sum(cost_usd) AS cost,
             coalesce(sum(cost_usd) FILTER (WHERE is_loop AND NOT progressed), 0) AS wasted
        FROM r GROUP BY 1) d),
  'by_kind', (SELECT coalesce(json_agg(k ORDER BY k.cost DESC), '[]') FROM (
      SELECT kind, count(*) AS calls, sum(cost_usd) AS cost,
             round(avg(cost_usd), 4) AS avg_cost, round(avg(duration_s)) AS avg_seconds
        FROM r GROUP BY kind) k),
  'by_model', (SELECT coalesce(json_agg(m ORDER BY m.cost DESC), '[]') FROM (
      SELECT model, count(*) AS loops, sum(cost_usd) AS cost,
             count(*) FILTER (WHERE is_checkpoint) AS checkpoints
        FROM r WHERE is_loop GROUP BY model) m),
  'by_prompts', (SELECT coalesce(json_agg(p ORDER BY p.first_seen), '[]') FROM (
      SELECT prompts, to_char(min(created_at), 'YYYY-MM-DD') AS first_seen,
             count(*) AS loops, sum(cost_usd) AS cost,
             count(*) FILTER (WHERE is_checkpoint) AS checkpoints,
             count(*) FILTER (WHERE kind = 'retry') AS retries
        FROM r WHERE is_loop GROUP BY prompts) p),
  'budget', (SELECT json_build_object(
      'loops', count(*),
      'cap', max(budget_usd),
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
  'tickets', (SELECT coalesce(json_agg(t ORDER BY t.last DESC), '[]') FROM (
      SELECT * FROM (
      SELECT r.repo, r.ticket, count(*) FILTER (WHERE is_loop) AS loops,
             sum(cost_usd) AS cost,
             (SELECT count(*) FROM events ev
               WHERE ev.repo = r.repo AND ev.ticket = r.ticket AND ev.kind = 'detention') AS detentions,
             coalesce((SELECT ev.kind FROM events ev
                        WHERE ev.repo = r.repo AND ev.ticket = r.ticket
                        ORDER BY ev.id DESC LIMIT 1), 'in progress') AS state,
             to_char(max(created_at), 'YYYY-MM-DD HH24:MI') AS last
        FROM r GROUP BY r.repo, r.ticket) recent
       ORDER BY last DESC LIMIT 50) t)
);
