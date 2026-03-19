# Advantix Branding Guide

## Purpose

Advantix is positioned as a premium event ticketing brand for premieres, live entertainment, and flagship onsales, with a global-ready presentation and a demo event mix that leans toward major North American markets. In this pretix demo, the brand layer is public-storefront only. Control/admin, transactional email, invoices, and PDF ticket output stay on standard pretix styling in v1.

## Brand Idea

The core mark is a ticket-shaped `A` with film-strip and perforation cues. The shape ties directly to ticketing without leaning on generic cinema icons. The visual direction is cinematic, premium, and slightly theatrical: midnight surfaces, warm metallic gold, and restrained ivory contrast.

## Canonical Source Artwork

These SVGs in `advantix-branding/` are the editable source assets:

- `advantix_icon_mark.svg`
  Use for favicon, app icon, avatar, and square mark applications.
- `advantix_wordmark.svg`
  Use for pretix organizer/event header image uploads.
- `advantix_logo_primary.svg`
  Use for dark-surface hero, social, and presentation applications.
- `advantix_logo_light.svg`
  Use for light-surface documentation and internal presentation applications.

The small favicon SVGs are reference exports only:

- `advantix_favicon_32.svg`
- `advantix_favicon_16.svg`

Advantix storefront headers are rendered directly from the committed static SVG through the theme override. Favicon and social surfaces remain raster-oriented in pretix settings, so those should continue to use the PNG exports listed below.

## Approved Color Tokens

- Midnight: `#0A0E1A`
- Dark surface: `#141828`
- Primary gold: `#C9972A`
- Highlight gold: `#F5C842`
- Champagne highlight: `#FFE085`
- Ivory background: `#F7F5F0`
- Success accent: `#2F7A62`
- Danger accent: `#A43A32`
- Muted silver: `#8A95B0`

## Typography Direction

- Brand voice: classic serif display styling carried mostly by the logo artwork.
- Runtime UI: keep the default pretix sans stack for body copy and form UI.
- Theme layer headings: use system serif stack only, `Georgia, "Times New Roman", serif`.
- Do not add an external webfont in v1.

## Pretix Mapping

Storefront settings that carry the brand:

- `primary_color` -> `#C9972A`
- `theme_color_background` -> `#F7F5F0`
- `theme_color_success` -> `#2F7A62`
- `theme_color_danger` -> `#A43A32`
- storefront organizer/event header -> static `advantix-wordmark.svg`
- `organizer_logo_image` -> Advantix wordmark PNG fallback upload
- `organizer_logo_image_inherit` -> enabled on events
- `favicon` -> square icon PNG source
- `og_image` -> social preview PNG on event pages
- `organizer_homepage_text` -> branded organizer landing hero/content
- `frontpage_text` -> branded event hero/content
- `banner_text` -> demo-only notice copy

Theme code lives in:

- `src/pretix/plugins/advantixtheme/`
- `src/templates/pretixpresale/base.html`
- `src/templates/pretixpresale/organizers/index.html`

## Production Export Matrix

Committed runtime exports live in:

- `src/pretix/plugins/advantixtheme/static/pretixplugins/advantixtheme/assets/advantix-header-wordmark.png`
  Purpose: organizer/event header image upload
  Source: `advantix_wordmark.svg`
- `src/pretix/plugins/advantixtheme/static/pretixplugins/advantixtheme/assets/advantix-icon-source.png`
  Purpose: favicon/app icon source for pretix thumbnailing
  Source: `advantix_icon_mark.svg`
- `src/pretix/plugins/advantixtheme/static/pretixplugins/advantixtheme/assets/advantix-social-preview.png`
  Purpose: organizer Open Graph image and event social preview upload
  Source: `advantix_logo_primary.svg`

## Usage Rules

- Prefer the wordmark for storefront headers.
- Prefer the square icon for favicon/app contexts.
- Keep the mark on midnight or ivory backgrounds only.
- Preserve the gold gradient and do not flatten it to a single-tone yellow.
- Do not stretch the wordmark or crop the ticket-shaped `A`.
- Keep enough padding around the logo so the perforation details remain legible.

## Demo Copy Direction

Use English only in v1. Copy should sound polished and ticketing-focused, not corporate-SaaS oriented.

Preferred categories for seeded content:

- film premieres
- arena and theater onsales
- comedy weekends
- live music showcases
- destination events

## Deploy and Maintenance

The AWS demo deploy copies the committed PNG exports into `/data/branding/` on the EC2 host and seeds pretix settings from those raster files. If branding changes:

1. Update the SVG source files in `advantix-branding/` if the artwork changes.
2. Regenerate the committed PNG exports in `src/pretix/plugins/advantixtheme/static/pretixplugins/advantixtheme/assets/`.
3. Update theme CSS or seeded copy if the runtime presentation changes.
4. Rerun `deployment/aws-demo/deploy-demo-ec2.sh` to push the app and refresh seeded branding assets.

This file is the source of truth for which asset is authoritative and where it is used in the pretix demo stack.
