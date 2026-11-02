-- Questions on hold: figures we could not open and keys under doubt. Admin test picker hides them.
alter table public.questions add column if not exists hold boolean not null default false;
-- Release later: update questions set hold=false where id in (...);
