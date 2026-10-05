.PHONY: test compose-config build export-image

ENGINE_IMAGE ?= safewhisper-engine:local

test:
	/Users/gil/.hermes/hermes-agent/venv/bin/python -m pytest -q

compose-config:
	docker compose config

build:
	docker compose build

export-image:
	docker save $(ENGINE_IMAGE) | gzip > safewhisper-engine-image.tar.gz
