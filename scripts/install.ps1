# Installs the Haxe debugger for Zed from the latest release of Jarrio/Zed-Haxe-Debug (Windows).
#
#   irm https://github.com/Jarrio/Zed-Haxe-Debug/releases/latest/download/install.ps1 | iex
#
# Quit Zed first, or restart it afterwards. Replaces any installed `haxe-debug` extension, including a
# dev extension (only the link to the dev folder is removed, not the folder).
#
# Environment: HAXE_DEBUG_ARCHIVE (a local package instead of downloading one), ZED_DATA_DIR (Zed's
# data folder, if it isn't the usual one).

# In a script block so that `| iex` leaves the caller's session as it was.
& {
	$ErrorActionPreference = "Stop"
	$ProgressPreference = "SilentlyContinue"

	$repo = "Jarrio/Zed-Haxe-Debug"
	$data = if ($env:ZED_DATA_DIR) { $env:ZED_DATA_DIR } else { Join-Path $env:LOCALAPPDATA "Zed" }
	$extensions = Join-Path $data "extensions"
	$target = Join-Path $extensions "installed\haxe-debug"

	$work = Join-Path ([System.IO.Path]::GetTempPath()) ("haxe-debug-" + [guid]::NewGuid())
	New-Item -ItemType Directory -Path $work | Out-Null
	try {
		$archive = $env:HAXE_DEBUG_ARCHIVE
		if (-not $archive) {
			$archive = Join-Path $work "haxe-debug.tar.gz"
			Write-Host "Downloading the latest release of $repo..."
			Invoke-WebRequest -Uri "https://github.com/$repo/releases/latest/download/haxe-debug.tar.gz" -OutFile $archive -UseBasicParsing
		}

		New-Item -ItemType Directory -Force -Path (Join-Path $extensions "installed") | Out-Null
		if (Test-Path $target) {
			$item = Get-Item $target -Force
			if ($item.LinkType) {
				# A dev extension: remove the link, not the folder it points to.
				$item.Delete()
			} else {
				Remove-Item -Recurse -Force $target
			}
		}
		New-Item -ItemType Directory -Path $target | Out-Null
		# tar ships with Windows 10 and later.
		tar -xzf $archive -C $target
		if ($LASTEXITCODE -ne 0) { throw "could not unpack $archive" }
		# Zed rebuilds this cache on start; a stale one makes it load the old extension first.
		Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $extensions "index.json")

		$version = (Select-String -Path (Join-Path $target "extension.toml") -Pattern '^version = "(.*)"' | Select-Object -First 1).Matches[0].Groups[1].Value
		Write-Host "Installed the Haxe debugger $version into $target"
		Write-Host "Restart Zed if it is running."
		Write-Host "Zed offers Haxe tasks for debugging once your Zed settings have"
		Write-Host '  "languages": { "Haxe": { "debuggers": ["Haxe"] }, "HXML": { "debuggers": ["Haxe"] } }'
	} finally {
		Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work
	}
}
