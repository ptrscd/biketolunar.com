+++
title = "Colophon"
description = "How this site is built."
+++

How **BikeToLunar** is made.

## Built with
- **[Zola](https://www.getzola.org/)** — a fast static-site generator. Every page is plain HTML, built
  ahead of time.
- **No JavaScript.** Nothing here runs JS — dark mode follows your device via CSS, and the progress
  numbers are formatted at build time.
- **System fonts** — no web-font downloads, so pages load fast and private.

## Icons
- Brand logos from **[Font Awesome Free](https://fontawesome.com/license/free)** (CC BY 4.0) and
  **[Simple Icons](https://simpleicons.org/)** (CC0), inlined as SVG so they inherit the page colour.

## Look
- A light "Daylight Ride" theme with a sunrise-orange accent, plus an automatic dark mode.

## Data & maps
- **Weather** on ride posts comes from **[Open-Meteo](https://open-meteo.com/)** (CC BY 4.0), fetched by
  location and time from the ride's GPS track.
- **Route maps** are rendered from each ride's GPX with Apple **MapKit**.

## Hosting
- [add where you deploy — e.g. Netlify / Cloudflare Pages / GitHub Pages].

The total distance is summed at build time from a per-ride log (`data/distance.json`) generated from my
Garmin GPX files.
