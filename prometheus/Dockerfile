FROM ubuntu:16.04

RUN apt update -y && apt -y upgrade

RUN apt install curl zip -y

RUN cd /home && curl https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip && unzip awscliv2.zip && ./aws/install

# Copy script bash
WORKDIR /src

COPY cronjob.sh cronjob.sh

RUN chmod +x cronjob.sh