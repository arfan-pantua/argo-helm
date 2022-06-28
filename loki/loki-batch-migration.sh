#!/bin/bash

set -e -x

#-------------------------------------------------------------------------------------
#!!! Replace the values !!!
export ACCOUNT_ID="<ACCOUNT_ID>"
export OIDC_PROVIDER="<OIDC_PROVIDER>"
export SERVICE_ACCOUNT_NAME="<SERVICE_ACCOUNT_NAME>"
export ROLE_NAME="<ROLE_NAME>"
export BUCKET_NAME="<BUCKET_NAME>"
export POLICY_NAME="<POLICY_NAME>"

export LOKI_NAMESPACE=loki # or 'default'
export LOKI_RELEASE_NAME=loki
export STORAGE_CLASS_NAME=<STORAGE_CLASS_NAME>

# Set to the specific version
export LOKI_VERSION=2.11.1
export CLUSTER_NAME=DEMO
#--------------------------------------------------------------------------------------

# Env Definition
export LOKI_VALUES=loki.values.yaml
export LOKI_POD_HELPER=loki-0

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
#kubectl scale statefulset/loki --replicas=0
#sleep 10s

echo "-- Create container as sidecar of loki --"
# Prepare sidecar
helm get values loki | tee $LOKI_VALUES
cp $LOKI_VALUES "$LOKI_VALUES.bak"
cat << EOF >> $LOKI_VALUES
extraContainers:
## Additional containers to be added to the loki pod.
- name: helper
  image: python:latest
  imagePullPolicy: IfNotPresent
  command: ["/bin/sleep", "3650d"]
  volumeMounts:
    - name: storage
      mountPath: /tmp/data
securityContext:
  runAsNonRoot: false
  runAsUser: 0
serviceAccount:
  create: false
  name: loki-sa
  annotations: {}
EOF

echo "-- Upgrade the helm: $LOKI_VERSION"
helm repo add loki https://grafana.github.io/helm-charts
helm repo update
helm upgrade --version $LOKI_VERSION loki loki/loki --values $LOKI_VALUES
sleep 30s
echo "-- python script"
cat << EOF > $PYTHON_SCRIPT
#!/usr/bin/python3

import binascii
import sqlite3
import datetime
from datetime import datetime
import time
from multiprocessing import Pool
import multiprocessing
import time
import glob 
import boto3 
import os 
import sys 
import base64
import shutil
from dateutil.relativedelta import relativedelta


# target location of the files on S3  
BUCKET = '<Bucket Name>'
# Source location of files on local system 
DATA_FILES_LOCATION   = "/tmp/data/loki/chunks"
s3 = boto3.resource('s3')
# The list of files we're uploading to S3 

filenames =  glob.glob(f"{DATA_FILES_LOCATION}/*", recursive=True)

# Sort list of files based on last modification time in ascending order
#filenames = sorted( filenames, key = os.path.getmtime)
first_file = min(filenames, key=os.path.getmtime)
current_month_file = time.strftime("%B", time.gmtime(os.path.getmtime("{}".format(first_file))))
current_year_file = time.strftime("%Y", time.gmtime(os.path.getmtime("{}".format(first_file))))
thisLatest = False
def isNotLatest():
    global thisLatest
    latest_file = max(filenames, key=os.path.getmtime)
    latest_month_file = get_month(latest_file)
    latest_year_file = get_year(latest_file)
    if latest_month_file == current_month_file and latest_year_file == current_year_file:
        thisLatest= True
    return True
def nextPatch():
    global current_month_file, current_year_file
    datetime_str = f"{current_month_file} {current_year_file}"
    datetime_object = datetime.strptime(datetime_str, '%B %Y')
    next_month = datetime_object + relativedelta(months=1)
    current_month_file = next_month.strftime("%B")
    current_year_file = next_month.strftime("%Y")
def get_month(file):
    month = time.strftime("%B", time.gmtime(os.path.getmtime("{}".format(file))))
    return month
def get_year(file):
    year = time.strftime("%Y", time.gmtime(os.path.getmtime("{}".format(file))))
    return year

def upload():    
    data = filtering_data(filenames,current_month_file,current_year_file)
    time_start = datetime.now()
    counter = 1
    for myfile in data:
        filename = os.path.basename(myfile)    
        if os.path.isfile(myfile) and filename != "index":
            try:
                full_filename = str(filename)            
                b64_filename = base64.b64decode(full_filename)
                b64_filename = b64_filename.decode("utf-8")
                src = f"{DATA_FILES_LOCATION}/{full_filename}"
                dst = f"{b64_filename}"
                s3.Bucket(BUCKET).upload_file(src, dst)
                print("---")
                print("Uploading...")
                print(":: %s -> %s", (src, dst))
                print(f" Data : {counter}")
                counter = counter + 1
            except binascii.Error as e:
                print(f'Filename {full_filename} in month {current_month_file} and year {current_year_file} cant be decoded!', str(e))
    time_finish = datetime.now()
    addData(time_start,time_finish,counter,f"Done data in {current_month_file} {current_year_file}")
def addData(time_start,time_finish,total,status):
    try:
        sqliteConnection = sqlite3.connect('loki-migration.db')
        cursor = sqliteConnection.cursor()
        print("Connected to SQLite")
        duration = time_finish - time_start
        # Insert data
        sqlite_insert_with_param = """INSERT INTO 'progres_data'(month,year,time_start,time_finish,duration,total,status) values (?,?,?,?,?,?);"""
        data = (current_month_file,current_year_file,time_start,time_finish,duration.total_seconds(),total,status)
        cursor.execute(sqlite_insert_with_param, data)
        sqliteConnection.commit()
    except sqlite3.Error as error:
        print("Error while working with SQLite", error)
    finally:
        if sqliteConnection:
            sqliteConnection.close()
            print("sqlite connection is closed")
def filtering_data(data,current_patch_month, current_patch_year):
    current_patch_files = []
    while len(current_patch_files)==0:
        current_patch_files = [f for f in data if get_month(f) == current_patch_month and get_year(f) == current_patch_year]
        if len(current_patch_files)!=0:
            break
        nextPatch()
        current_patch_month = current_month_file
        current_patch_year = current_year_file
    return current_patch_files

if __name__ == "__main__":
    tic = time.perf_counter()
    while isNotLatest():
        upload()
        nextPatch()
        if thisLatest:
            break
    toc = time.perf_counter()
    print(f"Done! Total time is {toc - tic} in seconds")
EOF

# Prepare the initial commands
cat << EOF > $CONTAINER_CMD
set -x
apt-get update
apt-get install curl zip python3-pip sqlite3 -y
pip install boto3
pip install awscli
pip install python-dateutil
cd /home

curl https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip

unzip awscliv2.zip

./aws/install


cd /tmp/data/loki
aws s3api put-object --bucket $BUCKET_NAME --key index/
aws s3api put-object --bucket $BUCKET_NAME --key fake/
aws s3 cp chunks/index s3://$BUCKET_NAME/index --recursive

chmod +x /tmp/data/$PYTHON_SCRIPT

# Create Database SQLite

sqlite3 -line loki-migration.db 'create table progres_data (id INTEGER PRIMARY KEY AUTOINCREMENT,month TEXT NOT NULL,year TEXT NOT NULL, time_start timestamp, time_finish timestamp, duration integer,total integer, status TEXT)'

python /tmp/data/$PYTHON_SCRIPT
EOF

echo "-- Transfer processing ... --"
kubectl cp $PYTHON_SCRIPT $LOKI_POD_HELPER:/tmp/data/ -c helper
kubectl cp $CONTAINER_CMD $LOKI_POD_HELPER:/tmp/data/ -c helper
kubectl exec po/$LOKI_POD_HELPER -c helper -- /bin/bash -c "chmod +x /tmp/data/$CONTAINER_CMD"
kubectl exec po/$LOKI_POD_HELPER -c helper -- /bin/bash -c "bash /tmp/data/$CONTAINER_CMD"
echo "-- Data is copied to S3!"
