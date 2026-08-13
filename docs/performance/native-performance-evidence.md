# Native performance evidence contract

A Ghostlight native performance run is measured only when every required evidence
gate is present and valid. Missing or malformed evidence produces a blocked receipt
and a nonzero exit status.

## Required evidence

- **Exact source:** the working tree is clean, the requested source matches `HEAD`,
  and the native raw receipt carries the same 40- or 64-hex commit identifier.
- **Direct selected UDP:** the client connects over direct LAN and every phase's
  selected WebRTC candidate pair reports `protocol=udp`. SSH forwarding remains a
  smoke path and cannot produce a measured receipt.
- **Causal X11/client pixels:** F8 is dispatched through the persistent X11
  `xdotool` channel, and the client video observer detects the resulting green
  fixture marker in decoded pixels for every attempt. A next-frame callback without
  the marker is not causal evidence.
- **WebRTC and dropped frames:** every phase has active decoded media, negotiated
  codec evidence, and finite decoded-frame, dropped-frame, and dropped-frame-ratio
  counters.
- **CPU and memory:** every phase contains timestamp-bounded viewer container CPU
  and memory samples plus process CPU attribution. The native receipt additionally
  requires samples from both `GhostlightApp` and newly launched WebKit processes.

CDP is optional diagnostics only. Enabling it may add diagnostic artifacts, but CDP
availability, attachment, and output never satisfy or block a required evidence gate.

## Commands

Run the deterministic evaluators before using the live harness:

```sh
node tools/test-evaluate-native-performance.mjs
node tools/measure-streaming-performance.mjs --self-test
node tests/acceptance/performance.mjs --self-test
```

The live harness defaults to direct LAN. Set
`GHOSTLIGHT_PERFORMANCE_SSH_TUNNEL=true` only for a TCP smoke run; that run will be
recorded as blocked for benchmark purposes.
