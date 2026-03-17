# Reliability Hardening Checklist

## Automated Verification
- [x] `xcodebuild -scheme Porch -destination 'platform=iOS Simulator,name=iPhone 17' test` passed on 2026-03-16.
- [x] Network coverage includes `/v1/models`, request normalization, request body shape, SSE parsing, fallback behavior, and empty-response handling.
- [x] View-model coverage includes send, regenerate, stop, partial persistence on cancel and post-token failure, and validation retry behavior.
- [x] Persistence coverage includes chat snapshot values, message ordering, delete cascade, and app settings parameter/model round trips.

## Manual iPhone Validation
- [ ] First launch from a clean install.
- [ ] Local network permission prompt appears and the configured local server remains reachable after approval.
- [ ] Validate and refresh models against the Mac-hosted server.
- [ ] Send, stop, and regenerate all behave correctly on device.
- [ ] Long responses surface truncation cleanly and preserve any partial stop result.
- [ ] Offline server and server-error cases show actionable error messaging.
- [ ] App relaunch restores prior chats and partial messages.
- [ ] Same Wi-Fi URL pass completed.
- [ ] Existing VPN or tunnel URL pass completed, if available.

## Notes
- Automated hardening is complete; the remaining work is the real-device manual pass.
- No tunnel-specific product work was added in this phase.
