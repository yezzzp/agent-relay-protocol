name: Go
detect: go.mod
language: Go
package_manager: go modules
install: go mod download
dev: go run ./...
check: gofmt -l . && go vet ./... && go test ./...
test_one: go test ./pkg -run TestX
