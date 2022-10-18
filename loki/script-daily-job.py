#!/usr/bin/python3

import binascii
from calendar import week
import sqlite3
import datetime
from multiprocessing import Pool
import time
import glob
import boto3
import os
import logging
import base64
from dateutil.relativedelta import relativedelta


# target location of the files on S3
BUCKET_NAME=os.environ.get('BUCKET_NAME')
# Source location of files on local system
DATA_FILES_LOCATION   = "/tmp/data/loki/chunks"
s3 = boto3.resource('s3')
# The list of files we're uploading to S3

filenames =  glob.glob(f"{DATA_FILES_LOCATION}/*", recursive=True) #sorted by name
#sorted(glob.glob(f"{DATA_FILES_LOCATION}/*", recursive=True), key=os.path.getmtime) sorted by time
datauploaded = []

def get_today(file):
    today = time.strftime("%d/%m/%Y", time.gmtime(os.path.getmtime("{}".format(file))))
    return today

def upload(myfile):
    filename = os.path.basename(myfile)
    if os.path.isfile(myfile) and filename != "index":
        try:
            full_filename = str(filename)
            b64_filename = base64.b64decode(full_filename)
            b64_filename = b64_filename.decode("utf-8")
            src = f"{DATA_FILES_LOCATION}/{full_filename}"
            dst = f"{b64_filename}"
            time_start = datetime.datetime.now()
            s3.Bucket(BUCKET_NAME).upload_file(src, dst)
            time_finish = datetime.datetime.now()
            size_file= os.path.getsize(src)
            print(f"Filename {full_filename} today {datetime.datetime.now()}")
            addDataUploaded(time_start,time_finish,size_file,filename)
            logging.info(f"Filename {full_filename} today {datetime.datetime.now()}")
        except binascii.Error as e:
            logging.error(f"The program encountered an error", str(e))

def addDataUploaded(time_start,time_finish,size,filename):
    try:
        logging.basicConfig(filename="log-sqlite-migration-data-uploaded.txt", level=logging.ERROR)
        sqliteConnection = sqlite3.connect('/tmp/data/loki-migration.db')
        cursor = sqliteConnection.cursor()
        print("Connected to SQLite")
        duration = time_finish - time_start
        # Insert data
        sqlite_insert_with_param = """INSERT INTO 'progres_data_uploaded'(day,week,year,time_start,time_finish,duration,size,filename) values (?,?,?,?,?,?,?,?);"""
        data = (datetime.datetime.now().strftime("%d"),datetime.datetime.now().strftime("%W"),datetime.datetime.now().strftime("%Y"),time_start,time_finish,duration.total_seconds(),size,filename)
        cursor.execute(sqlite_insert_with_param, data)
        sqliteConnection.commit()
    except sqlite3.Error as error:
        logging.error(f"The program encountered an error", str(error))
    finally:
        if sqliteConnection:
            sqliteConnection.close()
            print("sqlite connection is closed")

def pool_handler():
    time_start = datetime.datetime.now()
    pool = Pool(10)
    processes = [pool.apply_async(upload, args=(x,)) for x in filtering_data(filenames)]
    result = [p.get() for p in processes]
    print(f" Today is : {time_start}")
    time_finish = datetime.datetime.now()
    addData(time_start,time_finish,len(result),f"Done data today {time_finish}")

def getAllDataUploaded():
    global datauploaded
    sqliteConnection = sqlite3.connect('/tmp/data/loki-migration.db')
    cursor = sqliteConnection.cursor()
    day = datetime.datetime.now().strftime("%d")
    week = datetime.datetime.now().strftime("%W")
    year = datetime.datetime.now().strftime("%Y")
    print("Connected to SQLite")
    cursor.execute("select filename from progres_data_uploaded where day=? and week=? and year=?",(day,week,year))
    results = cursor.fetchall()
    if results:
        for result in results:
            datauploaded.append(result[0])

def addData(time_start,time_finish,total,status):
    try:
        logging.basicConfig(filename="log-sqlite-migration.txt", level=logging.ERROR)
        sqliteConnection = sqlite3.connect('/tmp/data/loki-migration.db')
        cursor = sqliteConnection.cursor()
        print("Connected to SQLite")
        duration = time_finish - time_start
        # Insert data
        sqlite_insert_with_param = """INSERT INTO 'progres_data_daily'(day,time_start,time_finish,duration,total,status) values (?,?,?,?,?,?);"""
        data = (datetime.datetime.now().strftime("%d/%m/%Y"),time_start,time_finish,duration.total_seconds(),total,status)
        cursor.execute(sqlite_insert_with_param, data)
        sqliteConnection.commit()
    except sqlite3.Error as error:
        logging.error(f"The program encountered an error", str(error))
    finally:
        if sqliteConnection:
            sqliteConnection.close()
            print("sqlite connection is closed")

def filtering_data(data):
    all_files_today = []
    all_files_today_to_upload = []
    all_files_today = [f for f in data if get_today(f) == datetime.datetime.now().strftime("%d/%m/%Y")]
    if all_files_today:
        for file in all_files_today:
            if checkUploadedFile(os.path.basename(file)):
                all_files_today_to_upload.append(file)
    return all_files_today_to_upload

def checkUploadedFile(filename):
    global datauploaded
    if datauploaded:
        for file in datauploaded:
            if filename == file:
                return False
    return True

if __name__ == "__main__":
    tic = time.perf_counter()
    getAllDataUploaded()
    pool_handler()
    toc = time.perf_counter()
    print(f"Done! Total time is {toc - tic} in seconds")