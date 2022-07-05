#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!

export PROMTAIL_VERSION=...

export PROMTAIL_NAMESPACE=...

export PROMTAIL_RELEASE_NAME=...

export LOKI_NAMESPACE=...
#--------------------------------------------------------------------------------------

export PROMTAIL_VALUES=promtail.values.yaml

# Set namespace
echo "-- Set the kubectl context to use the Promtail Namespace: $PROMTAIL_NAMESPACE"
kubectl config set-context --current --namespace=$PROMTAIL_NAMESPACE

helm get values promtail | tee $PROMTAIL_VALUES
cp $PROMTAIL_VALUES "$PROMTAIL_VALUES.bak"
cat << EOF >> $PROMTAIL_VALUES
loki:
  serviceName: "loki.$LOKI_NAMESPACE"
config:
  client:
    # Maximum wait period before sending batch
    batchwait: 5s
EOF

echo "-- Upgrade the helm: $LOKI_VERSION"
kubectl label pods -l app=promtail,release=$PROMTAIL_RELEASE_NAME app.kubernetes.io/name=promtail app.kubernetes.io/instance=$PROMTAIL_RELEASE_NAME
kubectl delete daemonset -l app=promtail,release=$PROMTAIL_RELEASE_NAME --cascade=false
helm repo add promtail https://grafana.github.io/helm-charts
helm repo update
helm upgrade --version $PROMTAIL_VERSION promtail promtail/promtail --values $PROMTAIL_VALUES
