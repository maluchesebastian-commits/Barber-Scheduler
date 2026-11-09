# BARBERÍA QR — Guía de instalación del MVP

Aplicación web para clientes, barberos y un administrador. **No necesita Node.js ni servidor propio**: funciona con GitHub Pages + Supabase.

## 1. Crear un proyecto NUEVO en Supabase

1. En https://supabase.com crea un proyecto nuevo (no uses la base de datos de COFFEE REGISTER).
2. En **SQL Editor**, copia el contenido completo de `supabase/schema.sql` y ejecuta **Run**. Confirma las tablas: `profiles`, `services`, `barber_settings`, `appointments`, `cuts`.
3. En **Project Settings → API / Data API**, copia la **Project URL** y la **publishable key** (`sb_publishable_...`; o `anon` pública si tu proyecto usa la clave antigua).
4. Pega ambos valores en `config.js`. **Nunca coloques la service_role key ni una secret key en este archivo.**
5. En **Authentication → Providers → Email**, habilita el proveedor Email. Decide si requerirás confirmación de correo. Para pruebas puedes desactivarla temporalmente; para uso real se recomienda confirmación.

## 2. Crear administrador

1. Abre `index.html` con **Live Server** de Visual Studio Code o publica primero el sitio.
2. Registra tu cuenta de administrador como un usuario normal.
3. En Supabase → SQL Editor ejecuta, reemplazando el correo:

```sql
UPDATE public.profiles
SET role='admin'
WHERE id=(SELECT id FROM auth.users WHERE email='admin@ejemplo.com');
```

4. Cierra sesión y vuelve a entrar. Aparecerán los módulos de administrador.

**Nota:** nunca se puede elegir el rol administrador desde el formulario público. Solo se asigna desde la base de datos.

## 3. Crear barberos

1. Cada barbero se registra en la aplicación con correo y contraseña, como un cliente.
2. El administrador ingresa a **Barberos → Agregar un barbero**.
3. Selecciona el usuario y el porcentaje convenido: 50/50, 40/60 o 60/40.
4. El barbero vuelve a iniciar sesión y ve su agenda, registro de cortes y su parte económica.

## 4. Publicar en GitHub Pages

1. Crea un repositorio **nuevo** (por ejemplo `barberia-qr`).
2. Sube **el contenido de la carpeta** `Barberia_QR_MVP` a la raíz del repositorio: `index.html`, `app.js`, `styles.css`, `config.js`, `assets/`, `supabase/` y la guía.
3. Ve a **Settings → Pages → Deploy from a branch → main → /(root)** y guarda.
4. El sitio quedará en `https://USUARIO.github.io/barberia-qr/` (usa el nombre real del repositorio).
5. En Supabase → **Authentication → URL Configuration**, establece esa URL completa como **Site URL** y añádela a **Redirect URLs**. Incluye la barra `/` final.
6. Verifica registro, confirmación de correo y acceso desde el enlace público.

## 5. Flujo de prueba recomendado

1. Registra un cliente y verifica que se genera un QR único.
2. Registra un barbero y actívalo desde el panel admin.
3. Entra como cliente, agenda una cita y verifica que aparece en la agenda del barbero.
4. Entra como admin, registra el corte del cliente (QR o búsqueda). Debe aparecer 1/9.
5. Registra 8 cortes adicionales: el contador llegará a 9/9.
6. Registra el siguiente corte: el cliente paga **$0**, el barbero recibe su porcentaje sobre el precio normal y el contador vuelve a 0/9.
7. Registra un particular: no recibe puntos de fidelización.
8. Cambia el porcentaje de un barbero y comprueba que los cortes históricos conservan el porcentaje original.
9. Prueba que un cliente no pueda ver la información privada de otros clientes.

## 6. Reglas de negocio

- Precio inicial: **$20.000 COP**; modificable por el administrador.
- Reparto individual por barbero: **50/50, 40/60, 60/40**, con edición numérica de 0 a 100 si se pacta otro porcentaje.
- Cada corte pagado registrado suma un punto; con 9 puntos, el siguiente es **gratuito**.
- La barbería asume el valor correspondiente al barbero en el corte gratis. En reportes `shop_amount` puede ser negativo: es el costo de fidelización, **no una venta negativa**.
- Los particulares se registran sin puntos.
- Cada corte guarda precio y porcentaje aplicados en el momento del registro.
- Las citas son de lunes a sábado, de 9:00 a 19:00, con 30 minutos mínimos de anticipación y hasta 60 días de antelación. Estos horarios son valores iniciales del MVP; para cambiarlos se debe editar la función SQL `book_appointment` y el selector de horas en `app.js`.
- Los clientes pueden cancelar hasta una hora antes; el personal puede cancelar citas programadas.
- Las atenciones se confirman manualmente. **Escanear un QR no genera automáticamente un corte.**

## 7. Consideraciones antes de producción

- El QR es un **identificador**, no una contraseña: un empleado autorizado debe comprobar que la persona presente corresponde al cliente.
- El sitio necesita Internet para conectarse a Supabase y cargar librerías CDN. La cámara QR requiere HTTPS (GitHub Pages) o localhost.
- El MVP no procesa pagos ni liquida nómina: muestra la distribución por atención y el acumulado.
- No hay pasarela de pagos, facturación electrónica, reprogramación avanzada, calendario de turnos individuales ni exportación a Excel.
- El historial y los resúmenes muestran hasta 300 atenciones recientes, **no son cierres contables oficiales**.
- Antes de registrar datos personales reales, revisar las políticas de privacidad, la normativa colombiana de protección de datos, copias de seguridad, reglas de acceso, y probar todos los roles con cuentas distintas.
- Se recomienda que el administrador haga copias de seguridad periódicas desde Supabase.

## Estructura

```
Barberia_QR_MVP/
├── index.html
├── styles.css
├── app.js
├── config.js
├── assets/
├── supabase/
│   └── schema.sql
└── GUIA_INSTALACION.md
```
