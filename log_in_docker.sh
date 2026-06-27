#!/bin/bash

# Script Name: connect_mq_container.sh
# Purpose: List MQ containers, let user pick one, connect inside.

echo "📦 Available IBM MQ Docker Containers:"
echo "-------------------------------------"

# Get list of running MQ containers (those running ibmcom/mq)
containers=($(docker ps --filter ancestor=ibmcom/mq --format "{{.Names}}"))

if [ ${#containers[@]} -eq 0 ]; then
  echo "❌ No IBM MQ containers running."
  exit 1
fi

# Show numbered list
for i in "${!containers[@]}"; do
  container="${containers[$i]}"
  qmgr_name=$(docker exec "$container" bash -c 'echo $MQ_QMGR_NAME' 2>/dev/null)
  listener_port=$(docker port "$container" 1414 | awk -F':' '{print $2}')
  echo "$((i+1)). Container: $container | QMGR: $qmgr_name | Listener Port: $listener_port"
done

echo "-------------------------------------"
read -p "👉 Enter the number of the container you want to connect to: " choice

# Validate choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#containers[@]}" ]; then
  echo "❌ Invalid choice. Exiting."
  exit 1
fi

selected_container="${containers[$((choice-1))]}"
echo "🔗 Connecting to container: $selected_container ..."
echo ""

# Connect inside
docker exec -it "$selected_container" bash
