#!/bin/bash

unregister(){
    gitlab-runner unregister --all-runners
}


# Ensure clean removal from gitlab in most cases
trap unregister SIGINT SIGTERM SIGHUP EXIT  # cannot be caught: SIGKILL SIGSTOP

# Ensure sudo rights
touch /etc/sudoers.d/gitlab-runner
echo '%gitlab-runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/gitlab-runner
chmod 0400 /etc/sudoers.d/gitlab-runner

# Ensure docker run permissions
groupadd -g `stat -c"%g" /var/run/docker.sock` docker || true
usermod -a -G docker gitlab-runner


CONFIG_DIR=/etc/gitlab-runner
STACK=$(docker inspect $HOSTNAME --format '{{index .Config.Labels "com.docker.stack.namespace"}}')
NODE_ID=$(docker inspect $HOSTNAME --format '{{index .Config.Labels "com.docker.swarm.node.id"}}')
NODE=$(docker node inspect $NODE_ID --format '{{.Description.Hostname}}')

# You could use this under stack files environment tag:
#  - STACK={{index .Service.Labels "com.docker.stack.namespace"}}  # - STACK={{printf "%#v" .}}
if [[ ! "${SERVICE:-}" ]]; then
    SERVICE=$(docker inspect $HOSTNAME --format '{{index .Config.Labels "com.docker.swarm.service.name"}}')
fi

: ${SERVICE:?SERVICE required}
: ${NODE:?NODE required}

# Baptize
DESCRIPTION=${SERVICE}_${HOSTNAME}@$NODE

# Ensure config/secret is bound to myself
MAINTAIN=$(docker config ls --format {{.Name}}|grep '^runner.maintain$') || true
dCONFIG=$(docker config ls --format {{.Name}}|grep '^runner.defaults$') || true
dSECRET=$(docker secret ls --format {{.Name}}|grep "^${STACK}$") || true


if [[ $MAINTAIN ]]; then
    echo docker config runner.maintain found
    echo Not auto adding runner.defaults, docker secret <stack_name>, nor mounting volumes
    echo Maintain those files and remove runner.maintain again.
    exit 1
fi


VOLUMES_OPTION=()
VOLUMES=${VOLUMES// /}
VOLUMES=(${VOLUMES//;/ })
if [[ "$VOLUMES" ]]; then
    for volume in ${VOLUMES[@]}; do
        VOLUMES_OPTION+=("--mount-add $volume")
    done
fi

# TODO
# to be able to update config files like runner.defaults
# we have to find a way. Otherwise auto adding will prevent us from doing this.
# E.g. wait some time, before self updating. Or totally rely on manually adding those configs/secrets

echo -n "update: "
set -x
docker service update $SERVICE -d ${VOLUMES_OPTION:+ ${VOLUMES_OPTION[@]}}${dCONFIG:+ --config-add $dCONFIG}${dSECRET:+ --secret-add $dSECRET} || true

# Source some variables
. /var/run/secrets/$STACK && echo /var/run/secrets/$STACK found || true
. /var/run/secrets/$SERVICE && echo /var/run/secrets/$SERVICE found || true
. /runner.defaults && echo /runner.defaults found || true
set +x

export CI_SERVER_URL=${URL:-${CI_SERVER_URL:?One of URL, CI_SERVER_URL required}}
export REGISTRATION_TOKEN=${TOKEN:-${REGISTRATION_TOKEN:-${CI_SERVER_TOKEN:?One of TOKEN, REGISTRATION_TOKEN, CI_SERVER_TOKEN required}}}
export RUNNER_EXECUTOR=${EXECUTOR:-${RUNNER_EXECUTOR:-shell}}

# Misc options
if [[ $RUNNER_EXECUTOR == 'docker' ]]; then
    OPTIONS+=" --docker-image docker:latest --docker-volumes /var/run/docker.sock:/var/run/docker.sock"
fi

if [[ $TAG_LIST ]]; then
    OPTIONS+=" --tag-list ${TAG_LIST// /,}"
fi


# Main
gitlab-runner register${OPTIONS:+ $OPTIONS} -n --description "$DESCRIPTION" --locked  # --executor ${EXECUTOR:-shell} -u ${URL:?URL required} -r ${TOKEN:?TOKEN required}

# Must not be exec'ed. Otherwise the trap won't unregister the runner
/entrypoint $@
