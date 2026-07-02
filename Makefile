.PHONY: test

# Run the dependency-free test suite in headless Neovim.
test:
	nvim --headless -u NONE -l tests/run.lua
