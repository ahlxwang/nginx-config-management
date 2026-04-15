import pytest
from app import create_app
from app.db import get_db


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


@pytest.fixture
def app_ctx(app):
    """提供应用上下文，用于直接调用 get_db() 等需要 current_app 的函数"""
    with app.app_context():
        yield app
