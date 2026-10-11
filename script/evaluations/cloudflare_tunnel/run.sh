#!/usr/bin/env bash
# Evaluation: does the client address survive the deployed edge?
#   [Cloudflare edge + cloudflared stand-in] -> kamal-proxy :80 (no host
#   ports) -> Thruster -> Puma -> Rails, on a private Docker network with its
#   own throwaway PostgreSQL. kamal-proxy runs the image and the deploy
#   command Kamal renders from config/deploy.yml (kamal_proxy.rb). It runs once
#   as committed, where every visitor must keep their own address and sign-in
#   budget whatever headers they send, and once with forwarding turned off,
#   where every visitor must share the stand-in's budget (a control that proves
#   the checks can fail). See production-deploy.md step 11.
# Exits nonzero, after printing the observations, if any expectation fails or
# a container does not become ready within READY_TIMEOUT seconds (default 120).
# Nothing here touches the development database, .env, Cloudflare or any
# external service. Everything is removed on exit.
#
# Usage, with an image built from this checkout:
#   IMAGE=three-heavens:local script/evaluations/cloudflare_tunnel/run.sh
set -euo pipefail
IMAGE=${IMAGE:?}
READY_TIMEOUT=${READY_TIMEOUT:-120}
DIR=$(cd "$(dirname "$0")" && pwd)
RUN=th-tunnel-$$
NET=$RUN PG=$RUN-pg APP=$RUN-app ECHO=$RUN-echo PROXY=$RUN-proxy
PASS=$(openssl rand -hex 16)

render() { (cd "$DIR/../../.." && bundle exec ruby "$DIR/kamal_proxy.rb" "$@"); }
PROXY_IMAGE=$(render image)
fail() { echo "FAIL: $*" >&2; exit 1; }

# Runs the probe until it succeeds; fails with the container's state and last
# log lines once the container stops or READY_TIMEOUT passes.
wait_ready() { # container, description, probe command...
  local container=$1 what=$2 started=$SECONDS state
  shift 2
  until "$@" >/dev/null 2>&1; do
    state=$(docker inspect -f '{{.State.Status}} (exit code {{.State.ExitCode}})' "$container" 2>&1 || true)
    if [[ $state != running* ]] || ((SECONDS - started >= READY_TIMEOUT)); then
      echo "FAIL: $what not ready after $((SECONDS - started))s (limit ${READY_TIMEOUT}s); container $container: $state. Last log lines:" >&2
      docker logs --tail 40 "$container" >&2 2>&1 || true
      exit 1
    fi
    sleep 0.5
  done
}

cleanup() { docker rm -fv $PG $APP $ECHO $PROXY >/dev/null 2>&1 || true; docker network rm $NET >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker network create $NET >/dev/null
docker run -d --name $PG --network $NET -e POSTGRES_PASSWORD=$PASS postgres:17 >/dev/null
wait_ready $PG PostgreSQL docker exec -e PGCONNECT_TIMEOUT=5 $PG psql -U postgres -h 127.0.0.1 -c 'select 1'

url() { echo "postgres://postgres:$PASS@$PG:5432/three_heavens_tunnel_$1"; }
docker run -d --name $APP --network $NET \
  -e DATABASE_URL=$(url primary) -e CACHE_DATABASE_URL=$(url cache) -e QUEUE_DATABASE_URL=$(url queue) -e CABLE_DATABASE_URL=$(url cable) \
  -e APP_HOST=threeheavens.test -e SECRET_KEY_BASE=$(openssl rand -hex 64) -e MAIL_FROM=tunnel@example.invalid \
  -e SMTP_HOST=smtp.example.invalid -e SMTP_USERNAME=unused -e SMTP_PASSWORD=unused -e GOOGLE_CLIENT_ID=unused.apps.googleusercontent.com \
  -e SOLID_QUEUE_IN_PUMA=true -e RAILS_LOG_LEVEL=info $IMAGE >/dev/null
docker run -d --name $ECHO --network $NET -v "$DIR:/work:ro" $IMAGE ./bin/thrust ruby /work/echo.rb >/dev/null
docker run -d --name $PROXY --network $NET $PROXY_IMAGE >/dev/null
wait_ready $APP "the application" docker exec $APP curl -fsS --max-time 5 http://127.0.0.1:80/up
echo "application image $IMAGE ($(docker image inspect -f '{{.Id}}' $IMAGE))" >&2
echo "kamal-proxy $PROXY_IMAGE at $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $PROXY)" >&2

deploy() { # target, extra kamal-proxy flags
  docker exec $PROXY sh -c "$(render deploy "$1") $2" >/dev/null
}
edge() { docker run --rm --network $NET -v "$DIR:/work:ro" $IMAGE bundle exec ruby /work/edge.rb "$@"; }

base=20
for expect in isolated shared; do
  [ $expect = shared ] && flags=--forward-headers=false || flags=
  echo "== $expect: kamal-proxy deploy as rendered from config/deploy.yml ${flags:+plus $flags}"
  deploy $ECHO "$flags"
  edge echo $PROXY $expect $base
  deploy $APP "$flags"
  edge app $PROXY $expect $base
  stored=$(docker exec $PROXY sh -c 'cat $HOME/.config/kamal-proxy/kamal-proxy.state' | tr ',' '\n' | grep -o '"forward_headers":[a-z]*' || true)
  last=$(docker logs $APP 2>&1 | grep 'Started POST "/session"' | tail -1 || true)
  echo "kamal-proxy state: $stored"
  echo "Rails log, last sign-in: $last"
  victim=198.51.100.$((base + 5))
  if [ $expect = isolated ]; then
    [ "$stored" = '"forward_headers":true' ] || fail "kamal-proxy is not forwarding headers as committed: ${stored:-no state}"
    [[ $last == *" for $victim at "* ]] || fail "Rails logged the last sign-in for another address than visitor $victim"
  else
    [ "$stored" = '"forward_headers":false' ] || fail "the control did not turn forwarding off: ${stored:-no state}"
    [[ $last != *" for 198.51.100."* ]] || fail "with forwarding off, Rails still logged a visitor address"
  fi
  base=$((base + 20))
done
echo "PASS: committed kamal-proxy settings keep each visitor's address and budget; the control shares them"
