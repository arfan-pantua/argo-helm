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

# Set to the specific version
export VERSION=10.4.2
export THANOS_VALUES=thanos.values.yaml
#--------------------------------------------------------------------------------------

# Set namespace
echo "-- Set the kubectl context to use the NAMESPACE: $NAMESPACE"
kubectl config set-context --current --namespace=$NAMESPACE

# Prepare the values
helm get values thanos | tee $THANOS_VALUES
cp $THANOS_VALUES "$THANOS_VALUES.bak"

# scaling pod to zero
echo "-- Scale Thanos's to 0"
kubectl scale statefulset/thanos-storegateway --replicas=0
kubectl scale deployment/thanos-compactor --replicas=0
echo "-- Waiting for terminating pod --"
kubectl wait pods -l app.kubernetes.io/name=$RELEASE_NAME,app.kubernetes.io/component=storegateway --for=delete --timeout=5m
kubectl wait pods -l app.kubernetes.io/name=$RELEASE_NAME,app.kubernetes.io/component=compactor --for=delete --timeout=5m

echo "-- Upgrade the helm value to migrate pod to dedicated node --"
helm repo add thanos https://charts.bitnami.com/bitnami
helm repo update
helm upgrade --version $VERSION thanos thanos/thanos --values $THANOS_VALUES \
--set compactor.tolerations[0].operator=$operator,compactor.tolerations[0].effect=$effect,compactor.tolerations[0].key=$key,compactor.tolerations[0].value=$value \
--set query.tolerations[0].operator=$operator,query.tolerations[0].effect=$effect,query.tolerations[0].key=$key,query.tolerations[0].value=$value \
--set queryFrontend.tolerations[0].operator=$operator,queryFrontend.tolerations[0].effect=$effect,queryFrontend.tolerations[0].key=$key,queryFrontend.tolerations[0].value=$value \
--set storegateway.tolerations[0].operator=$operator,storegateway.tolerations[0].effect=$effect,storegateway.tolerations[0].key=$key,storegateway.tolerations[0].value=$value \
--set compactor.nodeSelector.$label_node_key=$label_node_value \
--set query.nodeSelector.$label_node_key=$label_node_value \
--set queryFrontend.nodeSelector.$label_node_key=$label_node_value \
--set storegateway.nodeSelector.$label_node_key=$label_node_value