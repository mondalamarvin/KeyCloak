# UGEC Keycloak (Docker + MySQL)

Local-development Keycloak identity server for UGEC apps, backed by MySQL.

| Item | Value |
|---|---|
| Keycloak | `26.4.7` (quay.io/keycloak/keycloak) — `start-dev` mode |
| Database | MySQL `8.4` LTS (utf8mb4) |
| Admin console | http://localhost:8080/admin |
| App realm | `ugec` |
| Initial user | `mamondala@apobatangas.com` — **master admin** + **ugec realm-admin** |

---

## 1. What's in this folder

```
KeyCloak/
├── docker-compose.yml          # mysql + keycloak + one-shot keycloak-init
├── .env                        # ports, passwords, initial user  (do NOT commit)
├── .env.example                # copy of .env for sharing/templates
├── realm-import/
│   └── ugec-realm.json         # 'ugec' realm: roles, groups, clients, initial user
├── scripts/
│   ├── init-master-admin.sh    # makes the initial user a permanent master admin
│   ├── setup-costing-app.sh    # Costing app client + roles (§14)
│   └── setup-wastereducer-app.sh  # WasteReducer client + roles (§15)
├── .gitattributes              # keeps *.sh as LF (required on Windows)
└── .gitignore
```

How it starts up:

1. **mysql** starts and becomes healthy.
2. **keycloak** starts, creates its tables in the `keycloak` database, creates a temporary `tmp-admin`, and imports `realm-import/ugec-realm.json` (only if the `ugec` realm doesn't exist yet).
3. **keycloak-init** waits for Keycloak to be healthy, then creates `mamondala@apobatangas.com` in the **master** realm with the `admin` role, and exits.

---

## 2. Prerequisites

- **Docker Desktop** for Windows (WSL 2 backend), running. Check in PowerShell:
  ```powershell
  docker --version
  docker compose version
  ```
- Free ports **8080** (Keycloak) and **3307** (MySQL on the host). You can change them in `.env`.
- ~2 GB free RAM for the containers.

---

## 3. Configure (`.env`)

Open `.env` and change the passwords. The defaults:

| Variable | Default | Purpose |
|---|---|---|
| `KEYCLOAK_PORT` | `8080` | Keycloak URL port on your PC |
| `MYSQL_PORT` | `3307` | MySQL port on your PC (3307 avoids clashing with a local MySQL) |
| `MYSQL_ROOT_PASSWORD` | `RootPass_ChangeMe1!` | MySQL root |
| `MYSQL_USER` / `MYSQL_PASSWORD` | `keycloak` / `KcDbPass_ChangeMe1!` | DB account Keycloak uses |
| `KC_BOOTSTRAP_ADMIN_USERNAME` / `_PASSWORD` | `tmp-admin` / `TmpAdmin_ChangeMe1!` | Temporary admin, first start only |
| `INITIAL_USER_EMAIL` | `mamondala@apobatangas.com` | Your login (username = email) |
| `INITIAL_USER_PASSWORD` | `Welcome_ChangeMe1!` | **Temporary** — you must change it on first login |

> Passwords must satisfy the realm policy: 8+ chars, 1 upper, 1 lower, 1 digit, not equal to the username.
>
> Change `.env` **before the first start**. After that, users and passwords live in MySQL and editing `.env` won't change them (see §11 to reset).

---

## 4. Start Keycloak

From this folder in PowerShell:

```powershell
cd "C:\Users\MARVIN MONDALA\Projects\UGEC\KeyCloak"
docker compose up -d
```

The first start pulls images and takes 1–2 minutes. Watch progress:

```powershell
docker compose ps -a
docker compose logs -f keycloak        # Ctrl+C to stop following
```

You're ready when:

- `ugec-keycloak` and `ugec-keycloak-mysql` show **(healthy)**
- `ugec-keycloak-init` shows **Exited (0)**

Confirm the init job worked:

```powershell
docker compose logs keycloak-init
```

Expected output ends with:
```
>> Granting 'admin' role in master realm...
>> Done. Log in at http://keycloak:8080/admin with mamondala@apobatangas.com.
```

---

## 5. Log in to the Admin Console

1. Open **http://localhost:8080/admin**
2. Username: `mamondala@apobatangas.com`
3. Password: the `INITIAL_USER_PASSWORD` from `.env`
4. Keycloak asks you to **set a new password**. Do it.
5. Use the realm dropdown (top-left) to switch between **master** and **ugec**.

---

## 6. Remove the temporary admin (recommended)

Keycloak shows a banner while the temporary admin exists. Once you've logged in as yourself:

1. Realm **master** → **Users**
2. Open `tmp-admin` → **Action** (top-right) → **Delete**

> After deleting it, `keycloak-init` just logs "Bootstrap admin login failed… Nothing to do" on later starts. That's expected.

---

## 7. What's preconfigured in the `ugec` realm

**Realm settings**

- Login with email, remember-me, forgot-password enabled; self-registration **off**
- Brute-force protection (5 failures → temporary lockout, max 15 min)
- Access token 5 min, SSO idle 30 min, SSO max 10 h

**Roles and groups**

| Realm role | Description |
|---|---|
| `ugec-admin` | App administrator |
| `ugec-user` | App user (given to every new user by default) |

| Group | Roles |
|---|---|
| `/Administrators` | `ugec-admin`, `ugec-user` |
| `/Users` | `ugec-user` |

**Clients**

| Client ID | Type | Use for |
|---|---|---|
| `ugec-web` | Public, Auth Code + **PKCE (S256)** | React/Vite/vanilla JS front-ends on `localhost:5173` or `localhost:3000` |
| `ugec-api` | Confidential, service account | Backend APIs (client-credentials, token introspection) |

**Initial user** `mamondala@apobatangas.com`: member of `/Administrators`, roles `ugec-admin`, `ugec-user`, and `realm-management → realm-admin` (full control of the ugec realm).

Test the end-user login at the account console: **http://localhost:8080/realms/ugec/account** (it also asks for a new password the first time, since the ugec account is separate from the master account).

---

## 8. Get the `ugec-api` client secret

1. Admin console → realm **ugec** → **Clients** → `ugec-api`
2. Tab **Credentials** → copy **Client Secret**

Test it from PowerShell:

```powershell
$body = @{ grant_type="client_credentials"; client_id="ugec-api"; client_secret="<PASTE_SECRET>" }
Invoke-RestMethod -Method Post -Uri "http://localhost:8080/realms/ugec/protocol/openid-connect/token" -Body $body
```

You should get back an `access_token`.

---

## 9. Connect an app

**Useful endpoints (realm `ugec`)**

| Purpose | URL |
|---|---|
| OIDC discovery | http://localhost:8080/realms/ugec/.well-known/openid-configuration |
| Issuer | `http://localhost:8080/realms/ugec` |
| Token | `http://localhost:8080/realms/ugec/protocol/openid-connect/token` |
| JWKS (public keys) | `http://localhost:8080/realms/ugec/protocol/openid-connect/certs` |
| Account console | http://localhost:8080/realms/ugec/account |

**Front-end example (React / Vite) with `keycloak-js`**

```bash
yarn add keycloak-js
```

```js
// src/keycloak.js
import Keycloak from "keycloak-js";

const keycloak = new Keycloak({
  url: "http://localhost:8080",
  realm: "ugec",
  clientId: "ugec-web",
});

export async function initAuth() {
  const authenticated = await keycloak.init({
    onLoad: "login-required",
    pkceMethod: "S256",
    checkLoginIframe: false,
  });
  // Refresh the token shortly before it expires
  setInterval(() => keycloak.updateToken(60).catch(() => keycloak.login()), 30000);
  return authenticated;
}

export const hasRole = (role) => keycloak.hasRealmRole(role); // e.g. "ugec-admin"
export default keycloak;
```

Send `Authorization: Bearer ${keycloak.token}` to your API. The backend validates the JWT using the **Issuer** and **JWKS** URLs above. Realm roles are in the token's `realm_access.roles` claim.

> If your app runs on another port, add it in **Clients → ugec-web → Valid redirect URIs** (e.g. `http://localhost:4200/*`).

---

## 10. Day-to-day commands

| Task | Command |
|---|---|
| Start | `docker compose up -d` |
| Stop (keeps data) | `docker compose down` |
| Status | `docker compose ps -a` |
| Logs | `docker compose logs -f keycloak` |
| Restart Keycloak only | `docker compose restart keycloak` |
| Re-run the admin init job | `docker compose run --rm keycloak-init` |
| MySQL shell | `docker exec -it ugec-keycloak-mysql mysql -ukeycloak -p keycloak` |

From a GUI client (DBeaver, Workbench): host `localhost`, port `3307`, database `keycloak`, user `keycloak`, password from `.env`.

**Back up the database**

```powershell
docker exec ugec-keycloak-mysql sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" keycloak' > keycloak-backup.sql
```

**Export the ugec realm** (to version your config changes):

```powershell
docker exec ugec-keycloak /opt/keycloak/bin/kc.sh export --dir /tmp/export --realm ugec --users realm_file
docker cp ugec-keycloak:/tmp/export/ugec-realm.json .\ugec-realm-export.json
```

---

## 11. Reset everything (fresh start)

This **deletes all Keycloak data** (users, sessions, realm changes):

```powershell
docker compose down -v
docker compose up -d
```

The realm is imported again from `realm-import/ugec-realm.json` and the init job recreates your admin user with the passwords currently in `.env`.

---

## 12. Troubleshooting

| Symptom | Fix |
|---|---|
| MySQL log: `MYSQL_USER="root" ... cannot be used for the root user` | `MYSQL_USER` in `.env` must be a normal account (e.g. `keycloak`), not `root`. Fix it, then `docker compose down -v` and `docker compose up -d` |
| `port is already allocated` | Change `KEYCLOAK_PORT` or `MYSQL_PORT` in `.env`, then `docker compose up -d` |
| `keycloak-init` fails with `bad interpreter` / `\r` errors | The script got Windows (CRLF) line endings. In VS Code open `scripts/init-master-admin.sh`, click **CRLF** in the status bar → **LF**, save, then `docker compose run --rm keycloak-init` |
| Keycloak stays **unhealthy** | `docker compose logs keycloak` — usually wrong DB password. If you changed DB passwords after the first start, run §11 |
| "Invalid parameter: redirect_uri" | Add your app URL to **ugec-web → Valid redirect URIs** |
| CORS errors in the browser | **ugec-web → Web origins** must include your app origin (or `+`, which allows all redirect-URI origins) |
| Changes to `ugec-realm.json` not applied | Import runs only when the realm doesn't exist. Edit in the admin console, or reset (§11) |
| Forgot admin password | `docker compose down -v` (§11), or log in with `tmp-admin` if you haven't deleted it |

---

## 13. Going to production (later)

This setup is for **local development**. For a server deployment:

- Run `start` (optimized), not `start-dev`, and set `KC_HOSTNAME=https://sso.yourdomain.com`
- Put HTTPS in front (Nginx/Traefik) and set `KC_PROXY_HEADERS=xforwarded`; set the realm's **Require SSL** to *all requests*
- Don't publish MySQL's port; use strong secrets (Docker secrets / a vault)
- Set up SMTP (**Realm settings → Email**) for password reset and email verification
- Schedule MySQL backups, and pin image versions (already done in `.env`)

---

## 14. Costing app (`ugec-costing-api`)

The UGEC Costing app (API `localhost:5062`, React UI `localhost:5173`) signs in through this realm.

| Item | Value |
|---|---|
| UI client | `ugec-web` (Auth Code + PKCE) — has an audience mapper so access tokens carry `aud: ugec-costing-api` |
| API client | `ugec-costing-api` — bearer-only, holds the app roles |
| Client roles | `Admin` (everything), `Estimator` (create/edit jobs & estimates), `Viewer` (read-only) |
| Token claim | `resource_access.ugec-costing-api.roles` |

A user with **no** Costing role can sign in but sees "No access to the Costing app".

**Apply to the running realm** (realm-import only runs for a new realm). From this folder:

```powershell
docker compose run --rm -e KC_ADMIN_USER="mamondala@apobatangas.com" -e KC_ADMIN_PASSWORD="<your master password>" `
  --entrypoint /bin/bash keycloak-init /opt/keycloak/scripts/setup-costing-app.sh
```

It's idempotent: creates the client + roles, adds the audience mapper and Swagger redirect URIs to `ugec-web`, and gives `INITIAL_USER_EMAIL` the `Admin` role.

**Give someone access:** realm `ugec` → **Users** → user → **Role mapping** → **Assign role** → filter **by clients** → `ugec-costing-api` → pick `Admin` / `Estimator` / `Viewer`. They must sign out and in again (or wait ≤ 5 min for the token to refresh).

---

## 15. WasteReducer app (`ugec-wastereducer-api`)

WasteReducer (API `https://localhost:7073`, React UI `https://localhost:56848`) signs in through this realm. It has no user tables of its own: users, passwords and roles are all here.

| Item | Value |
|---|---|
| UI client | `ugec-web` (Auth Code + PKCE) — audience mapper so access tokens carry `aud: ugec-wastereducer-api` |
| API client | `ugec-wastereducer-api` — **confidential**: holds the app roles; its service account reads users (shift crew pickers, names on reports); direct-access grant lets the API check an approver's password on the press tablet (make-ready approval / waiver) |
| Client roles | `Admin`, `Manager`, `Supervisor`, `Planner`, `Operator`, `AssistantOperator`, `InkKitchen`, `QC`, `Warehouse`, `ProcessLogger` |
| Token claim | `resource_access.ugec-wastereducer-api.roles` |
| Employee no. | = Keycloak **username**. Create floor staff with username `10231` etc. (email optional). Office users can keep their email as username |

A user with **no** WasteReducer role can sign in but sees "No access to WasteReducer".

**Apply to the running realm** (realm-import only runs for a new realm; also run it after a reset — it sets things the import can't). From this folder:

```powershell
docker compose run --rm -e KC_ADMIN_USER="mamondala@apobatangas.com" -e KC_ADMIN_PASSWORD="<your master password>" `
  --entrypoint /bin/bash keycloak-init /opt/keycloak/scripts/setup-wastereducer-app.sh
```

Add `-e WR_DEMO_USERS=true` for 9 demo floor users (10372 Manager, 10302 Supervisor, 10360 Planner, 10231 Operator, 10277 Asst. Operator, 10325 Ink Kitchen, 10340 QC, 10352 Warehouse, 10380 Process Logger; password `Floor_Demo1`, or set `-e WR_DEMO_PASSWORD=...`). Don't use demo users on a shared server.

The script is idempotent. It:

1. turns **off** realm setting *Email as username* (Realm settings → Login) and makes **email optional** in the user profile, so floor users can have their employee number as username and no email. Existing usernames don't change and email login still works — but from now on the admin console asks for a username when you create a user (Costing users too)
2. creates `ugec-wastereducer-api` + the 10 roles, and gives its service account `realm-management` → `view-users`, `query-users`, `view-clients`, `query-clients`
3. adds the audience mapper and the WasteReducer URLs (redirect + post-logout) to `ugec-web`
4. gives `INITIAL_USER_EMAIL` the WasteReducer `Admin` role
5. prints the **client secret** — put it in the API's user secrets:

```powershell
cd "C:\Users\MARVIN MONDALA\Projects\UGEC\WasteReducer"
dotnet user-secrets --project WasteReducer.Server set "Keycloak:ClientSecret" "<secret>"
```

(Later: Clients → `ugec-wastereducer-api` → Credentials.)

**Give someone access:** realm `ugec` → **Users** → **Add user** (username = employee number, first + last name) → **Credentials** → set password → **Role mapping** → **Assign role** → filter **by clients** → `ugec-wastereducer-api` → pick the role(s). Role changes reach the app at the next token refresh (≤ 5 min) or sign-in.

> Approver checks use the person's Keycloak password, so wrong passwords count towards the brute-force lockout (5 tries). If a user still has pending required actions (e.g. a temporary password), they must sign in to WasteReducer once before they can approve.

