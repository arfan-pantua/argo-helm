FROM python:latest

RUN apt-get update && apt-get install curl zip python3-pip sqlite3 -y
RUN pip install boto3
RUN pip install awscli
RUN pip install python-dateutil
RUN cd /home &&  curl https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip &&  unzip awscliv2.zip && ./aws/install
ENV BUCKET_NAME "-"
WORKDIR /src

# Copy script python and bash
COPY script-batch-job.py script-batch-job.py
COPY script-daily-job.py script-daily-job.py
COPY running.sh running.sh
RUN chmod +x script-batch-job.py script-daily-job.py running.sh