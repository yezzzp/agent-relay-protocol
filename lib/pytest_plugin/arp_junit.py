"""pytest plugin loaded by `arp test-run`: every pytest process writes its own JUnit file.

A single `--junitxml` path is overwritten when one command runs pytest twice
(`pytest a && pytest b`), so only the last run would be recorded. This plugin
gives each process its own file in ``$ARP_JUNIT_DIR``. xdist workers are left
alone; their controller writes the report.
"""

import os

import pytest


@pytest.hookimpl(tryfirst=True)
def pytest_configure(config):
    folder = os.environ.get("ARP_JUNIT_DIR")
    if not folder or hasattr(config, "workerinput") or config.option.xmlpath:
        return
    config.option.xmlpath = os.path.join(folder, f"junit-{os.getpid()}.xml")
