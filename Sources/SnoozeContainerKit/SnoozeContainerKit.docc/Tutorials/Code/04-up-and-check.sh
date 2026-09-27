snooze up try
# ask it something, e.g. "create hello.txt saying hi, then run ls -l" — then Ctrl-] to detach

snooze exec try -- printenv ANTHROPIC_API_KEY     # snz_cred_… , a placeholder, not your key
snooze net log try                                # allowed/denied connections, metadata only
snooze exec try -- getent hosts example.com       # nothing: the agent policy allows only Anthropic + registries
snooze net log try --denied
