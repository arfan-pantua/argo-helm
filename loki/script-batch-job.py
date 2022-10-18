#!/usr/bin/python3
import sys
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

filenames =  glob.glob(f"{DATA_FILES_LOCATION}/*", recursive=True)
datauploaded = []
# Sort list of files based on last modification time in ascending order
#filenames = sorted( filenames, key = os.path.getmtime)
first_file = min(filenames, key=os.path.getmtime)
current_week_file = time.strftime("%W", time.gmtime(os.path.getmtime("{}".format(first_file))))
current_year_file = time.strftime("%Y", time.gmtime(os.path.getmtime("{}".format(first_file))))
thisLatest = False
def isNotLatest():
    global thisLatest
    latest_file = max(filenames, key=os.path.getmtime)
    latest_week_file = get_week(latest_file)
    latest_year_file = get_year(latest_file)
    if latest_week_file == current_week_file and latest_year_file == current_year_file:
        thisLatest= True
    return True

def checkLatestBatch():
    global current_week_file, current_year_file
    sqliteConnection = sqlite3.connect('/tmp/data/loki-migration.db')
    cursor = sqliteConnection.cursor()
    print("Connected to SQLite")
    cursor.execute("select week,year from progres_data_batch order by id desc limit 1")
    results = cursor.fetchone()
    if results:
        current_week_file = results[0]
        current_year_file = results[1]

def nextPatch():
    global current_week_file, current_year_file
    next_week = datetime.date(int(current_year_file), 1, 1) + relativedelta(weeks=+int(current_week_file)+1)
    current_week_file = next_week.strftime("%W")
    current_year_file = next_week.strftime("%Y")
def get_week(file):
    week = time.strftime("%W", time.gmtime(os.path.getmtime("{}".format(file))))
    return week
def get_year(file):
    year = time.strftime("%Y", time.gmtime(os.path.getmtime("{}".format(file))))
    return year

def upload(myfile):
    filename = os.path.basename(myfile)
    if os.path.isfile(myfile) and filename != "index":
        try:
            full_filename = str(filename)
            #b64_filename = base64.b64decode(full_filename)
            b64_filename = base64.b64decode(full_filename)
            b64_filename = b64_filename.decode("utf-8")
            src = f"{DATA_FILES_LOCATION}/{full_filename}"
            dst = f"{b64_filename}"
            time_start = datetime.datetime.now()
            s3.Bucket(BUCKET_NAME).upload_file(src, dst)
            time_finish = datetime.datetime.now()
            size_file= os.path.getsize(src)
            addDataUploaded(time_start,time_finish,size_file,full_filename)
            print(f"Filename {full_filename} in week {current_week_file} and year {current_year_file}")
            logging.info(f"Filename {full_filename} in week {current_week_file} and year {current_year_file}")
        except binascii.Error as e:
            logging.error(f"The program encountered an error", str(e))

def addDataUploaded(time_start,time_finish,size,filename):
    try:
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

def checkUploadedFile(filename):
    global datauploaded
    for file in datauploaded:
        if filename == file:
            return False
    return True

def pool_handler():
    time_start = datetime.datetime.now()
    pool = Pool(10)
    processes = [pool.apply_async(upload, args=(x,)) for x in filtering_data(filenames,current_week_file,current_year_file)]
    result = [p.get() for p in processes]
    print(f" Week : {current_week_file} Year : {current_year_file}")
    time_finish = datetime.datetime.now()
    addData(time_start,time_finish,len(result),f"Done data in week {current_week_file} and year {current_year_file}")

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
        sqlite_insert_with_param = """INSERT INTO 'progres_data_batch'(week,year,time_start,time_finish,duration,total,status) values (?,?,?,?,?,?
,?);"""
        data = (current_week_file,current_year_file,time_start,time_finish,duration.total_seconds(),total,status)
        cursor.execute(sqlite_insert_with_param, data)
        sqliteConnection.commit()
    except sqlite3.Error as error:
        logging.error(f"The program encountered an error", str(error))
    finally:
        if sqliteConnection:
            sqliteConnection.close()
            print("sqlite connection is closed")

def filtering_data(data,current_patch_week, current_patch_year):
    all_files_current_week = []
    all_files_current_week_to_upload = []
    while len(all_files_current_week)==0:
        all_files_current_week = [f for f in data if get_week(f) == current_patch_week and get_year(f) == current_patch_year]
        if all_files_current_week:
            for file in all_files_current_week:
                if checkUploadedFile(os.path.basename(file)):
                    all_files_current_week_to_upload.append(file)
            break
        nextPatch()
        current_patch_week = current_week_file
        current_patch_year = current_year_file
    return all_files_current_week_to_upload

if __name__ == "__main__":
    tic = time.perf_counter()
    checkLatestBatch()
    getAllDataUploaded()
    while isNotLatest():
        pool_handler()
        nextPatch()
        if thisLatest:
            break
    toc = time.perf_counter()
    print(f"Done! Total time is {toc - tic} in seconds")