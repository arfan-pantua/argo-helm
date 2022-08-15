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

filenames =  glob.glob(f"{DATA_FILES_LOCATION}/*", recursive=True)

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
            s3.Bucket(BUCKET_NAME).upload_file(src, dst)
            print(f"Filename {full_filename} today {datetime.datetime.now()}")
            logging.info(f"Filename {full_filename} today {datetime.datetime.now()}")
        except binascii.Error as e:
            logging.error(f"The program encountered an error", str(e))

def pool_handler():
    time_start = datetime.datetime.now()
    pool = Pool(10)
    processes = [pool.apply_async(upload, args=(x,)) for x in filtering_data(filenames)]
    result = [p.get() for p in processes]
    print(f" Today is : {time_start}")
    time_finish = datetime.datetime.now()
    addData(time_start,time_finish,len(result),f"Done data today {time_finish}")

def addData(time_start,time_finish,total,status):
    try:
        logging.basicConfig(filename="log-sqlite-migration.txt", level=logging.ERROR)
        sqliteConnection = sqlite3.connect('loki-migration.db')
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
    current_patch_files = []
    current_patch_files = [f for f in data if get_today(f) == datetime.datetime.now().strftime("%d/%m/%Y")]        
    return current_patch_files

if __name__ == "__main__":
    tic = time.perf_counter()
    pool_handler()
    toc = time.perf_counter()
    print(f"Done! Total time is {toc - tic} in seconds")