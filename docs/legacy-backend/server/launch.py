"""Single-service deployment: supervise API + queue worker on one persistent disk.
If either process exits, stop both and let the hosting platform restart the service.
"""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def supervise(commands, *, environments=None, grace_seconds=15):
    children = []
    stopping = False
    previous = {}
    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True
    try:
        for signum in (signal.SIGTERM, signal.SIGINT):
            previous[signum] = signal.signal(signum, stop)
        for index, command in enumerate(commands):
            if stopping:
                break
            children.append(subprocess.Popen(command, env=environments[index] if environments else None, start_new_session=True))
        while not stopping:
            if any(child.poll() is not None for child in children):
                return 1
            time.sleep(0.1)
        return 0
    finally:
        for child in children:
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        deadline = time.monotonic() + grace_seconds
        for child in children:
            try:
                child.wait(timeout=max(0.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait()
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def main():
    os.chdir(Path(__file__).resolve().parent)
    port = int(os.environ.get('PORT', '10000'))
    if not 1 <= port <= 65535:
        raise ValueError('PORT must be a TCP port')
    api_env = {key: value for key, value in os.environ.items() if key not in ('DEEPSEEK_API_KEY', 'SEEDREAM_API_KEY')}
    return supervise([
        [sys.executable, 'worker.py'],
        [sys.executable, '-m', 'uvicorn', 'app:app', '--host', '0.0.0.0', '--port', str(port), '--no-access-log', '--no-proxy-headers'],
    ], environments=[os.environ.copy(), api_env])


if __name__ == '__main__':
    raise SystemExit(main())
