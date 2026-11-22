#!/bin/sh
game_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 1
game=contact-sam-cruise
model=-pal
for arg in "$@"; do
  case "$arg" in
    standard) game=contact-sam-cruise ;;
    stripes) game=contact-sam-cruise-stripes ;;
    pal) model=-pal ;;
    ntsc) model=-ntsc ;;
    -h|--help)
      printf '%s\n' 'Usage: sh play.sh [standard | stripes] [pal | ntsc]' \
        'Set VICE_ROOT to the VICE installation directory or X64SC to the emulator path.'
      exit 0 ;;
    *)
      printf '%s\n' 'Unknown option. Run sh play.sh --help.' >&2
      exit 2 ;;
  esac
done
prg="$game_dir/build/$game.prg"
if [ ! -f "$prg" ]; then
  printf 'Missing %s.prg. Run python tools/build.py first.\n' "$game" >&2
  if [ "$game" = contact-sam-cruise-stripes ]; then
    printf '%s\n' 'Add --stripe-camera to build this variant.' >&2
  fi
  exit 1
fi
if [ -z "${X64SC:-}" ] && [ -n "${VICE_ROOT:-}" ]; then
  for candidate in "$VICE_ROOT/bin/x64sc" "$VICE_ROOT/bin/x64sc.exe" \
    "$VICE_ROOT/x64sc" "$VICE_ROOT/x64sc.exe"; do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
      X64SC=$candidate
      break
    fi
  done
  if [ -z "${X64SC:-}" ]; then
    printf '%s\n' 'x64sc was not found under VICE_ROOT. Check VICE_ROOT or set X64SC.' >&2
    exit 1
  fi
fi
exec "${X64SC:-x64sc}" "$model" -VICIIvsync -autostartprgmode 1 -autostart "$prg"
