# 🚀 MountMate

_A simple macOS menu bar app to manage your external drives._

<p align="center">
  <img src="https://raw.githubusercontent.com/homielab/mountmate/main/docs/assets/icon.png" alt="MountMate Icon" width="100" height="100" style="border-radius: 22%; border: 0.5px solid rgba(0,0,0,0.1);" />
</p>

<p align="center">
  <a href="https://github.com/homielab/mountmate/releases">
    <img src="https://img.shields.io/github/v/release/homielab/mountmate?label=release&style=flat-square" />
  </a>
  <a href="https://github.com/homielab/mountmate">
    <img src="https://img.shields.io/github/downloads/homielab/mountmate/total?style=flat-square" />
  </a>
  <a href="https://brew.sh">
    <img src="https://img.shields.io/badge/homebrew-supported-blue?style=flat-square" />
  </a>
</p>

---

## ⚡️ Quick Start

Install via [Homebrew](https://brew.sh):

```bash
brew tap homielab/mountmate https://github.com/homielab/mountmate
brew install --cask mountmate
```

Or [download the latest .dmg](https://github.com/homielab/mountmate/releases) and drag MountMate.app into your Applications folder.

## 🧩 What is MountMate?

MountMate is a lightweight macOS menu bar utility that lets you **mount and unmount external drives with a single click** – no Terminal, no Disk Utility, no hassle.

Whether you're dealing with a noisy spinning HDD or want finer control over when your drives are active, MountMate gives you a clean, no-nonsense solution right from your menu bar.

## 🧠 Why I Built It

I have a 4TB external HDD plugged into my Mac mini 24/7. Since it's a spinning drive, macOS constantly spins it up – just for trivial things like opening Finder or running Spotlight. That meant:

- Unwanted noise
- System slowdowns
- Wasted energy

I tried:

- Disk Utility – too slow and clunky
- Custom shell scripts – too technical
- Existing third-party apps – too bloated or didn’t work right

So I built **MountMate**.

## ✅ Features

- View all connected **external drives**
- See which ones are **mounted**
- **Mount/unmount** any drive with a click
- Check available **free space**
- Runs quietly in the **menu bar**
- Fully native – no Electron, no dependencies

## ✨ Why Use MountMate?

macOS automatically mounts drives when they’re plugged in – but gives you **no easy way to remount them later** unless you use Terminal or Disk Utility. MountMate is perfect for:

- External HDDs you don’t always need
- Drives used only for backup
- Reducing wear and tear or noise
- Improving system responsiveness

## 🔐 Private, Fast, and Safe

MountMate runs **entirely offline**, using native macOS APIs and command-line tools. It:

- Does **not** track anything
- Does **not** require connect to the internet
- Does **not** access your files
- Does **not** require root permissions

Just a clean utility that does one job well.

## 🖼️ Screenshots

<img src="https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/light.png" width="300" /><img src="https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/dark.png" width="300" />

![Full Screenshot](https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/light-full.png)

## 🛠️ Installation

### Manual Installation

1. [Download the latest `.dmg` release](https://github.com/homielab/mountmate/releases)
2. Open the `.dmg` file
3. Drag `MountMate.app` into the **Applications** folder
4. Eject the installer disk image
5. Launch MountMate from **Applications**

### Install via Homebrew

If you have [Homebrew](https://brew.sh) installed, you can install MountMate directly from this repository:

```bash
brew tap homielab/mountmate https://github.com/homielab/mountmate
brew install --cask mountmate
```

### First-Time Use on macOS

- If you see a warning that MountMate is from an unidentified developer, go to:  
  **System Settings → Privacy & Security → Open Anyway**
- Make sure you're connected to the internet to allow macOS to verify the app and receive updates

## 📫 Feedback & Contributions

MountMate was built to solve my personal workflow issue, but I’d love to improve it for others too.
Feel free to [open an issue](https://github.com/homielab/mountmate/issues) or suggest improvements!

## 🤝 Support

If you found MountMate helpful, please consider supporting its development:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/homielab)
