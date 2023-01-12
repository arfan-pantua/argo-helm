#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
export CURRENT_DATA_SOURCE=...#http://prometheus-server.prometheus.svc
export NEXT_DATA_SOURCE=...   #http://thanos-query.prometheus:9090

export GF_NAMESPACE=grafana # or 'default'
export GF_RELEASE_NAME=grafana

# Set to the specific version
export VERSION=6.30.3
export APP_VERSION=8.5.15

#--------------------------------------------------------------------------------------

# Env Definition
export GF_VALUES=grafana.values.yaml

# Set namespace
echo "-- Set the kubectl context to use: $GF_NAMESPACE"
kubectl config set-context --current --namespace=$GF_NAMESPACE


# Scale the grafana to 0
echo "-- Scale Grafana's Deployment to 0"
kubectl scale deploy/grafana --replicas=0
sleep 10s

# Prepare the new values
helm get values grafana | tee $GF_VALUES
cp $GF_VALUES "$GF_VALUES.bak"
sed -i  "s|$CURRENT_DATA_SOURCE *|$NEXT_DATA_SOURCE |" $GF_VALUES

echo "-- Upgrade the helm: $GF_VERSION to create schema"
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --version $VERSION grafana grafana/grafana --values $GF_VALUES --set replicas=3 \
    --set image.repository=grafana/grafana --set image.tag=$APP_VERSION