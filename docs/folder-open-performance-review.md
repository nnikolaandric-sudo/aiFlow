# Review performansi otvaranja foldera

**Datum:** 25.09.2026  
**Aplikacija:** aiFlow 2.4.0  
**Commit:** `875f96b`  
**Platforma:** macOS 26.5.1, Apple Silicon, arm64  
**Build:** `Release` iz `./build-local.sh`

## Zaključak

Default List view ima dobru arhitekturu za normalne foldere: klik na folder ne izvodi dodatni `stat` jer `FileItem` već postoji, navigacija odmah koristi in-memory snapshot kada je dostupan, a teški sort i čitanje metapodataka su van main threada.

Najveći problem nije sam double-click, nego **stalna revalidacija keširanog foldera**. Svaki povratak na keširani folder i dalje u pozadini ponovo enumeriše direktorijum, čita metadata za sve stavke i pravi novi niz `FileItem` objekata. Za folder sa 20.000 stavki to je u izmerenom pipeline-u približno **331 ms p95**, iako je trenutni snapshot sposoban da se prikaže za približno **14 ms p95**.

Za 100 stavki performanse su odlične. Za 1.000 stavki listing pipeline je prihvatljiv. Za 2.500 stavki postaje granično prihvatljiv za brzu navigaciju, a za 20.000 stavki potpuna revalidacija treba da bude izbegnuta ili značajno ograničena.

## Šta je mereno

Test fixture je privremeni direktorijum van repozitorijuma:

| Fixture | Direktnih stavki |
|---|---:|
| `small-000` | 100 |
| `medium-000` | 1.000 |
| `large-000` | 2.500 |
| `flat-20000` | 20.000 |

Benchmark je pokrenut pet puta po fixture-u i merio je isti osnovni pipeline koji koristi `loadItems`/`loadFreshItems`:

1. `FileManager.contentsOfDirectory`
2. `URL.resourceValues` za metadata svake stavke
3. paralelni `FileItem` build
4. folder/file particija
5. sortiranje po imenu

Posebno su izdvojeni:

- **Cold pipeline:** prvi prolaz kroz fixture, bez app-level `DirectoryCache` snapshota.
- **Warm paint:** ponovno sortiranje već postojećeg snapshota bez disk I/O.
- **Revalidation:** ponovna enumeracija i ponovni metadata build, kao background provera keša.

To nije potpuni input-to-paint benchmark niti pravi UI frame-time benchmark. Xcode Instruments nije dostupan u ovom okruženju jer je izabran Command Line Tools, a end-to-end klik automatizacija je bila pogođena istovremeno aktivnim instaliranim i lokalnim `aiFlow` procesima. Zato su brojevi pipeline-a odvojeni od statičkog review-a UI putanje.

## Rezultati

Vremena su u milisekundama; p50 je medijan pet merenja, p95 je gotov uzorak od pet merenja.

| Folder | Cold p50 | Cold p95 | Warm paint p50 | Warm paint p95 | Revalidation p50 | Revalidation p95 |
|---|---:|---:|---:|---:|---:|---:|
| 100 stavki | 1,69 | 1,73 | 0,06 | 0,07 | 1,78 | 1,84 |
| 1.000 stavki | 18,30 | 18,73 | 0,65 | 0,67 | 18,21 | 18,77 |
| 2.500 stavki | 43,78 | 44,16 | 1,55 | 1,60 | 43,54 | 43,76 |
| 20.000 stavki | 327,78 | 331,94 | 13,05 | 13,70 | 330,74 | 333,73 |

### Interpretacija

- **100 stavki:** nema merljivog problema u listing pipeline-u.
- **1.000 stavki:** lista se može prikazati brzo; najveći rizik je dodatni UI/render rad, ne sam disk pipeline.
- **2.500 stavki:** sortiranje je relativno jeftino, ali metadata i fresh listing traju oko 44 ms. To je već blizu granice gde se korisnik može osetiti kao „kasni folder“.
- **20.000 stavki:** snapshot paint je dobar, ali ponovna revalidacija traje oko treć sekunde. Ako se korisnik brzo vraća kroz foldere, taj pozadinski I/O može blokirati novi klik, iako trenutni UI može ostati vidljiv.

## Click-to-open putanja

U default List view-u klik na red selektuje stavku, a double-click otvara folder:

- `aiFlow/NativeFileTable.swift:226-230` — selekcija reda.
- `aiFlow/NativeFileTable.swift:316-319` — double-click callback.
- `aiFlow/ContentView.swift:2108-2112` — fast path: ako je `FileItem.isBrowsableFolder`, menja se samo `currentPath`.
- `aiFlow/ContentView.swift:455-492` — `currentPath` resetuje selection/filter state, čuva snapshot ili prikazuje loading, poziva `reload()` i Git refresh.
- `aiFlow/ContentView.swift:2213-2339` — keširani i cold put.

Ovo je dobro jer `navigateItem` ne radi novi disk upit. Najskuplji deo se tek pokreće kroz `reload()`.

## Pozitivne odluke u kodu

### 1. Keširan snapshot daje brz paint

`DirectoryCache.cachedItems(for:showHidden:)` vraća postojeći `FileItem` snapshot odmah, čak i kada je snapshot zastareo. `_reload` za male foldere prvo postavlja `rawFiles`, a tek nakon toga pokreće fresh revalidation.

- `aiFlow/DirectoryCache.swift:154-165`
- `aiFlow/ContentView.swift:2228-2297`

Za keširani folder od 20.000 stavki warm paint je u benchmark-u bio 13,70 ms p95 za sortiranje snapshota. To je znatno bolje od 333,73 ms p95 fresh pipeline-a.

### 2. Teški sort je van main threada

Za keširane foldere iznad 1.000 stavki sortiranje se izvršava na globalnom queue-u, a stari prikaz ostaje vidljiv dok novi snapshot ne dođe.

- `aiFlow/ContentView.swift:2231-2265`
- `aiFlow/ContentView.swift:140-141`

Ovo sprečava da `localizedCompare` na desetinama hiljada redova blokira main thread.

### 3. Metadata se čitaju paralelno

`buildItems` koristi `DispatchQueue.concurrentPerform` i zaseban autorelease pool za svaki URL.

- `aiFlow/FileItem.swift:1297-1315`

To je pravi izbor za I/O-bound metadata, uz ograničenje da `concurrentPerform` ne treba dozvoliti neograničen broj File Provider operacija.

### 4. AppKit tabela umesto SwiftUI `Table`

`NativeFileTable` koristi view-based `NSTableView`, fiksnu visinu reda i recikliranje ćelija. Sprečava raniji problem velikih SwiftUI diff-ova i automatskih row-height merenja.

- `aiFlow/NativeFileTable.swift:5-20`
- `aiFlow/NativeFileTable.swift:180-207`
- `aiFlow/NativeFileTable.swift:234-263`

### 5. Generacijski guard-ovi često sprečavaju stale publish

`reloadGeneration`, `largeSortGen` i provera `path == currentPath` sprečavaju da stari background load overiše novi folder.

- `aiFlow/ContentView.swift:2218-2224`
- `aiFlow/ContentView.swift:2257-2289`
- `aiFlow/ContentView.swift:2302-2317`

## Nalazi i prioriteti

### P1 — Keširani folder se uvek puno revalidira

**Lokacije:**

- `aiFlow/ContentView.swift:2298-2317`
- `aiFlow/ContentView.swift:2266-2289`
- `aiFlow/FileItem.swift:1423-1450`

`_reload` za svaki keširani folder pokreće `loadFreshItems`, čak i kada je `cachedURLs` validan. `loadFreshItems` namerno bypass-uje URL cache i uvek radi novu enumeraciju i novi `FileItem` build.

**Uticaj:** 20.000 stavki = približno 331 ms p95 pozadinskog rada. Kod brzog Back/Forward/tab klikanja taj rad se takmiči sa novim navigacionim loadom i može povećati latency sledećeg foldera.

**Preporuka:**

1. Uvesti eksplicitan `DirectoryCache` signal `needsRevalidation` umesto neuslovnog `loadFreshItems` na svaki cached navigation.
2. Snapshot prikazati odmah; fresh load pokrenuti tek nakon TTL-a, kada je directory stamp promenjen, kada je aplikacija dobila filesystem event ili kada korisnik eksplicitno refresh-uje.
3. Za česte local navigations koristiti kratki staleness window, npr. 1–2 sekunde, uz postojeći mehanizam za spoljne promene.
4. Meriti „time to first paint” i „time to fully fresh” odvojeno, ne samo ukupno trajanje background revalidacije.

### P1 — Folder sa 20.000 stavki nema dobar „fully ready” SLA

**Lokacije:**

- `aiFlow/FileItem.swift:1251-1289`
- `aiFlow/FileItem.swift:1300-1315`
- `aiFlow/ContentView.swift:2321-2337`

Cold put čita svaku stavku i pravi kompletan `FileItem` pre nego što se listing objavi. Benchmark pokazuje približno 328 ms p50 i 332 ms p95 za 20.000 stavki.

To je prihvatljivo kao pozadinski loading, ali nije prihvatljivo kao jedini model za veoma velike foldere. Ako korisnik odmah ponovo klikne ili scroll-uje, nema progresivnog prikaza delimičnog listinga.

**Preporuka:** uvesti tiered loading za foldere iznad konfigurisanog praga:

1. Brzo učitati URL listu i minimalne podatke potrebne za prikaz imena/direktorijuma.
2. Prvih 500–1.000 stavki prikazati odmah.
3. Metadata, badge i dodatne kolone učitavati u manjim batch-evima ili tek za vidljive redove.
4. Za 20.000+ stavki prikazati loading/progress ili korisnički limit bez obećanja da je listing potpuno gotov.

### P2 — Git refresh se pokreće na svakoj navigaciji

**Lokacije:**

- `aiFlow/ContentView.swift:489-492`
- `aiFlow/ContentView.swift:2213-2215`
- `aiFlow/GitService.swift:231-247`
- `aiFlow/GitService.swift:267-310`

`reload()` i `onChange(of: currentPath)` pozivaju `GitService.refresh`, a `git status --porcelain=v1 -uall -b -z` se izvršava u velikom repozitorijumu. Debounce od 250 ms sprečava lavinu, ali ne sprečava konkurenciju sa novim folder loadom.

**Preporuka:**

- Zadržati debounce, ali ga vezati za trenutni repo i prioritet navigacije.
- Uvesti minimalni fast status za badge, a `-uall` pokrenuti tek kada je potreban detaljan status ili kada korisnik otvori Git UI.
- Prekinuti ili prioritetno odbaciti stari Git refresh kada korisnik pređe u drugi repo.

### P2 — Folder size je ozbiljan I/O amplifier kada je uključen

**Lokacije:**

- `aiFlow/ContentView.swift:1863-1903`
- `aiFlow/ContentView.swift:1979-2042`
- `aiFlow/FolderSizeService.swift:122-147`

Opcija „Calculate folder sizes” je off po defaultu, što je dobro. Kada je uključena, svaka navigacija može pokrenuti rekurzivni walk po disku i progresivne publish-e.

**Preporuka:** ne pokretati rekurzivni walk za svaki folder automatski. Računati veličine samo za trenutno vidljive podfoldere, eksplicitno traženi folder ili kada je uključen size sort.

### P2 — Prefetch može takmičiti se sa korisničkim klikom

**Lokacije:**

- `aiFlow/DirectoryCache.swift:198-221`
- `aiFlow/DirectoryCache.swift:224-268`

Prefetch je serializovan i ima 350 ms debounce, što je već optimizacija. Ipak, čak i limit od 8 podfoldera može koristiti isti disk/URL metadata subsystem kao novi klik.

**Preporuka:** produžiti idle delay na 0,75–1,0 s, smanjiti limit na 2–4 i prekinuti prefetch ako se `currentPath` promeni. Za cloud/network lokacije postoji pravilan skip; isti princip treba primeniti i na lokalne foldere kada korisnik aktivno navigira.

### P3 — Per-visible-row badge i Git lookup nisu besplatni

**Lokacije:**

- `aiFlow/NativeFileTable.swift:605-624`
- `aiFlow/NativeFileTable.swift:629-691`
- `aiFlow/WorkspaceStore.swift:63-85`

Svaka reused ćelija radi Workspace badge lookup, ancestor walking i Git status lookup. Ovo nije glavni listing I/O, ali može uticati na scroll i prvi paint u workspace direktorijumima sa dubokom hijerarhijom.

**Preporuka:** cache badge po `FileItem.id` za trenutnu listing generations i računati batch badge mapu off-main.

## Prioritet implementacije

1. **Sprečiti unconditional full revalidation** keširanog foldera.
2. Uvesti progressive/tiered listing za >10.000 stavki.
3. Odvojiti Git fast status od detaljnog `-uall` statusa.
4. Ograničiti folder-size i subfolder prefetch na stvarni korisnički scenario.
5. Dodati instrumentaciju `click timestamp -> currentPath change -> first row paint -> fresh complete`; tek nakon toga meriti input-to-paint iz same aplikacije.

## Predloženi acceptance test

Testirati na lokalnom APFS disku, sa uključenim i isključenim „Calculate folder sizes”, u zasebnom Release procesu:

| Scenario | Očekivani rezultat |
|---|---|
| 100 stavki, cold | First paint <50 ms; fresh <100 ms |
| 1.000 stavki, warm Back/Forward | First paint <50 ms; nema praznog/spinner flickera |
| 2.500 stavki, warm Back/Forward | First paint <100 ms; fresh load ne blokira novi klik |
| 20.000 stavki, cold | Prvih 500–1.000 stavki vidljivo bez čekanja kompletnog metadata build-a |
| 20.000 stavki, warm | First paint <100 ms; nema unconditional 300+ ms revalidation sweep-a |
| Veliki Git repo | Navigacija ne čeka `git status -uall` |
| Folder sizes ON | Otvaranje foldera ne pokreće neočekivan rekurzivni walk svih podfoldera |

## Zaključna ocena

**Trenutno: 7/10 za normalne lokalne foldere, 4/10 za ekstremno velike foldere.**

Aplikacija je već napravlena svesno optimizovana za velike liste i keširanje. Najveći preostali dobitak nije u „bržem click event handleru“, već u tome da se posle keširanog otvaranja ne radi puni fresh metadata pass bez potrebe. Taj jedan zahvat bi najviše poboljšao realan osećaj brzine pri Back/Forward i tab navigaciji.
