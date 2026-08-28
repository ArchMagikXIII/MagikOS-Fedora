echo "Switch back to the repo quickshell build from the AUR quickshell-git build"

if magikos-pkg-present quickshell-git; then
  # One transaction with --ask 4 so pacman accepts replacing the conflicting
  # quickshell-git package in place; packages depending on quickshell stay
  # satisfied through the provides. quickshell-git is removed as part of the
  # same swap, so no separate drop step is needed.
  sudo pacman -S --noconfirm --ask 4 quickshell
fi
