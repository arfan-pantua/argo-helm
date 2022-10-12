#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
export CURRENT_DATA_SOURCE=...#http://prometheus-server.prometheus.svc
export NEXT_DATA_SOURCE=...   #http://thanos-query.prometheus:9090

export GF_NAMESPACE=grafana # or 'default'
export GF_RELEASE_NAME=grafana

# Set to the specific version
export GF_VERSION=6.17.9

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
sed -i  "s|$CURRENT_DATA_SOURCE *|$NEXT_DATA_SOURCE|" $GF_VALUES

echo "-- Upgrade the helm: $GF_VERSION to create schema"
helm repo update
helm upgrade --version $GF_VERSION grafana grafana/grafana --values $GF_VALUES