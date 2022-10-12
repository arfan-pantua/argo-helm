#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export SERVICE_ACCOUNT_NAME=... #by default it was prometheus-server dont use this name
export BUCKET_NAME=...
export EXISTING_PVC_ALERTMANAGER=...
export JOB_LATEST_MANUAL=...
export NEW_STORAGE_SIZE=...
export CLUSTER_NAME=...

# Set to the specific version
export PROM_VERSION=15.0.4
export THANOS_VERSION=10.4.2

#--------------------------------------------------------------------------------------

# Env Definition
export PROM_VALUES=prometheus.values.yaml
export PROM_NAMESPACE=prometheus # or 'default'
export PROM_RELEASE_NAME=prometheus
export THANOS_CONF_FILE=thanos-storage-config.yaml
export THANOS_VALUES=thanos.values.yaml
## !!! Fill this !!!


# Set namespace
echo "-- Set the kubectl context to use the PROM_NAMESPACE: $PROM_NAMESPACE"
kubectl config set-context --current --namespace=$PROM_NAMESPACE


# Scale the prometheus to 0
echo "-- Scale Prometheus's Deployment to 0"
kubectl scale deploy/prometheus-server --replicas=0
kubectl scale deploy/prometheus-alertmanager --replicas=0
sleep 10s

# Prepare sidecar
helm get values prometheus | tee $PROM_VALUES
cp $PROM_VALUES "$PROM_VALUES.bak"
cat << EOF >> $PROM_VALUES
  extraArgs:
    storage.tsdb.max-block-duration: 3m
    storage.tsdb.min-block-duration: 3m
EOF

echo "-- Upgrade the helm: $PROM_VERSION"
helm repo add prometheus https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --version $PROM_VERSION prometheus prometheus/prometheus --values $PROM_VALUES 
kubectl wait pods -l release=$PROM_RELEASE_NAME --for condition=Ready --timeout=3m
# waiting about 3 minutes
for j in {1..10}
do
    date +"%T"
    sleep 20s	
done

# Get the prometheus cron job name
echo "-- Get the prometheus Cron Job name"
export PROM_CRON_JOB_NAME=$(kubectl get cronjob -o custom-columns=:.metadata.name -n $PROM_NAMESPACE)
echo $PROM_CRON_JOB_NAME

# Get the prometheus job name
echo "-- Get the prometheus Cron Job name"
export PROM_JOB_NAME=$(kubectl get jobs -o custom-columns=:.metadata.name -n $PROM_NAMESPACE)
echo $PROM_JOB_NAME

# Running latest job before upgrade
kubectl create job --from=cronjob/$(echo $PROM_CRON_JOB_NAME) $JOB_LATEST_MANUAL
# Waiting for complete
sleep 50s
kubectl wait --for=condition=complete --timeout=10m job/$JOB_LATEST_MANUAL
sleep 5s
echo "-- Latest data is copied to S3!"

cat << EOF > $PROM_VALUES
# Disable the default reloader.
# Thanos sidecar will be doing this now
configmapReload:
  prometheus:
    enabled: false
serviceAccounts:
  server:
    create: false
    name: $SERVICE_ACCOUNT_NAME
  pushgateway:
    create: false
    name: $SERVICE_ACCOUNT_NAME
    annotations: {}
alertmanager:
  persistentVolume:
    enabled: true
server:
  replicaCount: 2
  # Keep the metrics for 3 months
  retention: 8h  # Can't use PVs with "Deployments" (1)
  persistentVolume:
    enabled: true
    size: $NEW_STORAGE_SIZE
  statefulSet:  # (3)
    enabled: true  # required by the Thanos sidecar
    headless:
      gRPC:
        enabled: true
  global:
    external_labels:
      cluster: $CLUSTER_NAME
  extraArgs:
    storage.tsdb.min-block-duration: 2h
    storage.tsdb.max-block-duration: 2h
  service:
    gRPC:
      enabled: true
  sidecarContainers:
  - name: thanos-sc
    image: quay.io/thanos/thanos:v0.26.0
    imagePullPolicy: IfNotPresent
    args:
    - sidecar
    - --prometheus.url=http://localhost:9090
    - --grpc-address=0.0.0.0:10901
    - --http-address=0.0.0.0:10902
    - --tsdb.path=/data/
    - --objstore.config=\$(OBJSTORE_CONFIG)
    - --reloader.config-file=/etc/config/prometheus.yml
    - --reloader.rule-dir=/etc/config
    env:
    - name: OBJSTORE_CONFIG
      valueFrom:
        secretKeyRef:
          name: thanos-storage-config
          key: thanos-storage-config
    volumeMounts:
    - mountPath: /data
      name: storage-volume  # Limit how many resources Prometheus can use
    - name: config-volume
      mountPath: /etc/config
      readOnly: true
EOF
cat << EOF > $THANOS_CONF_FILE
type: s3
config:
  bucket: $BUCKET_NAME
  endpoint: s3.ap-southeast-1.amazonaws.com
EOF
echo "-- create secret thanos storage "
kubectl  create secret generic  thanos-storage-config --from-file=thanos-storage-config=$THANOS_CONF_FILE

echo "-- Upgrade the helm: $PROM_VERSION"
helm repo add prometheus https://prometheus-community.github.io/helm-charts
helm repo update
kubectl delete deployments.apps -l release=$PROM_RELEASE_NAME,component=server
kubectl wait pods -l release=$PROM_RELEASE_NAME,component=server --for=delete --timeout=300s
helm upgrade --version $PROM_VERSION prometheus prometheus/prometheus --values $PROM_VALUES

echo "-- Waiting to available..."
sleep 30s


echo "-- Deploy Thanos --"

cat << EOF > $THANOS_VALUES
objstoreConfig: |-
  type: s3
  config:
    bucket: $BUCKET_NAME
    endpoint: s3.ap-southeast-1.amazonaws.com
query:
  enabled: true
  serviceAccount:
    existingServiceAccount: "$SERVICE_ACCOUNT_NAME"
  args:
  - query
  - --store=prometheus-server.$PROM_NAMESPACE.svc.cluster.local:10901
  - --store=dnssrv+_grpc._tcp.thanos-storegateway.$PROM_NAMESPACE.svc.cluster.local
  replicaCount: 2
queryFrontend:
  replicaCount: 2
  enabled: true
  serviceAccount:
    existingServiceAccount: "$SERVICE_ACCOUNT_NAME"
compactor:
  enabled: true
  serviceAccount:
    existingServiceAccount: "$SERVICE_ACCOUNT_NAME"
  args:
  - compact
  - --log.level=info
  - --log.format=logfmt
  - --http-address=0.0.0.0:10902
  - --data-dir=/data
  - --retention.resolution-raw=30d
  - --retention.resolution-5m=30d
  - --retention.resolution-1h=10y
  - --consistency-delay=30m
  - --objstore.config=\$(OBJSTORE_CONFIG)
  - --wait
  extraEnvVars:
  - name: OBJSTORE_CONFIG
    valueFrom:
      secretKeyRef:
        key: thanos-storage-config
        name: thanos-storage-config
storegateway:
  enabled: true
  replicaCount: 2
  serviceAccount:
    existingServiceAccount: "$SERVICE_ACCOUNT_NAME"
  args:
  - store
  - --objstore.config=\$(OBJSTORE_CONFIG)
  extraEnvVars:
  - name: OBJSTORE_CONFIG
    valueFrom:
      secretKeyRef:
        key: thanos-storage-config
        name: thanos-storage-config
EOF

helm repo add thanos https://charts.bitnami.com/bitnami
helm repo update
helm upgrade --install --version $THANOS_VERSION thanos thanos/thanos --values $THANOS_VALUES

# Delete all jobs and cronjob
for j in $PROM_JOB_NAME
do
    kubectl delete jobs $j &
done
kubectl delete cronjob $PROM_CRON_JOB_NAME