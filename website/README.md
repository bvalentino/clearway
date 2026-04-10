# Clearway — Landing Page

Static landing page for Clearway, served at [getclearway.app](https://getclearway.app).

## Stack

- [Vite](https://vitejs.dev/) — dev server + build
- [Tailwind CSS v4](https://tailwindcss.com/) via `@tailwindcss/vite`

No framework, no JavaScript runtime — just HTML, CSS, and a logo.

## Development

All commands run from the `website/` directory.

```bash
npm install          # first time only
npm run dev          # dev server with HMR at http://localhost:5173
npm run build        # production build to ./dist
npm run preview      # serve ./dist locally to verify the build
```

`npm run dev` watches `index.html`, `src/input.css`, and `public/` — changes hot-reload in the browser automatically.

## Structure

```
website/
├── index.html          # entry point (Vite convention)
├── src/
│   └── input.css       # @import "tailwindcss";
├── public/             # static assets served from site root
│   └── logo.png        # → /logo.png
├── vite.config.js      # Vite + Tailwind plugin
├── package.json
└── dist/               # build output (gitignored)
```

- **`public/`** — files here are copied verbatim to `dist/` and served from the site root. Use for images, favicons, and anything referenced with an absolute path.
- **`src/`** — source files processed by Vite (CSS, future JS).
- **`index.html`** at the root is Vite's entry point; do not move it.

The logo (`public/logo.png`) is exported from the macOS app icon at `Sources/Assets.xcassets/AppIcon.appiconset/512.png`.

## Deployment

Deployed via [Cloudflare Pages](https://pages.cloudflare.com/) with Git integration.

**Project settings:**

| Setting                  | Value           |
|--------------------------|-----------------|
| Production branch        | `main`          |
| Root directory           | `website`       |
| Build command            | `npm run build` |
| Build output directory   | `dist`          |
| Framework preset         | Vite (or None)  |

Cloudflare runs `npm install` automatically before the build command. Pushes to `main` trigger production deploys; pushes to other branches get preview URLs.

The custom domain `getclearway.app` is configured in the Cloudflare Pages dashboard → Custom domains.
