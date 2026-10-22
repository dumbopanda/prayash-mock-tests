-- Every attempt is kept. Up to tests.max_attempts (default 3) per student per test.
-- Re-grades kept attempts when an answer key, marks or negative marking changes.
-- A test with attempts cannot be deleted.

alter table public.tests add column if not exists max_attempts int not null default 3 check (max_attempts between 1 and 10);
alter table public.attempts add column if not exists attempt_no int not null default 1;
alter table public.attempts drop constraint if exists attempts_test_id_student_id_key;
alter table public.attempts add constraint attempts_test_student_no_key unique (test_id, student_id, attempt_no);
create unique index if not exists attempts_one_open on public.attempts (test_id, student_id) where submitted_at is null;
alter table public.attempts drop constraint attempts_test_id_fkey;
alter table public.attempts add constraint attempts_test_id_fkey foreign key (test_id) references public.tests(id) on delete restrict;

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
    cross join lateral (select (a2.answers ->> q.id::text)::int ch) x
    where a2.id = p_attempt
  ) g
  where a.id = p_attempt and a.submitted_at is not null;
$$;

-- p_id: attempt id made on the tablet, so a retried upload never opens a second attempt
drop function if exists public.start_attempt(uuid, text);
create function public.start_attempt(p_test uuid, p_strategy text, p_id uuid default null) returns public.attempts
language plpgsql security definer set search_path = public as $$
declare t public.tests; a public.attempts; n int;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  -- the tablet's own attempt first, else an unfinished one
  select * into a from public.attempts where test_id = p_test and student_id = auth.uid() and (id = p_id or submitted_at is null)
    order by (id = p_id) desc nulls last limit 1;
  if found then return a; end if;
  select * into t from public.tests where id = p_test and published;
  if not found then raise exception 'test not found'; end if;
  if now() < t.start_at then raise exception 'test has not started'; end if;
  if not (p_strategy = any (t.strategies)) then raise exception 'strategy not allowed'; end if;
  select count(*) into n from public.attempts where test_id = p_test and student_id = auth.uid();
  if n >= t.max_attempts then raise exception 'All % attempts used', t.max_attempts; end if;
  insert into public.attempts (id, test_id, student_id, strategy, attempt_no)
  values (coalesce(p_id, gen_random_uuid()), p_test, auth.uid(), p_strategy, n + 1) returning * into a;
  return a;
end $$;

drop function if exists public.get_result(uuid, uuid);
create function public.get_result(p_test uuid, p_student uuid default null, p_attempt uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sid uuid; a public.attempts; t public.tests;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  sid := case when public.is_admin() and p_student is not null then p_student else auth.uid() end;
  select * into a from public.attempts where test_id = p_test and student_id = sid and submitted_at is not null
    and (p_attempt is null or id = p_attempt) order by attempt_no desc limit 1;
  if not found then raise exception 'not submitted'; end if;
  select * into t from public.tests where id = p_test;
  return jsonb_build_object(
    'attempt', to_jsonb(a),
    'test', jsonb_build_object('id', t.id, 'title', t.title, 'neg_marks', t.neg_marks, 'duration_min', t.duration_min, 'max_attempts', t.max_attempts),
    'attempts', (select jsonb_agg(jsonb_build_object('id', x.id, 'attempt_no', x.attempt_no, 'score', x.score, 'submitted_at', x.submitted_at) order by x.attempt_no)
                 from public.attempts x where x.test_id = p_test and x.student_id = sid and x.submitted_at is not null),
    'questions', (
      select jsonb_agg(jsonb_build_object('id',q.id,'subject',q.subject,'chapter',q.chapter,'body',q.body,
                                          'options',q.options,'image_url',q.image_url,'marks',q.marks,
                                          'position',tq.position,'correct',k.correct,'solution',k.solution)
                       order by tq.position)
      from public.test_questions tq
      join public.questions q on q.id = tq.question_id
      join public.question_keys k on k.question_id = q.id
      where tq.test_id = p_test));
end $$;

drop function if exists public.submit_attempt(uuid, jsonb, jsonb, jsonb, jsonb);
create function public.submit_attempt(p_test uuid, p_answers jsonb, p_marked jsonb, p_times jsonb, p_flags jsonb, p_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.attempts;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  select * into a from public.attempts where test_id = p_test and student_id = auth.uid()
    and (id = p_id or (p_id is null and submitted_at is null)) limit 1;
  if not found then raise exception 'no attempt'; end if;
  if a.submitted_at is null then -- a repeated upload changes nothing
    update public.attempts set submitted_at = now(), answers = coalesce(p_answers, '{}'), marked = coalesce(p_marked, '[]'),
      times = coalesce(p_times, '{}'), flags = coalesce(p_flags, '[]')
    where id = a.id;
    perform public.grade_attempt(a.id);
  end if;
  return public.get_result(p_test, null, a.id);
end $$;

create or replace function public.get_paper(p_test uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.tests;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  select * into t from public.tests where id = p_test and published;
  if not found then raise exception 'test not found'; end if;
  if now() < t.start_at - interval '15 minutes' and not public.is_admin() then raise exception 'test not open yet'; end if;
  return jsonb_build_object(
    'now', now(),
    'test', jsonb_build_object('id',t.id,'title',t.title,'start_at',t.start_at,'duration_min',t.duration_min,
                               'neg_marks',t.neg_marks,'cheat_flags',t.cheat_flags,'strategies',t.strategies,'max_attempts',t.max_attempts,
                               'attempts_used',(select count(*) from public.attempts where test_id = p_test and student_id = auth.uid() and submitted_at is not null)),
    'questions', coalesce((
      select jsonb_agg(jsonb_build_object('id',q.id,'subject',q.subject,'chapter',q.chapter,'body',q.body,
                                          'options',q.options,'image_url',q.image_url,'marks',q.marks,'position',tq.position)
                       order by tq.position)
      from public.test_questions tq join public.questions q on q.id = tq.question_id
      where tq.test_id = p_test), '[]'::jsonb));
end $$;

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
      where a.student_id = sid and a.submitted_at is not null), '[]'::jsonb));
end $$;

create or replace function public.regrade_on_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.grade_attempt(a.id) from public.attempts a
  where a.submitted_at is not null and (
       (tg_table_name = 'question_keys' and a.test_id in (select test_id from public.test_questions where question_id = new.question_id))
    or (tg_table_name = 'questions' and a.test_id in (select test_id from public.test_questions where question_id = new.id))
    or (tg_table_name = 'tests' and a.test_id = new.id));
  return null;
end $$;
drop trigger if exists regrade_key on public.question_keys;
create trigger regrade_key after update of correct on public.question_keys
  for each row when (old.correct is distinct from new.correct) execute function public.regrade_on_change();
drop trigger if exists regrade_marks on public.questions;
create trigger regrade_marks after update of marks on public.questions
  for each row when (old.marks is distinct from new.marks) execute function public.regrade_on_change();
drop trigger if exists regrade_neg on public.tests;
create trigger regrade_neg after update of neg_marks on public.tests
  for each row when (old.neg_marks is distinct from new.neg_marks) execute function public.regrade_on_change();

revoke execute on function public.grade_attempt(uuid) from public, anon, authenticated;
revoke execute on function public.regrade_on_change() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.start_attempt(uuid, text, uuid) from public, anon;
revoke execute on function public.submit_attempt(uuid, jsonb, jsonb, jsonb, jsonb, uuid) from public, anon;
revoke execute on function public.get_result(uuid, uuid, uuid) from public, anon;
grant execute on function public.start_attempt(uuid, text, uuid) to authenticated;
grant execute on function public.submit_attempt(uuid, jsonb, jsonb, jsonb, jsonb, uuid) to authenticated;
grant execute on function public.get_result(uuid, uuid, uuid) to authenticated;

alter policy attempts_read on public.attempts to authenticated using (student_id = (select auth.uid()) or (select public.is_admin()));
alter policy profiles_read on public.profiles to authenticated using (id = (select auth.uid()) or (select public.is_admin()));
alter policy tests_student on public.tests to authenticated using (published);
