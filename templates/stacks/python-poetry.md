name: Python (poetry)
detect: poetry.lock
language: Python
package_manager: poetry
install: poetry install
dev: poetry run python -m <modulo>
check: poetry run ruff format --check . && poetry run ruff check . && poetry run mypy . && poetry run pytest
test_one: poetry run pytest tests/test_x.py::test_y
