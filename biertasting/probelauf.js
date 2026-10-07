/* Wenzel Club Biertasting – Probelauf (Demo ohne Datenbank).
   Bildet die Datenbank-Funktionen aus datenbank/biertasting-v1.sql + v2.sql im Browser nach,
   damit man einen kompletten Abend gefahrlos durchspielen kann. Mitspieler sind Bots. */
(function(){
  const uid = () => (crypto.randomUUID ? crypto.randomUUID() : "id-" + Math.random().toString(36).slice(2) + Date.now().toString(36));
  const today = () => { const d = new Date(); return d.getFullYear() + "-" + String(d.getMonth()+1).padStart(2,"0") + "-" + String(d.getDate()).padStart(2,"0"); };
  const BOTS = [
    {name:"Bina",   beer:"Licher Pilsner",          price:1.39, q:3.6},
    {name:"Maxim",  beer:"Eulchen Pils",            price:3.00, q:4.3},
    {name:"Harald", beer:"Schlappeseppel Pils",     price:1.45, q:3.9},
    {name:"Michel", beer:"Pilsner Urquell",         price:2.40, q:3.8},
    {name:"Günter", beer:"Krombacher Pils",         price:1.30, q:3.5},
    {name:"Alan",   beer:"Waldhaus Diplom Pils",    price:2.60, q:4.5},
  ];
  const NOTES = ["süffig","fein herb","riecht nach Wiese","tut nicht weh","Stadionbier","schnittfeste Schaumkrone","malzig im Abgang","zu bitter","runde Sache","Plastikbier","erfrischend","Eigene Liga","WC-Ente?","nussig","klassisch"];
  const TAGS = ["herb","süffig","malzig","spritzig","fruchtig","hopfig","mild","wässrig","Stadionbier"];
  let D, botTimer = null, speed = 1, listeners = [];

  function reset(){
    D = { event:{ id:uid(), code:"DEMO", name:"Probelauf", event_date: today(), status:"anmeldung", current_nr:0, revealed:0, draw_seq:0, created_at:new Date().toISOString() },
          players:[], beers:[], ratings:[], botsIn:false, log:[] };
    note("Neuer Probelauf gestartet. Abendcode DEMO, Gastgeber-PIN 1234.");
  }
  function note(t){ D.log.unshift({t, at:new Date()}); D.log = D.log.slice(0, 40); listeners.forEach(f=>f()); }
  const err = m => { throw new Error(m); };
  const clone = x => JSON.parse(JSON.stringify(x));
  const avg = a => a.length ? a.reduce((s,v)=>s+v,0)/a.length : null;
  const r2 = v => v==null ? null : Math.round(v*100)/100;
  const r1 = v => v==null ? null : Math.round(v*10)/10;

  function results(){
    const served = D.beers.filter(b=>b.blind_nr!=null);
    const rows = served.map(b => {
      const R = D.ratings.filter(r=>r.blind_nr===b.blind_nr);
      const o = avg(R.map(r=>r.optik).filter(v=>v!=null)), g = avg(R.map(r=>r.geruch).filter(v=>v!=null)), s = avg(R.map(r=>r.geschmack).filter(v=>v!=null));
      const ws = (o==null?0:.2)+(g==null?0:.2)+(s==null?0:.6);
      const sco = ws ? ((o||0)*(o==null?0:.2)+(g||0)*(g==null?0:.2)+(s||0)*(s==null?0:.6))/ws*20 : null;
      return { beer_id:b.id, blind_nr:b.blind_nr, name:b.name, brought_by:b.brought_by, price_per_l:b.price_per_l, n:R.length,
               optik:r2(o), geruch:r2(g), geschmack:r2(s), _s:sco, score:r1(sco),
               notes:R.map(r=>(r.notiz||"").trim()).filter(Boolean), tags:R.flatMap(r=>r.tags||[]) };
    });
    rows.sort((a,b)=> (b._s??-1)-(a._s??-1) || a.blind_nr-b.blind_nr);
    rows.forEach((r,i)=>{ r.pos = i+1; r.platz = 1 + rows.filter(x=>(x.score??-1) > (r.score??-1)).length; delete r._s; });
    return rows;
  }
  function live(){
    if (D.event.status !== "live") return [];
    const np = D.players.length, out = [];
    for (let nr = 1; nr <= D.event.current_nr; nr++) {
      const R = D.ratings.filter(r=>r.blind_nr===nr);
      if (!R.length || (R.length < np && nr > D.event.current_nr - 2)) continue;
      const o = avg(R.map(r=>r.optik)), g = avg(R.map(r=>r.geruch)), s = avg(R.map(r=>r.geschmack));
      out.push({nr, n:R.length, score: r1((o*.2+g*.2+s*.6)*20)});
    }
    out.sort((a,b)=>b.score-a.score || a.nr-b.nr);
    out.forEach(x=> x.rang = 1 + out.filter(y=>y.score > x.score).length);
    return out;
  }
  const player = (id, tok) => { const p = D.players.find(p=>p.id===id && p.token===tok); if (!p) err("Unbekannter Teilnehmer – bitte neu beitreten"); return p; };
  const checkCode = c => { if (String(c||"").toUpperCase().trim() !== D.event.code) err("Diesen Abendcode gibt es nicht"); };
  const admin = (c, p) => { checkCode(c); if (String(p||"") !== "1234") err("Falscher Code oder falsche PIN"); };

  const F = {
    bt_join({p_code, p_name}){
      checkCode(p_code); const n = String(p_name||"").trim(); if (!n) err("Bitte deinen Namen eingeben");
      let p = D.players.find(x=>x.name.toLowerCase()===n.toLowerCase());
      if (!p) { p = {id:uid(), name:n, token:uid(), created:Date.now()}; D.players.push(p); note(`${n} ist dem Abend beigetreten.`); }
      return {player_id:p.id, token:p.token, name:p.name, code:D.event.code};
    },
    bt_register_beer({p_player, p_token, p_name, p_price}){
      const p = player(p_player, p_token);
      if (D.event.status !== "anmeldung") err("Die Bier-Anmeldung ist schon geschlossen");
      const n = String(p_name||"").trim(); if (!n) err("Bitte die Biersorte eingeben");
      let b = D.beers.find(b=>b.player_id===p.id);
      if (b) { b.name = n; b.price_per_l = p_price ?? null; }
      else { D.beers.push({id:uid(), player_id:p.id, name:n, brought_by:p.name, price_per_l:p_price ?? null, blind_nr:null}); note(`${p.name} bringt ${n} mit.`); }
      return null;
    },
    bt_rate({p_player, p_token, p_nr, p_optik, p_geruch, p_geschmack, p_notiz, p_tags, p_tipp}){
      const p = player(p_player, p_token);
      if (D.event.status !== "live") err("Bewerten ist gerade nicht möglich");
      if (p_nr < 1 || p_nr > D.event.current_nr) err("Dieses Bier wurde noch nicht ausgeschenkt");
      const tipp = D.beers.some(b=>b.id===p_tipp) ? p_tipp : null;
      let r = D.ratings.find(r=>r.player_id===p.id && r.blind_nr===p_nr);
      const v = {optik:p_optik, geruch:p_geruch, geschmack:p_geschmack, notiz:(p_notiz||"").trim()||null, tags:p_tags||[], tipp_beer_id:tipp};
      if (r) Object.assign(r, v); else { D.ratings.push({player_id:p.id, blind_nr:p_nr, ...v}); if (!p.bot) note(`${p.name} hat Nr. ${p_nr} bewertet.`); }
      return null;
    },
    bt_state({p_code, p_player, p_token}){
      checkCode(p_code);
      const e = D.event, me = D.players.find(p=>p.id===p_player && p.token===p_token);
      const total = D.beers.filter(b=>b.blind_nr!=null).length;
      let res = [];
      if (e.status === "aufloesung" || e.status === "fertig") res = results().filter(r => e.status === "fertig" || r.pos > total - e.revealed);
      let tipps = [];
      if (e.status === "fertig") {
        tipps = D.players.map(p => {
          const R = D.ratings.filter(r=>r.player_id===p.id && r.tipp_beer_id);
          return {name:p.name, tipps:R.length, treffer:R.filter(r=>D.beers.find(b=>b.id===r.tipp_beer_id)?.blind_nr===r.blind_nr).length};
        }).filter(t=>t.tipps>0).sort((a,b)=>b.treffer-a.treffer || a.name.localeCompare(b.name));
      }
      return clone({
        live: live(),
        event:{name:e.name, date:e.event_date, code:e.code, status:e.status, current_nr:e.current_nr, revealed:e.revealed, draw_seq:e.draw_seq, served:total},
        players: D.players.map(p=>({name:p.name, rated_current: D.ratings.some(r=>r.player_id===p.id && r.blind_nr===e.current_nr), has_beer: D.beers.some(b=>b.player_id===p.id)})),
        beers: [...D.beers].sort((a,b)=>a.name.toLowerCase().localeCompare(b.name.toLowerCase())).map(b=>({id:b.id, name:b.name, brought_by:b.brought_by, price_per_l:b.price_per_l, mine: !!me && b.player_id===me.id})),
        rated_count: e.current_nr > 0 ? D.ratings.filter(r=>r.blind_nr===e.current_nr).length : 0,
        me: me ? {name:me.name, ratings: D.ratings.filter(r=>r.player_id===me.id).sort((a,b)=>a.blind_nr-b.blind_nr)
                   .map(r=>({nr:r.blind_nr, optik:r.optik, geruch:r.geruch, geschmack:r.geschmack, notiz:r.notiz, tags:r.tags, tipp:r.tipp_beer_id}))} : null,
        results: res, tipps
      });
    },
    bt_admin_state({p_code, p_pin}){
      admin(p_code, p_pin);
      return clone({ event: D.event,
        beers: [...D.beers].sort((a,b)=>(a.blind_nr??1e9)-(b.blind_nr??1e9) || a.name.toLowerCase().localeCompare(b.name.toLowerCase()))
                 .map(b=>({id:b.id, name:b.name, brought_by:b.brought_by, price_per_l:b.price_per_l, blind_nr:b.blind_nr})),
        players: D.players.map(p=>({id:p.id, name:p.name, ratings:D.ratings.filter(r=>r.player_id===p.id).length})),
        results: results() });
    },
    bt_admin_add_beer({p_code, p_pin, p_name, p_brought_by, p_price}){
      admin(p_code, p_pin); const n = String(p_name||"").trim(); if (!n) err("Bitte die Biersorte eingeben");
      D.beers.push({id:uid(), player_id:null, name:n, brought_by:String(p_brought_by||"").trim()||"Überraschung", price_per_l:p_price ?? null, blind_nr:null});
      note(`Gastgeber hat ${n} hinzugefügt.`); return null;
    },
    bt_admin_delete_beer({p_code, p_pin, p_beer}){
      admin(p_code, p_pin);
      if (D.beers.some(b=>b.id===p_beer && b.blind_nr!=null)) err("Dieses Bier wurde schon ausgeschenkt und kann nicht mehr gelöscht werden");
      D.beers = D.beers.filter(b=>b.id!==p_beer); return null;
    },
    bt_admin_set_status({p_code, p_pin, p_status}){
      admin(p_code, p_pin);
      if (!["anmeldung","live","aufloesung","fertig"].includes(p_status)) err("Unbekannter Status");
      D.event.status = p_status; if (p_status === "aufloesung") D.event.revealed = 0;
      note({anmeldung:"Zurück zur Anmeldung.", live:"Die Verkostung läuft!", aufloesung:"Die Auflösung beginnt.", fertig:"Das Endergebnis steht."}[p_status]);
      return null;
    },
    bt_admin_draw({p_code, p_pin}){
      admin(p_code, p_pin);
      if (D.event.status !== "live") err("Erst den Abend starten (Status „Live“)");
      const open = D.beers.filter(b=>b.blind_nr==null); if (!open.length) err("Alle Biere sind schon ausgeschenkt");
      const b = open[Math.floor(Math.random()*open.length)];
      const nr = Math.max(0, ...D.beers.map(x=>x.blind_nr||0)) + 1;
      b.blind_nr = nr; D.event.current_nr = nr; D.event.draw_seq++;
      note(`Los gezogen: Bier Nr. ${nr} wird eingeschenkt.`);
      return {nr, name:b.name, brought_by:b.brought_by};
    },
    bt_admin_set_current({p_code, p_pin, p_nr}){
      admin(p_code, p_pin); const mx = Math.max(0, ...D.beers.map(x=>x.blind_nr||0));
      if (p_nr < 1 || p_nr > mx) err("Diese Nummer gibt es noch nicht"); D.event.current_nr = p_nr; return null;
    },
    bt_admin_reveal({p_code, p_pin, p_delta}){
      admin(p_code, p_pin); const total = D.beers.filter(b=>b.blind_nr!=null).length;
      D.event.revealed = Math.max(0, Math.min(total, D.event.revealed + p_delta)); return D.event.revealed;
    },
    bt_create_event(){ err("Im Probelauf gibt es nur den Abend DEMO (PIN 1234)."); }
  };

  async function rpc(fn, args){
    await new Promise(r=>setTimeout(r, 60));
    if (!F[fn]) throw new Error("Unbekannte Funktion " + fn);
    return F[fn](args || {});
  }

  // ---- Bots
  function botsArrive(){
    if (D.botsIn) return; D.botsIn = true;
    BOTS.forEach((b, i) => setTimeout(() => {
      const j = F.bt_join({p_code:"DEMO", p_name:b.name});
      const p = D.players.find(p=>p.id===j.player_id); p.bot = true; p.q = b.q;
      if (D.event.status === "anmeldung") F.bt_register_beer({p_player:p.id, p_token:p.token, p_name:b.beer, p_price:b.price});
    }, (400 + i*700) / speed));
  }
  function botTick(){
    const e = D.event; if (e.status !== "live" || !e.current_nr) return;
    const beer = D.beers.find(b=>b.blind_nr===e.current_nr);
    const qBase = BOTS.find(b=>b.beer===beer?.name)?.q ?? 3.4;
    D.players.filter(p=>p.bot).forEach(p => {
      if (D.ratings.some(r=>r.player_id===p.id && r.blind_nr===e.current_nr)) return;
      if (Math.random() > 0.22 * speed) return;
      const own = beer && beer.player_id === p.id ? 0.4 : 0;           // ein bisschen Heimvorteil – menschlich
      const v = d => Math.max(1, Math.min(5, Math.round(qBase + own + d + (Math.random()*1.6 - .8))));
      const guessRight = Math.random() < .3;
      const others = D.beers.filter(b=>b.id!==beer?.id);
      F.bt_rate({p_player:p.id, p_token:p.token, p_nr:e.current_nr, p_optik:v(.2), p_geruch:v(0), p_geschmack:v(-.1),
        p_notiz: Math.random() < .55 ? NOTES[Math.floor(Math.random()*NOTES.length)] : "",
        p_tags: [TAGS[Math.floor(Math.random()*TAGS.length)]],
        p_tipp: Math.random() < .7 ? (guessRight ? beer?.id : others[Math.floor(Math.random()*others.length)]?.id) : null});
    });
  }
  function start(){ clearInterval(botTimer); botTimer = setInterval(botTick, 1000); }

  reset();
  window.BT_DEMO = {
    rpc, reset(){ reset(); }, botsArrive, start,
    setSpeed(s){ speed = s; }, get speed(){ return speed; },
    get data(){ return D; }, onChange(f){ listeners.push(f); },
    join(n){ const j = F.bt_join({p_code:"DEMO", p_name:n}); return D.players.find(p=>p.id===j.player_id); },
    beer(p, n, pr){ F.bt_register_beer({p_player:p.id, p_token:p.token, p_name:n, p_price:pr}); },
    admin: (fn, extra) => F[fn]({p_code:"DEMO", p_pin:"1234", ...(extra||{})})
  };
})();
