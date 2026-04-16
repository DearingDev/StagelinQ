#Requires -Module Pester
<#
.SYNOPSIS
    Integration tests for Start-StagelinQSession -DemoMode.
.DESCRIPTION
    Starts a full DemoMode session on a dedicated test port, then verifies:
      - All expected state keys are present on startup
      - Beat phase advances over time (the animator runspace is running)
      - PlayState and Loop/Active mutations are reflected in /state immediately
      - Crossfader mutations are reflected in /state immediately
      - /beats only returns BeatInfo/* keys and phase is a number in [0,1)

    Port 29337 is used to avoid clashing with Api.Tests.ps1 (19337) or the
    default session port (8080).
#>

BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'StagelinQ.psd1'
    Import-Module $modulePath -Force

    $script:TestPort = 29337
    $script:BaseUrl  = "http://localhost:$($script:TestPort)"

    $script:Session = Start-StagelinQSession `
        -DemoMode `
        -Port $script:TestPort `
        -Quiet

    # Give the animator and API a moment to settle
    Start-Sleep -Milliseconds 800
}

AfterAll {
    if ($script:Session) {
        Stop-StagelinQSession -Session $script:Session
    }
    Remove-Module StagelinQ -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------

Describe 'DemoMode startup — /state has expected keys' {
    BeforeAll {
        $script:InitialState = Invoke-RestMethod "$($script:BaseUrl)/state"
    }

    It 'Deck1 SongName is populated' {
        $script:InitialState.'/Engine/Deck1/Track/SongName' | Should -Not -BeNullOrEmpty
    }

    It 'Deck2 SongName is populated' {
        $script:InitialState.'/Engine/Deck2/Track/SongName' | Should -Not -BeNullOrEmpty
    }

    It 'Deck1 BPM is a positive number' {
        $bpm = [double]$script:InitialState.'/Engine/Deck1/CurrentBPM'
        $bpm | Should -BeGreaterThan 0
    }

    It 'Deck1 PlayState is present' {
        $script:InitialState.'/Engine/Deck1/PlayState' | Should -Not -BeNullOrEmpty
    }

    It 'Deck2 Loop/Active is present' {
        $script:InitialState.'/Engine/Deck2/Loop/Active' | Should -Not -BeNullOrEmpty
    }

    It 'Crossfader position is present' {
        $script:InitialState.'/Engine/Master/Crossfader/Position' | Should -Not -BeNullOrEmpty
    }

    It 'BeatInfo keys are present for both decks' {
        $script:InitialState.'BeatInfo/Deck1/Phase' | Should -Not -BeNullOrEmpty
        $script:InitialState.'BeatInfo/Deck2/Phase' | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------

Describe 'Beat animator — phase advances over time' {
    It 'Deck1 beat phase increases after 300 ms' {
        $before = [double](Invoke-RestMethod "$($script:BaseUrl)/state").'BeatInfo/Deck1/Phase'
        Start-Sleep -Milliseconds 300
        $after  = [double](Invoke-RestMethod "$($script:BaseUrl)/state").'BeatInfo/Deck1/Phase'
        # Phase wraps at 1.0, so either it went up or it wrapped around (after < before)
        ($after -gt $before) -or ($after -lt $before) | Should -Be $true
    }

    It 'Deck1 phase stays within [0, 1)' {
        # Sample several times to catch any out-of-range values
        1..5 | ForEach-Object {
            Start-Sleep -Milliseconds 60
            $p = [double](Invoke-RestMethod "$($script:BaseUrl)/state").'BeatInfo/Deck1/Phase'
            $p | Should -BeGreaterOrEqual 0
            $p | Should -BeLessThan      1
        }
    }

    It 'BeatIndex increments (observed within 2 full beats at 105 BPM ~ 1.14 s)' {
        $idxBefore = [int](Invoke-RestMethod "$($script:BaseUrl)/state").'BeatInfo/Deck1/BeatIndex'
        Start-Sleep -Milliseconds 1200
        $idxAfter  = [int](Invoke-RestMethod "$($script:BaseUrl)/state").'BeatInfo/Deck1/BeatIndex'
        $idxAfter | Should -BeGreaterThan $idxBefore
    }

    It '/beats endpoint phase is a number in [0, 1)' {
        $beats = Invoke-RestMethod "$($script:BaseUrl)/beats"
        $p = [double]$beats.'BeatInfo/Deck1/Phase'
        $p | Should -BeGreaterOrEqual 0
        $p | Should -BeLessThan      1
    }
}

# ---------------------------------------------------------------------------

Describe 'State mutations — PlayState reflected in /state' {
    It 'toggling Deck1 PlayState to false is immediately visible' {
        & (Get-Module StagelinQ) {
            $script:State['/Engine/Deck1/PlayState'] = 'false'
        }
        $snap = Invoke-RestMethod "$($script:BaseUrl)/state"
        $snap.'/Engine/Deck1/PlayState' | Should -Be 'false'
    }

    It 'toggling Deck1 PlayState back to true is immediately visible' {
        & (Get-Module StagelinQ) {
            $script:State['/Engine/Deck1/PlayState'] = 'true'
        }
        $snap = Invoke-RestMethod "$($script:BaseUrl)/state"
        $snap.'/Engine/Deck1/PlayState' | Should -Be 'true'
    }
}

# ---------------------------------------------------------------------------

Describe 'State mutations — Loop/Active reflected in /state' {
    It 'enabling Deck1 loop is immediately visible' {
        & (Get-Module StagelinQ) {
            $script:State['/Engine/Deck1/Loop/Active'] = 'true'
        }
        $snap = Invoke-RestMethod "$($script:BaseUrl)/state"
        $snap.'/Engine/Deck1/Loop/Active' | Should -Be 'true'
    }

    It 'disabling Deck1 loop is immediately visible' {
        & (Get-Module StagelinQ) {
            $script:State['/Engine/Deck1/Loop/Active'] = 'false'
        }
        $snap = Invoke-RestMethod "$($script:BaseUrl)/state"
        $snap.'/Engine/Deck1/Loop/Active' | Should -Be 'false'
    }
}

# ---------------------------------------------------------------------------

Describe 'State mutations — Crossfader reflected in /state' {
    It 'moving crossfader full-left (-1.0) is immediately visible' {
        & (Get-Module StagelinQ) {
            $script:State['/Engine/Master/Crossfader/Position'] = -1.0
        }
        $snap = Invoke-RestMethod "$($script:BaseUrl)/state"
        # ConvertTo-Json serialises [double]-1.0 as the integer -1 (no decimal),
    # so Invoke-RestMethod returns [int]-1. Compare numerically.
    [double]($snap.'/Engine/Master/Crossfader/Position') | Should -Be -1
    }

    It 'moving crossfader to centre (0.0) is immediately visible' {
        & (Get-Module StagelinQ) {
            $script:State['/Engine/Master/Crossfader/Position'] = 0.0
        }
        $snap = Invoke-RestMethod "$($script:BaseUrl)/state"
        [double]$snap.'/Engine/Master/Crossfader/Position' | Should -Be 0.0
    }

    It 'moving crossfader full-right (1.0) is immediately visible' {
        & (Get-Module StagelinQ) {
            $script:State['/Engine/Master/Crossfader/Position'] = 1.0
        }
        $snap = Invoke-RestMethod "$($script:BaseUrl)/state"
        [double]$snap.'/Engine/Master/Crossfader/Position' | Should -Be 1.0
    }
}
