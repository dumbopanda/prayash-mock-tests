-- Admin can mark an attempt's cheat flags as reviewed ("ignore"); ignored ones stop counting.
alter table public.attempts add column if not exists flags_ignored boolean not null default false;

create or replace function public.ignore_flags(p_ids uuid[], p_ignore boolean default true)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.attempts set flags_ignored = p_ignore where id = any(p_ids);
end $$;
revoke all on function public.ignore_flags(uuid[], boolean) from public, anon;
grant execute on function public.ignore_flags(uuid[], boolean) to authenticated;

CREATE OR REPLACE FUNCTION public.get_progress(p_student uuid DEFAULT NULL::uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare sid uuid;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  sid := case when public.is_admin() and p_student is not null then p_student else auth.uid() end;
  return jsonb_build_object(
    'attempts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id, 'test_id', a.test_id, 'title', t.title, 'attempt_no', a.attempt_no, 'strategy', a.strategy, 'score', a.score,
        'correct', a.correct, 'wrong', a.wrong, 'skipped', a.skipped, 'started_at', a.started_at,
        'submitted_at', a.submitted_at, 'flags', a.flags, 'flags_ignored', a.flags_ignored, 'times', a.times,
        'max', (select coalesce(sum(q.marks), 0) from public.test_questions tq join public.questions q on q.id = tq.question_id where tq.test_id = a.test_id))
        order by a.submitted_at)
      from public.attempts a join public.tests t on t.id = a.test_id
      where a.student_id = sid and a.submitted_at is not null), '[]'::jsonb),
    'answers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'attempt_id', a.id, 'submitted_at', a.submitted_at, 'question_id', q.id, 'subject', q.subject, 'chapter', q.chapter,
        'body', q.body, 'options', q.options, 'image_url', q.image_url, 'marks', q.marks,
        'correct', k.correct, 'solution', k.solution, 'concept', k.concept, 'formula', k.formula,
        'source_chapter', q.source_chapter, 'source_page', q.source_page, 'difficulty', q.difficulty,
        'chosen', a.answers -> q.id::text))
      from public.attempts a
      join public.test_questions tq on tq.test_id = a.test_id
      join public.questions q on q.id = tq.question_id
      join public.question_keys k on k.question_id = q.id
      where a.student_id = sid and a.submitted_at is not null and not a.flags @> '[{"type":"abandoned"}]'), '[]'::jsonb));
end $function$;
