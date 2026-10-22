-- Test window (end_at) and OMR minutes at the end of the paper.
-- end_at null = no closing time. She must start by end_at - duration so she can finish inside the window.

alter table public.tests add column if not exists end_at timestamptz;
alter table public.tests add column if not exists omr_min int not null default 10 check (omr_min between 0 and 60);
alter table public.tests drop constraint if exists tests_window_ok;
alter table public.tests add constraint tests_window_ok check (end_at is null or end_at >= start_at + make_interval(mins => duration_min));

-- get_paper sends the whole test row (no secrets live on tests), so new settings reach the tablet without another change here
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
    'test', to_jsonb(t) || jsonb_build_object('attempts_used',
      (select count(*) from public.attempts where test_id = p_test and student_id = auth.uid() and submitted_at is not null)),
    'questions', coalesce((
      select jsonb_agg(jsonb_build_object('id',q.id,'subject',q.subject,'chapter',q.chapter,'body',q.body,
                                          'options',q.options,'image_url',q.image_url,'marks',q.marks,'position',tq.position)
                       order by tq.position)
      from public.test_questions tq join public.questions q on q.id = tq.question_id
      where tq.test_id = p_test), '[]'::jsonb));
end $$;

create or replace function public.start_attempt(p_test uuid, p_strategy text, p_id uuid default null) returns public.attempts
language plpgsql security definer set search_path = public as $$
declare t public.tests; a public.attempts; n int;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  select * into a from public.attempts where test_id = p_test and student_id = auth.uid() and (id = p_id or submitted_at is null)
    order by (id = p_id) desc nulls last limit 1;
  if found then return a; end if;
  select * into t from public.tests where id = p_test and published;
  if not found then raise exception 'test not found'; end if;
  if now() < t.start_at then raise exception 'test has not started'; end if;
  -- 2 min grace for a tablet clock that runs slow
  if t.end_at is not null and now() > t.end_at - make_interval(mins => t.duration_min) + interval '2 minutes' then
    raise exception 'The window for this test has closed'; end if;
  if not (p_strategy = any (t.strategies)) then raise exception 'strategy not allowed'; end if;
  select count(*) into n from public.attempts where test_id = p_test and student_id = auth.uid();
  if n >= t.max_attempts then raise exception 'All % attempts used', t.max_attempts; end if;
  insert into public.attempts (id, test_id, student_id, strategy, attempt_no)
  values (coalesce(p_id, gen_random_uuid()), p_test, auth.uid(), p_strategy, n + 1) returning * into a;
  return a;
end $$;
