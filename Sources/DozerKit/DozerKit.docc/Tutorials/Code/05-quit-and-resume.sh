doz hibernate try
doz host stop                      # hibernates anything still running, then exits
doz host status                    # no host
doz ls                             # still answers (read from the store, no host started)

# if you used key option (a), set the key again now — the host that held it is gone
doz up try                         # a new host starts, wakes `try`, reattaches
# you are back in the SAME Claude Code conversation, on the same screen, same process
