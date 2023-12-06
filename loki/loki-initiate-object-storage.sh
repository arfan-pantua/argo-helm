#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export ACCOUNT_ID=...
export OIDC_PROVIDER=...
export SERVICE_ACCOUNT_NAME=...
export ROLE_NAME=...
export POLICY_NAME=...
export BUCKET_NAME=...
export REGION_S3=...
export LOKI_NAMESPACE=... # or 'default'
export CLUSTER_NAME=...
export RELEASE_NAME=...
#!!! Just ignore when loki doesnt need to run in dedicated Node, but fill the values if the pod need to run in dedicated node !!!
export DEDICATED_NODE=false # change to be "true" when loki need to run in dedicated node
export effect=""
export key=""
export value=""
export operator=""
export label_node_key=""
export label_node_value=""

# Set to the specific version
export LOKI_VERSION=2.9.1
#--------------------------------------------------------------------------------------

# Env Definition
export LOKI_VALUES=loki.values.yaml

# Create new namespace
echo "-- Create new namespace --"
kubectl create ns $LOKI_NAMESPACE

# Set namespace
echo "-- Set the kubectl context to use the LOKI_NAMESPACE: $LOKI_NAMESPACE"
kubectl config set-context --current --namespace=$LOKI_NAMESPACE

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
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${LOKI_NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
        }
      }
    }
  ]
}
EOF

ROLE_ARN=$(aws iam create-role --role-name ${ROLE_NAME} \
	    --assume-role-policy-document file://trust.json)

kubectl annotate serviceaccount -n ${LOKI_NAMESPACE} \
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


# Prepare the new values
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
      s3: s3://$REGION_S3/$BUCKET_NAME
    boltdb_shipper:
      active_index_directory: /data/loki/boltdb-shipper-active
      cache_location: /data/loki/boltdb-shipper-cache
      cache_ttl: 24h         # Can be increased for faster performance over longer query periods, uses more disk space
      shared_store: aws
  compactor:
    working_directory: /data/compactor
    shared_store: aws
    compaction_interval: 5m
replicas: 1
serviceAccount:
  create: false
  name: $SERVICE_ACCOUNT_NAME
  annotations: {}
EOF


echo "-- Upgrade the helm: $LOKI_VERSION"
helm repo add loki https://grafana.github.io/helm-charts
helm repo update

if [[ $DEDICATED_NODE == false ]]
then
    helm upgrade --install --version $LOKI_VERSION $RELEASE_NAME loki/loki --values $LOKI_VALUES \
    --set persistence.enabled=true --set replicas=1
else
    helm upgrade --install --version $LOKI_VERSION $RELEASE_NAME loki/loki --values $LOKI_VALUES \
    --set tolerations[0].operator=$operator,tolerations[0].effect=$effect,tolerations[0].key=$key,tolerations[0].value=$value \
    --set nodeSelector.$label_node_key=$label_node_value \
    --set persistence.enabled=false --set replicas=1
fi