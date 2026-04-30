# PDF Reference Library

Drop vendor PDFs (PANW deployment guides, Microsoft architecture papers,
whitepapers) into this directory.

The `*.pdf` binaries themselves are **gitignored** — they are vendor-copyrighted
material and must not be republished from this repository. Pull them locally
from the original publisher (e.g. <https://www.paloaltonetworks.com/referencearchitectures>)
as needed.

Tracked in git:
- `INDEX.md` — catalogue of every PDF expected here, with read-priority and a
  one-line summary scoped to this project.
- `README.md` — this file.

Suggested filename convention (for `INDEX.md` parsing):

```
{publisher}_{topic}_{version-or-year}.pdf
```

Examples:
- `panw_azure-transit-vnet-deployment-guide_v2.pdf`
- `panw_vm-series-deployment-guide_pan-os-11.pdf`
- `ms_azure-front-door-architecture-2024.pdf`

After adding a PDF locally, update `INDEX.md` with a one-line summary so future
readers can decide whether to open it without scanning every page.
