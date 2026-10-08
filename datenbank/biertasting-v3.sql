-- =====================================================================
--  WENZEL CLUB · BIERTASTING · Datenbank-Update v3.0 (Stand 08.10.2026)
--  Neu: Einladung zum Neustart 2026 und Pils-Prüfung bei der Anmeldung.
--   · Gäste wählen ihr Bier aus der Club-Liste (getestete Biere + Pils-Radar)
--     oder tragen ein eigenes ein (mit Brauerei, Link, Hinweis).
--   · Eigene/unklare Biere stehen auf „wird geprüft“, bis der Gastgeber
--     sie als Pils bestätigt oder ablehnt. Ausgelost wird erst, wenn alles geprüft ist.
--   · Kein Bier doppelt: Ist eine Sorte schon angemeldet, kommt ein Hinweis.
--   · Einladung: Ort, Uhrzeit und Einladungstext pro Abend.
--  Voraussetzung: biertasting-v1.sql und -v2.sql wurden schon ausgeführt.
--  Einmal in Supabase → SQL Editor einfügen und „Run“ drücken (darf mehrfach laufen).
-- =====================================================================

alter table bt_events add column if not exists ort       text;
alter table bt_events add column if not exists uhrzeit   text;
alter table bt_events add column if not exists einladung text;

alter table bt_beers add column if not exists pruefung    text not null default 'ok';
alter table bt_beers add column if not exists pils        text;
alter table bt_beers add column if not exists quelle      text;
alter table bt_beers add column if not exists brauerei    text;
alter table bt_beers add column if not exists link        text;
alter table bt_beers add column if not exists hinweis     text;
alter table bt_beers add column if not exists pruef_notiz text;
do $$ begin
  alter table bt_beers add constraint bt_beers_pruefung_chk check (pruefung in ('ok','pruefen','abgelehnt'));
exception when duplicate_object then null; end $$;

-- Biername vergleichbar machen (für „bringt schon jemand mit“)
create or replace function bt_norm(t text) returns text language sql immutable as $$
  select regexp_replace(lower(coalesce(t,'')), '[^a-z0-9äöüß]', '', 'g')
$$;

-- Gast meldet sein Bier an – mit Herkunft (Liste/eigenes) und Pils-Check der App
create or replace function bt_register_beer2(p_player uuid, p_token uuid, p_name text, p_price numeric,
  p_pils text, p_quelle text, p_brauerei text, p_link text, p_hinweis text)
returns json language plpgsql security definer set search_path = public as $$
declare v_event uuid; v_status text; v_pname text; v_pr text;
begin
  v_event := bt_player_event(p_player, p_token);
  select status into v_status from bt_events where id = v_event;
  if v_status <> 'anmeldung' then raise exception 'Die Bier-Anmeldung ist schon geschlossen'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'Bitte die Biersorte eingeben'; end if;
  if p_pils = 'kein' then raise exception 'Das ist kein Pils – bitte ein echtes Pils anmelden'; end if;
  if exists (select 1 from bt_beers where event_id = v_event and player_id is distinct from p_player
             and bt_norm(name) = bt_norm(p_name)) then
    raise exception 'Dieses Pils bringt schon jemand mit – bitte ein anderes aussuchen';
  end if;
  if p_quelle = 'eigen' and coalesce(trim(p_brauerei),'') = '' then
    raise exception 'Bitte bei einem eigenen Bier die Brauerei angeben';
  end if;
  v_pr := case when p_quelle = 'liste' and p_pils in ('pils','boehmisch','af') then 'ok' else 'pruefen' end;
  select name into v_pname from bt_players where id = p_player;
  update bt_beers set name = trim(p_name), price_per_l = p_price, pils = p_pils, quelle = p_quelle,
         brauerei = nullif(trim(p_brauerei),''), link = nullif(trim(p_link),''), hinweis = nullif(trim(p_hinweis),''),
         pruefung = v_pr, pruef_notiz = null
   where event_id = v_event and player_id = p_player;
  if not found then
    insert into bt_beers(event_id, player_id, name, brought_by, price_per_l, pils, quelle, brauerei, link, hinweis, pruefung)
    values (v_event, p_player, trim(p_name), v_pname, p_price, p_pils, p_quelle,
            nullif(trim(p_brauerei),''), nullif(trim(p_link),''), nullif(trim(p_hinweis),''), v_pr);
  end if;
  return json_build_object('pruefung', v_pr);
end $$;

-- Gastgeber prüft ein Bier: 'ok' (ist ein Pils) oder 'abgelehnt' (mit Begründung)
create or replace function bt_admin_review(p_code text, p_pin text, p_beer uuid, p_status text, p_notiz text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v uuid;
begin
  v := bt_admin_event(p_code, p_pin);
  if p_status not in ('ok','abgelehnt','pruefen') then raise exception 'Unbekannter Prüfstatus'; end if;
  update bt_beers set pruefung = p_status, pruef_notiz = nullif(trim(p_notiz),'')
   where id = p_beer and event_id = v;
  if not found then raise exception 'Dieses Bier gibt es nicht'; end if;
end $$;

-- Einladung: Ort, Uhrzeit, Text
create or replace function bt_admin_event_details(p_code text, p_pin text, p_ort text, p_uhrzeit text, p_text text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v uuid;
begin
  v := bt_admin_event(p_code, p_pin);
  update bt_events set ort = nullif(trim(p_ort),''), uhrzeit = nullif(trim(p_uhrzeit),''), einladung = nullif(trim(p_text),'')
   where id = v;
end $$;

-- Gastgeber-Sicht mit Prüfstatus
create or replace function bt_admin_state(p_code text, p_pin text)
returns json language plpgsql stable security definer set search_path = public, extensions as $$
declare v uuid; e bt_events;
begin
  v := bt_admin_event(p_code, p_pin);
  select * into e from bt_events where id = v;
  return json_build_object(
    'event', row_to_json(e),
    'beers', coalesce((select json_agg(json_build_object('id', b.id, 'name', b.name, 'brought_by', b.brought_by,
                 'price_per_l', b.price_per_l, 'blind_nr', b.blind_nr, 'pruefung', b.pruefung, 'pils', b.pils,
                 'quelle', b.quelle, 'brauerei', b.brauerei, 'link', b.link, 'hinweis', b.hinweis, 'pruef_notiz', b.pruef_notiz)
                 order by b.blind_nr nulls last, lower(b.name))
               from bt_beers b where b.event_id = v), '[]'),
    'players', coalesce((select json_agg(json_build_object('id', p.id, 'name', p.name,
                 'ratings', (select count(*) from bt_ratings r where r.player_id = p.id)) order by p.created_at)
               from bt_players p where p.event_id = v), '[]'),
    'results', coalesce((select json_agg(row_to_json(r) order by r.pos) from bt_results(v) r), '[]')
  );
end $$;

-- Losverfahren: erst wenn alle Biere geprüft sind; abgelehnte Biere werden nicht ausgelost
create or replace function bt_admin_draw(p_code text, p_pin text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v uuid; v_beer bt_beers; v_nr int; v_offen int;
begin
  v := bt_admin_event(p_code, p_pin);
  if (select status from bt_events where id = v) <> 'live' then
    raise exception 'Erst den Abend starten (Status „Live“)';
  end if;
  select count(*) into v_offen from bt_beers where event_id = v and pruefung = 'pruefen';
  if v_offen > 0 then raise exception 'Erst alle Biere prüfen – % wartet noch auf die Pils-Prüfung', v_offen; end if;
  select * into v_beer from bt_beers where event_id = v and blind_nr is null and pruefung <> 'abgelehnt'
   order by random() limit 1;
  if v_beer.id is null then raise exception 'Alle Biere sind schon ausgeschenkt'; end if;
  select coalesce(max(blind_nr),0) + 1 into v_nr from bt_beers where event_id = v;
  update bt_beers set blind_nr = v_nr, served_at = now() where id = v_beer.id;
  update bt_events set current_nr = v_nr, draw_seq = draw_seq + 1 where id = v;
  return json_build_object('nr', v_nr, 'name', v_beer.name, 'brought_by', v_beer.brought_by);
end $$;

-- Öffentlicher Stand: jetzt mit Einladung und Prüfstatus
create or replace function bt_state(p_code text, p_player uuid default null, p_token uuid default null)
returns json language plpgsql stable security definer set search_path = public as $$
declare e bt_events; v_me uuid; v_total int; v_res json; v_tipp json; v_live json; v_np int;
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

  -- Live-Tabelle: Ergebnis einer Nummer wird erst gezeigt, wenn ALLE sie bewertet haben
  -- (oder wenn schon zwei weitere Biere ausgeschenkt wurden). Biernamen bleiben geheim.
  select count(*) into v_np from bt_players where event_id = e.id;
  if e.status = 'live' then
    select coalesce(json_agg(json_build_object('nr', x.blind_nr, 'n', x.n, 'score', x.sco,
             'rang', x.rang) order by x.rang, x.blind_nr), '[]') into v_live
    from (
      select a.*, (rank() over (order by a.sco desc nulls last))::int as rang from (
        select r.blind_nr, count(*)::int as n,
          round((coalesce(avg(r.optik),0) * case when avg(r.optik) is null then 0 else 0.2 end +
                 coalesce(avg(r.geruch),0) * case when avg(r.geruch) is null then 0 else 0.2 end +
                 coalesce(avg(r.geschmack),0) * case when avg(r.geschmack) is null then 0 else 0.6 end)
                / nullif(case when avg(r.optik) is null then 0 else 0.2 end +
                         case when avg(r.geruch) is null then 0 else 0.2 end +
                         case when avg(r.geschmack) is null then 0 else 0.6 end, 0) * 20, 1) as sco
        from bt_ratings r
        where r.event_id = e.id and r.blind_nr <= e.current_nr
        group by r.blind_nr
        having count(*) >= v_np or r.blind_nr <= e.current_nr - 2
      ) a
    ) x;
  else
    v_live := '[]';
  end if;

  return json_build_object(
    'live', v_live,
    'event', json_build_object('name', e.name, 'date', e.event_date, 'code', e.code, 'status', e.status,
                               'ort', e.ort, 'uhrzeit', e.uhrzeit, 'einladung', e.einladung,
                               'current_nr', e.current_nr, 'revealed', e.revealed, 'draw_seq', e.draw_seq,
                               'served', v_total),
    'players', coalesce((select json_agg(json_build_object(
                  'name', p.name,
                  'rated_current', exists (select 1 from bt_ratings r where r.player_id = p.id and r.blind_nr = e.current_nr),
                  'has_beer', exists (select 1 from bt_beers b where b.player_id = p.id)) order by p.created_at)
                from bt_players p where p.event_id = e.id), '[]'),
    'beers', coalesce((select json_agg(json_build_object('id', b.id, 'name', b.name, 'brought_by', b.brought_by,
                  'price_per_l', b.price_per_l, 'mine', coalesce(b.player_id = v_me, false),
                  'pruefung', b.pruefung, 'pils', b.pils, 'quelle', b.quelle,
                  'pruef_notiz', case when b.player_id = v_me then b.pruef_notiz end) order by lower(b.name))
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


revoke all on function bt_norm(text) from public;
do $$
declare f text;
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function bt_norm(text) from anon, authenticated';
    foreach f in array array[
      'bt_register_beer2(uuid,uuid,text,numeric,text,text,text,text,text)',
      'bt_admin_review(text,text,uuid,text,text)',
      'bt_admin_event_details(text,text,text,text,text)',
      'bt_admin_state(text,text)',
      'bt_admin_draw(text,text)',
      'bt_state(text,uuid,uuid)'
    ] loop
      execute format('grant execute on function %s to anon, authenticated', f);
    end loop;
  end if;
end $$;

notify pgrst, 'reload schema';
