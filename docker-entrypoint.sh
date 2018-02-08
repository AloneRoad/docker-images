#!/bin/bash

touch /var/log/redis/runner.txt
chmod +w /var/log/redis/runner.txt
chmod +x /usr/local/bin/redis-launcher.sh

/usr/local/bin/redis-launcher.sh $@ | tee /var/log/redis/runner.txt
