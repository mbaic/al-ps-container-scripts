# Shared helpers for the Pester tests.
#
# The menu script is never executed by the tests: its function definitions are read from the
# parsed source (AST) and loaded on their own. That skips the #Requires check, does not need
# BcContainerHelper or Docker, and never starts the interactive menu.

$MenuScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Admin.Containers.AsMenu.ps1'

function Get-MenuScriptAst {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($MenuScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "Admin.Containers.AsMenu.ps1 has parse errors: $($errors[0].Message) (line $($errors[0].Extent.StartLineNumber))" }
    $ast
}

function Get-MenuScriptFunctionBlock {
    # Returns one scriptblock that defines every top-level function of the menu script.
    # Dot-source the result to make the functions available in the calling scope.
    $definitions = (Get-MenuScriptAst).FindAll({
            param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $false)
    [scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`n`n")
}

function Get-SplatKey {
    # Keys a splatting hashtable gets in the script: literal keys of "$Name = @{...}" plus
    # later "$Name.Key = ..." assignments.
    param([Parameter(Mandatory)][string] $Name)
    $ast  = Get-MenuScriptAst
    $keys = New-Object System.Collections.Generic.List[string]
    $assignments = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
    foreach ($a in $assignments) {
        $left = $a.Left
        if ($left -is [System.Management.Automation.Language.VariableExpressionAst] -and $left.VariablePath.UserPath -eq $Name) {
            $table = $a.Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
            if ($table) { foreach ($pair in $table.KeyValuePairs) { $keys.Add("$($pair.Item1.Value)") } }
        }
        elseif ($left -is [System.Management.Automation.Language.MemberExpressionAst] -and
                $left.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $left.Expression.VariablePath.UserPath -eq $Name) {
            $keys.Add("$($left.Member.Value)")
        }
    }
    $keys | Select-Object -Unique
}
