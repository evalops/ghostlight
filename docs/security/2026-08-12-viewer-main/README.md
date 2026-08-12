# Main viewer image security receipt

This directory records the public viewer image built from Ghostlight main commit `518b3bc2274cbc115322d6fde35cf7d23bdb8b22` by GitHub Actions run `31628573668`.

## Image identity

- Tag: `ghcr.io/evalops/ghostlight-viewer:sha-518b3bc2274cbc115322d6fde35cf7d23bdb8b22`
- Index: `sha256:bc657e706af0615606fd6837f8ccfb1bd1d6f013b8dafb765ef08ea973a7d327`
- Linux amd64: `sha256:e33428f6b138fbe3cead6cf3d9b83b10ae8d45261ef61badcbab4b493b97013c`
- Linux arm64: `sha256:5886f85b575060f32bc12c060b5881bbddabbe0cc0273526f9173a7c2ca9d7df`

An empty Docker configuration resolved the public tag to the index digest in this receipt.

## Files

- `transcript.txt` contains the commands and results for image resolution, manifests, labels, Neko version, health, SPDX SBOMs, SLSA provenance, and vulnerability scans.
- `trivy-linux-amd64.json` contains the reduced Trivy 0.73.0 result for the exact amd64 child.
- `trivy-linux-arm64.json` contains the reduced Trivy 0.73.0 result for the exact arm64 child.
- `SHA256SUMS` records the SHA-256 digest of each other file in this directory.

The Trivy JSON files retain the immutable image reference, scanner version, OS, image identifier, scan targets, and vulnerability arrays. Each vulnerability array is empty. The exact reduction filter is recorded in `transcript.txt`.

## Scope

The scan command selected the vulnerability scanner, severities `HIGH,CRITICAL`, and `--ignore-unfixed`; `--exit-code 1` made a matching finding fail the command. Both exact child scans exited successfully with zero matching findings.

The amd64 child reported Neko `v3.1.5` at upstream commit `395ca1a6f62b7b0e270e654d366a2d57b8042efd` and returned `true` from `/health`. The receipt verifies the arm64 manifest, labels, SBOM subject, provenance subject, and vulnerability result. It does not contain a native arm64 boot test.

The repository runtime at the time of capture pinned the earlier index `sha256:9c822dfd7713953af6a443960376fc59e3fd478fd3047c7880d0f0a5ad6d9e9f`. This directory records the later main-derived artifact and does not claim that Compose used it.
