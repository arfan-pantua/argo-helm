#!/usr/bin/python3

import binascii
from calendar import week
import sqlite3
import datetime
from multiprocessing import Pool
import time
import time
import glob
import boto3
import os
import logging
import base64
from dateutil.relativedelta import relativedelta


# target location of the files on S3  
BUCKET = 'hx-loki-demo-en5ainge'
# Source location of files on local system 
DATA_FILES_LOCATION   = "/tmp/data/loki/chunks"
s3 = boto3.resource('s3')
# The list of files we're uploading to S3 

filenames =  glob.glob(f"{DATA_FILES_LOCATION}/*", recursive=True)

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
            s3.Bucket(BUCKET).upload_file(src, dst)
            print(f"Filename {full_filename} in week {current_week_file} and year {current_year_file}")
            logging.basicConfig(filename="log-migration.txt", level=logging.ERROR)
            logging.info(f"Filename {full_filename} in week {current_week_file} and year {current_year_file}")
        except binascii.Error as e:
            logging.error(f"The program encountered an error", str(e))

def pool_handler():
    time_start = datetime.datetime.now()
    pool = Pool(10)
    processes = [pool.apply_async(upload, args=(x,)) for x in filtering_data(filenames,current_week_file,current_year_file)]
    result = [p.get() for p in processes]
    print(f" Week : {current_week_file} Year : {current_year_file}")
    time_finish = datetime.datetime.now()
    addData(time_start,time_finish,len(result),f"Done data in week {current_week_file} and year {current_year_file}")

def addData(time_start,time_finish,total,status):
    try:
        logging.basicConfig(filename="log-sqlite-migration.txt", level=logging.ERROR)
        sqliteConnection = sqlite3.connect('loki-migration.db')
        cursor = sqliteConnection.cursor()
        print("Connected to SQLite")
        duration = time_finish - time_start
        # Insert data
        sqlite_insert_with_param = """INSERT INTO 'progres_data'(week,year,time_start,time_finish,duration,total,status) values (?,?,?,?,?,?,?);"""
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
    current_patch_files = []
    while len(current_patch_files)==0:
        current_patch_files = [f for f in data if get_week(f) == current_patch_week and get_year(f) == current_patch_year]
        if len(current_patch_files)!=0:
            break
        nextPatch()
        current_patch_week = current_week_file
        current_patch_year = current_year_file
    return current_patch_files

if __name__ == "__main__":
    tic = time.perf_counter()
    while isNotLatest():
        pool_handler()
        nextPatch()
        if thisLatest:
            break
    toc = time.perf_counter()
    print(f"Done! Total time is {toc - tic} in seconds")