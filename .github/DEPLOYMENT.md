# Deployment setup

The repository uses Cloudflare Pages Direct Upload from GitHub Actions. This keeps source control and deployment policy in one place. Cloudflare documents that a Direct Upload project cannot later be converted to Git integration; retain this model unless a new Pages project is deliberately created.

## One-time Cloudflare setup

1. Create two **Direct Upload** Pages projects in the same Cloudflare account:
   - `tinyprune` → `tinyprune.com` and `www.tinyprune.com`
   - `tinyprune-docs` → `docs.tinyprune.com`
2. Add those custom domains in each Pages project and make the DNS records Cloudflare-proxied. Redirect `www.tinyprune.com` to `tinyprune.com` at the Cloudflare zone level.
3. Create an account-scoped API token with only **Account / Cloudflare Pages / Edit** access. Do not use a Global API Key.
4. In the GitHub repository, create the `cloudflare-pages-production` Environment. Store the Cloudflare account ID and API token as environment secrets named `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN`. Require a reviewer before production deploys once a maintainer group exists.

`website/` deploys to the `tinyprune` project. `docs/` deploys to the `tinyprune-docs` project. The workflow validates each static site before uploading it. A push to `main` deploys both Pages projects; manual runs can select one site.

## macOS release setup

Create a protected GitHub Environment named `release` (required reviewers, restricted to `v*` tags and `main`) and store these **environment secrets** (nothing else; never repository-level):

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | `base64 -i DeveloperID.p12` of the *Developer ID Application* certificate and private key |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID; the workflow refuses a certificate from another team |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID (Developer access or higher) |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect issuer UUID |
| `APPLE_NOTARY_PRIVATE_KEY_BASE64` | `base64 -i AuthKey_<ID>.p8` |

`release.yml` builds a universal binary with `swift Scripts/package-app.swift`, signs every component with the Developer ID identity (`TINYPRUNE_SIGN_IDENTITY`), hardened runtime and a secure timestamp, runs `Scripts/verify-signing.sh --release --pre-notarize`, notarizes and staples the app, re-verifies with Gatekeeper/stapler checks, builds and notarizes the DMG, and verifies the app inside the mounted DMG. The identifier and Team ID policy is in `ADRs/0004-signing-identifier-policy.md`. Locally, `swift Scripts/package-app.swift && Scripts/verify-signing.sh .build/package/TinyPrune.app` checks the ad-hoc development build.

After the signed DMG exists, add the Sparkle appcast signing key as a separately protected environment secret and publish the generated appcast to the website deployment. Sparkle may only be linked into the app, never the agent, CLI, or Finder extension (`verify-signing.sh` enforces this). The Homebrew cask release remains a separate protected workflow because it must ship a build with Sparkle automatic checks disabled.
