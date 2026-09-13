# Contributing

Contributions are welcome after the initial architecture stabilizes.

Before every commit to this public repository, run the security audit:

```bash
bash scripts/audit-public-repo.sh
```

Install the included Git hook once per clone to enforce that rule automatically:

```bash
git config core.hooksPath .githooks
```

Before submitting a change, also run:

```bash
swift test
bash scripts/audit-public-repo.sh
bash scripts/build-app.sh
```

Do not bypass the security hook without resolving its finding. Do not commit
models, runtime builds, audio recordings, transcripts, signing keys,
provisioning profiles, or user-specific paths. New user-facing features must
update `docs/PRODUCT_SCOPE.md` and include deterministic tests. Do not copy
another dictation product's code, assets, branding, sounds, or documentation.

Configure GitHub's private-email option or a project-safe no-reply address
before committing if you do not want an email address embedded permanently in
public Git metadata. Review both author and committer metadata before pushing.

Report suspected vulnerabilities through GitHub's private vulnerability
reporting flow as described in [SECURITY.md](SECURITY.md), not in a public
issue. See [the building and release guide](docs/BUILDING_AND_RELEASE.md) for
artifact and release requirements.
