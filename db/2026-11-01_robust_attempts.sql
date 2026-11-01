-- Found by stress test, 1 Nov 2026.
-- 1. An attempt started offline was created on the server only at upload. If that was after
--    "start by + 2 min" of a closed window, the upload failed with "no attempt" and her answers were stuck.
--    start_attempt now takes the tablet's own start time (p_started_at) and checks the window against it.
-- 2. An abandoned open attempt (tablet data lost) came back on the next Start with its old start time,
--    so the new test ended at once with a score of 0. It is now closed as "abandoned" and a fresh attempt starts.
-- 3. A junk answer value made the whole submit fail. Grading now treats anything but 0-3 as skipped.
-- 4. Questions of a test with attempts were locked in the admin page only. The database now enforces it.
-- 5. Abandoned attempts stay in the list but their blank answers no longer feed the mistake notebook.

create or replace function public.grade_attempt(p_attempt uuid) returns void
language sql security definer set search_path = public as $$
  update public.attempts a set score = g.sc, correct = g.c, wrong = g.w, skipped = g.s
  from (
    select count(*) filter (where x.ch = k.correct) c,
           count(*) filter (where x.ch is not null and x.ch <> k.correct) w,
           count(*) filter (where x.ch is null) s,
           coalesce(sum(case when x.ch is null then 0 when x.ch = k.correct then q.marks else -t.neg_marks end), 0) sc
    from public.attempts a2
    join public.tests t on t.id = a2.test_id
    join public.test_questions tq on tq.test_id = a2.test_id
    join public.questions q on q.id = tq.question_id
    join public.question_keys k on k.question_id = q.id
    cross join lateral (select case when jsonb_typeof(a2.answers -> q.id::text) = 'number'
                                    then case when (a2.answers ->> q.id::text)::numeric in (0, 1, 2, 3) then (a2.answers ->> q.id::text)::numeric::int end
                               end ch) x
    where a2.id = p_attempt
  ) g
  where a.id = p_attempt and a.submitted_at is not null;
$$;

drop function if exists public.start_attempt(uuid, text, uuid);
create function public.start_attempt(p_test uuid, p_strategy text, p_id uuid default null, p_started_at timestamptz default null) returns public.attempts
language plpgsql security definer set search_path = public as $$
declare t public.tests; a public.attempts; n int; eff timestamptz;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  -- the tablet's own attempt: carry on (or return it if already submitted)
  select * into a from public.attempts where id = p_id and test_id = p_test and student_id = auth.uid();
  if found then return a; end if;
  select * into t from public.tests where id = p_test;
  if not found then raise exception 'test not found'; end if;
  -- another unfinished attempt: still running = carry on; long over = close it as abandoned and start a fresh one
  select * into a from public.attempts where test_id = p_test and student_id = auth.uid() and submitted_at is null;
  if found then
    if now() <= a.started_at + make_interval(mins => t.duration_min + 10) then return a; end if;
    update public.attempts set submitted_at = a.started_at + make_interval(mins => t.duration_min),
      flags = flags || jsonb_build_array(jsonb_build_object('type', 'abandoned', 't', (extract(epoch from now()) * 1000)::bigint))
    where id = a.id;
    perform public.grade_attempt(a.id);
  end if;
  -- p_started_at: when the tablet really started (an offline start reaches the server later). Never in the future,
  -- never before the test opened (15 min early download), otherwise it counts as now.
  eff := least(coalesce(p_started_at, now()), now());
  if eff < t.start_at - interval '15 minutes' then eff := now(); end if;
  if not t.published and p_started_at is null then raise exception 'test not found'; end if; -- an offline attempt is kept even if unpublished since
  if p_started_at is null and now() < t.start_at then raise exception 'test has not started'; end if;
  -- 2 min grace for a tablet clock that runs slow
  if t.end_at is not null and eff > t.end_at - make_interval(mins => t.duration_min) + interval '2 minutes' then
    raise exception 'The window for this test has closed'; end if;
  if not (p_strategy = any (t.strategies)) then raise exception 'strategy not allowed'; end if;
  select count(*) into n from public.attempts where test_id = p_test and student_id = auth.uid();
  if n >= t.max_attempts then raise exception 'All % attempts used', t.max_attempts; end if;
  insert into public.attempts (id, test_id, student_id, strategy, attempt_no, started_at)
  values (coalesce(p_id, gen_random_uuid()), p_test, auth.uid(), p_strategy, n + 1, eff) returning * into a;
  return a;
end $$;
revoke execute on function public.start_attempt(uuid, text, uuid, timestamptz) from public, anon;
grant execute on function public.start_attempt(uuid, text, uuid, timestamptz) to authenticated;

create or replace function public.get_progress(p_student uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  sid := case when public.is_admin() and p_student is not null then p_student else auth.uid() end;
  return jsonb_build_object(
    'attempts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id, 'test_id', a.test_id, 'title', t.title, 'attempt_no', a.attempt_no, 'strategy', a.strategy, 'score', a.score,
        'correct', a.correct, 'wrong', a.wrong, 'skipped', a.skipped, 'started_at', a.started_at,
        'submitted_at', a.submitted_at, 'flags', a.flags, 'times', a.times,
        'max', (select coalesce(sum(q.marks), 0) from public.test_questions tq join public.questions q on q.id = tq.question_id where tq.test_id = a.test_id))
        order by a.submitted_at)
      from public.attempts a join public.tests t on t.id = a.test_id
      where a.student_id = sid and a.submitted_at is not null), '[]'::jsonb),
    'answers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'attempt_id', a.id, 'submitted_at', a.submitted_at, 'question_id', q.id, 'subject', q.subject, 'chapter', q.chapter,
        'body', q.body, 'options', q.options, 'image_url', q.image_url, 'marks', q.marks,
        'correct', k.correct, 'solution', k.solution, 'chosen', a.answers -> q.id::text))
      from public.attempts a
      join public.test_questions tq on tq.test_id = a.test_id
      join public.questions q on q.id = tq.question_id
      join public.question_keys k on k.question_id = q.id
      where a.student_id = sid and a.submitted_at is not null and not a.flags @> '[{"type":"abandoned"}]'), '[]'::jsonb));
end $$;

create or replace function public.lock_taken_test() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.attempts where test_id = coalesce(new.test_id, old.test_id)) then
    raise exception 'This test has attempts, so its questions are locked';
  end if;
  return coalesce(new, old);
end $$;
revoke execute on function public.lock_taken_test() from public, anon, authenticated;
drop trigger if exists test_questions_lock on public.test_questions;
create trigger test_questions_lock before insert or update or delete on public.test_questions
  for each row execute function public.lock_taken_test();
