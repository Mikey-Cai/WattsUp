#!/usr/bin/env python3
"""Bounded, local five-stimulus SMC/IOReport calibration; no inferred rail sums."""

import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import statistics
import subprocess
import sys
import tempfile
import time


STAGES = ("idle", "cpu", "gpu", "memory", "disk")


def timestamp():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def write_json(path, value):
    # The result directory belongs solely to this invocation.
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def digest(path):
    with path.open("rb") as file:
        return hashlib.sha256(file.read()).hexdigest()


class Interrupted(Exception):
    pass


class OwnedProcesses:
    """Own isolated process groups rooted at exact Popen handles; no PID scan."""

    def __init__(self):
        self.entries = []

    def start(self, command, role, capture=True, **kwargs):
        process = subprocess.Popen(command, stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                                   stderr=subprocess.PIPE if capture else subprocess.DEVNULL,
                                   text=True, encoding="utf-8", start_new_session=True, **kwargs)
        entry = {"process": process, "record": {"pid": process.pid, "role": role,
                 "ownedProcessGroup": process.pid, "command": [str(part) for part in command],
                 "started": timestamp()}, "captured": capture}
        self.entries.append(entry)
        return entry

    def stop(self, entry):
        process, record = entry["process"], entry["record"]
        # Never probe/signal a historic, already-reaped group: its PGID could
        # eventually be reused by an unrelated process.
        if record.get("cleanupFinished") and record.get("ownGroupStopped"):
            return record
        record["runningBeforeCleanup"] = process.poll() is None
        record["forcedKill"] = False
        # Each group was created by start_new_session=True. This also stops
        # compiler descendants if its driver has exited but pipes remain open.
        try:
            os.killpg(record["ownedProcessGroup"], signal.SIGTERM)
            record["groupTermSent"] = True
        except ProcessLookupError:
            record["groupTermSent"] = False
        try:
            stdout, stderr = process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            record["forcedKill"] = True
            try:
                os.killpg(record["ownedProcessGroup"], signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate(timeout=2)
        # A compiler descendant may close its inherited pipes before exiting.
        # Wait briefly for the owned group too, then force only that group.
        group_deadline = time.monotonic() + 0.5
        while self.group_exists(record) and time.monotonic() < group_deadline:
            time.sleep(0.025)
        if self.group_exists(record):
            record["forcedKill"] = True
            try:
                os.killpg(record["ownedProcessGroup"], signal.SIGKILL)
            except ProcessLookupError:
                pass
            group_deadline = time.monotonic() + 0.5
            while self.group_exists(record) and time.monotonic() < group_deadline:
                time.sleep(0.025)
        record.update(returncode=process.returncode, stopped=process.poll() is not None,
                      ownGroupStopped=not self.group_exists(record), cleanupFinished=timestamp())
        if entry["captured"]:
            record.update(stdout=stdout or "", stderr=stderr or "")
        return record

    def mark_finished(self, entry, stdout="", stderr=""):
        """Confirm the group immediately after communicate, not at run end."""
        record = entry["record"]
        record.update(returncode=entry["process"].returncode, stopped=True,
                      stdout=stdout or "", stderr=stderr or "")
        if not self.group_exists(record):
            record.update(ownGroupStopped=True, cleanupFinished=timestamp())
        else:
            self.stop(entry)
        return record

    @staticmethod
    def group_exists(record):
        try:
            os.killpg(record["ownedProcessGroup"], 0)
            return True
        except ProcessLookupError:
            return False
        except OSError:
            # Failure to inspect must not be reported as a stopped group.
            return True

    def cleanup(self):
        return self.cleanup_entries(reversed(self.entries))

    def cleanup_entries(self, entries):
        records = []
        for entry in entries:
            try:
                records.append(self.stop(entry))
            except Exception as error:
                # One blocked pipe or failed wait must not leave other loads
                # without even receiving their cleanup signal.
                record = entry["record"]
                try:
                    os.killpg(record["ownedProcessGroup"], signal.SIGKILL)
                except OSError:
                    pass
                record.update(cleanupError=type(error).__name__ + ": " + str(error),
                    stopped=entry["process"].poll() is not None,
                    ownGroupStopped=not self.group_exists(record))
                records.append(record)
        return records


def command_json(owner, command, role, timeout):
    before = time.monotonic()
    execution = {"command": [str(part) for part in command], "started": timestamp()}
    entry = owner.start(command, role)
    try:
        stdout, stderr = entry["process"].communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        execution["error"] = "command_timeout"
        record = owner.stop(entry)
        stdout, stderr = record.get("stdout", ""), record.get("stderr", "")
    else:
        owner.mark_finished(entry, stdout, stderr)
    execution.update(finished=timestamp(), durationSeconds=time.monotonic() - before,
                     returncode=entry["process"].returncode, stderr=stderr)
    try:
        report = json.loads(stdout)
        if not isinstance(report, dict):
            raise ValueError("CLI JSON root must be an object")
    except (json.JSONDecodeError, ValueError) as error:
        execution.update(parseError=str(error), stdout=stdout)
        report = None
    return report, execution


def load_alive(entries):
    return all(entry["process"].poll() is None for entry in entries)


def capture(owner, executable, phase, index, output, entries, ready_clock, deadline):
    start = time.monotonic()
    record = {"index": index, "started": timestamp(), "loadAliveBefore": load_alive(entries),
              "secondsSinceLoadReady": start - ready_clock if ready_clock is not None else None}
    for flag, field, suffix in (("--probe", "smcProbe", "probe"), ("--dump-json", "snapshot", "snapshot")):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not load_alive(entries):
            record["error"] = "stage_timeout" if remaining <= 0 else "load_exited_before_sampling_finished"
            break
        report, execution = command_json(owner, [str(executable), flag], phase + ":" + suffix,
                                         timeout=min(8, remaining))
        raw_path = output / (f"{phase}-{index:02d}-{suffix}.json")
        write_json(raw_path, {"execution": execution, "report": report})
        record[field] = report
        record[field + "Execution"] = execution
        record[field + "Path"] = str(raw_path)
    record.update(finished=timestamp(), durationSeconds=time.monotonic() - start,
                  loadAliveAfter=load_alive(entries))
    probe = record.get("smcProbe") or {}
    snapshot = record.get("snapshot") or {}
    power = snapshot.get("power") or {}
    channels = power.get("channels") or []
    # --dump-json creates its subscription after stimulus readiness. Also check
    # the energy delta does not extend beyond the observed ready-to-end window.
    available_window = time.monotonic() - ready_clock if ready_clock is not None else None
    window_valid = ready_clock is None or all(finite(ch.get("elapsedSeconds")) and
                        0 < ch["elapsedSeconds"] <= available_window + 0.1 for ch in channels)
    record["energyWindowsInsideStimulus"] = window_valid
    record["validForComparison"] = (not record.get("error") and record["loadAliveBefore"] and
        record["loadAliveAfter"] and window_valid and isinstance(probe.get("keys"), list) and
        isinstance(snapshot.get("power"), dict) and
        all(record.get(name + "Execution", {}).get("returncode") == 0 and
            not record.get(name + "Execution", {}).get("error") for name in ("smcProbe", "snapshot")))
    return record


def sensor_access(samples):
    samples = [sample for sample in samples if sample.get("validForComparison")]
    smc = any(finite(key.get("value")) and key.get("value", -1) >= 0 and not key.get("error")
              for sample in samples for key in (sample.get("smcProbe") or {}).get("keys", [])
              if key.get("key", "").startswith("P"))
    energy = any(finite(ch.get("watts")) and ch["watts"] >= 0 for sample in samples
                 for ch in ((sample.get("snapshot") or {}).get("power") or {}).get("channels", []))
    return {"smcPowerReadable": smc, "ioReportPowerReadable": energy, "anyPowerReadable": smc or energy}


def comparable_power(baseline, loaded):
    def identities(samples):
        smc, energy = set(), set()
        for sample in samples:
            if not sample.get("validForComparison"):
                continue
            for key in (sample.get("smcProbe") or {}).get("keys", []):
                if (key.get("key", "").startswith("P") and finite(key.get("value"))
                        and key["value"] >= 0 and not key.get("error")):
                    smc.add((key["key"], key.get("type", "")))
            for channel in ((sample.get("snapshot") or {}).get("power") or {}).get("channels", []):
                if finite(channel.get("watts")) and channel["watts"] >= 0:
                    energy.add(tuple(channel.get(key, "") for key in ("group", "subgroup", "name", "unit")))
        return smc, energy

    before_smc, before_io = identities(baseline)
    after_smc, after_io = identities(loaded)
    smc, energy = before_smc & after_smc, before_io & after_io
    return {"smcKeyAndType": [list(value) for value in sorted(smc)],
            "ioReportGroupSubgroupNameUnit": [list(value) for value in sorted(energy)],
            "anyComparablePower": bool(smc or energy)}


def summarize(phases):
    smc_values, io_values, descriptors = {}, {}, {}
    for phase in phases:
        name = phase["name"]
        # Local idle is kept separately so thermal/background drift is visible.
        sample_sets = ((name, phase.get("samples", [])), (name + "-local-idle", phase.get("baselineSamples", [])))
        for sample_name, samples in sample_sets:
            for sample in samples:
                if not sample.get("validForComparison"):
                    continue
                for key in (sample.get("smcProbe") or {}).get("keys", []):
                    if key.get("key", "").startswith("P"):
                        identity = (key.get("key"), key.get("type", ""))
                        values = smc_values.setdefault(identity, {}).setdefault(sample_name, [])
                        if finite(key.get("value")) and not key.get("error"):
                            values.append(key["value"])
                power = (sample.get("snapshot") or {}).get("power") or {}
                for channel in power.get("availableChannels", []):
                    identity = tuple(channel.get(key, "") for key in ("group", "subgroup", "name", "unit"))
                    descriptors[identity] = channel
                for channel in power.get("channels", []):
                    identity = tuple(channel.get(key, "") for key in ("group", "subgroup", "name", "unit"))
                    values = io_values.setdefault(identity, {}).setdefault(sample_name, [])
                    if finite(channel.get("watts")) and channel["watts"] >= 0:
                        values.append(channel["watts"])

    def stats(values):
        return {"count": len(values), "mean": statistics.mean(values) if values else None,
                "min": min(values) if values else None, "max": max(values) if values else None,
                "standardDeviation": statistics.pstdev(values) if values else None}

    def rows(collection, kind):
        result = []
        for identity, phase_values in sorted(collection.items()):
            by_phase = {name: stats(phase_values.get(name, [])) for name in STAGES}
            baseline = by_phase["idle"]["mean"]
            for name, summary in by_phase.items():
                summary["deltaFromIdle"] = summary["mean"] - baseline if finite(summary["mean"]) and finite(baseline) else None
                local_idle = stats(phase_values.get(name + "-local-idle", []))
                summary["localIdle"] = local_idle
                summary["deltaFromLocalIdle"] = (summary["mean"] - local_idle["mean"]
                    if finite(summary["mean"]) and finite(local_idle["mean"]) else None)
            if kind == "smc":
                row = {"key": identity[0], "type": identity[1], "unit": "SMC raw decoded numeric; unit not independently verified"}
            else:
                row = dict(zip(("group", "subgroup", "name", "energyUnit"), identity))
                row["unit"] = "W (energy delta / measured elapsed seconds)"
            row["stages"] = by_phase
            result.append(row)
        return result

    return {"smcPowerKeys": rows(smc_values, "smc"), "ioReportChannels": rows(io_values, "ioreport"),
            "availableIOReportDescriptors": list(descriptors.values()),
            "interpretation": "各刺激相对空闲的均值和Δ仅用于映射假设；P开头的键不保证都是瓦特。父子轨、别名和DC输入不自动相加。"}


def wait_ready(entry, ready_path, deadline):
    while time.monotonic() < deadline:
        if entry["process"].poll() is not None:
            raise RuntimeError("load_exited_before_ready")
        if ready_path.is_file():
            report = json.loads(ready_path.read_text(encoding="utf-8"))
            if report.get("pid") != entry["process"].pid or report.get("firstIterationCompleted") is not True:
                raise RuntimeError("invalid_load_ready_evidence")
            return report, time.monotonic()
        time.sleep(0.025)
    raise RuntimeError("load_ready_timeout")


def parse_arguments():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="五阶段本地标定：空闲/CPU/Metal GPU/内存带宽/磁盘读写；只清理自身子进程和临时文件。")
    parser.add_argument("--executable", type=Path, default=root / "build/WattsUp.app/Contents/MacOS/WattsUp")
    parser.add_argument("--output-dir", type=Path, default=root / "Reports")
    parser.add_argument("--samples", type=int, choices=range(2, 6), default=3, help="各阶段样本数（默认3）")
    parser.add_argument("--workers", type=int, choices=(1, 2, 3, 4), default=4, help="自有 yes CPU进程数（默认4）")
    parser.add_argument("--warmup", type=float, default=1, help="刺激预热秒数，0.25...3（默认1）")
    parser.add_argument("--cooldown", type=float, default=2, help="阶段间冷却秒数，1...5（默认2）")
    parser.add_argument("--sample-gap", type=float, default=0.25, help="样本间额外等待，0...1（默认0.25）")
    parser.add_argument("--memory-mb", type=int, choices=(64, 128, 256), default=128, help="两条内存流合计分配，1024进制MB")
    parser.add_argument("--disk-mb", type=int, choices=(16, 32, 64, 128), default=64, help="临时磁盘文件最大大小，1024进制MB")
    args = parser.parse_args()
    if not all(math.isfinite(value) for value in (args.warmup, args.cooldown, args.sample_gap)) or not (
            0.25 <= args.warmup <= 3 and 1 <= args.cooldown <= 5 and 0 <= args.sample_gap <= 1):
        parser.error("warmup/cooldown/sample-gap 超出允许范围")
    args.executable = args.executable.expanduser().resolve()
    if not args.executable.is_file() or not os.access(args.executable, os.X_OK):
        parser.error("找不到可执行 WattsUp App，请先构建")
    args.output_dir = args.output_dir.expanduser().resolve()
    args.root = root
    return args


def main():
    args = parse_arguments()
    owner = OwnedProcesses()
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    output = args.output_dir / ("calib2-" + stamp)
    output.mkdir(parents=True, exist_ok=False)
    result_path = output / "comparison.json"
    source = args.root / "scripts/CalibrationLoad.swift"
    result = {"schemaVersion": 2, "started": timestamp(), "status": "running",
              "executable": str(args.executable), "executableSHA256": digest(args.executable),
              "loadSourceSHA256": digest(source), "plan": list(STAGES),
              "settings": {name: value for name, value in vars(args).items() if isinstance(value, (int, float))},
              "phases": [], "ownedProcessCleanup": [], "temporaryFilesRemoved": False}

    def interrupted(signum, _frame):
        # Subsequent graceful signals must not interrupt cleanup itself.
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, signal.SIG_IGN)
        raise Interrupted("received_signal_" + str(signum))

    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)

    temporary_path = None
    temporary_holder = None
    return_code = 1
    try:
        temporary_holder = tempfile.TemporaryDirectory(prefix="wattsup-calibrate2-")
        temporary_path = Path(temporary_holder.name)
        result["temporaryDirectory"] = str(temporary_path)
        helper = temporary_path / "CalibrationLoad"
        # Compilation precedes the idle phase and a cooldown; it does not
        # contribute to any measured stimulus window.
        compile_entry = owner.start(["/usr/bin/xcrun", "swiftc", "-O", "-module-cache-path",
            str(temporary_path / "ModuleCache"), str(source), "-o", str(helper), "-framework", "Metal"], "compiler")
        try:
            stdout, stderr = compile_entry["process"].communicate(timeout=60)
        except subprocess.TimeoutExpired:
            owner.stop(compile_entry)
            raise RuntimeError("load_helper_compile_timeout")
        owner.mark_finished(compile_entry, stdout, stderr)
        result["compilation"] = compile_entry["record"].copy()
        if compile_entry["process"].returncode != 0:
            raise RuntimeError("load_helper_compile_failed")
        time.sleep(args.cooldown)

        idle = {"name": "idle", "started": timestamp(), "samples": []}
        result["phases"].append(idle)
        idle_deadline = time.monotonic() + 15
        for index in range(1, args.samples + 1):
            idle["samples"].append(capture(owner, args.executable, "idle", index, output, [], None, idle_deadline))
            if index < args.samples:
                time.sleep(args.sample_gap)
        idle.update(finished=timestamp(), status="complete" if all(sample["validForComparison"] for sample in idle["samples"]) else "sample_failure")
        result["sensorAccess"] = sensor_access(idle["samples"])
        if not result["sensorAccess"]["anyPowerReadable"]:
            result["status"] = "stopped_no_readable_power"
            result["reason"] = "预检SMC功率键及IOReport功率均不可读；保留原始权限诊断，未启动负载。完整五阶段实现可在正常本地环境直接复跑。"
            for name in STAGES[1:]:
                result["phases"].append({"name": name, "status": "skipped_no_readable_power", "samples": []})
            return_code = 0
        else:
            for name in STAGES[1:]:
                time.sleep(args.cooldown)
                phase = {"name": name, "started": timestamp(), "samples": [], "baselineSamples": [], "status": "starting"}
                result["phases"].append(phase)
                entries = []
                stage_started = None
                ready_clock = None
                try:
                    baseline_deadline = time.monotonic() + 15
                    for index in range(1, 3):
                        baseline = capture(owner, args.executable, name + "-idle", index, output, [], None, baseline_deadline)
                        phase["baselineSamples"].append(baseline)
                        if not baseline["validForComparison"] or not sensor_access([baseline])["anyPowerReadable"]:
                            baseline["validForComparison"] = False
                            raise RuntimeError("local_idle_sample_failed")
                        if index < 2:
                            time.sleep(args.sample_gap)
                    stage_started = time.monotonic()
                    if name == "cpu":
                        for _ in range(args.workers):
                            entries.append(owner.start(["/usr/bin/yes"], "cpu_load", capture=False))
                        time.sleep(0.1)
                        if not load_alive(entries):
                            raise RuntimeError("cpu_load_exited_before_ready")
                        ready_clock = time.monotonic()
                        phase["ready"] = {"method": "owned yes processes alive", "pids": [entry["process"].pid for entry in entries]}
                    else:
                        ready_path = temporary_path / (name + "-ready.json")
                        byte_count = args.disk_mb * 1024 * 1024 if name == "disk" else args.memory_mb * 1024 * 1024
                        command = [str(helper), "--mode", name, "--seconds", "25", "--bytes", str(byte_count),
                                   "--ready-file", str(ready_path)]
                        if name == "disk":
                            command += ["--disk-file", str(temporary_path / "disk-stimulus.bin")]
                        entries.append(owner.start(command, name + "_load"))
                        phase["ready"], ready_clock = wait_ready(entries[0], ready_path, time.monotonic() + 8)
                    phase["loadReady"] = timestamp()
                    time.sleep(args.warmup)
                    deadline = time.monotonic() + 15
                    for index in range(1, args.samples + 1):
                        sample = capture(owner, args.executable, name, index, output, entries, ready_clock, deadline)
                        phase["samples"].append(sample)
                        if not sample["validForComparison"]:
                            raise RuntimeError(sample.get("error", "invalid_sampling_window_or_command"))
                        if not sensor_access([sample])["anyPowerReadable"]:
                            sample["validForComparison"] = False
                            raise RuntimeError("no_readable_power_during_stimulus")
                        if index < args.samples:
                            time.sleep(args.sample_gap)
                    phase["comparablePower"] = comparable_power(phase["baselineSamples"], phase["samples"])
                    if not phase["comparablePower"]["anyComparablePower"]:
                        for sample in phase["samples"]:
                            sample["validForComparison"] = False
                        raise RuntimeError("no_common_power_keys_or_channels_between_local_idle_and_load")
                    phase["status"] = "complete"
                except (OSError, RuntimeError, ValueError) as error:
                    phase.update(status="failed", error=str(error))
                except Interrupted:
                    phase["status"] = "interrupted"
                    raise
                finally:
                    # Runs for normal completion, sampling timeout, helper
                    # failure, Ctrl-C, SIGTERM, and SIGHUP.
                    phase["loadCleanup"] = owner.cleanup_entries(entries)
                    phase["allOwnLoadsStopped"] = all(record["stopped"] and record["ownGroupStopped"] for record in phase["loadCleanup"])
                    if phase["status"] == "complete" and not phase["allOwnLoadsStopped"]:
                        phase.update(status="failed", error="owned_load_cleanup_incomplete")
                    phase.update(finished=timestamp(), stimulusWallSeconds=time.monotonic() - stage_started if stage_started is not None else 0)
                    if name != "cpu" and entries:
                        events = []
                        for line in phase["loadCleanup"][0].get("stdout", "").splitlines():
                            try:
                                events.append(json.loads(line))
                            except json.JSONDecodeError:
                                pass
                        phase["loadEvents"] = events
                        finished = next((event for event in events if event.get("event") == "finished"), None)
                        phase["workEvidenceValid"] = bool(finished and finished.get("iterations", 0) > 0
                            and finished.get("bytesMoved", 0) > 0 and phase["loadCleanup"][0]["returncode"] == 0)
                        if phase["status"] == "complete" and not phase["workEvidenceValid"]:
                            phase.update(status="failed", error="no_successful_load_completion_evidence")
                            for sample in phase["samples"]:
                                sample["validForComparison"] = False
                    write_json(result_path, result)
                print(f"{name}: {phase['status']}，{len(phase['samples'])} 个样本", flush=True)
            time.sleep(args.cooldown)
            recovery_deadline = time.monotonic() + 15
            result["recoverySamples"] = [capture(owner, args.executable, "recovery", index, output, [], None, recovery_deadline)
                                         for index in range(1, 3)]
            result["status"] = "complete_correlation_only" if all(phase["status"] == "complete" for phase in result["phases"]) else "partial_stimulus_failure"
            return_code = 0 if result["status"] == "complete_correlation_only" else 1
    except Interrupted as error:
        result.update(status="interrupted", error=str(error))
        return_code = 130
    except (OSError, RuntimeError, ValueError) as error:
        result.update(status="failed", error=str(error))
        return_code = 1
    finally:
        result["ownedProcessCleanup"] = owner.cleanup()
        if temporary_holder is not None:
            try:
                temporary_holder.cleanup()
            except Exception as error:
                result["temporaryCleanupError"] = type(error).__name__ + ": " + str(error)
        result["allOwnProcessesStopped"] = all(record.get("stopped") and record.get("ownGroupStopped") for record in result["ownedProcessCleanup"])
        result["temporaryFilesRemoved"] = temporary_path is None or not temporary_path.exists()
        if (not result["allOwnProcessesStopped"] or not result["temporaryFilesRemoved"]) and return_code == 0:
            result["status"] = "cleanup_incomplete"
            return_code = 1
        result.update(finished=timestamp(), comparison=summarize(result["phases"]))
        write_json(result_path, result)
        print(result.get("reason", "标定状态：" + result["status"]), flush=True)
        print(result_path, flush=True)
    return return_code


if __name__ == "__main__":
    sys.exit(main())
