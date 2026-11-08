cask "agterm" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/neelsatyavolu/agterm/releases/download/v#{version}/agterm-#{version}.zip"
  name "agterm"
  desc "Terminal for coding agents"
  homepage "https://agterm.xanom.co"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "agterm.app"

  zap trash: [
    "~/Library/Application Support/co.xanom.agterm",
    "~/Library/Caches/co.xanom.agterm",
    "~/Library/HTTPStorages/co.xanom.agterm",
    "~/Library/Preferences/co.xanom.agterm.plist",
    "~/Library/Saved Application State/co.xanom.agterm.savedState",
  ]
end
