# Recall dashboard scaffold

Navigation and honest placeholder pages for the family dashboard. No API requests, telemetry, sample measurements, or simulated rover states are included.

Requires Node.js 20.19+ or 22+ and npm. From `web/`:

```sh
npm ci
npm run dev
npm run build
npm run preview
```

`VITE_API_BASE` is reserved in `.env.example` for future integration; this scaffold does not consume it.

Routes: `/`, `/changes`, `/map`, `/objects`, `/patrols`, `/evals`, `/about`. Production hosting must rewrite unknown paths to `index.html` for direct route visits. Vite development and preview servers provide that fallback.

Appearance follows the device setting by default, with light/dark overrides saved locally when storage is available. Semantic navigation, visible focus indicators, route titles, skip link, and focus transfer to main content support keyboard navigation. Local fonts avoid external requests.

Full page features, API loading/error handling, live announcements, before/after interaction, maps, and evaluation charts are deferred. VoiceOver verification requires a human on a Mac.
