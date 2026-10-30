import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from launch import supervise


class LaunchTests(unittest.TestCase):
    def test_worker_exit_stops_api(self):
        started = time.monotonic()
        status = supervise([[sys.executable, '-c', 'raise SystemExit(2)'], [sys.executable, '-c', 'import time; time.sleep(20)']], grace_seconds=1)
        self.assertEqual(status, 1)
        self.assertLess(time.monotonic() - started, 5)

    def test_termination_stops_both_processes(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = [str(Path(tmp) / str(i)) for i in range(2)]
            commands = [[sys.executable, '-c', 'import os,time; from pathlib import Path; Path(' + repr(path) + ').write_text(str(os.getpid())); time.sleep(30)'] for path in paths]
            code = 'from launch import supervise; raise SystemExit(supervise(' + repr(commands) + ', grace_seconds=1))'
            parent = subprocess.Popen([sys.executable, '-c', code], cwd=str(Path(__file__).resolve().parents[1]))
            try:
                deadline = time.monotonic() + 5
                while not all(Path(x).exists() for x in paths) and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(all(Path(x).exists() for x in paths))
                pids = [int(Path(x).read_text()) for x in paths]
                parent.send_signal(signal.SIGTERM)
                self.assertEqual(parent.wait(timeout=5), 0)
                for pid in pids:
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
            finally:
                if parent.poll() is None:
                    parent.kill()
                    parent.wait()

if __name__ == '__main__':
    unittest.main()
