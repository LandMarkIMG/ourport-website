# First-build verification

24 September 2026. Local preview and compiled Astro output.

- Four routes compiled successfully: `/`, `/laundromats/`, `/housing/`, `/plan-a-site/`.
- Static reference check: 67 local image, script, style, route and download references resolve; one H1 per page; images have alt text.
- Browser layout checks at 320, 390, 768 and 1280 pixels. A 320-pixel inquiry overflow was found and corrected; the corrected page was checked again at 320 pixels.
- Desktop and mobile visual review of supplied-image placement and text flow; both room-comparison states are concept-labeled. The comparison preserves the full supplied image.
- Mobile menu opens and closes; Escape closes it. Native FAQ disclosure opens.
- Room comparison changes the source image, caption, alt text and pressed-button state.
- Inquiry required-field errors are visible. Role switching reveals the appropriate questions and disables inactive branches. The review includes only active-branch answers.
- Synthetic test inquiry produced the expected mailto recipient, subject and body; no email was sent.
- Seven automated server tests passed: allowlisting, required and bounded values, honeypot, missing configuration, origin/content validation, repeat-safe storage request and honest storage-failure handling.
- No browser console errors were observed in the tested flows.

Not verified: a deployed database write, database access under real public credentials, deployed Netlify rate-limit enforcement, staff notifications, mail-app delivery, domain/DNS, real hardware fit, third-party APIs or customer app behavior. These are outside the current local preview.

The current form runs in email mode. Server tests use mock storage and are not evidence of a live inquiry service.
