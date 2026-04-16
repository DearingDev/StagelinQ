#Requires -Module Pester
<#
.SYNOPSIS
    Unit tests for Get-StagelinQSnapshot.
.DESCRIPTION
    Verifies that Get-StagelinQSnapshot returns a plain hashtable that is a
    point-in-time copy of the module's ConcurrentDictionary state, and that
    mutations to the snapshot do not affect the live state.
#>

BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'StagelinQ.psd1'
    Import-Module $modulePath -Force
}

AfterAll {
    Remove-Module StagelinQ -ErrorAction SilentlyContinue
}

Describe 'Get-StagelinQSnapshot' {
    BeforeEach {
        # Reset to a known state before each test
        & (Get-Module StagelinQ) {
            $script:State.Clear()
        }
    }

    It 'returns a hashtable' {
        $snap = Get-StagelinQSnapshot
        $snap | Should -BeOfType [hashtable]
    }

    It 'returns an empty hashtable when state is empty' {
        $snap = Get-StagelinQSnapshot
        $snap.Count | Should -Be 0
    }

    It 'reflects a key that was seeded into the module state' {
        & (Get-Module StagelinQ) {
            $script:State['/Engine/Deck1/Track/SongName'] = 'Test Track'
        }
        $snap = Get-StagelinQSnapshot
        $snap['/Engine/Deck1/Track/SongName'] | Should -Be 'Test Track'
    }

    It 'contains all seeded keys' {
        & (Get-Module StagelinQ) {
            $script:State['Key1'] = 'Val1'
            $script:State['Key2'] = 'Val2'
            $script:State['Key3'] = 'Val3'
        }
        $snap = Get-StagelinQSnapshot
        $snap.Count | Should -Be 3
    }

    It 'returns a copy — mutating the snapshot does not affect live state' {
        & (Get-Module StagelinQ) {
            $script:State['/Engine/Deck1/PlayState'] = 'true'
        }
        $snap = Get-StagelinQSnapshot
        $snap['/Engine/Deck1/PlayState'] = 'MUTATED'

        # Live state should be unchanged
        $live = & (Get-Module StagelinQ) { $script:State['/Engine/Deck1/PlayState'] }
        $live | Should -Be 'true'
    }

    It 'a second snapshot reflects an update made after the first' {
        & (Get-Module StagelinQ) { $script:State['BeatInfo/Deck1/Phase'] = 0.0 }
        $before = Get-StagelinQSnapshot

        & (Get-Module StagelinQ) { $script:State['BeatInfo/Deck1/Phase'] = 0.9 }
        $after = Get-StagelinQSnapshot

        $before['BeatInfo/Deck1/Phase'] | Should -Be 0.0
        $after['BeatInfo/Deck1/Phase']  | Should -Be 0.9
    }
}
