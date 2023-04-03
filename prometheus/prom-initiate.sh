#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export ACCOUNT_ID=...
export OIDC_PROVIDER=...
export SERVICE_ACCOUNT_NAME=... #by default it was prometheus-server dont use this name
export ROLE_NAME=...
export BUCKET_NAME=...
export REGION_S3=...
export POLICY_NAME=...
export CLUSTER_NAME=...


#!!! Just ignore when prometheus doesnt need to run in dedicated Node, but fill the values if the pod need to run in dedicated node !!!
export DEDICATED_NODE=false # change to be "true" when loki need to run in dedicated node
export effect=""
export key=""
export value=""
export operator=""
export label_node_key=""
export label_node_value=""

# Set to the specific version
export PROM_VERSION=15.0.4
export THANOS_VERSION=11.6.5

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

# Create Service Account
kubectl create serviceaccount $SERVICE_ACCOUNT_NAME

###---
cat << EOF > trust.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${PROM_NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
        }
      }
    }
  ]
}
EOF

ROLE_ARN=$(aws iam create-role --role-name ${ROLE_NAME} \
	    --assume-role-policy-document file://trust.json)

kubectl annotate serviceaccount -n ${PROM_NAMESPACE} \
	    ${SERVICE_ACCOUNT_NAME} \
	        eks.amazonaws.com/role-arn=$(echo $ROLE_ARN | jq -r '.Role.Arn')
echo "-- Service Account and role were created"

###---
cat << EOF > policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Statement",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetObject",
                "s3:DeleteObject",
                "s3:PutObject"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}/*",
                "arn:aws:s3:::${BUCKET_NAME}"
            ]
        }
    ]
}
EOF
POLICY_ARN=$(aws iam create-policy --policy-name ${POLICY_NAME} --policy-document file://policy.json)
aws iam attach-role-policy --policy-arn $(echo $POLICY_ARN | jq -r '.Policy.Arn') --role-name ${ROLE_NAME}

echo "-- Policy to access S3 bucket was attached to role $ROLE_NAME --"

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
  endpoint: s3.$REGION_S3.amazonaws.com
EOF
echo "-- create secret thanos storage "
kubectl  create secret generic  thanos-storage-config --from-file=thanos-storage-config=$THANOS_CONF_FILE

echo "-- Upgrade the helm: $PROM_VERSION"
helm repo add prometheus https://prometheus-community.github.io/helm-charts
helm repo update
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