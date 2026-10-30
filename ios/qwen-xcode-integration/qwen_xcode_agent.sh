#!/bin/bash

# Qwen Xcode Agent - Build Script Integration
# This script analyzes Swift/Objective-C code and returns suggestions

set -e

# Configuration
LM_STUDIO_URL="${LM_STUDIO_URL:-http://localhost:1234}"
MODEL_NAME="qwen"  # Change to your downloaded model name

# Get the source file from build arguments
SOURCE_FILE="${1:-}"
CONTEXT="${2:-Code analysis and optimization suggestions}"

if [ -z "$SOURCE_FILE" ] || [ ! -f "$SOURCE_FILE" ]; then
    echo "Error: Source file not found or not specified" >&2
    exit 1
fi

# Read source code
SOURCE_CODE=$(cat "$SOURCE_FILE")

# Create prompt for Qwen
PROMPT="Analyze the following ${SOURCE_FILE##*.} code and provide suggestions for improvements, optimizations, or potential issues:\n\nContext: $CONTEXT\n\nCode:\n$SOURCE_CODE"

# Call LM Studio's local API
RESPONSE=$(curl -s -X POST "$LM_STUDIO_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$MODEL_NAME\",
    \"messages\": [
      {\"role\": \"user\", \"content\": \"$PROMPT\"}
    ],
    \"max_tokens\": 1024,
    \"temperature\": 0.7
  }" | jq -r '.choices[0].message.content')

# Output the response
echo "$RESPONSE" > /tmp/qwen_analysis_$(basename "$SOURCE_FILE").txt

# Optionally print to console
echo "Qwen Analysis:"
echo "$RESPONSE"

exit 0
