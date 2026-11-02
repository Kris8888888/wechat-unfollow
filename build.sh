#!/bin/bash
set -e
cd "$(dirname "$0")"
swiftc -O -swift-version 5 -o bin/wxunf src/core.swift src/parse.swift src/list.swift src/jobs.swift src/main.swift
echo "编译完成: bin/wxunf"
