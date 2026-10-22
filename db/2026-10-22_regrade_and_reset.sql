-- Pending: run once in Supabase (SQL editor) or approve when Claude applies it.
-- 1) Re-grade attempts when an answer key, marks or negative marking changes.
-- 2) Admin can reset an attempt so she can retake a test.
-- 3) Hardening: internal functions not callable over the API; policies scoped to signed-in users.

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

create or replace function public.submit_attempt(p_test uuid, p_answers jsonb, p_marked jsonb, p_times jsonb, p_flags jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.attempts;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  select * into a from public.attempts where test_id = p_test and student_id = auth.uid();
  if not found then raise exception 'no attempt'; end if;
  if a.submitted_at is null then
    update public.attempts set submitted_at = now(), answers = coalesce(p_answers, '{}'), marked = coalesce(p_marked, '[]'),
      times = coalesce(p_times, '{}'), flags = coalesce(p_flags, '[]')
    where id = a.id;
    perform public.grade_attempt(a.id);
  end if;
  return public.get_result(p_test);
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

create trigger regrade_key after update of correct on public.question_keys
  for each row when (old.correct is distinct from new.correct) execute function public.regrade_on_change();
create trigger regrade_marks after update of marks on public.questions
  for each row when (old.marks is distinct from new.marks) execute function public.regrade_on_change();
create trigger regrade_neg after update of neg_marks on public.tests
  for each row when (old.neg_marks is distinct from new.neg_marks) execute function public.regrade_on_change();

revoke execute on function public.grade_attempt(uuid) from public, anon, authenticated;
revoke execute on function public.regrade_on_change() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;

create policy attempts_admin_delete on public.attempts for delete to authenticated using ((select public.is_admin()));

alter policy attempts_read on public.attempts to authenticated using (student_id = (select auth.uid()) or (select public.is_admin()));
alter policy profiles_read on public.profiles to authenticated using (id = (select auth.uid()) or (select public.is_admin()));
alter policy tests_student on public.tests to authenticated using (published);
