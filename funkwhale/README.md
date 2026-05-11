# Funkwhale (stub)

Not yet templated. Funkwhale's deployment shape (api + celeryworker +
celerybeat + a frontend nginx that serves uploaded media) is more involved
than the apps already in this repo, and we want to validate the
shared-db + pixelfed + mastodon + diaspora baseline before adding it.

## What's needed when we get to it

- `docker-compose.yml` with sidecars for `tag:funkwhale-web` (api + frontend)
  and `tag:funkwhale-worker` (celery worker + beat sharing one sidecar).
- New env vars in repo-root `.env.example`:
  `FUNKWHALE_DOMAIN`, `FUNKWHALE_DB_*`, `FUNKWHALE_DJANGO_SECRET_KEY`,
  `FUNKWHALE_WEB_MAGIC_NAME`, `FUNKWHALE_WORKER_MAGIC_NAME`.
- Add the new tags to `acl.example.hujson` `tagOwners` and to the
  DB-access rule's `src` list.
- Decide how Funkwhale's media volume is exposed — its frontend nginx
  serves uploaded files directly, which complicates the host-nginx-only
  pattern. Likely: serve through the api container, or mount the media
  volume into the host nginx.
- Reference snippet in `nginx/sites-available/funkwhale.conf`.

## Upstream references

- https://docs.funkwhale.audio/admin/installation/docker.html
- https://dev.funkwhale.audio/funkwhale/funkwhale/-/blob/stable/docker/docker-compose.yml
