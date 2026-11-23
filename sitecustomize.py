# Railway shows the host's CPUs (32+) inside a 1 vCPU service. Repowise and
# asyncio size process and thread pools from os.cpu_count(), so report the
# count the start script derived from the service's memory limit instead.
import os

_n = os.environ.get("REPOWISE_CPUS", "")
if _n.isdigit() and int(_n) > 0:
    os.cpu_count = lambda: int(_n)  # type: ignore[assignment]
    if hasattr(os, "process_cpu_count"):
        os.process_cpu_count = lambda: int(_n)  # type: ignore[assignment]
