#!/bin/bash

# Set configure
BUCKET_NAME=hx-loki-demo-en5ainge
cd /tmp/data/loki/chunks
aws s3api put-object --bucket $BUCKET_NAME --key index/
aws s3api put-object --bucket $BUCKET_NAME --key fake/
aws s3 cp index s3://$BUCKET_NAME/index --recursive

chmod +x /src/script.py

# Create Database SQLite

sqlite3 -line loki-migration.db 'create table progres_data (id INTEGER PRIMARY KEY AUTOINCREMENT,week TEXT NOT NULL,year TEXT NOT NULL, time_start timestamp, time_finish timestamp, duration integer,total integer, status TEXT)'

python /src/script.py