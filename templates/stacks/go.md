name: Go
detect: go.mod
language: Go
package_manager: go modules
install: go mod download
dev: go run ./...
check: gofmt -l . && go vet ./... && go test ./...
check_changed: gofmt -l . && go vet ./... && go test ./...
note: go test caches results per package, so unchanged packages are not re-run
test_one: go test ./pkg -run TestX
