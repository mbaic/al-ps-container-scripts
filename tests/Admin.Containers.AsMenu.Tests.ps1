#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Unit tests for the pure logic of Admin.Containers.AsMenu.ps1.
# No container, Docker or BcContainerHelper is needed: see TestHelpers.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Get-MenuScriptFunctionBlock)
}

Describe 'Script structure' {
    BeforeAll {
        $scriptText = [System.IO.File]::ReadAllText($MenuScriptPath)
        $ast        = Get-MenuScriptAst
        $functions  = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Name })
        $menuItems  = @([regex]::Matches($scriptText, "@\{ Key = '(?<key>[^']+)'.*?Action = \{ (?<fn>[\w-]+) \}") |
            ForEach-Object { [pscustomobject]@{ Key = $_.Groups['key'].Value; Function = $_.Groups['fn'].Value } })
    }

    It 'parses without errors' {
        { Get-MenuScriptAst } | Should -Not -Throw
    }

    It 'is saved as UTF-8 with BOM (required for the box characters in Windows PowerShell 5.1)' {
        $bytes = [System.IO.File]::ReadAllBytes($MenuScriptPath)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
    }

    It 'has menu items' {
        $menuItems.Count | Should -BeGreaterThan 10
    }

    It 'has unique menu keys and does not reuse Q (quit)' {
        $keys = $menuItems.Key
        ($keys | Select-Object -Unique).Count | Should -Be $keys.Count
        $keys | Should -Not -Contain 'Q'
    }

    It 'menu item [<Key>] calls a function that exists (<Function>)' -ForEach @(
        # Discovery-time copy of the menu table so each item gets its own test.
        $path = Join-Path (Split-Path $PSScriptRoot -Parent) 'Admin.Containers.AsMenu.ps1'
        [regex]::Matches([System.IO.File]::ReadAllText($path), "@\{ Key = '(?<key>[^']+)'.*?Action = \{ (?<fn>[\w-]+) \}") |
            ForEach-Object { @{ Key = $_.Groups['key'].Value; Function = $_.Groups['fn'].Value } }
    ) {
        $functions | Should -Contain $Function
    }

    It 'lets only non-destructive container operations run on several containers' {
        $itemLines  = @($scriptText -split '\r?\n' | Where-Object { $_ -match "@\{ Key = '" })
        $multiLines = @($itemLines | Where-Object { $_ -match 'Multi = \$true' })
        $multiLines.Count | Should -BeGreaterThan 0
        foreach ($line in $multiLines) {
            $line | Should -Match 'Target = \$true'
            $line | Should -Not -Match 'Danger = \$true'
        }
    }

    It 'never uses exit (it would close the VS Code PowerShell session)' {
        $exits = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true)
        @($exits).Count | Should -Be 0
    }

    It 'defines no function that shadows a BcContainerHelper or Docker command name' {
        $functions | Where-Object { $_ -match 'BcContainer|NavContainer|-Container$' } | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-SelectionText' {
    BeforeAll { Mock Write-Host { } }

    It 'parses "<Text>" (count <Count>) to <Expected>' -ForEach @(
        @{ Text = '1,3';       Count = 5; Expected = @(0, 2) }
        @{ Text = '2-4';       Count = 5; Expected = @(1, 2, 3) }
        @{ Text = '4-2';       Count = 5; Expected = @(1, 2, 3) }
        @{ Text = ' 1 , 2 ';   Count = 5; Expected = @(0, 1) }
        @{ Text = '1,1,2,1-2'; Count = 5; Expected = @(0, 1) }
        @{ Text = '3-9';       Count = 5; Expected = @(2, 3, 4) }
        @{ Text = 'abc,2';     Count = 5; Expected = @(1) }
        @{ Text = '5,1';       Count = 5; Expected = @(4, 0) }
    ) {
        $result = ConvertFrom-SelectionText -Text $Text -Count $Count
        Should -ActualValue $result -Be $Expected
    }

    It 'returns an empty array when nothing valid is selected: "<Text>"' -ForEach @(
        @{ Text = '0' }, @{ Text = '6' }, @{ Text = 'x,y' }, @{ Text = ',' }
    ) {
        $result = ConvertFrom-SelectionText -Text $Text -Count 5
        @($result).Count | Should -Be 0
    }

    It 'warns about invalid and out-of-range entries' {
        ConvertFrom-SelectionText -Text 'abc,9' -Count 5 | Out-Null
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*Ignored invalid entry*abc*' } -Times 1 -Exactly
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*out-of-range*9*' } -Times 1 -Exactly
    }
}

Describe 'Format-Fit' {
    It 'pads short text' {
        Format-Fit 'abc' 6 | Should -BeExactly 'abc   '
    }
    It 'keeps text of exactly the column width' {
        Format-Fit 'abcdef' 6 | Should -BeExactly 'abcdef'
    }
    It 'truncates long text with an ellipsis and keeps the width' {
        $r = Format-Fit 'abcdefgh' 6
        $r | Should -BeExactly 'abcde…'
        $r.Length | Should -Be 6
    }
    It 'handles null as empty' {
        Format-Fit $null 3 | Should -BeExactly '   '
    }
}

Describe 'Get-InstallPlanEntry' {
    BeforeAll {
        $appId    = '8f3c2c55-1e3a-4c8e-9a0b-2b9a8f0e1d11'
        $manifest = { param($version) [pscustomobject]@{ id = $appId; name = 'My App'; publisher = 'Contoso'; version = $version } }
        $current  = { param($version, $installed) [pscustomobject]@{ AppId = [guid]$appId; Name = 'My App'; Publisher = 'Contoso'; Version = [version]$version; IsInstalled = $installed } }
    }

    It 'plans a new install when the app is not in the container' {
        $e = Get-InstallPlanEntry -Manifest (& $manifest '1.0.0.0') -CurrentApps @() -File 'C:\apps\a.app'
        $e.Action        | Should -Be 'Install'
        $e.Detail        | Should -Be 'new'
        $e.SamePublished | Should -BeFalse
        $e.File          | Should -Be 'C:\apps\a.app'
        $e.Version       | Should -Be ([version]'1.0.0.0')
    }

    It 'plans an upgrade when a lower version is installed' {
        $e = Get-InstallPlanEntry -Manifest (& $manifest '2.0.0.0') -CurrentApps @(& $current '1.0.0.0' $true)
        $e.Action             | Should -Be 'Upgrade'
        $e.Detail             | Should -BeLike 'v1.0.0.0*v2.0.0.0'
        $e.Installed.Version  | Should -Be ([version]'1.0.0.0')
    }

    It 'compares versions numerically, not as text (1.0.10.0 > 1.0.9.0)' {
        $e = Get-InstallPlanEntry -Manifest (& $manifest '1.0.10.0') -CurrentApps @(& $current '1.0.9.0' $true)
        $e.Action | Should -Be 'Upgrade'
    }

    It 'skips the same installed version' {
        $e = Get-InstallPlanEntry -Manifest (& $manifest '1.0.0.0') -CurrentApps @(& $current '1.0.0.0' $true)
        $e.Action | Should -Be 'Skip'
        $e.Detail | Should -Be 'same version installed'
    }

    It 'skips a downgrade' {
        $e = Get-InstallPlanEntry -Manifest (& $manifest '1.0.0.0') -CurrentApps @(& $current '2.0.0.0' $true)
        $e.Action | Should -Be 'Skip'
        $e.Detail | Should -BeLike 'downgrade from v2.0.0.0*'
    }

    It 'installs an already published, not installed same version (reuses the package)' {
        $e = Get-InstallPlanEntry -Manifest (& $manifest '1.0.0.0') -CurrentApps @(& $current '1.0.0.0' $false)
        $e.Action        | Should -Be 'Install'
        $e.Detail        | Should -Be 'already published, not installed'
        $e.SamePublished | Should -BeTrue
    }

    It 'installs when only another version is published (not installed)' {
        $e = Get-InstallPlanEntry -Manifest (& $manifest '1.1.0.0') -CurrentApps @(& $current '1.0.0.0' $false)
        $e.Action        | Should -Be 'Install'
        $e.Detail        | Should -Be 'other version published'
        $e.SamePublished | Should -BeFalse
    }

    It 'uses the installed version when several versions are published' {
        $apps = @((& $current '1.0.0.0' $false), (& $current '1.5.0.0' $true), (& $current '3.0.0.0' $false))
        $e = Get-InstallPlanEntry -Manifest (& $manifest '2.0.0.0') -CurrentApps $apps
        $e.Action | Should -Be 'Upgrade'
        $e.Detail | Should -BeLike 'v1.5.0.0*'
    }

    It 'matches app ids case-insensitively' {
        $upper = [pscustomobject]@{ AppId = $appId.ToUpperInvariant(); Version = [version]'1.0.0.0'; IsInstalled = $true }
        $e = Get-InstallPlanEntry -Manifest (& $manifest '1.0.0.0') -CurrentApps @($upper)
        $e.Action | Should -Be 'Skip'
    }

    It 'ignores apps with another id' {
        $other = [pscustomobject]@{ AppId = [guid]::NewGuid(); Version = [version]'9.0.0.0'; IsInstalled = $true }
        $e = Get-InstallPlanEntry -Manifest (& $manifest '1.0.0.0') -CurrentApps @($other, $null)
        $e.Action | Should -Be 'Install'
        $e.Detail | Should -Be 'new'
    }
}

Describe 'Format-EventMessage' {
    It 'surfaces the key lines of a BC server event and strips <ii> tags' {
        $message = @(
            'Server instance: BC'
            'Tenant ID: default'
            'Session type: WebClient'
            'User: ADMIN'
            'Type: Microsoft.Dynamics.Nav.Types.Exceptions.NavNCLDialogException'
            'Message: <ii>The Customer does not exist.</ii>'
            'StackTrace: at Something()'
        ) -join "`r`n"
        $lines = @(Format-EventMessage $message)
        $lines | Should -Contain 'Message: The Customer does not exist.'
        $lines | Should -Contain 'User: ADMIN'
        $lines | Should -Contain 'Session type: WebClient'
        $lines | Should -Not -Contain 'Tenant ID: default'
        ($lines -join ' ') | Should -Not -Match '<ii>'
    }

    It 'falls back to the first 6 non-empty lines when there are no key lines' {
        $message = (1..10 | ForEach-Object { "line $_" }) -join "`n`n"
        $lines = @(Format-EventMessage $message)
        $lines.Count | Should -Be 6
        $lines[0]    | Should -Be 'line 1'
    }

    It 'truncates very long lines' {
        $lines = @(Format-EventMessage ('Message: ' + ('x' * 1000)) -MaxLength 50)
        $lines[0].Length | Should -Be 50
        $lines[0]        | Should -BeLike '*…'
    }
}

Describe 'ConvertTo-GuideMarkdown' {
    It 'renders titles, headings, bullets and fenced code blocks' {
        $lines = @(
            [pscustomobject]@{ Kind = 'Title'; Text = 'Guide' }
            [pscustomobject]@{ Kind = 'Text';  Text = 'intro' }
            [pscustomobject]@{ Kind = 'Head';  Text = 'Endpoints' }
            [pscustomobject]@{ Kind = 'Code';  Text = 'GET a' }
            [pscustomobject]@{ Kind = 'Code';  Text = 'GET b' }
            [pscustomobject]@{ Kind = 'Ok';    Text = 'fine' }
            [pscustomobject]@{ Kind = 'Code';  Text = 'last' }
        )
        $md  = ConvertTo-GuideMarkdown -Lines $lines
        $out = $md -split '\r?\n'

        $out[0] | Should -Be '# Guide'
        $out    | Should -Contain '- intro'
        $out    | Should -Contain '## Endpoints'
        $out    | Should -Contain '- fine'
        # Two code blocks -> four fences; the trailing block is closed too.
        @($out | Where-Object { $_ -eq '```' }).Count | Should -Be 4
        $md | Should -Match '```\r?\nGET a\r?\nGET b\r?\n```'
    }
}

Describe 'Prompts' {
    BeforeAll { Mock Write-Host { } }

    Context 'Read-YesNo' {
        It 'returns the default on Enter (default <Default>)' -ForEach @(@{ Default = $true }, @{ Default = $false }) {
            Mock Read-Host { '' }
            Read-YesNo -Prompt 'Continue?' -Default $Default | Should -Be $Default
        }

        It 'accepts "<Answer>" as <Expected>' -ForEach @(
            @{ Answer = 'y'; Expected = $true }, @{ Answer = 'YES'; Expected = $true }
            @{ Answer = 'n'; Expected = $false }, @{ Answer = 'No'; Expected = $false }
        ) {
            Mock Read-Host -MockWith ([scriptblock]::Create("'$Answer'"))
            Read-YesNo -Prompt 'Continue?' -Default (-not $Expected) | Should -Be $Expected
        }

        It 'asks again after an invalid answer' {
            # Global on purpose: a mock body does not reliably see the test's own variables.
            $global:ReadYesNoAnswers = New-Object System.Collections.Queue
            'maybe', 'y' | ForEach-Object { $global:ReadYesNoAnswers.Enqueue($_) }
            try {
                Mock Read-Host { $global:ReadYesNoAnswers.Dequeue() }
                Read-YesNo -Prompt 'Continue?' | Should -BeTrue
                Should -Invoke Read-Host -Times 2 -Exactly
            }
            finally { Remove-Variable -Name ReadYesNoAnswers -Scope Global -ErrorAction SilentlyContinue }
        }
    }

    Context 'Confirm-Action' {
        It 'proceeds only on "<Answer>" = <Expected> (Enter means No)' -ForEach @(
            @{ Answer = 'y';   Expected = $true }, @{ Answer = 'Yes'; Expected = $true }
            @{ Answer = '';    Expected = $false }, @{ Answer = 'n';  Expected = $false }
        ) {
            Mock Read-Host -MockWith ([scriptblock]::Create("'$Answer'"))
            Confirm-Action -Question "Permanently delete container 'bcone'?" | Should -Be $Expected
        }

        It 'shows the question including the target' {
            Mock Read-Host { 'n' }
            Confirm-Action -Question "Permanently delete container 'bcone'?" | Out-Null
            Should -Invoke Read-Host -ParameterFilter { "$Prompt".Contains("Permanently delete container 'bcone'? [y/N]") } -Times 1 -Exactly
        }
    }

    It 'no typed-name confirmations remain in the script' {
        [System.IO.File]::ReadAllText($MenuScriptPath) | Should -Not -Match 'Confirm-ByTyping'
    }
}

Describe 'Read-TargetContainer' {
    BeforeAll {
        Mock Write-Host { }
        $list = @(
            [pscustomobject]@{ Name = 'bcone';   State = 'running' }
            [pscustomobject]@{ Name = 'bctwo';   State = 'running' }
            [pscustomobject]@{ Name = 'bcthree'; State = 'exited' }
        )
    }
    BeforeEach {
        # Global on purpose: a mock body does not reliably see the test's own variables.
        $global:TargetAnswers = New-Object System.Collections.Queue
        Mock Read-Host { $global:TargetAnswers.Dequeue() }
    }
    AfterAll { Remove-Variable -Name TargetAnswers -Scope Global -ErrorAction SilentlyContinue }

    It 'answers <Answers> (multiple allowed: <Multi>) select <Expected>' -ForEach @(
        @{ Answers = @('');          Multi = $false; Expected = @('bcone') }
        @{ Answers = @('2');         Multi = $false; Expected = @('bctwo') }
        @{ Answers = @('#3');        Multi = $false; Expected = @('bcthree') }
        @{ Answers = @('bctwo');     Multi = $false; Expected = @('bctwo') }
        @{ Answers = @('1,3', '2');  Multi = $false; Expected = @('bctwo') }
        @{ Answers = @('A', '2');    Multi = $false; Expected = @('bctwo') }
        @{ Answers = @('9', '1');    Multi = $false; Expected = @('bcone') }
        @{ Answers = @('');          Multi = $true;  Expected = @('bcone') }
        @{ Answers = @('2');         Multi = $true;  Expected = @('bctwo') }
        @{ Answers = @('1,3');       Multi = $true;  Expected = @('bcone', 'bcthree') }
        @{ Answers = @('2-3');       Multi = $true;  Expected = @('bctwo', 'bcthree') }
        @{ Answers = @('A');         Multi = $true;  Expected = @('bcone', 'bctwo', 'bcthree') }
        @{ Answers = @('a');         Multi = $true;  Expected = @('bcone', 'bctwo', 'bcthree') }
        @{ Answers = @('7-9', '1');  Multi = $true;  Expected = @('bcone') }
    ) {
        $Answers | ForEach-Object { $global:TargetAnswers.Enqueue($_) }
        $result = @(Read-TargetContainer -Containers $list -Current 'bcone' -AllowMultiple:$Multi)
        Should -ActualValue $result -Be $Expected
        Should -Invoke Read-Host -Times $Answers.Count -Exactly
    }

    It 'returns nothing on C (multiple allowed: <Multi>)' -ForEach @(@{ Multi = $false }, @{ Multi = $true }) {
        $global:TargetAnswers.Enqueue('C')
        @(Read-TargetContainer -Containers $list -Current 'bcone' -AllowMultiple:$Multi).Count | Should -Be 0
    }

    It 'does not ask when there is only one container' {
        $result = @(Read-TargetContainer -Containers @($list[1]) -Current 'bctwo' -AllowMultiple)
        Should -ActualValue $result -Be @('bctwo')
        Should -Invoke Read-Host -Times 0 -Exactly
    }
}

Describe 'Multi-container runs' {
    BeforeAll { Mock Write-Host { } }
    AfterEach { Remove-Variable -Name AskCount, Seen -Scope Global -ErrorAction SilentlyContinue }

    It 'asks a shared question every time outside a multi-container run' {
        $global:AskCount = 0
        1..2 | ForEach-Object { Get-SharedValue -Key 'q' -Ask { $global:AskCount++; 'v' } } | Out-Null
        $global:AskCount | Should -Be 2
    }

    It 'runs the action per container and asks shared questions only once' {
        $global:AskCount = 0
        $global:Seen = New-Object System.Collections.Generic.List[string]
        $item = @{
            Label  = 'Test operation'
            Action = {
                $answer = Get-SharedValue -Key 'q' -Ask { $global:AskCount++; 'answer' }
                $global:Seen.Add("$($script:ContainerName)=$answer")
            }
        }
        $results = @(Invoke-MultiContainerAction -Item $item -Containers 'c1', 'c2', 'c3')

        $global:AskCount | Should -Be 1
        Should -ActualValue @($global:Seen) -Be @('c1=answer', 'c2=answer', 'c3=answer')
        Should -ActualValue @($results | ForEach-Object { $_.Ok }) -Be @($true, $true, $true)

        # Shared answers are forgotten after the run.
        Get-SharedValue -Key 'q' -Ask { $global:AskCount++; 'again' } | Should -Be 'again'
        $global:AskCount | Should -Be 2
    }

    It 'continues after a failing container and reports it' {
        $item = @{ Label = 'Fails on c2'; Action = { if ($script:ContainerName -eq 'c2') { throw 'boom' } } }
        $results = @(Invoke-MultiContainerAction -Item $item -Containers 'c1', 'c2', 'c3')

        $results.Count | Should -Be 3
        ($results | Where-Object Container -eq 'c1').Ok     | Should -BeTrue
        ($results | Where-Object Container -eq 'c2').Ok     | Should -BeFalse
        ($results | Where-Object Container -eq 'c2').Detail | Should -Be 'boom'
        ($results | Where-Object Container -eq 'c3').Ok     | Should -BeTrue
    }
}

Describe 'Strict mode' {
    BeforeAll { Mock Write-Host { } }

    It 'turns strict mode off at the top of the script (the calling session may have enabled it)' {
        $topLevel = @((Get-MenuScriptAst).EndBlock.Statements | ForEach-Object { $_.Extent.Text.Trim() })
        $topLevel | Should -Contain 'Set-StrictMode -Off'
    }

    It 'renders the main menu under Set-StrictMode -Version Latest (regression: missing Danger key)' {
        # Load the real menu table and banner width from the script, then render the menu strictly.
        $ast = Get-MenuScriptAst
        $assignments = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -in '$script:MenuItems', '$script:BannerWidth'
            }, $false)
        foreach ($a in $assignments) { . ([scriptblock]::Create($a.Extent.Text)) }
        $script:Containers    = @(
            [pscustomobject]@{ Name = 'bcone'; State = 'running' }
            [pscustomobject]@{ Name = 'bctwo'; State = 'exited' }
        )
        $script:ContainerName = 'bcone'
        $script:Tenant        = 'default'

        Set-StrictMode -Version Latest
        try {
            { Show-Menu } | Should -Not -Throw
        }
        finally {
            Set-StrictMode -Off
        }
        @($script:MenuItems | Where-Object { $_.Danger }).Count | Should -BeGreaterThan 0
        @($script:MenuItems | Where-Object { $_.Multi }).Count  | Should -BeGreaterThan 0
    }

    It 'keeps the pure helpers strict-mode safe' {
        Set-StrictMode -Version Latest
        try {
            { ConvertFrom-SelectionText -Text '1,3-4' -Count 5 } | Should -Not -Throw
            { Format-Fit 'abc' 5 } | Should -Not -Throw
            { Format-EventMessage "Message: <ii>x</ii>" } | Should -Not -Throw
            { ConvertTo-GuideMarkdown -Lines @([pscustomobject]@{ Kind = 'Code'; Text = 'x' }) } | Should -Not -Throw
            $manifest = [pscustomobject]@{ id = [guid]::NewGuid().ToString(); name = 'A'; publisher = 'P'; version = '1.0.0.0' }
            { Get-InstallPlanEntry -Manifest $manifest -CurrentApps @() } | Should -Not -Throw
        }
        finally {
            Set-StrictMode -Off
        }
    }
}
