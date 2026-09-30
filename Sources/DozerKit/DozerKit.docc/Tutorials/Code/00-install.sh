export HOMEBREW_GITHUB_API_TOKEN=$(gh auth token)   # while the repositories are private
brew tap johnoscott/dozer git@github.com:johnoscott/homebrew-dozer-prelaunch.git
brew install doz                   # the prebuilt, signed release — seconds, no compiler
doz onboard                       # checks, the Claude account, settings, images — Enter takes each default
doz onboard --status               # after Ctrl-C: the preparation went on in the host; this follows it again
