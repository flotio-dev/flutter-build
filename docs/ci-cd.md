# CI and image publication

Pull requests validate `build.sh`, scan the source and Dockerfile, then build
and scan the real amd64 and arm64 images without publishing. Pushes to `main`
publish those exact scanned platform images, assemble the immutable
`ghcr.io/flotio-dev/flutter-build:sha-<full-git-sha>` manifest, attach both SPDX
SBOMs and provenance to its digest, and verify the attestations.

`latest` is retained only as a compatibility alias for existing consumers and
points to the same digest as the immutable SHA manifest. New consumers should
pin `ghcr.io/flotio-dev/flutter-build@sha256:<digest>`. A strict `vX.Y.Z` tag
adds an alias to an already-attested SHA manifest without rebuilding.

No repository secret is required. `GITHUB_TOKEN` receives Packages write only
in jobs capable of publication; OIDC and attestation permissions exist only in
the multi-architecture manifest job. No GitOps or Kubernetes access is used.

Source findings have no exception. Image-only exceptions live in
`.trivyignore-image`; every entry names the CVE and has an owner, justification
and expiration. The current entries expire on 2026-11-18 and cover only
non-executable Ubuntu kernel headers plus libraries embedded in Google's latest
Android tooling. Expired entries make the scan fail and must be removed or
renewed explicitly after a documented review.

Configure main-branch protection with required `ci-success`, protect `v*` tags,
enable Secret Scanning, Push Protection and Dependabot security updates, and
restrict Actions to approved publishers with full-SHA pinning.

Local checks:

```bash
bash -n build.sh
trivy fs --scanners vuln,misconfig,secret --severity HIGH,CRITICAL --exit-code 1 .
docker build -f flutter-build.Dockerfile -t flutter-build:local .
trivy image --severity HIGH,CRITICAL --exit-code 1 \
  --ignorefile .trivyignore-image flutter-build:local
actionlint .github/workflows/ci.yaml
```
