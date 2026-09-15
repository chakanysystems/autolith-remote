# Live status protocol

Use `GET /events` over WSS for session status and `POST /rpc` for commands and saved history. Tailscale Serve terminates TLS. The bridge listens on loopback port 4318; set `AUTOLITH_BRIDGE_PORT` to select another port.

Send `Authorization: Bearer <companion-token>` on both endpoints. The bridge authenticates before the WebSocket upgrade and rejects browser Origin headers. Capabilities include `eventStreamVersion: 1` and `backendTransport: "management-rpc"`.

## Subscription

Send one text message within ten seconds of the upgrade:

\```json
{"operation":"subscribe","id":"session-id"}
\```

Each socket watches one session. Open a new socket to change sessions. The session ID must be nonempty and at most 1,024 UTF-8 bytes. Optional `epoch` must be a string; optional `after` must be an integer from 0 through 9007199254740991. These cursors are validated but ignored: each subscription starts with a fresh epoch and current state.

The bridge requests only the selected session's status and transcript source description immediately and every two seconds. It skips a polling tick while the previous request is outstanding. Replay segment identities, sizes, nanosecond modification/change times, and live local-operation context determine the source revision without reading message history. For backend installation and gateway configuration, see [README.md](README.md#companion-bridge).

## Snapshots

Every successful poll sends a replacement snapshot with `version: 1`, `type: "snapshot"`, `sessionID`, `epoch`, `sequence`, `status`, `transcriptRevision`, and `activity: []`. The revision includes durable outbox and read-state changes. The client synchronizes history when this revision changes or a new stream epoch starts. Legacy snapshots without a revision still trigger synchronization. Sequence numbers start at 1 and increase within the connection's epoch, including when status is unchanged.

The current implementation supplies session status rather than token or tool activity. Fetch conversation history separately through RPC. The client supports additional event envelope types for compatibility, but the polling bridge emits snapshots.

A missing session or backend failure produces an error and closes the connection. Error text is bounded to 4,096 characters.

## Limits and lifecycle

The bridge admits four simultaneous streams separately from HTTP operation slots. Incoming WebSocket messages are limited to 8,192 bytes and pending sends to 2 MiB. Closing a stream cancels its polling timer and outstanding backend request context.

The bridge sends pings every 15 seconds and closes connections whose last matching pong is over 45 seconds old. The app closes its socket in the background and reconnects in the foreground with retry delays bounded at 30 seconds.

## Validation

Run `swift test`. Event-stream tests cover subscription validation, authentication and Origin rejection, upgrade-byte handoff, successive polling snapshots with a stable epoch, independent stream admission, and HTTP connection reuse. Client tests cover revision-based invalidation, replacement snapshots, sequence gaps and epoch changes, compatibility events, and activity bounds.
