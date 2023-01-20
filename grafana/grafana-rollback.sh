#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export NAMESPACE=... # or 'default'
export RELEASE_NAME=...
export GRAFANA_VERSION=...
export PVC_BACKUP_NAME=...
export GRAFANA_VALUES=... #File .yaml.bak
#!!! Just ignore when grafana doesnt need to run in dedicated Node, but fill the values if the pod need to run in dedicated node !!!
export DEDICATED_NODE=false
export effect=.""
export key=""
export value=""
export operator=""
export label_node_key=""
export label_node_value=""
#--------------------------------------------------------------------------------------


# Set namespace
echo "-- Set the kubectl context to use the NAMESPACE: $NAMESPACE"
kubectl config set-context --current --namespace=$NAMESPACE


# scaling pod to zero
kubectl scale deployment/grafana --replicas=0
echo "-- Waiting for terminating pod --"
kubectl wait pods -l app.kubernetes.io/instance=$RELEASE_NAME --for=delete --timeout=10m

echo "-- Upgrade the helm value to migrate pod to dedicated node"
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
if [[ $DEDICATED_NODE = true ]]
then
    helm upgrade --version $GRAFANA_VERSION grafana grafana/grafana --values $GRAFANA_VALUES --set replicas=3 \
    --set tolerations[0].operator=$operator,tolerations[0].effect=$effect,tolerations[0].key=$key,tolerations[0].value=$value \
    --set nodeSelector.$label_node_key=$label_node_value \
    --set persistence.existingClaim=$PVC_BACKUP_NAME
else
    helm upgrade --version $GRAFANA_VERSION grafana grafana/grafana --values $GRAFANA_VALUES  \
    --set persistence.existingClaim=$PVC_BACKUP_NAME
fi