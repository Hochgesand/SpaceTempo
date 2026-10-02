# SpaceTempo

SpaceTempo bietet zwei Modi für den Wechsel zwischen macOS Spaces:

- **Sofortwechsel:** überspringt die seitliche Animation. Kein Neustart, kein root und keine SIP-Änderung; benötigt die macOS-Bedienungshilfen-Freigabe. Für macOS 26.6+ und macOS 27.
- **Animationsdauer:** erhält die seitliche Animation und verkürzt sie beispielsweise auf ungefähr 0,5×. Dieser ältere, experimentelle Modus benötigt weiterhin die unten beschriebene SIP-Ausnahme und den genau geprüften Dock-Build.

## Sofortwechsel verwenden

1. Die App aus dem [neuesten Release](https://github.com/Hochgesand/SpaceTempo/releases) laden oder mit `make app` bauen. **SpaceTempo.app nach Programme kopieren** und dort öffnen.
2. Im Reiter **Sofortwechsel** auf **Freigabe anfragen** klicken.
3. In **Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen** SpaceTempo erlauben. Die App darf damit Eingaben erzeugen und globale Gesten verarbeiten. Es werden keine Tastatureingaben gespeichert.
4. Gegebenenfalls über das Menüleistensymbol **SpaceTempo beenden** und erneut öffnen, damit macOS die neue Freigabe übernimmt. Ein Mac-Neustart ist nicht nötig.
5. Zuerst einen **Test nach links/rechts** auf einem Bildschirm mit mehreren Spaces durchführen.
6. **Sofortwechsel aktivieren** übernimmt Ctrl + ←/→ sowie horizontale Trackpad-Gesten. Die MX-Master-Fensternavigation verwendet üblicherweise diese Kurzbefehle und muss separat mit der Maus geprüft werden.

Die App übernimmt die nativen Desktop-Kurzbefehle ausschließlich in der laufenden Sitzung und schreibt keine Tastatur-Voreinstellungen. Beim Ausschalten oder Beenden werden die vorherigen Zustände zurückgesetzt. Ein separater, benutzerlokaler Wächter stellt sie auch beim Absturz der App wieder her. Der Wächter läuft nur zusammen mit der App. Der optionale Autostart wird als normales macOS-Anmeldeobjekt eingerichtet.

Bei fehlender Freigabe, aktivierter sicherer Eingabe oder einem Fehler der Eingabeüberwachung wird der Sofortmodus abgelehnt beziehungsweise beendet. Falls macOS sichere Eingabe nach einer Passwortabfrage festhält, hilft gegebenenfalls einmal sperren und entsperren. Die App deaktiviert diese Sicherheitsfunktion nicht.

Der Sofortmodus verwendet private macOS-Gestenformate, die Apple ändern kann. Ein erfolgreicher Ereignisversand allein ist kein Nachweis: Die Testknöpfe prüfen die tatsächliche Space-ID und weitere 500 ms Stabilität, um einen unerwarteten Rücksprung zu erkennen. Diese Prüfung misst keine Animationsdauer. Der normale Eingabemodus wartet nicht auf diese Testprüfung und unterstützt schnelle aufeinanderfolgende Wechsel.

## Fenster schließen, Autostart und Einstellungen

SpaceTempo läuft als Menüleisten-App. **Der rote Schließen-Knopf und ⌘W schließen nur das Einstellungsfenster; der Sofortwechsel bleibt aktiv.** Über das Symbol mit den zwei Rechtecken in der Menüleiste lassen sich die Einstellungen wieder öffnen, der Sofortmodus umschalten oder die App ausdrücklich beenden. Ein erneutes Öffnen aus Programme zeigt ebenfalls die Einstellungen.

**Beim Anmelden starten** registriert die installierte App bei macOS. Beim nächsten Login startet sie im Hintergrund und aktiviert den zuletzt eingeschalteten Sofortmodus wieder, sobald die Bedienungshilfen-Freigabe und die Eingabeüberwachung verfügbar sind. Dafür muss die App unter `/Applications/SpaceTempo.app` liegen. Eine gegebenenfalls nötige Freigabe zeigt macOS unter **Allgemein → Anmeldeobjekte & Erweiterungen** an.

Sofortmodus, Dauer-Regler und ausgewählter Reiter werden automatisch in den Benutzer-Einstellungen gespeichert. **SpaceTempo beenden** stellt die nativen Kurzbefehle wieder her, behält aber die gewünschte Einstellung für den nächsten Start. **Sofortwechsel ausschalten** speichert dagegen den ausgeschalteten Zustand.

Zum Entfernen zuerst **Beim Anmelden starten** ausschalten, dann **SpaceTempo beenden** und die App in den Papierkorb verschieben.

## Status des Modus „Animationsdauer“

Experimentelle Version 0.1.0 für **Apple Silicon und den Dock-Build von macOS 27.0.1 (26A434)**. Beide enthaltenen arm64e-Slices werden anhand ihrer UUID geprüft; die gesamte Dock-Datei muss außerdem exakt den geprüften SHA-256 besitzen. Andere Versionen werden abgelehnt, bis sie separat geprüft und freigegeben wurden.

```text
b704affba65f732ffd6676c3bb22c94abc737ee73af8bdf29a5ef02650cde33e
```

**Gebaut und offline geprüft, noch nicht am laufenden Dock angewendet.** Auf dem Entwicklungssystem ist SIP vollständig eingeschaltet. Ein erfolgreicher Build und die Tests sind kein Nachweis für einen fehlerfreien Live-Eingriff. Es werden keine Kompatibilitätsversprechen für andere macOS-Versionen gemacht.

Die vorsichtige Prüfung aller Thread-Stacks kann auch bei ruhendem Dock einen Eingriff ablehnen, wenn sich ein Stack nicht vollständig nachvollziehen lässt. Diese Laufzeitprüfung ist noch nicht gegen den echten Dock-Prozess verifiziert.

## Bauen

Voraussetzung: Apple Silicon, aktuelle Xcode Command Line Tools mit Swift 6 und macOS SDK.

```sh
make test
make check
make app
open dist/SpaceTempo.app
```

`make check` liest Dock und den Systemschutz; es verändert nichts. Die App wird lokal ad hoc signiert, nicht mit einem Apple Developer ID signiert oder notarisiert. Der Build benötigt keine Drittanbieterbibliotheken.

## Einrichtung

**Dieser Recovery-Schritt betrifft ausschließlich den Modus „Animationsdauer“. Für Sofortwechsel ist er nicht erforderlich.**

SpaceTempo benötigt **root und ausgeschaltete SIP-Debugging-Beschränkungen**. Die App schaltet SIP niemals selbst aus. Dieser Schritt kann nicht in einer normalen macOS-Sitzung erledigt werden.

Das ist eine echte Änderung am Systemschutz: Prozesse, die bereits als root laufen, können anschließend auf geschützte Apple-Prozesse zugreifen. Auf Apple Silicon senkt diese SIP-Anpassung außerdem die Boot-Policy auf *Permissive Security*. Sie schaltet nicht den gesamten SIP-Schutz aus; andere SIP-Bestandteile, FileVault und Gatekeeper werden von SpaceTempo nicht umgestellt.

Wenn du diese Änderung bewusst vornehmen möchtest:

1. Arbeit speichern und den Mac ausschalten.
2. Einschalttaste gedrückt halten, bis die Startoptionen erscheinen.
3. **Optionen → Fortfahren** wählen und gegebenenfalls das Volume entsperren.
4. In Recovery **Dienstprogramme → Terminal** öffnen.
5. Den folgenden Befehl ausführen und den Rückfragen folgen:

   ```sh
   csrutil enable --without debug
   ```

6. Neu starten, SpaceTempo öffnen, **0,50×** einstellen und **Anwenden** klicken.

macOS fragt nach einem Administratorpasswort. Die App bekommt dieses Passwort nicht; die Abfrage wird vom System ausgeführt. Es werden keine entitlements installiert, keine dauerhaften root-Dienste eingerichtet angelegt. Das optionale Anmeldeobjekt startet lediglich die normale App ohne root-Rechte.

Während der Anwendung wird eine root-eigene Sperrdatei `/var/run/space-tempo.lock` verwendet, um gleichzeitige Änderungen zu verhindern. Sie enthält keine Konfiguration oder Zugangsdaten.

## Bedienung

- **0,50×**: ungefähr halbe Animationsdauer.
- **0,25× bis 1,00×**: einstellbarer Faktor; **1,00×** stellt Originalcode wieder her.
- **Original wiederherstellen**: Patch entfernen.
- **Prüfen**: Kompatibilität und SIP-Status erneut lesen.

Der Effekt gilt **bis Dock neu startet**, beispielsweise beim Abmelden oder Neustarten. Danach erneut anwenden. Das Beenden der App selbst setzt den Patch nicht zurück. Der Autostart wendet diesen privilegierten Dock-Patch nicht automatisch an.

Die Anzeige kann ohne Administratorrechte nicht immer feststellen, ob der laufende Dock-Prozess bereits verändert ist. Sie zeigt diesen Zustand dann als unbekannt; die Rücksetzfunktion prüft nach der Administratorabfrage erneut.

### Kommandozeile

```sh
.build/local/space-tempo-cli check
.build/local/space-tempo-cli status
sudo .build/local/space-tempo-cli apply 0.5
sudo .build/local/space-tempo-cli revert
```

`apply` und `revert` ändern den Arbeitsspeicher des Dock-Prozesses. `check` und `status` sind reine Leseoperationen. Der Zugriff auf Dock wird bei vollständig aktiviertem SIP abgelehnt, auch mit root.

## Rückgängig machen

Zuerst **Original wiederherstellen** verwenden. Falls die Anwendung oder Rücksetzung fehlschlägt, kann ein Neustart von Dock den ausschließlich im Arbeitsspeicher vorhandenen Patch entfernen:

```sh
killall Dock
```

Dock wird dabei beendet und von macOS neu gestartet. Anschließend die App löschen, falls sie nicht mehr benötigt wird. Den SIP-Schutz kannst du in Recovery mit dem folgenden Befehl auf die Standardkonfiguration zurücksetzen und danach neu starten:

```sh
csrutil clear
```

## Berechnung und Prüfungen

Dock führt eine diskrete Feder aus, keine einfache Animation mit einer Dauer in Sekunden:

```text
velocity = retention * velocity + gain * (target - position)
position = position + velocity / refreshRate
```

SpaceTempo skaliert die Eigenwerte dieser Dynamik auf den Exponenten `1 / durationFactor`. Daraus werden neue Werte für Dämpfung und Verstärkung berechnet. Die Referenz ist 120 Hz. Bei 0,5× ergeben Simulationen mit den verwendeten Abbruchschwellen ungefähr **53–56 %** der ursprünglichen Abschlusszeit bei 60–144 Hz. Der Faktor ist eine Skalierung der Dynamik, keine garantierte Millisekundendauer; Anfangsgeschwindigkeit, Abbruchschwellen und Bildwiederholrate beeinflussen die tatsächliche Dauer.

Die Tests prüfen Eingabevalidierung, eine unabhängige Formel für 0,5× und Stabilitätssimulationen über 60–144 Hz. Die Offline-Prüfung kontrolliert den konkreten Dock-Build, die Patchstellen und die ursprünglichen Instruktionen. Unbekannte, teilweise veränderte oder fremde Patches dürfen nicht überschrieben werden. Der Live-Patch suspendiert Dock nur während der Speicherschreiboperation und wird vor dem Fortsetzen überprüft.

Ein Integrationstest verwendet ausschließlich eine eigene, nicht ausgeführte Speicherseite des Testprozesses: Er prüft Schreiben, Rücksetzen, ARM-Cache-Flush und die Wiederherstellung der RX-Speicherrechte. Ein absichtlich teilweise fehlgeschlagener Schreibvorgang prüft den Rollback; eine Seite ohne Ausführungsrecht wird ohne Schreibvorgang abgelehnt. Diese Tests greifen nie auf Dock zu und benötigen keine Administratorrechte.

## Herkunft

Die technische Analyse der Space-Feder von [bisak/SpaceSwitchSpeed](https://github.com/bisak/SpaceSwitchSpeed/blob/main/docs/REVERSE-ENGINEERING.md) war der Ausgangspunkt für die Untersuchung des lokalen Dock-Binaries. Der C-Patch für den Modus „Animationsdauer“ ist eine eigenständige Implementierung ohne übernommenen Programmcode dieses Projekts. Der tatsächliche lokale Build wurde separat disassembliert und seine beiden Slices geprüft.

Der Sofortmodus adaptiert die MIT-lizenzierte Gestenserzeugung von [noswoosh](https://github.com/mmathys/noswoosh), einschließlich der dort genannten Vorarbeiten von InstantSpaceSwitcher und iss. Die vollständigen Hinweise stehen in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) und liegen der App bei. Der eigene Quellcode steht unter der MIT-Lizenz. Apples Dock-Binary wird nicht mitgeliefert.
