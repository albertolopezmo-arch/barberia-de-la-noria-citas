create table if not exists public.admin_users (
  email text primary key,
  created_at timestamptz not null default now()
);

alter table public.admin_users enable row level security;

create or replace function public.is_florido_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.admin_users
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

revoke all on function public.is_florido_admin() from public;
grant execute on function public.is_florido_admin() to authenticated;

create table if not exists public.blocked_slots (
  id uuid primary key default gen_random_uuid(),
  block_date date not null,
  block_time time,
  reason text check (reason is null or char_length(reason) <= 80),
  created_at timestamptz not null default now()
);

create unique index if not exists blocked_full_day_unique
on public.blocked_slots(block_date) where block_time is null;

create unique index if not exists blocked_time_unique
on public.blocked_slots(block_date, block_time) where block_time is not null;

alter table public.blocked_slots enable row level security;

drop policy if exists "Florido admin reads appointments" on public.appointments;
create policy "Florido admin reads appointments" on public.appointments
for select to authenticated using (public.is_florido_admin());

drop policy if exists "Florido admin updates appointments" on public.appointments;
create policy "Florido admin updates appointments" on public.appointments
for update to authenticated using (public.is_florido_admin()) with check (public.is_florido_admin());

drop policy if exists "Florido admin creates appointments" on public.appointments;
create policy "Florido admin creates appointments" on public.appointments
for insert to authenticated with check (public.is_florido_admin());

drop policy if exists "Florido admin manages blocks" on public.blocked_slots;
create policy "Florido admin manages blocks" on public.blocked_slots
for all to authenticated using (public.is_florido_admin()) with check (public.is_florido_admin());

grant select, insert, update on public.appointments to authenticated;
grant select, insert, delete on public.blocked_slots to authenticated;

create or replace function public.prevent_booking_on_blocked_slot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'confirmed' and exists (
    select 1 from public.blocked_slots b
    where b.block_date = new.appointment_date
      and (b.block_time is null or b.block_time = new.appointment_time)
  ) then
    raise exception 'La agenda está bloqueada para ese día u hora';
  end if;
  return new;
end;
$$;

drop trigger if exists prevent_booking_on_blocked_slot on public.appointments;
create trigger prevent_booking_on_blocked_slot
before insert or update of appointment_date, appointment_time, status
on public.appointments
for each row execute function public.prevent_booking_on_blocked_slot();

create or replace function public.get_available_slots(p_date date)
returns table(slot_time time)
language sql
security definer
set search_path = public
as $$
  with schedule(slot_time) as (
    values ('10:00'::time), ('11:00'::time), ('12:00'::time), ('13:00'::time),
           ('16:00'::time), ('17:00'::time), ('18:00'::time)
  )
  select schedule.slot_time
  from schedule
  where extract(isodow from p_date) between 1 and 5
    and (p_date + schedule.slot_time) > timezone('Europe/Madrid', now())
    and not exists (
      select 1 from public.appointments a
      where a.appointment_date = p_date
        and a.appointment_time = schedule.slot_time
        and a.status = 'confirmed'
    )
    and not exists (
      select 1 from public.blocked_slots b
      where b.block_date = p_date
        and (b.block_time is null or b.block_time = schedule.slot_time)
    )
  order by schedule.slot_time;
$$;

revoke all on function public.get_available_slots(date) from public;
grant execute on function public.get_available_slots(date) to anon, authenticated;

create or replace function public.get_blocked_days(p_start date, p_end date)
returns table(block_date date)
language sql
security definer
set search_path = public
as $$
  select b.block_date
  from public.blocked_slots b
  where b.block_time is null
    and b.block_date between p_start and p_end
  order by b.block_date;
$$;

revoke all on function public.get_blocked_days(date, date) from public;
grant execute on function public.get_blocked_days(date, date) to anon, authenticated;

-- DESPUÉS de crear el usuario en Authentication, ejecuta una sola vez:
-- insert into public.admin_users(email)
-- values ('correo-del-peluquero@ejemplo.com')
-- on conflict (email) do nothing;
