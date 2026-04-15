# app/__init__.py
from flask import Flask
from app.config import config_map
from app.extensions import csrf, login_manager, limiter


def create_app(config_name='development'):
    app = Flask(__name__)
    app.config.from_object(config_map[config_name])

    if config_name == 'production' and app.config.get('SECRET_KEY') == 'dev-secret-change-in-prod':
        raise RuntimeError('SECRET_KEY must be set via environment variable in production')

    # 初始化扩展
    csrf.init_app(app)
    login_manager.init_app(app)
    limiter.init_app(app)

    # 注册 teardown
    from app.db import close_db
    app.teardown_appcontext(close_db)

    # 注册蓝图
    from app.auth import auth_bp
    from app.routes.config import config_bp
    from app.routes.cluster import cluster_bp
    from app.routes.host import host_bp
    from app.routes.user import user_bp
    from app.routes.log import log_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(config_bp, url_prefix='/config')
    app.register_blueprint(cluster_bp, url_prefix='/cluster')
    app.register_blueprint(host_bp, url_prefix='/host')
    app.register_blueprint(user_bp, url_prefix='/user')
    app.register_blueprint(log_bp, url_prefix='/log')

    return app
