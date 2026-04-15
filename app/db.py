import pymysql
import pymysql.cursors
from contextlib import contextmanager
from flask import current_app, g


def get_db():
    if 'db' not in g:
        cfg = current_app.config
        g.db = pymysql.connect(
            host=cfg['DB_HOST'],
            port=cfg['DB_PORT'],
            user=cfg['DB_USER'],
            password=cfg['DB_PASSWORD'],
            database=cfg['DB_NAME'],
            charset='utf8mb4',
            cursorclass=pymysql.cursors.DictCursor,
            autocommit=True,
            connect_timeout=5,
        )
    else:
        g.db.ping(reconnect=True)
    return g.db


def close_db(e=None):
    db = g.pop('db', None)
    if db is not None:
        db.close()


def query(sql, args=None):
    with get_db().cursor() as cursor:
        cursor.execute(sql, args or ())
        return cursor.fetchall()


def get_one(sql, args=None):
    with get_db().cursor() as cursor:
        cursor.execute(sql, args or ())
        return cursor.fetchone()


def execute(sql, args=None):
    with get_db().cursor() as cursor:
        cursor.execute(sql, args or ())
        return cursor.lastrowid


@contextmanager
def transaction():
    """多步操作的事务上下文管理器"""
    db = get_db()
    db.autocommit(False)
    try:
        yield db
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.autocommit(True)
