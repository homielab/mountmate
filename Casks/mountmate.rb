cask "mountmate" do
  version "1.4"
  sha256 "a88cca38d4eedc963cd1622c091cfdbb6fcdd73ceaccf1034c41c4adbb2475b5"

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
