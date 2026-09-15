# Florido Style · Reservas

Web de reservas para GitHub Pages.

## Activación

1. Crea un proyecto gratuito en Supabase.
2. Abre **SQL Editor**, pega el contenido de `supabase.sql` y ejecútalo una vez.
3. La URL y la clave pública de Supabase ya están configuradas en `config.js`.
4. En **Settings → Pages**, selecciona **GitHub Actions** como origen.

La clave incluida es la clave pública `publishable`, diseñada por Supabase para utilizarse en aplicaciones web. No incluyas nunca una clave `secret` o `service_role`.

## Panel del peluquero

1. Ejecuta `admin_setup.sql` en el SQL Editor de Supabase.
2. En Supabase abre **Authentication > Users > Add user** y crea el usuario del peluquero con correo y contraseña.
3. Ejecuta en el SQL Editor, sustituyendo el correo:

```sql
insert into public.admin_users(email)
values ('correo-del-peluquero@ejemplo.com')
on conflict (email) do nothing;
```

4. Entra en `admin.html` desde el enlace **Acceso profesional** del pie de página.

Desde el panel se pueden ver las citas del día o de otra fecha, añadir citas manuales, cancelar citas, bloquear una hora, cerrar un día completo y volver a abrir los bloqueos. En una cita manual el teléfono es opcional.

## Limpieza automática de citas

Ejecuta una sola vez `cleanup_old_appointments.sql` en el SQL Editor de Supabase. La tarea conserva las citas de hoy, ayer y las futuras, y elimina diariamente las filas completas de citas de hace dos días o más.

## Panel privado

El panel del peluquero está en `admin.html`. Para activarlo:

1. Ejecuta `admin_setup.sql` en el SQL Editor del proyecto Florido Style.
2. En Supabase abre **Authentication → Users → Add user** y crea el usuario del peluquero con correo y contraseña.
3. Ejecuta la última instrucción comentada de `admin_setup.sql`, sustituyendo el correo de ejemplo por el correo creado.
