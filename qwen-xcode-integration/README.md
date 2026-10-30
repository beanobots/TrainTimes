# Qwen Xcode Integration - Multi-File Edition

This folder contains tools to integrate the Qwen AI model (running locally via LM Studio) with your Xcode projects. **Now supports batch analysis of multiple Swift/Objective-C files across your entire project structure!**

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
QWEN_MODEL=qwen  # or your model name like "Qwen2.5-7B-Instruct-GGUF"
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

# Analyze all Swift files in your project (excluding Pods, Carthage, etc.)
bash "$(dirname "$SCRIPT_PATH")/qwen_xcode_agent.sh" "${SRCROOT}" "Swift code analysis and optimization"

# Or analyze specific files:
bash "$(dirname "$SCRIPT_PATH")/qwen_xcode_agent.sh" "${SRCROOT}/ViewController.swift" "Swift code review"
```

#### Option B: Using Python Client (More flexible)

1. Add **New Run Script Phase** in Build Phases
2. Paste this script:

```bash
# Ensure Python and requests are available
python3 -c "import requests" 2>/dev/null || pip3 install requests

# Batch analyze all Swift files in your project
python3 "$(dirname "$SCRIPT_PATH")/qwen_api_client.py" --batch "${SRCROOT}" "Code review and optimization suggestions"

# Or analyze specific files:
python3 "$(dirname "$SCRIPT_PATH")/qwen_api_client.py" "${SRCROOT}/ViewController.swift" "Swift code review"
```

### Step 4: Configure Build Triggers (Optional)

You can configure when Qwen runs:

- **Pre-build**: Add before "Compile Sources" for real-time feedback
- **Post-build**: Add after "Copy Bundle Resources" for final analysis
- **Custom target**: Create a separate Xcode target that runs Qwen on demand

## Usage Examples

### Single File Analysis (Existing Method)

```bash
# Using Python client
python3 qwen_api_client.py /path/to/YourFile.swift "Swift code optimization"

# Using shell script
./qwen_xcode_agent.sh /path/to/YourFile.swift "Swift code analysis"

# Using shell script with output file
python3 qwen_api_client.py /path/to/YourFile.swift "Swift code optimization" output.txt
```

### Batch Mode - Analyze Entire Project (NEW!)

```bash
# Python client - analyze all Swift files in project directory
python3 qwen_api_client.py --batch /path/to/your/project "Code review and optimization"

# This will:
# - Recursively find all .swift, .m, and .mm files
# - Exclude Pods/, Carthage/, .build/, DerivedData/, .git/ directories
# - Analyze each file with Qwen
# - Save results to timestamped folder in /tmp/
# - Generate summary report

# Dry run - list files without analyzing (for testing)
python3 qwen_api_client.py --dry-run /path/to/your/project

# Or specify custom file extensions
python3 qwen_api_client.py --dry-run /path/to/your/project "*.swift,*.m"
```

### Shell Script - Multi-File Analysis (NEW!)

```bash
# Analyze all files in project directory
./qwen_xcode_agent.sh /path/to/your/project "Swift code analysis"

# Analyze specific files
./qwen_xcode_agent.sh /path/to/file1.swift "/path/to/file2.m" "Code review"

# Results are saved to /tmp/qwen_analysis_YYYYMMDD_HHMMSS/ directory
```

### Custom Context Examples

Modify the `CONTEXT` variable to specify what you want:

- Code optimization suggestions
- Security vulnerability check
- Performance analysis
- Documentation generation
- Unit test recommendations
- Code style review

## Advanced Configuration

### Custom Temperature/Max Tokens

Edit the scripts to adjust:
```python
"temperature": 0.3,  # Lower = more deterministic (0-1)
"max_tokens": 2048   # Increase for longer responses
```

### Exclude Specific Directories

The scripts automatically exclude: `Pods/`, `Carthage/`, `.build/`, `DerivedData/`, `.git/`

To add custom exclusions, modify the `exclude_dirs` parameter in `find_source_files()` function.

### Save Results to Project Directory

Results are automatically copied to your project's `qwen_analysis_results/` folder for easy access.

### Custom Output Directory

```bash
python3 qwen_api_client.py --batch /path/to/project \
  --output-dir /custom/path/results/ \
  "Code analysis"
```

## Batch Mode Features (NEW!)

### Automatic File Discovery

- Recursively searches all subdirectories
- Finds `.swift`, `.m`, and `.mm` files by default
- Excludes third-party dependencies (Pods, Carthage, etc.)

### Per-File Analysis Results

Each file gets its own analysis saved as:
```
/tmp/qwen_analysis_YYYYMMDD_HHMMSS/
  ViewController.analysis.txt
  AppDelegate.analysis.txt
  ...
```

### Summary Report

Automatically generates `summary.txt` with:
- Total files analyzed
- Successful analyses count
- Error details for failed files
- Timestamp and configuration info

### Dry Run Mode

List all discoverable files without actually analyzing them:
```bash
python3 qwen_api_client.py --dry-run /path/to/project
```

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

### No files found in batch mode
- Verify your project has Swift/Objective-C files
- Check that files aren't in excluded directories (Pods, Carthage, etc.)

## Security Notes

- All processing happens **locally** - no data leaves your machine
- Ensure LM Studio server only listens on localhost (default)
- Don't commit API keys or sensitive code to version control

## File Structure

```
qwen-xcode-integration/
├── qwen_api_client.py      # Python client (supports batch mode)
├── qwen_xcode_agent.sh     # Shell script (multi-file support)
├── setup_xcode.sh          # Setup helper script
└── README.md               # This documentation
```

## Support

For issues with LM Studio, check: https://lmstudio.ai/docs

For Qwen model-specific questions, see: https://qwenlm.github.io/
