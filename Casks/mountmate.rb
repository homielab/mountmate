cask "mountmate" do
  version "1.6"
  sha256 "44e569005874e00291147c528b177e4e2b410e26680fe1328c6f48b5066550a3"

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
