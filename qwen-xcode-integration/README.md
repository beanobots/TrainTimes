# Qwen Xcode Integration

This folder contains tools to integrate the Qwen AI model (running locally via LM Studio) with your Xcode projects.

## Prerequisites

1. **LM Studio** installed and running
2. **Qwen model downloaded** in LM Studio (e.g., `Qwen2.5-7B-Instruct`)
3. **Python 3.8+** installed (for Python client)
4. **requests library** for Python (`pip install requests`)

## Setup Instructions

### Step 1: Start LM Studio Server

1. Open **LM Studio**
2. Go to the **Server** tab (🔌 icon)
3. Select your downloaded Qwen model from the dropdown
4. Click **Start Server** (green button)
5. Verify server is running at `http://localhost:1234`

### Step 2: Configure Environment Variables (Optional)

Create a `.env` file in your Xcode project root:

```bash
LM_STUDIO_URL=http://localhost:1234
QWEN_MODEL=qwen  # or your model name
```

### Step 3: Add to Xcode Build Phases

#### Option A: Using Shell Script (Recommended for Swift/Objective-C)

1. In Xcode, select your target
2. Go to **Build Phases** tab
3. Click **+ → New Run Script Phase**
4. Name it "Qwen Code Analysis"
5. Drag the script above your compilation steps (or at end for post-build)

**Script content:**
```bash
# Load environment variables if .env exists
if [ -f ".env" ]; then
  export $(cat .env | xargs)
fi

# Run Qwen analysis on main source file
python3 "$(dirname "$SCRIPT_PATH")/qwen_api_client.py" "${BUILT_PRODUCTS_DIR}/${INFOPLIST_FILE}" "Build analysis"

# Or use the shell script version:
bash "$(dirname "$SCRIPT_PATH")/qwen_xcode_agent.sh" "${SRCROOT}/YourMainFile.swift" "Swift code analysis"
```

#### Option B: Using Python Client (More flexible)

1. Add **New Run Script Phase** in Build Phases
2. Paste this script:

```bash
# Ensure Python and requests are available
python3 -c "import requests" 2>/dev/null || pip3 install requests

# Run Python-based Qwen analysis
python3 "$(dirname "$SCRIPT_PATH")/qwen_api_client.py" "${SRCROOT}/YourFile.swift" "Code review"
```

### Step 4: Configure Build Triggers (Optional)

You can configure when Qwen runs:

- **Pre-build**: Add before "Compile Sources" for real-time feedback
- **Post-build**: Add after "Copy Bundle Resources" for final analysis
- **Custom target**: Create a separate Xcode target that runs Qwen on demand

## Usage Examples

### Analyze Swift File

```bash
# Using shell script
./qwen_xcode_agent.sh /path/to/YourFile.swift "Swift code optimization"

# Using Python client
python3 qwen_api_client.py /path/to/YourFile.swift "Swift code optimization" output.txt
```

### Analyze Objective-C File

```bash
./qwen_xcode_agent.sh /path/to/YourFile.m "Objective-C code review"
```

### Custom Context

Modify the `CONTEXT` variable in the scripts to specify what you want:
- Code optimization suggestions
- Security vulnerability check
- Performance analysis
- Documentation generation

## Troubleshooting

### "Connection refused" error
- Ensure LM Studio server is running (`http://localhost:1234`)
- Check that your Qwen model is loaded in LM Studio

### "Model not found" error
- Verify the model name matches what you downloaded in LM Studio
- Check `MODEL_NAME` variable in scripts

### Python errors
- Install Python 3.8+ from python.org or Homebrew (`brew install python`)
- Install requests: `pip3 install requests`

### Xcode build script not executing
- Ensure the Run Script phase is positioned correctly in Build Phases
- Check file permissions: `chmod +x qwen_xcode_agent.sh`

## Advanced Configuration

### Custom Temperature/Max Tokens

Edit the scripts to adjust:
```python
"temperature": 0.3,  # Lower = more deterministic
"max_tokens": 2048   # Increase for longer responses
```

### Multiple Files Analysis

Modify the script to loop through multiple source files:
```bash
for file in ${SRCROOT}/*.swift; do
  ./qwen_xcode_agent.sh "$file" "Swift code analysis"
done
```

### Save Results to Log File

Add this line to your script:
```bash
echo "=== $(date) ===" >> /tmp/qwen_build_log.txt
./qwen_xcode_agent.sh "$SOURCE_FILE" "Context" >> /tmp/qwen_build_log.txt
```

## Security Notes

- All processing happens **locally** - no data leaves your machine
- Ensure LM Studio server only listens on localhost (default)
- Don't commit API keys or sensitive code to version control

## Support

For issues with LM Studio, check: https://lmstudio.ai/docs

For Qwen model-specific questions, see: https://qwenlm.github.io/
