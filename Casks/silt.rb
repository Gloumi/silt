# Homebrew cask for Silt.
#
# This repo doubles as its own tap: Homebrew accepts an explicit URL, so no
# second `homebrew-silt` repo is needed as long as Casks/ sits at the root.
#
#   brew tap Gloumi/silt https://github.com/Gloumi/silt
#   brew install --cask --no-quarantine silt
#
# `--no-quarantine` matters while the app is unsigned: without it macOS flags
# the download and refuses the first launch. Drop it once notarisation is in
# place.
#
# Submitting to homebrew-cask proper requires the app to be signed and
# notarised, and the project to have some visible following. Do that once the
# first is working.
#
# `version` and `sha256` are filled in by Scripts/update-cask.sh from the
# published release, so this file is never edited by hand.

cask "silt" do
  version "0.5.0"
  sha256 "cb1c85139d54a141dd5bca5d54a202f67b46806be48f1e6da9d9bf6398219896"

  url "https://github.com/Gloumi/silt/releases/download/v#{version}/Silt-#{version}.dmg"
  name "Silt"
  desc "Disk space analyser with sunburst and treemap views"
  homepage "https://github.com/Gloumi/silt"

  depends_on macos: :sequoia

  app "Silt.app"

  # Silt needs Full Disk Access, which the user grants in System Settings.
  # It is not something a cask can request, so it is only mentioned here.
  caveats <<~EOS
    Silt needs Full Disk Access to scan your whole Mac:

      System Settings › Privacy & Security › Full Disk Access

    The app explains this on first launch. Without it, protected folders
    (Mail, Messages, Photos, device backups) are reported as unreadable and
    excluded from the totals.
  EOS

  zap trash: [
    "~/Library/Preferences/app.silt.mac.plist",
    "~/Library/Saved Application State/app.silt.mac.savedState",
  ]
end
