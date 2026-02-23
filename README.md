# Harmonica MCP Server

[![npm version](https://img.shields.io/npm/v/harmonica-mcp)](https://www.npmjs.com/package/harmonica-mcp)

MCP server enabling AI agents to create and query [Harmonica](https://harmonica.chat) deliberation sessions.

[Harmonica](https://harmonica.chat) is a structured deliberation platform where groups coordinate through AI-facilitated async conversations. Create a session with a topic and goal, share a link with participants, and each person has a private 1:1 conversation with an AI facilitator. Responses are synthesized into actionable insights. [Learn more](https://help.harmonica.chat).

## Quick Start

### 1. Get an API key

1. [Sign up for Harmonica](https://app.harmonica.chat) (free)
2. Go to [Profile](https://app.harmonica.chat/profile) > **API Keys** > **Generate API Key**
3. Copy your `hm_live_...` key — it's only shown once

### 2. Configure your MCP client

Add to your MCP client config (e.g. Claude Code, Cursor, Windsurf):

```json
{
  "mcpServers": {
    "harmonica": {
      "command": "npx",
      "args": ["-y", "harmonica-mcp"],
      "env": {
        "HARMONICA_API_KEY": "hm_live_your_key_here"
      }
    }
  }
}
```

### 3. Start a deliberation

Ask your AI agent to create a session:

> Create a Harmonica session about "Team Retrospective" with the goal "Review Q1 and identify improvements"

Share the join URL with participants. Once they've responded, use `get_responses` and `get_summary` to see the results.

## Tools

| Tool | Description |
|------|-------------|
| `create_session` | Create a new deliberation session and get a shareable join URL |
| `list_sessions` | List your deliberation sessions (filter by status, search) |
| `get_session` | Get full session details |
| `get_responses` | Get participant responses |
| `get_summary` | Get AI-generated summary |
| `search_sessions` | Search by topic or goal |

## Cross-Pollination Experiment Tools

These tools support an async cross-pollination experiment flow. Data is stored locally under `CROSSPOLL_DATA_DIR` and never committed.

| Tool | Description |
|------|-------------|
| `xp_register_participant` | Register a Harmonica participant and return an experiment participant ID |
| `xp_store_initial_answer` | Store the participant's initial vote + reasoning |
| `xp_store_rephrase` | Store a shareable rephrase of a participant answer |
| `xp_upsert_crosspoll_packet` | Upsert the latest session-level cross-pollination packet (server computes snapshot_id) |
| `xp_get_cross_pollination_packet` | Retrieve the latest session-level packet (NEXT/REFRESH) |
| `xp_log_crosspoll_display` | Log that a packet was displayed in the UI |

NEXT/REFRESH flow:
1. Codex collects new rephrased opinions and calls `xp_upsert_crosspoll_packet`.
2. The UI moderator calls `xp_get_cross_pollination_packet` on NEXT/REFRESH.
3. The UI moderator calls `xp_log_crosspoll_display` after showing a packet.
4. The server also maintains the latest packet automatically on each `xp_store_rephrase`.

Snapshot IDs:
- `snapshot_id` is computed server-side from the packet contents.
- It is a deterministic hash: sort all `rephrase_id` values, join with `|`, SHA-256 hash, and take the first 16 hex chars.

## Two-Phase Facilitation Workflow

Phase 1 (collect ideas):
1. Create a session whose topic starts with `P1`.
2. Run the session monitor to poll messages and store answers in `answers_p1` and rephrases in `rephrases`.
3. Rephrases are currently stored as the raw answer text (rephrase = answer).

Phase 2 (reflect on others' ideas):
1. Use the Phase 2 script to create a new session whose prompt injects the collected rephrases.
2. The moderator presents ideas one-by-one and asks for reflection.
3. Run the session monitor in phase 2 to store reflections in `answers_p2`.

Session monitor (requires session id):
```bash
HARMONICA_API_KEY=... npm run build
HARMONICA_API_KEY=... npm run session:monitor -- --session-id hst_... --phase 1 --interval 60 --stop-mode users --max-users 5
```

Phase 2 reflections monitor:
```bash
HARMONICA_API_KEY=... npm run session:monitor -- --session-id hst_... --phase 2 --interval 60 --stop-mode users --max-users 5
```

Legacy stop mode (answers/rephrases):
```bash
HARMONICA_API_KEY=... npm run session:monitor -- --session-id hst_... --phase 1 --interval 60 --stop-mode answers --max-rephrases 5
HARMONICA_API_KEY=... npm run session:monitor -- --session-id hst_... --phase 2 --interval 60 --stop-mode answers --max-answers 5
```

Stop monitoring manually:
```bash
HARMONICA_API_KEY=... npm run session:monitor -- --stop --session-id hst_...
```

Create Phase 2 session:
```bash
HARMONICA_API_KEY=... npm run phase2:create -- --source-session hst_...
```

Tool usage summary:
1. `create_session` for Phase 1, with topic prefixed by `P1`.
2. `session:monitor` for Phase 1 to capture answers/rephrases outside the moderator.
3. `phase2:create` to build a Phase 2 session with injected rephrases.
4. `session:monitor` for Phase 2 to capture reflections in `answers_p2`.

Example tool-call script:

```text
# TODO: paste the example tool-call script here.
```

## From Source

```bash
git clone https://github.com/harmonicabot/harmonica-mcp.git
cd harmonica-mcp
npm install && npm run build
```

Then use `node /path/to/harmonica-mcp/dist/index.js` instead of `npx -y harmonica-mcp` in your config.

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `HARMONICA_API_KEY` | Yes | — | Your Harmonica API key |
| `HARMONICA_API_URL` | No | `https://app.harmonica.chat` | API base URL |
| `CROSSPOLL_DATA_DIR` | No | `./data/crosspoll` | Directory to store cross-pollination experiment data |

## See Also

- **[harmonica-chat](https://github.com/harmonicabot/harmonica-chat)** — Conversational Harmonica companion for Claude Code — design, create, and manage sessions (`/harmonica-chat`)
- **[Harmonica docs](https://help.harmonica.chat)** — Full platform documentation and API reference

## License

MIT
