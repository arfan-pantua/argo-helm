#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export NAMESPACE=... # or 'default'
export RELEASE_NAME=...
export ROOT_DOMAIN=...
export CSRF_TRUSTED_ORIGINS=...
#!!! Just ignore when grafana doesnt need to run in dedicated Node, but fill the values if the pod need to run in dedicated node !!!
export DEDICATED_NODE=false
export effect=.""
export key=""
export value=""
export operator=""
export label_node_key=""
export label_node_value=""

# Set to the specific version
export VERSION=6.30.3
export APP_VERSION=8.5.15
#--------------------------------------------------------------------------------------

# Env Definition
export GRAFANA_VALUES=grafana.values.yaml

# Set namespace
echo "-- Set the kubectl context to use the NAMESPACE: $NAMESPACE"
kubectl config set-context --current --namespace=$NAMESPACE

# Prepare the new values
helm get values grafana | tee $GRAFANA_VALUES
cp $GRAFANA_VALUES "$GRAFANA_VALUES.bak"
cat << EOF >> $GRAFANA_VALUES

grafana.ini:
  server:
    root_url: https://$ROOT_DOMAIN
  security:
    csrf_trusted_origins: $CSRF_TRUSTED_ORIGINS
  # force_migration: true #for degrade version we need to activate this script
EOF

# scaling pod to zero
kubectl scale deployment/grafana --replicas=0
echo "-- Waiting for terminating pod --"
kubectl wait pods -l app.kubernetes.io/instance=$RELEASE_NAME --for=delete --timeout=10m

echo "-- Upgrade the helm value to migrate pod to dedicated node"
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
if [[ $DEDICATED_NODE = true ]]
then
    helm upgrade --version $VERSION grafana grafana/grafana --values $GRAFANA_VALUES --set replicas=3 \
    --set tolerations[0].operator=$operator,tolerations[0].effect=$effect,tolerations[0].key=$key,tolerations[0].value=$value \
    --set nodeSelector.$label_node_key=$label_node_value \
    --set image.repository=grafana/grafana --set image.tag=$APP_VERSION
else
    helm upgrade --version $VERSION grafana grafana/grafana --values $GRAFANA_VALUES --set replicas=3 \
    --set image.repository=grafana/grafana --set image.tag=$APP_VERSION
fi