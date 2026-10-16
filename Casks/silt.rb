# Homebrew cask for Silt.
#
# This repo doubles as its own tap: Homebrew accepts an explicit URL, so no
# second `homebrew-silt` repo is needed as long as Casks/ sits at the root.
#
#   brew tap Gloumi/silt https://github.com/Gloumi/silt
#   brew install --cask silt
#
# While the app is unsigned, macOS refuses the first launch of what Homebrew
# downloads. `--no-quarantine` used to avoid that; Homebrew 7 rejects it as an
# invalid option, so the README walks people through « Ouvrir quand même »
# instead. Notarisation is the real fix.
#
# Submitting to homebrew-cask proper requires the app to be signed and
# notarised, and the project to have some visible following. Do that once the
# first is working.
#
# `version` and `sha256` are filled in by Scripts/update-cask.sh from the
# published release, so this file is never edited by hand.

cask "silt" do
  version "0.6.0"
  sha256 "269d0972819383d2282b88704750d855a6f43b4ed8c1dbb93d1fa6852f103814"

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
