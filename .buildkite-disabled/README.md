# Disabled standalone Buildkite pipeline

This pipeline targeted the standalone `evalops/ghostlight` repository and the
retired `hetzner-linux-heavy` queue. Canonical source is now
[`evalops/mono`](https://github.com/evalops/mono) at `products/ghostlight`
([import PR](https://github.com/evalops/mono/pull/9056)).

Buildkite only loads `.buildkite/pipeline.yml`. Keep this directory out of
`.buildkite/` so the standalone pipeline cannot run. Component checks live in
`evalops/mono` `components/ghostlight.yaml`.
