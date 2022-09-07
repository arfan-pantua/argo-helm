#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export DB_HOST=...
export DB_PORT=...
export DB_USER=...
export DB_PASS=...
export DB_NAME=...

export GF_NAMESPACE=grafana # or 'default'
export GF_RELEASE_NAME=grafana

# Set to the specific version
export GF_VERSION=6.17.9
#--------------------------------------------------------------------------------------

# Env Definition
export GF_VALUES=grafana.values.yaml

# Set namespace
echo "-- Set the kubectl context to use the GF_NAMESPACE: $GF_NAMESPACE"
kubectl config set-context --current --namespace=$GF_NAMESPACE

# Prepare the new values
cat << EOF > $GF_VALUES
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - access: proxy
      isDefault: true
      name: Prometheus
      type: prometheus
      url: http://prometheus-server.prometheus.svc
    - access: proxy
      name: Loki
      type: loki
      url: http://loki.loki.svc:3100
    - access: proxy
      name: Jaeger
      type: jaeger
      url: http://jaeger-jaeger-operator-metrics.jaeger.svc:16686

persistence:
  enabled: false
replicas: 2
env:
  GF_DATABASE_TYPE: postgres
  GF_DATABASE_HOST: $DB_HOST
  GF_DATABASE_NAME: $DB_NAME
  GF_DATABASE_USER: $DB_USER

envFromSecret: gf-database-password

EOF

echo "-- create secret grafana database password"
kubectl  create secret generic gf-database-password --from-literal=GF_DATABASE_PASSWORD=$DB_PASS

echo "-- Upgrade the helm: $GF_VERSION to create schema"
#helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install --version $GF_VERSION grafana grafana/grafana --values $GF_VALUES

echo "-- Waiting to available..."
kubectl wait pods -l app.kubernetes.io/instance=$GF_RELEASE_NAME --for condition=Ready --timeout=90s
