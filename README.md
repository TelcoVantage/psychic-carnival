# Genesys Cloud data action: Check Caller Recent Activity

A Genesys Cloud **Data Actions** custom action that answers one question for
an inbound call: *has this ANI made a completed inbound voice call to us in
the last 30 minutes?* The window is computed at run time on every execution,
so the check is always relative to "now" for the current call.

```
data-actions/Check-Caller-Recent-Activity.json   importable action export
data-actions/src/request.vm                      request template (readable, commented)
data-actions/src/success.vm                      success template
architect/flow-wiring.md                         exact Architect steps, variables, expressions
scripts/build.py                                 rebuilds/validates the export from src/
scripts/deploy-and-test.sh                       optional: create + test the action via the Platform API (bash)
powershell/GcCommon.ps1                          CLM-safe helpers: pure-PowerShell Base64, token, API call, errors
powershell/Test-GcCallerRecentActivity.ps1       run the 30-minute caller check from PowerShell, optional CSV
powershell/Publish-GcDataAction.ps1              create/update, test and publish the action via the API
```

## How it works

1. The Architect flow computes the window with two expressions right before
   the **Call Data Action** step:

   ```
   Task.intervalStart = ToString(AddMinutes(GetCurrentDateTimeUtc(), -30))
   Task.intervalEnd   = ToString(GetCurrentDateTimeUtc())
   ```

   Data action templates expose `$esc`, `$math`, `$encoding`,
   `$successTemplateUtils` and `$urlTool`, but **no date tool**, so the clock
   must come from Architect. Because these run on every call, the 30-minute
   window is dynamic per execution.

2. The action calls `POST /api/v2/analytics/conversations/details/query` with

   * `interval` = `intervalStart/intervalEnd`
   * segment filters: `direction = inbound`, `mediaType = voice`,
     `ani = <caller>`
   * conversation filter: `conversationEnd exists`, which drops the
     in-progress call so it never counts as its own previous call
   * newest first, page size 25

3. The success template maps the response to flow-friendly outputs:

   | Output                   | Type              | Meaning                                              |
   |--------------------------|-------------------|------------------------------------------------------|
   | `hasCalledRecently`      | Boolean           | `true` when at least one completed call is in window |
   | `priorCallCount`         | Integer           | Number of completed calls in window                  |
   | `lastCallConversationId` | String            | Most recent matching conversation, or `""`           |
   | `lastCallStart`          | String            | ISO-8601 start of that call, or `""`                 |
   | `lastCallEnd`            | String            | ISO-8601 end of that call, or `""`                   |
   | `conversationIds`        | String Collection | All matching conversation IDs, newest first          |

Inputs: `ani` (pass `Call.Ani`), `intervalStart`, `intervalEnd`. All three
are required strings. A bare number without `tel:` is prefixed automatically.

## Install

1. **Integration.** Admin > Integrations. Make sure a **Genesys Cloud Data
   Actions** integration exists and is Active. Its OAuth client (client
   credentials) needs a role that includes the permission
   `analytics > conversationDetail > view`.
2. **Import.** Admin > Integrations > Actions > **Import**, choose
   `data-actions/Check-Caller-Recent-Activity.json`, pick the integration
   above, give it a name, and import.
3. **Test.** On the action's *Setup > Test* tab enter, for example:

   | Field           | Value                                        |
   |-----------------|----------------------------------------------|
   | `ani`           | `tel:+15551234567` (a number that called today) |
   | `intervalStart` | a UTC timestamp 30 minutes ago, e.g. `2026-09-28T00:37:00.000Z` |
   | `intervalEnd`   | the current UTC timestamp, e.g. `2026-09-28T01:07:00.000Z`      |

   Run it, confirm the response parses, then **Save** and **Publish**.
4. **Wire the flow.** Follow `architect/flow-wiring.md` step by step
   (variables, the two Update Data expressions, the Call Data Action mapping,
   and the Decision on `Task.hasCalledRecently == true`).

To create and test the action from a terminal instead, see
`scripts/deploy-and-test.sh` (needs an OAuth client-credentials grant with
`integrations:action:add`, `integrations:action:edit`,
`integrations:action:test` and `integrations:integration:view`).

## PowerShell (Constrained Language Mode safe)

The `powershell/` scripts target Windows PowerShell 5.1 on AppLocker/WDAC
locked-down endpoints running in Constrained Language Mode:

* no .NET static calls, `::new()` or `[pscustomobject]` casts; objects are
  built with `New-Object PSObject -Property` and column order is fixed with
  `Select-Object` before `Export-Csv`
* the OAuth Basic header is Base64-encoded in pure PowerShell (UTF-8 encoder
  plus `-shl`/`-shr`/`-band`/`-bor`), verified against .NET output for 306
  vectors including multi-byte and emoji characters
* HTTP status comes from `[int]$_.Exception.Response.StatusCode` in try/catch
  with a regex fallback on the message; 429 responses are retried with backoff
* every response is validated (`access_token`, `id`, `version`, `success`)
  before it is used

Check a caller directly (same query the data action runs, window computed at
run time):

```powershell
.\powershell\Test-GcCallerRecentActivity.ps1 -Region mypurecloud.ie `
    -ClientId $id -ClientSecret $secret -Ani 'tel:+447700900123' -OutCsv .\recent.csv
```

Create, test and publish the data action:

```powershell
.\powershell\Publish-GcDataAction.ps1 -Region mypurecloud.com `
    -ClientId $id -ClientSecret $secret -IntegrationId '<data actions integration id>' `
    -TestAni 'tel:+15551234567' -Publish
```

Both accept `-ApiBaseUri`/`-LoginBaseUri` overrides for proxies or testing.
If Windows PowerShell 5.1 reports a TLS handshake failure, enable TLS 1.2 as
the system default (`SchUseStrongCrypto` / `SystemDefaultTlsVersions`
registry values), since `[Net.ServicePointManager]` cannot be set in CLM.

## Behaviour details and limits

* **Match is exact on ANI.** `Call.Ani` is stored as `tel:+15551234567`; pass
  it unchanged. Do not strip the `+` or country code in the flow.
* **Only completed calls count.** A concurrent second call from the same
  number that is still in progress is not counted. If you need that, remove
  the `conversationEnd exists` conversation filter and compare
  `lastCallConversationId` against `Call.ConversationId` in the flow.
* **Window is by conversation start.** A call that started 40 minutes ago
  and ended 5 minutes ago is not counted with a 30-minute window. Widen the
  window in the Architect expression if that matters to you.
* **Analytics latency.** Conversation details are typically queryable within
  seconds of disconnect, but a redial inside that gap may be missed once.
* **Rate limits.** The details query is rate-limited per org; one call per
  inbound interaction is well within normal limits. On Failure/Timeout the
  flow should default `hasCalledRecently` to `false` and continue.

## Changing the action

Edit the templates in `data-actions/src/`, then:

```
python3 scripts/build.py          # regenerate the export and validate contracts
python3 scripts/build.py --check  # CI-style check that the export is current
```

The templates were rendered with Apache Velocity 1.7 against sample inputs
(full ANI, bare number with whitespace, quotes in ANI, 0 and N results,
string and integer `totalHits`) and produced valid JSON in every case.
