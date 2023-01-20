#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export PROM_VERSION=...
export PVC_BACKUP_NAME=...
export PROM_VALUES=...

export PVC_ALERTMANAGER_BACKUP_NAME=...

export PROM_NAMESPACE=prometheus # or 'default'
export PROM_RELEASE_NAME=prometheus

#!!! Just ignore when loki doesnt need to run in dedicated Node, but fill the values if the pod need to run in dedicated node !!!
export DEDICATED_NODE=false # change to be "true" when loki need to run in dedicated node
export CURRENT_STORAGE_SIZE="" #Please check by helm get values <loki-release-name> -n <namespace> #the value is persistence.size
export effect=""
export key=""
export value=""
export operator=""
export label_node_key=""
export label_node_value=""

# -------------------------------------------------------------------------------------
# Delete stateful prometheus
export PROMETHEUS_STATEFULSET=$(kubectl get statefulset -n prometheus | awk '{print $1}' | grep prometheus-server)
kubectl delete statefulsets $PROMETHEUS_STATEFULSET
echo "-- Waiting for terminating pod --"
kubectl wait pods -l release=$RELEASE_NAME,component=server --for=delete --timeout=5m

# Uninstall Thanos
helm uninstall thanos

echo "-- Upgrade the helm: $PROM_VERSION"
helm repo add prometheus https://prometheus-community.github.io/helm-charts
helm repo update

if [[ $DEDICATED_NODE == false ]]
then
    helm upgrade --install --version $PROM_VERSION prometheus prometheus/prometheus --values $PROM_VALUES \
    --set alertmanager.persistentVolume.existingClaim=$PVC_ALERTMANAGER_BACKUP_NAME \
    --set server.persistentVolume.existingClaim=$PVC_BACKUP_NAME
else
    helm upgrade --install --version $PROM_VERSION prometheus prometheus/prometheus --values $PROM_VALUES \
    --set alertmanager.persistentVolume.existingClaim=$PVC_ALERTMANAGER_BACKUP_NAME \
    --set server.persistentVolume.existingClaim=$PVC_BACKUP_NAME \
    --set alertmanager.tolerations[0].operator=$operator,alertmanager.tolerations[0].effect=$effect,alertmanager.tolerations[0].key=$key,alertmanager.tolerations[0].value=$value \
    --set nodeExporter.tolerations[0].operator=$operator,nodeExporter.tolerations[0].effect=$effect,nodeExporter.tolerations[0].key=$key,nodeExporter.tolerations[0].value=$value \
    --set server.tolerations[0].operator=$operator,server.tolerations[0].effect=$effect,server.tolerations[0].key=$key,server.tolerations[0].value=$value \
    --set pushgateway.tolerations[0].operator=$operator,pushgateway.tolerations[0].effect=$effect,pushgateway.tolerations[0].key=$key,pushgateway.tolerations[0].value=$value \
    --set kube-state-metrics.tolerations[0].operator=$operator,kube-state-metrics.tolerations[0].effect=$effect,kube-state-metrics.tolerations[0].key=$key,kube-state-metrics.tolerations[0].value=$value \
    --set alertmanager.nodeSelector.$label_node_key=$label_node_value \
    --set server.nodeSelector.$label_node_key=$label_node_value \
    --set pushgateway.nodeSelector.$label_node_key=$label_node_value \
    --set kube-state-metrics.nodeSelector.$label_node_key=$label_node_value
fi
echo "-- Waiting to available..."
sleep 30s