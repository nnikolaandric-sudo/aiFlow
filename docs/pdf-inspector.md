# PDFInspector — lokalno čitanje PDF-a za AI agente

Port ideje [firecrawl/pdf-inspector](https://github.com/firecrawl/pdf-inspector)
(MIT) u Swift/PDFKit — bez Rust/Python/Node runtime-a, jer je FinderFlow
self-contained app bez spoljnih zavisnosti.

## Zašto postoji

Jev (TypeSafe System One) i chat modeli u AI Organizeru moraju da **pročitaju
dokument pre preimenovanja** — broj fakture, dobavljač, datum izdavanja.
Umesto da svaki PDF ide na skupi OCR servis, PDFInspector prvo klasifikuje:

```
PDF stigne
  → PDFInspector ga klasifikuje (~20ms uzorkovanjem)
  → text_based + visok confidence?
      DA → lokalna ekstrakcija (~150ms), gotovo
      NE → selektivni on-device OCR samo za stranice bez teksta (Vision, ništa se ne uploaduje)
```

## Gde živi kod

| Sloj | Fajl | Koristi |
| ---- | ---- | ------- |
| App (Jev + AI) | `FinderFlow/PDFInspector.swift` | `PDFInspector.processPDF(url:)` → `PDFInspectorResult` |
| AI prompt | `AIContentReader.describe` (u `AIOrganizerEngine.swift`) | `PDFInspector.describe(url:size:maxChars:)` → `(preview, details)` |
| CLI za agente | `tools/pdf-inspect/main.swift` + `run.sh` | `pdf-inspect faktura.pdf --json` |

App i CLI dele istu logiku (klasifikacija, Markdown, OCR prag) — ako menjaš
jedno, promeni i drugo.

## Swift API (za buduće agente u app-u)

```swift
let r = PDFInspector.processPDF(url: url)   // ceo dokument, sa OCR fallbackom
r?.pdfType        // .textBased | .scanned | .imageBased | .mixed
r?.confidence     // 0.0–1.0
r?.pagesNeedingOcr // [3, 7] — 1-indexed, za rutiranje
r?.markdown       // čist Markdown (liste, naslovi, spojene reči, bez TOC tačaka)
r?.excerpt(maxChars: 4000) // AI izvod: "Datum: … | Kupac: …"
r?.details        // ["12 pages", "title “Ugovor”", "scanned, text read by OCR"]
r?.toJSON(pretty: true)    // snake_case JSON kao upstream Python binding
```

Opcije (`PDFInspectorOptions`): `strategy` (`.sample(8)` default, `.full`,
`.earlyExit`, `.pages([1,3])`), `ocrMissingPages`, `ocrMaxPages` (default 4),
`maxFileBytes` (80 MB), `textThreshold` (40 alnum znakova).

## CLI (za Claude Code, Codex, Cursor i sve buduće agente)

```sh
./tools/pdf-inspect/run.sh faktura.pdf --json | jq .pdf_type
./tools/pdf-inspect/run.sh sken.pdf --excerpt 4000
./tools/pdf-inspect/run.sh ugovor.pdf --select-pages 1-3 --json --pretty
./tools/pdf-inspect/run.sh --build-only   # samo binary u build/local/pdf-inspect
```

| Flag | Efekat |
| ---- | ------ |
| (bez flaga) | Markdown sa headerom na stdout |
| `--json` | JSON envelope (`pdf_type`, `confidence`, `page_count`, `pages_needing_ocr`, `markdown`, `title`, `ocr_used`) |
| `--pretty` | uvučen JSON (uz `--json`) |
| `--raw` | samo Markdown, bez headera (kao `pdf2md --raw`) |
| `--excerpt N` | AI izvod do N znakova (`"a \| b \| c"`) |
| `--detect` | samo klasifikacija: `mixed (0.75), 12 pages` |
| `--select-pages 1,3,5-10` | samo date strane |
| `--no-ocr` | bez Vision OCR-a (samo tekstualni sloj) |

JSON primer:

```json
{
  "confidence": 1.0,
  "markdown": "## Faktura 123-45\nTelekom Srbija ...",
  "ocr_used": false,
  "page_count": 2,
  "pages_needing_ocr": [],
  "pdf_type": "text_based",
  "title": "Faktura"
}
```

## Razlike vs upstream Rust lib

- Nema Rust toolchaina, PDFium-a ni ONNX modela — PDFKit + Vision koji već
  postoje na svakom Mac-u (macOS 14+).
- Nema koordinata (`--items-json`): PDFKit ne daje pozicije povoljno, pa
  tabele nisu rectangle-based nego heurističke (višestruki razmaci, liste).
- Nema CID/ToUnicode ručnog dekodiranja — to radi PDFKit.
- Cap od prvih 60 strana za excerpt (AI prompt ionako uzima prvih ~4000
  znakova); `--select-pages` čita i ostalo.
- Sve lokalno: nema telemetrije, naloga ni mrežnih poziva (kao ostatak app-a).

## Upstream kredit

Ideja, imena polja (`pdf_type`, `pages_needing_ocr`), strategije uzorkovanja
i "single document load" princip su iz `firecrawl/pdf-inspector` (MIT).
Benchmark upstream-a (200 PDF-a, Apple M4 Pro): overall 0.875, reading order
0.915, brzina 0.470s — naš port cilja isti "smart routing" efekat unutar
ograničenja PDFKit-a.
