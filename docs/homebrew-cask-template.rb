# Template for a Homebrew cask (submit to homebrew/cask or a personal tap
# once a signed release exists; --no-quarantine needed while unsigned).
cask "localflow" do
  version "0.1.0"
  sha256 "REPLACE_WITH_RELEASE_ZIP_SHA256"
  url "https://github.com/OWNER/localflow/releases/download/v#{version}/LocalFlow.zip"
  name "LocalFlow"
  desc "Hold a key, speak, release — 100% local AI dictation"
  homepage "https://github.com/OWNER/localflow"
  depends_on macos: ">= :tahoe"
  depends_on arch: :arm64
  app "LocalFlow.app"
end
