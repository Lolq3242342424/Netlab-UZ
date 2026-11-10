"""Учебные задания: стартовые схемы и автоматическая проверка.

Задание проверяется ДВИЖКОМ (ping в обе стороны), а не сравнением с «эталонной»
схемой, поэтому любое корректное решение засчитывается. Тексты заданий и
объяснений лежат в static/i18n/*.json, здесь только коды.
"""
from . import engine


def _pc(dev_id, name, x, y, ip="", mask=""):
    return {"id": dev_id, "type": "pc", "name": name, "x": x, "y": y, "ip": ip, "mask": mask}


def _sw(dev_id, name, x, y):
    return {"id": dev_id, "type": "switch", "name": name, "x": x, "y": y, "ip": "", "mask": ""}


def _link(link_id, dev_a, port_a, dev_b, port_b):
    return {"id": link_id, "a": {"device": dev_a, "port": port_a},
            "b": {"device": dev_b, "port": port_b}}


def _base(ip1="", mask1="", ip2="", mask2="", cables=2):
    """Два ПК и коммутатор; cables = сколько ПК подключено к коммутатору."""
    links = [_link("l1", "pc1", "eth0", "sw1", "fa0/1"),
             _link("l2", "pc2", "eth0", "sw1", "fa0/2")][:cables]
    return {"devices": [_pc("pc1", "PC1", 160, 300, ip1, mask1),
                        _sw("sw1", "SW1", 500, 300),
                        _pc("pc2", "PC2", 840, 300, ip2, mask2)],
            "links": links}


# checks: devices_present всегда первая; далее — особые проверки; ping в обе стороны — всегда.
TASKS = {
    "connect_two_pcs": {
        "topology": _base(cables=0),
        "checks": ["cables_to_switch"],
    },
    "no_cable": {
        "topology": _base("192.168.1.10", "255.255.255.0", "192.168.1.20", "255.255.255.0", cables=1),
        "checks": ["cables_to_switch"],
    },
    "fix_mask": {
        "topology": _base("192.168.1.10", "255.255.255.0", "192.168.1.200", "255.255.255.128"),
        "checks": ["ips_kept"],
        "keep_ips": {"pc1": "192.168.1.10", "pc2": "192.168.1.200"},
    },
    "fix_conflict": {
        "topology": _base("192.168.1.10", "255.255.255.0", "192.168.1.10", "255.255.255.0"),
        "checks": ["unique_ips"],
    },
    "fix_subnet": {
        "topology": _base("192.168.1.10", "255.255.255.0", "192.168.2.10", "255.255.255.0"),
        "checks": ["ips_kept"],
        "keep_ips": {"pc1": "192.168.1.10"},
    },
}
TASK_ORDER = ["connect_two_pcs", "no_cable", "fix_mask", "fix_conflict", "fix_subnet"]


def list_tasks():
    """Список id заданий в учебном порядке."""
    return list(TASK_ORDER)


def get_task_topology(task_id):
    """Стартовая схема задания (копия) или None."""
    task = TASKS.get(task_id)
    if task is None:
        return None
    return engine.validate_topology(task["topology"])


def check_task(task_id, raw_topology):
    """Проверяет решение. Возвращает {passed, checks:[{id, ok, code?, params?}]}.

    Если задания нет — None. Если схема некорректна — TopologyError.
    """
    task = TASKS.get(task_id)
    if task is None:
        return None
    topo = engine.validate_topology(raw_topology)
    devs = {d["id"]: d for d in topo["devices"]}
    checks = []

    # 0. нужные устройства на месте (проверка всегда идёт по pc1, pc2 и sw1)
    missing = [i for i in ("pc1", "pc2", "sw1") if i not in devs]
    if missing:
        return {"passed": False, "checks": [
            {"id": "devices_present", "ok": False, "params": {"missing": ", ".join(missing)}}]}
    checks.append({"id": "devices_present", "ok": True})

    for name in task["checks"]:
        if name == "cables_to_switch":  # оба ПК подключены прямо к коммутатору
            linked = set()
            for ln in topo["links"]:
                ends = {ln["a"]["device"], ln["b"]["device"]}
                if "sw1" in ends:
                    linked |= ends - {"sw1"}
            bad = [devs[i]["name"] for i in ("pc1", "pc2") if i not in linked]
            checks.append({"id": name, "ok": not bad, "params": {"devices": ", ".join(bad)}})
        elif name == "ips_kept":  # IP-адреса менять нельзя (решение — в другом месте)
            changed = [devs[i]["name"] for i, ip in task["keep_ips"].items()
                       if devs[i]["ip"].strip() != ip]
            checks.append({"id": name, "ok": not changed,
                           "params": {"devices": ", ".join(changed)}})
        elif name == "unique_ips":  # у разных ПК разные адреса
            ips = [engine.parse_ip(d["ip"]) for d in topo["devices"] if d["type"] == "pc"]
            ips = [i for i in ips if i is not None]
            checks.append({"id": name, "ok": len(ips) == len(set(ips))})

    for check_id, (a, b) in (("ping_forward", ("pc1", "pc2")), ("ping_backward", ("pc2", "pc1"))):
        res = engine.ping(topo, a, b)
        checks.append({"id": check_id, "ok": res["success"], "code": res["code"],
                       "params": res["params"]})
    return {"passed": all(c["ok"] for c in checks), "checks": checks}
