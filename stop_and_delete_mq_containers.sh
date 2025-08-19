#!/bin/bash

# Script: stop_and_delete_mq_containers.sh
# Purpose: Stop and remove only IBM MQ containers (image=ibmcom/mq)

echo "🔍 Finding IBM MQ containers..."

mq_containers=$(docker ps -a --filter ancestor=ibmcom/mq --format "{{.ID}}")

if [[ -z "$mq_containers" ]]; then
  echo "✅ No IBM MQ containers found."
  exit 0
fi

echo "🛑 Stopping IBM MQ containers..."
echo "$mq_containers" | xargs -r docker stop

echo "🗑 Removing IBM MQ containers..."
echo "$mq_containers" | xargs -r docker rm

echo "✅ All IBM MQ containers have been stopped and removed."