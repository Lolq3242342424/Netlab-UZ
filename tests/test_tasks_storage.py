"""Тесты заданий и хранилища NetLab UZ.

Запуск: uv run python -m unittest tests.test_tasks_storage -v
Не требует ни сети, ни сервера. Использует только временную директорию.
"""
import os
import tempfile
import unittest

from netlab import engine, tasks
from netlab.storage import ProjectError, ProjectStore


# ---------------------------------------------------------------- решения
def solved(task_id):
    """Эталонное решение каждого задания — правит схему так, как должен ученик.

    Для connect_two_pcs добавляются и кабели, и IP (стартовая — пустые).
    Для no_cable — только второй кабель (IP уже настроены).
    Для fix_mask / fix_conflict / fix_subnet IP запрещено менять
    только там, где это явно указано в TASKS (ключ keep_ips).
    """
    t = tasks.get_task_topology(task_id)
    devs = {d["id"]: d for d in t["devices"]}

    if task_id in ("connect_two_pcs", "no_cable"):
        t["links"] = [
            {"id": "l1", "a": {"device": "pc1", "port": "eth0"},
                          "b": {"device": "sw1", "port": "fa0/1"}},
            {"id": "l2", "a": {"device": "pc2", "port": "eth0"},
                          "b": {"device": "sw1", "port": "fa0/2"}},
        ]
    if task_id == "connect_two_pcs":
        devs["pc1"].update(ip="10.0.0.1", mask="255.255.255.0")
        devs["pc2"].update(ip="10.0.0.2", mask="255.255.255.0")
    if task_id == "fix_mask":
        devs["pc2"]["mask"] = "255.255.255.0"
    if task_id == "fix_conflict":
        devs["pc2"]["ip"] = "192.168.1.20"
    if task_id == "fix_subnet":
        devs["pc2"]["ip"] = "192.168.1.20"
    return t


# ---------------------------------------------------------------- задания
class TaskTests(unittest.TestCase):
    def test_all_tasks_start_unsolved(self):
        for tid in tasks.list_tasks():
            res = tasks.check_task(tid, tasks.get_task_topology(tid))
            self.assertFalse(res["passed"], tid)

    def test_all_tasks_solvable(self):
        for tid in tasks.list_tasks():
            res = tasks.check_task(tid, solved(tid))
            self.assertTrue(res["passed"], (tid, res))

    def test_unknown_task(self):
        self.assertIsNone(tasks.check_task("nope", {"devices": [], "links": []}))
        self.assertIsNone(tasks.get_task_topology("nope"))

    def test_missing_devices(self):
        res = tasks.check_task("fix_mask", {"devices": [], "links": []})
        self.assertFalse(res["passed"])
        self.assertEqual(res["checks"][0]["id"], "devices_present")
        self.assertFalse(res["checks"][0]["ok"])

    def test_cheating_by_changing_ip_fails(self):
        # fix_subnet: менять pc1 нельзя, ping должен работать через pc2.ip
        t = tasks.get_task_topology("fix_subnet")
        for d in t["devices"]:
            if d["id"] == "pc1":
                d["ip"] = "192.168.2.99"  # ping заработает, но ips_kept упадёт
        res = tasks.check_task("fix_subnet", t)
        self.assertFalse(res["passed"])
        ips_kept = next(c for c in res["checks"] if c["id"] == "ips_kept")
        self.assertFalse(ips_kept["ok"])


# ---------------------------------------------------------------- хранилище
class StorageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "test.db")
        self.store = ProjectStore(self.path)

    def tearDown(self):
        self.tmp.cleanup()

    def test_crud(self):
        t = tasks.get_task_topology("fix_mask")
        p = self.store.create("  Мой проект ", t)
        self.assertEqual(p["name"], "Мой проект")  # strip + unicode
        self.assertEqual(self.store.get(p["id"])["topology"], t)
        self.assertEqual(len(self.store.list()), 1)

        self.store.update(p["id"], "Новое имя", t)
        self.assertEqual(self.store.get(p["id"])["name"], "Новое имя")

        self.store.delete(p["id"])
        with self.assertRaises(ProjectError) as cm:
            self.store.get(p["id"])
        self.assertEqual(cm.exception.code, "NOT_FOUND")

    def test_rejects_bad_input(self):
        t = tasks.get_task_topology("fix_mask")
        for name in ("", "   ", "x" * 61, None, 5):
            with self.assertRaises(ProjectError) as cm:
                self.store.create(name, t)
            self.assertEqual(cm.exception.code, "INVALID_NAME")

        with self.assertRaises(engine.TopologyError):
            self.store.create("ok", {"devices": "x", "links": []})

        self.assertEqual(self.store.list(), [])

    def test_missing_ids(self):
        t = tasks.get_task_topology("fix_mask")
        with self.assertRaises(ProjectError):
            self.store.update(999, "a", t)
        with self.assertRaises(ProjectError):
            self.store.delete(999)
        with self.assertRaises(ProjectError):
            self.store.get(999)

    def test_sql_injection_text_is_just_text(self):
        t = tasks.get_task_topology("fix_mask")
        malicious = "x'; DROP TABLE projects;--"
        p = self.store.create(malicious, t)
        self.assertEqual(self.store.get(p["id"])["name"], malicious)
        self.assertEqual(len(self.store.list()), 1)  # таблица на месте

    def test_max_projects(self):
        # Временно уменьшаем лимит, чтобы не создавать 200 записей.
        from netlab import storage as storage_mod
        old = storage_mod.MAX_PROJECTS
        storage_mod.MAX_PROJECTS = 2
        try:
            t = tasks.get_task_topology("fix_mask")
            self.store.create("A", t)
            self.store.create("B", t)
            with self.assertRaises(ProjectError) as cm:
                self.store.create("C", t)
            self.assertEqual(cm.exception.code, "TOO_MANY_PROJECTS")
        finally:
            storage_mod.MAX_PROJECTS = old


if __name__ == "__main__":
    unittest.main()