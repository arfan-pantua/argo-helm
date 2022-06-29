#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!

export LOKI_NAMESPACE=loki # or 'default'
export LOKI_RELEASE_NAME=loki
export STORAGE_CLASS_NAME=...

# Set to the specific version
export LOKI_VERSION=2.11.1
export CLUSTER_NAME=DEV
#--------------------------------------------------------------------------------------

# Env Definition
export LOKI_VALUES=loki.after.batch.values.yaml
export LOKI_CONTAINER_HELPER=loki-0

export PYTHON_SCRIPT="script-upgrade.py"
export POD_CMD="container-helper.upgrade.sh"

# Set namespace
echo "-- Set the kubectl context to use the LOKI_NAMESPACE: $LOKI_NAMESPACE"
kubectl config set-context --current --namespace=$LOKI_NAMESPACE


# Prepare the initial commands
cat << EOF > $POD_CMD
#!/bin/bash

cd /tmp/data/loki

aws s3 cp chunks/index s3://$BUCKET_NAME/index --recursive

chmod +x /tmp/data/$PYTHON_SCRIPT

python /tmp/data/$PYTHON_SCRIPT


EOF

echo "-- Transfer processing ... --"
kubectl cp $POD_CMD $LOKI_CONTAINER_HELPER:/tmp/data/ -c helper
kubectl exec po/$LOKI_CONTAINER_HELPER -c helper -- /bin/bash -c "chmod +x /tmp/data/$POD_CMD"
kubectl exec po/$LOKI_CONTAINER_HELPER -c helper -- /bin/bash -c "bash /tmp/data/$POD_CMD"
echo "-- Latest data is copied to S3!"


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
  storageClassName: $STORAGE_CLASS_NAME
  size: 300Gi
replicas: 1
serviceAccount:
  create: false
  name: $SERVICE_ACCOUNT_NAME
  annotations: {}
EOF


# Scale the loki to 0
echo "-- Scale Loki's Deployment to 0"
kubectl scale statefulset/loki --replicas=0

# Delete container helper
kubectl delete po loki-0 --force
sleep 10s



echo "-- Upgrade the helm: $LOKI_VERSION"
helm repo add loki https://grafana.github.io/helm-charts
helm repo update
helm upgrade --version $LOKI_VERSION loki loki/loki --values $LOKI_VALUES