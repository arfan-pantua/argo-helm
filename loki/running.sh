#!/bin/bash


if [[ $1 == 'batch-job' ]]
then
    # Create Database SQLite
    sqlite3 -line loki-migration.db 'create table if not exists progres_data_batch (id INTEGER PRIMARY KEY AUTOINCREMENT,week TEXT NOT NULL,year TEXT NOT NULL, time_start timestamp, time_finish timestamp, duration integer,total integer, status TEXT)'
    # Running proses migration data
    python /src/script-batch-job.py
else
    # Create Database SQLite
    sqlite3 -line loki-migration.db 'create table if not exists progres_data_daily (id INTEGER PRIMARY KEY AUTOINCREMENT,day TEXT NOT NULL,time_start timestamp, time_finish timestamp, duration integer,total integer, status TEXT)'
    # Running proses migration data
    python /src/script-daily-job.py
fi