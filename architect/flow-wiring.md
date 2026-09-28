# Architect wiring for "Check Caller Recent Activity"

The data action cannot read the clock. Genesys Cloud data action templates
expose `$esc`, `$math`, `$encoding`, `$successTemplateUtils` and `$urlTool`,
but no date tool, so the look-back window is computed by the flow on every
execution and handed to the action as two ISO-8601 UTC strings. Because the
expressions below run each time the **Call Data Action** step is reached, the
"last 30 minutes" is always relative to the moment of the current call.

## 1. Variables

Create these task-level variables (type in brackets):

| Variable                        | Type              | Purpose                                |
|---------------------------------|-------------------|----------------------------------------|
| `Task.intervalStart`            | String            | Window start, ISO-8601 UTC             |
| `Task.intervalEnd`              | String            | Window end (now), ISO-8601 UTC         |
| `Task.hasCalledRecently`        | Boolean           | Result used for routing                |
| `Task.priorCallCount`           | Integer           | Optional, for prompts/attributes       |
| `Task.lastCallConversationId`   | String            | Optional, for agent scripts/attributes |
| `Task.lastCallStart`            | String            | Optional                               |
| `Task.lastCallEnd`              | String            | Optional                               |
| `Task.recentConversationIds`    | String Collection | Optional                               |

## 2. Update Data step (immediately before the Call Data Action)

| Variable             | Expression                                              |
|----------------------|---------------------------------------------------------|
| `Task.intervalStart` | `ToString(AddMinutes(GetCurrentDateTimeUtc(), -30))`     |
| `Task.intervalEnd`   | `ToString(GetCurrentDateTimeUtc())`                      |

`ToString()` on an Architect DateTime yields `yyyy-MM-ddTHH:mm:ss.fffZ`, which
is exactly what the Analytics API interval accepts. To change the window,
change `-30` only. If you prefer a single tunable, set an integer variable
`Task.lookbackMinutes = 30` and use
`ToString(AddMinutes(GetCurrentDateTimeUtc(), -Task.lookbackMinutes))`.

## 3. Call Data Action step

* Category: **Genesys Cloud Data Actions** (your integration name)
* Data action: **Check Caller Recent Activity**
* Inputs

  | Input           | Value                 |
  |-----------------|-----------------------|
  | `ani`           | `Call.Ani`            |
  | `intervalStart` | `Task.intervalStart`  |
  | `intervalEnd`   | `Task.intervalEnd`    |

* Success outputs

  | Output                   | Variable                      |
  |--------------------------|-------------------------------|
  | `hasCalledRecently`      | `Task.hasCalledRecently`      |
  | `priorCallCount`         | `Task.priorCallCount`         |
  | `lastCallConversationId` | `Task.lastCallConversationId` |
  | `lastCallStart`          | `Task.lastCallStart`          |
  | `lastCallEnd`            | `Task.lastCallEnd`            |
  | `conversationIds`        | `Task.recentConversationIds`  |

* **Failure** and **Timeout** paths: add an Update Data step that sets
  `Task.hasCalledRecently = false` so the call still routes normally when
  analytics is slow or unavailable. Keep the step timeout at the default
  (20 s is plenty; the query usually returns in well under a second).

## 4. Decision step

Expression: `Task.hasCalledRecently == true`

* **Yes**: repeat caller within 30 minutes. Typical uses: skip the greeting,
  play "Welcome back", set a participant attribute such as
  `Set Participant Data: RepeatCaller = "true"` and
  `LastConversationId = Task.lastCallConversationId`, bump priority, or route
  to the same queue/agent.
* **No**: normal path.

## Notes

* **ANI format.** `Call.Ani` is already `tel:+15551234567`, which is the value
  stored in the analytics `ani` dimension. The action prefixes `tel:` if a bare
  number is passed, but it cannot add a country code, so always pass `Call.Ani`
  rather than a reformatted number. If your trunk delivers ANI as a SIP URI,
  check a recent interaction under Performance > Interactions and match that.
* **The current call is excluded.** The query keeps only conversations that
  have a `conversationEnd`, so the in-progress call never counts as its own
  "previous" call and `priorCallCount` is the count of completed calls.
* **Analytics latency.** Conversation detail data is normally queryable within
  a few seconds of the previous call disconnecting. A caller who hangs up and
  redials within that gap may not be detected on the very first attempt.
