# PDF fonts

IBM Plex Sans (Regular, Medium, SemiBold, Bold) and IBM Plex Mono (Regular,
Medium), used by `src/lib/documents/branded-pdf.ts` for invoices, billing
packets and statements.

- Source: the official `@ibm/plex-sans` 1.1.0 and `@ibm/plex-mono` 2.5.0
  npm packages (`fonts/complete/woff/`), copied **unmodified**.
- License: SIL Open Font License 1.1 (`OFL-LICENSE.txt`). Embedding the fonts
  in generated PDFs is permitted; pdf-lib embeds only the glyphs a document
  uses.
- Deployed with the server code via `outputFileTracingIncludes` in
  `next.config.ts`. If they can't be read at runtime, the PDFs fall back to
  Helvetica rather than failing.
