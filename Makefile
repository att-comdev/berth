# This Makefile is used during development and can usually be ignored
# by most people.

all: test

default: test

test: install

install: build
	@echo
	-helm delete --purge berth
	@echo
	helm install --name=berth           --debug --values=examples/vmlist-1.yaml ./berth
	@sleep 5.0 # give k8s a chance to see the IP
	@echo
	kubectl get pods -o wide

build:
	@echo
	helm lint berth

clean:
	rm -f *~ */*~ */*/*~ berth-0.1.0.tgz

.PHONY:
	all default build clean
