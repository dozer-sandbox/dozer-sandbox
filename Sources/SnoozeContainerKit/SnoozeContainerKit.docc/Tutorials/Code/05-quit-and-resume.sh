snooze deep-sleep try
snooze host stop                      # deep-sleeps anything still running, then exits
snooze host status                    # no host
snooze ls                             # still answers (read from the store, no host started)

# if you used key option (a), set the key again now — the host that held it is gone
snooze up try                         # a new host starts, wakes `try`, reattaches
# you are back in the SAME Claude Code conversation, on the same screen, same process
