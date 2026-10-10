-- 1. Visit admin.html and create your account (or Supabase > Authentication > Users).
-- 2. Confirm your email if required.
-- 3. REPLACE the email below with your exact authenticated staff account email.
-- 4. Run this SQL in Supabase SQL Editor. Never run it with a stranger's email.

do $$
begin
  if not exists (select 1 from auth.users where lower(email)=lower('REPLACE_WITH_YOUR_EMAIL@example.com')) then
    raise exception 'No Auth user with this email. Create and confirm the account first.';
  end if;
end $$;

insert into public.staff_users (user_id,role)
select id,'admin' from auth.users where lower(email)=lower('REPLACE_WITH_YOUR_EMAIL@example.com')
on conflict (user_id) do update set role='admin';

select s.user_id,u.email,s.role from public.staff_users s join auth.users u on s.user_id=u.id;
