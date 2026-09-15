create extension if not exists pgcrypto;

create table if not exists public.appointments (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null check (char_length(trim(customer_name)) between 2 and 60),
  phone text not null check (char_length(trim(phone)) between 6 and 20),
  service text not null check (service in ('Corte de pelo', 'Corte de pelo y barba')),
  appointment_date date not null,
  appointment_time time not null,
  price_eur numeric(6,2) not null default 15.00,
  status text not null default 'confirmed' check (status in ('confirmed', 'cancelled')),
  created_at timestamptz not null default now()
);

create unique index if not exists appointments_active_slot_unique
on public.appointments (appointment_date, appointment_time)
where status = 'confirmed';

alter table public.appointments enable row level security;

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
  order by schedule.slot_time;
$$;

create or replace function public.create_booking(
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
declare new_id uuid;
begin
  if extract(isodow from p_date) not between 1 and 5 then
    raise exception 'La peluquería está cerrada ese día';
  end if;
  if p_time not in ('10:00'::time, '11:00'::time, '12:00'::time, '13:00'::time, '16:00'::time, '17:00'::time, '18:00'::time) then
    raise exception 'Hora no válida';
  end if;
  if (p_date + p_time) <= timezone('Europe/Madrid', now()) then
    raise exception 'La cita debe ser futura';
  end if;
  if p_service not in ('Corte de pelo', 'Corte de pelo y barba') then
    raise exception 'Servicio no válido';
  end if;
  insert into public.appointments(customer_name, phone, service, appointment_date, appointment_time)
  values (trim(p_customer_name), trim(p_phone), p_service, p_date, p_time)
  returning id into new_id;
  return new_id;
exception when unique_violation then
  raise exception 'La hora ya está reservada';
end;
$$;

revoke all on public.appointments from anon, authenticated;
revoke all on function public.get_available_slots(date) from public;
revoke all on function public.create_booking(text,text,text,date,time) from public;
grant execute on function public.get_available_slots(date) to anon, authenticated;
grant execute on function public.create_booking(text,text,text,date,time) to anon, authenticated;
