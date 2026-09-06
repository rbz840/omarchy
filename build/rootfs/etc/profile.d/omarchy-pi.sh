# Omarchy ARM64 Pi 5 — environment defaults.
# Export OMARCHY_PATH if the Omarchy tree is present at the standard location.

if [[ -d /opt/omarchy/bin ]]; then
  export OMARCHY_PATH=/opt/omarchy
  case ":$PATH:" in
    *":/opt/omarchy/bin:"*) ;;
    *) export PATH="/opt/omarchy/bin:$PATH" ;;
  esac
fi
