#!/bin/bash

# Qwen Xcode Setup Script - Multi-File Edition
# This script helps you configure your Xcode project for Qwen integration

set -e

echo "🔧 Setting up Multi-File Qwen Xcode Integration..."
echo ""

# Check if LM Studio is running
echo "📡 Checking LM Studio server..."
if curl -s http://localhost:1234/health > /dev/null 2>&1; then
    echo "✅ LM Studio server is running!"
else
    echo "⚠️  LM Studio server is NOT running."
    echo ""
    echo "Please start LM Studio and start the server:"
    echo "  1. Open LM Studio"
    echo "  2. Go to Server tab (🔌 icon)"
    echo "  3. Select your Qwen model"
    echo "  4. Click Start Server (green button)"
    exit 1
fi

# Check Python and requests
echo ""
echo "🐍 Checking Python..."
if ! command -v python3 &> /dev/null; then
    echo "❌ Python 3 not found. Please install from python.org"
    exit 1
fi

echo "✅ Python 3 is available"

echo ""
echo "📦 Checking requests library..."
if ! python3 -c "import requests" 2>/dev/null; then
    echo "Installing requests library..."
    pip3 install requests
fi

echo "✅ Requests library is available"

# Create .env file if it doesn't exist
if [ ! -f ".env" ]; then
    echo ""
    echo "📝 Creating .env file..."
    cat > .env << 'EOF'
LM_STUDIO_URL=http://localhost:1234
QWEN_MODEL=qwen
EOF
    echo "✅ .env file created"
fi

# Make scripts executable
echo ""
echo "⚙️  Making scripts executable..."
chmod +x qwen_xcode_agent.sh

echo ""
echo "✅ Setup complete!"
echo ""
echo "📋 Usage Options:"
echo ""
echo "1️⃣  Single File Analysis (existing method):"
echo "   python3 qwen_api_client.py <file.swift> [context]"
echo ""
echo "2️⃣  Batch Mode - Analyze entire project:"
echo "   python3 qwen_api_client.py --batch ${SRCROOT}"
echo ""
echo "3️⃣  Dry Run - List files without analyzing:"
echo "   python3 qwen_api_client.py --dry-run ${SRCROOT}"
echo ""
echo "4️⃣  Shell Script - Multi-file analysis:"
echo "   ./qwen_xcode_agent.sh ${SRCROOT} \"Code review\""
echo ""
echo "📖 For more details, see README.md"
