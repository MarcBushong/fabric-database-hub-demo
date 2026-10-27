BeforeDiscovery {
    # Convention test for the presenter scripts in docs/demo-walkthrough.md (Phase 15 amendment). The governing
    # brief requires nine fields on every walkthrough step: the time, the presenter action, the narration, the
    # expected visual and signal, the preview fallback, the reset instruction, a screenshot placeholder, and why
    # the customer should care. The document is parsed here, during discovery, so every step gets its own tests,
    # named after the step.
    $walkthroughPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../../docs/demo-walkthrough.md'))

    function Read-WalkthroughDocument {
        param(
            [string] $Path
        )

        $errors = [System.Collections.Generic.List[string]]::new()
        $text = ''
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $text = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
        }
        else {
            $errors.Add('docs/demo-walkthrough.md does not exist.')
        }
        $lines = $text.Split("`n")

        # Headings outside fenced code blocks: level, text, and line index.
        $headings = [System.Collections.Generic.List[object]]::new()
        $inFence = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*(```|~~~)') {
                $inFence = -not $inFence
                continue
            }
            if (-not $inFence) {
                $headingMatch = [regex]::Match($lines[$i], '^(?<hashes>#{1,6}) (?<title>.+)$')
                if ($headingMatch.Success) {
                    $headings.Add([pscustomobject]@{ Level = $headingMatch.Groups['hashes'].Value.Length; Text = $headingMatch.Groups['title'].Value.Trim(); Line = $i })
                }
            }
        }

        $stepPattern = '^(?:Beat (?<number>[1-9][0-9]*)|Close) \((?<start>[0-9]{1,2}:[0-5][0-9])[\u2013-](?<end>[0-9]{1,2}:[0-5][0-9])\)(?:: \S.*)?$'
        $tablePattern = '^\| (?<start>[0-9]{1,2}:[0-5][0-9])[\u2013-](?<end>[0-9]{1,2}:[0-5][0-9]) \|'
        $scripts = [System.Collections.Generic.List[object]]::new()
        $steps = [System.Collections.Generic.List[object]]::new()
        $firstScriptLine = $lines.Count
        foreach ($definition in @(@{ Minutes = '15'; End = '15:00' }, @{ Minutes = '30'; End = '30:00' })) {
            $title = 'The {0}-minute script' -f $definition.Minutes
            $section = @($headings | Where-Object -FilterScript { $_.Level -eq 2 -and $_.Text -ceq $title })
            if ($section.Count -ne 1) {
                $errors.Add(('Expected one "## {0}" section; found {1}.' -f $title, $section.Count))
                continue
            }
            $sectionStart = $section[0].Line
            $firstScriptLine = [System.Math]::Min($firstScriptLine, $sectionStart)
            $nextSection = @($headings | Where-Object -FilterScript { $_.Level -le 2 -and $_.Line -gt $sectionStart } | Select-Object -First 1)
            $sectionEnd = if ($nextSection.Count -gt 0) { $nextSection[0].Line } else { $lines.Count }
            $inside = @($headings | Where-Object -FilterScript { $_.Line -gt $sectionStart -and $_.Line -lt $sectionEnd })
            $firstStepLine = $sectionEnd

            $scriptSteps = [System.Collections.Generic.List[object]]::new()
            for ($h = 0; $h -lt $inside.Count; $h++) {
                $heading = $inside[$h]
                if ($heading.Level -ne 3 -or $heading.Text -cnotmatch '^(Beat|Close)\b') {
                    continue
                }
                $headingMatch = [regex]::Match($heading.Text, $stepPattern)
                if (-not $headingMatch.Success) {
                    $errors.Add(('"### {0}" in the {1}-minute script has no valid time range (m:ss-m:ss).' -f $heading.Text, $definition.Minutes))
                    continue
                }
                $firstStepLine = [System.Math]::Min($firstStepLine, $heading.Line)
                $kind = if ($headingMatch.Groups['number'].Success) { 'Beat' } else { 'Close' }
                $number = if ($headingMatch.Groups['number'].Success) { [int]$headingMatch.Groups['number'].Value } else { 0 }
                $start = $headingMatch.Groups['start'].Value
                $end = $headingMatch.Groups['end'].Value
                $bodyEnd = $sectionEnd
                foreach ($later in $inside) {
                    if ($later.Line -gt $heading.Line -and $later.Level -le 3) {
                        $bodyEnd = $later.Line
                        break
                    }
                }
                $body = @(if ($bodyEnd - $heading.Line -gt 1) { $lines[($heading.Line + 1)..($bodyEnd - 1)] })

                # Top-level labels: lines such as '- **Say:** ...'. Nested bullets don't count.
                $labels = @(foreach ($line in $body) {
                        $labelMatch = [regex]::Match($line, '^- \*\*(?<label>[^*]+)\*\*')
                        if ($labelMatch.Success) { $labelMatch.Groups['label'].Value }
                    })
                $screenshot = ''
                $why = ''
                # The reset instruction: its bullet and the lines that continue it, such as a code block.
                $reset = [System.Text.StringBuilder]::new()
                $inReset = $false
                foreach ($line in $body) {
                    if ($line.StartsWith('- **Screenshot:**', [System.StringComparison]::Ordinal) -and -not $screenshot) {
                        $screenshotMatch = [regex]::Match($line, '^- \*\*Screenshot:\*\* `(?<path>[^`]+)` \(planned\): \S')
                        if ($screenshotMatch.Success) {
                            $screenshot = $screenshotMatch.Groups['path'].Value
                        }
                    }
                    if ($line.StartsWith('- **Why it matters:** ', [System.StringComparison]::Ordinal) -and -not $why) {
                        $why = $line.Substring('- **Why it matters:** '.Length)
                    }
                    if ($line.StartsWith('- **Reset:**', [System.StringComparison]::Ordinal)) {
                        $inReset = $true
                    }
                    elseif ($inReset -and $line.StartsWith('- ', [System.StringComparison]::Ordinal)) {
                        $inReset = $false
                    }
                    if ($inReset) {
                        [void]$reset.AppendLine($line)
                    }
                }

                $step = @{
                    Minutes    = $definition.Minutes
                    Name       = $heading.Text
                    Kind       = $kind
                    Number     = $number
                    Start      = $start
                    End        = $end
                    Labels     = $labels
                    Screenshot = $screenshot
                    Why        = $why
                    Reset      = $reset.ToString()
                }
                $scriptSteps.Add($step)
                $steps.Add($step)
            }

            # The time table between the section heading and its first step.
            $tableTimes = @(if ($firstStepLine - $sectionStart -gt 1) {
                    foreach ($line in $lines[($sectionStart + 1)..($firstStepLine - 1)]) {
                        $rowMatch = [regex]::Match($line, $tablePattern)
                        if ($rowMatch.Success) { '{0}-{1}' -f $rowMatch.Groups['start'].Value, $rowMatch.Groups['end'].Value }
                    }
                })
            $scripts.Add(@{ Minutes = $definition.Minutes; End = $definition.End; Steps = $scriptSteps.ToArray(); TableTimes = $tableTimes })
        }

        # The "Every step has" checklist and its numbered items.
        $checklistLine = -1
        $checklistItems = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Contains('**Every step has**')) {
                $checklistLine = $i
                for ($j = $i + 1; $j -lt $lines.Count -and $lines[$j] -match '^\s+[0-9]+\. '; $j++) {
                    $checklistItems.Add($lines[$j].Trim())
                }
                break
            }
        }

        @{
            Errors          = $errors.ToArray()
            Steps           = $steps.ToArray()
            Scripts         = $scripts.ToArray()
            ScreenshotPaths = @([regex]::Matches($text, 'docs/images/walkthrough/[^`\s)]+') | ForEach-Object -Process { $_.Value })
            ImageLinks      = @([regex]::Matches($text, '!\[[^\]]*\]\s*[\(\[]|(?i)<img\b') | ForEach-Object -Process { $_.Value })
            ChecklistLine   = $checklistLine
            ChecklistItems  = $checklistItems.ToArray()
            FirstScriptLine = $firstScriptLine
        }
    }

    $walkthroughDocument = Read-WalkthroughDocument -Path $walkthroughPath
    $walkthroughSteps = @($walkthroughDocument.Steps)
    $walkthroughScripts = @($walkthroughDocument.Scripts)
}

BeforeAll {
    # 'A|B' means either label. Labels match '- **<label>** ...' at the start of a line, case-sensitively.
    $requiredLabels = @('Show:|Do:', 'Say:', 'Look for:', 'If it isn''t there:', 'Reset:', 'Why it matters:', 'Screenshot:')
    $checklistLabels = @('Show:', 'Do:', 'Say:', 'Look for:', 'If it isn''t there:', 'Reset:', 'Screenshot:', 'Why it matters:')
    $valueThemes = @('faster detection', 'less tool switching', 'consistent hybrid inventory', 'shared context', 'guided investigation', 'human-controlled action')
    $screenshotPattern = '^docs/images/walkthrough/(15|30)-(beat-[1-9][0-9]*|close)-[a-z0-9]+(-[a-z0-9]+)*\.png$'

    function ConvertFrom-WalkthroughTime {
        param(
            [string] $Text
        )
        $parts = $Text.Split(':')
        ([int]$parts[0] * 60) + [int]$parts[1]
    }
}

Describe 'Demo walkthrough (docs/demo-walkthrough.md)' {
    It 'has both scripts, each with numbered beats and one closing step' -ForEach @(@{ Errors = $walkthroughDocument.Errors; Scripts = $walkthroughScripts }) {
        $Errors | Should -BeNullOrEmpty
        $Scripts.Count | Should -Be 2
        foreach ($scriptEntry in $Scripts) {
            $beats = @($scriptEntry.Steps | Where-Object -FilterScript { $_.Kind -eq 'Beat' })
            $closes = @($scriptEntry.Steps | Where-Object -FilterScript { $_.Kind -eq 'Close' })
            $beats.Count | Should -BeGreaterThan 0 -Because "the $($scriptEntry.Minutes)-minute script needs its beats"
            (@($beats | ForEach-Object -Process { $_.Number }) -join ',') | Should -Be ((1..$beats.Count) -join ',') -Because "the $($scriptEntry.Minutes)-minute script numbers its beats 1, 2, 3, and so on, in order"
            $closes.Count | Should -Be 1 -Because "the $($scriptEntry.Minutes)-minute script ends with one '### Close (m:ss-m:ss)' step"
            $scriptEntry.Steps[-1].Kind | Should -Be 'Close' -Because "the $($scriptEntry.Minutes)-minute script's last step is its close"
        }
    }

    It '<Minutes>-minute script, <Name>: has every required label' -ForEach $walkthroughSteps {
        $missing = @(foreach ($required in $requiredLabels) {
                $alternatives = $required.Split('|')
                if (-not @($alternatives | Where-Object -FilterScript { $Labels -ccontains $_ })) {
                    '**' + ($alternatives -join '** or **') + '**'
                }
            })
        $missing | Should -BeNullOrEmpty -Because ("'{0}' in the {1}-minute script needs a top-level '- **<label>**' line for every field, and it's missing {2}" -f $Name, $Minutes, ($missing -join ', '))
    }

    It '<Minutes>-minute script, <Name>: has a planned screenshot path for this step' -ForEach $walkthroughSteps {
        $Screenshot | Should -Not -BeNullOrEmpty -Because ("'{0}' in the {1}-minute script needs '- **Screenshot:** ``docs/images/walkthrough/...png`` (planned): <what to capture>'" -f $Name, $Minutes)
        $Screenshot | Should -MatchExactly $screenshotPattern -Because ("'{0}' in the {1}-minute script must use the pattern docs/images/walkthrough/{{15|30}}-{{beat-N|close}}-{{slug}}.png" -f $Name, $Minutes)
        $step = if ($Kind -eq 'Close') { 'close' } else { 'beat-{0}' -f $Number }
        $prefix = 'docs/images/walkthrough/{0}-{1}-' -f $Minutes, $step
        $Screenshot.StartsWith($prefix, [System.StringComparison]::Ordinal) | Should -BeTrue -Because ("'{0}' in the {1}-minute script must use a path that starts with {2}" -f $Name, $Minutes, $prefix)
    }

    It '<Minutes>-minute script, <Name>: ties "Why it matters" to a value theme' -ForEach $walkthroughSteps {
        $text = $Why.ToLowerInvariant()
        @($valueThemes | Where-Object -FilterScript { $text.Contains($_) }).Count | Should -BeGreaterThan 0 -Because ("'{0}' in the {1}-minute script must name one of these themes in '**Why it matters:**': {2}" -f $Name, $Minutes, ($valueThemes -join ', '))
    }

    It '<Minutes>-minute script, <Name>: gives the reset command, or says there is nothing to reset' -ForEach $walkthroughSteps {
        ($Reset -cmatch 'Nothing to reset' -or $Reset -cmatch 'Invoke-Demo[A-Za-z]+ |\./scripts/[a-z-]+\.ps1') | Should -BeTrue -Because ("'{0}' in the {1}-minute script must give the exact command in '**Reset:**', or say 'Nothing to reset'" -f $Name, $Minutes)
    }

    It 'uses each screenshot path once' -ForEach @(@{ Paths = $walkthroughDocument.ScreenshotPaths; StepCount = $walkthroughSteps.Count }) {
        $duplicates = @($Paths | Group-Object | Where-Object -Property Count -GT -Value 1 | ForEach-Object -Process { $_.Name })
        $duplicates | Should -BeNullOrEmpty -Because 'each step needs its own screenshot'
        $Paths.Count | Should -Be $StepCount -Because 'every step has exactly one screenshot placeholder, and no other line names a screenshot path'
    }

    It 'times the <Minutes>-minute script in order, from 0:00 to <End>' -ForEach $walkthroughScripts {
        $Steps.Count | Should -BeGreaterThan 0
        $previousEnd = 0
        foreach ($step in $Steps) {
            $startSeconds = ConvertFrom-WalkthroughTime -Text $step.Start
            $endSeconds = ConvertFrom-WalkthroughTime -Text $step.End
            $startSeconds | Should -Be $previousEnd -Because ("'{0}' must start when the step before it ends, or at 0:00" -f $step.Name)
            $endSeconds | Should -BeGreaterThan $startSeconds -Because ("'{0}' must end after it starts" -f $step.Name)
            $previousEnd = $endSeconds
        }
        $previousEnd | Should -Be (ConvertFrom-WalkthroughTime -Text $End) -Because "the $Minutes-minute script must end at $End"
    }

    It 'lists the same times in the <Minutes>-minute script''s table as in its step headings' -ForEach $walkthroughScripts {
        $headingTimes = @($Steps | ForEach-Object -Process { '{0}-{1}' -f $_.Start, $_.End })
        ($TableTimes -join ', ') | Should -Be ($headingTimes -join ', ')
    }

    It 'has no Markdown image links' -ForEach @(@{ ImageLinks = $walkthroughDocument.ImageLinks }) {
        $ImageLinks | Should -BeNullOrEmpty -Because 'screenshots stay planned paths in inline code until a rehearsal captures them'
    }

    It 'lists the nine fields in its "Every step has" checklist, before the scripts' -ForEach @(@{ Line = $walkthroughDocument.ChecklistLine; FirstScriptLine = $walkthroughDocument.FirstScriptLine; Items = $walkthroughDocument.ChecklistItems }) {
        $Line | Should -BeGreaterOrEqual 0 -Because 'the walkthrough needs an "Every step has" checklist near the top'
        $Line | Should -BeLessThan $FirstScriptLine -Because 'the checklist comes before the scripts'
        $Items.Count | Should -Be 9 -Because 'the checklist lists the nine fields'
        $text = $Items -join "`n"
        foreach ($label in $checklistLabels) {
            $text.Contains('`' + $label + '`') | Should -BeTrue -Because "the checklist must name the label '$label'"
        }
    }
}
