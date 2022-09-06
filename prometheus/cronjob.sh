#!/bin/bash
set -x

cd /tmp/data
curr_date=$(date +%F)
path="/tmp/data/*"
echo "Current date is $curr_date"
for file in $path
do
    basename=$(basename $file)
    if [[ $2 != "" ]]
    then
      file_last_modified=$(date -r $file +%F)
      if [[ $file_last_modified == $curr_date ]]
      then        
        aws s3 cp "$file" s3://$1/$basename --recursive
        echo "From $2"
        echo "File name is $basename , last modified at  $file_last_modified"
      fi
    else
      aws s3 cp "$file" s3://$1/$basename --recursive
      echo "From Non-Daily"
      echo "File name is $basename , last modified at  $file_last_modified "
    fi     
done
echo "Data has been transferred"
