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

## Two-Phase Facilitation Workflow

Phase 1 (collect ideas):
1. Create a session whose topic starts with `P1`.
2. Run the session monitor to poll for completion.
3. When N participants finish, the monitor saves the full `get_responses` payload to `data/responses/phase<1|2>_<session_id>.json`.
4. Run Phase 1 extraction to produce votes/reasoning JSON.

Phase 2 (reflect on others' ideas):
1. Use the Phase 2 script to create a new session whose prompt injects the collected rephrases.
2. The moderator presents ideas one-by-one and asks for reflection.
3. Run the session monitor in phase 2 to capture the completed transcript into `data/responses/phase<1|2>_<session_id>.json`.

Pilot config (optional):
- If `example_pilot.yaml` is present, scripts will use:
  - `topic.description` to populate session goals/prompts
  - `expected_participants` as the default `--max-users` if you don’t pass one

Create Phase 1 session (optional helper):
```bash
HARMONICA_API_KEY=... npm run phase1:create -- --config example_pilot.yaml
```

Session monitor (requires session id):
```bash
HARMONICA_API_KEY=... npm run build
HARMONICA_API_KEY=... npm run session:monitor -- --session-id hst_... --phase 1 --interval 60 --max-users 5
```

Phase 2 reflections monitor:
```bash
HARMONICA_API_KEY=... npm run session:monitor -- --session-id hst_... --phase 2 --interval 60 --max-users 5
```

Stop monitoring manually:
```bash
HARMONICA_API_KEY=... npm run session:monitor -- --stop --session-id hst_...
```

Create Phase 2 session:
```bash
HARMONICA_API_KEY=... npm run phase2:create -- --source-session hst_... --config example_pilot.yaml
```
Phase 2 creation reads from `data/responses/phase1_<session_id>_extractions.json` by default.

Tool usage summary:
1. `phase1:create` (or `create_session`) for Phase 1, with topic prefixed by `P1`.
2. `session:monitor` for Phase 1 to capture answers/rephrases outside the moderator.
3. `reasoning:extract` to extract votes/reasoning from the Phase 1 transcript.
4. `phase2:create` to build a Phase 2 session with injected rephrases.
5. `session:monitor` for Phase 2 to capture the transcript JSON.

## Running a 2-phase experiment

1. Create Phase 1 session (uses `example_pilot.yaml` for goal/prompt defaults):
```bash
HARMONICA_API_KEY=... npm run phase1:create -- --config example_pilot.yaml
```

2. Monitor Phase 1 until N participants finish (saves Phase 1 transcript JSON):
```bash
HARMONICA_API_KEY=... npm run session:monitor -- --session-id hst_<PHASE1_ID> --phase 1 --interval 60 --max-users 3
```

3. Extract votes + reasoning from Phase 1 transcript:
```bash
OPENAI_API_KEY=... npm run reasoning:extract -- --session-id hst_<PHASE1_ID> --phase 1 --config example_pilot.yaml
```

4. Create Phase 2 session using extracted reasoning:
```bash
HARMONICA_API_KEY=... npm run phase2:create -- --source-session hst_<PHASE1_ID> --config example_pilot.yaml
```

5. Monitor Phase 2 until N participants finish (saves Phase 2 transcript JSON):
```bash
HARMONICA_API_KEY=... npm run session:monitor -- --session-id hst_<PHASE2_ID> --phase 2 --interval 60 --max-users 3
```

Check current status:
```bash
npm run pilot:status -- --config example_pilot.yaml
```

Archive a completed cycle (moves phase1/phase2 JSONs to `data/archive/`):
```bash
npm run cycle:archive
```
This also writes `pilot_status.txt` into the archive folder.

Optional label:
```bash
npm run cycle:archive -- --label pilot_001
```

Phase 1/2 extraction (phase-agnostic):
```bash
OPENAI_API_KEY=... npm run reasoning:extract -- --session-id hst_... --phase 1 --config example_pilot.yaml
OPENAI_API_KEY=... npm run reasoning:extract -- --session-id hst_... --phase 2 --config example_pilot.yaml
# OPENAI_API_KEY=... npm run reasoning:extract -- --input data/responses/phase2_hst_...json --config example_pilot.yaml
```
This writes `data/responses/phase<1|2>_<session_id>_extractions.json`.

## Cross-Pollination Experiment Tools (Optional)

These tools are available but are not required for the main two-phase workflow above. Data is stored locally under `CROSSPOLL_DATA_DIR` and never committed.

| Tool | Description |
|------|-------------|
| `xp_register_participant` | Register a Harmonica participant and return an experiment participant ID |
| `xp_store_initial_answer` | Store the participant's initial vote + reasoning |
| `xp_store_rephrase` | Store a shareable rephrase of a participant answer |
| `xp_upsert_crosspoll_packet` | Upsert the latest session-level cross-pollination packet (server computes snapshot_id) |
| `xp_get_cross_pollination_packet` | Retrieve the latest session-level packet (NEXT/REFRESH) |
| `xp_log_crosspoll_display` | Log that a packet was displayed in the UI |

NEXT/REFRESH flow (optional):
1. Codex collects new rephrased opinions and calls `xp_upsert_crosspoll_packet`.
2. The UI moderator calls `xp_get_cross_pollination_packet` on NEXT/REFRESH.
3. The UI moderator calls `xp_log_crosspoll_display` after showing a packet.
4. The server also maintains the latest packet automatically on each `xp_store_rephrase`.

Snapshot IDs:
- `snapshot_id` is computed server-side from the packet contents.
- It is a deterministic hash: sort all `rephrase_id` values, join with `|`, SHA-256 hash, and take the first 16 hex chars.

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
| `EXTRACTION_API_URL` | No (defaults to OpenAI) | `https://api.openai.com/v1/chat/completions` | LLM endpoint for extraction (chat-completions compatible) |
| `EXTRACTION_API_KEY` | No (fallback to `OPENAI_API_KEY`) | — | API key for extraction endpoint |
| `OPENAI_API_KEY` | No (fallback for extraction) | — | OpenAI API key used if `EXTRACTION_API_KEY` is not set |

## See Also

- **[harmonica-chat](https://github.com/harmonicabot/harmonica-chat)** — Conversational Harmonica companion for Claude Code — design, create, and manage sessions (`/harmonica-chat`)
- **[Harmonica docs](https://help.harmonica.chat)** — Full platform documentation and API reference

## License

MIT
