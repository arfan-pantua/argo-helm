#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export DB_HOST=...
export DB_PORT=...
export DB_USER=...
export DB_PASS=...
export DB_NAME=...

export GF_NAMESPACE=... # or 'default'
export GF_RELEASE_NAME=...

export ROOT_DOMAIN=...
export CSRF_TRUSTED_ORIGINS=... # use <space> if values is more than one

#!!! Just ignore when grafana doesnt need to run in dedicated Node, but fill the values if the pod need to run in dedicated node !!!
export DEDICATED_NODE=false # change to be "true" when grafana need to run in dedicated node
export effect=""
export key=""
export value=""
export operator=""
export label_node_key=""
export label_node_value=""

# Set to the specific version
export GF_VERSION=6.30.3
export APP_VERSION=8.5.15
#--------------------------------------------------------------------------------------

# Env Definition
export GF_PVC_MOUNT_DIR=/opt/gf-data
export GF_VALUES=grafana.values.yaml
export GF_POD_HELPER=gf-migrate-helper
export GF_CREATE_DB_JOB_MANIFEST=create-db-job.yaml
export GF_CREATE_DB_JOB=create-db-job
export GF_MIGRATE_DB_JOB_MANIFEST=migrate-db-job.yaml
export GF_MIGRATE_DB_JOB=migrate-db-job


# Set namespace
echo "-- Set the kubectl context to use the GF_NAMESPACE: $GF_NAMESPACE"
kubectl config set-context --current --namespace=$GF_NAMESPACE

# Scale the grafana to 0
echo "-- Scale Grafana's Deployment to 0"
kubectl scale deploy/grafana --replicas=0
sleep 5s

# Get the grafana PVC name
echo "-- Get the grafana PVC name"
export GF_PVC=$(kubectl get pvc -n $GF_NAMESPACE | awk '{print $1}' | grep grafana)
echo $GF_PVC

echo "-- Create database job"
# Prepare Job
cat << EOF > $GF_CREATE_DB_JOB_MANIFEST
apiVersion: batch/v1
kind: Job
metadata:
  name: $GF_CREATE_DB_JOB
spec:
  template:
    spec:
      containers:
      - name: $GF_CREATE_DB_JOB
        image: 944131029014.dkr.ecr.ap-southeast-1.amazonaws.com/devops-monitoring-stack-upgrade:grafana
        imagePullPolicy: Always
        command: ["/bin/sh"]
        args: ["-c", "export PGPASSWORD=$DB_PASS;psql --host=$DB_HOST --port=$DB_PORT -U $DB_USER --dbname=postgres -c 'drop database $DB_NAME';
        psql --host=$DB_HOST --port=$DB_PORT -U $DB_USER --dbname=postgres -c 'create database $DB_NAME'"]
      restartPolicy: Never
EOF
if [[ $DEDICATED_NODE = true ]]
then
cat << EOF >> $GF_CREATE_DB_JOB_MANIFEST
      tolerations:
      - effect: $effect
        key: $key
        operator: $operator
        value: $value
EOF
fi

echo "... apply the job ..."
kubectl apply -f $GF_CREATE_DB_JOB_MANIFEST
kubectl wait --for=condition=complete --timeout=10m job/$GF_CREATE_DB_JOB

echo "-- Database is created!"
# Prepare the new values
helm get values grafana | tee $GF_VALUES
cp $GF_VALUES "$GF_VALUES.bak"
cat << EOF >> $GF_VALUES

env:
  GF_DATABASE_TYPE: postgres
  GF_DATABASE_HOST: $DB_HOST
  GF_DATABASE_NAME: $DB_NAME
  GF_DATABASE_USER: $DB_USER

envFromSecret: gf-database-password
grafana.ini:
  server:
    root_url: https://$ROOT_DOMAIN
  security:
    csrf_trusted_origins: $CSRF_TRUSTED_ORIGINS
  # force_migration: true #for degrade version we need to activate this script
EOF

echo "-- create secret grafana database password"
kubectl  create secret generic gf-database-password --from-literal=GF_DATABASE_PASSWORD=$DB_PASS

echo "-- Upgrade the helm: $GF_VERSION to create schema"
#helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
if [[ $DEDICATED_NODE = true ]]
then
    helm upgrade --version $GF_VERSION grafana grafana/grafana --values $GF_VALUES --set replicas=1 \
    --set tolerations[0].operator=$operator,tolerations[0].effect=$effect,tolerations[0].key=$key,tolerations[0].value=$value \
    --set nodeSelector.$label_node_key=$label_node_value \
    --set image.repository=grafana/grafana --set image.tag=$APP_VERSION
else
    helm upgrade --version $GF_VERSION grafana grafana/grafana --values $GF_VALUES --set replicas=1 \
    --set image.repository=grafana/grafana --set image.tag=$APP_VERSION
fi


echo "-- Waiting to available..."
kubectl wait pods -l app.kubernetes.io/instance=$GF_RELEASE_NAME --for condition=Ready --timeout=3m

# Update the new values
helm get values grafana | tee $GF_VALUES

echo "-- Migrate database job"
# Prepare Job
cat << EOF > $GF_MIGRATE_DB_JOB_MANIFEST
apiVersion: batch/v1
kind: Job
metadata:
  name: $GF_MIGRATE_DB_JOB
spec:
  template:
    spec:
      volumes:
        - name: grafana-pvc
          persistentVolumeClaim:
            claimName: $GF_PVC
      containers:
      - name: job-create-db
        image: 944131029014.dkr.ecr.ap-southeast-1.amazonaws.com/devops-monitoring-stack-upgrade:grafana
        imagePullPolicy: Always
        command: ["/bin/sh"]
        args: ["-c", "export PGPASSWORD=$DB_PASS;
        /tmp/grafana-migrate $GF_PVC_MOUNT_DIR/grafana.db 'postgres://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME?sslmode=disable';"]
        volumeMounts:
        - mountPath: "$GF_PVC_MOUNT_DIR"
          name: grafana-pvc
      restartPolicy: Never
EOF
if [[ $DEDICATED_NODE = true ]]
then
cat << EOF >> $GF_MIGRATE_DB_JOB_MANIFEST
      tolerations:
      - effect: $effect
        key: $key
        operator: $operator
        value: $value
EOF
fi
echo "Scale grafana pod over 0"
kubectl scale deploy/grafana --replicas=0
sleep 5s

echo "... apply the migrate job ..."
kubectl apply -f $GF_MIGRATE_DB_JOB_MANIFEST
kubectl wait --for=condition=complete --timeout=10m job/$GF_MIGRATE_DB_JOB

echo "-- Migration is complete! Please check jobs log first"
read -p "Press ENTER to continue, or Ctrl+C to stop..." tmp

echo "release pvc in grafana"
helm upgrade --version $GF_VERSION grafana grafana/grafana --values $GF_VALUES --set persistence.enabled=false --set replicas=3

rm $GF_VALUES *.bak

# Get the prometheus job name
echo "-- Get the prometheus Cron Job name"
export GF_JOB_NAME=$(kubectl get jobs -o custom-columns=:.metadata.name -n $GF_NAMESPACE)
echo $GF_JOB_NAME

# Delete all jobs and cronjob
for j in $GF_JOB_NAME
do
    kubectl delete jobs $j &
done