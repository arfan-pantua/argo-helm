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

export LOKI_NAMESPACE=... # or 'default'
export LOKI_RELEASE_NAME=...
export scheduler="<scheduler>" # * * * * *

# Set to the specific version
export LOKI_VERSION=2.9.1
export CLUSTER_NAME=DEMO
#--------------------------------------------------------------------------------------

# Env Definition
export LOKI_JOB_SIDE=job.migration.yaml
export LOKI_CRON_JOB_SIDE=cronjob.migration.yaml
export LOKI_JOB_NAME=job-migration-helper
export LOKI_CRON_JOB_NAME=cronjob-migration-helper
# Set namespace
echo "-- Set the kubectl context to use the LOKI_NAMESPACE: $LOKI_NAMESPACE"
kubectl config set-context --current --namespace=$LOKI_NAMESPACE

# Get the loki PVC name
echo "-- Get the loki PVC name"
export LOKI_PVC=$(kubectl get pvc -n $LOKI_NAMESPACE | awk '{print $1}' | grep storage-loki-0)
echo $LOKI_PVC

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



echo "-- Create job and mount to loki existing pvc --"
# Prepare pod
cat << EOF > $LOKI_JOB_SIDE
apiVersion: batch/v1
kind: Job
metadata:
  name: $LOKI_JOB_NAME
spec:
  template:
    spec:
      volumes:
        - name: job-migration-storage
          persistentVolumeClaim:
            claimName: $LOKI_PVC
      serviceAccountName: $SERVICE_ACCOUNT_NAME
      affinity:
        # The Pod affinity rule tells the scheduler to place each replica on a node that has a Pod with the label app=loki
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - loki
            topologyKey: "kubernetes.io/hostname"
      containers:
      - name: job-migration
        image: 944131029014.dkr.ecr.ap-southeast-1.amazonaws.com/devops-monitoring-stack-upgrade:1dd185f4e923
        imagePullPolicy: Always
        command: ["/bin/sh"]
        args: ["-c", "cd /tmp/data/loki/chunks; aws s3api put-object --bucket $BUCKET_NAME
        --key index/; aws s3api put-object --bucket $BUCKET_NAME --key fake/; aws s3 cp index
        s3://$BUCKET_NAME/index --recursive; /src/running.sh batch-job"]
        env:
        - name: BUCKET_NAME
          value: $BUCKET_NAME
        volumeMounts:
        - mountPath: /tmp/data
          name: job-migration-storage
        resources:
          limits:
            cpu: 0.25
            memory: 1Gi
          requests:
            cpu: 0.20
            memory: 250Mi
      restartPolicy: Never
  backoffLimit: 4
EOF

echo "... apply the job ..."
kubectl apply -f $LOKI_JOB_SIDE

echo "-- Create job and mount to loki existing pvc --"
# Prepare pod
cat << EOF > $LOKI_CRON_JOB_SIDE
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: $LOKI_CRON_JOB_NAME
spec:
  schedule: $scheduler
  jobTemplate:
    spec:
      template:
        spec:
          volumes:
            - name: cronjob-migration-storage
              persistentVolumeClaim:
                claimName: $LOKI_PVC
          serviceAccountName: $SERVICE_ACCOUNT_NAME
          affinity:
            # The Pod affinity rule tells the scheduler to place each replica on a node that has a Pod with the label app=loki
            podAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
              - labelSelector:
                  matchExpressions:
                  - key: app
                    operator: In
                    values:
                    - loki
                topologyKey: "kubernetes.io/hostname"
          containers:
          - name: cronjob-migration
            image: 944131029014.dkr.ecr.ap-southeast-1.amazonaws.com/devops-monitoring-stack-upgrade:1dd185f4e923
            imagePullPolicy: Always
            command: ["/bin/sh"]
            args: ["-c", "cd /tmp/data/loki/chunks; aws s3 cp index
            s3://$BUCKET_NAME/index --recursive; /src/running.sh cron-job"]
            env:
            - name: BUCKET_NAME
              value: $BUCKET_NAME
            volumeMounts:
            - mountPath: /tmp/data
              name: cronjob-migration-storage
            resources:
              limits:
                cpu: 0.25
                memory: 1Gi
              requests:
                cpu: 0.20
                memory: 250Mi
          restartPolicy: Never
EOF

echo "... apply the cron job ..."
kubectl apply -f $LOKI_CRON_JOB_SIDE