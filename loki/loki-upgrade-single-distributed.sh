#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!

export LOKI_NAMESPACE=... # or 'default'
export SERVICE_ACCOUNT_NAME=...
export BUCKET_NAME=...
export CLUSTER_NAME=...
#!!! Just ignore when loki doesnt need to run in dedicated Node, but fill the values if the pod need to run in dedicated node !!!
export DEDICATED_NODE=false # change to be "true" when loki need to run in dedicated node
export effect=...
export key=...
export value=...
export operator=...
export label_node_key=...
export label_node_value=...
export ingester_replicas=...
export distributor_replicas=...
export querier_replicas=...
export queryFrontend_replicas=...

export ingester_memory_limit=... #Mi or Gi
export ingester_cpu_limit=...
export distributor_memory_limit=...
export distributor_cpu_limit=...
export querier_memory_limit=...
export querier_cpu_limit=...
export queryFrontend_memory_limit=...
export queryFrontend_cpu_limit=...

# Set to the specific version
export LOKI_VERSION=0.67.2
#--------------------------------------------------------------------------------------

# Env Definition
export LOKI_VALUES=loki.values.yaml

# Set namespace
echo "-- Set the kubectl context to use the LOKI_NAMESPACE: $LOKI_NAMESPACE"
kubectl config set-context --current --namespace=$LOKI_NAMESPACE


# Prepare the new values
helm get values loki | tee $LOKI_VALUES
cp $LOKI_VALUES "$LOKI_VALUES.bak"
cat << EOF > $LOKI_VALUES
loki:
  schemaConfig:
    configs:
    - from: 2020-07-01
      store: boltdb-shipper
      object_store: aws
      schema: v11
      index:
        prefix: index_
        period: 24h
    - from: 2022-12-03
      store: boltdb-shipper
      object_store: aws
      schema: v12
      index:
        prefix: loki_index_
        period: 24h
  storageConfig:
    aws:
      s3: s3://ap-southeast-1/$BUCKET_NAME
    boltdb_shipper:
      cache_ttl: 24h         # Can be increased for faster performance over longer query periods, uses more disk space
      shared_store: aws
  compactor:
    shared_store: aws
  frontend:
    max_outstanding_per_tenant: 2048 # default = 100
  limits_config:
    max_streams_per_user: 0 # Old Default: 10000
    max_query_length: 0h # Default: 721h
    max_query_series: 100000 #default 500

ingester:
  kind: StatefulSet
  # -- Number of replicas for the ingester
  replicas: $ingester_replicas
  autoscaling:
    # -- Enable autoscaling for the distributor
    enabled: false
    # -- Minimum autoscaling replicas for the distributor
    minReplicas: 1
    # -- Maximum autoscaling replicas for the distributor
    maxReplicas: 3
  persistence:
      # -- Enable creating PVCs which is required when using boltdb-shipper
    enabled: false
  maxUnavailable: 2
  affinity: |
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
            - key: app.kubernetes.io/component
              operator: In
              values:
              - ingester
          topologyKey: kubernetes.io/hostname
  resources:
    limits:
      cpu: $ingester_cpu_limit
      memory: $ingester_memory_limit
# Configuration for the querier
querier:
  replicas: $querier_replicas
  autoscaling:
    # -- Enable autoscaling for the distributor
    enabled: false
    # -- Minimum autoscaling replicas for the distributor
    minReplicas: 1
    # -- Maximum autoscaling replicas for the distributor
    maxReplicas: 3
  maxUnavailable: 2
  affinity: |
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
            - key: app.kubernetes.io/component
              operator: In
              values:
              - querier
          topologyKey: kubernetes.io/hostname
  resources:
    limits:
      cpu: $querier_cpu_limit
      memory: $querier_memory_limit
# Configuration for the querie front end
queryFrontend:
  replicas: $queryFrontend_replicas
  autoscaling:
    # -- Enable autoscaling for the distributor
    enabled: false
    # -- Minimum autoscaling replicas for the distributor
    minReplicas: 1
    # -- Maximum autoscaling replicas for the distributor
    maxReplicas: 3
  maxUnavailable: 2
  resources:
    limits:
      cpu: $queryFrontend_cpu_limit
      memory: $queryFrontend_memory_limit
distributor:
  replicas: $distributor_replicas
  maxUnavailable: 2
  affinity: |
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
            - key: app.kubernetes.io/component
              operator: In
              values:
              - distributor
          topologyKey: kubernetes.io/hostname
  resources:
    limits:
      cpu: $distributor_cpu_limit
      memory: $distributor_memory_limit
securityContext:
  runAsNonRoot: false
  runAsUser: 0
serviceAccount:
  create: false
  name: $SERVICE_ACCOUNT_NAME
EOF

# Delete container and uninstall loki
# helm uninstall loki
export LOKI_STATEFULSET=$(kubectl get statefulset -n loki | awk '{print $1}' | grep loki)
kubectl delete statefulsets $LOKI_STATEFULSET

kubectl wait pods --for=delete loki-0 --timeout=80s

echo "-- Upgrade the helm: $LOKI_VERSION"
helm repo add loki https://grafana.github.io/helm-charts
helm repo update

if [[ $DEDICATED_NODE == false ]]
then
    helm upgrade --install --version $LOKI_VERSION loki loki/loki-distributed --values $LOKI_VALUES 
else
    helm upgrade --install --version $LOKI_VERSION loki loki/loki-distributed --values $LOKI_VALUES \
    --set ingester.tolerations[0].operator=$operator,ingester.tolerations[0].effect=$effect,ingester.tolerations[0].key=$key,ingester.tolerations[0].value=$value \
    --set ingester.nodeSelector.$label_node_key=$label_node_value \
    --set querier.tolerations[0].operator=$operator,querier.tolerations[0].effect=$effect,querier.tolerations[0].key=$key,querier.tolerations[0].value=$value \
    --set querier.nodeSelector.$label_node_key=$label_node_value \
    --set queryFrontend.tolerations[0].operator=$operator,queryFrontend.tolerations[0].effect=$effect,queryFrontend.tolerations[0].key=$key,queryFrontend.tolerations[0].value=$value \
    --set queryFrontend.nodeSelector.$label_node_key=$label_node_value \
    --set distributor.tolerations[0].operator=$operator,distributor.tolerations[0].effect=$effect,distributor.tolerations[0].key=$key,distributor.tolerations[0].value=$value \
    --set distributor.nodeSelector.$label_node_key=$label_node_value \
    --set persistence.enabled=false --set replicas=1
fi