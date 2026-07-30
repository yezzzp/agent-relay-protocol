name: Python (uv)
detect: uv.lock
language: Python
package_manager: uv
install: uv sync
dev: uv run python -m <modulo>
check: uv run ruff format --check . && uv run ruff check . && uv run mypy . && uv run pytest
test_one: uv run pytest tests/test_x.py::test_y
