# 🚀 START HERE - Agentic Coding Support

Welcome! You now have a **real AI coding agent** that can actively help you write, fix, and optimize code in your Xcode projects.

---

## ⚡ Quick Setup (5 Minutes)

### Step 1: Copy Agent to Your Project

```bash
# Navigate to your Xcode project directory (replace with actual path)
cd /Users/benwilsker/Projects/YourXcodeProjectName

# Copy the agent
cp -r /Users/benwilsker/Projects/QwenCodingAgent ./

# Verify it's there
ls -la QwenCodingAgent/
```

### Step 2: Start LM Studio Server ⚠️ (Required!)

1. Open **LM Studio** app
2. Go to the **Server** tab (🔌 icon)
3. Select your downloaded Qwen model from dropdown
4. Click **Start Server** (green button)
5. Wait for "Server started successfully"

### Step 3: Install Python Dependencies

```bash
pip3 install requests
```

### Step 4: Test the Agent

```bash
cd /Users/benwilsker/Projects/YourXcodeProjectName/QwenCodingAgent

# Test with a single file
python3 qwen_agent.py review ViewController.swift

# Or start interactive mode
python3 qwen_agent.py interactive
```

### Step 5: Use in Your Workflow

Now you can use the agent while coding!

---

## 🎯 How to Use (Simplest Method)

### Interactive Mode - Best for Development

```bash
cd /Users/benwilsker/Projects/YourXcodeProjectName/QwenCodingAgent

# Start interactive session
python3 qwen_agent.py interactive
```

Then type commands like:

```
📝 Enter command: review ViewController.swift
✅ Review complete! Here are the issues found...

📝 Enter command: fix AppDelegate.swift
Issues to fix (comma-separated, or press Enter for all): 
✅ Fixed code saved to AppDelegate.swift

📝 Enter command: generate-tests ViewController.swift
✅ Tests generated and saved to ViewController_Tests.swift

📝 Enter command: quit
👋 Goodbye!
```

### One-off Commands - Quick Analysis

```bash
# Review code (read-only)
python3 qwen_agent.py review ViewController.swift

# Fix issues automatically (modifies file!)
python3 qwen_agent.py fix AppDelegate.swift

# Optimize code for performance (modifies file!)
python3 qwen_agent.py optimize NetworkManager.swift

# Generate unit tests (creates new file)
python3 qwen_agent.py generate-tests ViewController.swift

# Explain what code does
python3 qwen_agent.py explain UserService.swift

# Refactor for better structure (modifies file!)
python3 qwen_agent.py refactor ViewController.swift "Improve separation of concerns"

# Process multiple files
python3 qwen_agent.py batch .  # All Swift files in project
```

---

## 📋 Command Reference

| Command | What It Does | Modifies Files? |
|---------|--------------|-----------------|
| `review <file>` | Review code and provide feedback | ❌ No |
| `fix <file> [issues]` | Fix issues in file | ✅ Yes (auto-modifies) |
| `optimize <file>` | Optimize for performance | ✅ Yes (auto-modifies) |
| `generate-tests <file>` | Generate unit tests | ✅ Yes (creates new file) |
| `explain <file>` | Explain what code does | ❌ No |
| `refactor <file> [goal]` | Refactor code structure | ✅ Yes (auto-modifies) |
| `batch <directory>` | Process multiple files | ✅ Yes (modifies all) |

---

## 💡 Integration with Xcode

### Option A: Manual Use (Recommended)

1. Open your project in **Xcode**
2. Press `Cmd + Shift + R` (or open Terminal)
3. Navigate to your project: `cd /path/to/YourProject`
4. Run agent commands while coding

### Option B: Add to Build Phases (Optional)

If you want automatic analysis during builds:

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

## 🎓 Example Workflow

### Daily Development

1. **Code normally in Xcode**
2. **When you want feedback:**
   - Open Terminal (`Cmd + Shift + R`)
   - Navigate to your project: `cd /Users/.../YourProject`
   - Run agent: `python3 QwenCodingAgent/qwen_agent.py review ViewController.swift`
   - Review the feedback and make changes

### Using Interactive Mode

```bash
cd /Users/.../YourProject/QwenCodingAgent

# Start interactive session
python3 qwen_agent.py interactive

# Then type commands:
review ViewController.swift      # Get feedback on current file
fix AppDelegate.swift           # Auto-fix issues (modifies file)
generate-tests ViewController.swift  # Generate tests
explain NetworkManager.swift    # Understand complex code
quit                            # Exit when done
```

### Batch Processing (Weekend Cleanup)

```bash
# Review all Swift files in project
python3 qwen_agent.py batch .

# Or fix issues automatically (be careful!)
python3 qwen_agent.py batch . --mode fix

# Results saved to: YourProject/QwenCodingAgent/results/
```

---

## ✅ Summary Checklist

- [ ] LM Studio server running (Server tab → Start Server)
- [ ] Agent copied to project root (`QwenCodingAgent/`)
- [ ] Python 3.8+ with requests library installed (`pip3 install requests`)
- [ ] Test agent on a single file first before batch operations
- [ ] Review changes before committing to production

---

## 📚 Documentation Files

| File | Purpose |
|------|---------|
| `qwen_agent.py` | Main agent script (all commands) |
| `README.md` | Full documentation with examples |
| `XCODE_INTEGRATION.md` | How to integrate with Xcode |
| `xcode_build_script.sh` | Build script for automatic analysis |
| `START_HERE.md` | This quick start guide |

---

## 🎯 Next Steps

1. **Start LM Studio server** (Server tab → Start Server)
2. **Copy agent to your project**: `cp -r /Users/benwilsker/Projects/QwenCodingAgent ./`
3. **Test with a single file**: `python3 qwen_agent.py review ViewController.swift`
4. **Try interactive mode**: `python3 qwen_agent.py interactive`

---

**Need help?** Let me know what you're trying to accomplish!
