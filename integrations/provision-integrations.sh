#!/bin/bash

###################################################################
# Script Name   : provision-integrations.sh
# Description   : Provision required integrations
# Author        : Kasun Talwatta
# Email         : kasun.talwatta@solo.io
# Version       : v0.1
###################################################################

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

error_exit() {
    echo "Error: $1"
    exit 1
}

error() {
    echo "Error: $1"
}

print_info() {
    echo ""
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo ""
}

validate_env_var() {
    [[ -z ${!1+set} ]] && error_exit "Error: Define ${1} environment variable"

    [[ -z ${!1} ]] && error_exit "${2}"
}

validate_var() {
    [[ -z $1 ]] && error_exit $2
}

has_array_value () {
    local -r item="{$1:?}"
    local -rn items="{$2:?}"

    echo $2

    for value in "${items[@]}"; do
        echo $value
        if [[ "$value" == "$item" ]]; then
            return 0
        fi
    done

    return 1
}

create_iam_oidc_identity_provider() {
    local cluster_name=$1
    local issuer_url=$2
    validate_env_var cluster_name "Cluster name is not set"
    validate_env_var issuer_url "Issuer URL is not set"

    # Ask OIDC Provider for JWKS host (remove schema and path with sed)
    local jwks_uri=$(curl -s ${issuer_url}/.well-known/openid-configuration | jq -r '.jwks_uri' | sed -e "s/^https:\/\///" | sed 's/\/.*//')

    # Extract all certificates in separate files
    temp=$DIR/../._output/eks-oidc
    mkdir -p $temp

    openssl s_client -servername $jwks_uri -showcerts -connect $jwks_uri:443 < /dev/null 2>/dev/null | \
        awk -v dir="$temp" '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/{ if(/BEGIN/){a++}; out=dir"/cert00"a".crt"; print >out }'

    # Assume last found certificate in chain is the root_ca
    local root_ca=$(ls -1 $temp/* | tail -1)

    # Extract fingerprint in desired format (no header, no colons)
    local thumbprint=$(openssl x509 -fingerprint -noout -in $root_ca | sed 's/^.*=//' | sed 's/://g')

    rm -rf $temp

    aws iam create-open-id-connect-provider \
        --url $issuer_url \
        --thumbprint-list $thumbprint \
        --client-id-list sts.amazonaws.com
}

create_aws_identity_provider_with_policy_and_service_account() {
    local cluster_name=$1
    local cluster_region=$2
    local policy_name=$3
    local policy_file=$4
    local role_name=$5
    local sa_name=$6
    local sa_namespace=$7
    validate_env_var cluster_name "Cluster name is not set"
    validate_env_var cluster_region "Cluster region is not set"
    validate_env_var policy_name "Policy name is not set"
    validate_env_var role_name "Role name is not set"
    validate_env_var sa_name "Service account name is not set"
    validate_env_var sa_namespace "Namespace for service account is not set"

    local sanitized_policy_name=`echo "${CLUSTER_OWNER}-${policy_name}" | cut -c -63`
    local sanitized_role_name=`echo "${cluster_name}-${role_name}" | cut -c -63`

    local issuer_url=$(aws eks describe-cluster \
                    --name $cluster_name \
                    --region $cluster_region \
                    --query cluster.identity.oidc.issuer \
                    --output text)
    [[ -z $issuer_url ]] && error_exit "OIDC provider url not found, unable to proceed with the identity creation"

    create_iam_oidc_identity_provider $cluster_name $issuer_url

    aws iam create-policy \
        --policy-name "${sanitized_policy_name}" \
        --policy-document file://$DIR/$policy_file

    local issuer_hostpath=$(echo $issuer_url | cut -f 3- -d'/')
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local provider_arn="arn:aws:iam::${account_id}:oidc-provider/${issuer_hostpath}"
    cat > $DIR/../._output/irp-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${provider_arn}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${issuer_hostpath}:sub": "system:serviceaccount:${sa_namespace}:${sa_name}"
        }
      }
    }
  ]
}
EOF

    aws iam create-role \
        --role-name "${sanitized_role_name}" \
        --assume-role-policy-document file://$DIR/../._output/irp-trust-policy.json
    aws iam update-assume-role-policy \
        --role-name "${sanitized_role_name}" \
        --policy-document file://$DIR/../._output/irp-trust-policy.json
    aws iam attach-role-policy \
        --role-name "${sanitized_role_name}" \
        --policy-arn $(aws iam list-policies --output json | jq --arg pn "${sanitized_policy_name}" -r '.Policies[] | select(.PolicyName == $pn)'.Arn)
    local role_arn=$(aws iam get-role \
        --role-name "${sanitized_role_name}" \
        --query Role.Arn --output text)

    [[ -z $role_arn ]] && error_exit "Role arn is not computed, unable to proceed with the identity creation"

    kubectl create ns $sa_namespace
    kubectl create sa $sa_name -n $sa_namespace
    kubectl annotate sa $sa_name -n $sa_namespace "eks.amazonaws.com/role-arn=${role_arn}"
}

install_alb_controller() {
    local cluster_name=$1
    local cluster_region=$2
    local cluster_provider=$3
    local sa_namespace="kube-system"

    print_info "Installing ALB Controller"

    validate_env_var cluster_name "Cluster name not set"
    validate_env_var cluster_region "Cluster region not set"
    validate_env_var cluster_provider "Cluster provider not set"

    if [[ "$cluster_provider" == "eks" ]]; then
        # Create an IAM OIDC identity provider and policy
        create_aws_identity_provider_with_policy_and_service_account $context \
            $cluster_name \
            $cluster_region \
            "AWSLoadBalancerControllerIAMPolicy" \
            "alb-controller/iam-policy.json" \
            "aws-load-balancer-controller-role" \
            "alb-ingress-controller" \
            $sa_namespace

        # Get the VPC ID
        export VPC_ID=$(aws ec2 describe-vpcs --region $cluster_region \
            --filters Name=tag:Name,Values=eksctl-${cluster_name}-cluster/VPC | jq -r '.Vpcs[]|.VpcId')
    elif [[ "$cluster_provider" == "eks-ipv6" ]]; then
        export ALB_ARN=$(aws iam get-role --role-name "$cluster_name-alb" --query 'Role.[Arn]' --output text)
        export VPC_ID=$(aws ec2 describe-vpcs --region $cluster_region \
            --filters Name=tag:Name,Values=${cluster_name} | jq -r '.Vpcs[]|.VpcId')
        envsubst < <(cat $DIR/alb-controller/cluster-role-binding.yaml) | kubectl --context $context apply -n $sa_namespace -f -
    else
        error_exit "$cluster_provider not supported"
    fi

    # Install ALB controller
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update eks --fail-on-repo-update-fail

    export CLUSTER_NAME=$cluster_name
    envsubst < <(cat $DIR/alb-controller/helm-values.yaml) | helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n ${sa_namespace} -f -

    kubectl \
        -n kube-system wait deploy/aws-load-balancer-controller --for condition=Available=True --timeout=90s
}

install_alb_controller "$CLUSTER_OWNER-$CLUSTER_NAME" "$CLUSTER_REGION" "eks"