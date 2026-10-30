#!/usr/bin/env python3

"""
Qwen API Client for Xcode Integration - Multi-File Version
This script provides a Python-based interface to communicate with LM Studio's local Qwen server.
Supports batch processing of multiple Swift/Objective-C files across folder structures.
"""

import json
import sys
import os
from typing import Optional, List
from datetime import datetime
import fnmatch

# Configuration
LM_STUDIO_URL = os.environ.get("LM_STUDIO_URL", "http://localhost:1234")
MODEL_NAME = os.environ.get("QWEN_MODEL", "qwen")


def analyze_code(
    source_file: str,
    context: str = "Code analysis and optimization suggestions",
    max_tokens: int = 1024,
) -> str:
    """
    Analyze source code using Qwen via LM Studio's local API.

    Args:
        source_file: Path to the source code file
        context: Additional context for the analysis
        max_tokens: Maximum tokens to generate

    Returns:
        Analysis response from Qwen
    """
    if not os.path.exists(source_file):
        raise FileNotFoundError(f"Source file not found: {source_file}")

    # Read source code
    with open(source_file, "r", encoding="utf-8") as f:
        source_code = f.read()

    # Create prompt
    prompt = (
        f"Analyze the following {os.path.splitext(source_file)[1].lstrip('.')} code "
        f"and provide suggestions for improvements, optimizations, or potential issues:\n\n"
        f"Context: {context}\n\nFile path: {source_file}\n\nCode:\n{source_code}"
    )

    # Call LM Studio API
    payload = {
        "model": MODEL_NAME,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.3,
    }

    import requests

    response = requests.post(
        f"{LM_STUDIO_URL}/v1/chat/completions",
        headers={"Content-Type": "application/json"},
        json=payload,
    )

    if response.status_code != 200:
        raise Exception(f"API error: {response.status_code} - {response.text}")

    result = response.json()
    return result.get("choices", [{}])[0].get("message", {}).get("content", "")


def find_source_files(
    search_dir: str,
    extensions: List[str] = None,
    exclude_dirs: List[str] = None,
) -> List[str]:
    """
    Recursively find source files in directory structure.

    Args:
        search_dir: Directory to search
        extensions: File extensions to include (default: .swift, .m, .mm)
        exclude_dirs: Directory patterns to exclude

    Returns:
        List of file paths
    """
    if extensions is None:
        extensions = ["*.swift", "*.m", "*.mm"]

    if exclude_dirs is None:
        exclude_dirs = ["Pods", "Carthage", ".build", "DerivedData", ".git"]

    source_files = []

    for root, dirs, files in os.walk(search_dir):
        # Remove excluded directories from traversal
        dirs[:] = [d for d in dirs if not any(fnmatch.fnmatch(d, pattern) for pattern in exclude_dirs)]

        for file in files:
            if any(fnmatch.fnmatch(file, ext) for ext in extensions):
                file_path = os.path.join(root, file)
                source_files.append(file_path)

    return sorted(source_files)


def analyze_batch(
    search_dir: str,
    context: str = "Code analysis and optimization suggestions",
    max_tokens: int = 1024,
    output_dir: str = None,
    dry_run: bool = False,
) -> dict:
    """
    Analyze multiple source files recursively.

    Args:
        search_dir: Directory to search for source files
        context: Analysis context
        max_tokens: Maximum tokens per analysis
        output_dir: Directory to save results (creates timestamped folder)
        dry_run: If True, only list files without analyzing

    Returns:
        Dictionary with analysis results summary
    """
    print("🔍 Starting multi-file Qwen analysis...")
    print(f"📂 Source directory: {search_dir}")
    print(f"🤖 Model: {MODEL_NAME}")
    print(f"💬 Context: {context}")
    print()

    # Check if LM Studio server is running
    import requests
    try:
        response = requests.get(f"{LM_STUDIO_URL}/health", timeout=5)
        if response.status_code != 200:
            raise Exception("Server not responding")
    except Exception as e:
        print(f"❌ Error: LM Studio server is not running at {LM_STUDIO_URL}")
        print(f"   Error: {e}")
        print("   Please start the server in LM Studio app.")
        sys.exit(1)

    # Find all source files
    source_files = find_source_files(search_dir)

    if not source_files:
        print("⚠️  No Swift/Objective-C files found in " + search_dir)
        return {"total": 0, "successful": 0, "errors": 0}

    file_count = len(source_files)
    print(f"📋 Found {file_count} source file(s)")
    print()

    # Create output directory
    if output_dir is None:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_dir = f"/tmp/qwen_analysis_{timestamp}"

    os.makedirs(output_dir, exist_ok=True)

    # Analyze each file
    results = {
        "total": 0,
        "successful": 0,
        "errors": 0,
        "files_analyzed": [],
        "error_files": []
    }

    for file_path in source_files:
        results["total"] += 1
        print(f"📄 Analyzing: {file_path}")

        try:
            analysis = analyze_code(file_path, context, max_tokens)

            # Save to file
            safe_filename = os.path.basename(file_path).rsplit('.', 1)[0] if '.' in os.path.basename(file_path) else os.path.basename(file_path)
            output_file = os.path.join(output_dir, f"{safe_filename}.analysis.txt")

            with open(output_file, "w", encoding="utf-8") as f:
                f.write(analysis)

            results["successful"] += 1
            results["files_analyzed"].append(file_path)
            print(f"✅ Analysis saved to: {output_file}")

        except Exception as e:
            results["errors"] += 1
            results["error_files"].append({"file": file_path, "error": str(e)})
            print(f"❌ Error analyzing {file_path}: {e}")

        # Optional: Add delay to avoid rate limiting
        import time
        time.sleep(0.5)

    # Generate summary report
    print()
    print("📊 Analysis Summary")
    print("=" * 40)
    print(f"Total files: {results['total']}")
    print(f"Successful: {results['successful']}")
    print(f"Errors: {results['errors']}")
    print()
    print(f"Results saved to: {output_dir}/")

    # Create summary file
    summary_file = os.path.join(output_dir, "summary.txt")
    with open(summary_file, "w", encoding="utf-8") as f:
        f.write(f"Qwen Multi-File Analysis Summary\n")
        f.write("=" * 40 + "\n\n")
        f.write(f"Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"Source Directory: {search_dir}\n")
        f.write(f"Model: {MODEL_NAME}\n")
        f.write(f"Context: {context}\n\n")
        f.write(f"Total files analyzed: {results['total']}\n")
        f.write(f"Successful analyses: {results['successful']}\n")
        f.write(f"Errors: {results['errors']}\n\n")

        if results["error_files"]:
            f.write("Error Details:\n")
            for error in results["error_files"]:
                f.write(f"  - {error['file']}: {error['error']}\n")

        f.write("\nIndividual analysis files are in this directory.\n")

    print(f"✅ Summary saved to: {summary_file}")
    print()

    # Optionally copy results to project directory
    if search_dir != output_dir and not dry_run:
        project_output = os.path.join(search_dir, "qwen_analysis_results")
        if not os.path.exists(project_output):
            os.makedirs(project_output)

        for filename in os.listdir(output_dir):
            src = os.path.join(output_dir, filename)
            dst = os.path.join(project_output, filename)
            if os.path.isfile(src):
                import shutil
                shutil.copy2(src, dst)

        print(f"📁 Also copied results to: {project_output}/")

    return results


def main():
    """Main entry point for command-line usage."""
    if len(sys.argv) < 2:
        print("Usage:")
        print("  Single file: python qwen_api_client.py <source_file> [context]")
        print("  Batch mode: python qwen_api_client.py --batch <directory> [context]")
        print("  Dry run: python qwen_api_client.py --dry-run <directory>")
        sys.exit(1)

    # Batch mode
    if sys.argv[1] == "--batch" or sys.argv[1] == "-b":
        if len(sys.argv) < 3:
            print("Error: Batch mode requires a directory path")
            sys.exit(1)

        search_dir = sys.argv[2]
        context = sys.argv[3] if len(sys.argv) > 3 else "Code analysis"

        # Check for dry-run flag
        dry_run = False
        if "--dry-run" in sys.argv or "-d" in sys.argv:
            dry_run = True

        if not os.path.isdir(search_dir):
            print(f"Error: Directory not found: {search_dir}")
            sys.exit(1)

        results = analyze_batch(search_dir, context, dry_run=dry_run)
        sys.exit(0 if results["errors"] == 0 else 1)

    # Dry-run mode (list files only)
    if sys.argv[1] == "--dry-run" or sys.argv[1] == "-d":
        if len(sys.argv) < 3:
            print("Error: Dry-run mode requires a directory path")
            sys.exit(1)

        search_dir = sys.argv[2]
        extensions = ["*.swift", "*.m", "*.mm"]

        if len(sys.argv) > 3:
            # Custom extensions
            extensions = sys.argv[3].split(",")

        files = find_source_files(search_dir, extensions)
        print(f"Found {len(files)} source files in {search_dir}:")
        for f in files:
            print(f"  - {f}")
        sys.exit(0)

    # Single file mode (default)
    source_file = sys.argv[1]
    context = sys.argv[2] if len(sys.argv) > 2 else "Code analysis"
    output_file = sys.argv[3] if len(sys.argv) > 3 else None

    try:
        analysis = analyze_code(source_file, context)
        print(analysis)

        # Save to file if requested
        if output_file:
            with open(output_file, "w", encoding="utf-8") as f:
                f.write(analysis)

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
