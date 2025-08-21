cask "mountmate" do
  version "4.1"
  sha256 "8231fec5eeddb615a18984a1cb32a646cf4f019aa082b00aad8e23802ec7f8b4"

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
