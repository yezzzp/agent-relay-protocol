name: Python (poetry)
detect: poetry.lock
language: Python
package_manager: poetry
install: poetry install
dev: poetry run python -m <module>
check: poetry run ruff format --check . && poetry run ruff check . && poetry run mypy . && poetry run pytest -q --testmon-noselect
check_changed: poetry run ruff format --check . && poetry run ruff check . && poetry run mypy . && poetry run pytest -q --testmon
test_deps: poetry add --group dev pytest-testmon
test_map: .testmondata
test_one: poetry run pytest tests/test_x.py::test_y
