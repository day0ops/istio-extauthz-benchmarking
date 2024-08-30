#!/usr/bin/env bash

AUTHZ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source $AUTHZ_DIR/generate-keyset.sh

error_exit() { echo "$1"; exit 1; }
b64enc() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }
json() { jq -c . | LC_CTYPE=C tr -d '\n'; }
hs_sign() { openssl dgst -binary -sha"${1}" -hmac "${2}"; }
rs_sign() { openssl dgst -binary -sha"${1}" -sign <(printf '%s\n' "${2}"); }

gen_jwt_token() {
    echo "Generating a valid JWT token ...."

    local algo=$1
    local kid=$2
    local jwt_secret=$3
    local payload=$4
    local encode_secret=$5
    local expiration_in_sec=$6

    [ -n "$algo" ] || error_exit "Algorithm not specified, RS256 or HS256."
    [ -n "$kid" ] || error_exit "Kid not specified."
    [ -n "$jwt_secret" ] || error_exit "Secret not provided."

    algo=${algo^^}

    local default_payload='{
    }'

    # Number of seconds to expire token, default 1h
    local expire_seconds="${expiration_in_sec:-3600}"

    # Check if secret should be base64 encoded
    ${encode_secret:-false} && jwt_secret=$(printf %s "$jwt_secret" | base64 --decode)

    header_template='{
        "typ": "JWT"
    }'

    gen_header=$(jq -c \
        --arg alg "${algo}" \
        --arg kid "${kid}" \
        '
        .alg = $alg
        | .kid = $kid
        ' <<<"${header_template}" | tr -d '\n') || error_exit "Unable to generate JWT header"

    # Generate payload
    gen_payload=$(jq -c \
        --arg iat_str "$(date +%s)" \
        --arg alg "${algo}" \
        --arg expiry_str "${expire_seconds}" \
        '
        ($iat_str | tonumber) as $iat
        | ($expiry_str | tonumber) as $expiry
        | .alg = $alg
        | .iat = $iat
        | .exp = ($iat + $expiry)
        | .nbf = $iat
        ' <<<"${payload:-$default_payload}" | tr -d '\n') || error_exit "Unable to generate JWT payload"

    echo $gen_payload

    signed_content="$(json <<<"$gen_header" | b64enc).$(json <<<"$gen_payload" | b64enc)"

    # Based on algo sign the content
    case ${algo} in
        HS*) signature=$(printf %s "$signed_content" | hs_sign "${algo#HS}" "$jwt_secret" | b64enc) ;;
        RS*) signature=$(printf %s "$signed_content" | rs_sign "${algo#RS}" "$jwt_secret" | b64enc) ;;
        *) echo "Unknown algorithm" >&2; return 1 ;;
    esac

    echo "Successfully generated a JWT token. ** Expires in ${expire_seconds} seconds ** ====> ${signed_content}.${signature}"

    export AUTH_TOKEN="${signed_content}.${signature}"
    envsubst < <(cat $AUTHZ_DIR/../locust/load-test-cm.yaml.tmp) > $AUTHZ_DIR/../locust/._load-test-cm.yaml.yaml
}

generate() {
    payload=$(jq -c \
        --arg iss "${ACCOUNT_EMAIL}" \
        --arg org "${ORG}" \
        --arg aud "${AUDIENCE}" \
        '
        .iss = $iss
        | .org = $org
        | .aud = $aud
        ' <<<"{}" | tr -d '\n') || error_exit "Unable to generate the payload"

    kid=$(gen_keys "$GEN_DIR" false false)
    rsa_token=$(cat $GEN_DIR/private.key)

    gen_jwt_token rs256 "$kid" "$rsa_token" "$payload" false 864000
}

generate