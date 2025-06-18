cask "mountmate" do
  version "1.3"
  sha256 "6db8e4f223ac880b82dc9623e1c51ce2fd87f7ea96111e1662a91a5372871611"

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
