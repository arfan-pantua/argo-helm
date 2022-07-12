#!/bin/bash

# Create Database SQLite
sqlite3 -line loki-migration.db 'create table progres_data (id INTEGER PRIMARY KEY AUTOINCREMENT,week TEXT NOT NULL,year TEXT NOT NULL, time_start timestamp, time_finish timestamp, duration integer,total integer, status TEXT)'
# Running proses migration data
python /src/script.py