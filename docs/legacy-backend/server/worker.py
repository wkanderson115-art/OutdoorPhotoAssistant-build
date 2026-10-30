"""One process per database. Exclusive OS lock prevents duplicate worker recovery."""
import fcntl
import time
from core import Store, process_one

if __name__ == '__main__':
    store = Store()
    with open(store.path + '.worker.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        store.recover()
        while True:
            store.cleanup()
            if not process_one(store):
                time.sleep(1)
