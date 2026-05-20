#!/bin/sh
# The front nginx template hardcodes `server api:5000` as the upstream,
# expecting Docker bridge DNS to resolve the service name. In the sidecar
# pattern there is no bridge network, but api IS on 127.0.0.1 (shared
# loopback). Patch the config after envsubst has processed the template.
sed -i 's/server api:/server 127.0.0.1:/g' /etc/nginx/conf.d/default.conf
