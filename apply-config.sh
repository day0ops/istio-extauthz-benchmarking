#!/usr/bin/env bash

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source $DIR/authz-server/generate-keyset.sh

generate_templates() {
    export ORG=$ORG
    export AUDIENCE=$AUDIENCE
    export ACCOUNT_EMAIL=$ACCOUNT_EMAIL
    export AUTHZ_SIGNING_KEY=`base64 -w 0 $GEN_DIR/private.key && echo`
    export AUTHZ_VER_KEY=`base64 -w 0 $GEN_DIR/public_key.pem && echo`
    export KEY_ID=$(gen_keys "$GEN_DIR" false false)
    export JWKS_STRING=$(cat $DIR/authz-server/jwt-gen/jwks.json)

    envsubst < <(cat $DIR/authz-server/security-config.yaml) | kubectl apply -f -
    envsubst < <(cat $DIR/authz-server/config.yaml) | kubectl apply -f -
    envsubst < <(cat $DIR/authz-server/sidecar.yaml) | kubectl apply -f -

    envsubst < <(cat $DIR/configuration/auth-policy-config.yaml) | kubectl apply -f -
    envsubst < <(cat $DIR/configuration/gw.yaml) | kubectl apply -f -
    envsubst < <(cat $DIR/configuration/vs.yaml) | kubectl apply -f -
}

generate_templates