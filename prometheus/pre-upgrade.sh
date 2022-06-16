#!/bin/bash

export PROM_VERSION=...
export PROM_NAMESPACE=...
export PROM_RELEASE_NAME=...
export PROM_VALUES=prometheus.values.yaml.bak

# Set namespace
echo "-- Set the kubectl context to use the PROM_NAMESPACE: $PROM_NAMESPACE"
kubectl config set-context --current --namespace=$PROM_NAMESPACE
# Get current value
echo "-- Get values and save to local"
#helm get values $PROM_RELEASE_NAME  > $PROM_VALUES

# Prepare the new values
helm get values prometheus | tee $PROM_VALUES
cat << EOF >> $PROM_VALUES
  extraArgs:
    storage.tsdb.max-block-duration: 3m
    storage.tsdb.min-block-duration: 3m
EOF

# Scale the prometheus to 0
echo "-- Scale prometheus's Deployment and alertmanager to 0"
kubectl scale deploy/prometheus-server --replicas=0
kubectl scale deploy/prometheus-alertmanager --replicas=0
sleep 20s

echo "-- Upgrade the helm: $PROM_VERSION"
helm repo add prometheus https://prometheus-community.github.io/helm-charts
helm repo update
kubectl delete deployments.apps -l app.kubernetes.io/instance=prometheus,app.kubernetes.io/name=kube-state-metrics --cascade=orphan
helm upgrade --version $PROM_VERSION prometheus prometheus/prometheus --values $PROM_VALUES 
