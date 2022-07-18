#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export SERVICE_ACCOUNT_NAME=... #by default it was prometheus-server dont use this name
export BUCKET_NAME=...
export EXISTING_PVC_ALERTMANAGER=...

export PROM_NAMESPACE=prometheus # or 'default'
export PROM_RELEASE_NAME=prometheus
export THANOS_CONF_FILE="thanos-storage-config.yaml"
export THANOS_VALUES="thanos.values.yaml"

# Set to the specific version
export PROM_VERSION=15.0.4
export THANOS_VERSION=10.4.2
export CLUSTER_NAME=...
#--------------------------------------------------------------------------------------

# Env Definition
export PROM_VALUES=prometheus.after.batch.values.yaml
export CONTAINER_CMD="pod-helper.install.sh"

## !!! Fill this !!!


# Set namespace
echo "-- Set the kubectl context to use the PROM_NAMESPACE: $PROM_NAMESPACE"
kubectl config set-context --current --namespace=$PROM_NAMESPACE
# Get Pod Name
export PROM_POD_CURRENT=$(kubectl get po -n $PROM_NAMESPACE | awk '{print $1}' | grep prometheus-server)

# Prepare the initial commands
cat << EOF > $CONTAINER_CMD
#!/bin/bash
set -x
cd /tmp/data
curr_month=$(date +%m)
curr_year=$(date +%Y)
path="/tmp/data/*"
for file in $path
do
    file_month=$(date -r $file +%m)
    file_year=$(date -r $file +%Y)
    if [[ $file_month == $curr_month && $file_year == $curr_year ]]
    then
      aws s3 cp "$file" s3://$BUCKET_NAME/$file --recursive
    fi
done

EOF

echo "-- Transfer processing ... --"
kubectl cp $CONTAINER_CMD $PROM_POD_CURRENT:/tmp/data/ -c helper
kubectl exec po/$PROM_POD_CURRENT -c helper -- /bin/bash -c "chmod +x /tmp/data/$CONTAINER_CMD"
kubectl exec po/$PROM_POD_CURRENT -c helper -- /bin/bash -c "bash /tmp/data/$CONTAINER_CMD"
echo "-- Data is copied to S3!"

# Scale the prometheus to 0
echo "-- Scale Prometheus's Deployment to 0"
kubectl scale deploy/prometheus-server --replicas=0
kubectl scale deploy/prometheus-alertmanager --replicas=0
kubectl delete po $PROM_POD_CURRENT --force
sleep 10s


# Prepare the new values
helm get values prometheus | tee $PROM_VALUES
cp $PROM_VALUES "$PROM_VALUES.bak"
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
    existingClaim: $EXISTING_PVC_ALERTMANAGER
server:
  replicaCount: 1
  # Keep the metrics for 3 months
  retention: 8h  # Can't use PVs with "Deployments" (1)
  persistentVolume:
    enabled: true
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
kubectl  create secret generic  thanos-storage-config --from-file=thanos-storage-config=thanos-storage-config.yaml

echo "-- Upgrade the helm: $PROM_VERSION"
helm repo add prometheus https://prometheus-community.github.io/helm-charts
helm repo update
kubectl delete deployments.apps -l app.kubernetes.io/instance=prometheus,app.kubernetes.io/name=kube-state-metrics --cascade=orphan
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

compactor:
  enabled: true
  serviceAccount:
    existingServiceAccount: "$SERVICE_ACCOUNT_NAME"
  extraEnvVars:
  - name: OBJSTORE_CONFIG
    valueFrom:
      secretKeyRef:
        key: thanos-storage-config
        name: thanos-storage-config
storegateway:
  enabled: true
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