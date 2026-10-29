import os
from contextlib import closing

import psycopg2
from flask import Flask, jsonify

app = Flask(__name__)


def read_secret(name):
    secret_file = os.getenv(f"{name}_FILE")
    if secret_file:
        with open(secret_file, encoding="utf-8") as f:
            return f.read().strip()
    return os.getenv(name)


DB_HOST = os.getenv("DB_HOST", "db")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "testdb")
DB_USER = os.getenv("DB_USER", "testuser")
DB_PASSWORD = read_secret("DB_PASSWORD")


@app.route("/health")
def health_check():
    return jsonify({"status": "ok"})


@app.route("/hello")
def hello():
    return jsonify({"message": "Hello world"})


def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=5,
    )


@app.route("/dbtest")
def db_test():
    try:
        with closing(get_db_connection()) as conn, closing(conn.cursor()) as cur:
            cur.execute("SELECT 1")
            result = cur.fetchone()
        if result == (1,):
            return jsonify({"db_connection": "successful"})
    except psycopg2.Error:
        app.logger.exception("Database connection failed")
    return jsonify({"db_connection": "failed"}), 500
