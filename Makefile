.PHONY: test integration-test build

IMAGE ?= tinitasker/migrations-runner:local
CONTAINER_ENGINE ?= docker

test:
	./tests/run.sh

integration-test:
	./tests/postgres-integration.sh

build:
	$(CONTAINER_ENGINE) build --tag $(IMAGE) .
