snooze point take lab1 clean          # instant: an APFS clone of the disk
snooze exec lab1 -- rm -rf /usr/bin/vi /root/marker
snooze point revert lab1 clean        # asks first; shuts the sandbox down
snooze start lab1
snooze exec lab1 -- cat /root/marker  # "I was here" is back, and so is vi
snooze point ls lab1                  # clean, plus the automatic "before revert" point

# make a second sandbox from that point:
snooze point fork lab1 clean lab2
