-- Results and progress now also return where each question comes from (NCERT chapter + page).
-- Additive keys only: older clients ignore them. Applied 18 Nov 2026 as migration results_return_source.
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
        'correct', k.correct, 'solution', k.solution, 'concept', k.concept, 'formula', k.formula,
        'source_chapter', q.source_chapter, 'source_page', q.source_page, 'difficulty', q.difficulty,
        'chosen', a.answers -> q.id::text))
      from public.attempts a
      join public.test_questions tq on tq.test_id = a.test_id
      join public.questions q on q.id = tq.question_id
      join public.question_keys k on k.question_id = q.id
      where a.student_id = sid and a.submitted_at is not null and not a.flags @> '[{"type":"abandoned"}]'), '[]'::jsonb));
end $$;

create or replace function public.get_result(p_test uuid, p_student uuid default null, p_attempt uuid default null) returns jsonb
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
                                          'position',tq.position,'correct',k.correct,'solution',k.solution,'concept',k.concept,'formula',k.formula,
                                          'source_chapter',q.source_chapter,'source_page',q.source_page,'difficulty',q.difficulty)
                       order by tq.position)
      from public.test_questions tq
      join public.questions q on q.id = tq.question_id
      join public.question_keys k on k.question_id = q.id
      where tq.test_id = p_test));
end $$;
