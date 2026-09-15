-- Ejecuta este archivo una sola vez en el SQL Editor de Supabase.
-- Conserva las citas de hoy, ayer y todas las futuras.
-- Elimina por completo las citas confirmadas o canceladas de hace dos días o más.

create extension if not exists pg_cron;

create or replace function public.cleanup_old_appointments()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.appointments
  where appointment_date <= (timezone('Europe/Madrid', now())::date - 2);
$$;

revoke all on function public.cleanup_old_appointments() from public;

select cron.schedule(
  'florido-clean-old-appointments',
  '15 3 * * *',
  'select public.cleanup_old_appointments();'
);

-- Ejecuta también una primera limpieza inmediatamente.
select public.cleanup_old_appointments();
