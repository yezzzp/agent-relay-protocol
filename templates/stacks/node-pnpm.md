name: Node (pnpm)
detect: pnpm-lock.yaml
language: TypeScript / JavaScript
package_manager: pnpm
install: pnpm install
dev: pnpm dev
check: pnpm lint && pnpm typecheck && pnpm test
test_one: pnpm test -- <patron>
