doz image ls                       # claude-code: prepared by doz onboard

mkdir -p ~/doz-try && cd ~/doz-try
doz create try --image claude-code --workspace ~/doz-try
doz inspect try --prompt           # what Claude is told about where it runs: /workspace = ~/doz-try
