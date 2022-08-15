#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export ACCOUNT_ID="<ACCOUNT_ID>"
export OIDC_PROVIDER="<OIDC_PROVIDER>"
export SERVICE_ACCOUNT_NAME="<SERVICE_ACCOUNT_NAME>"
export ROLE_NAME="<ROLE_NAME>"
export POLICY_NAME="<POLICY_NAME>"
export BUCKET_NAME="<BUCKET_NAME>"

export LOKI_NAMESPACE=loki # or 'default'
export LOKI_RELEASE_NAME=loki
export STORAGE_CLASS_NAME=<STORAGE_CLASS_NAME>

# Set to the specific version
export LOKI_VERSION=2.9.1
export CLUSTER_NAME=DEMO
#--------------------------------------------------------------------------------------

# Env Definition
export LOKI_VALUES=loki.values.yaml
export LOKI_CONTAINER_HELPER=loki-0

export PYTHON_SCRIPT="script.py"
export CONTAINER_CMD="container-helper.install.sh"

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


# Scale the loki to 0
echo "-- Scale Loki's Deployment to 0"
kubectl scale statefulset/loki --replicas=0
sleep 10s

echo "-- Create container as sidecar of loki --"
# Prepare sidecar
helm get values loki | tee $LOKI_VALUES
cp $LOKI_VALUES "$LOKI_VALUES.bak"
cat << EOF >> $LOKI_VALUES
extraContainers:
## Additional containers to be added to the loki pod.
- name: helper
  image: arfanpantua/loki-patch-migration:debian-11
  imagePullPolicy: Always
  #command: ["/bin/sleep", "3650d"]
  command: ["/bin/sh"]
  args: ["-c", "while true; do cd /tmp/data/loki/chunks; aws s3api put-object --bucket $BUCKET_NAME --key index/; aws s3api put-object --bucket $BUCKET_NAME --key fake/; aws s3 cp index s3://$BUCKET_NAME/index --recursive; /src/running.sh; sleep 30d;done"]
  volumeMounts:
    - name: storage
      mountPath: /tmp/data
  env:
    - name: BUCKET_NAME
      value: $BUCKET_NAME
serviceAccount:
  create: false
  name: $SERVICE_ACCOUNT_NAME
securityContext:
  runAsNonRoot: false
  runAsUser: 0
resources:
  limits:
    cpu: 0.25
    memory: 1Gi
  requests:
    cpu: 0.20
    memory: 205Mi
terminationGracePeriodSeconds: 50
EOF

echo "-- Upgrade the helm: $LOKI_VERSION"
helm repo add loki https://grafana.github.io/helm-charts
helm repo update
helm upgrade --version $LOKI_VERSION loki loki/loki --values $LOKI_VALUES
kubectl wait pods -l release=$LOKI_RELEASE_NAME --for condition=Ready --timeout=100s