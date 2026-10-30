#!/bin/bash

# Xcode Build Script - Agentic Coding Support
# This script runs during build and uses the Qwen agent to analyze/modify code

set -e

echo "🔧 Starting Agentic Code Analysis..."
echo ""

# Load environment variables if .env exists
if [ -f ".env" ]; then
  export $(cat .env | xargs)
fi

# Ensure Python and requests are available
python3 -c "import requests" 2>/dev/null || pip3 install requests

# Check if LM Studio server is running
if ! curl -s http://localhost:1234/health > /dev/null 2>&1; then
    echo "⚠️  LM Studio server not running. Please start it in LM Studio app."
    echo "   Skipping code analysis for this build."
    exit 0
fi

# Get the source directory (default to SRCROOT)
SOURCE_DIR="${SRCROOT}"

# Create results directory
RESULTS_DIR="${SRCROOT}/QwenCodingAgent/results"
mkdir -p "$RESULTS_DIR"

echo "📂 Analyzing: $SOURCE_DIR"
echo ""

# Find Swift files to process (excluding Pods, Carthage, etc.)
find "$SOURCE_DIR" -type f \( -name "*.swift" \) \
    ! -path "*/Pods/*" \
    ! -path "*/Carthage/*" \
    ! -path "*/.build/*" \
    ! -path "*/DerivedData/*" \
    2>/dev/null | head -n 10 > /tmp/qwen_files_list.txt

FILE_COUNT=$(wc -l < /tmp/qwen_files_list.txt)

if [ "$FILE_COUNT" -eq 0 ]; then
    echo "⚠️  No Swift files found in $SOURCE_DIR"
    exit 0
fi

echo "📋 Found $FILE_COUNT Swift file(s) to analyze"

# Process each file
SUCCESS_COUNT=0
ERROR_COUNT=0

while IFS= read -r file; do
    if [ -n "$file" ]; then
        echo "📄 Processing: $file"
        
        # Get file content
        FILE_CONTENT=$(cat "$file")
        
        # Call Qwen agent to review code
        RESPONSE=$(python3 "${SRCROOT}/QwenCodingAgent/qwen_agent.py" review "$file" 2>&1 || echo "Could not process file")
        
        # Save review to results directory
        SAFE_NAME=$(basename "$file" | sed 's/\.[^.]*$//')
        echo "$RESPONSE" > "${RESULTS_DIR}/${SAFE_NAME}_review.txt"
        
        ((SUCCESS_COUNT++)) || true
        
        # Small delay to avoid rate limiting
        sleep 0.5
    fi
done < /tmp/qwen_files_list.txt

# Generate summary
echo ""
echo "📊 Analysis Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total files: $FILE_COUNT"
echo "Successful: $SUCCESS_COUNT"
echo "Errors: $ERROR_COUNT"
echo ""

# Copy results to project directory for easy access
echo "📁 Results saved to: $RESULTS_DIR/"

# List all reviews generated
if [ -d "$RESULTS_DIR" ]; then
    echo ""
    echo "📄 Generated reviews:"
    ls -la "$RESULTS_DIR/" | grep "_review.txt" || echo "  No reviews generated"
fi

# Cleanup temp files
rm -f /tmp/qwen_files_list.txt

echo ""
echo "✅ Agentic code analysis complete!"

exit 0
