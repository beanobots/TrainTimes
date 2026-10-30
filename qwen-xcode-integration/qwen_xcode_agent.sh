#!/bin/bash

# Qwen Xcode Agent - Multi-File Analysis Script
# Analyzes multiple Swift/Objective-C files recursively across the project

set -e

# Configuration
LM_STUDIO_URL="${LM_STUDIO_URL:-http://localhost:1234}"
MODEL_NAME="${QWEN_MODEL:-qwen}"
CONTEXT="${2:-Code analysis and optimization suggestions}"

# Output directory for results
OUTPUT_DIR="/tmp/qwen_analysis_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"

# Find all Swift and Objective-C files (excluding Pods, Carthage, etc.)
find_files() {
    local search_dir="${1:-.}"
    
    # Find Swift files, excluding common third-party directories
    find "$search_dir" -type f \( -name "*.swift" -o -name "*.m" -o -name "*.mm" \) \
        ! -path "*/Pods/*" \
        ! -path "*/Carthage/*" \
        ! -path "*/.build/*" \
        ! -path "*/DerivedData/*" \
        ! -path "*/.git/*" \
        2>/dev/null | sort
}

# Analyze a single file
analyze_file() {
    local source_file="$1"
    local context="${2:-Code analysis}"
    
    if [ ! -f "$source_file" ]; then
        return 0
    fi
    
    echo "📄 Analyzing: $source_file"
    
    # Read source code
    local source_code
    source_code=$(cat "$source_file")
    
    # Create prompt for Qwen
    local prompt="Analyze the following ${source_file##*.} code and provide suggestions for improvements, optimizations, or potential issues:\n\nContext: $context\n\nFile path: $source_file\n\nCode:\n$source_code"
    
    # Call LM Studio's local API
    local response
    response=$(curl -s -X POST "$LM_STUDIO_URL/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"$MODEL_NAME\",
        \"messages\": [
          {\"role\": \"user\", \"content\": \"$prompt\"}
        ],
        \"max_tokens\": 2048,
        \"temperature\": 0.3
      }" | jq -r '.choices[0].message.content' 2>/dev/null || echo "Error: Could not get response from Qwen")
    
    # Save to file
    local output_file="$OUTPUT_DIR/$(basename "$source_file" | sed 's/\.[^.]*$//').analysis.txt"
    echo "$response" > "$output_file"
    
    # Also print to console (optional, can be disabled for large projects)
    echo "✅ Analysis saved to: $output_file"
}

# Main execution
main() {
    local source_dir="${1:-.}"
    
    echo "🔍 Starting multi-file Qwen analysis..."
    echo "📂 Source directory: $source_dir"
    echo "🤖 Model: $MODEL_NAME"
    echo "💬 Context: $CONTEXT"
    echo ""
    
    # Check if LM Studio server is running
    if ! curl -s "$LM_STUDIO_URL/health" > /dev/null 2>&1; then
        echo "❌ Error: LM Studio server is not running at $LM_STUDIO_URL"
        echo "   Please start the server in LM Studio app."
        exit 1
    fi
    
    # Find all relevant source files
    local files
    files=$(find_files "$source_dir")
    
    if [ -z "$files" ]; then
        echo "⚠️  No Swift/Objective-C files found in $source_dir"
        exit 0
    fi
    
    local file_count
    file_count=$(echo "$files" | wc -l)
    
    echo "📋 Found $file_count source file(s)"
    echo ""
    
    # Analyze each file
    local success_count=0
    local error_count=0
    
    while IFS= read -r file; do
        if analyze_file "$file" "$CONTEXT"; then
            ((success_count++)) || true
        else
            ((error_count++)) || true
        fi
        
        # Optional: Add delay to avoid rate limiting
        sleep 0.5
    done <<< "$files"
    
    # Generate summary report
    echo ""
    echo "📊 Analysis Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Total files: $file_count"
    echo "Successful: $success_count"
    echo "Errors: $error_count"
    echo ""
    echo "Results saved to: $OUTPUT_DIR/"
    
    # Create summary file
    cat > "$OUTPUT_DIR/summary.txt" << EOF
Qwen Multi-File Analysis Summary
=================================
Date: $(date)
Source Directory: $source_dir
Model: $MODEL_NAME
Context: $CONTEXT

Total files analyzed: $file_count
Successful analyses: $success_count
Errors: $error_count

Individual analysis files are in this directory.
EOF
    
    echo "✅ Summary saved to: $OUTPUT_DIR/summary.txt"
    
    # Optionally: Keep results forever by moving them to project directory
    if [ -n "$1" ] && [ -d "$1" ]; then
        local project_output_dir="$1/qwen_analysis_results_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$project_output_dir"
        cp "$OUTPUT_DIR"/* "$project_output_dir/" 2>/dev/null || true
        echo "📁 Also copied results to: $project_output_dir"
    fi
    
    # Cleanup temp directory (comment out if you want to keep results)
    rm -rf "$OUTPUT_DIR"
    
    exit 0
}

# Handle different usage patterns:
# - If called with a directory, analyze all files in it
# - If called with specific files, analyze those

if [ $# -eq 0 ]; then
    # No arguments: use current directory
    main "." "$CONTEXT"
elif [ -d "$1" ]; then
    # First argument is a directory
    main "$1" "$CONTEXT"
else
    # Analyze specific files passed as arguments
    echo "📄 Analyzing specific files..."
    for file in "$@"; do
        analyze_file "$file" "$CONTEXT"
    done
fi
