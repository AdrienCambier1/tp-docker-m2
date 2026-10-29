from unittest.mock import Mock

import psycopg2
import pytest
from app import app


@pytest.fixture
def client_app():
    with app.test_client() as client:
        with app.app_context():
            yield client


def test_health(client_app):
    res = client_app.get("/health")
    assert res.status_code == 200


def test_hello(client_app):
    res = client_app.get("/hello")
    assert res.status_code == 200


@pytest.mark.integration
def test_dbtest(client_app):
    res = client_app.get("/dbtest")
    assert res.status_code == 200
    json_data = res.get_json()
    assert json_data.get("db_connection") == "successful"


@pytest.mark.parametrize("query_fails", [False, True])
def test_dbtest_closes_resources(client_app, monkeypatch, query_fails):
    conn = Mock()
    cur = conn.cursor.return_value
    cur.fetchone.return_value = (1,)
    if query_fails:
        cur.execute.side_effect = psycopg2.DatabaseError("private connection details")
    monkeypatch.setattr("app.get_db_connection", lambda: conn)

    res = client_app.get("/dbtest")

    assert res.status_code == (500 if query_fails else 200)
    assert res.get_json() == {
        "db_connection": "failed" if query_fails else "successful"
    }
    cur.close.assert_called_once()
    conn.close.assert_called_once()
