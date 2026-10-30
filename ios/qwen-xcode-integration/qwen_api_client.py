#!/usr/bin/env python3

"""
Qwen API Client for Xcode Integration
This script provides a Python-based interface to communicate with LM Studio's local Qwen server.
"""

import json
import sys
import os
from typing import Optional

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
        f"Context: {context}\n\nCode:\n{source_code}"
    )

    # Call LM Studio API
    payload = {
        "model": MODEL_NAME,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.7,
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


def main():
    """Main entry point for command-line usage."""
    if len(sys.argv) < 2:
        print("Usage: python qwen_api_client.py <source_file> [context]")
        sys.exit(1)

    source_file = sys.argv[1]
    context = sys.argv[2] if len(sys.argv) > 2 else "Code analysis"

    try:
        analysis = analyze_code(source_file, context)
        print(analysis)

        # Save to file if requested
        output_file = sys.argv[3] if len(sys.argv) > 3 else None
        if output_file:
            with open(output_file, "w", encoding="utf-8") as f:
                f.write(analysis)

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
