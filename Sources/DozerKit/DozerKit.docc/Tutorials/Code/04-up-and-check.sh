doz up try
# ask it something, e.g. "create hello.txt saying hi, then run ls -l" — then Ctrl-] to detach

doz exec try -- printenv ANTHROPIC_API_KEY     # doz_cred_… , a placeholder, not your key
doz net log try                                # allowed/denied connections, metadata only
doz exec try -- getent hosts example.com       # nothing: the agent policy allows only Anthropic + registries
doz net log try --denied
