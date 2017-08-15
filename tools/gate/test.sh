#!/bin/bash

set -ex

NS=berth

#echo
#pwd
#ip r
#echo

helm install --name=berth --debug ./berth --values=examples/cirros-test.yaml --namespace="${NS}"

# pause just long enough for kubernets to fill in the blanks so 'get
# pods' output is useful
sleep 10
kubectl -n "${NS}" get pods

IP=$(kubectl get pods  -o wide  -n berth -o json | jq -r '.items[].status.podIP')

# wait for pod to come up say something on ssh
timeout=60
t=0
while : ; do
    if echo "bye" | nc "${IP}" 22 | grep --quiet ^SSH ; then
	echo "VM up"
	exit 0
    fi
    if [ $t -gt $timeout ] ; then
	exit 2
    fi
    t=$(($t + 5))
    sleep 5
done
exit 3
