doz pause lab1                     # ~1 ms. CPU stops; RAM is kept.
doz resume lab1

doz sleep lab1                     # pause + snapshot to disk; RAM still held
doz wake lab1

doz hibernate lab1                 # snapshot, then the VM stops: RAM held goes to —
doz ls
doz attach lab1                    # wakes it (~0.3 s) and reattaches: top is still running
