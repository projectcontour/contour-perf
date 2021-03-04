#!/usr/bin/env bash

set -o errexit
set -o pipefail

if [ -z "$1" ]
then
  echo "usage: ./parallel-create.sh COUNT"
  exit 1
fi

set -o nounset

# Runs 10 kubectl clients at the same time
count=$1
for i in `seq 0 10 ${count}`
do
    kubectl create -f gen/service-$i.yaml &
    kubectl create -f gen/service-$((i+1)).yaml &
    kubectl create -f gen/service-$((i+2)).yaml &
    kubectl create -f gen/service-$((i+3)).yaml &
    kubectl create -f gen/service-$((i+4)).yaml &
    kubectl create -f gen/service-$((i+5)).yaml &
    kubectl create -f gen/service-$((i+6)).yaml &
    kubectl create -f gen/service-$((i+7)).yaml &
    kubectl create -f gen/service-$((i+8)).yaml &
    kubectl create -f gen/service-$((i+9)).yaml 
done

for i in `seq 0 10 ${count}`
do
    kubectl create -f gen/proxy-$i.yaml &
    kubectl create -f gen/proxy-$((i+1)).yaml &
    kubectl create -f gen/proxy-$((i+2)).yaml &
    kubectl create -f gen/proxy-$((i+3)).yaml &
    kubectl create -f gen/proxy-$((i+4)).yaml &
    kubectl create -f gen/proxy-$((i+5)).yaml &
    kubectl create -f gen/proxy-$((i+6)).yaml &
    kubectl create -f gen/proxy-$((i+7)).yaml &
    kubectl create -f gen/proxy-$((i+8)).yaml &
    kubectl create -f gen/proxy-$((i+9)).yaml
done
