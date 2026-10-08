doz point take lab1 clean          # instant: an APFS clone of the disk
doz exec lab1 -- rm -rf /usr/bin/vi /root/marker
doz point revert lab1 clean        # asks first; shuts the sandbox down
doz start lab1
doz exec lab1 -- cat /root/marker  # "I was here" is back, and so is vi
doz point ls lab1                  # clean, plus the automatic "before revert" point

# make a second sandbox from that point:
doz point fork lab1 clean lab2
