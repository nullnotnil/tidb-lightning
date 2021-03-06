### Makefile for tidb-lightning

LDFLAGS += -X "github.com/pingcap/tidb-lightning/lightning/common.ReleaseVersion=$(shell git describe --tags --dirty="-dev")"
LDFLAGS += -X "github.com/pingcap/tidb-lightning/lightning/common.BuildTS=$(shell date -u '+%Y-%m-%d %I:%M:%S')"
LDFLAGS += -X "github.com/pingcap/tidb-lightning/lightning/common.GitHash=$(shell git rev-parse HEAD)"
LDFLAGS += -X "github.com/pingcap/tidb-lightning/lightning/common.GitBranch=$(shell git rev-parse --abbrev-ref HEAD)"
LDFLAGS += -X "github.com/pingcap/tidb-lightning/lightning/common.GoVersion=$(shell go version)"

LIGHTNING_BIN := bin/tidb-lightning
LIGHTNING_CTL_BIN := bin/tidb-lightning-ctl
FAILPOINT_CTL_BIN := tools/bin/failpoint-ctl
REVIVE_BIN        := tools/bin/revive
GOLANGCI_LINT_BIN := tools/bin/golangci-lint
VFSGENDEV_BIN     := tools/bin/vfsgendev
TEST_DIR := /tmp/lightning_test_result
# this is hard-coded unless we want to generate *.toml on fly.

path_to_add := $(addsuffix /bin,$(subst :,/bin:,$(GOPATH)))
export PATH := $(path_to_add):$(PATH)

GO        := go
GOBUILD   := GO111MODULE=on CGO_ENABLED=1 $(GO) build
GOTEST    := GO111MODULE=on CGO_ENABLED=1 $(GO) test -p 3

ARCH      := "`uname -s`"
LINUX     := "Linux"
MAC       := "Darwin"
PACKAGES  := $$(go list ./...| grep -vE 'vendor|cmd|test|proto|diff|bin|fuzz')
FILES     := $$(find lightning cmd -name '*.go' -type f -not -name '*.pb.go' -not -name '*_generated.go')

FAILPOINT_ENABLE  := $$($(FAILPOINT_CTL_BIN) enable $$PWD/lightning/)
FAILPOINT_DISABLE := $$($(FAILPOINT_CTL_BIN) disable $$PWD/lightning/)

RACE_FLAG =
ifeq ("$(WITH_RACE)", "1")
	RACE_FLAG = -race
	GOBUILD   = GOPATH=$(GOPATH) CGO_ENABLED=1 $(GO) build
endif

.PHONY: all clean lightning lightning-ctl test lightning_for_integration_test \
	integration_test coverage update ensure_failpoint_ctl failpoint_enable failpoint_disable \
	check vet fmt revive web

default: clean lightning lightning-ctl checksuccess

clean:
	rm -f $(LIGHTNING_BIN) $(LIGHTNING_CTRL_BIN) $(FAILPOINT_CTL_BIN) $(REVIVE_BIN) $(VFSGENDEV_BIN)

checksuccess:
	@if [ -f $(LIGHTNING_BIN) ] && [ -f $(LIGHTNING_CTRL_BIN) ]; \
	then \
		echo "Lightning build successfully :-) !" ; \
	fi

%_generated.go: %.rl
	ragel -Z -G2 -o tmp_parser.go $<
	@echo '// Code generated by ragel DO NOT EDIT.' | cat - tmp_parser.go | sed 's|//line |//.... |g' > $@
	@rm tmp_parser.go

$(VFSGENDEV_BIN):
	cd tools && $(GOBUILD) -o ../$(VFSGENDEV_BIN) github.com/shurcooL/vfsgen/cmd/vfsgendev

data_parsers: $(VFSGENDEV_BIN) lightning/mydump/parser_generated.go
	PATH="$(GOPATH)/bin":"$(PATH)" protoc -I. -I"$(GOPATH)/src" lightning/checkpoints/file_checkpoints.proto --gogofaster_out=.
	$(VFSGENDEV_BIN) -source='"github.com/pingcap/tidb-lightning/lightning/web".Res' && mv res_vfsdata.go lightning/web/

web:
	cd web && npm install && npm run build

lightning_for_web:
	$(GOBUILD) $(RACE_FLAG) -tags dev -ldflags '$(LDFLAGS)' -o $(LIGHTNING_BIN) cmd/tidb-lightning/main.go

lightning:
	$(GOBUILD) $(RACE_FLAG) -ldflags '$(LDFLAGS)' -o $(LIGHTNING_BIN) cmd/tidb-lightning/main.go

lightning-ctl:
	$(GOBUILD) $(RACE_FLAG) -ldflags '$(LDFLAGS)' -o $(LIGHTNING_CTL_BIN) cmd/tidb-lightning-ctl/main.go

test: ensure_failpoint_ctl
	mkdir -p "$(TEST_DIR)"
	$(FAILPOINT_ENABLE)
	@export log_level=error;\
	$(GOTEST) -cover -covermode=count -coverprofile="$(TEST_DIR)/cov.unit.out" $(PACKAGES) || ( $(FAILPOINT_DISABLE) && exit 1 )
	$(FAILPOINT_DISABLE)

lightning_for_integration_test: ensure_failpoint_ctl
	$(FAILPOINT_ENABLE)
	$(GOTEST) -c -cover -covermode=count \
		-coverpkg=github.com/pingcap/tidb-lightning/... \
		-o $(LIGHTNING_BIN).test \
		github.com/pingcap/tidb-lightning/cmd/tidb-lightning || ( $(FAILPOINT_DISABLE) && exit 1 )
	$(GOTEST) -c -cover -covermode=count \
		-coverpkg=github.com/pingcap/tidb-lightning/... \
		-o $(LIGHTNING_CTL_BIN).test \
		github.com/pingcap/tidb-lightning/cmd/tidb-lightning-ctl || ( $(FAILPOINT_DISABLE) && exit 1 )
	$(FAILPOINT_DISABLE)

integration_test: lightning_for_integration_test
	@which bin/tidb-server
	@which bin/tikv-server
	@which bin/pd-server
	@which bin/tikv-importer
	tests/run.sh

coverage:
	GO111MODULE=off go get github.com/wadey/gocovmerge
	gocovmerge "$(TEST_DIR)"/cov.* | grep -vE ".*.pb.go|.*__failpoint_binding__.go" > "$(TEST_DIR)/all_cov.out"
ifeq ("$(JenkinsCI)", "1")
	GO111MODULE=off go get github.com/mattn/goveralls
	@goveralls -coverprofile=$(TEST_DIR)/all_cov.out -service=jenkins-ci -repotoken $(COVERALLS_TOKEN)
else
	go tool cover -html "$(TEST_DIR)/all_cov.out" -o "$(TEST_DIR)/all_cov.html"
	grep -F '<option' "$(TEST_DIR)/all_cov.html"
endif

update:
	GO111MODULE=on go mod verify
	GO111MODULE=on go mod tidy

$(FAILPOINT_CTL_BIN):
	cd tools && $(GOBUILD) -o ../$(FAILPOINT_CTL_BIN) github.com/pingcap/failpoint/failpoint-ctl

ensure_failpoint_ctl: $(FAILPOINT_CTL_BIN)
	@[ "$$(grep -h failpoint go.mod tools/go.mod | uniq | wc -l)" -eq 1 ] || \
	( echo 'failpoint version of go.mod and tools/go.mod differ' && false )

failpoint_enable: ensure_failpoint_ctl
	$(FAILPOINT_ENABLE)

failpoint_disable: ensure_failpoint_ctl
	$(FAILPOINT_DISABLE)


check: fmt revive vet lint

fmt:
	gofmt -s -l -w $(FILES)

$(REVIVE_BIN):
	cd tools && $(GOBUILD) -o ../$(REVIVE_BIN) github.com/mgechev/revive

revive: $(REVIVE_BIN)
	$(REVIVE_BIN) -formatter friendly -config tools/revive.toml $(FILES)

vet:
	go vet -unreachable=false  $(PACKAGES)
# Not checking unreachable since Ragel-generated code do contain unreachable branches and
# go vet cannot be selectively silenced (https://github.com/golang/go/issues/17058).
# This is enabled in revive instead.

$(GOLANGCI_LINT_BIN):
	cd tools && $(GOBUILD) -o ../$(GOLANGCI_LINT_BIN) github.com/golangci/golangci-lint/cmd/golangci-lint

lint: $(GOLANGCI_LINT_BIN)
	export PACKAGES=$(PACKAGES) && \
	$(GOLANGCI_LINT_BIN) run $${PACKAGES//github.com\/pingcap\/tidb-lightning\//}
