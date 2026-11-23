name: Python (uv)
detect: uv.lock
language: Python
package_manager: uv
install: uv sync
dev: uv run python -m <module>
check: uv run ruff format --check . && uv run ruff check . && uv run mypy . && uv run pytest -q --testmon-noselect
check_changed: uv run ruff format --check . && uv run ruff check . && uv run mypy . && uv run pytest -q --testmon
test_deps: uv add --dev pytest-testmon
test_map: .testmondata
test_one: uv run pytest tests/test_x.py::test_y
