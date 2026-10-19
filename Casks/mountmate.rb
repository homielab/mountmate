cask "mountmate" do
  version "6.2"
  sha256 "6894faf4c6c34e3c847035f5e374330da5d1ab1b7011b7dd1ce719fa3c7e5c63"

  url "https://github.com/homielab/mountmate/releases/download/v#{version}/MountMate_#{version}.dmg"
  name "MountMate"
  desc "Menubar app to easily manage external drives"
  homepage "https://homielab.com/en/page/mountmate"

  livecheck do
    url "https://mountmate.homielab.com/appcast.xml"
    strategy :sparkle, &:title
  end

  auto_updates true
  depends_on macos: :ventura

  app "MountMate.app"

  zap trash: "~/Library/Preferences/com.homielab.mountmate.plist"
end
