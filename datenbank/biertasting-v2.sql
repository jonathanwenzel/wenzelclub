-- =====================================================================
--  WENZEL CLUB · BIERTASTING · Datenbank-Update v2.0 (Stand 07.10.2026)
--  Neu: Live-Tabelle für Fernseher und Handys.
--  Sobald ALLE Tester eine Nummer bewertet haben, erscheint deren Punktzahl
--  (nur die Nummer, nicht der Biername) in der Live-Tabelle. So beeinflusst
--  niemand die Bewertung eines Bieres, das noch im Glas ist.
--  Voraussetzung: biertasting-v1.sql wurde schon ausgeführt.
--  Einmal in Supabase → SQL Editor einfügen und „Run“ drücken (darf mehrfach laufen).
-- =====================================================================

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

grant execute on function bt_state(text,uuid,uuid) to anon, authenticated;

notify pgrst, 'reload schema';
