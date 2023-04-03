#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export PROMTAIL_NAMESPACE=...

export PROMTAIL_RELEASE_NAME=...

export LOKI_NAMESPACE=...
#--------------------------------------------------------------------------------------
# Set to the specific version
export VERSION=2.1.0
export PROMTAIL_VALUES=promtail.values.yaml

# Set namespace
echo "-- Set the kubectl context to use the Promtail Namespace: $PROMTAIL_NAMESPACE"
kubectl config set-context --current --namespace=$PROMTAIL_NAMESPACE

helm get values promtail | tee $PROMTAIL_VALUES
cp $PROMTAIL_VALUES "$PROMTAIL_VALUES.bak"
cat << EOF > $PROMTAIL_VALUES
loki:
  serviceName: loki.$LOKI_NAMESPACE
config:
  client:
    # Maximum wait period before sending batch
    batchwait: 5s
    backoff_config:
      # Initial backoff time between retries
      min_period: 100ms
      # Maximum backoff time between retries
      max_period: 5m
      # Maximum number of retries when sending batches, 0 means infinite retries
      max_retries: 20
resources:
 limits:
   cpu: 0.2
   memory: 500Mi
EOF

echo "-- Upgrade the helm: $PROMTAIL_VERSION"
helm repo add promtail https://grafana.github.io/helm-charts
helm repo update
helm upgrade --version $VERSION promtail promtail/promtail --values $PROMTAIL_VALUES