# Genesys Cloud agent script: Standard Inbound Script

A deliberately plain inbound script for the agent panel. One page, three things:

1. The standard out-of-the-box call details (interaction type and state, queue,
   customer number, plus the interaction ID).
2. A link the agent can click to open a specific web page.
3. A disclaimer block the agent reads out to the customer.

`Standard-Inbound-Script.definition.json` in this folder is the source of
truth for the content: exact text, variables, component order and styling.
Genesys Cloud only imports its own undocumented `.script` export format, so
the script is built once in the Script Designer using the steps below and then
exported from the org (**Scripts > select the script > Export**) if you want a
reusable `.script` file. Building it takes about ten minutes.

## Before you start: fill in the two blanks

Replace these placeholders (they are listed under `replaceBeforeBuilding` in the
definition file):

| Placeholder       | Meaning                                              | Default in this repo                    |
|-------------------|------------------------------------------------------|-----------------------------------------|
| `PAGE_URL`        | The page the link opens                              | `https://example.com/your-page`         |
| `PAGE_LINK_TEXT`  | Text of the link the agent clicks                    | `Open the reference page`               |
| `DISCLAIMER_TEXT` | Wording the agent reads out. Use your approved text. | A generic call-recording consent line   |

## Build steps (Script Designer)

### 1. Create the script

1. **Admin > Contact Center > Scripts** (or **Menu > Digital and Telephony >
   Interaction Assets > Scripts**).
2. Click **Create**, name it `Standard Inbound Script`, choose your Division
   and pick a **blank** script (not a template).
3. **Script > Script Properties**: turn on **Inbound** and tick **Allow
   inbound Architect flows to select a script**. Leave the other channels off
   unless you also want the same script on callbacks, in which case turn on
   **Callback** too.

### 2. Build the page

Work on the default page (rename it `Main`). Add the components below in this
order; a new component drops in under the previous one.

| # | Component      | Text / setting                                                   | Style                              |
|---|----------------|------------------------------------------------------------------|------------------------------------|
| 1 | Read-only Text | `Call Details`                                                   | Bold, larger font                  |
| 2 | Read-only Text | `Interaction Type: {{Scripter.Interaction Type}}`                |                                    |
| 3 | Read-only Text | `Interaction State: {{Scripter.Interaction State}}`              |                                    |
| 4 | Read-only Text | `Queue: {{Scripter.Queue Name}}`                                 |                                    |
| 5 | Read-only Text | `Customer Number: {{Scripter.Customer Formatted Number}}`        |                                    |
| 6 | Read-only Text | `Interaction ID: {{Scripter.Interaction Id}}`                    | Smaller font                       |
| 7 | Link           | Text `PAGE_LINK_TEXT`; **Click Action > URL** = `PAGE_URL`       | Top margin 16                      |
| 8 | Read-only Text | `Disclaimer - read this to the customer`                         | Bold, top margin 16                |
| 9 | Read-only Text | `"DISCLAIMER_TEXT"` (in quotes so it reads as a spoken line)     | Italic, dark red text (`#8A1C1C`)  |

Notes on the components:

* **Variables.** Type the `{{...}}` tokens exactly as shown, or put the cursor in
  the text and pick the variable from the **Variables** list. All of them are
  built-in `Scripter` variables, so no Architect input is needed. Interaction
  type, interaction state, queue name and customer number are the four values
  Genesys itself adds to a new script page, which is the "out of the box"
  set. Interaction ID is a small extra that helps when support asks for it.
* **Link.** The Link component opens the URL in a new browser tab, so the page
  does not need to allow iframe embedding and can be `http://` or `https://`.
  If you would rather show the page inside the script, use a **Web Page**
  component instead: the URL must then be `https://` and the site must allow
  framing (X-Frame-Options / CSP). Most public sites and SaaS logins block
  this, which is why the Link is the default here.
* **Disclaimer.** Read-only Text is fine for a paragraph. If you want line
  breaks or a bullet list, use a **Markdown** component with the same text.

### 3. Publish and assign

1. **Script > Publish**. Agents only ever see the published version.
2. Attach it in one of two places:
   * **Per queue:** Admin > Contact Center > Queues > the queue > **Voice** tab
     > **Default Script** = `Standard Inbound Script`. Every voice interaction
     on that queue gets it.
   * **Per flow:** in the inbound call flow in Architect, add a **Set Screen
     Pop** action before **Transfer to ACD** and choose this script. This
     overrides the queue default and works with the property enabled in step 1.
3. Take a test call. The details fill in as soon as the call is offered, and
   the link and disclaimer are visible without scrolling on a normal agent
   panel width.

## Optional: make the URL and disclaimer flow-driven

If different flows need a different page or wording, do not hardcode them:

1. **Script > Variables > Add**: String `Script.PageUrl` and String
   `Script.DisclaimerText`, each with **Input** ticked and the current text as
   the default value.
2. Point the Link's **Click Action > URL** at `{{Script.PageUrl}}` and set
   component 9's text to `{{Script.DisclaimerText}}`.
3. In Architect's **Set Screen Pop** action, map both inputs.

Leaving the inputs unmapped falls back to the defaults, so the queue-level
assignment keeps working unchanged.
