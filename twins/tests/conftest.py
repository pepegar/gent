import sys
import os
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


@pytest.fixture
def anthropic_client():
    from anthropic.main import app, control
    control.reset()
    client = TestClient(app)
    yield client
    control.reset()


@pytest.fixture
def openai_client():
    from openai.main import app, control
    control.reset()
    client = TestClient(app)
    yield client
    control.reset()
