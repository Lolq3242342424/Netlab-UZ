"""Хранилище проектов на SQLite (стандартная библиотека, без зависимостей).

Все SQL-запросы параметризованы. Схема проходит engine.validate_topology
до записи, поэтому в базу попадают только проверенные данные.
Пользователей в этом этапе нет: хранилище локальное, однопользовательское.
"""
import json  # схема хранится как JSON-текст
import sqlite3  # встроенная база данных
import time  # метки времени
from contextlib import closing  # гарантированное закрытие соединения

from . import engine

MAX_PROJECT_NAME = 60  # максимальная длина названия проекта
MAX_PROJECTS = 200  # лимит проектов на одну базу


class ProjectError(ValueError):
    """Ошибка работы с проектом (code — машинный код для интерфейса)."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


class ProjectStore:
    def __init__(self, db_path):
        self.db_path = db_path  # путь к файлу базы
        with closing(self._connect()) as db, db:
            db.execute("""CREATE TABLE IF NOT EXISTS projects (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                topology TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL)""")

    def _connect(self):
        db = sqlite3.connect(self.db_path, timeout=5)  # новое соединение на запрос
        db.row_factory = sqlite3.Row  # доступ к полям по имени
        return db

    @staticmethod
    def _clean_name(name):
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= MAX_PROJECT_NAME:
            raise ProjectError("INVALID_NAME")
        return name.strip()

    @staticmethod
    def _row(row, with_topology=False):
        item = {"id": row["id"], "name": row["name"],
                "created_at": row["created_at"], "updated_at": row["updated_at"]}
        if with_topology:
            item["topology"] = json.loads(row["topology"])
        return item

    def list(self):
        with closing(self._connect()) as db:
            rows = db.execute("SELECT * FROM projects ORDER BY updated_at DESC").fetchall()
        return [self._row(r) for r in rows]

    def get(self, project_id):
        with closing(self._connect()) as db:
            row = db.execute("SELECT * FROM projects WHERE id = ?", (project_id,)).fetchone()
        if row is None:
            raise ProjectError("NOT_FOUND")
        return self._row(row, with_topology=True)

    def create(self, name, topology):
        name = self._clean_name(name)
        topo = engine.validate_topology(topology)  # TopologyError, если схема плохая
        now = time.time()
        with closing(self._connect()) as db, db:
            count = db.execute("SELECT COUNT(*) FROM projects").fetchone()[0]
            if count >= MAX_PROJECTS:
                raise ProjectError("TOO_MANY_PROJECTS")
            cur = db.execute(
                "INSERT INTO projects (name, topology, created_at, updated_at) VALUES (?, ?, ?, ?)",
                (name, json.dumps(topo, ensure_ascii=False), now, now))
            new_id = cur.lastrowid
        return self.get(new_id)

    def update(self, project_id, name, topology):
        name = self._clean_name(name)
        topo = engine.validate_topology(topology)
        with closing(self._connect()) as db, db:
            cur = db.execute(
                "UPDATE projects SET name = ?, topology = ?, updated_at = ? WHERE id = ?",
                (name, json.dumps(topo, ensure_ascii=False), time.time(), project_id))
            if cur.rowcount == 0:
                raise ProjectError("NOT_FOUND")
        return self.get(project_id)

    def delete(self, project_id):
        with closing(self._connect()) as db, db:
            cur = db.execute("DELETE FROM projects WHERE id = ?", (project_id,))
            if cur.rowcount == 0:
                raise ProjectError("NOT_FOUND")
