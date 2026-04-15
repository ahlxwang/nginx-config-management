# app/db.py
import pymysql
import pymysql.cursors
from flask import current_app, g


def get_db():
    """获取当前请求的数据库连接（存储在 Flask g 对象中）"""
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
        )
    return g.db


def close_db(e=None):
    db = g.pop('db', None)
    if db is not None:
        db.close()


def query(sql, args=None):
    """执行查询，返回所有行（list of dict）"""
    with get_db().cursor() as cursor:
        cursor.execute(sql, args or ())
        return cursor.fetchall()


def get_one(sql, args=None):
    """执行查询，返回单行（dict 或 None）"""
    with get_db().cursor() as cursor:
        cursor.execute(sql, args or ())
        return cursor.fetchone()


def execute(sql, args=None):
    """执行 INSERT/UPDATE/DELETE，返回 lastrowid"""
    with get_db().cursor() as cursor:
        cursor.execute(sql, args or ())
        return cursor.lastrowid
