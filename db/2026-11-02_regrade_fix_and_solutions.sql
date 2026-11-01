-- 2 Nov 2026
-- question_keys: structured solution parts shown under "Show answer" in the review screen.
alter table public.question_keys add column if not exists concept text, add column if not exists formula text;
-- get_result / get_progress now also return k.concept and k.formula (applied as migration structured_solutions).

-- Answer-key changes always failed: the shared trigger read new.id, which question_keys does not have.
create or replace function public.regrade_on_change() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare t uuid[];
begin
  if tg_table_name = 'question_keys' then
    t := array(select test_id from public.test_questions where question_id = new.question_id);
  elsif tg_table_name = 'questions' then
    t := array(select test_id from public.test_questions where question_id = new.id);
  else
    t := array[new.id];
  end if;
  perform public.grade_attempt(a.id) from public.attempts a where a.submitted_at is not null and a.test_id = any (t);
  return null;
end $$;
