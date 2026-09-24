# OurPort laundry website: market, copy and UI notes

Reviewed 24 September 2026 (UTC). First-party public pages and supplied team chat. Vendor statements are attributed marketing claims, not independently tested performance. No named company is an agreed OurPort partner.

## Direction for this build

**Smart lockers for a better laundry handoff.** Sell the useful service point first: drop off a bag, operator processes it, collect the finished order. OurPort's proposed position is a carefully planned physical handoff that fits the room and the operator's workflow. This positioning is an editorial recommendation, not proof of unique capability.

The strongest story is the room transformation. White backgrounds, navy headings, restrained blue and gold, generous image space and short paragraphs give the proposition room to breathe. Technical due diligence belongs behind the sales conversation, with enough visible detail to establish credibility.

## Market landscape

| Segment / reference | What the public material emphasizes | Implication for OurPort |
| --- | --- | --- |
| Service network: [Tide Cleaners lockers](https://tidecleaners.com/en-us/touchpoints/lockers) | Laundry and dry-cleaning access, an app-led sequence, and separate answers about collection, turnaround and notifications. | Make the physical flow easy to understand. Keep building access separate from service turnaround. OurPort's visitor is a buyer planning a site, so the primary CTA is a conversation, not app download. |
| Operator locker system: [Laundry Lockers by Highmark](https://laundry-lockers.com/locker/laundromat/) | Bag-sized compartments, add-on towers, operator workflow, quote request and operator control. The vendor also makes aggressive revenue and installation claims. | Show the real load and modular intent. Explain operator responsibility. Do not borrow ROI, installation time, warranties, dimensions or fee terms. |
| Customer UI: [Laundry Lockers app](https://laundry-lockers.com/download/) | Location finding, order status, price approval and ready-for-pickup alerts. | Future resident UX should make location, price acceptance and next action explicit. These are design requirements, not an OurPort app announcement. |
| Laundry software: [CleanCloud / Highmark announcement](https://www.cleancloudapp.com/blog/cleancloud-partners-with-laundry-lockers-by-highmark-to-offer-flexible-locker-solutions) | A dated 6 August 2025 announcement of a specific locker relationship. The announcement was available in the search index; direct text retrieval failed in this review. | Treat integration as an explicit pairing with an agreed scope. Ask what software the prospect has before promising dashboard compatibility. |
| Laundry operations platform: [Cents + Laundroworks](https://www.trycents.com/cents-laundroworks-integration) | Order, machine and payment information within a combined platform. The named integration is the core proposition. | Mike's dashboard concern matters commercially. OurPort copy should promise a compatibility review, not imply it is already that platform's partner. |
| General locker infrastructure: [Luxer One products](https://www.luxerone.com/smart-locker-solutions/) | Multiple markets, configurations, access and pickup interfaces. | Use clear audience routes. Keep laundry prominent rather than copying the full general-locker catalogue. |

## Mike and Alex: operative September 23 direction

Source: `../../OurPort_Codex_Build_Packet/source/WhatsApp_Ourport_chat.txt` and matching full-media export in `/Users/landmark/Documents/WhatsApp Chat - OurPort/`.

| Time | Direction | Applied in the site |
| --- | --- | --- |
| Mike, 10:25 / 10:55 | Apartment and student housing are the first outreach area. | Dedicated housing page and direct homepage path. |
| Mike, 11:09–11:13 | A separate laundromat presentation; laundry first. | Dedicated laundromat page, no unrelated verticals. |
| Mike, 11:40 | The prospect's dashboard is a concrete concern. | Compatibility question and optional system-name field; no named integration claims. |
| Alex, 13:45–13:54 | Make full laundry-bag fit visually credible. | Bag fit is a prominent copy point. A new bag-in-locker illustration remains outstanding; image generation was unavailable. Existing room views are labeled concepts. |
| Mike, 13:49 / 14:02 | No build underway yet; cabinet choice remains open. | No fixed dimensions, production claims or implied installed client. |
| Alex, 14:28 | Images, existing setup, location count and contact capture. | Large imagery; short contact-first inquiry with optional setup fields. |
| Mike, 15:57 / 17:21 | Approves the room direction; Heritage Suds is a placeholder. | Reuse room concepts without making the placeholder a public customer name. |

## Copy changes and boundaries

| Avoid | Use instead | Why |
| --- | --- | --- |
| “24/7 laundry service” | “Drop-off and pickup beyond staffed processing hours, where site access permits.” | Building access is different from processing availability. |
| “Seamless integration with your dashboard” | “We review your system and required order events before agreeing an integration.” | No verified interface contract yet. |
| “Guaranteed revenue / no extra labor” | “Give customers another way to leave and collect orders.” | The commercial result depends on demand, staff and turnover. |
| “OurPort washes your laundry” | “Your operator controls pricing, processing and customer care.” | Preserve responsibility. |
| “Installed at Heritage Suds” | “Illustrative room concept.” | Both clean-room and locker-wall views are concepts. |
| Generic parcel-locker catalogue | “Start with the full bag and finished order.” | Laundry changes the capacity question. |

## UI research translated into the website

- **Audience routing:** two plain homepage choices; no login or resident account requirement for prospects.
- **Image + message:** room context makes placement understandable. No dense spec sheet or financial infographic in the first viewport.
- **Simple flow:** three public steps, with acceptance, pricing and exceptions described only where useful.
- **Form:** role, contact and location first; optional role-specific setup second. Visible labels, grouped controls, in-place errors, review before sending. This follows the [USWDS form guidance](https://designsystem.digital.gov/components/form/).
- **Current preview behavior:** prepares an email draft to the supplied Mike address; it does not claim a lead has been stored. Server submission is a separate configuration, disabled by default.
- **Small screens:** single-column reading order, visible menu button, large controls, no hover-only interaction, no autoplay or carousels.
- **Comparison control:** two clearly named buttons instead of a precision slider; keyboard accessible and usable on touch screens.

Tide's public page was reviewed visually in the browser; Laundry Lockers' public navigation and content hierarchy were inspected through its accessibility tree. No customer account, private dashboard or mobile app was accessed. Remaining research is supplier/API diligence, not needed to review this first marketing build.
