# Browser für Apple TV

Ein einfacher Web-Browser für das Apple TV. Du kannst jede Adresse eingeben oder suchen, Lesezeichen speichern und mit einem Zeiger über die Siri Remote surfen. Vorinstalliert sind Lesezeichen für SRF Sport, SRF News, Play SRF, SRF Meteo, Google und Wikipedia.

> Der Browser nutzt die versteckte Web-Komponente von tvOS (private API). Für den Eigengebrauch funktioniert das, im App Store wäre er nicht erlaubt. Ein künftiges tvOS-Update könnte ihn kaputt machen.

## Bedienung

| Fernbedienung | Wirkung |
|---|---|
| Über das Touchpad wischen | Zeiger bewegen (am Rand scrollt die Seite mit) |
| Touchpad / Mitte drücken | Klicken |
| Oben / unten am Ring drücken | Ein Stück nach oben / unten scrollen |
| **⏯ Play/Pause** | **Menü öffnen** |
| Zurück (‹ bzw. MENU) | Vorherige Seite. Auf der ersten Seite: Browser verlassen |

**Im Menü:**
- **Adresse oder Suche eingeben:** Mit `srf.ch/news` öffnest du die Seite. Alles andere, z. B. `Wetter Zürich`, wird gegoogelt.
- **Lesezeichen:** Seite öffnen, aktuelle Seite hinzufügen oder Lesezeichen löschen
- **Startseite**, **Vorwärts**, **Neu laden**
- **Scroll-Modus:** Wischen scrollt die Seite statt den Zeiger zu bewegen. Mit einem Klick beendest du ihn wieder.
- **Grösser / Kleiner:** zoomt die Seite, damit sie vom Sofa aus lesbar ist
- **Diese Seite als Startseite**

Klickst du in ein Textfeld, erscheint die Tastatur. Auf dem iPhone erscheint dann meist eine Mitteilung, über die du bequem auf dem Handy tippen kannst.

Beim nächsten Start macht der Browser dort weiter, wo du aufgehört hast.

## Installation (mit geliehenem Mac)

**Voraussetzungen**
- Mac mit Apple-Chip (M1 oder neuer) und aktuellem macOS
- **Xcode** aus dem Mac App Store. Beim ersten Start **tvOS** als Plattform wählen. Xcode ist mehrere GB gross, lade es also vorher.
- deine **Apple-ID**. Mit der kostenlosen läuft der Browser 7 Tage, mit dem Entwicklerkonto (99 $/Jahr) ein Jahr.
- Mac und Apple TV im **selben WLAN**

**Schritte**
1. ZIP entpacken und `TVBrowser.xcodeproj` per Doppelklick öffnen.
2. Links das blaue Projekt **TVBrowser** anklicken → Target **TVBrowser** → **Signing & Capabilities**:
   - **Team:** deine Apple-ID wählen (falls sie fehlt: *Add an Account…*)
   - **Bundle Identifier:** auf etwas Eigenes ändern, z. B. `ch.deinname.tvbrowser`
3. Apple TV koppeln:
   - Am Apple TV: *Einstellungen → Fernbedienungen und Geräte → Fernbedienungs-App und Geräte* öffnen und dort bleiben.
   - In Xcode: *Window → Devices and Simulators*. Beim Apple TV auf **Pair** klicken und den Code vom Fernseher eingeben.
4. Oben in Xcode das Apple TV als Ziel wählen und auf **▶︎** klicken. Beim ersten Mal richtet Xcode das Apple TV ein paar Minuten lang ein.

Danach findest du „Browser“ auf dem Home-Bildschirm. Du kannst dich in Xcode unter *Settings → Accounts* wieder abmelden, die App bleibt drauf.

**Erst ausprobieren ohne Apple TV:** Wähle in Xcode als Ziel einen *Apple TV Simulator*. Eine virtuelle Fernbedienung bekommst du über *I/O → Input → Apple TV Remote*.

## Anpassen

Oben in `TVBrowser/BrowserViewController.m`:
- `kDefaultHomeURL`: Startseite beim ersten Start
- `BrowserDefaultBookmarks`: vorinstallierte Lesezeichen
- `kSearchURL`: Suchmaschine
- `kCursorSpeed`, `kScrollSpeed`, `kArrowScrollStep`: Tempo von Zeiger und Scrollen

## Wenn etwas nicht klappt

- **„Signing … requires a development team“:** In Schritt 2 wurde kein Team gewählt.
- **„Failed to register bundle identifier“:** Der Bundle Identifier ist schon vergeben. Wähle einen anderen.
- **Rote Fehler beim Bauen:** Mach einen Screenshot der Fehlerliste (links das ⚠︎-Symbol) und schick ihn Claude.
- **„Die Web-Komponente konnte nicht geladen werden“:** Deine tvOS-Version stellt die versteckte Komponente nicht bereit.
- **Live-Videos ruckeln:** Für Livestreams ist die offizielle **Play SRF**-App aus dem App Store zuverlässiger.
