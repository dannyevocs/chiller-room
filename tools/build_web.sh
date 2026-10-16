#!/bin/bash
# Builds the web page's scene: a signed .riv (web runtimes reject unsigned scripts),
# copied straight into web/ as base64, since artifacts don't serve .riv files.
# Run from anywhere; publish the artifact from web/ afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
~/.rive/bin/rive . --publish
# Split into parts under the artifact's 16 MB per-file limit; the page joins them.
rm -f web/chiller_room.riv.b64.txt web/chiller_room.riv.b64.*.txt
base64 -i build/chiller_room.riv | tr -d '\n' > build/chiller_room.riv.b64
split -b 12000000 build/chiller_room.riv.b64 build/b64part.
i=0
for f in build/b64part.*; do mv "$f" "web/chiller_room.riv.b64.$i.txt"; i=$((i+1)); done
PARTS=$i
# Stamp the page with this build, so browsers fetch the new scene and people can see which one they have.
STAMP=$(date +%Y%m%d-%H%M)
sed -i '' "s/  var BUILD = \"[^\"]*\";/  var BUILD = \"$STAMP\";/; s/  var PARTS = [0-9]*;/  var PARTS = $PARTS;/" web/index.html
echo "build $STAMP"
echo "web/chiller_room.riv.b64.*.txt: $PARTS parts, $(( $(cat web/chiller_room.riv.b64.*.txt | wc -c) / 1024 )) KB"
