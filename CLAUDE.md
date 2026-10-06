# Wenzel Club – Projektnotizen für Claude

Private Plattform von Jonathan Wenzel für interaktive Apps mit Freunden, Familie und Gemeinde.
Immer auf Deutsch antworten. Keine Firmendaten (Wenzel Immobilien) in dieses Projekt.

## Technik
- **Domain:** wenzelclub.de (INWX, DNS: A @ → 75.2.60.5, CNAME www → wenzelclub.netlify.app)
- **Hosting:** Netlify, Projekt „wenzelclub“ – jeder Push auf `main` geht automatisch live
- **Datenbank:** Supabase-Projekt „wenzelclub“ (Region West EU / Irland)
  - URL: https://vyedtpuggrnxoajkilgv.supabase.co
  - Öffentlicher Schlüssel (publishable) steht in den App-Dateien – den geheimen Schlüssel nie ins Repo
  - Änderungen an der Datenbank als SQL-Skript in `datenbank/` ablegen; Jonathan führt es im Supabase SQL Editor aus
  - Supabase ist aus der Claude-Arbeitsumgebung nicht erreichbar → SQL lokal mit Postgres testen
- **Keine Suchmaschinen:** robots.txt + noindex bleiben drin

## Aufbau
| Pfad | Inhalt |
|---|---|
| `/` | Startseite mit Intro und App-Kacheln |
| `/biertasting/` | Biertasting-App (Kurzlink `/bier`) – Gast-, Fernseher- (`?modus=tv`) und Gastgeber-Ansicht (`?modus=gastgeber`) |
| `datenbank/biertasting-v1.sql` | Tabellen + Funktionen (Präfix `bt_`), Zugriff nur über Funktionen |

## Konventionen
- Jede App = eigener Ordner, eine HTML-Datei, Versionsnummer sichtbar im Footer
- Neue Datenbank-Tabellen bekommen ein App-Präfix (z. B. `poker_`, `fifa_`)
- Look Biertasting: schwarz/gold, Schrift „Saira Stencil One“ + Inter
