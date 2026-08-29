# Logs

## How logging works

Every branch of the flow calls one shared `log` Function node through Node-RED
`link call` / `link out (return)` nodes. The node is invoked twice per user
interaction: once right after the Telegram Receiver (inbound event) and once
before the Telegram Sender (what the bot replied). The currency branch calls it
a third time, right before the HTTP request.

Each entry is a single JSON line:

```json
{"ts":"2026-08-29T08:45:02.967Z","chatId":8631190257,"step":"calc:success","detail":"12+7=19"}
```

| field | meaning |
|---|---|
| `ts` | event time, ISO 8601 UTC |
| `chatId` | Telegram chat / session id |
| `step` | flow step, `<branch>:<outcome>` |
| `detail` | short human-readable summary |

Entries go to two sinks: container stdout (`docker logs redbot`) and
`/data/bot.log`, which is the mounted project folder. The fragments below are
copied verbatim from `bot.log`.

---

## Scenario 1 — successful calculation

```json
{"ts":"2026-08-29T08:45:01.347Z","chatId":8631190257,"step":"msg:received","detail":"menu:calc"}
{"ts":"2026-08-29T08:45:01.348Z","chatId":8631190257,"step":"calc:branch_entered","detail":"entered"}
{"ts":"2026-08-29T08:45:02.966Z","chatId":8631190257,"step":"msg:received","detail":"12 + 7"}
{"ts":"2026-08-29T08:45:02.967Z","chatId":8631190257,"step":"calc:success","detail":"12+7=19"}
```

The first line is the inline button press: RedBot delivers it as an ordinary
text message whose content is the button's `callback_data`, which is why the
router never has to distinguish taps from typing. The second line shows the
branch being entered — chat mode switched to `calc` and the input format hint
was sent. The last pair, one millisecond apart, is the expression arriving and
the Function node computing it; the user saw `🧮 12 + 7 = 19` with a Back button
and stayed in the calculator, ready for the next expression.

---

## Scenario 2 — invalid input

```json
{"ts":"2026-08-29T08:45:07.651Z","chatId":8631190257,"step":"msg:received","detail":"abc + 1"}
{"ts":"2026-08-29T08:45:07.651Z","chatId":8631190257,"step":"calc:invalid_number","detail":"bad=abc"}
```

Another variant, same branch:

```json
{"ts":"2026-08-29T08:50:38.391Z","chatId":8631190257,"step":"calc:invalid_number","detail":"bad=слон"}
```

The step name says exactly which validation rejected the input, and `detail`
names the operand that failed rather than reporting a generic error — that is
the difference between a log you can act on and a log you can only count. The
user saw «abc» — не число followed by the input format hint, and the bot stayed
in the calculator branch: no crash, no silence, no need to start over.

---

## Scenario 3 — external service failure

Baseline, working request:

```json
{"ts":"2026-08-29T08:45:21.366Z","chatId":8631190257,"step":"msg:received","detail":"menu:rates"}
{"ts":"2026-08-29T08:45:21.366Z","chatId":8631190257,"step":"nbu:request_sent","detail":"https://bank.gov.ua/NBUStatService/v1/statdirectory/exchange?json timeout=5000ms"}
{"ts":"2026-08-29T08:45:21.426Z","chatId":8631190257,"step":"nbu:success","detail":"USD=44.5505 EUR=51.8804"}
```

Same branch after the API URL was deliberately broken to `11https://...`:

```json
{"ts":"2026-08-29T08:46:06.390Z","chatId":8631190257,"step":"msg:received","detail":"menu:rates"}
{"ts":"2026-08-29T08:46:06.393Z","chatId":8631190257,"step":"nbu:error","detail":"exception:invalid API_URL: 11https://bank.gov.ua/NBUStatService/v1/"}
```

The telling detail is what is *missing* in the failure case: there is no
`nbu:request_sent` line. The URL was rejected by our own guard inside the
`rates` node before the HTTP node was ever called, so no request left the
container — and the log says so honestly instead of claiming a request that
never happened. The user saw only «Не вдалося отримати курс, спробуйте пізніше»
with a Back button; the technical cause (`exception:invalid API_URL: …`) stayed
in the log.

### Why the guard exists (found while testing)

An earlier version relied on the `http request` node to report failures. The
first attempt to break the URL produced this:

```
29 Aug 08:21:09 - [info] [function:log] {"step":"nbu:request_sent","detail":"11https://bank.gov.ua/..."}
29 Aug 08:21:09 - [warn] [http request:NBU exchange] non-http transport requested
```

Nothing followed. `non-http transport requested` is emitted with `node.warn()`,
not `node.error()`, so the Catch node never fired and the message was silently
dropped — the user got no reply at all. The fix was to validate the URL inside
the `rates` Function node and route invalid values straight to the error
handler through a second output.

The lesson: a third-party node cannot be trusted to report its own refusals in
a way your error handling will notice — validate the input you hand it, and read
the logs to confirm the failure path actually fires.

---

## Appendix — validation matrix

Collected from container stdout earlier in the session, before the file sink was
added. Same log format, same shared `log` node.

Division by zero:

```json
{"ts":"2026-08-29T08:07:53.950Z","chatId":8631190257,"step":"msg:received","detail":"44 / 0"}
{"ts":"2026-08-29T08:07:53.950Z","chatId":8631190257,"step":"calc:division_by_zero","detail":"44 / 0"}
```

No operator in the expression (`5 і слон`):

```json
{"ts":"2026-08-29T08:10:32.831Z","chatId":8631190257,"step":"msg:received","detail":"5 і слон"}
{"ts":"2026-08-29T08:10:32.832Z","chatId":8631190257,"step":"calc:no_operator","detail":"5 і слон"}
```

Input longer than the 50-character limit:

```json
{"ts":"2026-08-29T08:10:53.362Z","chatId":8631190257,"step":"msg:received","detail":"3892749823784582935789732485798347895789457893478957893457895789..."}
{"ts":"2026-08-29T08:10:53.363Z","chatId":8631190257,"step":"calc:too_long","detail":"len=270"}
```

Unrecognised input outside any branch (fallback):

```json
{"ts":"2026-08-29T08:07:34.899Z","chatId":8631190257,"step":"msg:received","detail":"вв"}
{"ts":"2026-08-29T08:07:34.900Z","chatId":8631190257,"step":"fallback:unknown_input","detail":"вв"}
```

Floating point and negative operands:

```json
{"ts":"2026-08-29T08:11:01.116Z","chatId":8631190257,"step":"calc:success","detail":"0.1+0.2=0.3"}
{"ts":"2026-08-29T08:11:05.615Z","chatId":8631190257,"step":"calc:success","detail":"-5*3=-15"}
```

More than one operation in a single expression:

```json
{"ts":"2026-08-29T09:13:06.469Z","chatId":8631190257,"step":"msg:received","detail":"1-2/3"}
{"ts":"2026-08-29T09:13:06.470Z","chatId":8631190257,"step":"calc:too_many_operations","detail":"expr=1-2/3"}
```

This case was found by testing the refactored flow: the parser handles one
operation, and the earlier version reported `1/2` as "not a number", which was
misleading. Operands are now validated by shape, so "not a number" and "more
than one operation" are two different steps with two different replies.

---

## Bonus — free-text recognition in the log

The `intent` node prefixes the log line with the rule that fired, so a free-text
request is traceable end to end without a separate log format:

```json
{"ts":"2026-08-29T09:33:23.177Z","chatId":8631190257,"step":"msg:received","detail":"курс"}
{"ts":"2026-08-29T09:33:23.180Z","chatId":8631190257,"step":"nbu:request_sent","detail":"[rates] https://bank.gov.ua/NBUStatService/v1/statdirectory/exchange?json timeout=5000ms"}
{"ts":"2026-08-29T09:33:23.265Z","chatId":8631190257,"step":"nbu:success","detail":"USD=44.5505 EUR=51.8804"}
```

Unrecognised free text is marked `[none]` and falls through to the normal
fallback answer:

```json
{"ts":"2026-08-29T09:33:18.730Z","chatId":8631190257,"step":"msg:received","detail":"калькулятор"}
{"ts":"2026-08-29T09:33:18.733Z","chatId":8631190257,"step":"fallback:unknown_input","detail":"[none] калькулятор"}
```

That second fragment is from before the branch-name patterns were added — the
user typed the name of a menu section and got the fallback. It is kept here on
purpose: it is what made the gap visible, and `[none]` is exactly the marker to
watch when deciding which patterns are missing.
