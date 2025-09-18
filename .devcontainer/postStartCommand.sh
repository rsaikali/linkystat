#!/bin/bash
/app/scripts/sync_dev_db.sh
nohup bash -c 'python /app/src/linky2db.py &'