cask "mountmate" do
  version "1.7"
  sha256 "15c8eaea34086804a37c27edcd59d2c0522c9134290b8d5cb9b142e8aac0dd97"

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
