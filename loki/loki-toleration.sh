#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export effect=...
export key=...
export value=...
export operator=...
export label_node_key=...
export label_node_value=...
export NAMESPACE=... # or 'default'
export RELEASE_NAME=...
export CURRENT_SIZE=...
export STORAGE_CLASS_NAME=...
# Set to the specific version
export VERSION=2.9.1
#--------------------------------------------------------------------------------------

# Env Definition
export LOKI_VALUES=loki.values.yaml

# Set namespace
echo "-- Set the kubectl context to use the NAMESPACE: $NAMESPACE"
kubectl config set-context --current --namespace=$NAMESPACE

# Prepare the new values
helm get values loki | tee $LOKI_VALUES
cp $LOKI_VALUES "$LOKI_VALUES.bak"

# scaling pod to zero
echo "-- Scale Loki's Statefull to 0"
kubectl scale statefulset/loki --replicas=0
echo "-- Waiting for terminating pod --"
kubectl wait pods -l release=$RELEASE_NAME --for=delete --timeout=10m

echo "-- Upgrade the helm value to migrate pod to dedicated node"
helm repo add loki https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install --version $VERSION loki loki/loki --values $LOKI_VALUES \
--set tolerations[0].operator=$operator,tolerations[0].effect=$effect,tolerations[0].key=$key,tolerations[0].value=$value \
--set nodeSelector.$label_node_key=$label_node_value \
--set persistence.enabled=true \
--set persistence.size=$CURRENT_SIZE \
--set persistence.storageClassName=$STORAGE_CLASS_NAME