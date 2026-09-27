snooze pause lab1                     # ~1 ms. CPU stops; RAM is kept.
snooze resume lab1

snooze sleep lab1                     # pause + snapshot to disk; RAM still held
snooze wake lab1

snooze deep-sleep lab1                # snapshot, then the VM stops: RAM held goes to —
snooze ls
snooze attach lab1                    # wakes it (~0.3 s) and reattaches: top is still running
