#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export SERVICE_ACCOUNT_NAME=... #by default it was prometheus-server dont use this name
export BUCKET_NAME=...
export REGION_S3=...
export JOB_LATEST_MANUAL=...
export NEW_STORAGE_SIZE=...
export CLUSTER_NAME=...
export PROM_NAMESPACE=... # or 'default'
export PROM_RELEASE_NAME=...

#!!! Just ignore when loki doesnt need to run in dedicated Node, but fill the values if the pod need to run in dedicated node !!!
export DEDICATED_NODE=false # change to be "true" when loki need to run in dedicated node
export CURRENT_STORAGE_SIZE="" #Please check by helm get values <loki-release-name> -n <namespace> #the value is persistence.size
export effect=""
export key=""
export value=""
export operator=""
export label_node_key=""
export label_node_value=""

# Set to the specific version
export PROM_VERSION=15.0.4
export THANOS_VERSION=11.6.8

#--------------------------------------------------------------------------------------

# Env Definition
export BACKUP_PVC_ALERTMANAGER=pvc-prom-alert-backup
export PROM_VALUES=prometheus.values.yaml
export PROM_PVC_BACKUP_VALUE=backup-pvc.yaml
export PROM_PVC_BACKUP_ALERTMANAGER_VALUE=backup-pvc-alertmanager.yaml
export THANOS_CONF_FILE=thanos-storage-config.yaml
export THANOS_VALUES=thanos.values.yaml

## !!! Fill this !!!


# Set namespace
echo "-- Set the kubectl context to use the PROM_NAMESPACE: $PROM_NAMESPACE"
kubectl config set-context --current --namespace=$PROM_NAMESPACE

# Documentation for backup

## Take previous version
helm list | grep prometheus | awk '{print "PROM_CHART_VERSION="$9}' >> prometheus.version.bak
helm list | grep prometheus | awk '{print "PROM_APP_VERSION="$10}' >> prometheus.version.bak

## Take prometheus helm values
helm get values prometheus | tee $PROM_VALUES
cp $PROM_VALUES "$PROM_VALUES.bak"

## Create snapshot prometheus server and prometheus alert
# Get the prometheus PVC name
echo "-- Get the prometheus PVC name"
export PROM_PVC=$(kubectl get pvc -n $PROM_NAMESPACE | awk '{print $1}' | grep prometheus-server)
echo $PROM_PVC

# Get the prometheus PV name
echo "-- Get the prometheus PV name"
export PROM_PV=$(kubectl get pvc -n $PROM_NAMESPACE | grep prometheus-server | awk '{print $3}')
echo $PROM_PV

# Get and set volume id
export PROM_VOLUME_ID=$(kubectl get pv -n $PROM_NAMESPACE -o json | jq -j '.items[] | "\(.spec.awsElasticBlockStore.volumeID) \(.metadata.name)\n"' | grep $PROM_PV | awk -F/ '{print $4}' | awk '{print $1}')
export PROM_REGION_VOL_BACKUP=$(kubectl get pv -n $PROM_NAMESPACE -o json | jq -j '.items[] | "\(.spec.awsElasticBlockStore.volumeID) \(.metadata.name)\n"' | grep $PROM_PV | awk -F/ '{print $3}' | awk '{print $1}')
aws ec2 create-snapshot --volume-id $PROM_VOLUME_ID

# Get the prometheus alert PVC name
echo "-- Get the prometheus PVC name"
export PROM_ALERT_PVC=$(kubectl get pvc -n $PROM_NAMESPACE | awk '{print $1}' | grep prometheus-alertmanager)
echo $PROM_ALERT_PVC

# Get the prometheus alert PV name
echo "-- Get the prometheus alert PV name"
export PROM_ALERT_PV=$(kubectl get pvc -n $PROM_NAMESPACE | grep prometheus-alertmanager | awk '{print $3}')
echo $PROM_ALERT_PV

# Get and set volume id
export PROM_ALERT_VOLUME_ID=$(kubectl get pv -n $PROM_NAMESPACE -o json | jq -j '.items[] | "\(.spec.awsElasticBlockStore.volumeID) \(.metadata.name)\n"' | grep $PROM_ALERT_PV | awk -F/ '{print $4}' | awk '{print $1}')
export PROM_ALERT_REGION_VOL_BACKUP=$(kubectl get pv -n $PROM_NAMESPACE -o json | jq -j '.items[] | "\(.spec.awsElasticBlockStore.volumeID) \(.metadata.name)\n"' | grep $PROM_ALERT_PV | awk -F/ '{print $3}' | awk '{print $1}')
aws ec2 create-snapshot --volume-id $PROM_ALERT_VOLUME_ID

## Backup pvc

# cat << EOF > $PROM_PVC_BACKUP_VALUE
# ---
# apiVersion: v1
# kind: PersistentVolume
# metadata:
#   name: pv-prom-backup
# spec:
#   accessModes:
#   - ReadWriteOnce
#   awsElasticBlockStore:
#     fsType: ext4
#     volumeID: aws://$REGION_VOL_BACKUP/$VOL_BACKUP_ID
#   persistentVolumeReclaimPolicy: Retain
#   storageClassName: encrypted-gp2
#   volumeMode: Filesystem
# ---
# apiVersion: v1
# kind: PersistentVolumeClaim
# metadata:
#   name: pvc-prom-backup
# spec:
#   accessModes:
#   - ReadWriteOnce
#   storageClassName: encrypted-gp2
#   volumeMode: Filesystem
#   volumeName: pv-prom-backup
# EOF
# kubectl apply -f $PROM_PVC_BACKUP_VALUE
# cat << EOF > $PROM_PVC_BACKUP_ALERTMANAGER_VALUE
# ---
# apiVersion: v1
# kind: PersistentVolume
# metadata:
#   name: pv-prom-alert-backup
# spec:
#   accessModes:
#   - ReadWriteOnce
#   awsElasticBlockStore:
#     fsType: ext4
#     volumeID: aws://$REGION_VOL_BACKUP_ALERTMANAGER/$VOL_BACKUP_ID_ALERTMANAGER
#   persistentVolumeReclaimPolicy: Retain
#   storageClassName: encrypted-gp2
#   volumeMode: Filesystem
# ---
# apiVersion: v1
# kind: PersistentVolumeClaim
# metadata:
#   name: pvc-prom-alert-backup
# spec:
#   accessModes:
#   - ReadWriteOnce
#   storageClassName: encrypted-gp2
#   volumeMode: Filesystem
#   volumeName: pv-prom-alert-backup
# EOF
# kubectl apply -f $PROM_PVC_BACKUP_ALERTMANAGER_VALUE
# Scale the prometheus to 0
echo "-- Scale Prometheus's Deployment to 0"
kubectl scale deploy/prometheus-server --replicas=0
kubectl scale deploy/prometheus-alertmanager --replicas=0
echo "-- Waiting for terminating pod --"
kubectl wait pods -l release=$RELEASE_NAME,component=server --for=delete --timeout=5m
kubectl wait pods -l release=$RELEASE_NAME,component=alertmanager --for=delete --timeout=5m

# Prepare sidecar

cat << EOF >> $PROM_VALUES
  extraArgs:
    storage.tsdb.max-block-duration: 3m
    storage.tsdb.min-block-duration: 3m
EOF
kubectl delete deployment prometheus-kube-state-metrics
echo "-- Upgrade the helm: $PROM_VERSION"
helm repo add prometheus https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --version $PROM_VERSION prometheus prometheus/prometheus --values $PROM_VALUES --set alertmanager.replicaCount=1 --set server.replicaCount=1
kubectl wait pods -l release=$PROM_RELEASE_NAME,component=server --for condition=Ready --timeout=5m

echo "-- Please wait..."
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
    image: quay.io/thanos/thanos:v0.30.0
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
  endpoint: s3.$REGION_S3.amazonaws.com
EOF
echo "-- create secret thanos storage "
kubectl  create secret generic  thanos-storage-config --from-file=thanos-storage-config=$THANOS_CONF_FILE

echo "-- Upgrade the helm: $PROM_VERSION"
helm repo add prometheus https://prometheus-community.github.io/helm-charts
helm repo update
# kubectl delete deployments.apps -l release=$PROM_RELEASE_NAME,component=server
# kubectl wait pods -l release=$PROM_RELEASE_NAME,component=server --for=delete --timeout=300s

# scaling pod to zero
echo "-- Scale Prometheus's Statefull server to 0"
kubectl scale deployment/prometheus-server --replicas=0
echo "-- Scale Prometheus's deployment alertmanager server to 0"
kubectl scale deployment/prometheus-alertmanager --replicas=0
echo "-- Waiting for terminating pod --"
kubectl wait pods -l release=$RELEASE_NAME,component=server --for=delete --timeout=5m
kubectl wait pods -l release=$RELEASE_NAME,component=alertmanager --for=delete --timeout=5m

if [[ $DEDICATED_NODE == false ]]
then
    helm upgrade --install --version $PROM_VERSION prometheus prometheus/prometheus --values $PROM_VALUES
else
    helm upgrade --install --version $PROM_VERSION prometheus prometheus/prometheus --values $PROM_VALUES \
    --set alertmanager.tolerations[0].operator=$operator,alertmanager.tolerations[0].effect=$effect,alertmanager.tolerations[0].key=$key,alertmanager.tolerations[0].value=$value \
    --set nodeExporter.tolerations[0].operator=$operator,nodeExporter.tolerations[0].effect=$effect,nodeExporter.tolerations[0].key=$key,nodeExporter.tolerations[0].value=$value \
    --set server.tolerations[0].operator=$operator,server.tolerations[0].effect=$effect,server.tolerations[0].key=$key,server.tolerations[0].value=$value \
    --set pushgateway.tolerations[0].operator=$operator,pushgateway.tolerations[0].effect=$effect,pushgateway.tolerations[0].key=$key,pushgateway.tolerations[0].value=$value \
    --set kube-state-metrics.tolerations[0].operator=$operator,kube-state-metrics.tolerations[0].effect=$effect,kube-state-metrics.tolerations[0].key=$key,kube-state-metrics.tolerations[0].value=$value \
    --set alertmanager.nodeSelector.$label_node_key=$label_node_value \
    --set server.nodeSelector.$label_node_key=$label_node_value \
    --set pushgateway.nodeSelector.$label_node_key=$label_node_value \
    --set kube-state-metrics.nodeSelector.$label_node_key=$label_node_value
fi
echo "-- Waiting to available..."
sleep 30s
echo "-- Deploy Thanos --"

cat << EOF > $THANOS_VALUES
objstoreConfig: |-
  type: s3
  config:
    bucket: $BUCKET_NAME
    endpoint: s3.$REGION_S3.amazonaws.com
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
if [[ $DEDICATED_NODE == false ]]
then
    helm upgrade --install --version $THANOS_VERSION thanos thanos/thanos --values $THANOS_VALUES
else
    helm upgrade --install --version $THANOS_VERSION thanos thanos/thanos --values $THANOS_VALUES \
    --set compactor.tolerations[0].operator=$operator,compactor.tolerations[0].effect=$effect,compactor.tolerations[0].key=$key,compactor.tolerations[0].value=$value \
    --set query.tolerations[0].operator=$operator,query.tolerations[0].effect=$effect,query.tolerations[0].key=$key,query.tolerations[0].value=$value \
    --set queryFrontend.tolerations[0].operator=$operator,queryFrontend.tolerations[0].effect=$effect,queryFrontend.tolerations[0].key=$key,queryFrontend.tolerations[0].value=$value \
    --set storegateway.tolerations[0].operator=$operator,storegateway.tolerations[0].effect=$effect,storegateway.tolerations[0].key=$key,storegateway.tolerations[0].value=$value \
    --set compactor.nodeSelector.$label_node_key=$label_node_value \
    --set query.nodeSelector.$label_node_key=$label_node_value \
    --set queryFrontend.nodeSelector.$label_node_key=$label_node_value \
    --set storegateway.nodeSelector.$label_node_key=$label_node_value
fi


# Delete all jobs and cronjob
for j in $PROM_JOB_NAME
do
    kubectl delete jobs $j &
done
kubectl delete cronjob $PROM_CRON_JOB_NAME