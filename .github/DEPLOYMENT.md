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

Create a protected GitHub Environment named `release` and store only these environment secrets:

- `DEVELOPER_ID_CERTIFICATE_P12_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`
- `APPLE_NOTARY_PRIVATE_KEY_BASE64`

The release workflow intentionally refuses to run until the native Xcode project and its `scripts/release/verify-version.sh` and `scripts/release/create-dmg.sh` packaging scripts exist. That prevents a tag from publishing an unsigned or un-notarized placeholder artifact.

After Phase 0 creates the native package, add the Sparkle appcast signing key as a separately protected environment secret and publish the generated appcast to the website deployment. The Homebrew cask release remains a separate protected workflow because it must ship a build with Sparkle automatic checks disabled.
