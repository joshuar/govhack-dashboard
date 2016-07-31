#!/bin/bash

echo "Download CSV data..."
curl -L -o /tmp/projects.csv http://2016.hackerspace.govhack.org/projects/csv
echo "Convert to JSON..."
csvjson --stream /tmp/projects.csv > /tmp/projects.json
echo "Index to ES with LS..."
timeout -s TERM 120 /opt/logstash/bin/logstash -f ./logstash/logstash-govhack.conf < /tmp/projects.json
echo "Sleeping 120s zzz"
sleep 120
exec $0
