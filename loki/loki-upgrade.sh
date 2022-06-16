#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export LOKI_NAMESPACE=loki # or 'default'
export LOKI_RELEASE_NAME=loki
export STORAGE_CLASS_NAME=...

# Set to the specific version
export LOKI_VERSION=2.10.3
export CLUSTER_NAME=DEV
#--------------------------------------------------------------------------------------

# Env Definition
export LOKI_VALUES=loki.values.yaml
export LOKI_POD_HELPER=loki-migrate-helper

export POD_MANIFEST="pod-helper.manifest.yaml"
export PYTHON_SCRIPT="script.py"
export POD_CMD="pod-helper.install.sh"

## !!! Fill this !!!
export ACCOUNT_ID="<ACCOUNT_ID>"
export OIDC_PROVIDER="<OIDC_PROVIDER>"
export SERVICE_ACCOUNT_NAME="<SERVICE_ACCOUNT_NAME>" #by default it was prometheus-server dont use this name
export ROLE_NAME="<ROLE_NAME>"
export BUCKET_NAME="<BUCKET_NAME>"
export POLICY_NAME="<POLICY_NAME>"

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

# Get the loki PVC name
echo "-- Get the loki PVC name"
export LOKI_PVC=$(kubectl get pvc -n $LOKI_NAMESPACE | awk '{print $1}' | grep loki)
echo $LOKI_PVC


# Prepare the pod manifest
cat << EOF > $POD_MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: $LOKI_POD_HELPER
  labels:
    app: $LOKI_POD_HELPER
spec:
  serviceAccountName: $SERVICE_ACCOUNT_NAME
  volumes:
    - name: pv-storage
      persistentVolumeClaim:
        claimName: $LOKI_PVC
  containers:
  - name: $LOKI_POD_HELPER
    image: python:latest
    imagePullPolicy: IfNotPresent
    command: ["/bin/sleep", "3650d"]
    volumeMounts:
      - mountPath: "/tmp/data"
        name: pv-storage
  restartPolicy: Always
EOF
kubectl apply -f $POD_MANIFEST
echo "-- Waiting to available..."
kubectl wait pods -l app=$LOKI_POD_HELPER --for condition=Ready --timeout=100s
sleep 30s

echo "-- python script"
cat << EOF > $PYTHON_SCRIPT
#!/usr/bin/python3
import os
import base64
import shutil
def main():
    os.chdir("/tmp/data/loki/chunks")
    os.mkdir("/tmp/data/loki/chunks-copy")
    os.mkdir("/tmp/data/loki/chunks-copy/fake")
    for count, filename in enumerate(os.listdir("/tmp/data/loki/chunks")):
        if filename != "index":
            full_filename = str(filename)
            srcDir = "/tmp/data/loki/chunks"
            dstDir = "/tmp/data/loki/chunks-copy"
            b64_filename = base64.b64decode(full_filename)
            b64_filename = b64_filename.decode("utf-8")
            src = f"{srcDir}/{full_filename}"
            dst = f"{dstDir}/{b64_filename}"
            shutil.copyfile(src,dst)
            #os.rename(src, dst)
if __name__ == '__main__':
    main()
EOF

# Prepare the initial commands
cat << EOF > $POD_CMD
set -x
apt update -y && apt -y upgrade

apt install curl zip -y

cd /home

curl https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip

unzip awscliv2.zip

./aws/install

chmod +x /tmp/data/$PYTHON_SCRIPT

/tmp/data/$PYTHON_SCRIPT

cd /tmp/data/loki
aws s3api put-object --bucket $BUCKET_NAME --key index/
aws s3 cp chunks-copy s3://$BUCKET_NAME --recursive
aws s3 cp chunks/index s3://$BUCKET_NAME/index --recursive

rm -R chunks-copy
EOF

echo "-- Transfer processing ... --"
kubectl cp $PYTHON_SCRIPT $LOKI_POD_HELPER:/tmp/data/
kubectl cp $POD_CMD $LOKI_POD_HELPER:/tmp/data/
kubectl exec po/$LOKI_POD_HELPER -- /bin/bash -c "chmod +x /tmp/data/$POD_CMD"
kubectl exec po/$LOKI_POD_HELPER -- /bin/bash -c "bash /tmp/data/$POD_CMD"
echo "-- Data is copied to S3!"
# Release helper pod
echo "-- Release the POD Helper"
kubectl delete -f $POD_MANIFEST

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
replicas: 1
serviceAccount:
  create: false
  name: $SERVICE_ACCOUNT_NAME
  annotations: {}
EOF

echo "-- Upgrade the helm: $LOKI_VERSION"
helm repo add loki https://grafana.github.io/helm-charts
helm repo update
helm upgrade --version $LOKI_VERSION loki loki/loki --values $LOKI_VALUES