cask "mountmate" do
  version "3.1"
  sha256 "d28d1bb36d0f76c33f7307fa8a01c2712ab2bd02ed1f8b71a88e77bc80c55280"

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
