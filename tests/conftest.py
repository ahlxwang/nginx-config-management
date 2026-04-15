# tests/conftest.py
import pytest
from app import create_app


@pytest.fixture
def app():
    app = create_app('development')
    app.config.update({
        'TESTING': True,
        'WTF_CSRF_ENABLED': False,
        'DB_NAME': 'nginx_manager_test',
    })
    yield app


@pytest.fixture
def client(app):
    return app.test_client()
