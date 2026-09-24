# OurPort launch readiness

## Source and build

- GitHub repository: `ourport-website` (private unless Mike requests public access)
- Production build: `pnpm run build`
- Publish directory: `dist`
- Runtime: Node 20+
- Inquiry endpoint: `/.netlify/functions/site-inquiry`

## Supabase

Apply `supabase/migrations/202609240001_site_inquiries.sql` to the selected OurPort project. Configure the deployment environment with:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY` (server-side only; never expose in client code)
- `ALLOWED_ORIGIN=https://ourport.us`

Submit a production test inquiry and confirm one row appears in `site_inquiries` before changing DNS.

## GoDaddy activation

1. Record the current `ourport.us` DNS values before making changes, especially MX and TXT records used for email.
2. Add the apex and `www` records supplied by the production host. Do not replace mail records.
3. Add both `ourport.us` and `www.ourport.us` to the host; make the apex domain canonical.
4. Wait for the host to issue TLS, then verify HTTPS on all four routes.
5. Remove the temporary `noindex` directive only after the production form and HTTPS pass.

## Launch verification

- `/`, `/laundromats/`, `/housing/`, and `/plan-a-site/` return 200.
- Navigation and inquiry review work on mobile and desktop.
- Form success is reported only after Supabase accepts the record.
- Email draft fallback addresses `Mike@Monetize-that.com`.
- Browser console has no errors.
- Existing email delivery for `ourport.us` remains intact.
