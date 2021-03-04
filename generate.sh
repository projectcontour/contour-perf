#!/usr/bin/env bash

set -o errexit
set -o pipefail

if [ -z "$1" ]
then
  echo "usage: ./generate.sh COUNT"
  exit 1
fi

set -o nounset

# clean up 
rm -rf gen
mkdir -p gen

count=$1
echo "Generating ${count} httpproxies and services in ./gen"
for i in `seq 1 ${count}`
do
  sed "s/NUMBER/$i/g" httpproxy.template > gen/proxy-$i.yaml
  sed "s/NUMBER/$i/g" service.template > gen/service-$i.yaml
done
echo "Done"