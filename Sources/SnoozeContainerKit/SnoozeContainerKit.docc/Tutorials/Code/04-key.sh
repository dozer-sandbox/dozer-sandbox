# (a) for this session: paste at the prompt (no echo), or pipe it from a file
snooze key set try --anthropic

# (b) kept in the login keychain, re-read whenever a new host loads the sandbox
security add-generic-password -s snooze-anthropic -a "$USER" -w     # prompts for the key
snooze key set try --anthropic --keychain snooze-anthropic
