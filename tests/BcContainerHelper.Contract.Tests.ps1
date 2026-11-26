#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Contract tests: every BcContainerHelper command the menu script calls must exist in the installed
# module and accept every parameter name the script passes (including splatted hashtable keys).
# This catches the bug class "parameter does not exist", e.g. -ErrorAction on a function without
# [CmdletBinding()]. Requires BcContainerHelper to be installed; tagged so it can run separately.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module BcContainerHelper -DisableNameChecking -ErrorAction Stop | Out-Null
    $bchNames = @{}
    Get-Command -Module BcContainerHelper | ForEach-Object { $bchNames[$_.Name] = $true }

    $calls = @((Get-MenuScriptAst).FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        Where-Object { $_.GetCommandName() -and $bchNames.ContainsKey($_.GetCommandName()) } |
        ForEach-Object {
            @{
                Command    = $_.GetCommandName()
                Line       = $_.Extent.StartLineNumber
                Parameters = @($_.CommandElements |
                    Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                    ForEach-Object { $_.ParameterName })
            }
        })

    $splats = @(
        @{ Variable = 'publishParams'; Command = 'Publish-BcContainerApp' }
        @{ Variable = 'apiParams';     Command = 'Invoke-BcContainerApi' }
        @{ Variable = 'target';        Command = 'UnInstall-BcContainerApp' }
        @{ Variable = 'target';        Command = 'UnPublish-BcContainerApp' }
    )
}

Describe 'BcContainerHelper contract' -Tag 'BcContainerHelper' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
        Import-Module BcContainerHelper -DisableNameChecking -ErrorAction Stop | Out-Null

        function Get-KnownParameterName {
            param([string] $Command)
            $cmd = Get-Command -Name $Command -Module BcContainerHelper -ErrorAction Stop
            @($cmd.Parameters.Values | ForEach-Object { $_.Name; $_.Aliases })
        }
    }

    It 'finds BcContainerHelper calls in the script' -ForEach @{ Count = $calls.Count } {
        $Count | Should -BeGreaterThan 20
    }

    It 'every command the script calls exists (built-in, BcContainerHelper or defined in the script)' {
        $ast     = Get-MenuScriptAst
        $defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Name })
        $allowed = @('docker')   # external CLI, not a PowerShell command
        $missing = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } |
            Where-Object { $_ } |
            Sort-Object -Unique |
            Where-Object { $defined -notcontains $_ -and $allowed -notcontains $_ -and -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
        $missing | Should -BeNullOrEmpty -Because 'every command must resolve at runtime'
    }

    It '<Command> (line <Line>) accepts all parameters used' -ForEach $calls {
        $known = Get-KnownParameterName -Command $Command
        foreach ($p in $Parameters) {
            $known | Should -Contain $p -Because "the script calls $Command -$p on line $Line"
        }
    }

    It '<Command> accepts every key of the $<Variable> splat' -ForEach $splats {
        $keys = @(Get-SplatKey -Name $Variable)
        $keys.Count | Should -BeGreaterThan 0 -Because "the script should build `$$Variable as a hashtable"
        $known = Get-KnownParameterName -Command $Command
        foreach ($k in $keys) {
            $known | Should -Contain $k -Because "`$$Variable is splatted into $Command"
        }
    }
}
