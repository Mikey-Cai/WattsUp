#!/usr/bin/python3
"""Local-only SMC idle/load comparison. No inferred component mappings."""

import argparse
import datetime
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def finite_number(value):
    return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value)


def run_probe(executable, path):
    started = timestamp()
    try:
        completed = subprocess.run([str(executable), "--probe"], capture_output=True,
                                   text=True, encoding="utf-8", timeout=12, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        evidence = {"started": started, "error": str(error), "probe": None}
        write_json(path, evidence)
        return None, evidence
    evidence = {"started": started, "returncode": completed.returncode,
                "stderr": completed.stderr, "stdout": completed.stdout}
    try:
        report = json.loads(completed.stdout)
        if not isinstance(report, dict) or not isinstance(report.get("keys"), list):
            raise ValueError("--probe JSON has no keys array")
    except (json.JSONDecodeError, ValueError) as error:
        evidence["error"] = str(error)
        write_json(path, evidence)
        return None, evidence
    # Keep the CLI JSON without wrapping it; access and per-key failures stay intact.
    write_json(path, report)
    return report if completed.returncode == 0 else None, evidence


def usable_power(report):
    if not report or not report.get("totalKeyCount"):
        return False
    return any(key.get("key", "").startswith("P") and key.get("type") == "flt "
               and key.get("error") is None and finite_number(key.get("value"))
               and key["value"] >= 0 for key in report["keys"])


def compare(idle, loaded):
    if not idle or not loaded:
        return []
    before = {key.get("key"): key for key in idle["keys"]}
    rows = []
    for key in loaded["keys"]:
        name = key.get("key", "")
        original = before.get(name)
        if not original or key.get("type") != "flt " or original.get("type") != "flt ":
            continue
        a, b = original.get("value"), key.get("value")
        if not finite_number(a) or not finite_number(b) or original.get("error") or key.get("error"):
            continue
        rows.append({"key": name, "type": "flt ", "powerRelated": name.startswith("P"),
                     "idle": a, "load": b, "delta": b - a,
                     "mapping": "未确认：CPU负载相关性不能证明CPU专属轨"})
    return sorted(rows, key=lambda row: (not row["powerRelated"], -abs(row["delta"]), row["key"]))


def stop_workers(workers):
    records = []
    # Only Popen handles created by this invocation are ever signalled.
    for process in workers:
        if process.poll() is None:
            process.terminate()
    for process in workers:
        forced = False
        try:
            code = process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            forced = True
            process.kill()
            code = process.wait(timeout=2)
        records.append({"pid": process.pid, "returncode": code,
                        "forcedKill": forced, "stopped": process.poll() is not None})
    return records


def main():
    def interrupted(signum, _frame):
        # A terminal hangup or graceful cancellation must also run load cleanup.
        raise KeyboardInterrupt("received signal " + str(signum))

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="只用自己启动的短时 CPU 子进程比较 SMC 键；不联网、不推断部件映射。")
    parser.add_argument("--executable", type=Path, default=root / "build/WattsUp.app/Contents/MacOS/WattsUp")
    parser.add_argument("--output-dir", type=Path, default=root / "Reports")
    parser.add_argument("--workers", type=int, choices=(2, 3, 4), default=2)
    parser.add_argument("--load-seconds", type=float, default=3)
    args = parser.parse_args()
    if not 1 <= args.load_seconds <= 5:
        parser.error("--load-seconds 必须在 1–5 秒内")
    if not args.executable.is_file() or not os.access(args.executable, os.X_OK):
        parser.error("找不到可执行 App；请先运行 ./scripts/build.sh")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    prefix = args.output_dir / ("raw-power-" + stamp)
    summary_path = Path(str(prefix) + "-comparison.json")
    idle_path = Path(str(prefix) + "-idle.json")
    summary = {"started": timestamp(), "executable": str(args.executable.resolve()),
               "idlePath": str(idle_path), "workersRequested": args.workers,
               "loadSecondsRequested": args.load_seconds, "loadLaunched": False,
               "workers": [], "classification": "未确认；不由相关性指定 CPU/GPU/DRAM 电气映射"}
    idle, idle_evidence = run_probe(args.executable, idle_path)
    summary["idleExecution"] = idle_evidence
    if not usable_power(idle):
        summary["status"] = "stopped_no_readable_smc_power"
        summary["reason"] = "SMC 功耗不可读，已保存拒绝/错误证据；没有启动 CPU 负载。"
        write_json(summary_path, summary)
        print(summary["reason"])
        print(summary_path)
        return 0

    workers = []
    loaded = None
    try:
        for _ in range(args.workers):
            workers.append(subprocess.Popen(["/usr/bin/yes"], stdout=subprocess.DEVNULL,
                                            stderr=subprocess.DEVNULL))
        summary["loadLaunched"] = True
        summary["loadStarted"] = timestamp()
        time.sleep(args.load_seconds)
        load_path = Path(str(prefix) + "-load.json")
        loaded, load_evidence = run_probe(args.executable, load_path)
        summary["loadPath"] = str(load_path)
        summary["loadExecution"] = load_evidence
    except (OSError, KeyboardInterrupt) as error:
        summary["loadError"] = str(error)
    finally:
        summary["workers"] = stop_workers(workers)
        summary["loadStopped"] = timestamp()
        summary["allOwnWorkersStopped"] = all(record["stopped"] for record in summary["workers"])
        # Always persist cleanup evidence, including interrupted/failed probes.
        write_json(summary_path, summary)

    recovery_path = Path(str(prefix) + "-recovery.json")
    recovery, recovery_evidence = run_probe(args.executable, recovery_path)
    summary["recoveryPath"] = str(recovery_path)
    summary["recoveryExecution"] = recovery_evidence
    summary["recoveryPowerReadable"] = usable_power(recovery)
    summary["comparison"] = compare(idle, loaded)
    summary["status"] = "complete_correlation_only" if loaded else "load_probe_failed"
    summary["finished"] = timestamp()
    write_json(summary_path, summary)
    print("已保存空闲、负载、恢复探测；仅比较键的相关性，部件映射仍为未确认。")
    print(summary_path)
    return 0 if loaded and summary["allOwnWorkersStopped"] else 1


if __name__ == "__main__":
    sys.exit(main())
