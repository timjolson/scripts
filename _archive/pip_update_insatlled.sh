#!/bin/bash

pip list --outdated --format=columns | tail -n +3 | awk '{print $1}' | xargs -n1 pip install -U
