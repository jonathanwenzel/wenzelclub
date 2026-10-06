-- =====================================================================
--  WENZEL CLUB · BIERTASTING · Datenbank v1.0 (Stand 07.10.2026)
--  Einmal komplett in Supabase → SQL Editor einfügen und „Run“ drücken.
--  Das Skript darf auch mehrfach ausgeführt werden (Funktionen werden
--  ersetzt, vorhandene Daten bleiben erhalten).
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
--  Tabellen
-- ---------------------------------------------------------------------
create table if not exists bt_events (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null,
  name        text not null,
  event_date  date,
  status      text not null default 'anmeldung'
              check (status in ('anmeldung','live','aufloesung','fertig')),
  current_nr  int  not null default 0,
  revealed    int  not null default 0,
  draw_seq    int  not null default 0,
  created_at  timestamptz not null default now()
);

create table if not exists bt_event_secrets (
  event_id  uuid primary key references bt_events(id) on delete cascade,
  pin_hash  text not null
);

create table if not exists bt_players (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references bt_events(id) on delete cascade,
  name        text not null,
  token       uuid not null default gen_random_uuid(),
  created_at  timestamptz not null default now()
);
create unique index if not exists bt_players_name_uq on bt_players(event_id, lower(name));

create table if not exists bt_beers (
  id           uuid primary key default gen_random_uuid(),
  event_id     uuid not null references bt_events(id) on delete cascade,
  player_id    uuid references bt_players(id) on delete set null,
  name         text not null,
  brought_by   text not null,
  price_per_l  numeric(6,2),
  blind_nr     int,
  served_at    timestamptz,
  created_at   timestamptz not null default now(),
  unique (event_id, blind_nr)
);

create table if not exists bt_ratings (
  id           uuid primary key default gen_random_uuid(),
  event_id     uuid not null references bt_events(id) on delete cascade,
  player_id    uuid not null references bt_players(id) on delete cascade,
  blind_nr     int  not null,
  optik        smallint check (optik between 1 and 5),
  geruch       smallint check (geruch between 1 and 5),
  geschmack    smallint check (geschmack between 1 and 5),
  notiz        text,
  tags         text[] not null default '{}',
  tipp_beer_id uuid references bt_beers(id) on delete set null,
  updated_at   timestamptz not null default now(),
  unique (player_id, blind_nr)
);

-- Kein direkter Zugriff von außen: alles läuft über die Funktionen unten.
alter table bt_events        enable row level security;
alter table bt_event_secrets enable row level security;
alter table bt_players       enable row level security;
alter table bt_beers         enable row level security;
alter table bt_ratings       enable row level security;
revoke all on bt_events, bt_event_secrets, bt_players, bt_beers, bt_ratings from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on bt_events, bt_event_secrets, bt_players, bt_beers, bt_ratings from anon, authenticated';
  end if;
end $$;

-- ---------------------------------------------------------------------
--  Hilfsfunktionen (nicht von außen aufrufbar)
-- ---------------------------------------------------------------------
create or replace function bt_admin_event(p_code text, p_pin text)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare v uuid;
begin
  select e.id into v
  from bt_events e join bt_event_secrets s on s.event_id = e.id
  where e.code = upper(trim(p_code)) and s.pin_hash = crypt(coalesce(p_pin,''), s.pin_hash);
  if v is null then raise exception 'Falscher Code oder falsche PIN'; end if;
  return v;
end $$;

create or replace function bt_player_event(p_player uuid, p_token uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select event_id into v from bt_players where id = p_player and token = p_token;
  if v is null then raise exception 'Unbekannter Teilnehmer – bitte neu beitreten'; end if;
  return v;
end $$;

-- Ergebnis je Bier: Gewichtung Optik 20 %, Geruch 20 %, Geschmack 60 %.
-- Fehlende Bewertungen zählen nicht als 0, sondern werden ausgelassen.
create or replace function bt_results(p_event uuid)
returns table (
  pos int, platz int, beer_id uuid, blind_nr int, name text, brought_by text,
  price_per_l numeric, n int, optik numeric, geruch numeric, geschmack numeric,
  score numeric, notes text[], tags text[]
) language sql stable security definer set search_path = public as $$
  with agg as (
    select b.id, b.blind_nr, b.name, b.brought_by, b.price_per_l,
           count(r.id)::int as n,
           avg(r.optik)::numeric as o, avg(r.geruch)::numeric as g, avg(r.geschmack)::numeric as s,
           coalesce(array_agg(trim(r.notiz)) filter (where coalesce(trim(r.notiz),'') <> ''), '{}') as notes,
           coalesce((select array_agg(t) from bt_ratings r2, unnest(r2.tags) t
                     where r2.event_id = b.event_id and r2.blind_nr = b.blind_nr), '{}') as tags
    from bt_beers b
    left join bt_ratings r on r.event_id = b.event_id and r.blind_nr = b.blind_nr
    where b.event_id = p_event and b.blind_nr is not null
    group by b.id
  ), w as (
    select *,
      (case when o is null then 0 else 0.2 end +
       case when g is null then 0 else 0.2 end +
       case when s is null then 0 else 0.6 end) as wsum
    from agg
  ), sc as (
    select *,
      case when wsum = 0 then null else
        (coalesce(o,0) * case when o is null then 0 else 0.2 end +
         coalesce(g,0) * case when g is null then 0 else 0.2 end +
         coalesce(s,0) * case when s is null then 0 else 0.6 end) / wsum * 20
      end as sco
    from w
  )
  select (row_number() over (order by sco desc nulls last, blind_nr))::int,
         (rank()       over (order by round(sco,1) desc nulls last))::int,
         id, blind_nr, name, brought_by, price_per_l, n,
         round(o,2), round(g,2), round(s,2), round(sco,1), notes, tags
  from sc
  order by 1;
$$;

-- ---------------------------------------------------------------------
--  Öffentliche Funktionen
-- ---------------------------------------------------------------------

-- Neuen Abend anlegen → liefert den Abendcode (4 Zeichen)
create or replace function bt_create_event(p_name text, p_date date, p_pin text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  v_code text; v_id uuid; i int;
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if coalesce(length(trim(p_pin)),0) < 4 then raise exception 'Die PIN braucht mindestens 4 Zeichen'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'Bitte einen Namen für den Abend angeben'; end if;
  loop
    v_code := '';
    for i in 1..4 loop
      v_code := v_code || substr(chars, 1 + floor(random() * length(chars))::int, 1);
    end loop;
    exit when not exists (select 1 from bt_events where code = v_code);
  end loop;
  insert into bt_events(code, name, event_date) values (v_code, trim(p_name), p_date) returning id into v_id;
  insert into bt_event_secrets(event_id, pin_hash) values (v_id, crypt(trim(p_pin), gen_salt('bf')));
  return v_code;
end $$;

-- Gast tritt bei (gleicher Name = gleicher Teilnehmer, z. B. bei Handywechsel)
create or replace function bt_join(p_code text, p_name text)
returns json language plpgsql security definer set search_path = public as $$
declare v_event uuid; v_p bt_players;
begin
  select id into v_event from bt_events where code = upper(trim(p_code));
  if v_event is null then raise exception 'Diesen Abendcode gibt es nicht'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'Bitte deinen Namen eingeben'; end if;
  select * into v_p from bt_players where event_id = v_event and lower(name) = lower(trim(p_name));
  if v_p.id is null then
    insert into bt_players(event_id, name) values (v_event, trim(p_name)) returning * into v_p;
  end if;
  return json_build_object('player_id', v_p.id, 'token', v_p.token, 'name', v_p.name, 'code', upper(trim(p_code)));
end $$;

-- Gast meldet sein Bier an (ein Bier pro Person, erneutes Senden ändert es)
create or replace function bt_register_beer(p_player uuid, p_token uuid, p_name text, p_price numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_event uuid; v_status text; v_pname text;
begin
  v_event := bt_player_event(p_player, p_token);
  select status into v_status from bt_events where id = v_event;
  if v_status <> 'anmeldung' then raise exception 'Die Bier-Anmeldung ist schon geschlossen'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'Bitte die Biersorte eingeben'; end if;
  select name into v_pname from bt_players where id = p_player;
  update bt_beers set name = trim(p_name), price_per_l = p_price
   where event_id = v_event and player_id = p_player;
  if not found then
    insert into bt_beers(event_id, player_id, name, brought_by, price_per_l)
    values (v_event, p_player, trim(p_name), v_pname, p_price);
  end if;
end $$;

-- Bewertung abgeben/ändern
create or replace function bt_rate(p_player uuid, p_token uuid, p_nr int,
  p_optik int, p_geruch int, p_geschmack int, p_notiz text, p_tags text[], p_tipp uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_event uuid; e bt_events;
begin
  v_event := bt_player_event(p_player, p_token);
  select * into e from bt_events where id = v_event;
  if e.status <> 'live' then raise exception 'Bewerten ist gerade nicht möglich'; end if;
  if p_nr < 1 or p_nr > e.current_nr then raise exception 'Dieses Bier wurde noch nicht ausgeschenkt'; end if;
  if p_tipp is not null and not exists (select 1 from bt_beers where id = p_tipp and event_id = v_event) then
    p_tipp := null;
  end if;
  insert into bt_ratings(event_id, player_id, blind_nr, optik, geruch, geschmack, notiz, tags, tipp_beer_id, updated_at)
  values (v_event, p_player, p_nr, p_optik, p_geruch, p_geschmack, nullif(trim(p_notiz),''), coalesce(p_tags,'{}'), p_tipp, now())
  on conflict (player_id, blind_nr) do update set
    optik = excluded.optik, geruch = excluded.geruch, geschmack = excluded.geschmack,
    notiz = excluded.notiz, tags = excluded.tags, tipp_beer_id = excluded.tipp_beer_id, updated_at = now();
end $$;

-- Öffentlicher Stand des Abends (für Handys und Fernseher).
-- Verrät die Zuordnung Nummer → Bier erst bei der Auflösung.
create or replace function bt_state(p_code text, p_player uuid default null, p_token uuid default null)
returns json language plpgsql stable security definer set search_path = public as $$
declare e bt_events; v_me uuid; v_total int; v_res json; v_tipp json;
begin
  select * into e from bt_events where code = upper(trim(p_code));
  if e.id is null then raise exception 'Diesen Abendcode gibt es nicht'; end if;
  select id into v_me from bt_players where id = p_player and token = p_token and event_id = e.id;
  select count(*) into v_total from bt_beers where event_id = e.id and blind_nr is not null;

  if e.status in ('aufloesung','fertig') then
    select coalesce(json_agg(row_to_json(r) order by r.pos), '[]') into v_res
    from bt_results(e.id) r
    where e.status = 'fertig' or r.pos > v_total - e.revealed;
  else
    v_res := '[]';
  end if;

  if e.status = 'fertig' then
    select coalesce(json_agg(t order by t.treffer desc, t.name), '[]') into v_tipp from (
      select p.name, count(*) filter (where b.id is not null)::int as treffer,
             count(r.tipp_beer_id)::int as tipps
      from bt_players p
      left join bt_ratings r on r.player_id = p.id
      left join bt_beers b on b.id = r.tipp_beer_id and b.blind_nr = r.blind_nr
      where p.event_id = e.id
      group by p.id
      having count(r.tipp_beer_id) > 0
    ) t;
  else
    v_tipp := '[]';
  end if;

  return json_build_object(
    'event', json_build_object('name', e.name, 'date', e.event_date, 'code', e.code, 'status', e.status,
                               'current_nr', e.current_nr, 'revealed', e.revealed, 'draw_seq', e.draw_seq,
                               'served', v_total),
    'players', coalesce((select json_agg(json_build_object(
                  'name', p.name,
                  'rated_current', exists (select 1 from bt_ratings r where r.player_id = p.id and r.blind_nr = e.current_nr),
                  'has_beer', exists (select 1 from bt_beers b where b.player_id = p.id)) order by p.created_at)
                from bt_players p where p.event_id = e.id), '[]'),
    'beers', coalesce((select json_agg(json_build_object('id', b.id, 'name', b.name, 'brought_by', b.brought_by,
                  'price_per_l', b.price_per_l, 'mine', coalesce(b.player_id = v_me, false)) order by lower(b.name))
                from bt_beers b where b.event_id = e.id), '[]'),
    'rated_count', (select count(*) from bt_ratings r where r.event_id = e.id and r.blind_nr = e.current_nr and e.current_nr > 0),
    'me', case when v_me is null then null else json_build_object(
             'name', (select name from bt_players where id = v_me),
             'ratings', coalesce((select json_agg(json_build_object('nr', r.blind_nr, 'optik', r.optik, 'geruch', r.geruch,
                           'geschmack', r.geschmack, 'notiz', r.notiz, 'tags', r.tags, 'tipp', r.tipp_beer_id) order by r.blind_nr)
                         from bt_ratings r where r.player_id = v_me), '[]')) end,
    'results', v_res,
    'tipps', v_tipp
  );
end $$;

-- ---------------------------------------------------------------------
--  Gastgeber-Funktionen (Abendcode + PIN)
-- ---------------------------------------------------------------------
create or replace function bt_admin_state(p_code text, p_pin text)
returns json language plpgsql stable security definer set search_path = public, extensions as $$
declare v uuid; e bt_events;
begin
  v := bt_admin_event(p_code, p_pin);
  select * into e from bt_events where id = v;
  return json_build_object(
    'event', row_to_json(e),
    'beers', coalesce((select json_agg(json_build_object('id', b.id, 'name', b.name, 'brought_by', b.brought_by,
                 'price_per_l', b.price_per_l, 'blind_nr', b.blind_nr) order by b.blind_nr nulls last, lower(b.name))
               from bt_beers b where b.event_id = v), '[]'),
    'players', coalesce((select json_agg(json_build_object('id', p.id, 'name', p.name,
                 'ratings', (select count(*) from bt_ratings r where r.player_id = p.id)) order by p.created_at)
               from bt_players p where p.event_id = v), '[]'),
    'results', coalesce((select json_agg(row_to_json(r) order by r.pos) from bt_results(v) r), '[]')
  );
end $$;

create or replace function bt_admin_add_beer(p_code text, p_pin text, p_name text, p_brought_by text, p_price numeric)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v uuid;
begin
  v := bt_admin_event(p_code, p_pin);
  if coalesce(trim(p_name),'') = '' then raise exception 'Bitte die Biersorte eingeben'; end if;
  insert into bt_beers(event_id, name, brought_by, price_per_l)
  values (v, trim(p_name), coalesce(nullif(trim(p_brought_by),''), 'Überraschung'), p_price);
end $$;

create or replace function bt_admin_delete_beer(p_code text, p_pin text, p_beer uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v uuid;
begin
  v := bt_admin_event(p_code, p_pin);
  if exists (select 1 from bt_beers where id = p_beer and event_id = v and blind_nr is not null) then
    raise exception 'Dieses Bier wurde schon ausgeschenkt und kann nicht mehr gelöscht werden';
  end if;
  delete from bt_beers where id = p_beer and event_id = v;
end $$;

create or replace function bt_admin_set_status(p_code text, p_pin text, p_status text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v uuid;
begin
  v := bt_admin_event(p_code, p_pin);
  if p_status not in ('anmeldung','live','aufloesung','fertig') then raise exception 'Unbekannter Status'; end if;
  update bt_events set status = p_status,
         revealed = case when p_status = 'aufloesung' then 0 else revealed end
   where id = v;
end $$;

-- Losverfahren: zieht zufällig das nächste noch nicht ausgeschenkte Bier
create or replace function bt_admin_draw(p_code text, p_pin text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v uuid; v_beer bt_beers; v_nr int;
begin
  v := bt_admin_event(p_code, p_pin);
  if (select status from bt_events where id = v) <> 'live' then
    raise exception 'Erst den Abend starten (Status „Live“)';
  end if;
  select * into v_beer from bt_beers where event_id = v and blind_nr is null order by random() limit 1;
  if v_beer.id is null then raise exception 'Alle Biere sind schon ausgeschenkt'; end if;
  select coalesce(max(blind_nr),0) + 1 into v_nr from bt_beers where event_id = v;
  update bt_beers set blind_nr = v_nr, served_at = now() where id = v_beer.id;
  update bt_events set current_nr = v_nr, draw_seq = draw_seq + 1 where id = v;
  return json_build_object('nr', v_nr, 'name', v_beer.name, 'brought_by', v_beer.brought_by);
end $$;

create or replace function bt_admin_set_current(p_code text, p_pin text, p_nr int)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v uuid; v_max int;
begin
  v := bt_admin_event(p_code, p_pin);
  select coalesce(max(blind_nr),0) into v_max from bt_beers where event_id = v;
  if p_nr < 1 or p_nr > v_max then raise exception 'Diese Nummer gibt es noch nicht'; end if;
  update bt_events set current_nr = p_nr where id = v;
end $$;

-- Auflösung: weitere Plätze aufdecken (von hinten nach vorne)
create or replace function bt_admin_reveal(p_code text, p_pin text, p_delta int)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare v uuid; v_total int; v_new int;
begin
  v := bt_admin_event(p_code, p_pin);
  select count(*) into v_total from bt_beers where event_id = v and blind_nr is not null;
  update bt_events set revealed = greatest(0, least(v_total, revealed + p_delta))
   where id = v returning revealed into v_new;
  return v_new;
end $$;

-- ---------------------------------------------------------------------
--  Rechte: nur die öffentlichen Funktionen sind von außen aufrufbar
-- ---------------------------------------------------------------------
revoke all on function bt_admin_event(text,text), bt_player_event(uuid,uuid), bt_results(uuid) from public;

do $$
declare f text;
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function bt_admin_event(text,text), bt_player_event(uuid,uuid), bt_results(uuid) from anon, authenticated';
    foreach f in array array[
      'bt_create_event(text,date,text)',
      'bt_join(text,text)',
      'bt_register_beer(uuid,uuid,text,numeric)',
      'bt_rate(uuid,uuid,int,int,int,int,text,text[],uuid)',
      'bt_state(text,uuid,uuid)',
      'bt_admin_state(text,text)',
      'bt_admin_add_beer(text,text,text,text,numeric)',
      'bt_admin_delete_beer(text,text,uuid)',
      'bt_admin_set_status(text,text,text)',
      'bt_admin_draw(text,text)',
      'bt_admin_set_current(text,text,int)',
      'bt_admin_reveal(text,text,int)'
    ] loop
      execute format('grant execute on function %s to anon, authenticated', f);
    end loop;
  end if;
end $$;

notify pgrst, 'reload schema';
