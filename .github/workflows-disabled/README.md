# Disabled standalone CI

GitHub Actions workflows and Dependabot config in this directory used to run
from `evalops/ghostlight`. Canonical source is now
[`evalops/mono`](https://github.com/evalops/mono) at `products/ghostlight`
([import PR](https://github.com/evalops/mono/pull/9056)).

GitHub only runs workflows from `.github/workflows/` and only reads Dependabot
from `.github/dependabot.yml`. Files here must stay out of those paths so this
repository cannot publish, re-run standalone CI, or open dependency pull
requests. Component checks live in `evalops/mono` `components/ghostlight.yaml`.
