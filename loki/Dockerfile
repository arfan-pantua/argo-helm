FROM python:latest

RUN apt-get update && apt-get install curl zip python3-pip sqlite3 -y
RUN pip install boto3
RUN pip install awscli
RUN pip install python-dateutil
RUN cd /home &&  curl https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip &&  unzip awscliv2.zip && ./aws/install

WORKDIR /src

# Copy script python and bash
COPY script.py script.py
COPY running.sh running.sh
RUN chmod +x script.py running.sh