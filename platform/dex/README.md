# Dex: shared OIDC issuer

**Issuer:** `https://dex.carlboettiger.info`
(discovery at `/.well-known/openid-configuration`).

Dex logs people in with GitHub and issues standard OIDC tokens. The ID token
is a signed JWT carrying `sub` (the GitHub user ID), `preferred_username` (the
GitHub login), `email` and `groups`. Any service can verify it offline against
Dex's published keys. `groups` holds `org` and `org:team` strings (team
slugs). Login requires membership in one of the orgs listed under the
connector in `values.yaml`.

Services trust Dex rather than GitHub directly, so access is managed in one
place: removing someone from the GitHub org stops new tokens for every service.

## Files

| | |
|---|---|
| `values.yaml` | Helm values for the official chart ([charts.dexidp.io](https://charts.dexidp.io)): config, connector, clients, ingress |
| `setup-secrets.sh` | creates the `dex-github` Secret (GitHub OAuth client secret) |
| `up.sh` | `helm upgrade -i` with the pinned chart version |

## Deploy

```bash
./setup-secrets.sh   # once, or to rotate the GitHub client secret
./up.sh
curl -s https://dex.carlboettiger.info/.well-known/openid-configuration | jq .issuer
```

## Adding a client

Add an entry under `config.staticClients` in `values.yaml` and re-run `./up.sh`.
Give each consuming service its own client. The ID token's `aud` is the client
ID, so a service that checks `aud` won't accept a token minted for another one.

- **CLIs and agents:** `public: true`, no secret. Dex allows public clients to
  use `http://localhost:<any port>` and `/device/callback` (the device grant,
  for headless login).
- **Web apps:** a confidential client with a `secret`. Supply the secret from
  env the same way as the GitHub secret (`$VAR` in config, `envVars` from a
  Secret) and keep it out of this file.

Clients today: `openshell-cli` (see `../../services/openshell/`).

## Storage

`storage.type: kubernetes`: Dex keeps sessions, refresh tokens and its signing
keys as `dex.coreos.com` custom resources in the cluster datastore. Everything
else is in `values.yaml`. Losing the store only forces users to log in again.
