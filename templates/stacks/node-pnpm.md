name: Node (pnpm)
detect: pnpm-lock.yaml
language: TypeScript / JavaScript
package_manager: pnpm
install: pnpm install
dev: pnpm dev
check: pnpm lint && pnpm typecheck && pnpm test
check_changed: pnpm lint && pnpm typecheck && pnpm vitest run --changed {integration}
test_one: pnpm test -- <pattern>
