#!/usr/bin/env bash
# Evaluation: does the client address survive the deployed edge?
#   [Cloudflare edge + cloudflared stand-in] -> kamal-proxy v0.9.2 :80 (no host
#   ports) -> Thruster -> Puma -> Rails, on a private Docker network with its
#   own throwaway PostgreSQL. It runs once with kamal-proxy's forward-headers
#   off and once on, and prints the headers that reach Puma, Rails'
#   remote_ip, sign-in rate-limit outcomes, the "Started ... for" log line and
#   kamal-proxy's stored forward_headers. See production-deploy.md step 11.
# Nothing here touches the development database, .env, Cloudflare or any
# external service. Everything is removed on exit.
#
# Usage, with an image built from this checkout:
#   IMAGE=three-heavens:local script/evaluations/cloudflare_tunnel/run.sh
set -euo pipefail
IMAGE=${IMAGE:?}
DIR=$(cd "$(dirname "$0")" && pwd)
RUN=th-tunnel-$$
NET=$RUN PG=$RUN-pg APP=$RUN-app ECHO=$RUN-echo PROXY=$RUN-proxy
PASS=$(openssl rand -hex 16)

cleanup() { docker rm -fv $PG $APP $ECHO $PROXY >/dev/null 2>&1 || true; docker network rm $NET >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker network create $NET >/dev/null
docker run -d --name $PG --network $NET -e POSTGRES_PASSWORD=$PASS postgres:17 >/dev/null
until docker exec $PG psql -U postgres -h 127.0.0.1 -c 'select 1' >/dev/null 2>&1; do sleep 0.5; done

url() { echo "postgres://postgres:$PASS@$PG:5432/three_heavens_tunnel_$1"; }
docker run -d --name $APP --network $NET \
  -e DATABASE_URL=$(url primary) -e CACHE_DATABASE_URL=$(url cache) -e QUEUE_DATABASE_URL=$(url queue) -e CABLE_DATABASE_URL=$(url cable) \
  -e APP_HOST=threeheavens.test -e SECRET_KEY_BASE=$(openssl rand -hex 64) -e MAIL_FROM=tunnel@example.invalid \
  -e SMTP_HOST=smtp.example.invalid -e SMTP_USERNAME=unused -e SMTP_PASSWORD=unused -e GOOGLE_CLIENT_ID=unused.apps.googleusercontent.com \
  -e SOLID_QUEUE_IN_PUMA=true -e RAILS_LOG_LEVEL=info $IMAGE >/dev/null
docker run -d --name $ECHO --network $NET -v "$DIR:/work:ro" $IMAGE ./bin/thrust ruby /work/echo.rb >/dev/null
docker run -d --name $PROXY --network $NET basecamp/kamal-proxy:v0.9.2 >/dev/null
for i in $(seq 1 240); do docker exec $APP curl -fsS http://127.0.0.1:80/up >/dev/null 2>&1 && break; sleep 0.5; done
docker exec $APP curl -fsS http://127.0.0.1:80/up >/dev/null || { docker logs --tail 40 $APP; exit 1; }
echo "kamal-proxy addr: $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $PROXY)" >&2

deploy() { # target, forward-headers flag
  docker exec $PROXY kamal-proxy deploy three_heavens --target=$1:80 --host=threeheavens.test --health-check-path=/up \
    --buffer-requests --buffer-responses --max-request-body=22020096 "$2" >/dev/null
}
edge() { docker run --rm --network $NET -v "$DIR:/work:ro" $IMAGE bundle exec ruby /work/edge.rb "$@"; }

base=20
for mode in --forward-headers=false --forward-headers; do
  deploy $ECHO $mode
  edge echo $PROXY "$mode" $base
  deploy $APP $mode
  edge app $PROXY "$mode" $base
  echo "== $mode: Rails log for the last sign-in, then kamal-proxy's stored setting"
  docker logs $APP 2>&1 | grep 'Started POST "/session"' | tail -1
  docker exec $PROXY sh -c 'cat $HOME/.config/kamal-proxy/kamal-proxy.state' | tr ',' '\n' | grep forward_headers
  base=$((base + 20))
done
