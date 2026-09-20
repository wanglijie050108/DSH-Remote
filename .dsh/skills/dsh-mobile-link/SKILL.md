---
name: dsh-mobile-link
description: Use when working on the dsh-mobile-link project in this workspace — designing, implementing, reviewing, or extending the DSH plugin, the remotedsh-bridge server, the remotedsh-android app, or the remotedsh-contract share repo; when a task touches the WebRTC tunnel frame format, the dshlink:// pairing QR, the hello signature, pair lifecycle / boot_id, or the 127.0.0.1:13080 authority; and whenever you are about to re-derive a fact about this project or about the DSH internals it depends on, because most of those facts are already settled and some are verified against the live DSH source.
whenToUse: Any task in D:\DSP-mobile touching the remote-DSH-over-mobile feature.
---

# dsh-mobile-link — settled facts

This skill exists to stop re-derivation. The project's design was settled across four reviewed
documents, and its DSH-side assumptions were verified against the live installed DSH. Re-deriving
any of it from scratch wastes a review cycle at best and contradicts a signed-off decision at worst.

**Read the rule below before you propose anything "better".** Several tempting improvements were
proposed, argued, and rejected with reasons that are not obvious from the code.

## 0. Read this first: the three things you must not do

1. **Do not re-litigate §2.** Those are decisions with owners. Reversing one silently will break a
   promise made elsewhere in the design.
2. **Do not re-propose the 8 rejected items** listed in §5 without first refuting the recorded
   argument in `docs/04-未采纳项与理由.md` §三.
3. **Do not trust a fact in §3 because this skill says so — run the verifier.** §3's rows carry a
   source location precisely so the claim can be re-checked in seconds. DSH gets upgraded; the
   verifier is the authority, and this file is only the index.

```sh
node .dsh/skills/dsh-mobile-link/scripts/verify-dsh-facts.mjs
```

Any FAIL means a fact this project depends on has moved. Report it before writing code.

## 1. Sources of truth

Never edit these four; they are inputs, not notes. Resolve disagreements **in this order**:

| Order | Document | Holds |
|---|---|---|
| 1 | `docs/00-接口契约(2).md` (**v1.0.5**) | The only interface truth for all three components |
| 2 | `docs/01-DSH端插件实施方案(1).md` (v1.2) | Plugin form, lifecycle, module design, DoD |
| 3 | `docs/02-服务端实施方案(1).md` (v1.2) | Bridge / coturn / Caddy |
| 4 | `docs/03-APP端实施方案(1).md` (v1.2) | Android app |
| — | `docs/04-未采纳项与理由.md` | What was rejected and why (this is a **constraint**, not history) |
| — | `docs/05-开发计划.md` | Milestones G0–G4, the 12-week plan, deployment checklist |
| — | `审查报告-四文档一致性与可行性.md` | The audit that produced v1.0.3; §1 is the 24 DSH assertions |

A later-versioned document wins over an earlier one. **When the contract and an implementation doc
disagree, the contract wins** and the implementation doc has a bug — that is exactly how B-1…B-4
were found. If they disagree and you cannot tell which is stale, stop and say so.

**§7 of the contract is the only version-history entry point.** Its 确认 column reads
待三方会签 on purpose: the user is the requirement owner, not one of the three implementing
parties. Do not "fix" that column.

## 2. Settled decisions — do not silently reverse

| # | Decision | Set by | Why it matters |
|---|---|---|---|
| 1 | Grace period **T = 24 h** | user, 2026-09-12 | T is a **memory bound only**; `boot_id` carries all the semantics |
| 2 | Mobile authority is **fixed `127.0.0.1:13080`**, **no fallback, no runtime switch** | user, 2026-09-12 | Cookie name derives from authority; changing the port invalidates every cookie |
| 3 | **`boot_id`** is the restart predicate | user, 2026-09-12 | Replaces "how long was it gone" with "is it the same process" |
| 4 | Plugin is **always the offerer**; phone is always the answerer | contract §3.5 | The phone **MUST NOT** call `createDataChannel` — the message table has no app→agent offer, so it would force a renegotiation |
| 5 | **Two DataChannels**: `data` (ordered) + `ctl` (unordered) | contract §3 | Contained **head-of-line blocking**; `FIN` would be reordered ahead of the last `DATA` on a shared channel |
| 6 | **Single-phase ICE**, never "fall back to TURN after failing" | contract §4.3 | TURN credentials must be present **before the first gather**, or relay candidates are silently missing |
| 7 | **`webView.reload()` is a required path**, not a nicety | `docs/03` §4 | DSH's frontend gives up after 12.75–25.5 s while ICE `failed` may take ~30 s |
| 8 | **Bridge is presence-only** | `docs/02` §1 | No database, no business bytes. The closed `t` message set is what guarantees this |
| 9 | **Light shell for the app** in v1 | user, this session | Still requires E4; see §6 |
| 10 | **App has no Google/Go resourcing**; 2 developers | user, this session | Plugin and Bridge are one person's serial work → 12 weeks is the floor |

## 3. Verified DSH facts

Verified against the live install at `D:\npm-global\node_modules\@deepseek-ai\dsh\`. Paths below are
relative to `node_modules/@deepseek-ai/` (`…/` for short). **Re-run the verifier before relying on
any row marked ⚠.**

| # | Fact | Source |
|---|---|---|
| 1 | `/api` Host fence checks **only that the hostname is loopback — not the port** | ⚠ `…/dsh-client-connection/lib/index.js` `isTrustedApiRequest` |
| 2 | Cookie name = `dsh-auth-<base64url(sha256(authority))>`; authority **includes the port** | ⚠ same file, `cookieName` / `requestAuthority` |
| 3 | `GET /` without a valid cookie → **401**, emitted by `writeUnauthorized` (not a literal `return 401`) | ⚠ same file, `authorizeIndex` → `writeUnauthorized` |
| 4 | Token exchange requires **exactly** `GET` + `pathname === "/"` + **exactly one** `token` param → **303 + Set-Cookie**; any extra query param is fine | ⚠ same file, `authorizeIndex` |
| 5 | `ctx.webServer.port` is the **real listening port**; `ctx.webServer.host` returns the **configured** value (may be `0.0.0.0`) | `…/dsh-host-webserver/lib/index.js` (`get port` / `get host`) |
| 6 | `ctx.connection.authenticatedUrl(baseUrl)` returns this process's launch token as the sole query param, after clearing path/search/hash | ⚠ `…/dsh-client-connection/lib/index.js` `authenticatedUrl` |
| 7 | `/api/remote.mux`: heartbeat **2000 ms**, **2** consecutive missed pongs → `terminate()`; a binary frame → `close(1003)` | ⚠ `…/dsh-api-gateway/lib/index.js` |
| 8 | The mux **upgrade** passes the same fence | ⚠ same file |
| 9 | DSH frontend backoff is `500 ms / ×2 / max 10 s`; the last tier emits `disconnected` and **waits forever** → self-healing window is exactly **12.75–25.5 s** | ⚠ `…/dsh-client-connection/lib/client.js` |
| 10 | `online` / `offline` fire only on **system** network changes — they do **not** observe a dead tunnel | ⚠ same file |
| 11 | web profile sets **`patchReload: "live"`** → editing the plugin hot-reloads it **without** restarting the process | ⚠ `…/dsh-app-boot/lib/index.js` |
| 12 | A failed activation **fails DSH startup**; a row stuck in `FIBER_PENDING` (missing injected service) **counts as failed** | ⚠ same file, `assertEntriesActivated` |
| 13 | The fail-fast escape hatch is real: add `- id: mobile-link` + `disabled: true` to the profile patch | same file; profile templates document `disabled` |
| 14 | Bundle resolution walks the filesystem and **does not require `exports`** — `manifest` and patch are read by absolute path | `…/dsh-app-boot/lib/index.js` `resolveBundleDir` / `packageDirFromAnchor` |
| 15 | `dsh plugin --profile web add` forwards to pnpm (no pnpm → exit 127), then `reconcilePlugins` writes `dsh.profile.bundles` | `lib/plugin-*.js` |
| 16 | Changing `Host`: `/api*` → **403**, `GET /` → **401**, `/plugins/*` and dist assets → **200** | the fence + index authorization + static routes |
| 17 | `approval/request` is a **waterfall**; service name is **`approval`** | ⚠ `…/dsh-user-approval/lib/index.js` |
| 18 | `ctx.storage` is a **registry (hub), not a KV store**; records go through `ctx.storageDomain` | `…/dsh-storage`, `…/dsh-storage-domain` |
| 19 | A combined URL is `/plugins/??<id1>/client.js,<id2>/client.js,…`; largest single `client.js` is **620 160 B**; 48 of them ≈ **3.62 MiB** | `…/dsh-client-modules/lib/index.js` |
| 20 | web profile enables `compression: gzip` → **E1 must pin `Accept-Encoding` on both legs** | `…/dsh-web-app/cordis.patch.yml` |
| 21 | The 401 for an unauthenticated index is emitted by **`writeUnauthorized`**, and the fence/401 split is **`connection.requestRejection(req)`** — the mux upgrade calls it, so there is no separate inline check in the gateway | ⚠ `…/dsh-client-connection/lib/index.js` (`writeUnauthorized`, `requestRejection`) |

> Facts 1–21 are what `scripts/verify-dsh-facts.mjs` checks. Two naming traps that cost time when
> writing new checks: the unauthenticated status is `writeHead(401, …)` inside `writeUnauthorized`
> (**not** `return 401`), and `requestRejection` returns `403`/`401`/`undefined` from a ternary
> (**not** `return 401`). Anchor substring assertions on what the source literally says.

**werift API surface** (this is what makes DTLS pinning implementable — see §3.1): `RTCCertificate(privateKeyPem, certPem, signatureHash)`, `RTCConfiguration.certificates`, `PeerConfig.dtls.keys`, and `getFingerprints(): {algorithm, value}[]`. **Verified 2026-09-13 (werift↔werift loopback, `remotedsh-contract/scripts/poc-werift-loopback.mjs`):** `signatureHash` MUST be the `{hash, signature}` enum object `{hash: 4 /*HashAlgorithm.sha256_4*/, signature: 3 /*SignatureAlgorithm.ecdsa_3*/}` — the string `'sha-256'` constructs silently and the DTLS handshake then always fails (see §6 trap); non-trickle SDP carries all candidates after `setLocalDescription`; two labeled DataChannels (`data`/`ctl`) and 16373-byte frames work. Events are DOM-style properties (`pc.ondatachannel`, `ch.onopen`, `ch.onmessage`) or `Event.subscribe()` — assigning a bare function to the Event property throws at runtime. **Still unverified by anyone:** whether the injected certificate actually handshakes with `org.webrtc` (the Android half of G1), when `disconnected`/`failed` fire, and the real `bufferedAmount` curve.

### 3.1 The one fact that is a security anchor

`a=fingerprint` is a hash of the **whole certificate**, not of the public key. That is why the plugin
persists the **entire** DTLS certificate and key rather than re-deriving it — a re-derived
certificate has a different serial and validity window, so the fingerprint would change and every
phone's pin would break. Take `fp` from `getFingerprints()` (normalize `algorithm` to `sha-256`)
rather than computing a DER hash yourself.

## 4. Hard limits — memorize these numbers

| Constant | Value | Source |
|---|---|---|
| Frame header | **11 bytes**, big-endian: `ver u8`, `type u8`, `flags u8`, `stream_id u32`, `len u32` | contract §3.1 |
| Frame `ver` | `1`; anything else → disconnect and report | contract §3.1 |
| `flags` | **always 0**; sender MUST write 0, receiver MUST ignore non-zero | contract §3.1 |
| `len` | **≤ 16373** (so the whole frame ≤ **16384**, matching `maxMessageSize` semantics) | contract §3.1 |
| `stream_id` | allocated by the **phone**, from 1; **`PING`/`PONG` MUST use 0** | contract §3.1 |
| Frame types | `OPEN 0x01` `DATA 0x02` `FIN 0x03` `RST 0x04` `WINDOW 0x05` `PING 0x06` `PONG 0x07` | contract §3.2 |
| Credit | **256 KiB per direction per stream**, initial | contract §3.4 |
| `WINDOW.credit` | the **delta** of bytes actually written to the local socket since the last WINDOW — **not** a fixed 64 KiB | contract §3.4 |
| WINDOW trigger | every **≥ 64 KiB** written (and a final top-up before close) | contract §3.4 |
| Unsent queue | **256 KiB per stream**, **512 KiB global** | contract §3.4 |
| Global in-flight | **8 MiB** | contract §3.4 |
| Concurrent streams | **128** per tunnel; over that → `RST` the new `OPEN` | contract §3.4 |
| Tunnel keepalive | **PING every 5 s**, dead after **15 s** with no frame | contract §3.5 |
| Rebuild trigger | `connectionState` / `iceConnectionState` ∈ {`disconnected`, `failed`} (primary) + the 15 s fallback | contract §3.5 |
| Voluntary offer re-send | **≥ 2 s** apart, and **only** for spontaneous re-sends | contract §4.1 |
| `pair_token` | 32 B random → base64url, **single use, TTL 5 min** | contract §2, §4.4 |
| Signalling heartbeat | client **every 25 s**; server declares offline after **60 s** | contract §4 |
| `hello` deadline | **10 s** | contract §4.1 |
| TURN credential | `username = "<expire_epoch>:<pair_id>"`, `credential = base64(HMAC-SHA1(S, username))`, **TTL 3600 s** | contract §5 |
| Phone authority | `127.0.0.1:13080` | contract §1 |
| Plugin forward target | `127.0.0.1:<ctx.webServer.port>`, fallback `127.0.0.1:3080` | contract §1 |

## 5. The 8 rejected items — do not re-propose without refuting

Read `docs/04-未采纳项与理由.md` §三 for the full arguments. In short:

| Rejected | Counter-argument you must beat first |
|---|---|
| "Lower the tunnel death threshold to 6 s" | It replaces WebRTC's own failure detection with an app-layer timer, and the traffic cost was recomputed and found irrelevant |
| "Reserve credit for the mux stream" | It would make the transport layer aware of business semantics — the exact thing the tunnel is forbidden to do |
| "Add a tunnel epoch field" | `stream_id` restarting at 1 + dropping all old flow state is already semantically equivalent |
| "Delete `DSML_AUTHORITY`" | A readable authoritative value is still needed for the QR `a` field; instead it fail-fasts when it differs from the contract |
| "Close half-closed flows at tunnel teardown" | Partially accepted; the `OPEN`-reuses-live-`stream_id` case is deferred to v1.0.4 |
| "Re-`OPEN` the inner WS" as a fix | The DSH frontend already reconnects by itself; it solves nothing |
| "Tighten PING when flows are active" | Adds a state dimension for no measured benefit; revisit only if E9 shows a power problem |
| "Treat a single big flow as able to fill 8 MiB" | Credit refill is paced by the receiver actually writing to its socket, so the arithmetic was wrong |

## 6. The traps — where a correct-looking implementation is silently wrong

Each row is a bug that passes code review and fails in production.

| Trap | Correct behaviour |
|---|---|
| Using `ctx.webServer.host` | Use `.port`. The host getter is the **configured** value, possibly `0.0.0.0` |
| Treating `FIN` as a full close | `end()` / `shutdown(SHUT_WR)` and **keep reading and forwarding** — a request body ends with FIN and the response follows. A full close **silently truncates the response body** |
| Sending a fixed 64 KiB `WINDOW` | Send the **delta actually written**. A fixed value leaks credit and deadlocks the stream in ~43 rounds |
| Sending `FIN` on the `ctl` channel | `FIN` **MUST** ride `data` — it orders the end of this side's data |
| Treating `credential TTL` as needing renewal | TTL gates **new allocations** only. A working tunnel is kept alive by the client's Refresh. Renaming a `relay.request` into a "re-new" would kill a live tunnel |
| Gathering before ensuring credentials | Any new gather must be preceded by `relay.request` when credentials are missing or nearly expired, or relay candidates are **silently absent** |
| Re-sending `pair.ready` after every reconnect | Register **only** after `hello.ok{pair:null}` — otherwise every network blip prints a fresh QR |
| Emitting the QR before `pair.ready.ok` | Never render before the ACK; the user would scan an un-bindable QR that reports only `PAIR_NOT_FOUND` |
| Re-printing the QR after `pair.ok` | **MUST NOT.** The token is spent |
| Sending `bye` from every fiber disposer | Hot reload (`patchReload: live`) also disposes the fiber. Sending `bye` there destroys the pair and forces a re-scan — **the exact thing `boot_id` exists to prevent** |
| Generating `boot_id` per plugin instance | It **MUST** be process-level, or one hot reload looks like a DSH restart |
| Blocking inside a WebRTC callback | `onMessage` is push-style. Enqueue only; do the socket write elsewhere. Blocking stalls the whole `PeerConnection` |
| Swallowing or re-encoding the DSH WS | Byte-transparent only. DSH pings every 2 s and kills the mux after 2 misses; a binary frame means `close(1003)` |
| Signing `hello` with a hand-rolled string | `ts` = epoch **seconds, decimal integer**; `nonce` = 32 B → base64url; signed bytes = UTF-8 `"hello\|" + ts + "\|" + nonce`; `sig` = **DER** → base64url, **never** P1363 |
| Comparing `a=fingerprint` naively | Take the `sha-256` line (media level wins on conflict), then strip the hash-func prefix, **remove all colons/whitespace, lowercase ASCII**. No `sha-256` line → **fail closed** |
| Pinning only on first pairing | Pin before **every** `setRemoteDescription` — the plugin may re-send an offer at any time. The phone must persist `fp` or a post-restart re-connect cannot verify |
| Letting the phone create a DataChannel | Forbidden; it needs the two `data`/`ctl` channels via `onDataChannel` and must not create its own |
| Reading the tunnel as HTTP | It is an L4 byte pump. No HTTP parsing, no header rewriting, no `Content-Length` logic |
| Assuming "fiber disposed" means "process exited" | Only the real process exit sends `bye`. Both candidate detectors in `docs/01` §2.2 fail toward **not** sending, which is the safe direction |
| Passing `'sha-256'` (string) as `RTCCertificate`'s 3rd arg | MUST be the enum object `{hash: HashAlgorithm.sha256_4, signature: SignatureAlgorithm.ecdsa_3}` (= `{4,3}`). The string form constructs fine, passes code review, and the DTLS handshake then fails with an opaque error — verified 2026-09-13 on werift 0.24.4 (`remotedsh-contract/scripts/poc-werift-loopback.mjs`) |
| Assigning a bare function to a werift Event property (e.g. `pc.onDataChannel = fn`) | werift Events need `.subscribe(fn)` or the DOM-style lowercase property (`pc.ondatachannel`); bare assignment to the Event field throws `execute is not a function` at runtime |
| Calling `ws.Close()` from multiple code paths in Go (e.g. hello timer + defer) | Wrap in `sync.Once`. Although `gorilla/websocket.Conn.Close()` is idempotent, the second call logs an error. Use `var closeOnce sync.Once; closeWS := func() { closeOnce.Do(func() { _ = ws.Close() }) }` and route all close paths (hello timeout, non-text frame, defer) through `closeWS`. | 011 审查 |
| Overwriting a callback (e.g. `this.opts.onByeOk`) set by another module | Save the original handler reference; call it after your own logic. Exit-time paths like `sendByeOnShutdown` are still part of the single `Bridge` instance and must not silently destroy the handler that `index.js` wired. | 011 审查 |
| `Thread.sleep()` inside an OkHttp `WebSocketListener` callback (Android) | OkHttp callbacks execute on OkHttp's thread pool. Blocking them delays ALL WebSocket connections on that dispatcher. Use `Handler(Looper.getMainLooper()).postDelayed(reconnectRunnable, delay)` instead, and cancel via `handler.removeCallbacks()` in `close()`. | 011 审查 |
| Managing Compose UI state with a plain `var` in Activity | Compose only recomposes when a `State<T>` changes. Use `var s by mutableStateOf<T>(initial)` — not `object MainViewModel { var state = ... }`. A plain property mutation is invisible to the recomposition system; the UI will never refresh. | 011 审查 |
| Kotlin `ByteBuffer.getInt()` for protocol u32 fields | `getInt()` returns a **signed** `Int`. Protocol fields defined as `u32` (e.g. frame `len`, `stream_id`) MUST be read as `b.int.toLong() and 0xFFFFFFFFL`. The old check `len < 0 \|\| len > MAX` "works" for current values but breaks silently if the protocol ever carries `len >= 2^31`. JS (`DataView.getUint32`) and Go (`binary.BigEndian.Uint32`) do not have this problem. | 011 审查 |

## 7. Provenance rule

If you are about to write a fact about this project into code, a comment, or a new document,
**state where it came from** — a contract §, a `docs/0N` §, or a source file with a symbol name.
This project's whole review method is "check the assertion against the real implementation", and it
only works while every claim carries its origin. A number with no citation is a defect.

When you find that a cited fact is **no longer true**, do not quietly code around it. Report it,
name the source that changed, and say which of the four documents now needs an amendment.

## 8. Change log discipline

Every change to the `new_docs/` plans or to implementation code MUST get a record in
`changelog/` (`YYYY-MM-DD-NNN-<topic>.md`, `NNN` globally increasing, never reused) plus a row
at the top of `changelog/INDEX.md`, written in the same sitting as the change itself — not
retroactively. Records are **append-only**: a wrong record is corrected by a new record that
names it, never edited or deleted. Review verdicts and user decisions get a record even when no
file changes that day. Convention and template: `changelog/README.md`.

### Live issue ledger

`changelog/ISSUES.md` is the single live issue ledger and the only exception to the append-only
rule above. Read it before planning or changing implementation code, and update it in the same
sitting whenever an issue is found, changes state, or is resolved.

- Keep every `未解决` or `验证中` item before the `已解决` section.
- Give every issue a stable ID. Never reuse or renumber an ID.
- Every issue MUST state its introduction/root cause, impact or evidence, and objective closure
  criteria. `Unknown` is acceptable only when the investigation gap is stated.
- Code written is not the same as resolved. Hardware, deployment, or E2E issues remain `验证中`
  until the required real-environment check passes.
- When an issue is resolved, move the whole entry to the end section, mark it `已解决`, and add the
  fix, verification evidence, resolution date, and numbered changelog record. Never delete it.
- If code contradicts an older changelog claim, trust the current code, keep the issue open, and
  add a new numbered changelog correction; do not rewrite the old record.

## 9. Android code status (as of 2026-09-17, updated 014)

The Android app compiles against a Kotlin toolchain but is **not yet verified on a real device**.
The following tracks what has been wired and what still needs device testing:

### ✅ Wired (014 — `qc_android_wiring`)

| Item | Location | What was done |
|---|---|---|
| QR parsing | `core-contract/.../PairQR.kt` (new) | `PairQRCodec.parse()` mirrors JS `parsePairQr`, fills missing import in Pairing.kt |
| RTC engine | `core-rtc/.../RtcEngine.kt` (rewritten) | Real `org.webrtc` APIs: `PeerConnectionFactory`, pin verification, dual DataChannel observation, `TunnelSender` + `sendCtlFrame` |
| App glue | `app/.../AppViewModel.kt` (new) | Complete flow: QR→signal→pair→WebRTC offer/answer→tunnel ready→WebView |
| RTC→Proxy data path | `AppViewModel.onDataFrameReceived` | Decodes frames, routes DATA to `proxy.routeToSocket()`, handles FIN/RST, sends WINDOW via ctl |
| Proxy→RTC data path | `AppViewModel.onTunnelReady` | Sets `proxy.senderProvider = rtc.tunnelSender` when tunnel ready |
| QR scanning | `MainActivity.ScanScreen` | Wired to `ScanContract` (journeyapps), triggers `viewModel.onQrScanned()` |
| SignalClient→StateMachine | `AppViewModel.onSignalErrorEvent` | Routes `SignalEvent.Error` to `StateMachine.onSignalError` with correct `isPassive` |
| PING auto-reply | `AppViewModel.onCtlFrameReceived` | Auto-replies PONG on ctl channel (DSH mux 2s heartbeat) |
| Reconnect path | `AppViewModel.onHelloOk` | Skips bind(ptok) when `e.pair` is non-null (existing pair) |
| WebRTC dep location | `core-rtc/build.gradle.kts` | `io.getstream:stream-webrtc-android:1.1.3` (wraps `org.webrtc`) moved here from `app` |
| fp vs agentId | `AppViewModel.qrFp` | Separate from `agentId` — certificate fingerprint ≠ public key hash (SKILL §3.1) |

### ❌ Still needs device testing

| Gap | Why can't be solved offline |
|---|---|
| G1 gate (werift ↔ org.webrtc) | Must test on real Android device |
| E4 risk (WebView plaintext loopback) | Must test on real Android device |
| `org.webrtc` ABI / NDK / ProGuard | Only surfaces when building and running on device |
| DataChannel parameter compatibility | Must verify ordered/binary between werift and Google WebRTC |
