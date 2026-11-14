# Listigt

Inköpslista för iPhone med basvaror, EAN-scanning och delning via iCloud.

- **Inköpslista**: skriv eller scanna varor. Scannade koder slås upp i Open Food Facts; okända koder får du namnge en gång.
- **Basvaror**: läggs automatiskt på inköpslistan och kommer tillbaka vid varje *Ny inköpsrunda*.
- **Delning**: knappen uppe till vänster skickar en iCloud-inbjudan (som i Anteckningar). Ändringar synkas mellan alla som delar listan.

## Bygga

    xcodegen generate        # skapar Listigt.xcodeproj från project.yml
    open Listigt.xcodeproj

Koppla in iPhonen, välj den som mål och tryck ▶︎.

## Till en annan iPhone (TestFlight)

1. Skapa appen i App Store Connect med bundle-id `se.langseth.listigt`.
2. Xcode: Product → Archive → Distribute App → TestFlight.
3. **CloudKit-schemat måste publiceras till produktion** innan TestFlight-versionen kan synka:
   https://icloud.developer.apple.com → iCloud.se.langseth.listigt → Deploy Schema Changes.
   (Schemat skapas automatiskt i utvecklingsmiljön första gången appen körs och sparar data.)
4. Lägg till den andra personen som testare i TestFlight.

Webbversionen finns kvar i `web/`.
