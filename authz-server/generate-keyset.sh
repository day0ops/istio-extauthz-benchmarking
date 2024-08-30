#!/usr/bin/env bash

AUTHZ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

error_exit() { echo "$1"; exit 1; }

GEN_DIR="$AUTHZ_DIR/jwt-gen"

AUDIENCE="http://httpbin.apps.svc.cluster.local:8000"
ORG="solo.io"
ACCOUNT_EMAIL="testing@solo.io"

gen_jwks() {
    local key=$1;shift
    local jwks_path=$1;shift

    ! command -v python3 >/dev/null 2>&1 && echo Python 3 is not installed && exit 1
    ! command -v pip3 >/dev/null 2>&1 && echo Python 3 is not installed && exit 1

    if [[ ! -f $AUTHZ_DIR/._venv/bin/activate ]]; then
        python3 -m venv $AUTHZ_DIR/._venv
    fi
    if [[ -f $AUTHZ_DIR/._venv/bin/activate ]]; then
        source $AUTHZ_DIR/._venv/bin/activate
        pip3 install jwcrypto 1>&2 > /dev/null
    fi

    python3 $AUTHZ_DIR/jwks-gen.py $key -jwks $jwks_path
}

gen_keys() {
    local gen_dir=$1;shift
    local force_create_dir=${1:-true};shift
    local force_gen_key=${1:-true};shift

    if [[ "$force_create_dir" == true ]]; then
        rm -rf $gen_dir
    fi

    mkdir -p $gen_dir

    if [[ (! -f "$gen_dir/private.key") || ("$force_gen_key" == true) ]]; then
        openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
            -subj "/C=US/ST=MA/L=Boston/O=Solo.io/OU=DevOps/CN=localhost" \
            -keyout $gen_dir/private.key \
            -out $gen_dir/public_cert.pem 2>/dev/null
        openssl x509 -pubkey -noout -in $gen_dir/public_cert.pem > $gen_dir/public_key.pem 2>/dev/null
    fi 

    kid=$(gen_jwks "$gen_dir/private.key" "$gen_dir/jwks.json")
    echo $kid
}