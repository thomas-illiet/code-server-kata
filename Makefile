SHELL := /usr/bin/bash
.DEFAULT_GOAL := help

VM_NAME ?= kata-k8s
NAMESPACE ?= code-server
KUBECONFIG ?= $(CURDIR)/.state/hyperv-kata/$(VM_NAME).kubeconfig
BENCHMARK_ITERATIONS ?= 10

COMMON_ARGS = --vm-name "$(VM_NAME)" --kubeconfig "$(KUBECONFIG)"
WORKSPACE_ARGS = $(COMMON_ARGS) --namespace "$(NAMESPACE)"

.PHONY: help tools doctor versions-check repository-check check release-check cluster deploy deploy-fast verify benchmark status shell

help:
	@printf '%s\n' \
	  'Workflow WSL principal:' \
	  '  make tools        Installe les outils Linux dans WSL' \
	  '  make doctor       Vérifie WSL, Multipass, la VM et Kubernetes' \
	  '  make versions-check Vérifie hors ligne les versions et images épinglées' \
	  '  make repository-check Recherche secrets, chemins locaux et gros fichiers' \
	  '  make check        Lance les validations statiques Bash/Kustomize' \
	  '  make release-check Exécute toutes les portes locales avant publication' \
	  '  make cluster      Provisionne K3s + Kata dans la VM existante' \
	  '  make deploy       Construit, importe, déploie et vérifie' \
	  '  make deploy-fast  Redéploie sans reconstruire l’image' \
	  '  make verify       Relance toutes les preuves live' \
	  '  make benchmark    Compare runc rootful et Kata rootless' \
	  '  make status       Affiche nœud, pod, PVC, service et URL' \
	  '  make shell        Ouvre un shell dans la VM Multipass'

tools:
	bash ./scripts/wsl/install-tools.sh

doctor:
	bash ./scripts/wsl/doctor.sh $(COMMON_ARGS)

versions-check:
	bash ./scripts/wsl/check-version-pins.sh

repository-check:
	bash ./scripts/wsl/check-repository.sh

check: versions-check
	bash ./tests/test-static.sh

release-check: repository-check check

cluster:
	bash ./scripts/wsl/provision-cluster.sh $(COMMON_ARGS)

deploy:
	bash ./scripts/wsl/deploy-workspace.sh $(WORKSPACE_ARGS)

deploy-fast:
	bash ./scripts/wsl/deploy-workspace.sh $(WORKSPACE_ARGS) --skip-image-build

verify:
	bash ./scripts/wsl/verify-workspace.sh $(WORKSPACE_ARGS)

benchmark:
	bash ./scripts/wsl/benchmark-podman.sh --kubeconfig "$(KUBECONFIG)" \
	  --iterations "$(BENCHMARK_ITERATIONS)"

status:
	bash ./scripts/wsl/status.sh $(WORKSPACE_ARGS)

shell:
	bash ./scripts/wsl/shell.sh --vm-name "$(VM_NAME)"
