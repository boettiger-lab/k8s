#!/bin/bash
# Quick start script to view the documentation

echo "=========================================="
echo "K8s Documentation Quick Start"
echo "=========================================="
echo ""

# Check if Hugo is installed
if ! command -v hugo &> /dev/null; then
    echo "⚠️  Hugo is not installed."
    echo ""
    echo "To install Hugo:"
    echo "  Linux:  sudo snap install hugo"
    echo "  macOS:  brew install hugo"
    echo "  Or run: ./setup.sh"
    echo ""
    exit 1
fi

echo "✓ Hugo is installed: $(hugo version)"
echo ""

# Check if theme is installed
if [ ! -d "themes/hugo-book" ]; then
    echo "📦 Installing Hugo Book theme..."
    git clone https://github.com/alex-shpak/hugo-book themes/hugo-book
    echo "✓ Theme installed"
    echo ""
fi

echo "🚀 Starting Hugo server..."
echo ""
echo "Documentation will be available at:"
echo "  → http://localhost:1313"
echo ""
echo "Press Ctrl+C to stop the server"
echo ""
echo "=========================================="
echo ""

# Start Hugo server
hugo server -D
