# Harmonica Two-Phase Pipeline

Scripts for running a two‑phase [Harmonica](https://harmonica.chat) deliberation workflow.

[Harmonica](https://harmonica.chat) is a structured deliberation platform where groups coordinate through AI-facilitated async conversations. Create a session with a topic and goal, share a link with participants, and each person has a private 1:1 conversation with an AI facilitator. Responses are synthesized into actionable insights. [Learn more](https://help.harmonica.chat).

## Quick Start

### 1. Get an API key

1. [Sign up for Harmonica](https://app.harmonica.chat) (free)
2. Go to [Profile](https://app.harmonica.chat/profile) > **API Keys** > **Generate API Key**
3. Copy your `hm_live_...` key — it's only shown once

## Two-Phase Facilitation Workflow

Phase 1 (collect ideas):
1. Create a session whose topic starts with `P1`.
2. Run the session monitor to poll for completion.
3. When N participants finish, the monitor saves the full `get_responses` payload to `data/responses/phase<1|2>_<session_id>.json`.
4. Run Phase 1 extraction to produce vote-ranking/reasoning JSON.

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
1. `phase1:create` for Phase 1, with topic prefixed by `P1`.
2. `session:monitor` for Phase 1 to capture answers/rephrases outside the moderator.
3. `reasoning:extract` to extract vote rankings/reasoning from the Phase 1 transcript.
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

3. Extract vote rankings + reasoning from Phase 1 transcript:
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
For Phase 1, each row stores `vote_ranking` as an ordered array from most preferred to least preferred.
For Phase 2, each row stores `initial_vote_ranking`, `initial_reasoning`, `final_vote_ranking`, and `final_reasoning`.

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `HARMONICA_API_KEY` | Yes | — | Your Harmonica API key |
| `HARMONICA_API_URL` | No | `https://app.harmonica.chat` | API base URL |
| `EXTRACTION_API_URL` | No (defaults to OpenAI) | `https://api.openai.com/v1/chat/completions` | LLM endpoint for extraction (chat-completions compatible) |
| `EXTRACTION_API_KEY` | No (fallback to `OPENAI_API_KEY`) | — | API key for extraction endpoint |
| `OPENAI_API_KEY` | No (fallback for extraction) | — | OpenAI API key used if `EXTRACTION_API_KEY` is not set |

## See Also

- **[harmonica-chat](https://github.com/harmonicabot/harmonica-chat)** — Conversational Harmonica companion for Claude Code — design, create, and manage sessions (`/harmonica-chat`)
- **[Harmonica docs](https://help.harmonica.chat)** — Full platform documentation and API reference

## License

MIT
