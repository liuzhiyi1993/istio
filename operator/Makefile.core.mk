# Copyright 2019 Istio Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

HUB ?= gcr.io/istio-testing
TAG ?= 1.6-dev

pwd := $(shell pwd)

# make targets

# -------------------------- Lint ----------------------------------

.PHONY: lint lint-dependencies test_with_coverage mandiff build fmt vfsgen update-charts update-goldens

lint-dependencies:
	@! go mod graph | grep k8s.io/kubernetes || echo "depenency on k8s.io/kubernetes not allowed" || exit 2

lint: lint-copyright-banner lint-dependencies lint-go lint-python lint-scripts lint-yaml lint-dockerfiles lint-licenses

fmt: format-go tidy-go

# -------------------------- Tests ---------------------------------

test:
	@go test -v -race ./...

test_with_coverage:
	@go test -race -coverprofile=coverage.txt -covermode=atomic ./...
	@curl -s https://codecov.io/bash | bash -s -- -c -F aFlag -f coverage.txt

mandiff:
	@scripts/run_mandiff.sh

gen-check: clean gen check-clean-repo

update-goldens:
	@REFRESH_GOLDENS=true go test -v ./cmd/mesh/...

e2e:
	@HUB=$(HUB) TAG=$(TAG) bash -c tests/e2e/e2e.sh

# -------------------------- Gen -----------------------------------

gen: operator-proto vfsgen tidy-go mirror-licenses

vfsgen:
	@scripts/run_update_charts.sh

# -------------------------- Clean ---------------------------------

clean: clean-proto clean-vfs

clean-vfs:
	@rm -fr pkg/vfs/assets.gen.go

clean-proto:
	@rm -fr $(v1alpha1_pb_gos) $(v1alpha1_pb_docs) $(v1alpha1_pb_pythons)

# -------------------------- Controller ----------------------------

controller:
	go build -o $(GOBIN)/istio-operator ./cmd/manager
	STATIC=0 GOOS=$(TARGET_OS) GOARCH=$(TARGET_ARCH) LDFLAGS='-extldflags -static -s -w' common/scripts/gobuild.sh $(TARGET_OUT)/istio-operator ./cmd/manager

docker: controller
	mkdir -p $(GOBIN)/docker
	cp -a $(GOBIN)/istio-operator $(GOBIN)/docker/istio-operator
	cp -a build/Dockerfile $(GOBIN)/docker/Dockerfile.operator
	cp -aR build/bin $(GOBIN)/docker/bin
	cd $(GOBIN)/docker;docker build -t $(HUB)/operator:$(TAG) -f Dockerfile.operator .

docker.push:
	docker push $(HUB)/operator:$(TAG)

docker.save: docker
	mkdir -p $(TARGET_OUT)/release/docker
	docker save $(HUB)/operator:$(TAG) -o $(TARGET_OUT)/release/docker/operator.tar
	gzip --best $(TARGET_OUT)/release/docker/operator.tar

docker.all: docker docker.push

# -------------------------- Proto ---------------------------------

TMPDIR := $(shell mktemp -d)

repo_dir := .
out_path = ${TMPDIR}
protoc = protoc -I../common-protos -I.

go_plugin_prefix := --go_out=plugins=grpc,
go_plugin := $(go_plugin_prefix):$(out_path)

python_output_path := python/istio_api
protoc_gen_python_prefix := --python_out=,
protoc_gen_python_plugin := $(protoc_gen_python_prefix):$(repo_dir)/$(python_output_path)

protoc_gen_docs_plugin := --docs_out=warnings=true,mode=html_fragment_with_front_matter:$(repo_dir)/

########################

# Legacy IstioControlPlane included for translation purposes.
icp_v1alpha2_path := pkg/apis/istio/v1alpha2
icp_v1alpha2_protos := $(wildcard $(icp_v1alpha2_path)/*.proto)
icp_v1alpha2_pb_gos := $(icp_v1alpha2_protos:.proto=.pb.go)
icp_v1alpha2_pb_pythons := $(patsubst $(icp_v1alpha2_path)/%.proto,$(python_output_path)/$(icp_v1alpha2_path)/%_pb2.py,$(icp_v1alpha2_protos))
icp_v1alpha2_pb_docs := $(icp_v1alpha2_path)/v1alpha2.pb.html
icp_v1alpha2_openapi := $(icp_v1alpha2_protos:.proto=.json)

$(icp_v1alpha2_pb_gos) $(icp_v1alpha2_pb_docs) $(icp_v1alpha2_pb_pythons): $(icp_v1alpha2_protos)
	@$(protoc) $(go_plugin) $(protoc_gen_docs_plugin)$(icp_v1alpha2_path) $(protoc_gen_python_plugin) $^
	@cp -r ${TMPDIR}/pkg/* pkg/
	@rm -fr ${TMPDIR}/pkg
	@go run $(repo_dir)/pkg/apis/istio/fixup_structs/main.go -f $(icp_v1alpha2_path)/istiocontrolplane_types.pb.go
	@sed -i 's|<key,value,effect>|\&lt\;key,value,effect\&gt\;|g' $(icp_v1alpha2_path)/v1alpha2.pb.html
	@sed -i 's|<operator>|\&lt\;operator\&gt\;|g' $(icp_v1alpha2_path)/v1alpha2.pb.html

generate-icp: $(icp_v1alpha2_pb_gos) $(icp_v1alpha2_pb_docs) $(icp_v1alpha2_pb_pythons)

clean-icp:
	@rm -fr $(icp_v1alpha2_pb_gos) $(icp_v1alpha2_pb_docs) $(icp_v1alpha2_pb_pythons)

v1alpha1_path := pkg/apis/istio/v1alpha1
v1alpha1_protos := $(wildcard $(v1alpha1_path)/*.proto)
v1alpha1_pb_gos := $(v1alpha1_protos:.proto=.pb.go)
v1alpha1_pb_pythons := $(patsubst $(v1alpha1_path)/%.proto,$(python_output_path)/$(v1alpha1_path)/%_pb2.py,$(v1alpha1_protos))
v1alpha1_pb_docs := $(v1alpha1_path)/v1alpha1.pb.html
v1alpha1_openapi := $(v1alpha1_protos:.proto=.json)

$(v1alpha1_pb_gos) $(v1alpha1_pb_docs) $(v1alpha1_pb_pythons): $(v1alpha1_protos)
	@$(protoc) $(go_plugin) $(protoc_gen_docs_plugin)$(v1alpha1_path) $(protoc_gen_python_plugin) $^
	@cp -r ${TMPDIR}/pkg/* pkg/
	@rm -fr ${TMPDIR}/pkg
	@go run $(repo_dir)/pkg/apis/istio/fixup_structs/main.go -f $(v1alpha1_path)/values_types.pb.go

operator-proto: $(v1alpha1_pb_gos) $(v1alpha1_pb_docs) $(v1alpha1_pb_pythons)

include common/Makefile.common.mk
