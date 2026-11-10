# Shared by the scripts in this folder. Sourced, not run: the caller sets HERE to this folder first.

CONFIG_DIR="$HERE/../Config"
LOCAL_CONFIG="$CONFIG_DIR/Local.xcconfig"

die() { print -r -u2 -- "$*"; exit 1; }

# A build value by name: the environment first, then Config/Local.xcconfig, then Config/T3Bot.xcconfig.
# An empty value in Local.xcconfig counts (it is how a default is switched off).
setting() {
  local name=$1 file
  if [[ -n ${(P)name:-} ]]; then
    print -r -- "${(P)name}"
    return 0
  fi
  for file in "$LOCAL_CONFIG" "$CONFIG_DIR/T3Bot.xcconfig"; do
    [[ -r $file ]] || continue
    if grep -q "^${name}[[:space:]]*=" "$file"; then
      sed -n "s/^${name}[[:space:]]*=[[:space:]]*//p" "$file" | sed 's/[[:space:]]*$//' | tail -1
      return 0
    fi
  done
  return 0
}

# Rewrites Config/Local.xcconfig: every line that sets one of the given names is dropped, the lines read
# from standard input are added, and everything else in the file is kept. The file holds the server token,
# so it is only readable by its owner.
rewrite_local_config() {
  local pattern="^(${(j:|:)@})[[:space:]]*=" tmp
  mkdir -p "$CONFIG_DIR"
  tmp=$(mktemp "$CONFIG_DIR/.local.XXXXXX")
  {
    if [[ -r $LOCAL_CONFIG ]]; then
      grep -v -E "$pattern" "$LOCAL_CONFIG" || true
    else
      print -r -- "// Build values for this checkout only. Not committed. Written by ios/scripts."
    fi
    cat
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$LOCAL_CONFIG"
}
