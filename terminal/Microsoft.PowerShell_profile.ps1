if (Get-Module -ListAvailable posh-git) { Import-Module posh-git }

# Inline suggestions (needs PSReadLine 2.2+). The plugin predictor turns the completers below into suggestions; it needs PowerShell 7.2+, so 5.1 gets history only.
try {
	$source = 'History'
	if ($PSVersionTable.PSVersion -ge [version]'7.2' -and (Get-Module -ListAvailable CompletionPredictor)) {
		Import-Module CompletionPredictor -ErrorAction Stop
		$source = 'HistoryAndPlugin'
	}
	Set-PSReadLineOption -PredictionSource $source -PredictionViewStyle ListView -ErrorAction Stop
} catch { }

# dotnet
Register-ArgumentCompleter -Native -CommandName dotnet -ScriptBlock {
	param($wordToComplete, $commandAst, $cursorPosition)
	dotnet complete --position $cursorPosition "$commandAst" | ForEach-Object {
		[System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
	}
}

# GitHub CLI
if (Get-Command gh -ErrorAction SilentlyContinue) {
	gh completion -s powershell | Out-String | Invoke-Expression
}

# dev: command names come from bin\dev.ps1 itself
Register-ArgumentCompleter -Native -CommandName dev -ScriptBlock {
	param($wordToComplete, $commandAst, $cursorPosition)
	$script = Get-Command dev.ps1 -CommandType ExternalScript -ErrorAction SilentlyContinue
	if (-not $script) { return }
	$typed = @($commandAst.CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.ToString() })
	if ($wordToComplete) { $typed = @($typed | Select-Object -SkipLast 1) }
	$prefix = (($typed + $wordToComplete) -join ' ')
	& $script.Source complete $prefix | ForEach-Object {
		[System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
	}
}
