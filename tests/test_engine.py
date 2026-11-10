"""Тесты движка симуляции NetLab UZ.

Запуск: uv run python -m unittest tests.test_engine -v
Не требуют ни сети, ни БД, ни сервера — только netlab.engine.
"""
import unittest

from netlab import engine


def topo(ip1="192.168.1.10", m1="255.255.255.0",
         ip2="192.168.1.20", m2="255.255.255.0", cables=2):
    """Два ПК и коммутатор. cables — сколько ПК подключено (0, 1 или 2).

    Локальная копия схемы, чтобы тест не зависел от netlab.tasks.
    """
    links = [
        {"id": "l1", "a": {"device": "pc1", "port": "eth0"},
                      "b": {"device": "sw1", "port": "fa0/1"}},
        {"id": "l2", "a": {"device": "pc2", "port": "eth0"},
                      "b": {"device": "sw1", "port": "fa0/2"}},
    ][:cables]
    return {
        "devices": [
            {"id": "pc1", "type": "pc", "name": "PC1",
             "x": 160, "y": 300, "ip": ip1, "mask": m1},
            {"id": "sw1", "type": "switch", "name": "SW1",
             "x": 500, "y": 300, "ip": "", "mask": ""},
            {"id": "pc2", "type": "pc", "name": "PC2",
             "x": 840, "y": 300, "ip": ip2, "mask": m2},
        ],
        "links": links,
    }


# ---------------------------------------------------------------- парсеры
class ParseTests(unittest.TestCase):
    def test_ip_ok(self):
        self.assertEqual(engine.parse_ip("192.168.1.10"), 0xC0A8010A)

    def test_ip_bad(self):
        bad_values = ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "01.2.3.4",
                      "a.b.c.d", "1.2.3.-4", " 1.2.3.4x", None, 5]
        for bad in bad_values:
            self.assertIsNone(engine.parse_ip(bad), bad)

    def test_mask(self):
        self.assertEqual(engine.parse_mask("255.255.255.0"), 24)
        self.assertEqual(engine.parse_mask("/25"), 25)
        for bad in ["255.0.255.0", "0.0.0.0", "255.255.255.255",
                    "/0", "/31", "/x", "", None]:
            self.assertIsNone(engine.parse_mask(bad), bad)


# ---------------------------------------------------------------- схема
class ValidateTests(unittest.TestCase):
    def code(self, t):
        with self.assertRaises(engine.TopologyError) as cm:
            engine.validate_topology(t)
        return cm.exception.code

    def test_valid(self):
        self.assertEqual(len(engine.validate_topology(topo())["links"]), 2)

    def test_not_dict(self):
        self.assertEqual(self.code([]), "TOPOLOGY_INVALID")

    def test_duplicate_device(self):
        t = topo()
        t["devices"].append(dict(t["devices"][0]))
        self.assertEqual(self.code(t), "DUPLICATE_ID")

    def test_unknown_device_in_link(self):
        t = topo()
        t["links"][0]["a"]["device"] = "ghost"
        self.assertEqual(self.code(t), "UNKNOWN_DEVICE")

    def test_bad_port(self):
        t = topo()
        t["links"][0]["b"]["port"] = "fa9/9"
        self.assertEqual(self.code(t), "BAD_PORT")

    def test_port_busy(self):
        t = topo()
        t["links"][1]["b"]["port"] = "fa0/1"
        self.assertEqual(self.code(t), "PORT_BUSY")

    def test_self_link(self):
        t = topo()
        t["links"] = [{"id": "x",
                       "a": {"device": "sw1", "port": "fa0/1"},
                       "b": {"device": "sw1", "port": "fa0/2"}}]
        self.assertEqual(self.code(t), "SELF_LINK")

    def test_too_big(self):
        t = {"devices": [{"id": f"d{i}", "type": "pc", "name": "P",
                          "x": 0, "y": 0} for i in range(51)],
             "links": []}
        self.assertEqual(self.code(t), "TOPOLOGY_TOO_BIG")

    def test_bad_type_and_coords(self):
        t = topo()
        t["devices"][0]["type"] = "router"
        self.assertEqual(self.code(t), "BAD_DEVICE")

        t = topo()
        t["devices"][0]["x"] = "10"
        self.assertEqual(self.code(t), "BAD_DEVICE")


# ---------------------------------------------------------------- ping
class PingTests(unittest.TestCase):
    def ping(self, t, a="pc1", b="pc2"):
        return engine.ping(t, a, b)

    def test_success_both_ways(self):
        for a, b in (("pc1", "pc2"), ("pc2", "pc1")):
            r = self.ping(topo(), a, b)
            self.assertTrue(r["success"], r)
            self.assertEqual(r["code"], "OK")
        self.assertEqual(self.ping(topo())["path"], ["pc1", "sw1", "pc2"])

    def test_no_ip_and_bad_ip(self):
        self.assertEqual(self.ping(topo(ip1=""))["code"], "SRC_NO_IP")
        self.assertEqual(self.ping(topo(ip1="300.1.1.1"))["code"], "SRC_BAD_IP")
        self.assertEqual(self.ping(topo(ip2=""))["code"], "DST_NO_IP")

    def test_mask_problems(self):
        self.assertEqual(self.ping(topo(m1=""))["code"], "SRC_NO_MASK")
        self.assertEqual(self.ping(topo(m1="255.0.255.0"))["code"], "SRC_BAD_MASK")

    def test_network_and_broadcast_address(self):
        self.assertEqual(self.ping(topo(ip1="192.168.1.0"))["code"],
                         "SRC_ADDR_IS_NETWORK")
        self.assertEqual(self.ping(topo(ip2="192.168.1.255"))["code"],
                         "DST_ADDR_IS_BROADCAST")

    def test_conflict(self):
        self.assertEqual(self.ping(topo(ip2="192.168.1.10"))["code"],
                         "IP_CONFLICT")

    def test_different_subnet(self):
        r = self.ping(topo(ip2="192.168.2.10"))
        self.assertEqual(r["code"], "DIFFERENT_SUBNET")

    def test_no_cable(self):
        self.assertEqual(self.ping(topo(cables=1))["code"], "NO_PATH")
        self.assertEqual(self.ping(topo(cables=0))["code"], "NO_PATH")

    def test_asymmetric_mask(self):
        # pc2 /25: запрос доходит, но ответ pc2 считает pc1 «чужим»
        t = topo(ip2="192.168.1.200", m2="255.255.255.128")
        self.assertEqual(self.ping(t, "pc1", "pc2")["code"],
                         "REPLY_DIFFERENT_SUBNET")
        self.assertEqual(self.ping(t, "pc2", "pc1")["code"],
                         "DIFFERENT_SUBNET")

    def test_unconnected_pc_unreachable(self):
        t = topo()
        t["devices"].append(
            {"id": "pc3", "type": "pc", "name": "PC3",
             "x": 0, "y": 0, "ip": "192.168.1.30", "mask": "255.255.255.0"})
        t["links"] = [{"id": "a",
                       "a": {"device": "pc1", "port": "eth0"},
                       "b": {"device": "pc3", "port": "eth0"}}]
        # pc1—pc3 соединены, pc2 ни с кем: до pc2 пути нет
        self.assertEqual(self.ping(t)["code"], "NO_PATH")
        self.assertTrue(self.ping(t, "pc1", "pc3")["success"])

    def test_direct_pc_to_pc(self):
        t = topo()
        t["links"] = [{"id": "d",
                       "a": {"device": "pc1", "port": "eth0"},
                       "b": {"device": "pc2", "port": "eth0"}}]
        self.assertTrue(self.ping(t)["success"])

    def test_bad_targets(self):
        self.assertEqual(engine.ping(topo(), "pc1", "zzz")["code"],
                         "TARGET_NOT_FOUND")
        self.assertEqual(engine.ping(topo(), "pc1", "sw1")["code"],
                         "NOT_A_HOST")
        self.assertEqual(engine.ping(topo(), "pc1", "pc1")["code"],
                         "SAME_DEVICE")

    def test_steps_stop_at_failure(self):
        r = self.ping(topo(cables=1))
        self.assertEqual(r["steps"][-1], {"id": "link_path", "ok": False})


if __name__ == "__main__":
    unittest.main()