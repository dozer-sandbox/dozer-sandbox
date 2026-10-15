#!/bin/sh
# Start Scripts/fake-provider.py in DIR (617): a throwaway CA, a leaf for every host it fakes, the server in the
# background. Used by the network profiler (profile-agents.sh) and `make recipe-check` (recipe-check.py).
#   fake-provider-up.sh DIR      → DIR/{ca.pem, port, pid, requests.log, fake.out}; prints "PORT"
# Env: FAKE_XAI_KEY, FAKE_GOOGLE_KEY, FAKE_ANTHROPIC_KEY, FAKE_OPENAI_KEY, FAKE_OPENROUTER_KEY, FAKE_VERCEL_KEY, FAKE_STITCH_KEY (the fake
# keys it accepts), FAKE_PORT.
# A server already running from DIR (its pid alive) is left as it is. Never a real key.
set -u
D=${1:?usage: fake-provider-up.sh DIR}
REPO=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$D"
cd "$D" || exit 1
if [ -f pid ] && kill -0 "$(cat pid)" 2>/dev/null && [ -s port ]; then cat port; echo; exit 0; fi
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > ca.ext
printf 'subjectAltName=DNS:api.x.ai,DNS:generativelanguage.googleapis.com,DNS:api.anthropic.com,DNS:api.openai.com,DNS:openrouter.ai,DNS:ai-gateway.vercel.sh,DNS:stitch.googleapis.com\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' > leaf.ext
/usr/bin/openssl req -new -newkey rsa:2048 -nodes -keyout ca.key -out ca.csr -subj '/CN=Dozer test fake provider CA' 2>/dev/null || exit 1
/usr/bin/openssl x509 -req -in ca.csr -signkey ca.key -out ca.pem -days 2 -extfile ca.ext 2>/dev/null || exit 1
/usr/bin/openssl req -new -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj '/CN=api.x.ai' 2>/dev/null || exit 1
/usr/bin/openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -days 2 -extfile leaf.ext 2>/dev/null || exit 1
rm -f port requests.log
nohup /usr/bin/python3 "$REPO/Scripts/fake-provider.py" leaf.pem leaf.key requests.log port > fake.out 2>&1 &
echo $! > pid
i=0
while [ ! -s port ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s port ] || { echo "fake-provider-up: the fake did not start (see $D/fake.out)" >&2; exit 1; }
cat port; echo
