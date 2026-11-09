-- BARBERÍA QR · esquema inicial para proyecto Supabase NUEVO.
-- Ejecutar una sola vez en SQL Editor. Zona horaria de visualización: America/Bogota.
create extension if not exists pgcrypto;

create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null default '', phone text not null default '',
 role text not null default 'customer' check(role in ('customer','barber','admin')),
 loyalty_paid_count integer not null default 0 check(loyalty_paid_count between 0 and 9),
 qr_token uuid not null unique default gen_random_uuid(),
 active boolean not null default true,
 created_at timestamptz not null default now()
);
create table public.services (
 id bigint generated always as identity primary key,
 name text not null, price numeric(12,2) not null check(price>=0),
 duration_minutes integer not null default 30 check(duration_minutes between 15 and 240),
 active boolean not null default true
);
insert into public.services(name,price,duration_minutes) values ('Corte de cabello',20000,30);
create table public.barber_settings (
 barber_id uuid primary key references public.profiles(id) on delete cascade,
 barber_percentage integer not null default 50 check(barber_percentage between 0 and 100),
 active boolean not null default true,
 updated_at timestamptz not null default now()
);
create table public.appointments (
 id bigint generated always as identity primary key,
 customer_id uuid not null references public.profiles(id),
 barber_id uuid not null references public.profiles(id),
 service_id bigint not null references public.services(id),
 starts_at timestamptz not null,
 ends_at timestamptz not null,
 status text not null default 'scheduled' check(status in ('scheduled','cancelled','completed')),
 created_at timestamptz not null default now(),
 constraint appointment_positive_duration check(ends_at>starts_at)
);
create index appointments_barber_time_idx on public.appointments(barber_id,starts_at);
create table public.cuts (
 id bigint generated always as identity primary key,
 customer_id uuid references public.profiles(id),
 guest_name text,
 barber_id uuid not null references public.profiles(id),
 service_id bigint not null references public.services(id),
 appointment_id bigint unique references public.appointments(id),
 kind text not null check(kind in ('paid','free','guest')),
 price_snapshot numeric(12,2) not null,
 customer_paid numeric(12,2) not null,
 barber_percentage integer not null,
 barber_amount numeric(12,2) not null,
 shop_amount numeric(12,2) not null,
 loyalty_progress_after integer,
 recorded_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now(),
 constraint cut_customer_or_guest check ((kind='guest' and customer_id is null) or (kind<>'guest' and customer_id is not null))
);
create index cuts_created_at_idx on public.cuts(created_at desc);
create index cuts_customer_idx on public.cuts(customer_id,created_at desc);
create index cuts_barber_idx on public.cuts(barber_id,created_at desc);

-- Privilegios mínimos: las operaciones sensibles se ejecutan por RPC.
revoke all on public.profiles,public.services,public.barber_settings,public.appointments,public.cuts from anon;
grant select on public.services to authenticated;
grant select on public.profiles,public.barber_settings,public.appointments,public.cuts to authenticated;
grant update(full_name,phone) on public.profiles to authenticated;
grant insert on public.appointments to authenticated;
grant update(status) on public.appointments to authenticated;
grant update(barber_percentage,active) on public.barber_settings to authenticated;
grant update(active,price,duration_minutes,name) on public.services to authenticated;
grant insert on public.services to authenticated;
grant usage,select on sequence public.services_id_seq to authenticated;
grant usage,select on sequence public.appointments_id_seq to authenticated;

create or replace function public.current_role() returns text
language sql stable security definer set search_path = '' as $$
 select coalesce((select role from public.profiles where id=auth.uid() and active), 'none')
$$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
 select public.current_role()='admin'
$$;
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
 select public.current_role() in ('admin','barber')
$$;
revoke all on function public.current_role(),public.is_admin(),public.is_staff() from public;
grant execute on function public.current_role(),public.is_admin(),public.is_staff() to authenticated;

create or replace function public.create_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 insert into public.profiles(id,full_name,phone,role)
 values(new.id,coalesce(nullif(left(new.raw_user_meta_data->>'full_name',120),''),'Cliente'),coalesce(left(new.raw_user_meta_data->>'phone',30),''),'customer');
 return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.create_profile();

create or replace function public.sync_barber_settings() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.role='barber' then
  insert into public.barber_settings(barber_id) values(new.id) on conflict do nothing;
 end if;
 return new;
end $$;
create trigger on_profile_role_change after insert or update of role on public.profiles
for each row execute function public.sync_barber_settings();

alter table public.profiles enable row level security;
alter table public.services enable row level security;
alter table public.barber_settings enable row level security;
alter table public.appointments enable row level security;
alter table public.cuts enable row level security;

create policy profiles_read on public.profiles for select to authenticated using (
 id=auth.uid() or public.is_admin() or (public.current_role()='barber' and exists (
 select 1 from public.appointments a where a.customer_id=profiles.id and a.barber_id=auth.uid()
 ))
);
create policy profiles_edit_self on public.profiles for update to authenticated
 using(id=auth.uid()) with check(id=auth.uid());
-- Solo se conceden UPDATE de nombre/teléfono por columna: no permite alterar rol ni puntos.
create policy services_read on public.services for select to authenticated using (active or public.is_staff());
create policy services_admin_insert on public.services for insert to authenticated with check(public.is_admin());
create policy services_admin_update on public.services for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy barber_settings_read on public.barber_settings for select to authenticated using(
 active or public.is_admin() or barber_id=auth.uid()
);
create policy barber_settings_admin_update on public.barber_settings for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy appointments_read on public.appointments for select to authenticated using(
 customer_id=auth.uid() or barber_id=auth.uid() or public.is_admin()
);
-- Inserciones y cambios de estado se hacen únicamente mediante RPC con bloqueo y validaciones.
create policy cuts_read on public.cuts for select to authenticated using(
 customer_id=auth.uid() or barber_id=auth.uid() or public.is_admin()
);

-- No se permite al cliente consultar citas ajenas, pero sí ver horarios ocupados sin datos personales.
create or replace function public.busy_slots(p_barber uuid,p_day date)
returns table(starts_at timestamptz,ends_at timestamptz)
language sql stable security definer set search_path = '' as $$
 select a.starts_at,a.ends_at from public.appointments a
 where auth.uid() is not null and a.barber_id=p_barber and a.status='scheduled'
 and a.starts_at >= (p_day::timestamp at time zone 'America/Bogota')
 and a.starts_at < ((p_day+1)::timestamp at time zone 'America/Bogota')
 and exists(select 1 from public.barber_settings b where b.barber_id=p_barber and b.active)
$$;

create or replace function public.book_appointment(p_barber uuid,p_service bigint,p_start timestamptz)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_duration integer; v_end timestamptz; v_id bigint; v_local timestamp;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and active) then raise exception 'Debes iniciar sesión'; end if;
 if not exists(select 1 from public.barber_settings where barber_id=p_barber and active) then raise exception 'Barbero no disponible'; end if;
 select duration_minutes into v_duration from public.services where id=p_service and active;
 if v_duration is null then raise exception 'Servicio no disponible'; end if;
 if p_start < now()+interval '30 minutes' or p_start>now()+interval '60 days' then raise exception 'La cita debe ser entre 30 minutos y 60 días en el futuro'; end if;
 v_end:=p_start+make_interval(mins=>v_duration);
 v_local:=p_start at time zone 'America/Bogota';
 if extract(isodow from v_local)=7 or v_local::time < time '09:00' or (v_end at time zone 'America/Bogota')::time > time '19:00' or (v_end at time zone 'America/Bogota')::date<>v_local::date then
  raise exception 'Horario de atención: lunes a sábado, 9:00 a 19:00';
 end if;
 perform pg_advisory_xact_lock(hashtext(p_barber::text));
 if exists(select 1 from public.appointments a where a.barber_id=p_barber and a.status='scheduled' and a.starts_at<v_end and a.ends_at>p_start) then
  raise exception 'Horario ocupado. Elige otra hora';
 end if;
 insert into public.appointments(customer_id,barber_id,service_id,starts_at,ends_at)
 values(auth.uid(),p_barber,p_service,p_start,v_end) returning id into v_id;
 return v_id;
end $$;

create or replace function public.cancel_appointment(p_appointment bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare v public.appointments%rowtype;
begin
 select * into v from public.appointments where id=p_appointment for update;
 if not found or v.status<>'scheduled' then raise exception 'Cita no disponible'; end if;
 if not (public.is_admin() or v.barber_id=auth.uid() or (v.customer_id=auth.uid() and v.starts_at>now()+interval '1 hour')) then
  raise exception 'No autorizado: el cliente cancela hasta 1 hora antes';
 end if;
 update public.appointments set status='cancelled' where id=p_appointment;
end $$;

create or replace function public.record_cut(
 p_barber uuid,p_service bigint,p_customer uuid default null,
 p_guest_name text default null,p_appointment bigint default null
) returns bigint language plpgsql security definer set search_path = '' as $$
declare v_price numeric(12,2); v_pct integer; v_kind text; v_count integer;
 v_paid numeric(12,2);v_barber numeric(12,2);v_shop numeric(12,2);v_id bigint;
 v_appt public.appointments%rowtype;
begin
 if not public.is_staff() then raise exception 'Solo el personal registra cortes'; end if;
 if public.current_role()='barber' and p_barber<>auth.uid() then raise exception 'Solo puedes registrar tus propias atenciones'; end if;
 if not exists(select 1 from public.profiles where id=p_barber and role='barber' and active) then raise exception 'Barbero no válido'; end if;
 select barber_percentage into v_pct from public.barber_settings where barber_id=p_barber and active;
 if v_pct is null then raise exception 'Barbero inactivo'; end if;
 select price into v_price from public.services where id=p_service and active;
 if v_price is null then raise exception 'Servicio no disponible'; end if;
 if p_appointment is not null then
  select * into v_appt from public.appointments where id=p_appointment for update;
  if not found or v_appt.status<>'scheduled' or v_appt.barber_id<>p_barber or v_appt.service_id<>p_service or v_appt.customer_id is distinct from p_customer then
   raise exception 'La cita no corresponde a esta atención';
  end if;
  if v_appt.starts_at>now()+interval '1 hour' then raise exception 'No se puede finalizar una cita futura'; end if;
 end if;
 if p_customer is null then
  if p_appointment is not null then raise exception 'Una cita registrada requiere cliente'; end if;
  v_kind:='guest';v_count:=null;
 else
  select loyalty_paid_count into v_count from public.profiles where id=p_customer and role='customer' and active for update;
  if not found then raise exception 'Cliente no encontrado o inactivo'; end if;
  if v_count=9 then v_kind:='free';v_count:=0;
  else v_kind:='paid';v_count:=v_count+1; end if;
  update public.profiles set loyalty_paid_count=v_count where id=p_customer;
 end if;
 v_paid:=case when v_kind='free' then 0 else v_price end;
 v_barber:=round(v_price*v_pct/100,2);
 v_shop:=v_paid-v_barber;
 insert into public.cuts(customer_id,guest_name,barber_id,service_id,appointment_id,kind,
  price_snapshot,customer_paid,barber_percentage,barber_amount,shop_amount,loyalty_progress_after,recorded_by)
 values(p_customer,case when p_customer is null then coalesce(nullif(left(trim(p_guest_name),120),''),'Particular') else null end,
 p_barber,p_service,p_appointment,v_kind,v_price,v_paid,v_pct,v_barber,v_shop,v_count,auth.uid()) returning id into v_id;
 if p_appointment is not null then update public.appointments set status='completed' where id=p_appointment; end if;
 return v_id;
end $$;

-- Administrador: consultar clientes por token QR sin exponer la tabla completa al cliente.
create or replace function public.lookup_qr(p_token uuid)
returns table(id uuid,full_name text,phone text,loyalty_paid_count integer)
language plpgsql stable security definer set search_path = '' as $$
begin
 if not public.is_staff() then raise exception 'No autorizado'; end if;
 return query select p.id,p.full_name,p.phone,p.loyalty_paid_count from public.profiles p
 where p.qr_token=p_token and p.role='customer' and p.active;
end $$;

-- Solo admin puede convertir un cliente registrado en barbero.
create or replace function public.promote_barber(p_user uuid,p_percentage integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if not public.is_admin() then raise exception 'No autorizado'; end if;
 if p_percentage<0 or p_percentage>100 then raise exception 'Porcentaje inválido'; end if;
 update public.profiles set role='barber' where id=p_user and role='customer';
 if not found then raise exception 'No existe cliente elegible'; end if;
 insert into public.barber_settings(barber_id,barber_percentage,active)
 values(p_user,p_percentage,true)
 on conflict(barber_id) do update set barber_percentage=excluded.barber_percentage,active=true;
end $$;

revoke all on function public.busy_slots(uuid,date),public.book_appointment(uuid,bigint,timestamptz),public.cancel_appointment(bigint),public.record_cut(uuid,bigint,uuid,text,bigint),public.lookup_qr(uuid),public.promote_barber(uuid,integer) from public;
grant execute on function public.busy_slots(uuid,date),public.book_appointment(uuid,bigint,timestamptz),public.cancel_appointment(bigint),public.record_cut(uuid,bigint,uuid,text,bigint),public.lookup_qr(uuid),public.promote_barber(uuid,integer) to authenticated;

-- PASO MANUAL tras registrar la cuenta principal desde la web:
-- UPDATE public.profiles SET role='admin' WHERE id=(SELECT id FROM auth.users WHERE email='TU_CORREO_ADMIN');
-- NO introducir claves secretas en el frontend.

create or replace function public.available_barbers()
returns table(id uuid,full_name text,barber_percentage integer)
language sql stable security definer set search_path = '' as $$
 select p.id,p.full_name,b.barber_percentage
 from public.profiles p join public.barber_settings b on b.barber_id=p.id
 where auth.uid() is not null and p.role='barber' and p.active and b.active
 order by p.full_name
$$;
revoke all on function public.available_barbers() from public;
grant execute on function public.available_barbers() to authenticated;

-- El personal puede agendar citas para clientes registrados.
create or replace function public.staff_book_appointment(p_customer uuid,p_barber uuid,p_service bigint,p_start timestamptz)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_duration integer; v_end timestamptz; v_id bigint; v_local timestamp;
begin
 if not public.is_staff() then raise exception 'Solo el personal puede agendar para terceros'; end if;
 if public.current_role()='barber' and p_barber<>auth.uid() then raise exception 'Solo puedes agendar en tu propia agenda'; end if;
 if not exists(select 1 from public.profiles where id=p_customer and role='customer' and active) then raise exception 'Cliente no válido'; end if;
 if not exists(select 1 from public.barber_settings where barber_id=p_barber and active) then raise exception 'Barbero no disponible'; end if;
 select duration_minutes into v_duration from public.services where id=p_service and active;
 if v_duration is null then raise exception 'Servicio no disponible'; end if;
 if p_start < now()+interval '30 minutes' or p_start>now()+interval '60 days' then raise exception 'Fecha fuera de rango'; end if;
 v_end:=p_start+make_interval(mins=>v_duration);
 v_local:=p_start at time zone 'America/Bogota';
 if extract(isodow from v_local)=7 or v_local::time<time '09:00' or (v_end at time zone 'America/Bogota')::time>time '19:00' or (v_end at time zone 'America/Bogota')::date<>v_local::date then raise exception 'Horario: lunes a sábado de 9:00 a 19:00'; end if;
 perform pg_advisory_xact_lock(hashtext(p_barber::text));
 if exists(select 1 from public.appointments where barber_id=p_barber and status='scheduled' and starts_at<v_end and ends_at>p_start) then raise exception 'Horario ocupado'; end if;
 insert into public.appointments(customer_id,barber_id,service_id,starts_at,ends_at) values(p_customer,p_barber,p_service,p_start,v_end) returning id into v_id;
 return v_id;
end $$;

create or replace function public.staff_find_customers(p_search text)
returns table(id uuid,full_name text,loyalty_paid_count integer)
language plpgsql stable security definer set search_path = '' as $$
begin
 if not public.is_staff() then raise exception 'No autorizado'; end if;
 if length(trim(coalesce(p_search,'')))<2 then return; end if;
 return query select p.id,p.full_name,p.loyalty_paid_count from public.profiles p
 where p.role='customer' and p.active and p.full_name ilike '%'||replace(replace(trim(p_search),'%',''),'_','')||'%'
 order by p.full_name limit 30;
end $$;
revoke all on function public.staff_book_appointment(uuid,uuid,bigint,timestamptz),public.staff_find_customers(text) from public;
grant execute on function public.staff_book_appointment(uuid,uuid,bigint,timestamptz),public.staff_find_customers(text) to authenticated;
