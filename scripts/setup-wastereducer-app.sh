#!/bin/bash
# Configures the RUNNING 'ugec' realm for the WasteReducer app (realm-import only applies to a fresh realm).
# Safe to run many times (idempotent). It:
#   0. lets floor users be created with username = employee number and no email:
#      realm 'Email as username' off (existing usernames are not changed; email login still works),
#      and email no longer required in the user profile
#   1. creates the confidential client 'ugec-wastereducer-api' with the app roles as client roles
#      (Admin, Manager, Supervisor, Planner, Operator, AssistantOperator, InkKitchen, QC, Warehouse, ProcessLogger)
#      - service account: reads users / roles through the Admin API (employee directory)
#      - direct access grants: the API checks an approver's password on the press tablet (make-ready approvals)
#   2. gives its service account realm-management: view-users, query-users, view-clients, query-clients
#   3. adds an audience mapper to 'ugec-web' so its access tokens carry aud=ugec-wastereducer-api
#   4. adds the WasteReducer UI URLs to 'ugec-web' (redirect + post-logout redirect URIs)
#   5. gives the initial user (INITIAL_USER_EMAIL) the WasteReducer 'Admin' role
#   6. optional (WR_DEMO_USERS=true): demo floor users, username = employee number, one per role
#   7. prints the client secret for the API's user secrets (Keycloak:ClientSecret)
#
# Run from the KeyCloak folder (PowerShell):
#   docker compose run --rm -e KC_ADMIN_USER="mamondala@apobatangas.com" -e KC_ADMIN_PASSWORD="<your master password>" `
#     --entrypoint /bin/bash keycloak-init /opt/keycloak/scripts/setup-wastereducer-app.sh
# Add -e WR_DEMO_USERS=true (and optionally -e WR_DEMO_PASSWORD=...) for the demo users.
# KC_ADMIN_USER / KC_ADMIN_PASSWORD default to the bootstrap admin from .env (only works if tmp-admin still exists).
set -euo pipefail

KCADM=${KCADM:-/opt/keycloak/bin/kcadm.sh}
CFG=/tmp/kcadm-wastereducer.config
REALM=ugec
API_CLIENT=ugec-wastereducer-api
WEB_CLIENT=ugec-web
ADMIN_USER="${KC_ADMIN_USER:-$KC_BOOTSTRAP_ADMIN_USERNAME}"
ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-$KC_BOOTSTRAP_ADMIN_PASSWORD}"
ADMIN_REALM="${KC_ADMIN_REALM:-master}"
DEMO_USERS="${WR_DEMO_USERS:-false}"
DEMO_PASSWORD="${WR_DEMO_PASSWORD:-Floor_Demo1}"

# Vite dev server (npm run dev), the API serving the built SPA (https + http)
APP_URLS=("https://localhost:56848" "https://localhost:7073" "http://localhost:5230")

ROLES=(
  "Admin|System administrator: users, roles and all settings"
  "Manager|Production / plant manager: dashboards, master data, approvals"
  "Supervisor|Shift supervisor: live board, approvals, shift report"
  "Planner|Planner / PPIC: MOs, material issue, reconciliation"
  "Operator|Machine operator: run logger, parameter readings, scrap"
  "AssistantOperator|Assistant operator: scrap weighing, readings"
  "InkKitchen|Ink kitchen: ink and solvent issue / return"
  "QC|Quality control: readings and color approval"
  "Warehouse|Warehouse: substrate issue / return"
  "ProcessLogger|Process logger: takes timed parameter readings on the machines assigned per shift"
)

# employee no | first name | last name | role
DEMO=(
  "10372|Ben|Cruz|Manager"
  "10302|Liza|Mendoza|Supervisor"
  "10360|Anna|Lim|Planner"
  "10231|Ramon|Dela Cruz|Operator"
  "10277|Mark|Bautista|AssistantOperator"
  "10325|Nestor|Aquino|InkKitchen"
  "10340|Grace|Castillo|QC"
  "10352|Paolo|Torres|Warehouse"
  "10380|Joy|Ramos|ProcessLogger"
)

kc() { $KCADM "$@" --config "$CFG"; }
client_id() { kc get clients -r "$REALM" -q clientId="$1" --fields id --format csv --noquotes; }

echo ">> Logging in to ${KC_SERVER_URL} (realm ${ADMIN_REALM}) as ${ADMIN_USER}..."
kc config credentials --server "$KC_SERVER_URL" --realm "$ADMIN_REALM" --user "$ADMIN_USER" --password "$ADMIN_PASSWORD"

# --- 0. Realm: username = employee number, email optional ---------------------
echo ">> Realm ${REALM}: turning off 'Email as username' (usernames can be employee numbers)..."
kc update "realms/${REALM}" -s registrationEmailAsUsername=false

PROFILE=/tmp/wastereducer-user-profile.json
kc get users/profile -r "$REALM" > "$PROFILE"
if sed -n '/"name" : "email"/,/"permissions"/p' "$PROFILE" | grep -q '"required"'; then
  echo ">> Realm ${REALM}: making email optional in the user profile (floor staff often have none)..."
  sed -i '/"name" : "email"/,/"permissions"/{/"required" : {/,/},/d}' "$PROFILE"
  kc update users/profile -r "$REALM" -f "$PROFILE"
else
  echo ">> Email is already optional in the ${REALM} user profile."
fi

# --- 1. API client + roles ---------------------------------------------------
API_ID=$(client_id "$API_CLIENT")
if [ -z "$API_ID" ]; then
  echo ">> Creating client ${API_CLIENT}..."
  API_ID=$(kc create clients -r "$REALM" -i \
    -s clientId="$API_CLIENT" -s name="UGEC WasteReducer API" \
    -s 'description=Resource server for WasteReducer. Holds the app roles; tokens carry it as audience. Service account reads users; direct grant checks approver passwords.' \
    -s enabled=true -s protocol=openid-connect -s publicClient=false -s bearerOnly=false \
    -s clientAuthenticatorType=client-secret \
    -s standardFlowEnabled=false -s implicitFlowEnabled=false \
    -s directAccessGrantsEnabled=true -s serviceAccountsEnabled=true -s fullScopeAllowed=true)
else
  echo ">> Client ${API_CLIENT} already exists (id=${API_ID}); making sure grants are on."
  kc update "clients/${API_ID}" -r "$REALM" -s publicClient=false -s bearerOnly=false \
    -s directAccessGrantsEnabled=true -s serviceAccountsEnabled=true
fi

for entry in "${ROLES[@]}"; do
  name="${entry%%|*}"; desc="${entry#*|}"
  if kc get "clients/${API_ID}/roles/${name}" -r "$REALM" >/dev/null 2>&1; then
    echo ">> Role ${API_CLIENT}/${name} already exists."
  else
    echo ">> Creating role ${API_CLIENT}/${name}..."
    kc create "clients/${API_ID}/roles" -r "$REALM" -s name="$name" -s "description=WasteReducer: ${desc}"
  fi
done

# --- 2. Service account: read users and clients ------------------------------
echo ">> Granting realm-management view/query users + clients to the ${API_CLIENT} service account..."
kc add-roles -r "$REALM" --uusername "service-account-${API_CLIENT}" --cclientid realm-management \
  --rolename view-users --rolename query-users --rolename view-clients --rolename query-clients

# --- 3 + 4. SPA client: audience mapper + app URLs ---------------------------
WEB_ID=$(client_id "$WEB_CLIENT")
if [ -z "$WEB_ID" ]; then
  echo "!! Client ${WEB_CLIENT} not found in realm ${REALM}." >&2
  exit 1
fi

if kc get "clients/${WEB_ID}/protocol-mappers/models" -r "$REALM" | grep -q "\"${API_CLIENT}-audience\""; then
  echo ">> Audience mapper already on ${WEB_CLIENT}."
else
  echo ">> Adding audience mapper (aud=${API_CLIENT}) to ${WEB_CLIENT}..."
  kc create "clients/${WEB_ID}/protocol-mappers/models" -r "$REALM" \
    -s name="${API_CLIENT}-audience" -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
    -s "config.\"included.client.audience\"=${API_CLIENT}" \
    -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' \
    -s 'config."introspection.token.claim"=true'
fi

WEB_JSON=$(kc get "clients/${WEB_ID}" -r "$REALM")

# Redirect URIs (JSON array)
mapfile -t URIS < <(kc get "clients/${WEB_ID}" -r "$REALM" --fields redirectUris | grep -o '"[^"]*"' | grep -v '"redirectUris"' | tr -d '"')
CHANGED=false
for url in "${APP_URLS[@]}"; do
  if ! printf '%s\n' "${URIS[@]}" | grep -qxF "${url}/*"; then URIS+=("${url}/*"); CHANGED=true; fi
done
if $CHANGED; then
  JSON=$(printf '"%s",' "${URIS[@]}"); JSON="[${JSON%,}]"
  echo ">> Setting ${WEB_CLIENT} redirect URIs: ${JSON}"
  kc update "clients/${WEB_ID}" -r "$REALM" -s "redirectUris=${JSON}"
else
  echo ">> WasteReducer redirect URIs already on ${WEB_CLIENT}."
fi

# Post-logout redirect URIs (one attribute, '##'-separated)
POST_LOGOUT=$(printf '%s' "$WEB_JSON" | grep -o '"post.logout.redirect.uris" *: *"[^"]*"' | sed 's/.*: *"\(.*\)"/\1/' || true)
NEW_POST_LOGOUT="$POST_LOGOUT"
for url in "${APP_URLS[@]}"; do
  if ! printf '%s' "##${NEW_POST_LOGOUT}##" | grep -qF "##${url}/*##"; then
    NEW_POST_LOGOUT="${NEW_POST_LOGOUT:+${NEW_POST_LOGOUT}##}${url}/*"
  fi
done
if [ "$NEW_POST_LOGOUT" != "$POST_LOGOUT" ]; then
  echo ">> Setting ${WEB_CLIENT} post-logout redirect URIs: ${NEW_POST_LOGOUT}"
  kc update "clients/${WEB_ID}" -r "$REALM" -s "attributes.\"post.logout.redirect.uris\"=${NEW_POST_LOGOUT}"
else
  echo ">> WasteReducer post-logout redirect URIs already on ${WEB_CLIENT}."
fi

# --- 5. Initial user gets WasteReducer Admin ---------------------------------
if [ -n "${INITIAL_USER_EMAIL:-}" ]; then
  echo ">> Granting ${API_CLIENT}/Admin to ${INITIAL_USER_EMAIL} in realm ${REALM}..."
  kc add-roles -r "$REALM" --uusername "$INITIAL_USER_EMAIL" --cclientid "$API_CLIENT" --rolename Admin
fi

# --- 6. Demo floor users (optional) ------------------------------------------
if [ "$DEMO_USERS" = "true" ]; then
  for entry in "${DEMO[@]}"; do
    IFS='|' read -r no first last role <<< "$entry"
    USER_ID=$(kc get users -r "$REALM" -q username="$no" -q exact=true --fields id --format csv --noquotes)
    if [ -z "$USER_ID" ]; then
      echo ">> Creating demo user ${no} (${first} ${last}, ${role})..."
      USER_ID=$(kc create users -r "$REALM" -i -s username="$no" -s enabled=true \
        -s firstName="$first" -s lastName="$last")
      kc set-password -r "$REALM" --userid "$USER_ID" --new-password "$DEMO_PASSWORD"
    else
      echo ">> Demo user ${no} already exists."
    fi
    kc add-roles -r "$REALM" --uid "$USER_ID" --cclientid "$API_CLIENT" --rolename "$role"
  done
  echo ">> Demo users sign in with their employee number and password '${DEMO_PASSWORD}'."
fi

# --- 7. Client secret ---------------------------------------------------------
SECRET=$(kc get "clients/${API_ID}/client-secret" -r "$REALM" | grep -o '"value" *: *"[^"]*"' | sed 's/.*: *"\(.*\)"/\1/')
echo ""
echo ">> Done. ${API_CLIENT} client secret:"
echo "   ${SECRET}"
echo ">> Put it in the API's user secrets (from the WasteReducer folder):"
echo "   dotnet user-secrets --project WasteReducer.Server set \"Keycloak:ClientSecret\" \"${SECRET}\""
echo ">> Assign WasteReducer roles in Admin console: ${REALM} > Users > <user> > Role mapping > Assign role > Filter by clients > ${API_CLIENT}."
echo ">> Floor users: create them with username = employee number."
