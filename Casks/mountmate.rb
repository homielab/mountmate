cask "mountmate" do
  version "1.8"
  sha256 "ea4b26f5ff0e9ee351c205ab643621ec8466b29c72a9c675abcc978a3dafa656"

  url "https://github.com/homielab/mountmate/releases/download/v#{version}/MountMate_#{version}.dmg"
  name "MountMate"
  desc "A menubar app to easily manage external drives"
  homepage "https://homielab.com/page/mountmate"

  auto_updates true
  app "MountMate.app"

  zap trash: [
    "~/Library/Preferences/com.homielab.mountmate.plist",
  ]
end
