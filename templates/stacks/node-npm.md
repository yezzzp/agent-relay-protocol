name: Node (npm)
detect: package-lock.json
language: TypeScript / JavaScript
package_manager: npm
install: npm ci
dev: npm run dev
check: npm run lint && npm run typecheck && npm test
test_one: npm test -- <patron>
