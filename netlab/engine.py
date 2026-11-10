"""Движок симуляции NetLab UZ: валидация схемы и ping.

Упрощённая учебная модель, не эмулятор реальной ОС:
  * IPv4, Ethernet-подобные кабели.
  * Типы устройств: PC и коммутатор (L2). Маршрутизатор не реализован.
  * ARP, DHCP, DNS, VLAN, ACL не моделируются.
  * Пакет идёт только внутри одной подсети.
  * PC не пересылает чужой трафик (не транзитное устройство).
  * Реальные сетевые пакеты не отправляются.
  * Результат детерминирован для одинаковой топологии и конфигурации.
"""

MAX_DEVICES = 50
MAX_LINKS = 200
PC_PORTS = ("eth0",)
SWITCH_PORTS = tuple(f"fa0/{i}" for i in range(1, 9))


class TopologyError(ValueError):
    """Схема не проходит проверку. code — машинный код для i18n."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


# ---------------------------------------------------------------- IPv4
def parse_ip(text):
    """Возвращает int-IPv4 или None. Ведущие нули и не-цифры запрещены."""
    if not isinstance(text, str):
        return None
    parts = text.split(".")
    if len(parts) != 4:
        return None
    value = 0
    for p in parts:
        if not p or len(p) > 3 or not p.isdigit():
            return None
        if len(p) > 1 and p[0] == "0":
            return None
        n = int(p)
        if n > 255:
            return None
        value = (value << 8) | n
    return value


def parse_mask(text):
    """Длина префикса 1..30 или None для /0, /31, /32 и битых масок."""
    if not isinstance(text, str):
        return None
    s = text.strip()
    if s.startswith("/"):
        if not s[1:].isdigit():
            return None
        prefix = int(s[1:])
        return prefix if 1 <= prefix <= 30 else None
    ip = parse_ip(s)
    if ip is None:
        return None
    bits = 0
    seen_zero = False
    for shift in range(31, -1, -1):
        bit = (ip >> shift) & 1
        if bit:
            if seen_zero:
                return None
            bits += 1
        else:
            seen_zero = True
    return bits if 1 <= bits <= 30 else None


def _fmt_ip(value):
    return ".".join(str((value >> s) & 0xFF) for s in (24, 16, 8, 0))


def _network(ip, prefix):
    mask = ((1 << prefix) - 1) << (32 - prefix) if prefix > 0 else 0
    return ip & mask


def _broadcast(ip, prefix):
    host = 32 - prefix
    host_mask = (1 << host) - 1 if host > 0 else 0
    return _network(ip, prefix) | host_mask


# ---------------------------------------------------------------- схема
def validate_topology(raw):
    if not isinstance(raw, dict):
        raise TopologyError("TOPOLOGY_INVALID")
    raw_devices = raw.get("devices")
    raw_links = raw.get("links")
    if not isinstance(raw_devices, list) or not isinstance(raw_links, list):
        raise TopologyError("TOPOLOGY_INVALID")
    if len(raw_devices) > MAX_DEVICES or len(raw_links) > MAX_LINKS:
        raise TopologyError("TOPOLOGY_TOO_BIG")

    devices = []
    by_id = {}
    for d in raw_devices:
        if not isinstance(d, dict):
            raise TopologyError("BAD_DEVICE")
        did = d.get("id")
        if not isinstance(did, str) or not did or len(did) > 40:
            raise TopologyError("BAD_DEVICE")
        if did in by_id:
            raise TopologyError("DUPLICATE_ID")
        dtype = d.get("type")
        if dtype not in ("pc", "switch"):
            raise TopologyError("BAD_DEVICE")
        name = d.get("name")
        if not isinstance(name, str) or not name or len(name) > 40:
            raise TopologyError("BAD_DEVICE")
        x = d.get("x")
        y = d.get("y")
        if (not isinstance(x, (int, float)) or isinstance(x, bool) or
                not isinstance(y, (int, float)) or isinstance(y, bool)):
            raise TopologyError("BAD_DEVICE")
        if not (0 <= x <= 2000 and 0 <= y <= 2000):
            raise TopologyError("BAD_DEVICE")
        ip = d.get("ip", "")
        mask = d.get("mask", "")
        if not isinstance(ip, str) or len(ip) > 20:
            raise TopologyError("BAD_DEVICE")
        if not isinstance(mask, str) or len(mask) > 20:
            raise TopologyError("BAD_DEVICE")
        dev = {"id": did, "type": dtype, "name": name,
               "x": x, "y": y, "ip": ip, "mask": mask}
        devices.append(dev)
        by_id[did] = dev

    used_ports = set()
    seen_links = set()
    links = []
    for ln in raw_links:
        if not isinstance(ln, dict):
            raise TopologyError("BAD_LINK")
        lid = ln.get("id")
        if not isinstance(lid, str) or not lid or len(lid) > 40:
            raise TopologyError("BAD_LINK")
        if lid in seen_links:
            raise TopologyError("BAD_LINK")
        seen_links.add(lid)
        a = ln.get("a")
        b = ln.get("b")
        if not isinstance(a, dict) or not isinstance(b, dict):
            raise TopologyError("BAD_LINK")
        da, pa = a.get("device"), a.get("port")
        db, pb = b.get("device"), b.get("port")
        for did, port in ((da, pa), (db, pb)):
            if not isinstance(did, str) or did not in by_id:
                raise TopologyError("UNKNOWN_DEVICE")
            if not isinstance(port, str):
                raise TopologyError("BAD_PORT")
            allowed = PC_PORTS if by_id[did]["type"] == "pc" else SWITCH_PORTS
            if port not in allowed:
                raise TopologyError("BAD_PORT")
            if (did, port) in used_ports:
                raise TopologyError("PORT_BUSY")
            used_ports.add((did, port))
        if da == db:
            raise TopologyError("SELF_LINK")
        links.append({"id": lid,
                      "a": {"device": da, "port": pa},
                      "b": {"device": db, "port": pb}})

    return {"devices": devices, "links": links}


# ---------------------------------------------------------------- ping
def _bfs_path(topo, source_id, target_id):
    """Кратчайший путь по кабелям. PC — не транзитное устройство."""
    by_id = {d["id"]: d for d in topo["devices"]}
    adj = {}
    for ln in topo["links"]:
        a = ln["a"]["device"]
        b = ln["b"]["device"]
        adj.setdefault(a, []).append(b)
        adj.setdefault(b, []).append(a)
    if source_id not in adj:
        return None
    queue = [(source_id, [source_id])]
    visited = {source_id}
    while queue:
        node, path = queue.pop(0)
        if node == target_id:
            return path
        if node != source_id and by_id[node]["type"] == "pc":
            continue
        for nxt in adj.get(node, []):
            if nxt in visited:
                continue
            visited.add(nxt)
            queue.append((nxt, path + [nxt]))
    return None


def _path_names(topo, ids):
    by_id = {d["id"]: d for d in topo["devices"]}
    return " → ".join(by_id[i]["name"] for i in ids)


def ping(raw_topology, source_id, target_id):
    """Симуляция ping. Возвращает success, code, params, steps, path.

    steps останавливаются ровно на первом проваленном шаге.
    """
    topo = validate_topology(raw_topology)
    devs = {d["id"]: d for d in topo["devices"]}
    steps = []

    def ok(step_id):
        steps.append({"id": step_id, "ok": True})

    def fail(step_id, code, params=None):
        steps.append({"id": step_id, "ok": False})
        return {"success": False, "code": code,
                "params": params or {}, "steps": steps, "path": []}

    if not isinstance(source_id, str) or source_id not in devs:
        return {"success": False, "code": "SOURCE_NOT_FOUND",
                "params": {}, "steps": [], "path": []}
    if not isinstance(target_id, str) or target_id not in devs:
        return {"success": False, "code": "TARGET_NOT_FOUND",
                "params": {}, "steps": [], "path": []}
    src, dst = devs[source_id], devs[target_id]
    if src["type"] != "pc" or dst["type"] != "pc":
        return {"success": False, "code": "NOT_A_HOST",
                "params": {}, "steps": [], "path": []}
    if source_id == target_id:
        return {"success": False, "code": "SAME_DEVICE",
                "params": {"device": src["name"]}, "steps": [], "path": []}

    s_ip = parse_ip(src["ip"])
    if not src["ip"].strip():
        return fail("source_config", "SRC_NO_IP", {"device": src["name"]})
    if s_ip is None:
        return fail("source_config", "SRC_BAD_IP",
                    {"device": src["name"], "ip": src["ip"]})
    if not src["mask"].strip():
        return fail("source_config", "SRC_NO_MASK", {"device": src["name"]})
    s_prefix = parse_mask(src["mask"])
    if s_prefix is None:
        return fail("source_config", "SRC_BAD_MASK",
                    {"device": src["name"], "mask": src["mask"]})
    s_net = _network(s_ip, s_prefix)
    if s_ip == s_net:
        return fail("source_config", "SRC_ADDR_IS_NETWORK",
                    {"device": src["name"], "ip": src["ip"]})
    if s_ip == _broadcast(s_ip, s_prefix):
        return fail("source_config", "SRC_ADDR_IS_BROADCAST",
                    {"device": src["name"], "ip": src["ip"]})
    ok("source_config")

    d_ip = parse_ip(dst["ip"])
    if not dst["ip"].strip():
        return fail("target_config", "DST_NO_IP", {"device": dst["name"]})
    if d_ip is None:
        return fail("target_config", "DST_BAD_IP",
                    {"device": dst["name"], "ip": dst["ip"]})
    if not dst["mask"].strip():
        return fail("target_config", "DST_NO_MASK", {"device": dst["name"]})
    d_prefix = parse_mask(dst["mask"])
    if d_prefix is None:
        return fail("target_config", "DST_BAD_MASK",
                    {"device": dst["name"], "mask": dst["mask"]})
    d_net = _network(d_ip, d_prefix)
    if d_ip == d_net:
        return fail("target_config", "DST_ADDR_IS_NETWORK",
                    {"device": dst["name"], "ip": dst["ip"]})
    if d_ip == _broadcast(d_ip, d_prefix):
        return fail("target_config", "DST_ADDR_IS_BROADCAST",
                    {"device": dst["name"], "ip": dst["ip"]})
    ok("target_config")

    if s_ip == d_ip:
        return fail("ip_unique", "IP_CONFLICT",
                    {"source": src["name"], "target": dst["name"],
                     "ip": dst["ip"]})
    ok("ip_unique")

    if _network(d_ip, s_prefix) != s_net:
        return fail("same_subnet", "DIFFERENT_SUBNET", {
            "target": dst["name"], "target_ip": dst["ip"],
            "source_net": f"{_fmt_ip(s_net)}/{s_prefix}",
        })
    ok("same_subnet")

    path = _bfs_path(topo, source_id, target_id)
    if path is None:
        return fail("link_path", "NO_PATH",
                    {"source": src["name"], "target": dst["name"]})
    ok("link_path")

    if _network(s_ip, d_prefix) != d_net:
        return fail("reply", "REPLY_DIFFERENT_SUBNET", {
            "target": dst["name"], "target_ip": dst["ip"],
            "source_ip": src["ip"],
            "target_net": f"{_fmt_ip(d_net)}/{d_prefix}",
        })
    ok("reply")

    return {
        "success": True, "code": "OK",
        "params": {"source": src["name"], "target": dst["name"],
                   "path": _path_names(topo, path)},
        "steps": steps,
        "path": path,
    }