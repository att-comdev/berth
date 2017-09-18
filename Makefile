# This Makefile is used during development and can usually be ignored
# by most people.

validation:
	@echo ===========================================================================
	python validate.py example-vmlist-1.yaml
	@echo ===========================================================================
	python validate.py example-vmlist-bad.yaml
	@echo ===========================================================================

all: test

default: test

test: install

install: build
	@echo
	-helm delete --purge berth >>helm-delete.log 2>&1
	@echo
	helm install --name=berth --dry-run --debug --values=example-vmlist-1.yaml ./berth 2>&1 | tee helm-debug.log
	helm install --name=berth           --debug --values=example-vmlist-1.yaml ./berth 2>&1 | tee helm-install.log
	@sleep 5.0 # give k8s a chance to see the IP
	@echo
	kubectl get pods -o wide

build:
	@echo
	helm lint berth

clean:
	rm -f *~ */*~ */*/*~ berth-0.1.0.tgz helm*.log

.PHONY:
	all default build clean
