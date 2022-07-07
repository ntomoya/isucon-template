#!/bin/bash

set -ex

# Common deploy script

# (cd ./webapp/go/ && env GOOS=linux GOARCH=amd64 go build -o isucondition)

# cp /home/isucon/isucon11-quals/webapp/go/isucondition /home/isucon/webapp/go/
# scp /home/isucon/isucon11-quals/webapp/go/isucondition 192.168.0.12:/home/isucon/webapp/go/

# ssh isu3 sudo systemctl stop r-isucon-go.service
# scp ./webapp/r-isucon/webapps/go/rmail isu3:/home/isucon/r-isucon/webapps/go/
# ssh isu3 sudo systemctl start r-isucon-go.service

# rsync -avh ./webapp isu1:/home/isucon/
# rsync -avh ./webapp isu2:/home/isucon/
# rsync -avh ./webapp isu3:/home/isucon/
