#!/bin/sh

set -x

NS=berth

#echo
#pwd
#ip r
#echo

helm install --name=berth ./berth --values=examples/cirros-test.yaml --namespace="${NS}"
kubectl -n "${NS}" get pods
