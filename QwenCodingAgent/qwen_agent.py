#!/usr/bin/env python3

"""
Qwen Coding Agent - Agentic Code Assistant
This agent can read, analyze, and MODIFY your code files.

Usage:
    python qwen_agent.py <command> [options]

Commands:
    review <file>          - Review code and suggest improvements
    fix <file>             - Automatically fix issues in file
    optimize <file>        - Optimize code for performance
    generate-tests <file>  - Generate unit tests for file
    explain <file>         - Explain what code does
    refactor <file>        - Refactor code for better structure
    
    batch <directory>      - Analyze/modify multiple files
    interactive            - Start interactive coding session
    
Examples:
    python qwen_agent.py review ViewController.swift
    python qwen_agent.py fix AppDelegate.swift
    python qwen_agent.py optimize .  # All Swift files in project
    python qwen_agent.py interactive  # Interactive mode
"""

import sys
import os
from typing import Optional, List, Dict, Any
from datetime import datetime
import json

# Configuration
LM_STUDIO_URL = os.environ.get("LM_STUDIO_URL", "http://localhost:1234")
MODEL_NAME = os.environ.get("QWEN_MODEL", "qwen")


def read_file(path: str) -> str:
    """Read file contents."""
    if not os.path.exists(path):
        raise FileNotFoundError(f"File not found: {path}")
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write_file(path: str, content: str) -> None:
    """Write content to file."""
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def call_qwen(prompt: str, max_tokens: int = 2048) -> str:
    """Call LM Studio's Qwen API."""
    import requests
    
    payload = {
        "model": MODEL_NAME,
        "messages": [
            {"role": "system", "content": """You are an expert coding agent. 
Your job is to help developers write better code by:
1. Understanding the existing code context
2. Providing actionable suggestions
3. Making actual code changes when requested
4. Following best practices and conventions

Be specific, practical, and provide complete code snippets when making changes."""},
            {"role": "user", "content": prompt}
        ],
        "max_tokens": max_tokens,
        "temperature": 0.3,
    }

    response = requests.post(
        f"{LM_STUDIO_URL}/v1/chat/completions",
        headers={"Content-Type": "application/json"},
        json=payload,
    )

    if response.status_code != 200:
        raise Exception(f"API error: {response.status_code} - {response.text}")

    result = response.json()
    return result.get("choices", [{}])[0].get("message", {}).get("content", "")


def review_code(file_path: str, context: str = None) -> str:
    """Review code and provide feedback."""
    content = read_file(file_path)
    
    prompt = f"""Review the following Swift code and provide detailed feedback:

File: {file_path}
Context: {context or "General code review"}

Code:
{content}

Please provide:
1. Code quality issues and bugs
2. Performance concerns
3. Best practice violations
4. Specific improvement suggestions with code examples"""

    return call_qwen(prompt)


def fix_code(file_path: str, issues: List[str] = None) -> str:
    """Fix issues in code and return modified content."""
    original_content = read_file(file_path)
    
    issues_str = "\n".join(issues) if issues else "General code improvements"
    
    prompt = f"""Fix the following Swift code. Address these issues: {issues_str}

Original Code:
{original_content}

Return ONLY the fixed code with no explanations or markdown. 
Make sure the code compiles and follows Swift best practices."""

    fixed_content = call_qwen(prompt, max_tokens=4096)
    
    # Save the fixed code back to file
    write_file(file_path, fixed_content)
    
    return f"Fixed code saved to {file_path}"


def optimize_code(file_path: str) -> str:
    """Optimize code for performance."""
    original_content = read_file(file_path)
    
    prompt = f"""Optimize this Swift code for performance and efficiency.

Original Code:
{original_content}

Return ONLY the optimized code with no explanations or markdown. 
Focus on:
- Algorithm efficiency
- Memory management
- Concurrency where appropriate
- Swift best practices"""

    optimized_content = call_qwen(prompt, max_tokens=4096)
    
    write_file(file_path, optimized_content)
    
    return f"Optimized code saved to {file_path}"


def generate_tests(file_path: str) -> str:
    """Generate unit tests for the code."""
    content = read_file(file_path)
    
    test_file = file_path.replace(".swift", "_Tests.swift")
    
    prompt = f"""Generate comprehensive unit tests for this Swift code.

Original Code:
{content}

Create a test file that includes:
- Unit tests for all public methods
- Edge case handling
- Mock dependencies where needed
- Follow XCTest best practices

Return ONLY the test code with no explanations or markdown."""

    test_content = call_qwen(prompt, max_tokens=4096)
    
    write_file(test_file, test_content)
    
    return f"Tests generated and saved to {test_file}"


def explain_code(file_path: str) -> str:
    """Explain what the code does."""
    content = read_file(file_path)
    
    prompt = f"""Explain what this Swift code does in detail.

File: {file_path}
Code:
{content}

Please explain:
1. Overall purpose and functionality
2. Key algorithms and logic
3. Data flow and dependencies
4. Any complex or non-obvious parts"""

    return call_qwen(prompt)


def refactor_code(file_path: str, goal: str = None) -> str:
    """Refactor code for better structure."""
    original_content = read_file(file_path)
    
    goal_str = goal or "Improve code structure and maintainability"
    
    prompt = f"""Refactor this Swift code to {goal_str}.

Original Code:
{original_content}

Return ONLY the refactored code with no explanations or markdown. 
Focus on:
- Better organization and structure
- Separation of concerns
- Follow SOLID principles
- Improve readability"""

    refactored_content = call_qwen(prompt, max_tokens=4096)
    
    write_file(file_path, refactored_content)
    
    return f"Refactored code saved to {file_path}"


def interactive_mode():
    """Start interactive coding session."""
    print("🤖 Qwen Coding Agent - Interactive Mode")
    print("=" * 50)
    print("Commands:")
    print("  review <file>     - Review code")
    print("  fix <file>        - Fix issues in file")
    print("  optimize <file>   - Optimize code")
    print("  generate-tests <file> - Generate tests")
    print("  explain <file>    - Explain code")
    print("  refactor <file>   - Refactor code")
    print("  batch <dir>       - Process multiple files")
    print("  quit/exit         - Exit")
    print("=" * 50)
    
    while True:
        try:
            user_input = input("\n📝 Enter command: ").strip()
            
            if not user_input or user_input.lower() in ["quit", "exit"]:
                print("👋 Goodbye!")
                break
            
            parts = user_input.split(maxsplit=1)
            command = parts[0].lower()
            args = parts[1] if len(parts) > 1 else None
            
            if command == "review" and args:
                print(review_code(args))
            
            elif command == "fix" and args:
                issues = input("Issues to fix (comma-separated, or press Enter for all): ").strip()
                issues_list = [i.strip() for i in issues.split(",")] if issues else None
                print(fix_code(args, issues_list))
            
            elif command == "optimize" and args:
                print(optimize_code(args))
            
            elif command == "generate-tests" and args:
                print(generate_tests(args))
            
            elif command == "explain" and args:
                print(explain_code(args))
            
            elif command == "refactor" and args:
                goal = input("Refactoring goal (or press Enter for default): ").strip() or None
                print(refactor_code(args, goal))
            
            elif command == "batch" and args:
                print(batch_process(args, mode="analyze"))
            
            else:
                print("❌ Unknown command. Type 'help' for commands.")
                
        except KeyboardInterrupt:
            print("\n👋 Exiting...")
            break
        except Exception as e:
            print(f"❌ Error: {e}")


def batch_process(directory: str, mode: str = "analyze") -> str:
    """Process multiple files in directory."""
    print(f"🔍 Processing directory: {directory}")
    
    # Find Swift files
    swift_files = []
    for root, dirs, files in os.walk(directory):
        # Skip excluded directories
        dirs[:] = [d for d in dirs if d not in ["Pods", "Carthage", ".build", "DerivedData"]]
        
        for file in files:
            if file.endswith(".swift"):
                swift_files.append(os.path.join(root, file))
    
    print(f"📋 Found {len(swift_files)} Swift files")
    
    results = []
    for file_path in swift_files[:20]:  # Limit to first 20 files
        try:
            if mode == "analyze":
                result = review_code(file_path)
                results.append(f"✓ {file_path}: Reviewed")
            else:
                result = fix_code(file_path)
                results.append(f"✓ {file_path}: Fixed")
        except Exception as e:
            results.append(f"✗ {file_path}: Error - {str(e)}")
    
    return f"\nProcessed {len(results)} files:\n" + "\n".join(results[:10])


def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    
    command = sys.argv[1].lower()
    
    if command == "interactive":
        interactive_mode()
    
    elif command == "review" and len(sys.argv) >= 3:
        print(review_code(sys.argv[2]))
    
    elif command == "fix" and len(sys.argv) >= 3:
        issues = sys.argv[3].split(",") if len(sys.argv) >= 4 else None
        print(fix_code(sys.argv[2], issues))
    
    elif command == "optimize" and len(sys.argv) >= 3:
        print(optimize_code(sys.argv[2]))
    
    elif command == "generate-tests" and len(sys.argv) >= 3:
        print(generate_tests(sys.argv[2]))
    
    elif command == "explain" and len(sys.argv) >= 3:
        print(explain_code(sys.argv[2]))
    
    elif command == "refactor" and len(sys.argv) >= 3:
        goal = sys.argv[3] if len(sys.argv) >= 4 else None
        print(refactor_code(sys.argv[2], goal))
    
    elif command == "batch" and len(sys.argv) >= 3:
        print(batch_process(sys.argv[2]))
    
    else:
        print("❌ Invalid command. Use --help for usage.")
        sys.exit(1)


if __name__ == "__main__":
    main()
