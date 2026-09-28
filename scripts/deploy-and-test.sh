#!/usr/bin/env bash
# Create (or update) and test the "Check Caller Recent Activity" data action
# through the Genesys Cloud Platform API.
#
# Required environment:
#   GC_REGION         e.g. mypurecloud.com, mypurecloud.ie, usw2.pure.cloud
#   GC_CLIENT_ID      OAuth client (client credentials grant)
#   GC_CLIENT_SECRET
#   GC_INTEGRATION_ID id of the active "Genesys Cloud Data Actions" integration
# Optional:
#   GC_ACTION_ID      existing action id to update instead of creating
#   TEST_ANI          ANI to test with, default tel:+15551234567
#
# The OAuth client's role needs integrations:action:add, integrations:action:edit,
# integrations:action:test and integrations:integration:view.
set -euo pipefail

: "${GC_REGION:?set GC_REGION}"
: "${GC_CLIENT_ID:?set GC_CLIENT_ID}"
: "${GC_CLIENT_SECRET:?set GC_CLIENT_SECRET}"
: "${GC_INTEGRATION_ID:?set GC_INTEGRATION_ID}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORT="$HERE/../data-actions/Check-Caller-Recent-Activity.json"
API="https://api.${GC_REGION}"

echo "Requesting token from login.${GC_REGION}"
TOKEN=$(curl -sS -f -X POST "https://login.${GC_REGION}/oauth/token" \
  -u "${GC_CLIENT_ID}:${GC_CLIENT_SECRET}" \
  -d 'grant_type=client_credentials' | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')
AUTH=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")

# Draft body = export + integrationId
BODY=$(python3 - "$EXPORT" "$GC_INTEGRATION_ID" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["integrationId"] = sys.argv[2]
print(json.dumps(d))
PY
)

if [[ -z "${GC_ACTION_ID:-}" ]]; then
  echo "Creating draft action"
  GC_ACTION_ID=$(curl -sS -f -X POST "${API}/api/v2/integrations/actions/drafts" "${AUTH[@]}" -d "$BODY" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
  echo "Created action ${GC_ACTION_ID}"
else
  echo "Updating draft of action ${GC_ACTION_ID}"
  curl -sS -f -X PATCH "${API}/api/v2/integrations/actions/${GC_ACTION_ID}/draft" "${AUTH[@]}" -d "$BODY" >/dev/null
fi

# Dynamic window for the test, mirroring what Architect computes at run time
START=$(date -u -d '-30 minutes' +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -v-30M +%Y-%m-%dT%H:%M:%S.000Z)
END=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
TEST_ANI="${TEST_ANI:-tel:+15551234567}"

echo "Testing draft with ani=${TEST_ANI} interval=${START}/${END}"
curl -sS -f -X POST "${API}/api/v2/integrations/actions/${GC_ACTION_ID}/draft/test" "${AUTH[@]}" \
  -d "$(python3 -c 'import json,sys;print(json.dumps({"ani":sys.argv[1],"intervalStart":sys.argv[2],"intervalEnd":sys.argv[3]}))' "$TEST_ANI" "$START" "$END")" \
  | python3 -m json.tool

cat <<MSG

Draft created/updated and tested. To publish it:
  curl -X POST "${API}/api/v2/integrations/actions/${GC_ACTION_ID}/draft/publish" -H "Authorization: Bearer \$TOKEN" -H "Content-Type: application/json" -d '{"version": <draft version>}'
or press Publish on the action in Admin > Integrations > Actions.
MSG
