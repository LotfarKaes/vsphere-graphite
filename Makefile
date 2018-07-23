GOVERSION=$(shell go version)
COMMIT=$(shell git log -1 --pretty=format:"%h")
TAG=$(shell git tag -l --points-at HEAD)
GOOS=$(word 1,$(subst /, ,$(lastword $(GOVERSION))))
GOARCH=$(word 2,$(subst /, ,$(lastword $(GOVERSION))))
RELEASE_DIR=releases
SRC_FILES=$(wildcard *.go)
EXTRA_FLAGS=-X main.commit=$(COMMIT) -X main.tag=$(TAG)
MUSL_BUILD_FLAGS=-ldflags '-linkmode external -s -w -extldflags "-static" $(EXTRA_FLAGS)' -a
BUILD_FLAGS=-ldflags '$(EXTRA_FLAGS) -s' -a
MUSL_CC=musl-gcc
MUSL_CCGLAGS="-static"

deps:
	go get golang.org/x/sys/windows/registry
	go get github.com/takama/daemon
	go get golang.org/x/net/context
	go get github.com/vmware/govmomi
	go get github.com/marpaia/graphite-golang
	go get github.com/influxdata/influxdb/client/v2
	go get github.com/pquerna/ffjson/fflib/v1
	go get code.cloudfoundry.org/bytefmt
	go get github.com/pquerna/ffjson
	go get github.com/olivere/elastic
	go get github.com/prometheus/client_golang/prometheus
	go generate ./...

build-windows-amd64:
	@$(MAKE) build GOOS=windows GOARCH=amd64 SUFFIX=.exe

dist-windows-amd64:
	@$(MAKE) dist GOOS=windows GOARCH=amd64 SUFFIX=.exe

build-linux-amd64:
	@$(MAKE) build GOOS=linux GOARCH=amd64

dist-linux-amd64:
	@$(MAKE) dist GOOS=linux GOARCH=amd64

build-darwin-amd64:
	@$(MAKE) build GOOS=darwin GOARCH=amd64

dist-darwin-amd64:
	@$(MAKE) dist GOOS=darwin GOARCH=amd64
    
build-linux-arm:
	@$(MAKE) build GOOS=linux GOARCH=arm GOARM=5

dist-linux-arm:
	@$(MAKE) dist GOOS=linux GOARCH=arm GOARM=5

docker-build: $(RELEASE_DIR)/$(GOOS)/$(GOARCH)/vsphere-graphite
	cp $(RELEASE_DIR)/$(GOOS)/$(GOARCH)/* docker/
	mkdir -p docker/etc
	cp vsphere-graphite-example.json docker/etc/vsphere-graphite.json
	docker build -f docker/Dockerfile -t cblomart/$(PREFIX)vsphere-graphite docker
	docker tag cblomart/$(PREFIX)vsphere-graphite cblomart/$(PREFIX)vsphere-graphite:$(COMMIT)
	if [ ! -z "$TAG"];then\
		docker tag cblomart/$(PREFIX)vsphere-graphite cblomart/$(PREFIX)vsphere-graphite:$(TAG);\
		docker tag cblomart/$(PREFIX)vsphere-graphite cblomart/$(PREFIX)vsphere-graphite:latest;\
	fi

docker-push:
    docker push cblomart/$(PREFIX)vsphere-graphite:$(COMMIT)
	if [ ! -z "$TAG"];then\
		docker push cblomart/$(PREFIX)vsphere-graphite:($TAG);\
		docker push cblomart/$(PREFIX)vsphere-graphite:latest;\
	fi
    

docker-linux-amd64:
	@$(MAKE) docker-build GOOS=linux GOARCH=amd64

docker-linux-arm:
	@$(MAKE) docker-build GOOS=linux GOARCH=arm PREFIX=rpi-

docker-darwin-amd64: ;

docker-windows-amd64: ;

push-linux-amd64:
	@$(MAKE) docker-push 

push-linux-arm:
    @$(MAKE) docker-push PREFIX=rpi-

checks:
	go get honnef.co/go/tools/cmd/gosimple
	go get golang.org/x/lint/golint
	go get github.com/gordonklaus/ineffassign
	go get github.com/securego/gosec/cmd/gosec/...
	gosimple ./...
	gofmt -s -d .
	go vet ./...
	golint ./...
	ineffassign ./
	gosec ./...
	go tool vet ./..

$(RELEASE_DIR)/$(GOOS)/$(GOARCH)/vsphere-graphite$(SUFFIX): $(SRC_FILES)
	if [ "$(GOOS)-$(GOARCH)" = "linux-amd64" ]; then\
		echo "Using musl";\
		CC=$(MUSL_CC) CCGLAGS=$(MUSL_CCGLAGS) go build $(MUSL_BUILD_FLAGS) -o $(RELEASE_DIR)/linux/amd64//vsphere-graphite .;\
	else\
		go build $(BUILD_FLAGS) -o $(RELEASE_DIR)/$(GOOS)/$(GOARCH)/vsphere-graphite$(SUFFIX) .;\
	fi
	if [ ! -z "$(TAG)"]; then\
		upx -qq --best $(RELEASE_DIR)/$(GOOS)/$(GOARCH)/vsphere-graphite$(SUFFIX);\
	fi
	cp vsphere-graphite-example.json $(RELEASE_DIR)/$(GOOS)/$(GOARCH)/vsphere-graphite.json

$(RELEASE_DIR)/vsphere-graphite_$(GOOS)_$(GOARCH).tgz: $(RELEASE_DIR)/$(GOOS)/$(GOARCH)/vsphere-graphite$(SUFFIX)
	cd $(RELEASE_DIR)/$(GOOS)/$(GOARCH); tar czf /tmp/vsphere-graphite_$(GOOS)_$(GOARCH).tgz ./vsphere-graphite$(SUFFIX) ./vsphere-graphite.json

dist: $(RELEASE_DIR)/vsphere-graphite_$(GOOS)_$(GOARCH).tgz

build: $(RELEASE_DIR)/$(GOOS)/$(GOARCH)/vsphere-graphite$(SUFFIX)

clean:
	rm -rf $(RELEASE_DIR)
	
all:
	@$(MAKE) dist-windows-amd64 
	@$(MAKE) dist-linux-amd64
	@$(MAKE) dist-darwin-amd64
	@$(MAKE) dist-linux-arm
