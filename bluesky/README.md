# Bluesky PDS (stub)

Not yet templated. The Bluesky Personal Data Server is much more
self-contained than the ActivityPub apps in this repo (single container,
SQLite by default with optional Postgres, no separate worker tier), so
adding it should be straightforward — but we want to prove the baseline
pattern first before introducing AT Protocol.

## What's needed when we get to it

- `docker-compose.yml` with one sidecar `tag:bluesky-pds`. PDS reaches
  shared Postgres if you opt in to Postgres mode, otherwise no DB
  dependency at all.
- New env vars in repo-root `.env.example`:
  `BLUESKY_DOMAIN`, `BLUESKY_PDS_MAGIC_NAME`, `BLUESKY_PDS_ADMIN_PASSWORD`,
  `BLUESKY_PDS_JWT_SECRET`, `BLUESKY_PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX`.
- Add the new tag to `acl.example.hujson` `tagOwners`. Whether to add it
  to the DB-access rule depends on whether you run PDS in Postgres mode.
- Reference snippet in `nginx/sites-available/bluesky.conf`.

## Upstream references

- https://github.com/bluesky-social/pds
- https://github.com/bluesky-social/pds/blob/main/compose.yaml
