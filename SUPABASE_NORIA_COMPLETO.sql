-- LA BARBERÍA DE LA NORIA
-- Ejecutar una sola vez en el SQL Editor del mismo proyecto Supabase de Florido Style.
-- Todas las tablas y funciones usan nombres propios y no modifican los datos de Florido.

create extension if not exists pgcrypto;

create table if not exists public.noria_admin_users (
  email text primary key,
  created_at timestamptz not null default now()
);

create table if not exists public.noria_services (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(trim(name)) between 2 and 80),
  price_eur numeric(6,2) not null check (price_eur >= 0),
  duration_minutes integer not null default 60 check (duration_minutes between 5 and 240),
  active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now()
);

create table if not exists public.noria_appointments (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null check (char_length(trim(customer_name)) between 2 and 60),
  phone text not null check (char_length(trim(phone)) between 6 and 20),
  service text not null,
  appointment_date date not null,
  appointment_time time not null,
  price_eur numeric(6,2) not null,
  status text not null default 'confirmed' check (status in ('confirmed', 'cancelled')),
  created_at timestamptz not null default now()
);

create unique index if not exists noria_appointments_active_slot_unique
on public.noria_appointments (appointment_date, appointment_time)
where status = 'confirmed';

create table if not exists public.noria_blocked_slots (
  id uuid primary key default gen_random_uuid(),
  block_date date not null,
  block_time time,
  reason text check (reason is null or char_length(reason) <= 80),
  created_at timestamptz not null default now()
);

create unique index if not exists noria_blocked_full_day_unique
on public.noria_blocked_slots(block_date) where block_time is null;

create unique index if not exists noria_blocked_time_unique
on public.noria_blocked_slots(block_date, block_time) where block_time is not null;

insert into public.noria_services(name, price_eur, duration_minutes, sort_order)
values
  ('Todos los cortes de pelo', 8, 60, 10),
  ('Corte y barba', 12, 60, 20),
  ('Decoloración (desde)', 29.99, 60, 30),
  ('Color: pelo y barba', 15, 60, 40),
  ('Tinte color pelo', 12, 60, 50),
  ('Permanente rizada', 40, 60, 60),
  ('Afeitado de barba', 5, 60, 70),
  ('Manicura masculina', 12, 60, 80),
  ('Pedicura masculina', 15, 60, 90),
  ('Masajes corporales', 25, 40, 100),
  ('Limpieza facial', 20, 60, 110),
  ('Dermapen', 30, 60, 120)
on conflict (name) do nothing;

alter table public.noria_admin_users enable row level security;
alter table public.noria_services enable row level security;
alter table public.noria_appointments enable row level security;
alter table public.noria_blocked_slots enable row level security;

create or replace function public.is_noria_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.noria_admin_users
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

revoke all on function public.is_noria_admin() from public;
grant execute on function public.is_noria_admin() to authenticated;

drop policy if exists "Noria admin manages services" on public.noria_services;
create policy "Noria admin manages services" on public.noria_services
for all to authenticated
using (public.is_noria_admin())
with check (public.is_noria_admin());

drop policy if exists "Noria admin reads appointments" on public.noria_appointments;
create policy "Noria admin reads appointments" on public.noria_appointments
for select to authenticated using (public.is_noria_admin());

drop policy if exists "Noria admin creates appointments" on public.noria_appointments;
create policy "Noria admin creates appointments" on public.noria_appointments
for insert to authenticated with check (public.is_noria_admin());

drop policy if exists "Noria admin updates appointments" on public.noria_appointments;
create policy "Noria admin updates appointments" on public.noria_appointments
for update to authenticated
using (public.is_noria_admin()) with check (public.is_noria_admin());

drop policy if exists "Noria admin manages blocks" on public.noria_blocked_slots;
create policy "Noria admin manages blocks" on public.noria_blocked_slots
for all to authenticated
using (public.is_noria_admin())
with check (public.is_noria_admin());

revoke all on public.noria_admin_users from anon, authenticated;
revoke all on public.noria_services from anon, authenticated;
revoke all on public.noria_appointments from anon, authenticated;
revoke all on public.noria_blocked_slots from anon, authenticated;
grant select, insert, update on public.noria_services to authenticated;
grant select, insert, update on public.noria_appointments to authenticated;
grant select, insert, delete on public.noria_blocked_slots to authenticated;

create or replace function public.get_noria_services()
returns table(name text, price_eur numeric, duration_minutes integer)
language sql
stable
security definer
set search_path = public
as $$
  select s.name, s.price_eur, s.duration_minutes
  from public.noria_services s
  where s.active
  order by s.sort_order, s.name;
$$;

create or replace function public.get_noria_available_slots(p_date date)
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
      select 1 from public.noria_appointments a
      where a.appointment_date = p_date
        and a.appointment_time = schedule.slot_time
        and a.status = 'confirmed'
    )
    and not exists (
      select 1 from public.noria_blocked_slots b
      where b.block_date = p_date
        and (b.block_time is null or b.block_time = schedule.slot_time)
    )
  order by schedule.slot_time;
$$;

create or replace function public.get_noria_blocked_days(p_start date, p_end date)
returns table(block_date date)
language sql
security definer
set search_path = public
as $$
  select b.block_date
  from public.noria_blocked_slots b
  where b.block_time is null
    and b.block_date between p_start and p_end
  order by b.block_date;
$$;

create or replace function public.create_noria_booking(
  p_customer_name text,
  p_phone text,
  p_service text,
  p_date date,
  p_time time
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid;
  selected_price numeric(6,2);
begin
  if extract(isodow from p_date) not between 1 and 5 then
    raise exception 'La barbería está cerrada ese día';
  end if;
  if p_time not in ('10:00'::time, '11:00'::time, '12:00'::time, '13:00'::time,
                    '16:00'::time, '17:00'::time, '18:00'::time) then
    raise exception 'Hora no válida';
  end if;
  if (p_date + p_time) <= timezone('Europe/Madrid', now()) then
    raise exception 'La cita debe ser futura';
  end if;
  if exists (
    select 1 from public.noria_blocked_slots b
    where b.block_date = p_date
      and (b.block_time is null or b.block_time = p_time)
  ) then
    raise exception 'La agenda está bloqueada para ese día u hora';
  end if;

  select s.price_eur into selected_price
  from public.noria_services s
  where s.name = p_service and s.active;
  if selected_price is null then raise exception 'Servicio no válido'; end if;

  insert into public.noria_appointments(
    customer_name, phone, service, appointment_date, appointment_time, price_eur
  ) values (
    trim(p_customer_name), trim(p_phone), p_service, p_date, p_time, selected_price
  ) returning id into new_id;
  return new_id;
exception when unique_violation then
  raise exception 'La hora ya está reservada';
end;
$$;

create or replace function public.prevent_noria_booking_on_blocked_slot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'confirmed' and exists (
    select 1 from public.noria_blocked_slots b
    where b.block_date = new.appointment_date
      and (b.block_time is null or b.block_time = new.appointment_time)
  ) then
    raise exception 'La agenda está bloqueada para ese día u hora';
  end if;
  return new;
end;
$$;

drop trigger if exists prevent_noria_booking_on_blocked_slot on public.noria_appointments;
create trigger prevent_noria_booking_on_blocked_slot
before insert or update of appointment_date, appointment_time, status
on public.noria_appointments
for each row execute function public.prevent_noria_booking_on_blocked_slot();

revoke all on function public.get_noria_services() from public;
revoke all on function public.get_noria_available_slots(date) from public;
revoke all on function public.get_noria_blocked_days(date,date) from public;
revoke all on function public.create_noria_booking(text,text,text,date,time) from public;
grant execute on function public.get_noria_services() to anon, authenticated;
grant execute on function public.get_noria_available_slots(date) to anon, authenticated;
grant execute on function public.get_noria_blocked_days(date,date) to anon, authenticated;
grant execute on function public.create_noria_booking(text,text,text,date,time) to anon, authenticated;

-- ÚLTIMO PASO, después de crear el usuario en Authentication > Users:
-- insert into public.noria_admin_users(email)
-- values ('correo-de-la-profesional@ejemplo.com')
-- on conflict (email) do nothing;
