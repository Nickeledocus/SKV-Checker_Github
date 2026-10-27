# SKV Certificaat Checker

Klein Windows-programma om bij de SKV API te controleren of een combinatie van
**UBN** (Uniek Bedrijfsnummer) en **AM91-nummer** (certificaatnummer) een geldig
kwaliteitscertificaat heeft.

- 1 UBN en 1 tot 5 AM91-nummers per controle
- Haalt zelf een bearer-token op (gebruikersnaam en wachtwoord uit een configuratiebestand)
- Per regel: groen ✓ gelukt, oranje ! let op, rood ! fout
- Dubbelklik op een regel voor het volledige JSON-antwoord en om de certificaat- en stallijst-PDF op te slaan
- Exporteren van het overzicht naar een `.txt`-bestand

Geschreven in Windows PowerShell 5.1 met Windows Forms. Er hoeft niets
geïnstalleerd te worden.

## Installeren

1. Download de code: groene knop **Code** → **Download ZIP**.
2. Klik met de rechtermuisknop op de zip → **Eigenschappen** → vink **Blokkering opheffen** aan (als die optie er staat) → **OK**.
3. Pak de zip uit naar een map die alleen van jou is, bijvoorbeeld `C:\Tools\SKV-Checker`.
4. Kopieer `appsettings.example.json` naar `appsettings.json` en vul daarin de URL's, je SKV-gebruikersnaam en je wachtwoord in.
   (Vergeet je dit, dan maakt het programma bij de eerste start zelf een `appsettings.json` aan en vraagt het je die in te vullen.)
5. Dubbelklik op **Start SKV Checker.bat**.

Zie [LEESMIJ.txt](LEESMIJ.txt) voor de uitgebreide uitleg en oplossingen bij problemen.

## Bestanden

| Bestand | Doel |
|---|---|
| `Start SKV Checker.bat` | Start het programma |
| `Start SKV Checker (met foutmeldingen).bat` | Start het programma en laat foutmeldingen zien |
| `SKV-Checker.ps1` | Het programma zelf |
| `appsettings.example.json` | Voorbeeld van de instellingen (zonder wachtwoord) |
| `appsettings.json` | Jouw eigen instellingen |

## Instellingen (`appsettings.json`)

| Veld | Uitleg |
|---|---|
| `TokenUrl` | Adres waar het bearer-token wordt opgehaald |
| `CertificaatUrl` | Adres van de certificaatcontrole |
| `Username` / `Password` | Je SKV-inloggegevens |
| `TokenMethod` | `GET`, `POST` of `AUTO` (eerst POST, dan GET) |
| `TimeoutSeconds` | Maximaal wachten op SKV, in seconden |

Benodigde URL's, gebruikersnaam en wachtwoord zijn op te vragen bij de auteur. Deze gegevens zijn aan een bedrijf gebonden!
