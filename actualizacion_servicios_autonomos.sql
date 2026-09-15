-- Ejecutar una sola vez en Supabase > SQL Editor.
-- Añade servicios y precios administrables sin borrar citas existentes.

create table if not exists public.florido_services (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(trim(name)) between 2 and 80),
  price_eur numeric(6,2) not null check (price_eur >= 0),
  duration_minutes integer not null default 60 check (duration_minutes between 5 and 240),
  active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now()
);

insert into public.florido_services(name, price_eur, duration_minutes, sort_order)
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

alter table public.florido_services enable row level security;

drop policy if exists "Florido admin manages services" on public.florido_services;
create policy "Florido admin manages services" on public.florido_services
for all to authenticated
using (public.is_florido_admin())
with check (public.is_florido_admin());

grant select, insert, update on public.florido_services to authenticated;

create or replace function public.get_florido_services()
returns table(name text, price_eur numeric, duration_minutes integer)
language sql
stable
security definer
set search_path = public
as $$
  select s.name, s.price_eur, s.duration_minutes
  from public.florido_services s
  where s.active
  order by s.sort_order, s.name;
$$;

revoke all on function public.get_florido_services() from public;
grant execute on function public.get_florido_services() to anon, authenticated;

alter table public.appointments
drop constraint if exists appointments_service_check;

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
declare
  new_id uuid;
  selected_price numeric(6,2);
begin
  if extract(isodow from p_date) not between 1 and 5 then
    raise exception 'La peluquería está cerrada ese día';
  end if;
  if p_time not in ('10:00'::time, '11:00'::time, '12:00'::time, '13:00'::time,
                    '16:00'::time, '17:00'::time, '18:00'::time) then
    raise exception 'Hora no válida';
  end if;
  if (p_date + p_time) <= timezone('Europe/Madrid', now()) then
    raise exception 'La cita debe ser futura';
  end if;

  select s.price_eur into selected_price
  from public.florido_services s
  where s.name = p_service and s.active;
  if selected_price is null then
    raise exception 'Servicio no válido';
  end if;

  insert into public.appointments(
    customer_name, phone, service, appointment_date, appointment_time, price_eur
  ) values (
    trim(p_customer_name), trim(p_phone), p_service, p_date, p_time, selected_price
  ) returning id into new_id;
  return new_id;
exception when unique_violation then
  raise exception 'La hora ya está reservada';
end;
$$;

revoke all on function public.create_booking(text,text,text,date,time) from public;
grant execute on function public.create_booking(text,text,text,date,time) to anon, authenticated;
