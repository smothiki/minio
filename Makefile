SHORT_NAME := minio

export GO15VENDOREXPERIMENT=1

# Note that Minio currently uses CGO.

VERSION ?= git-$(shell git rev-parse --short HEAD)
LDFLAGS := "-s -X main.version=${VERSION}"
BINDIR := ./rootfs/bin
DEV_REGISTRY ?= $(docker-machine ip deis):5000
DEIS_REGISTRY ?= ${DEV_REGISTRY}

IMAGE_PREFIX ?= deis

RC := manifests/deis-${SHORT_NAME}-rc.yaml
SVC := manifests/deis-${SHORT_NAME}-service.yaml
ADMIN_SEC := manifests/deis-${SHORT_NAME}-secretAdmin.yaml
USER_SEC := manifests/deis-${SHORT_NAME}-secretUser.yaml
SSL_SEC := manifests/deis-${SHORT_NAME}-secretssl-final.yaml
IMAGE := ${DEIS_REGISTRY}${IMAGE_PREFIX}/${SHORT_NAME}:${VERSION}
MC_IMAGE := ${DEIS_REGISTRY}${IMAGE_PREFIX}/mc:${VERSION}
MC_INTEGRATION_IMAGE := ${DEIS_REGISTRY}${IMAGE_PREFIX}/mc-integration:${VERSION}

all: build docker-build docker-push

bootstrap:
	glide up

build:
	mkdir -p ${BINDIR}
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -a -installsuffix cgo -ldflags '-s' -o $(BINDIR)/boot boot.go || exit 1

docker-build:
	# build the minio server
	docker build -t minio mc
	docker cp `docker run -d minio`:/go/bin/minio $(BINDIR)

	# build the main image
	docker build --rm -t ${IMAGE} rootfs
	# These are both YAML specific
	perl -pi -e "s|image: [a-z0-9.:]+\/deis\/${SHORT_NAME}:[0-9a-z-.]+|image: ${IMAGE}|g" ${RC}
	perl -pi -e "s|release: [a-zA-Z0-9.+_-]+|release: ${VERSION}|g" ${RC}

docker-push: docker-build
	docker push ${IMAGE}

deploy: build docker-build docker-push kube-rc

ssl-cert:
	# generate ssl certs
	docker run --rm -v "${PWD}":/pwd -w /pwd centurylink/openssl:0.0.1 ./genssl/gen.sh
	# replace values in ssl secrets file
	docker run --rm -v "${PWD}":/pwd -w /pwd alpine:3.2 ./genssl/manifest_replace.sh

kube-rc:
	kubectl create -f ${RC}

kube-secrets: ssl-cert
	kubectl create -f ${ADMIN_SEC}
	kubectl create -f ${USER_SEC}
	kubectl create -f ${SSL_SEC}

kube-clean-secrets:
	kubectl delete secret minio-user
	kubectl delete secret minio-admin
	kubectl delete secret minio-ssl

kube-service: kube-secrets
	- kubectl create -f ${SVC}
	- kubectl create -f manifests/deis-minio-secretUser.yaml

kube-clean:
	- kubectl delete rc deis-${SHORT_NAME}-rc

kube-mc:
	kubectl create -f manifests/deis-mc-pod.yaml

kube-mc-integration:
	kubectl create -f manifests/deis-mc-integration-pod.yaml

build-mc:
	docker run -e GO15VENDOREXPERIMENT=1 -e GOROOT=/usr/local/go --rm -v "${PWD}/mc":/pwd -w /pwd golang:1.5.2 ./install.sh

docker-build-mc:
	docker build -t ${MC_IMAGE} mc

docker-push-mc:
	docker push ${MC_IMAGE}
	perl -pi -e "s|image: [a-z0-9.:]+\/|image: ${MC_IMAGE}/|g" manifests/deis-mc-pod.yaml

docker-build-mc-integration:
	docker build -t ${MC_INTEGRATION_IMAGE} mc

docker-push-mc-integration:
	docker push ${MC_INTEGRATION_IMAGE}
	perl -pi -e "s|image: [a-z0-9.:]+\/|image: ${MC_INTEGRATION_IMAGE}/|g" manifests/deis-mc-integration-pod.yaml

.PHONY: all build docker-compile kube-up kube-down deploy mc kube-mc
