# Mobile bridge

This plugin turns the running Harness into a small HTTP service on your local
network so the **DSH Mobile** iOS app can read and drive it from your phone.
Nothing leaves the machine: there is no cloud hop and no account.

## How it starts

The bundle patch inserts one row. The row activates as soon as the Host Session
API exists, which is during normal Harness startup, so the bridge is already
listening by the time the desktop window appears. It writes its own settings once
on first activation and reuses the same pairing token after that.

## What the app can do

- See every Session with its title, working directory, and whether it is running.
- Open one Session and read the transcript as message bubbles and tool rows.
- Watch a turn arrive live, including assistant text while the model is still
  streaming.
- Send a prompt as if it were typed on the computer.
- Stop a running turn.
- Create a fresh Session.
- Change the model for one Session.

Whatever the phone sends is a normal Session prompt, so it appears in the
desktop's own transcript and in the durable Session log.

## HTTP surface

All routes except the health probe require the token the plugin generated.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/health` | Liveness probe, no token required. |
| `GET` | `/api/info` | Harness version, profile, host name, LAN addresses, capabilities. |
| `GET` | `/api/sessions` | Session rows, newest first. |
| `POST` | `/api/sessions` | Create a Session (`cwd`, `agentPreset` optional). |
| `GET` | `/api/session/:id` | Transcript, state, title, and page cursor. |
| `GET` | `/api/session/:id/stream` | Server-Sent Events: `reset`, `op`, `status`, `error`. |
| `POST` | `/api/session/:id/prompt` | Submit `{ "text": "..." }`. |
| `POST` | `/api/session/:id/cancel` | Stop the active turn. |
| `POST` | `/api/session/:id/model` | Select `{ provider, model }` for this Session. |
| `GET` | `/api/models` | The routable model catalog. |

## Discovery

A UDP beacon on port 5181 carries the service name, the host name, the HTTP
port, and both versions. The token is left out unless `includeTokenInBeacon` is
turned on, so discovery alone cannot drive the computer.

## What stays on the computer

Approvals and user questions need a human decision with the full context of the
tool being approved, so they stay on the desktop. File uploads, image prompts,
and terminal control are likewise not exposed. When a Session is waiting for an
approval, the phone shows it as running with pending input; answer it on the
computer and the turn continues.
