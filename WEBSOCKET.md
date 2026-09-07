# Live activity protocol

The app uses `GET /events` over WSS for live activity. Commands and saved history use `POST /rpc`. Tailscale Serve terminates TLS. The bridge listens on loopback port 4318; `AUTOLITH_BRIDGE_PORT` can select a separate test port.

Use the same `Authorization: Bearer <companion-token>` header on both endpoints. The bridge authenticates before the WebSocket upgrade and rejects browser Origin headers. `capabilities` includes `eventStreamVersion: 1` for bridge support. The selected native backend must also support subscriptions.

The conversation uses one compact worker status bar. It shows active worker names, tool execution, waits for jobs or RLM, and queue counts. Tool start and completion rows determine pending work; idle and disconnected sessions clear that detail. Conversation rows come only from the saved transcript, in its sequence order. Stream text has separate IDs and is not appended as a second copy of the reply.

## Subscription

Send one text message after the upgrade:

\```json
{"operation":"subscribe","id":"session-id","epoch":"previous-epoch","after":12}
\```

`epoch` and `after` are optional. Each socket watches one session. Open a new socket to change sessions.

The bridge starts one long-lived `autolith mobile` process. It writes the subscription to standard input and forwards JSON lines from standard output. It does not poll the backend for activity.

## Envelopes

Every envelope has `version`, `type`, `sessionID`, `epoch`, and `sequence`.

| Type | Fields | Meaning |
|---|---|---|
| `snapshot` | `status`, `activity` | Replace the current session status and live activity rows. |
| `event`, kind `activity` | `payload.event` | Replace or insert a row by its stable ID. Text is the current bounded value, not an append delta. |
| `event`, kind `status` | `payload.status` | Update native session status. Also serves as the native heartbeat. |
| `event`, kind `transcript-changed` | `payload` | Fetch saved history through HTTP. The app combines nearby invalidations. |
| `error` | `error` | Report the failure and close the stream. |

Activity rows contain `id`, `role`, `tool`, `text`, and `timestamp`. Live rows are separate from saved transcript events. They have no durable message identity or read receipt.

Each connection starts with a fresh epoch and an authoritative snapshot. Version 1 accepts old cursors but resets from current state instead of replaying old events. Wire sequence numbers are consecutive within an epoch. The native producer can combine rapid updates before delivery. Eviction produces another replacement snapshot.

## State and limits

The native publisher captures application reasoning, answer text, tool status, task lifecycle, and existing RLM progress. RLM progress is text; this version does not add a frame tree. Subscriptions start with retained job identities and states.

Native state holds at most 200 rows and 100,000 text characters. Each row holds at most 8,192 characters. Long streamed text keeps its recent portion. Saved history is fetched separately.

The bridge accepts four streams in addition to its HTTP operation slots. It limits a backend line to 1 MiB and pending sends to 2 MiB. It closes slow or invalid streams and stops their native subscription processes. It sends pings every 15 seconds. Native subscriptions emit status at least every 10 seconds.

The app closes the socket when it enters the background. It reconnects in the foreground with a bounded retry delay. APNs handles background notifications. Sidebar status refreshes every 10 seconds; a connected selected session uses stream invalidations for transcript refreshes.

## Backend build

The mobile-enabled Autolith backend implements native streaming in `src/localgroup/mobile-stream.lisp`. Its tests are in `tests/mobile-stream-tests.lisp` and the localgroup suite.

From that backend checkout, run `nix build .#default`. Configure the bridge's `AUTOLITH_EXECUTABLE` to use the resulting package's `bin/autolith`. Rebuild the bridge and app as well. Existing session processes need a restart to load the publisher; updating only the command-line adapter does not change their heaps.

## Validation

- `swift test`: frame parser, authentication, stream limits, malformed native envelopes, process cleanup, and client state tests.
- iOS simulator build through `xcodebuild`.
- Native source compilation, bounded-state tests, and subscription-loop sequence tests.
- Nix package and image validation.
- Isolated native session → Swift bridge → `URLSessionWebSocketTask` → `SessionStream`: initial snapshot, live reasoning update, and reconnect reset. This check used fixture activity, without a provider request.
