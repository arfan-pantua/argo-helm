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
export VERSION=15.0.4
export PROMETHEUS_VALUES=prom.values.yaml
#--------------------------------------------------------------------------------------

# Set namespace
echo "-- Set the kubectl context to use the NAMESPACE: $NAMESPACE"
kubectl config set-context --current --namespace=$NAMESPACE

# Prepare the values
helm get values prometheus | tee $PROMETHEUS_VALUES
cp $PROMETHEUS_VALUES "$PROMETHEUS_VALUES.bak"

# scaling pod to zero
echo "-- Scale Prometheus's Statefull server to 0"
kubectl scale statefulset/prometheus-server --replicas=0
echo "-- Scale Prometheus's deployment alertmanager server to 0"
kubectl scale deployment/prometheus-alertmanager --replicas=0
echo "-- Waiting for terminating pod --"
kubectl wait pods -l release=$RELEASE_NAME,component=server --for=delete --timeout=5m
kubectl wait pods -l release=$RELEASE_NAME,component=alertmanager --for=delete --timeout=5m


echo "-- Upgrade the helm value to migrate pod to dedicated node --"
helm repo add prometheus https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --version $VERSION prometheus prometheus/prometheus --values $PROMETHEUS_VALUES \
--set alertmanager.tolerations[0].operator=$operator,alertmanager.tolerations[0].effect=$effect,alertmanager.tolerations[0].key=$key,alertmanager.tolerations[0].value=$value \
--set nodeExporter.tolerations[0].operator=$operator,nodeExporter.tolerations[0].effect=$effect,nodeExporter.tolerations[0].key=$key,nodeExporter.tolerations[0].value=$value \
--set server.tolerations[0].operator=$operator,server.tolerations[0].effect=$effect,server.tolerations[0].key=$key,server.tolerations[0].value=$value \
--set pushgateway.tolerations[0].operator=$operator,pushgateway.tolerations[0].effect=$effect,pushgateway.tolerations[0].key=$key,pushgateway.tolerations[0].value=$value \
--set kube-state-metrics.tolerations[0].operator=$operator,kube-state-metrics.tolerations[0].effect=$effect,kube-state-metrics.tolerations[0].key=$key,kube-state-metrics.tolerations[0].value=$value \
--set alertmanager.nodeSelector.$label_node_key=$label_node_value \
--set server.nodeSelector.$label_node_key=$label_node_value \
--set pushgateway.nodeSelector.$label_node_key=$label_node_value \
--set kube-state-metrics.nodeSelector.$label_node_key=$label_node_value