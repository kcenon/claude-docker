"""Record the actual backend and check enforced cgroup limits, not YAML alone."""
import platform
import re
from container_fixture import policy
from workflow_support import WorkflowFailure

PROFILES = ("linux-engine", "macos-desktop", "windows-desktop", "wsl2-desktop", "linux-rootless")


def backend_profile(provenance):
    daemon = provenance["daemon"]
    desktop = "docker desktop" in daemon["OperatingSystem"].lower()
    rootless = any("rootless" in option for option in daemon["SecurityOptions"])
    host = platform.system()
    if desktop:
        if host == "Darwin":
            return "macos-desktop"
        if host == "Windows":
            return "windows-desktop"
        if host == "Linux" and "microsoft" in platform.release().lower():
            return "wsl2-desktop"
    elif host == "Linux":
        return "linux-rootless" if rootless else "linux-engine"
    raise WorkflowFailure("unrecognized_host_backend_profile")


def verify_environment(fixture, provenance, requested_profile=None, desktop_version=None):
    profile = backend_profile(provenance)
    if requested_profile and requested_profile != profile:
        raise WorkflowFailure("host_backend_profile_mismatch")
    observations = []
    for index, name in enumerate(fixture.services):
        service = fixture.model["services"][name]
        limits = service["deploy"]["resources"]["limits"]
        memory = int(fixture.execute(index, "sh", "-c",
            "cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes"))
        pids = int(fixture.execute(index, "sh", "-c",
            "cat /sys/fs/cgroup/pids.max 2>/dev/null || cat /sys/fs/cgroup/pids/pids.max"))
        cpu = fixture.execute(index, "sh", "-c",
            "cat /sys/fs/cgroup/cpu.max 2>/dev/null || { cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us; cat /sys/fs/cgroup/cpu/cpu.cfs_period_us; }")
        quota, period = map(int, cpu.split())
        expected_pids = service.get("pids_limit", limits.get("pids"))
        if (memory != policy.size_bytes(limits["memory"]) or pids != int(expected_pids)
                or quota <= 0 or period <= 0 or abs(quota / period - float(limits["cpus"])) > 0.00001):
            raise WorkflowFailure("resource_enforcement_mismatch")
        status = fixture.execute(index, "cat", "/proc/self/status")
        fields = dict(line.split(":", 1) for line in status.splitlines() if ":" in line)
        if (int(fields["NoNewPrivs"]) != 1 or int(fields["Seccomp"]) != 2
                or int(fields["CapEff"], 16) or int(fields["CapBnd"], 16)
                or int(fixture.execute(index, "id", "-u")) != fixture.uid or fixture.uid == 0):
            raise WorkflowFailure("effective_security_mismatch")
        mounts = [line.split() for line in fixture.execute(index, "cat", "/proc/mounts").splitlines()]
        if not any(row[1] == "/" and "ro" in row[3].split(",") for row in mounts):
            raise WorkflowFailure("effective_root_not_read_only")
        scratch = {}
        for path, key in policy.SCRATCH.items():
            row = next(row for row in mounts if row[1] == path)
            size = next(option[5:] for option in row[3].split(",") if option.startswith("size="))
            scratch[path] = policy.size_bytes(size)
            if row[2] != "tmpfs" or scratch[path] != int(fixture.values.get(key, policy.DEFAULTS[key])) * 1048576:
                raise WorkflowFailure("effective_scratch_mismatch")
        observations.append({"account": index + 1, "memory_limit_bytes": memory, "pids_limit": pids,
                             "cpu_quota": quota, "cpu_period": period, "scratch_limit_bytes": scratch,
                             "runtime_version": fixture.execute(index, fixture.spec["binary"], "--version").strip()})
    host = {"system": platform.system(), "release": platform.release(), "version": platform.version(),
            "architecture": platform.machine(), "python": platform.python_version()}
    if fixture.language == "powershell":
        host["powershell"] = fixture.run(["pwsh", "--version"]).strip()
    else:
        host["bash"] = fixture.run(["bash", "--version"]).splitlines()[0]
    if "desktop" in profile:
        # `docker desktop version` describes its CLI plugin, not the Desktop
        # application. Do not substitute it for the operator's product version.
        if not desktop_version or not re.fullmatch(r"[0-9][0-9A-Za-z.+_-]{0,60}", desktop_version):
            raise WorkflowFailure("desktop_product_version_required")
        host["docker_desktop"] = desktop_version
        host["desktop_version_source"] = "explicit operator input from Docker Desktop About"
    return {"profile": profile, "host": host, "effective_limits": observations}
