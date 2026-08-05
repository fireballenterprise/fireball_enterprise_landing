# fireball_enterprise_landing

Landing site for `fireballenterprise.com` — directs visitors to the Fireball Enterprise brand
sites and social profiles. Static site (Vite + Tailwind CSS), deployed to S3.

## Local development

```bash
npm install
npm run dev
```

Or from `fireball_orchestrator`: `uv run --no-sync invoke landing.view`.

## Build

```bash
npm run build
```

Outputs static files to `dist/`.

## AWS setup

Infra setup tooling (S3 bucket, CloudFront, ACM cert, IAM OIDC role, Route 53) lives in
`fireball_orchestrator`, not here — see `scripts/aws/fbe/` and
`topics/landing/docs/setup_aws.md` in that repo.

## How the pieces fit together

- **Tailwind CSS** — utility classes written directly in `index.html`; generates the stylesheet
  (`@theme` in `src/style.css` holds the Fireball brand colors).
- **Vite** — bundles `index.html` + the generated CSS into the static `dist/` output; also runs
  the local dev server with live reload.
- **Node.js** — only runs the build/dev tooling above. Not needed at runtime — `dist/` is plain
  static files, served from S3 with no server-side code.
