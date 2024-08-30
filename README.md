# Testing Ext Auth Scaling on Istio

Using Istio version 1.19.7.

## Prerequisites

1. Provision a new cluster.

    ```bash
    export CLUSTER_REGION="ap-southeast-1"
    export CLUSTER_OWNER="kasunt"
    export CLUSTER_NAME="istio-extauth-scale-testing"

    # 4 node pool m4.2xlarge
    ./cloud-provision/provision-eks-cluster.sh create -n $CLUSTER_NAME -o $CLUSTER_OWNER -a 4 -m m4.2xlarge -v 1.28 -r $CLUSTER_REGION

    export ISTIO_MINOR_VERSION="1.19"
    export ISTIO_VERSION="1.19.7"
    export ISTIO_HELM_VERSION="${ISTIO_VERSION}"
    export ISTIO_SOLO_VERSION="${ISTIO_VERSION}-solo"
    export ISTIO_SOLO_REPO="us-docker.pkg.dev/gloo-mesh/istio-bf39a24ed9df"
    export ISTIO_REVISION=1-19-7
    export ISTIO_HELM_VERSION=1.19.7
    ```

2. Integrations. Setting up NLB

    ```bash
    ./integrations/provision-integrations.sh
    ```

3. Set up Istio

    ```bash
    helm repo add istio https://istio-release.storage.googleapis.com/charts
    helm repo update istio --fail-on-repo-update-fail
    helm upgrade --install istio-base istio/base \
        --create-namespace \
        -n istio-system \
        --version $ISTIO_HELM_VERSION

    envsubst < <(cat istio/istiod-helm-values.yaml) | helm upgrade -i istiod istio/istiod \
        -n istio-system \
        --version $ISTIO_HELM_VERSION \
        --wait \
        --timeout 5m0s \
        -f -

    # Root namespace for Istio configuration
    kubectl create ns istio-config

    # Setting up ingress
    kubectl create ns istio-ingress
    kubectl label namespace istio-ingress istio.io/rev=$ISTIO_REVISION
    envsubst < <(cat istio/istio-ingress-helm-values.yaml) | helm upgrade -i istio-ingress istio/gateway \
        -n istio-ingress \
        --version $ISTIO_HELM_VERSION \
        --wait \
        --timeout 5m0s \
        -f -

    export PUBLIC_API_ENDPOINT=$(kubectl get svc/istio-ingressgateway-$ISTIO_REVISION -n istio-ingress -o jsonpath="{.status.loadBalancer.ingress[*].hostname}")
    echo $PUBLIC_API_ENDPOINT
    ```

4. Deploy sample application

    ```bash
    envsubst < <(cat apps/httpbin-deploy.yaml) | kubectl apply -f -
    ```

5. olly setup

    ```bash
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-$ISTIO_MINOR_VERSION/samples/addons/prometheus.yaml
    kubectl apply -f grafana/deploy.yaml
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-$ISTIO_MINOR_VERSION/samples/addons/kiali.yaml

    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm install kube-state-metrics prometheus-community/kube-state-metrics -n kube-system

    # add dashboards to grafana
    GRAFANA_HOST="http://localhost:3000"
    GRAFANA_CRED="USER:PASSWORD"
    GRAFANA_DATASOURCE="Prometheus"

    for f in integrations/grafana/dashboards/*.json; do
        echo "Importing $(cat $f | jq -r '.title')"
        curl -s -k -u "$GRAFANA_CRED" -XPOST \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "{\"dashboard\":$(cat $f),\"overwrite\":true, \
                \"inputs\":[{\"name\":\"DS_PROMETHEUS\",\"type\":\"datasource\", \
                \"pluginId\":\"prometheus\",\"value\":\"$GRAFANA_DATASOURCE\"}]}" \
            $GRAFANA_HOST/api/dashboards/import
        echo -e "\nDone\n"
    done
    ```

6. Setting up Locust.

    ```bash
    # 4 node pool m4.2xlarge
    ./cloud-provision/provision-eks-cluster.sh create -n locust -o $CLUSTER_OWNER -a 4 -m m4.2xlarge -v 1.28 -r $CLUSTER_REGION

    # generate a token
    ./authz-server/generate-jwt.sh
    envsubst < <(cat locust/._load-test-cm.yaml) | kubectl apply -n locust -f -
    envsubst < <(cat locust/master.yaml) | kubectl apply -n locust -f -
    envsubst < <(cat locust/worker.yaml) | kubectl apply -n locust -f -
    ```

## Ext Authz Configuration

1. Install Ext Authz server

    ```bash
    envsubst < <(cat authz-server/deploy.yaml) | kubectl apply -f -
    ```

2. Push all the configuration

    ```bash
    ./apply-config.sh
    ```