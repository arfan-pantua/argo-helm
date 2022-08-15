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
export BUCKET_NAME=...
export ORGANIZATION_ID=
export scheduler="* * * * *" # * * * * *

export PROM_NAMESPACE=prometheus # or 'default'
export PROM_RELEASE_NAME=prometheus
export PROM_JOB_SIDE=job.migration.yaml
export PROM_CRON_JOB_SIDE=cronjob.migration.yaml
export PROM_JOB_NAME=job-migration-helper
export PROM_CRON_JOB_NAME=cronjob-migration-helper

# Set to the specific version
export PROM_VERSION=15.0.4
export CLUSTER_NAME=DEV
#--------------------------------------------------------------------------------------

# Env Definition
export PROM_VALUES=prometheus.values.yaml


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
      "Sid": "statement-cluster",
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

# Get the prometheus PVC name
echo "-- Get the prometheus PVC name"
export PROM_PVC=$(kubectl get pvc -n $PROM_NAMESPACE | awk '{print $1}' | grep prometheus-server)
echo $PROM_PVC

echo "-- Create job and mount to prometheus existing pvc --"
# Prepare pod
cat << EOF > $PROM_JOB_SIDE
apiVersion: batch/v1
kind: Job
metadata:
  name: $PROM_JOB_NAME
spec:
  template:
    spec:
      volumes:
        - name: job-migration-storage
          persistentVolumeClaim:
            claimName: $PROM_PVC
      serviceAccountName: $SERVICE_ACCOUNT_NAME
      affinity:
        # The Pod affinity rule tells the scheduler to place each replica on a node that has a Pod with the label app=prometheus
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - prometheus
            topologyKey: "kubernetes.io/hostname"
      containers:
      - name: job-migration
        image: 944131029014.dkr.ecr.ap-southeast-1.amazonaws.com/devops-monitoring-stack-upgrade:2d3670702e97
        imagePullPolicy: Always
        command: ["/bin/sh"]
        args: ["-c", "cd /home; aws s3 cp /tmp/data s3://$BUCKET_NAME --recursive;"]
        volumeMounts:
        - mountPath: /tmp/data
          name: job-migration-storage
        resources:
          limits:
            cpu: 0.25
            memory: 250Mi
          requests:
            cpu: 0.20
            memory: 250Mi
      restartPolicy: Never
  backoffLimit: 4
EOF

echo "... apply the job ..."
kubectl apply -f $PROM_JOB_SIDE

echo "-- Create cron job and mount to prometheus existing pvc --"
# Prepare pod
cat << EOF > $PROM_CRON_JOB_SIDE
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: $PROM_CRON_JOB_NAME
spec:
  schedule: $scheduler
  jobTemplate:
    spec:
      template:
        spec:
          volumes:
            - name: cronjob-migration-storage
              persistentVolumeClaim:
                claimName: $PROM_PVC
          serviceAccountName: $SERVICE_ACCOUNT_NAME
          affinity:
            # The Pod affinity rule tells the scheduler to place each replica on a node that has a Pod with the label app=prometheus
            podAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
              - labelSelector:
                  matchExpressions:
                  - key: app
                    operator: In
                    values:
                    - prometheus
                topologyKey: "kubernetes.io/hostname"
          containers:
          - name: cronjob-migration
            image: 944131029014.dkr.ecr.ap-southeast-1.amazonaws.com/devops-monitoring-stack-upgrade:2d3670702e97
            imagePullPolicy: Always
            command: ["/bin/sh"]
            args: ["-c", "bash /src/cronjob.sh $BUCKET_NAME;"]
            volumeMounts:
            - mountPath: /tmp/data
              name: cronjob-migration-storage
            resources:
              limits:
                cpu: 0.25
                memory: 250Mi
              requests:
                cpu: 0.20
                memory: 250Mi
          restartPolicy: Never
EOF

echo "... apply the cron job ..."
kubectl apply -f $PROM_CRON_JOB_SIDE