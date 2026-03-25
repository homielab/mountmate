cask "mountmate" do
  version "5.5"
  sha256 "4c3b0e5ae32e06799eea4b63ec3f17d94b905910e2f215c930af55985ef0ca60"

  url "https://github.com/homielab/mountmate/releases/download/v#{version}/MountMate_#{version}.dmg",
      verified: "github.com/homielab/mountmate/"
  name "MountMate"
  desc "Menubar app to easily manage external drives"
  homepage "https://homielab.com/page/mountmate"

  livecheck do
    url "https://homielab.github.io/mountmate/appcast.xml"
    strategy :sparkle, &:title
  end

  auto_updates true
  depends_on macos: ">= :ventura"

  app "MountMate.app"

  zap trash: "~/Library/Preferences/com.homielab.mountmate.plist"
end
