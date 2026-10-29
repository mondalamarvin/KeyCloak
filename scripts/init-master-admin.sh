#!/bin/bash
# Creates the initial user as a permanent admin in the MASTER realm.
# Safe to run many times (idempotent).
set -euo pipefail

KCADM=/opt/keycloak/bin/kcadm.sh
CFG=/tmp/kcadm.config
USER_NAME="${INITIAL_USER_EMAIL}"

echo ">> Logging in to ${KC_SERVER_URL} as bootstrap admin..."
if ! $KCADM config credentials --config "$CFG" --server "$KC_SERVER_URL" \
      --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" 2>/dev/null; then
  echo ">> Bootstrap admin login failed (it was probably deleted already). Nothing to do."
  exit 0
fi

USER_ID=$($KCADM get users --config "$CFG" -r master -q username="$USER_NAME" -q exact=true \
          --fields id --format csv --noquotes)

if [ -z "$USER_ID" ]; then
  echo ">> Creating master admin user ${USER_NAME}..."
  $KCADM create users --config "$CFG" -r master \
    -s username="$USER_NAME" -s email="$USER_NAME" -s emailVerified=true -s enabled=true \
    -s firstName="$INITIAL_USER_FIRSTNAME" -s lastName="$INITIAL_USER_LASTNAME"
  $KCADM set-password --config "$CFG" -r master --username "$USER_NAME" \
    --new-password "$INITIAL_USER_PASSWORD" --temporary
else
  echo ">> User ${USER_NAME} already exists in master (id=${USER_ID})."
fi

echo ">> Granting 'admin' role in master realm..."
$KCADM add-roles --config "$CFG" -r master --uusername "$USER_NAME" --rolename admin

echo ">> Done. Log in at ${KC_SERVER_URL%/}/admin with ${USER_NAME}."
