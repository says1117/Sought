#!/usr/bin/env python3
"""Motion self-test report: reads the JSONL written by the app's SelfTest screen, recomputes the metrics from the raw
pose / command / status records, and prints a pass/fail table against tools/motion_thresholds.json.

The thresholds file is a PLACEHOLDER ("to be calibrated by Steven, not measured"). This script never invents numbers:
a check with no data in the log is reported as NO DATA, never as a pass.

Usage:  python3 tools/motion_report.py LOG.jsonl [--thresholds tools/motion_thresholds.json] [--summary OUT.json]
Exit code: 0 all checks pass, 1 at least one fail / no data / abort, 2 unreadable input.
Metric definitions: docs/field-test-checklist.md. Standard library only.
"""
import argparse
import json
import math
import sys
from pathlib import Path

DEFAULT_THRESHOLDS = Path(__file__).with_name("motion_thresholds.json")
EPS = 1e-6  # phase windows are half-open: a status at the boundary belongs to the next phase
STEPS = ["wheels_off", "watchdog", "forward_back", "square", "spin", "obstacle"]


# ---------- helpers ----------
def forward_unit(yaw_deg):
    """Yaw 0 faces -z, +90 faces -x (CCW positive from above), docs/03_CONTRACTS.md section 0."""
    r = math.radians(yaw_deg)
    return (-math.sin(r), -math.cos(r))


def shortest_delta(a, b):
    d = (b - a) % 360.0
    return d - 360.0 if d > 180.0 else d


def along(p0, u, p):
    return (p["x"] - p0["x"]) * u[0] + (p["z"] - p0["z"]) * u[1]


def lateral(p0, u, p):
    return (p["x"] - p0["x"]) * u[1] - (p["z"] - p0["z"]) * u[0]


def dist(a, b):
    return math.hypot(a["x"] - b["x"], a["z"] - b["z"])


def mean(v):
    return sum(v) / len(v) if v else None


def load(path):
    """Returns (records, bad_line_count). Bad lines are counted, never silently dropped."""
    records, bad = [], 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
                if isinstance(r, dict) and "type" in r and isinstance(r.get("t", 0), (int, float)):
                    records.append(r)
                else:
                    bad += 1
            except json.JSONDecodeError:
                bad += 1
    return records, bad


class Log:
    def __init__(self, records):
        self.meta = next((r for r in records if r["type"] == "meta"), {})
        self.events = [r for r in records if r["type"] == "event"]
        self.status = [r for r in records if r["type"] == "status"]
        self.pose = [r for r in records if r["type"] == "pose" and "x" in r and "z" in r and "yaw_deg" in r]
        self.cmd = [r for r in records if r["type"] == "cmd"]

    def ev(self, name, step=None):
        return [e for e in self.events if e.get("name") == name and (step is None or e.get("step") == step)]

    def first(self, name, step=None):
        e = self.ev(name, step)
        return e[0] if e else None

    def status_in(self, t0, t1):
        return [s for s in self.status if t0 <= s["t"] <= t1]

    def pose_in(self, t0, t1):
        return [p for p in self.pose if t0 <= p["t"] <= t1]

    def step_end(self, step):
        return self.first("step_end", step)

    def bounds(self, step):
        ts = [e["t"] for e in self.events if e.get("step") == step and e.get("name") != "step_end"]
        end = self.step_end(step)
        if not ts or not end:
            return None
        return min(ts), end["t"]


class Checks:
    """Collects checks for one step. status: pass | fail | no_data."""

    def __init__(self):
        self.items, self.metrics = [], {}

    def add(self, name, value, op, limit, unit=""):
        if value is None or (isinstance(value, float) and not math.isfinite(value)):
            status = "no_data"
        else:
            ok = {"<=": value <= limit, ">=": value >= limit, "==": value == limit}[op]
            status = "pass" if ok else "fail"
        self.items.append({"name": name, "value": value, "op": op, "limit": limit, "unit": unit, "status": status})
        if value is not None:
            self.metrics[name] = value

    def overall(self):
        s = {i["status"] for i in self.items}
        if "fail" in s:
            return "fail"
        if "no_data" in s or not s:
            return "no_data"
        return "pass"


# ---------- per-step analysis ----------
def analyze_wheels_off(log, th):
    c = Checks()
    b = log.bounds("wheels_off")
    if not b:
        return c
    worst = None
    starts = log.ev("phase_start", "wheels_off")
    for phase in ("forward", "back", "spin_left", "spin_right"):
        matches = [event for event in starts if event.get("phase") == phase]
        if len(matches) != 1:
            c.add(f"{phase} phase records", None, "==", 1)
    for ps in starts:
        pe = next((e for e in log.ev("phase_end", "wheels_off") if e.get("phase") == ps.get("phase") and e["t"] >= ps["t"]), None)
        if not pe:
            c.add(f"{ps.get('phase')} phase end", None, "==", 1)
            continue
        win = log.status_in(ps["t"] + th["wheel_settle_s"], pe["t"] + 0.05)
        name = ps["phase"]
        if len(win) < 2:
            c.add(f"{name} applied vs commanded (max abs error)", None, "<=", th["wheel_tolerance_units"], "units")
            continue
        err = max(abs(mean([s["left"] for s in win]) - ps["left"]), abs(mean([s["right"] for s in win]) - ps["right"]))
        c.add(f"{name} applied vs commanded (max abs error)", round(err, 2), "<=", th["wheel_tolerance_units"], "units")
        if any(s["flags"] & 1 for s in win):
            c.add(f"{name} watchdog flag while commands flowing", 1, "==", 0)
        worst = err if worst is None else max(worst, err)
    times = [s["t"] for s in log.status_in(*b)]
    hz = (len(times) - 1) / (times[-1] - times[0]) if len(times) >= 2 and times[-1] > times[0] else None
    c.add("status rate", None if hz is None else round(hz, 2), ">=", th["min_status_hz"], "Hz")
    missing = sum(1 for s in log.status_in(*b) if not s["flags"] & 8) if times else None
    c.add("status lines without BLE-connected flag", missing, "==", 0)
    return c


def analyze_watchdog(log, th):
    c = Checks()
    sus, res = log.first("watchdog_suspend", "watchdog"), log.first("watchdog_resume", "watchdog")
    if not sus:
        return c
    end = log.step_end("watchdog")
    silent_end = (res or end or {}).get("t", sus["t"])
    after = [s for s in log.status if sus["t"] <= s["t"] < silent_end]
    stop = next((s for s in after if s["left"] == 0 and s["right"] == 0), None)
    flag = next((s for s in after if s["flags"] & 1), None)
    c.add("motors read 0 after commands stop", None if not stop else round(stop["t"] - sus["t"], 3), "<=", th["watchdog_stop_limit_s"], "s")
    c.add("watchdog flag (1) set", None if not after else (1 if flag else 0), "==", 1)
    if res:
        back = next((s for s in log.status if res["t"] <= s["t"] <= (end or {}).get("t", res["t"])
                     and (s["left"] or s["right"]) and not s["flags"] & 1), None)
        c.add("motors resume after next command", None if not back else round(back["t"] - res["t"], 3), "<=", th["watchdog_resume_limit_s"], "s")
    else:
        c.add("motors resume after next command", None, "<=", th["watchdog_resume_limit_s"], "s")
    return c


def analyze_forward_back(log, th):
    c = Checks()
    s0, s1, s2 = log.first("leg_start", "forward_back"), log.first("fwd_end", "forward_back"), log.first("back_end", "forward_back")
    if not s0:
        return c
    u = forward_unit(s0["yaw_deg"])
    if s1:
        d = along(s0, u, s1)
        c.add("distance error (forward leg)", round(abs(d - th["forward_target_m"]), 4), "<=", th["forward_distance_error_m"], "m")
        c.metrics["forward_distance_m"] = round(d, 4)
    else:
        c.add("distance error (forward leg)", None, "<=", th["forward_distance_error_m"], "m")
    end_t = (s2 or s1 or {}).get("t")
    if end_t is not None:
        lat = [abs(lateral(s0, u, p)) for p in log.pose_in(s0["t"], end_t)]
        c.add("max lateral drift", round(max(lat), 4) if lat else None, "<=", th["forward_lateral_drift_m"], "m")
    else:
        c.add("max lateral drift", None, "<=", th["forward_lateral_drift_m"], "m")
    c.add("return error (ARKit pose)", round(dist(s2, s0), 4) if s2 else None, "<=", th["forward_return_error_m"], "m")
    if s2:
        c.metrics["return_yaw_error_deg"] = round(abs(shortest_delta(s0["yaw_deg"], s2["yaw_deg"])), 3)
    return c


def analyze_square(log, th):
    c = Checks()
    s0 = next((e for e in log.ev("leg_start", "square") if e.get("leg") == 0), None)
    ends = [e for e in log.ev("turn_end", "square")]
    last = next((e for e in ends if e.get("leg") == 3), None)
    if not s0:
        return c
    c.add("final position error vs start (ARKit pose)", round(dist(last, s0), 4) if last else None, "<=", th["square_final_error_m"], "m")
    c.add("final yaw error", round(abs(shortest_delta(s0["yaw_deg"], last["yaw_deg"])), 3) if last else None, "<=", th["square_final_yaw_error_deg"], "deg")
    c.metrics["turns_completed"] = len(ends)
    return c


def analyze_spin(log, th):
    c = Checks()
    s0, s1 = log.first("spin_start", "spin"), log.first("spin_end", "spin")
    if not s0:
        return c
    if s1:
        poses = log.pose_in(s0["t"], s1["t"])
        total = sum(shortest_delta(a["yaw_deg"], b["yaw_deg"]) for a, b in zip(poses, poses[1:]))
        c.add("yaw error (unwrapped total minus target)", round(abs(total - th["spin_target_deg"]), 3), "<=", th["spin_yaw_error_deg"], "deg")
        c.metrics["spin_total_deg"] = round(total, 3)
    else:
        c.add("yaw error (unwrapped total minus target)", None, "<=", th["spin_yaw_error_deg"], "deg")
    stop = next((r for r in log.cmd if r["t"] > s0["t"] and r.get("mode") == "stop" and r.get("step") == "spin"), None)
    c.add("spin time (start to stop command)", round(stop["t"] - s0["t"], 3) if stop else None, "<=", th["spin_time_max_s"], "s")
    return c


def analyze_obstacle(log, th):
    c = Checks()
    a0, a1 = log.first("approach_start", "obstacle"), log.first("approach_end", "obstacle")
    if not a0:
        return c
    stopped = log.first("approach_stopped", "obstacle")
    c.add("stopped for the box (guard or sonar)", None if not stopped else 1, "==", 1)
    fronts = [s["front_cm"] for s in log.status_in(a0["t"], (a1 or {}).get("t", a0["t"] + 60)) if 0 < s["front_cm"] < 999]
    c.add("closest front sonar before stopping", min(fronts) if fronts else None, ">=", th["contact_margin_cm"], "cm")
    b0, cr, sr, rr = (log.first(n, "obstacle") for n in ("blocked_start", "clamp_forward_result", "blocked_spin_result", "reverse_result"))
    if b0 and cr:
        win = log.status_in(b0["t"] + 0.4, cr["t"] - EPS)
        lin = max(((s["left"] + s["right"]) / 2 for s in win), default=None)
        c.add("forward clamped when front < 20 cm (max applied linear)", lin, "<=", th["clamp_max_linear"], "units")
        seen = any(s["flags"] & 2 for s in log.status_in(b0["t"], cr["t"] - EPS)) if win else None
        c.add("front blocked flag (2) set", None if seen is None else int(seen), "==", 1)
    else:
        c.add("forward clamped when front < 20 cm (max applied linear)", None, "<=", th["clamp_max_linear"], "units")
        c.add("front blocked flag (2) set", None, "==", 1)
    if cr and sr:
        ang = mean([(s["right"] - s["left"]) / 2 for s in log.status_in(cr["t"] + 0.4, sr["t"] - EPS)])
        c.add("turning allowed while blocked (mean applied angular)", None if ang is None else round(ang, 2), ">=", th["blocked_turn_min_angular"], "units")
    else:
        c.add("turning allowed while blocked (mean applied angular)", None, ">=", th["blocked_turn_min_angular"], "units")
    if sr and rr:
        lin = mean([(s["left"] + s["right"]) / 2 for s in log.status_in(sr["t"] + 0.4, rr["t"] - EPS)])
        c.add("reverse allowed while blocked (mean applied linear)", None if lin is None else round(lin, 2), "<=", th["blocked_reverse_max_linear"], "units")
    else:
        c.add("reverse allowed while blocked (mean applied linear)", None, "<=", th["blocked_reverse_max_linear"], "units")
    return c


ANALYZERS = {"wheels_off": analyze_wheels_off, "watchdog": analyze_watchdog, "forward_back": analyze_forward_back,
             "square": analyze_square, "spin": analyze_spin, "obstacle": analyze_obstacle}


# ---------- report ----------
def analyze(records, th, source="", bad_lines=0):
    log = Log(records)
    steps = {}
    for name in STEPS:
        chk = ANALYZERS[name](log, th)
        end = log.step_end(name)
        entry = {"status": "not_run" if not chk.items else chk.overall(), "checks": chk.items, "metrics": chk.metrics,
                 "app_verdict": None if not end else {"pass": end.get("pass"), "reason": end.get("reason"), "metrics": end.get("metrics", {})}}
        steps[name] = entry
    t_inc = len(log.ev("tracking_incident"))
    b_inc = len(log.ev("ble_disconnect"))
    inc = Checks()
    inc.add("tracking incidents (tracking != normal)", t_inc, "<=", th["max_tracking_incidents"])
    inc.add("BLE disconnects", b_inc, "<=", th["max_ble_disconnects"])
    steps["incidents"] = {"status": inc.overall() if log.events else "not_run", "checks": inc.items, "metrics": inc.metrics, "app_verdict": None}
    aborts = [e.get("reason") for e in log.ev("abort")]
    halted = [e.get("reason") for e in log.ev("run_halted")]
    incomplete_steps = [name for name in STEPS if log.step_end(name) is None]
    manual = [{"step": e.get("step"), "key": e.get("key"), "value": e.get("value")} for e in log.ev("manual_measurement")]
    statuses = [v["status"] for k, v in steps.items() if v["status"] != "not_run"]
    if not statuses:
        overall = "no_data"
    elif "fail" in statuses or aborts or halted:
        overall = "fail"
    elif "no_data" in statuses:
        overall = "no_data"
    elif bad_lines or incomplete_steps or any(steps[n]["status"] == "not_run" for n in STEPS):
        overall = "incomplete"      # a partial run is never reported as an overall pass
    else:
        overall = "pass"
    return {"schema": "motion_report.v1", "source": source, "run_id": log.meta.get("run_id"),
            "thresholds_status": th.get("_status"), "bad_log_lines": bad_lines, "aborts": aborts, "halts": halted,
            "human_measurements": manual, "steps": steps, "overall": overall}


def fmt(v):
    return "-" if v is None else (f"{v:.3f}".rstrip("0").rstrip(".") if isinstance(v, float) else str(v))


def render(summary):
    out = [f"Motion self-test report  run_id={summary['run_id']}  source={summary['source']}",
           f"THRESHOLDS: {summary['thresholds_status']}", ""]
    out.append(f"{'step':<14}{'check':<58}{'value':>10}  {'limit':>10}  result")
    for name, st in summary["steps"].items():
        if st["status"] == "not_run":
            out.append(f"{name:<14}{'(not run / no records in the log)':<58}{'':>10}  {'':>10}  NOT RUN")
            continue
        for i in st["checks"]:
            res = {"pass": "PASS", "fail": "FAIL", "no_data": "NO DATA"}[i["status"]]
            lim = f"{i['op']} {fmt(i['limit'])}{(' ' + i['unit']) if i['unit'] else ''}"
            out.append(f"{name:<14}{i['name'][:56]:<58}{fmt(i['value']):>10}  {lim:>10}  {res}")
    if summary["aborts"]:
        out.append("\nABORTED: " + ", ".join(map(str, summary["aborts"])))
    if summary["halts"]:
        out.append("HALTED: " + "; ".join(map(str, summary["halts"])))
    for m in summary["human_measurements"]:
        out.append(f"Human tape measure: {m['step']} {m['key']} = {fmt(m['value'])} (not verified by the app)")
    if summary["bad_log_lines"]:
        out.append(f"WARNING: {summary['bad_log_lines']} unreadable log lines were skipped")
    out.append(f"\nOVERALL: {summary['overall'].upper().replace('_', ' ')}")
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("log")
    ap.add_argument("--thresholds", default=str(DEFAULT_THRESHOLDS))
    ap.add_argument("--summary", help="write the summary JSON here")
    args = ap.parse_args(argv)
    try:
        th = json.loads(Path(args.thresholds).read_text())
        records, bad = load(args.log)
    except (OSError, json.JSONDecodeError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    if not records:
        print("error: no readable records in the log", file=sys.stderr)
        return 2
    summary = analyze(records, th, source=str(args.log), bad_lines=bad)
    print(render(summary))
    if args.summary:
        Path(args.summary).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    return 0 if summary["overall"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
