#!/bin/sh

sudo docker buildx build --platform linux/amd64 -t linode-valheim-corntab -f Dockerfile .
sudo docker tag linode-valheim-corntab nicjansma/linode-valheim-corntab:latest
