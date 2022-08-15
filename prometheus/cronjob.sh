#!/bin/bash
set -x

cd /tmp/data
curr_date=$(date +%F)
path="/tmp/data/*"
echo "Current date is $curr_date"
for file in $path
do
    file_last_modified=$(date -r $file +%F)
    if [[ $file_last_modified == $curr_date ]]
    then
      aws s3 cp "$file" s3://$1/$file --recursive
      echo "File name is $file , last modified at  $file_last_modified"
    fi
done