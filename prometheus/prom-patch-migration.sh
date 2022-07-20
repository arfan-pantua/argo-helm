#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export ACCOUNT_ID="<ACCOUNT_ID>"
export OIDC_PROVIDER="<OIDC_PROVIDER>"
export SERVICE_ACCOUNT_NAME="<SERVICE_ACCOUNT_NAME>" #by default it was prometheus-server dont use this name
export ROLE_NAME="<ROLE_NAME>"
export BUCKET_NAME="<BUCKET_NAME>"
export POLICY_NAME="<POLICY_NAME>"

export PROM_NAMESPACE=prometheus # or 'default'
export PROM_RELEASE_NAME=prometheus

# Set to the specific version
export PROM_VERSION=15.0.4
export CLUSTER_NAME=DEV
#--------------------------------------------------------------------------------------

# Env Definition
export PROM_VALUES=prometheus.values.yaml
export BUCKET_NAME="hx-prom"

# Set namespace
echo "-- Set the kubectl context to use the PROMETHEUS NAMESPACE: $PROM_NAMESPACE"
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


# Scale the prometheus to 0
echo "-- Scale Prometheus's Deployment to 0"
kubectl scale deploy/prometheus-server --replicas=0
kubectl scale deploy/prometheus-alertmanager --replicas=0
sleep 10s

echo "-- Create container as sidecar of prometheus --"
# Prepare sidecar
helm get values prometheus | tee $PROM_VALUES
cp $PROM_VALUES "$PROM_VALUES.bak"
cat << EOF >> $PROM_VALUES
  extraArgs:
    storage.tsdb.max-block-duration: 3m
    storage.tsdb.min-block-duration: 3m
  sidecarContainers:
  - name: helper
    image: arfanpantua/prometheus-patch-migration:ubuntu-16
    imagePullPolicy: Always
    command: ["/bin/sh"]
    args: ["-c", "while true; do cd /home; aws s3 cp /tmp/data s3://$BUCKET_NAME --recursive; sleep 30d;done"]
    volumeMounts:
    - mountPath: /tmp/data
      name: storage-volume
      readOnly: true
    securityContext:
      runAsNonRoot: false
      runAsUser: 0
resources:
  limits:
    cpu: 1
  requests:
    cpu: 0.5
serviceAccounts:
  server:
    create: false
    name: $SERVICE_ACCOUNT_NAME
  pushgateway:
    create: false
    name: $SERVICE_ACCOUNT_NAME
EOF

echo "-- Upgrade the helm: $PROM_VERSION"
helm repo add prometheus https://prometheus-community.github.io/helm-charts
helm repo update
kubectl delete deployments.apps -l app.kubernetes.io/instance=prometheus,app.kubernetes.io/name=kube-state-metrics --cascade=orphan
helm upgrade --version $PROM_VERSION prometheus prometheus/prometheus --values $PROM_VALUES 
