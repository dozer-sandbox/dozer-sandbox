# (a) for this session: paste at the prompt (no echo), or pipe it from a file
doz key set try --anthropic

# (b) kept in the login keychain, re-read whenever a new host loads the sandbox
security add-generic-password -s doz-anthropic -a "$USER" -w     # prompts for the key
doz key set try --anthropic --keychain doz-anthropic
