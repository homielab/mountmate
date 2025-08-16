cask "mountmate" do
  version "2.0"
  sha256 "0b3162e16293b83d6bf13b8e80f8bbbc12cd3caedd5e981e09a0300635f8ae3a"

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
