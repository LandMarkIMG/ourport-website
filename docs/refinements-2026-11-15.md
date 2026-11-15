# OurPort interaction refinements — 15 November 2026

The public site is an Astro static build on GitHub Pages at https://ourport.us. GoDaddy manages the domain. This update preserves the existing navy, powder blue and gold presentation and supplied illustrative concepts.

## Visitor experience

- The homepage action leads to a small planning chooser: laundromat, housing, or builder/developer. Each selection shows relevant preparation questions and carries the role into the existing inquiry page.
- The laundromat explorer remains manually controlled. Comparison images, captions, alternative text and status agree; larger controls and scoped keyboard handling improve use with touch and keyboard.
- Navigation dismisses with Escape, outside interaction and focus changes. Mobile layout resets correctly across the menu breakpoint. Hover and focus feedback respects reduced-motion preferences.

Research informed the interaction direction, without reusing proprietary artwork or code: [USM guided starting points](https://www.usm.com/en-uk/how-to-buy/configurator), [Miele staged planning](https://www.miele-professional.co.uk/s/planning-consultancy-3413), and [W3C interaction-animation guidance](https://www.w3.org/WAI/WCAG22/Understanding/animation-from-interactions.html).

## Supabase boundary

The website currently prepares an email draft. It does not submit or store inquiries in Supabase, and the new chooser keeps only its current selection in page memory. No customer account or order feature was added.

The existing SQL migration enables row-level security on `site_inquiries`, revokes access from `anon` and `authenticated`, and defines no public policies. This is source evidence, not a current inspection of deployed database grants. The dashboard required sign-in during this review.

The optional server function is not hosted by GitHub Pages. Activating stored inquiries would require a deployed endpoint, verified rate limiting, live permission checks, a staff workflow and retention rules. Elevated Supabase keys must remain exclusively on the server because they bypass RLS. See [Supabase API keys](https://supabase.com/docs/guides/getting-started/api-keys) and [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security).

The deployment validation scans generated text assets for elevated Supabase keys, service-role JWTs and private-key material before Pages upload. Public publishable/anon keys are not treated as privileged secrets. This reduces accidental exposure; it is not a complete security audit.

## Local verification

- Six routes built successfully. Static references, image alternative text, heading structure and generated-text secret checks passed.
- All seven existing inquiry tests passed; server storage tests use mocks.
- Browser review at 1365px and 390px; all six routes checked at 320px without horizontal overflow. Lazy images below the viewport were not treated as failed downloads.
- Planner role changes and native radio keyboard selection worked. The builder action selected the matching inquiry branch; synthetic details produced a correct review and email link. No email was sent.
- Carousel Before/With OurPort captions and state, Home/End navigation, next-slide controls, desktop menu Escape/outside dismissal, and mobile nested-menu dismissal were exercised.
- No browser warnings or errors were captured in these local checks.

The public site's existing search-indexing setting and email-only behavior are unchanged. Production publication is tracked by the GitHub Pages workflow and verified separately after deployment.
