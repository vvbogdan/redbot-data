# Telegram bot on RedBot (Node-RED)

Test assignment: a Telegram bot built visually on the RedBot chatbot platform
(`node-red-contrib-chatbot` on top of Node-RED), with all non-trivial logic in
JavaScript Function nodes.

## How to run

Requirements: Docker. Nothing else is installed on the host.

1. Create a bot in Telegram via [@BotFather](https://t.me/BotFather) (`/newbot`)
   and copy the token it returns.

2. Put the token into `.env` in the project root (see `.env.example`):

   ```
   TELEGRAM_TOKEN=YOUR_TELEGRAM_TOKEN
   ```

   No quotes, no spaces around `=`.

3. Start Node-RED with this folder mounted as its data directory:

   ```bash
   docker run -d -p 1880:1880 \
     -v "$PWD":/data \
     --env-file "$PWD/.env" \
     --name redbot nodered/node-red
   ```

   `--env-file` is read only when the container is **created**. After editing
   `.env` you must `docker rm -f redbot` and run the command again — `docker
   restart` keeps the old value.

4. Install the RedBot palette into the mounted data directory:

   ```bash
   docker exec -w /data redbot npm install node-red-contrib-chatbot
   docker restart redbot
   ```

5. Open the editor at <http://localhost:1880>. If the flow is not already
   loaded, import `flows.json` (☰ → Import → select a file).

6. Open the `novait-bot` config node (Global Configuration Nodes) and paste the
   token into the **Token** field, then Deploy.

7. Send `/start` to the bot in Telegram.

### Where the token lives

`flows.json` contains **no token** — it only references the bot config node by
id. Node-RED stores credentials separately in `flows_cred.json` (encrypted, and
git-ignored together with `.env`). `check-secrets.sh` scans the tracked files
for anything that looks like a Telegram token before commit.

## Architecture

```
config (On Start)            ← all constants and user-facing strings
   │  flow.set('cfg'), flow.set('i18n')
   ▼
Telegram Receiver
      │
   [link call: log]                        ┌── one shared log node, called
      │                                    │   from every branch through
   router (Function, 5 outputs)            │   link call / link out (return)
      ├── menu       ──┐
      ├── about      ──┤
      ├── calc       ──┤
      ├── rates ─0─────┼─ [log] → [http request: NBU] → rates format ──┐
      │         └─1────┼──────────────────────────────────────────────►│
      │                │           [catch: NBU] ───────────────────────►│
      └── intent ────┬─┤   free text → calc / rates / menu / fallback   │
                     └─┤                                                │
                       └──────────────► [link call: log] → Telegram Sender
```

Chat state is a single `mode` variable per chat (`idle` / `calc`) stored in the
RedBot chat context. `/start`, `/menu` and the "Back" button reset it to `idle`
from anywhere.

Inline button presses arrive as ordinary text messages whose content is the
button's `callback_data` (this is what RedBot's Telegram connector does in
`callbackQuery()`), so the router only ever deals with strings.

### Configuration

Every constant and every string the user can see lives in the `config` node, on
its **On Start** tab, and is published into flow context as `cfg` and `i18n`:

- `cfg.nbu.url`, `cfg.nbu.timeoutMs`, `cfg.nbu.currencies`
- `cfg.calc.maxLen`, `cfg.calc.precision`
- `cfg.action.*` — inline button `callback_data` values
- `cfg.command.*` — bot commands
- `i18n.uk`, `i18n.en` — all user-facing text

On Start runs before the first message reaches the flow, so there is no race
between configuration and traffic (an inject node set to "run once" would have
one). Flow context holds **data only** — the `fmt()` placeholder helper stays in
node code, because a function would not survive a move to a persistent context
store.

The interface language comes from `language_code` in the Telegram profile. The
router resolves it once into `msg.lang`; an unknown language falls back to
`cfg.defaultLang`. Code and comments are in English; Ukrainian text exists only
as data inside `i18n.uk`.

## What's implemented

- Main menu with an inline keyboard: Calculator, Exchange rates, About.
- Return to the main menu from every branch, plus `/start` and `/menu`.
- Fallback for unrecognised text and for non-text messages (stickers, photos).
- Calculator in a Function node, single-line input format `12 + 7`,
  operators `+ − × ÷` (`*` and `/` also accepted).
- Validation: non-numeric operand, missing operator, more than one operation,
  division by zero, empty input, input longer than 50 characters, non-finite
  result.
- Exchange rates from the NBU open API, USD and EUR with the quotation date.
- API failure handling on three separate paths (see Known issues).
- Structured JSON logging from a single shared node into container stdout and
  `/data/bot.log`.
- All constants and user-facing strings centralised in one `config` node,
  with `uk` / `en` string dictionaries.
- Free-text understanding on the fallback path (bonus): "скільки буде 5 плюс 7",
  "який курс долара", "калькулятор".

### Why single-line calculator input

The task lets the author pick the input format. Step-by-step prompting ("send
the first number" → "the operator" → "the second number") needs intermediate
state per chat, plus handling for leaving the dialog halfway and for `/start`
arriving in the middle of input — a lot of edge cases for no gain here, because
every validation requirement is covered by the single-line format anyway. The
format is stated to the user on entering the branch and repeated with every
error message.

## Bonus blocks

### Free text instead of buttons

The `intent` node sits **on the fallback path only**, so exact commands and
button payloads are still resolved by the router and free-text matching can
never hijack an unambiguous input. Recognised text is rewritten into the
canonical form the existing branches already accept:

```
"скільки буде 5 плюс 7"  ->  msg.payload.content = "5 + 7"  ->  calc branch
"який курс долара"       ->  rates branch
"калькулятор"            ->  calc branch, chat mode set to `calc`
```

Neither the calculator nor the rates branch knows that free-text recognition
exists. Replacing the regex layer with a real NLU engine would touch one node
and nothing else.

Patterns live in `cfg.intent` as **strings**, not `RegExp` objects, so the
config stays serialisable; the node compiles them with `new RegExp(..., 'i')`.
The log line shows which rule fired: `[calc:words]`, `[calc:symbols]`,
`[rates]`, `[calc:branch]`, `[menu]` or `[none]`.

### Postman collection

`postman/nbu-api.postman_collection.json` — three requests with tests:

1. the exact call the bot makes, asserting the array shape, USD/EUR presence
   and a positive rate;
2. a single-currency request (`?valcode=usd`), with a note on why the bot does
   not use it — one request for the whole list is cheaper than one per currency;
3. an unknown currency code, which the NBU API answers with **HTTP 200 and an
   empty array** rather than an error status. This is the direct justification
   for the `Array.isArray` and `missing_currency` checks in the flow: a 200 does
   not mean the payload is usable.

### Network diagnostics

See [`network.md`](network.md).

## Known issues / not done

- The `status=...` error path (where the `http request` node forwards a network
  error itself) is implemented but was not verified empirically; only the
  invalid-URL path was reproduced. To test: set `TIMEOUT_MS = 1` in the `rates`
  node.
- Empty input cannot actually be produced from a Telegram client — the branch
  exists but is unreachable in practice.
- Chat context provider is `memory`, so the `mode` variable is lost on restart.
  A user who was inside the calculator branch lands in `idle` after a restart.
- `npm install node-red-contrib-chatbot` reports 39 vulnerabilities in the
  transitive dependency tree (RedBot 2.0.4 pulls in Apollo Server 2, Sequelize 5,
  express 2.x). Acceptable for a test assignment, not for production.
- Long polling only; no webhook mode.

<!-- TODO: anything else you got stuck on, and what you tried -->


## Time spent

About 2 hours, including deployment, one refactoring pass (constants and strings
moved into a single config node) and two defects found and fixed during testing:
the silently dropped message on an invalid URL, and the misleading "not a
number" reply for expressions with more than one operation.

## Checklist

| Item | Status |
|---|---|
| RedBot deployed, bot answers `/start` | ✅ |
| Menu with 3 items + "Back" button | ✅ |
| Fallback on unrecognised input | ✅ |
| Calculator computes correctly | ✅ |
| Validation: non-numeric value | ✅ |
| Validation: division by zero | ✅ |
| Validation: empty / too long input | 🟡 |
| Exchange rates from NBU API | ✅ |
| API unavailability handled | ✅ |
| Logs: successful scenario | ✅ |
| Logs: invalid input | ✅ |
| Logs: API failure | ✅ |
| README in English | ✅ |
| Bonus: Postman collection | ✅ |
| Bonus: free text instead of buttons | ✅ |
| Bonus: network diagnostics | 🟡 |

Evidence for every logging row is in [`logs.md`](logs.md).
