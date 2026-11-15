# OurPort laundry website

Static Astro website with supplied OurPort imagery, a role-based inquiry, a room comparison and a working concept PDF download. Source documents outside this folder remain unchanged.

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
pnpm test:intake
```

The compiled website is in `dist/`. Serve it over HTTP; it uses root-relative links and is not intended to be opened as a `file://` document. No runtime JavaScript framework is shipped. The lockfile records the installed versions. Node 22+ is recommended; this build was checked with Node 24.

## Structure

- `src/pages/`: Home, Laundromats, Housing, Plan a Site, CCTV and WiFi/WAP.
- `src/layouts/`, `src/components/`, `src/styles/`: shared brand shell, workflow and styling.
- `src/content/site.ts`: shared navigation, workflow, contact and FAQ copy.
- `public/images/`: optimized copies of supplied OurPort artwork.
- `public/downloads/`: the unmodified three-page owner/builder working brief.
- `docs/market-and-copy-research.md`: market references, team requirements and editorial decisions.
- `docs/claims-register.md`, `docs/assets.md`: status and provenance.
- `supabase/functions/ourport-intake/`: validated intake endpoint for the shared company Supabase project.
- `supabase/migrations/`, `supabase/tests/`: dedicated OurPort inquiry storage, private notification outbox and database verification.
- `supabase/OURPORT-INTAKE.md`: backend contracts, permissions, notification setup and activation steps.
- `netlify/functions/`: retained legacy inquiry example; it is not hosted by GitHub Pages.

## Inquiry behavior

The form supports two build modes. An unset `PUBLIC_INQUIRY_MODE` selects **email**: the visitor reviews their details, opens an email draft, and sends it themselves. That mode does not automatically transmit or store the inquiry. Copy-details provides a fallback if no mail app is configured.

With `PUBLIC_INQUIRY_MODE=server`, the form sends reviewed inquiries to the Supabase Edge endpoint. Completed submissions require name, valid email and city/state. Optional progress sharing requires explicit consent and a valid email; partial drafts may omit name and location. Turning progress sharing off requests cancellation of pending draft notices, but does not erase details already shared or retract an email already sent. Request failures retain the entered details and provide email/copy alternatives.

The endpoint validates allowed fields, rejects inactive-branch fields, honeypots and unexpected origins, and bounds payload size. Database RPCs enforce consent, ownership, revisions, safe retries and quotas. Client roles receive no direct inquiry-table access. Company database administrators review inquiries in Supabase; existing portal roles do not automatically gain access. When notification dispatch is activated, the worker sends summaries to Mike and Joe.

The source includes these capabilities; it does not by itself prove that a deployed form uses server mode or that notifications are active. Record actual deployment and live verification separately.

## Deployment and online-intake activation

The public website deploys to GitHub Pages through `.github/workflows/deploy-pages.yml`. Its build runs both unit suites, compiles the six static pages, then checks local references and generated text assets for privileged credentials before upload. GoDaddy manages the domain. GitHub Pages does not execute the retained Netlify function.

Before enabling online intake:

1. Follow [the intake deployment guide](supabase/OURPORT-INTAKE.md) for the existing shared company Supabase project. Apply only the dedicated OurPort migrations and run the rollback-only database checks.
2. Deploy the intake Edge Function and verify allowed origins, storage receipts, quotas and denial of public table/RPC access. Keep privileged credentials exclusively in server-side configuration.
3. Provision and verify the sending provider/domain, configure the protected notification secrets, and separately activate the notification worker as described in the guide. Verify an actual submitted and consented unfinished inquiry, including provider evidence; provider acceptance alone does not prove mailbox delivery.
4. Set `PUBLIC_INQUIRY_MODE=server` in the production **build** environment. `PUBLIC_INQUIRY_ENDPOINT` can override the default shared-project Edge URL. These two public settings are not credentials; never prefix a secret with `PUBLIC_`.
5. Rebuild/deploy and verify the actual page mode and complete browser-to-storage-to-notification flow. Unit tests use mock storage and are not evidence of a live service.

For a local server-mode build after the backend is ready:

```sh
PUBLIC_INQUIRY_MODE=server pnpm build
```

Technical references: [GitHub Pages](https://docs.github.com/en/pages), [Supabase Edge Functions](https://supabase.com/docs/guides/functions), [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security).

## Before public launch

1. Review the current repository, hosting and DNS deployment records; confirm public use of the supplied concept imagery.
2. Confirm the preferred public brief. This build uses the Second Folder version because it includes the complete pickup step.
3. Add a credible full-bag deposit image when available. The attempted generation was unavailable; no unverified visual fit is implied.
4. Complete online-intake activation and live checks when using server mode, including staff access and failure paths. Confirm no public inquiry read is possible.
5. Decide inquiry retention and add the appropriate privacy notice for the actual hosting/processing setup.
6. Remove the preview `noindex` directive only for an approved public launch; set the verified canonical domain and preserve email DNS records.

Website publication does not establish real hardware fit, completed installations or working third-party integrations. Supplied imagery remains illustrative.
