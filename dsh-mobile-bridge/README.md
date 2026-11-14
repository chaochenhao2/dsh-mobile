# Mobile bridge

Serves the running Harness to the **DSH Mobile** iOS app over your local
network. The plugin starts with the Host, listens on a port, and answers a small
JSON + Server-Sent-Events API on top of the Host Session API.

## What it does

- Announces itself on the LAN every 3 seconds over UDP (port 5181) so the app can
  find the computer without typing an address.
- Answers `GET /api/info` with the Harness version, profile, host name, LAN
  addresses, the Web GUI URL, and the bridge's capabilities.
- Lists Sessions with their titles, working directory, and running state.
- Reads one Session as a flat transcript of `user`, `assistant`, and `tool`
  nodes, folding the wide Session event vocabulary into something a phone can
  render.
- Follows a Session live over SSE, including provisional assistant text while a
  model step is still streaming.
- Submits a prompt and cancels a turn on behalf of the phone.

## Setup

1. Enable the **Mobile bridge** row in **Plugins**. On first activation the
   plugin writes `${DSH_HOME}/mobile-bridge/config.json` and prints the URL.
2. Read the `token` from that file, or open the file and copy it.
3. In the iOS app, tap **Discover** on the same Wi-Fi network, or type the
   address and token by hand.

## Configuration

Everything lives in `${DSH_HOME}/mobile-bridge/config.json`:

| Key | Default | Meaning |
| --- | --- | --- |
| `port` | `5180` | HTTP port the bridge listens on. |
| `host` | `0.0.0.0` | Bind address. Set `127.0.0.1` to disable LAN access. |
| `discovery` | `true` | Broadcast the UDP beacon. |
| `discoveryPort` | `5181` | UDP port the beacon is sent to. |
| `includeTokenInBeacon` | `false` | Ship the token inside the beacon, so the app pairs with zero typing. |
| `token` | generated | Bearer token every request must present. |

A key in the bundle row's `config` overrides the file.

## Security

The bridge refuses every request without the token and binds to the LAN, not the
internet. `includeTokenInBeacon` trades that protection for convenience: any
device on the same network can then pair silently. Keep it `false` on untrusted
networks, and set `host: 127.0.0.1` when you only need the simulator.

## Limits

- Approvals, file uploads, image prompts, and terminal control are not exposed;
  answer approvals on the computer.
- Transcript folding covers user messages, assistant messages, and tool calls.
  Other Session events are summarized as status frames, not as transcript nodes.
- The bridge is read-mostly by design: it never changes models per Session
  unless asked, and it writes only the prompt it was given.
