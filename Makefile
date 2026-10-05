.PHONY: test compose-config build export-image

ENGINE_IMAGE ?= whisperflow-engine:local

test:
	/Users/gil/.hermes/hermes-agent/venv/bin/python -m pytest -q

compose-config:
	docker compose config

build:
	docker compose build

export-image:
	docker save $(ENGINE_IMAGE) | gzip > whisperflow-engine-image.tar.gz
