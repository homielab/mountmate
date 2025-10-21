cask "mountmate" do
  version "4.3"
  sha256 "1239c651db6cedbcd8043e444381dbedf99d9a232a34fd15bb6dccd444e3f8fd"

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
