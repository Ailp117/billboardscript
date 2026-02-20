# esx_billboardscript

Digitale Werbetafeln fuer FiveM/ESX mit URL-Rotation, Admin-UI und MySQL-Speicherung.

## Uebersicht

- Ersetzt Vanilla-Billboard-Texturen durch ein DUI-Weboverlay
- Erkennt zusaetzlich billboard-aehnliche Custom-Modelle automatisch (optional)
- Rotiert Werbung ueber mehrere URLs im einstellbaren Intervall
- Admin-UI per Ingame-Command (`/billboardadmin`)
- Live-Vorschau im UI (kleines Preview-Bild)
- Einstellungen werden serverweit synchronisiert und in MySQL gespeichert
- Debug-Modus per Command (`/billboarddebug`)

## Voraussetzungen

- FiveM Server (Artifact mit `AddReplaceTexture` Support)
- `es_extended` (ESX)
- `oxmysql`
- Internetzugang fuer externe Bild-URLs

## Installation

1. Resource in deinen `resources`-Ordner legen (z. B. `resources/[local]/esx_billboardscript`).
2. In `server.cfg` Startreihenfolge setzen:
   - `ensure oxmysql`
   - `ensure es_extended`
   - `ensure esx_billboardscript`
3. Optional SQL manuell importieren:
   - Datei: `sql/billboard_settings.sql`
   - Hinweis: Die Tabelle wird beim Resource-Start auch automatisch erstellt.
4. Resource neu starten:
   - `restart esx_billboardscript`

## Rechte und Adminzugriff

Admin-Check erfolgt ueber:

- ESX Gruppen in `Config.AdminGroups`
- oder ACE Permission in `Config.AcePermission`

Optionales ACE-Beispiel:

```cfg
add_ace group.admin billboard.admin allow
```

## Commands

- `/billboardadmin`
  - Oeffnet das Admin-UI (nur Admins)
- `/billboarddebug on`
- `/billboarddebug off`
- `/billboarddebug toggle`
- `/billboarddebug status`
- `/billboardcoverage toggle [radius]`
- `/billboardcoverage on [radius]`
- `/billboardcoverage off`
- `/billboardcoverage scan [radius]`
- `/billboardcoverage status`

## Admin-UI Funktionen

- Aktivieren/Deaktivieren der digitalen Billboards
- Wechselintervall in Sekunden
- Mehrere URLs (eine pro Zeile)
- Live-Vorschau der aktuellen Zeile
- Speichern auf Server + sofortige Synchronisierung an alle Spieler

## Konfiguration (`config.lua`)

Wichtige Optionen:

- `Config.AdminCommand`
- `Config.DebugCommand`
- `Config.AdminGroups`
- `Config.AcePermission`
- `Config.Debug`
- `Config.DatabaseTable`
- `Config.DatabaseRowId`
- `Config.AutoCreateSchema`
- `Config.DefaultSettings`
- `Config.MinRotationSeconds`
- `Config.MaxRotationSeconds`
- `Config.MaxUrls`
- `Config.MaxUrlLength`
- `Config.MaxIncomingPayloadUrls`
- `Config.MaxIncomingPayloadBytes`
- `Config.RequestCooldownMs`
- `Config.SaveCooldownMs`
- `Config.CacheBust`
- `Config.ClientSettingsRetryMs`
- `Config.CoverageCommand`
- `Config.CoverageDefaultRadius`
- `Config.CoverageMinRadius`
- `Config.CoverageMaxRadius`
- `Config.CoverageScanIntervalMs`
- `Config.CoverageDrawDistance`
- `Config.CoverageMaxDrawEntries`
- `Config.AutoDiscoverBillboardTargets`
- `Config.AutoDiscoverRadius`
- `Config.AutoDiscoverIntervalMs`
- `Config.AutoDiscoverKeywords`
- `Config.CustomTextureTargets`

### Billboard-Texturen (Vanilla)

- `Config.VanillaBillboardTextures` enthaelt die bekannten Vanilla-Billboard-Namen.
- `Config.TextureTargets` wird daraus automatisch generiert (inkl. `_lod` Varianten).
- `Config.VanillaBillboardModels` steuert, welche Modelle der Coverage-Scan prueft.
- Falls auf deiner Map einzelne Schilder nicht ersetzt werden, musst du passende `txd/txn` Targets ergaenzen.

### Billboard-Texturen (Custom Maps / Modded Billboards)

- `Config.AutoDiscoverBillboardTargets = true` aktiviert eine automatische Erkennung von Modellnamen in der Naehe.
- Gefundene Namen mit Keywords aus `Config.AutoDiscoverKeywords` erhalten automatisch Targets (`name` und `name_lod`).
- Fuer feste manuelle Zuordnungen nutze `Config.CustomTextureTargets`:

```lua
Config.CustomTextureTargets = {
    { txd = "my_billboard_asset", txn = "my_billboard_asset" },
    { txd = "my_billboard_asset", txn = "my_billboard_face" }
}
```

## Datenbank

Standard:

- Tabelle: `billboard_settings`
- Datensatz-ID: `1` (`Config.DatabaseRowId`)
- Feld `settings` enthaelt die JSON-Einstellungen

Beim Speichern aus dem UI werden die Settings per UPSERT aktualisiert.

## URL-Anforderungen

- Nur `http://` oder `https://` URLs sind erlaubt
- Leere, doppelte oder zu lange Eintraege werden bereinigt
- Fuer die UI-Livevorschau am besten direkte Bild-URLs nutzen (`.png`, `.jpg`, `.webp`)
- Manche Seiten blockieren Einbettung, dann zeigt die Vorschau einen Fehlerhinweis

## Debugging

Debug einschalten:

```text
/billboarddebug on
```

Dann bekommst du zusaetzliche Logs:

- Server-Konsole: DB, Settings-Ladevorgaenge, Sync-Ereignisse, Admin-Aktionen
- Client-F8: DUI-Wechsel, Texture-Replacement, Rotationsereignisse, UI-Events

## Hardening

Eingebaute Schutzmechanismen:

- Serverseitige Payload-Limits (Groesse und URL-Anzahl)
- Cooldowns gegen Event-Spam (`requestSettings` und `saveSettings`)
- Save-Lock gegen gleichzeitige Schreibvorgaenge
- Init-Guards waehrend Datenbank/Resource noch startet
- Client-Retry, falls initiale Settings nicht sofort ankommen
- Strengere URL-Validierung im UI vor dem Speichern

## Coverage-Mode (Verifikation)

Mit dem Coverage-Mode kannst du schnell pruefen, ob erkannte Billboard-Modelle im Umkreis durch deine `TextureTargets` abgedeckt sind.

Empfohlener Ablauf:

1. `/billboardcoverage on 400`
2. Fahre an mehreren Stellen durch die Stadt.
3. Achte auf Marker/Text:
   - `MAPPED` = Modell hat passende Texture-Abdeckung
   - `UNMAPPED` = Modell gefunden, aber keine passende Texture-Abdeckung erkannt
4. Optional Einzel-Scan:
   - `/billboardcoverage scan 600`
5. Wenn `UNMAPPED` auftaucht:
   - fehlende Billboard-Modelle/Textures in `config.lua` ergaenzen

## Troubleshooting

- Billboards bleiben unveraendert:
  - Resource laeuft nicht oder Startreihenfolge falsch
  - Fehlende TextureTargets fuer deine Map
- Bilder wechseln nicht:
  - URL nicht erreichbar
  - Host blockiert Zugriff/Einbettung
- Admin-UI oeffnet nicht:
  - Keine Adminrechte (ESX Gruppe/ACE pruefen)
- DB-Fehler:
  - `oxmysql` laeuft nicht
  - DB-Zugangsdaten in `server.cfg` falsch

## Dateien

- `fxmanifest.lua` - Resource Manifest
- `config.lua` - zentrale Konfiguration
- `server/main.lua` - Adminrechte, DB, Sync
- `client/main.lua` - DUI, Replacement, Rotation
- `web/index.html` - NUI Markup
- `web/style.css` - NUI Styling
- `web/app.js` - NUI Logik inkl. Live-Vorschau
- `sql/billboard_settings.sql` - optionale SQL-Datei
