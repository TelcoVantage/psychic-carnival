#!/usr/bin/env python3
"""Assemble and validate the Genesys Cloud data action export.

Reads the readable Velocity sources in data-actions/src/, injects them into
the action definition, validates the JSON Schema contracts, and writes the
importable export to data-actions/Check-Caller-Recent-Activity.json.

Usage:
    python3 scripts/build.py          # build + validate
    python3 scripts/build.py --check  # validate that the committed export is current
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "data-actions" / "src"
OUT = ROOT / "data-actions" / "Check-Caller-Recent-Activity.json"

DRAFT4 = "http://json-schema.org/draft-04/schema#"


def action_definition(request_vm: str, success_vm: str) -> dict:
    return {
        "name": "Check Caller Recent Activity",
        "integrationType": "purecloud-data-actions",
        "actionType": "custom",
        "config": {
            "request": {
                "requestUrlTemplate": "/api/v2/analytics/conversations/details/query",
                "requestType": "POST",
                "headers": {},
                "requestTemplate": request_vm,
            },
            "response": {
                "translationMap": {
                    "totalHits": "$.totalHits",
                    "conversationIds": "$.conversations[*].conversationId",
                    "lastCallConversationId": "$.conversations[0].conversationId",
                    "lastCallStart": "$.conversations[0].conversationStart",
                    "lastCallEnd": "$.conversations[0].conversationEnd",
                },
                "translationMapDefaults": {
                    "totalHits": "0",
                    "conversationIds": "[]",
                    "lastCallConversationId": "\"\"",
                    "lastCallStart": "\"\"",
                    "lastCallEnd": "\"\"",
                },
                "successTemplate": success_vm,
            },
        },
        "contract": {
            "input": {
                "inputSchema": {
                    "$schema": DRAFT4,
                    "title": "Check Caller Recent Activity - Input",
                    "type": "object",
                    "properties": {
                        "ani": {
                            "type": "string",
                            "description": (
                                "Caller's ANI exactly as Genesys Cloud records it, e.g. "
                                "tel:+15551234567. In Architect pass Call.Ani. A bare "
                                "number is prefixed with tel: automatically."
                            ),
                        },
                        "intervalStart": {
                            "type": "string",
                            "description": (
                                "Start of the look-back window, ISO-8601 UTC. Compute at "
                                "run time in Architect: "
                                "ToString(AddMinutes(GetCurrentDateTimeUtc(), -30))"
                            ),
                        },
                        "intervalEnd": {
                            "type": "string",
                            "description": (
                                "End of the look-back window, ISO-8601 UTC. Compute at run "
                                "time in Architect: ToString(GetCurrentDateTimeUtc())"
                            ),
                        },
                    },
                    "required": ["ani", "intervalStart", "intervalEnd"],
                    "additionalProperties": True,
                }
            },
            "output": {
                "successSchema": {
                    "$schema": DRAFT4,
                    "title": "Check Caller Recent Activity - Output",
                    "type": "object",
                    "properties": {
                        "hasCalledRecently": {
                            "type": "boolean",
                            "description": "True when at least one completed inbound voice call from this ANI started inside the window.",
                        },
                        "priorCallCount": {
                            "type": "integer",
                            "description": "Number of completed inbound voice calls from this ANI inside the window (excludes the in-progress call).",
                        },
                        "lastCallConversationId": {
                            "type": "string",
                            "description": "Conversation ID of the most recent matching call, or empty string.",
                        },
                        "lastCallStart": {
                            "type": "string",
                            "description": "conversationStart of the most recent matching call (ISO-8601), or empty string.",
                        },
                        "lastCallEnd": {
                            "type": "string",
                            "description": "conversationEnd of the most recent matching call (ISO-8601), or empty string.",
                        },
                        "conversationIds": {
                            "type": "array",
                            "description": "Conversation IDs of matching calls, most recent first (max 25).",
                            "items": {"type": "string"},
                        },
                    },
                    "additionalProperties": True,
                }
            },
        },
        "secure": False,
    }


def strip_vm_comments(text: str) -> str:
    """Drop full-line Velocity '##' comments so the export stays compact.

    Inline '##' comments are left alone; only lines that start with '##'
    (after leading whitespace) are removed.
    """
    kept = [ln for ln in text.splitlines() if not ln.lstrip().startswith("##")]
    return "\n".join(kept).strip() + "\n"


def validate(definition: dict) -> list:
    problems = []
    try:
        import jsonschema  # type: ignore

        meta = jsonschema.Draft4Validator.META_SCHEMA
        for label, schema in (
            ("inputSchema", definition["contract"]["input"]["inputSchema"]),
            ("successSchema", definition["contract"]["output"]["successSchema"]),
        ):
            for err in jsonschema.Draft4Validator(meta).iter_errors(schema):
                problems.append(f"{label}: {err.message}")
    except ImportError:
        print("note: jsonschema not installed, skipping meta-schema validation")

    resp = definition["config"]["response"]
    for key in resp["translationMap"]:
        if key not in resp["translationMapDefaults"]:
            problems.append(f"translationMap key '{key}' has no default")
        if f"${key}" not in resp["successTemplate"] and f"${{{key}}}" not in resp["successTemplate"]:
            problems.append(f"translationMap key '{key}' is unused in successTemplate")
    for default in resp["translationMapDefaults"].values():
        try:
            json.loads(default)
        except json.JSONDecodeError:
            problems.append(f"translationMapDefault {default!r} is not valid JSON text")

    req = definition["config"]["request"]["requestTemplate"]
    for name in definition["contract"]["input"]["inputSchema"]["required"]:
        if f"$input.{name}" not in req and f"${{input.{name}}}" not in req:
            problems.append(f"required input '{name}' is never referenced in requestTemplate")
    return problems


def main() -> int:
    request_vm = strip_vm_comments((SRC / "request.vm").read_text())
    success_vm = strip_vm_comments((SRC / "success.vm").read_text())
    definition = action_definition(request_vm, success_vm)

    problems = validate(definition)
    if problems:
        print("validation failed:")
        for p in problems:
            print("  -", p)
        return 1

    rendered = json.dumps(definition, indent=2) + "\n"
    if "--check" in sys.argv:
        if OUT.read_text() != rendered:
            print(f"{OUT.relative_to(ROOT)} is out of date; run scripts/build.py")
            return 1
        print("export is current and valid")
        return 0

    OUT.write_text(rendered)
    print(f"wrote {OUT.relative_to(ROOT)} ({len(rendered)} bytes), contracts valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
