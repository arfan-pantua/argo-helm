#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!

export LOKI_NAMESPACE=loki # or 'default'
export STORAGE_CLASS_NAME=...
export SERVICE_ACCOUNT_NAME=...
export NEW_PVC=...
export NEW_STORAGE_SIZE=... # by default 10Gi
export BUCKET_NAME=...
export JOB_LATEST_MANUAL=...

# Set to the specific version
export LOKI_VERSION=2.9.1
export CLUSTER_NAME=...
#--------------------------------------------------------------------------------------

# Env Definition
export LOKI_VALUES=loki.values.yaml
export LOKI_VALUES_PVC=loki.pvc.yaml

# Set namespace
echo "-- Set the kubectl context to use the LOKI_NAMESPACE: $LOKI_NAMESPACE"
kubectl config set-context --current --namespace=$LOKI_NAMESPACE

# Get the loki cron job name
echo "-- Get the loki Cron Job name"
export LOKI_CRON_JOB_NAME=$(kubectl get cronjob -o custom-columns=:.metadata.name -n $LOKI_NAMESPACE)
echo $LOKI_CRON_JOB_NAME

# Get the loki job name
echo "-- Get the loki Cron Job name"
export LOKI_JOB_NAME=$(kubectl get jobs -o custom-columns=:.metadata.name -n $LOKI_NAMESPACE)
echo $LOKI_JOB_NAME

# Running latest job before upgrade
kubectl create job --from=cronjob/$(echo $LOKI_CRON_JOB_NAME) $JOB_LATEST_MANUAL
# Waiting for complete
kubectl wait --for=condition=complete --timeout=100s job/$JOB_LATEST_MANUAL
sleep 5s
echo "-- Latest data is copied to S3!"

echo "-- Create new PVC ... --"
cat << EOF > $LOKI_VALUES_PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $NEW_PVC
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  resources:
    requests:
      storage: $NEW_STORAGE_SIZE
  storageClassName: $STORAGE_CLASS_NAME
EOF
kubectl apply -f $LOKI_VALUES_PVC
sleep 10s

# Prepare the new values
helm get values loki | tee $LOKI_VALUES
cp $LOKI_VALUES "$LOKI_VALUES.bak"
cat << EOF > $LOKI_VALUES
config:
  auth_enabled: false
  schema_config:
    configs:
    - from: 2020-07-01
      store: boltdb-shipper
      object_store: aws
      schema: v11
      index:
        prefix: index_
        period: 24h
  storage_config:
    aws:
      s3: s3://ap-southeast-1/$BUCKET_NAME
    boltdb_shipper:
      active_index_directory: /data/loki/boltdb-shipper-active
      cache_location: /data/loki/boltdb-shipper-cache
      cache_ttl: 24h         # Can be increased for faster performance over longer query periods, uses more disk space
      shared_store: aws
  compactor:
    working_directory: /data/compactor
    shared_store: aws
    compaction_interval: 5m
persistence:
  enabled: true
  existingClaim: $NEW_PVC
replicas: 1
serviceAccount:
  create: false
  name: $SERVICE_ACCOUNT_NAME
  annotations: {}
EOF

# Delete container and uninstall loki helper
helm uninstall loki
# Delete all jobs and cronjob
kubectl delete cronjob $LOKI_CRON_JOB_NAME
for j in $LOKI_JOB_NAME
do
    kubectl delete jobs $j &
done
kubectl wait pods --for=delete loki-0 --timeout=80s

echo "-- Upgrade the helm: $LOKI_VERSION"
helm repo add loki https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install --version $LOKI_VERSION loki loki/loki --values $LOKI_VALUES