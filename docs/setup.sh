#!/bin/bash
# Setup script to initialize Hugo documentation site

echo "Setting up Hugo documentation site..."

# Check if Hugo is installed
if ! command -v hugo &> /dev/null; then
    echo "Hugo is not installed. Installing..."
    
    # Detect OS and install Hugo
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "Installing Hugo on Linux..."
        sudo snap install hugo || sudo apt-get install hugo -y
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "Installing Hugo on macOS..."
        brew install hugo
    else
        echo "Please install Hugo manually from https://gohugo.io/installation/"
        exit 1
    fi
fi

# Verify Hugo installation
hugo version

# Clone Hugo Book theme
echo "Installing Hugo Book theme..."
if [ ! -d "themes/hugo-book" ]; then
    git clone https://github.com/alex-shpak/hugo-book themes/hugo-book
    echo "Theme installed successfully"
else
    echo "Theme already installed"
fi

# Build the site
echo "Building documentation site..."
hugo --minify

echo ""
echo "Setup complete!"
echo ""
echo "To view the documentation locally, run:"
echo "  hugo server -D"
echo ""
echo "Then open http://localhost:1313 in your browser"
