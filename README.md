# OurPort laundry website

First website build, 24 September 2026. Four static Astro pages with local supplied imagery, an accessible role-based inquiry, a room comparison and a working concept PDF download. Source documents outside this folder are unchanged.

## Preview

```sh
pnpm install --frozen-lockfile
pnpm dev
```

Local address: `http://127.0.0.1:4321/`.

```sh
pnpm build
pnpm check:site
pnpm test
```

The compiled website is in `dist/`. Serve it over HTTP; it uses root-relative links and is not intended to be opened as a `file://` document. No runtime JavaScript framework is shipped. The lockfile records the installed versions. Node 22+ is recommended; this build was checked with Node 24.

## Structure

- `src/pages/`: Home, Laundromats, Housing, Plan a Site.
- `src/layouts/`, `src/components/`, `src/styles/`: shared brand shell, workflow and styling.
- `src/content/site.ts`: shared navigation, workflow, contact and FAQ copy.
- `public/images/`: optimized copies of supplied OurPort artwork.
- `public/downloads/`: the unmodified three-page owner/builder working brief.
- `docs/market-and-copy-research.md`: market references, team requirements and editorial decisions.
- `docs/claims-register.md`, `docs/assets.md`: status and provenance.
- `netlify/functions/`, `supabase/migrations/`: optional server inquiry foundation, not connected to an account.

## Inquiry behavior

Default mode is **email**: required details are validated, shown for review, then placed into a mailto draft addressed to the contact supplied in the team chat. The visitor must send that email. Nothing is automatically transmitted or stored. Copy-details provides a fallback if no mail app is configured. No analytics or tracking scripts are installed.

Server mode is disabled until a destination is verified. To activate it, confirm the intended Netlify site, Supabase sales-inquiry project, recipient/staff workflow and retention policy. Apply the included migration, set server-only secrets and `ALLOWED_ORIGIN`, then build with `PUBLIC_INQUIRY_MODE=server`. Never prefix a secret with `PUBLIC_`.

The endpoint validates an allowlist, removes inactive-branch fields, rejects honeypots and unexpected origins, bounds payloads, uses a repeat-safe request ID and has a declared Netlify IP/domain rate limit. It returns success only after storage accepts the record. Browser failures retain the entered details. The database denies anonymous and authenticated public access; only the server-side service role writes. The rate rule, database grants and end-to-end write still require deployed verification.

Technical references: [Astro on Netlify](https://docs.astro.build/en/guides/deploy/netlify/), [Netlify rate limits](https://docs.netlify.com/manage/security/secure-access-to-sites/rate-limiting/), [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security).

## Before public launch

1. Confirm repository, hosting account, current DNS and public use of concept imagery. No account, DNS or domain changes have been made.
2. Confirm the preferred public brief. This build uses the Second Folder version because it includes the complete pickup step.
3. Add a credible full-bag deposit image when available. The attempted generation was unavailable; no unverified visual fit is implied.
4. Activate and test the lead destination, staff access and failure path. Confirm no public lead read is possible. Current tests use mock storage only.
5. Decide inquiry retention and add the appropriate privacy notice for the actual hosting/processing setup.
6. Remove the preview `noindex` directive only for an approved public launch; set the verified canonical domain and preserve email DNS records.

This is a local review build, not a claim that OurPort hardware, software integrations or service operations are live.
