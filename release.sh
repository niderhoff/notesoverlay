#!/bin/zsh
# Cut a release: bump version, build, zip, tag, GitHub release, update the cask in the tap.
#   ./release.sh 1.2.0
# Afterwards on any machine:  brew install --cask niderhoff/personal/notesoverlay
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: release.sh X.Y.Z}"
REPO="${REPO:-niderhoff/notesoverlay}"
TAP_DIR="${TAP_DIR:-$(brew --repository)/Library/Taps/niderhoff/homebrew-personal}"
CASK="$TAP_DIR/Casks/notesoverlay.rb"

[ -z "$(git status --porcelain)" ] || { echo "working tree not clean"; exit 1; }
[ -d "$TAP_DIR/.git" ] || { echo "tap not found at $TAP_DIR (brew tap niderhoff/personal)"; exit 1; }

# 1. Version
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Resources/Info.plist

# 2. Build and zip (ditto keeps the bundle's metadata intact)
./build.sh
ZIP="build/NotesOverlay-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent --norsrc build/NotesOverlay.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "built $ZIP  sha256 $SHA"

# 3. Commit, tag, push, GitHub release with the zip attached
git add Resources/Info.plist
git commit -q -m "Release $VERSION"
git tag -a "v$VERSION" -m "NotesOverlay $VERSION"
git push origin HEAD "v$VERSION"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "NotesOverlay $VERSION" --generate-notes

# 4. Cask in the tap
mkdir -p "$(dirname "$CASK")"
cat > "$CASK" <<CASKEOF
cask "notesoverlay" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/NotesOverlay-#{version}.zip"
  name "NotesOverlay"
  desc "Floating Markdown scratchpad with a global hotkey"
  homepage "https://github.com/$REPO"

  depends_on macos: :sonoma

  app "NotesOverlay.app"

  # Ad-hoc signed (no Developer ID): drop the quarantine flag so Gatekeeper lets it run.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-cr", "{{appdir}}/NotesOverlay.app"]
  end

  uninstall quit: "com.niid.NotesOverlay"

  zap trash: "~/Library/Preferences/com.niid.NotesOverlay.plist"
end
CASKEOF
(cd "$TAP_DIR" && git add Casks/notesoverlay.rb && git commit -q -m "notesoverlay $VERSION" && git push)

echo "Released NotesOverlay $VERSION."
echo "Install / upgrade anywhere:  brew install --cask niderhoff/personal/notesoverlay   |   brew upgrade --cask notesoverlay"
