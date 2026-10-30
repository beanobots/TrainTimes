# 🚀 Agentic Coding Support for Xcode

This guide shows how to use the Qwen Coding Agent for **actual code modification** in your Xcode projects.

---

## ⚡ Quick Start (3 Steps)

### Step 1: Copy Agent to Your Project

```bash
cd /Users/benwilsker/Projects/YourXcodeProjectName

# Copy the agent
cp -r /Users/benwilsker/Projects/QwenCodingAgent ./

# Make executable
chmod +x QwenCodingAgent/qwen_agent.py

# Verify
ls -la QwenCodingAgent/
```

### Step 2: Start LM Studio Server

1. Open **LM Studio** app
2. Go to **Server** tab (🔌 icon)
3. Select your Qwen model
4. Click **Start Server** (green button)

### Step 3: Use the Agent

#### Option A: Interactive Mode (Recommended)
```bash
cd /Users/benwilsker/Projects/YourXcodeProjectName/QwenCodingAgent

# Start interactive coding session
python3 qwen_agent.py interactive
```

Then type commands like:
- `review ViewController.swift` - Review code
- `fix AppDelegate.swift` - Fix issues (auto-modifies file)
- `optimize NetworkManager.swift` - Optimize code (auto-modifies)
- `generate-tests ViewController.swift` - Generate tests
- `explain UserService.swift` - Explain what code does

#### Option B: One-off Commands

```bash
# Review a file
python3 qwen_agent.py review ViewController.swift

# Fix issues in a file (auto-modifies)
python3 qwen_agent.py fix AppDelegate.swift

# Optimize code (auto-modifies)
python3 qwen_agent.py optimize NetworkManager.swift

# Generate unit tests (creates new file)
python3 qwen_agent.py generate-tests ViewController.swift

# Explain code
python3 qwen_agent.py explain UserService.swift

# Refactor for better structure (auto-modifies)
python3 qwen_agent.py refactor ViewController.swift "Improve separation of concerns"

# Process multiple files
python3 qwen_agent.py batch .  # All Swift files in project
```

---

## 📋 Command Reference

| Command | What It Does | Modifies Files? |
|---------|--------------|-----------------|
| `review <file>` | Review code and provide feedback | ❌ No |
| `fix <file>` | Fix issues in file | ✅ Yes (auto-modifies) |
| `optimize <file>` | Optimize for performance | ✅ Yes (auto-modifies) |
| `generate-tests <file>` | Generate unit tests | ✅ Yes (creates new file) |
| `explain <file>` | Explain what code does | ❌ No |
| `refactor <file> [goal]` | Refactor code structure | ✅ Yes (auto-modifies) |
| `batch <directory>` | Process multiple files | ✅ Yes (modifies all) |

---

## 🎯 Integration with Xcode Build Process

### Add to Build Phases (Optional)

If you want the agent to run during builds:

1. In Xcode, select your **TARGET** (blue icon 🎯)
2. Go to **Build Phases** tab
3. Click **+ → New Run Script Phase**
4. Rename to "Qwen Code Agent"

Paste this script:

```bash
#!/bin/bash

# Ensure Python and requests are available
python3 -c "import requests" 2>/dev/null || pip3 install requests

# Check LM Studio server
if ! curl -s http://localhost:1234/health > /dev/null 2>&1; then
    echo "⚠️  LM Studio server not running"
    exit 0
fi

# Review main Swift files (modify paths as needed)
python3 "${SRCROOT}/QwenCodingAgent/qwen_agent.py" review "${SRCROOT}/ViewController.swift" > /tmp/qwen_review.txt

# Or fix issues automatically (uncomment to enable):
# python3 "${SRCROOT}/QwenCodingAgent/qwen_agent.py" fix "${SRCROOT}/ViewController.swift"

# Display results
cat /tmp/qwen_review.txt 2>/dev/null || echo "No review generated"

exit 0
```

---

## 💡 Advanced Usage

### Create Custom Commands

Edit `qwen_agent.py` to add your own commands:

```python
def my_custom_command(file_path: str) -> str:
    """Your custom code analysis."""
    content = read_file(file_path)
    
    prompt = f"""Analyze this code and provide custom feedback:

{content}

Return your analysis here."""
    
    return call_qwen(prompt)
```

### Batch Process Your Entire Project

```bash
# Review all Swift files in project (limit to 20)
python3 qwen_agent.py batch .

# Fix issues in all Swift files (be careful!)
python3 qwen_agent.py batch . --mode fix

# Generate tests for all files
python3 qwen_agent.py batch . --mode generate-tests
```

### Configure Model Parameters

Edit `qwen_agent.py` lines 15-16:

```python
LM_STUDIO_URL = "http://localhost:1234"  # Your server URL
MODEL_NAME = "qwen"  # or your actual model name

# Adjust max_tokens for longer responses (default: 2048)
```

### Save Results to Project

Add this to your workflow:

```bash
# Create results directory
mkdir -p QwenCodingAgent/results

# Save review to file
python3 qwen_agent.py review ViewController.swift > "QwenCodingAgent/results/ViewController_review.txt"

# Save all batch results
python3 qwen_agent.py batch . > "QwenCodingAgent/results/batch_review.txt"
```

---

## 🔧 Troubleshooting

| Issue | Solution |
|-------|----------|
| "Connection refused" | Start LM Studio server first |
| "File not found" | Check file path is correct |
| Python errors | `pip3 install requests` |
| Model not found | Verify model name in LM Studio |
| Code doesn't compile after fix | Review changes manually before committing |

---

## 📖 Example Session

```bash
$ python3 qwen_agent.py interactive

🤖 Qwen Coding Agent - Interactive Mode
==================================================
Commands:
  review <file>     - Review code
  fix <file>        - Fix issues in file
  optimize <file>   - Optimize code
  generate-tests <file> - Generate tests
  explain <file>    - Explain code
  refactor <file>   - Refactor code
  batch <dir>       - Process multiple files
  quit/exit         - Exit

📝 Enter command: review ViewController.swift

✅ Review complete! Here are the issues found...

📝 Enter command: fix ViewController.swift
Issues to fix (comma-separated, or press Enter for all): 

✅ Fixed code saved to ViewController.swift

📝 Enter command: generate-tests ViewController.swift

✅ Tests generated and saved to ViewController_Tests.swift

📝 Enter command: quit
👋 Goodbye!
```

---

## ✅ Summary Checklist

- [ ] LM Studio server running (Server tab → Start Server)
- [ ] Agent copied to project root (`QwenCodingAgent/`)
- [ ] Python 3.8+ with requests library installed
- [ ] Test agent on a single file first
- [ ] Review changes before committing to production

---

**Need help?** Let me know what you're trying to accomplish!
