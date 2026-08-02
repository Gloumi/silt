# Homebrew cask for Strata.
#
# Two ways to publish it. To offer `brew install --cask strata` straight away,
# host this as a tap — a repo named `homebrew-strata` containing this file under
# Casks/ — and users run:
#
#   brew tap <user>/strata
#   brew install --cask strata
#
# Submitting to homebrew-cask proper requires the app to be signed and
# notarised, and the project to have some visible following. Do that once the
# first is working.
#
# `version` and `sha256` are filled in by Scripts/update-cask.sh from the
# published release, so this file is never edited by hand.

cask "strata" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/USER/strata/releases/download/v#{version}/Strata-#{version}.dmg"
  name "Strata"
  desc "Disk space analyser with sunburst and treemap views"
  homepage "https://github.com/USER/strata"

  depends_on macos: ">= :sequoia"

  app "Strata.app"

  # Strata needs Full Disk Access, which the user grants in System Settings.
  # It is not something a cask can request, so it is only mentioned here.
  caveats <<~EOS
    Strata needs Full Disk Access to scan your whole Mac:

      System Settings › Privacy & Security › Full Disk Access

    The app explains this on first launch. Without it, protected folders
    (Mail, Messages, Photos, device backups) are reported as unreadable and
    excluded from the totals.
  EOS

  zap trash: [
    "~/Library/Preferences/app.strata.mac.plist",
    "~/Library/Saved Application State/app.strata.mac.savedState",
  ]
end
