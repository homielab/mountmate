cask "mountmate" do
  version "4.0"
  sha256 "bcd70eac156b98f1b9874c8271ae60a7f55d176b25876ca0c90489ddbcfc3bda"

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
