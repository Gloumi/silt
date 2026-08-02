# Homebrew cask for Silt.
#
# Two ways to publish it. To offer `brew install --cask silt` straight away,
# host this as a tap — a repo named `homebrew-silt` containing this file under
# Casks/ — and users run:
#
#   brew tap <user>/silt
#   brew install --cask silt
#
# Submitting to homebrew-cask proper requires the app to be signed and
# notarised, and the project to have some visible following. Do that once the
# first is working.
#
# `version` and `sha256` are filled in by Scripts/update-cask.sh from the
# published release, so this file is never edited by hand.

cask "silt" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/USER/silt/releases/download/v#{version}/Silt-#{version}.dmg"
  name "Silt"
  desc "Disk space analyser with sunburst and treemap views"
  homepage "https://github.com/USER/silt"

  depends_on macos: ">= :sequoia"

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
