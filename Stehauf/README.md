# Stehauf

Eine macOS-App, die deinen LINAK-Stehschreibtisch regelmäßig hochfährt, damit du öfter im Stehen arbeitest.

Die App kündigt jede Fahrt an: Der Tisch stupst kurz, ein kleines Fenster zählt 60 Sekunden herunter, dann fährt er. Wer sitzen bleiben will, muss aktiv widersprechen.

> **Stand:** Der Code wird auf GitHub Actions unter macOS gebaut und die Logik ist getestet. An einem echten Tisch und mit echten Sensoren ist die App noch nicht gelaufen. Die Liste unter [Erster Test](#erster-test) zeigt, was zu prüfen ist.

## Bauen und starten

Voraussetzungen: macOS 14 oder neuer und die Xcode Command Line Tools (`xcode-select --install`).

```bash
cd Stehauf
./build-app.sh
open build/Stehauf.app
```

Beim ersten Start öffnet sich das Statusfenster. macOS fragt nach Bluetooth- und Kalenderzugriff. Nach jedem Neubau fragt macOS erneut, weil die App nur lokal signiert ist.

Der Tisch muss mit dem Mac gekoppelt werden: Halte die Bluetooth-Taste am Bedienpanel gedrückt, bis sie blinkt, und starte dann die App. Die LINAK-App auf dem Handy sollte währenddessen geschlossen sein, weil der Tisch nur eine Verbindung annimmt.

Die App merkt sich den ersten LINAK-Tisch, den sie findet. Starte sie deshalb das erste Mal zu Hause. Mit „Tisch vergessen“ im Statusfenster wählst du neu.

## Verhalten

- **Sitz-Uhr:** Sie läuft nur, wenn du am Rechner bist und der Tisch unten ist. Nach 45 Minuten kommt die Ankündigung.
- **Ankündigung:** Der Tisch fährt nur, wenn während des Countdowns eine Eingabe kam. Sonst wartet die App, bis du die Maus bewegst, und zählt dann 10 Sekunden.
- **Stehphase:** Nach 20 Minuten Stehen fährt der Tisch mit derselben Ankündigung wieder runter. Das lässt sich abschalten.
- **Rückkehr:** Kommst du nach einer Pause zurück und hast schon 60 % der Sitzzeit erreicht, kommt die Ankündigung sofort.
- **Meetings:** Während eines Meetings, fünf Minuten vor einem Termin und eine Minute danach fährt nichts.
- **Unterwegs:** Ist der Tisch nicht per Bluetooth erreichbar, tut die App nichts.
- **Von Hand:** Fährst du den Tisch am Bedienpanel, zählt das genauso.
- **Menüleiste:** Das Icon erscheint nur während Ankündigung, Fahrt und Stehphase. Das Statusfenster erreichst du, indem du die App erneut öffnest, zum Beispiel über Spotlight.

### Wie die App erkennt, was du tust

| Frage | Signal |
|---|---|
| Am Rechner? | Tastatur- oder Mauseingabe in den letzten 5 Minuten, Bildschirm nicht gesperrt |
| Stehst du? | Tischhöhe über der Mitte zwischen Sitz- und Stehhöhe |
| Im Meeting? | Kamera läuft, eine Meeting-App nutzt das Mikrofon, ein Kalendertermin mit Teilnehmern läuft, oder eine unbekannte App nutzt das Mikrofon länger als 2 Minuten |

Diktier-Tools werden ignoriert. Welche Apps als Meeting-App oder Diktier-Tool gelten, steht in `meetingAppPatterns` und `ignoredMicAppPatterns` in der Konfigurationsdatei. Es sind Teilstrings von Bundle-IDs.

## Sicherheit

- Der Tisch fährt nur, solange die App alle 0,4 Sekunden einen Befehl schickt. Stürzt die App ab, bleibt er stehen.
- Die App fährt erst, wenn du Sitz- und Stehhöhe am echten Tisch übernommen hast.
- Während der Fahrt zeigt das Fenster einen Stopp-Knopf.
- Bleibt der Tisch vor dem Ziel stehen, etwa durch den Kollisionsschutz, versucht die App es erst nach 15 Minuten wieder.

## Messprotokoll

Die App schreibt pro Tag eine Datei nach `~/Library/Application Support/Stehauf/logs/` im Format JSON Lines. Damit lässt sich die Erkennung nach einer Woche Betrieb mit echten Daten nachstellen.

| `kind` | Inhalt |
|---|---|
| `sample` | Messpunkt bei jeder Änderung und alle 15 Sekunden, solange du am Rechner bist |
| `decision` | Entscheidung des Regelwerks, z. B. Ankündigung oder Fahrt |
| `feedback` | Von dir markierter Fehler der Erkennung |
| `desk` | Meldungen der Bluetooth-Verbindung |
| `app` | Start und Ende |

Jede Zeile enthält die Rohsignale (`signals`), die Ableitung (`assessment`) und den Zustand des Regelwerks. Termintitel und Inhalte werden nicht gespeichert, nur die Bundle-IDs der Apps am Mikrofon.

**Fehler markieren:** Im Menü und im Statusfenster gibt es „Erkennung war falsch“ mit vier festen Einträgen und einer freien Notiz. Der Knopf „Bin im Meeting“ in der Ankündigung markiert ebenfalls einen Fehler.

## Einstellungen

Die wichtigsten Werte stehen im Statusfenster. Alle Werte stehen in `~/Library/Application Support/Stehauf/config.json`; die Bedeutung ist in `Sources/StehaufCore/Config.swift` dokumentiert. Nach einer Änderung an der Datei im Statusfenster „Neu laden“ drücken.

## Erster Test

1. Die App findet den Tisch und zeigt im Statusfenster eine plausible Höhe.
2. Tisch am Bedienpanel auf Sitzhöhe fahren und „Aktuelle Höhe übernehmen“ drücken, dasselbe für die Stehhöhe. Vorher fährt die App nicht.
3. „Hochfahren“, „Runterfahren“ und „Stopp“ im Statusfenster funktionieren.
4. Zum Ausprobieren `sitMinutes` in der Konfigurationsdatei auf 1 setzen: Ankündigung, Stupser und Fahrt beobachten.
5. Diktieren und einen Testanruf starten und prüfen, ob „Meeting“ im Statusfenster stimmt.

## Aufbau

| Ordner | Inhalt |
|---|---|
| `Sources/StehaufCore` | Protokoll, Erkennung und Regelwerk ohne macOS-Abhängigkeiten |
| `Sources/Stehauf` | Bluetooth, Sensoren, Menüleiste, Ankündigung, Statusfenster |
| `Tests/StehaufCoreTests` | Tests für den Kern (`swift test`, braucht Xcode) |

Das Bluetooth-Protokoll ist aus dem Python-Code dieses Repositories portiert (`linak_controller/gatt.py`, `linak_controller/desk.py`).
