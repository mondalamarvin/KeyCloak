#!/bin/bash
# Configures the RUNNING 'ugec' realm for the Costing app (realm-import only applies to a fresh realm).
# Safe to run many times (idempotent). It:
#   1. creates the bearer-only client 'ugec-costing-api' with client roles Admin, Estimator, Viewer
#   2. adds an audience mapper to 'ugec-web' so its access tokens carry aud=ugec-costing-api
#   3. adds the Swagger UI redirect URIs of the API to 'ugec-web'
#   4. gives the initial user (INITIAL_USER_EMAIL) the Costing 'Admin' role
#
# Run from the KeyCloak folder (PowerShell):
#   docker compose run --rm -e KC_ADMIN_USER="mamondala@apobatangas.com" -e KC_ADMIN_PASSWORD="<your master password>" `
#     --entrypoint /bin/bash keycloak-init /opt/keycloak/scripts/setup-costing-app.sh
# KC_ADMIN_USER / KC_ADMIN_PASSWORD default to the bootstrap admin from .env (only works if tmp-admin still exists).
set -euo pipefail

KCADM=/opt/keycloak/bin/kcadm.sh
CFG=/tmp/kcadm-costing.config
REALM=ugec
API_CLIENT=ugec-costing-api
WEB_CLIENT=ugec-web
ADMIN_USER="${KC_ADMIN_USER:-$KC_BOOTSTRAP_ADMIN_USERNAME}"
ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-$KC_BOOTSTRAP_ADMIN_PASSWORD}"
ADMIN_REALM="${KC_ADMIN_REALM:-master}"
SWAGGER_REDIRECTS=("http://localhost:5062/swagger/oauth2-redirect.html" "https://localhost:7273/swagger/oauth2-redirect.html")

kc() { $KCADM "$@" --config "$CFG"; }

echo ">> Logging in to ${KC_SERVER_URL} (realm ${ADMIN_REALM}) as ${ADMIN_USER}..."
kc config credentials --server "$KC_SERVER_URL" --realm "$ADMIN_REALM" --user "$ADMIN_USER" --password "$ADMIN_PASSWORD"

# --- 1. API client + roles -------------------------------------------------
API_ID=$(kc get clients -r "$REALM" -q clientId="$API_CLIENT" --fields id --format csv --noquotes)
if [ -z "$API_ID" ]; then
  echo ">> Creating client ${API_CLIENT}..."
  API_ID=$(kc create clients -r "$REALM" -i \
    -s clientId="$API_CLIENT" -s name="UGEC Costing API" \
    -s 'description=Resource server for the Costing app. Holds the app roles; tokens carry it as audience.' \
    -s enabled=true -s protocol=openid-connect -s publicClient=false -s bearerOnly=true \
    -s standardFlowEnabled=false -s implicitFlowEnabled=false \
    -s directAccessGrantsEnabled=false -s serviceAccountsEnabled=false)
else
  echo ">> Client ${API_CLIENT} already exists (id=${API_ID})."
fi

create_role() {
  local name="$1" desc="$2"
  if kc get "clients/${API_ID}/roles/${name}" -r "$REALM" >/dev/null 2>&1; then
    echo ">> Role ${API_CLIENT}/${name} already exists."
  else
    echo ">> Creating role ${API_CLIENT}/${name}..."
    kc create "clients/${API_ID}/roles" -r "$REALM" -s name="$name" -s "description=${desc}"
  fi
}
create_role Admin     "Costing app: full access incl. master data"
create_role Estimator "Costing app: create / edit jobs and estimates"
create_role Viewer    "Costing app: read-only"

# --- 2 + 3. SPA client: audience mapper + Swagger redirect URIs --------------
WEB_ID=$(kc get clients -r "$REALM" -q clientId="$WEB_CLIENT" --fields id --format csv --noquotes)
if [ -z "$WEB_ID" ]; then
  echo "!! Client ${WEB_CLIENT} not found in realm ${REALM}." >&2
  exit 1
fi

if kc get "clients/${WEB_ID}/protocol-mappers/models" -r "$REALM" | grep -q '"ugec-costing-api-audience"'; then
  echo ">> Audience mapper already on ${WEB_CLIENT}."
else
  echo ">> Adding audience mapper (aud=${API_CLIENT}) to ${WEB_CLIENT}..."
  kc create "clients/${WEB_ID}/protocol-mappers/models" -r "$REALM" \
    -s name=ugec-costing-api-audience -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
    -s "config.\"included.client.audience\"=${API_CLIENT}" \
    -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' \
    -s 'config."introspection.token.claim"=true'
fi

mapfile -t URIS < <(kc get "clients/${WEB_ID}" -r "$REALM" --fields redirectUris | grep -o '"[^"]*"' | grep -v '"redirectUris"' | tr -d '"')
CHANGED=false
for uri in "${SWAGGER_REDIRECTS[@]}"; do
  if ! printf '%s\n' "${URIS[@]}" | grep -qxF "$uri"; then URIS+=("$uri"); CHANGED=true; fi
done
if $CHANGED; then
  JSON=$(printf '"%s",' "${URIS[@]}"); JSON="[${JSON%,}]"
  echo ">> Setting ${WEB_CLIENT} redirect URIs: ${JSON}"
  kc update "clients/${WEB_ID}" -r "$REALM" -s "redirectUris=${JSON}"
else
  echo ">> Swagger redirect URIs already on ${WEB_CLIENT}."
fi

# --- 4. Initial user gets Costing Admin --------------------------------------
if [ -n "${INITIAL_USER_EMAIL:-}" ]; then
  echo ">> Granting ${API_CLIENT}/Admin to ${INITIAL_USER_EMAIL} in realm ${REALM}..."
  kc add-roles -r "$REALM" --uusername "$INITIAL_USER_EMAIL" --cclientid "$API_CLIENT" --rolename Admin
fi

echo ">> Done. Assign Costing roles in Admin console: ${REALM} > Users > <user> > Role mapping > Assign role > Filter by clients > ${API_CLIENT}."
