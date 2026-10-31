#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p fixtures/authorized_keys
if [ ! -f fixtures/id_ed25519 ]; then
  ssh-keygen -q -t ed25519 -a 4 -N amber-it-pass -C amber-docker-test-only -f fixtures/id_ed25519
fi
cp fixtures/id_ed25519.pub fixtures/authorized_keys/jumper
cp fixtures/id_ed25519.pub fixtures/authorized_keys/deploy
chmod 644 fixtures/authorized_keys/*
printf '%s\n' 'Synthetic fixture ready. Import fixtures/id_ed25519 with passphrase amber-it-pass. Never use this key outside local tests.'
