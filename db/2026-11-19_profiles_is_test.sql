-- Test accounts never show in the admin dashboard, results, report, alerts or live strip.
alter table public.profiles add column if not exists is_test boolean not null default false;
update public.profiles set is_test = true where id = '7d392955-8597-45b5-8bdc-cae832e4c308'; -- anupamojhla
