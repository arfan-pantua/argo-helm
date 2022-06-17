#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export LOKI_NAMESPACE=loki # or 'default'
export LOKI_RELEASE_NAME=loki

# Set to the specific version
export LOKI_VERSION=2.6.0
#-------------------------------------------------------------------------------------
# Env Definition
export LOKI_VALUES=loki.values.yaml.bak

# Set namespace
echo "-- Set the kubectl context to use the LOKI_NAMESPACE: $LOKI_NAMESPACE"
kubectl config set-context --current --namespace=$LOKI_NAMESPACE

# Scale the loki to 0
echo "-- Scale Prometheus's Deployment to 0"
kubectl scale statefulset/loki --replicas=0
sleep 15s

echo "-- Upgrade the helm: $LOKI_VERSION"
helm repo add loki https://grafana.github.io/helm-charts
helm repo update
helm upgrade --version $LOKI_VERSION loki loki/loki --values $LOKI_VALUES
