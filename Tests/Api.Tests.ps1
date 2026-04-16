#Requires -Module Pester
<#
.SYNOPSIS
    Integration tests for the StagelinQ HTTP REST API.
.DESCRIPTION
    Imports the module, seeds $script:State via the module scope, starts the API on a
    dedicated test port, then verifies every endpoint with Invoke-RestMethod.
    No hardware or network discovery required.

    Port 19337 is used to avoid clashing with the default 8080.
#>

BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'StagelinQ.psd1'
    Import-Module $modulePath -Force

    $script:TestPort   = 19337
    $script:BaseUrl    = "http://localhost:$($script:TestPort)"

    # Seed a known, stable state via the module's internal scope
    & (Get-Module StagelinQ) {
        $script:State.Clear()
        $script:State['/Engine/Deck1/Track/SongName']       = 'Midnight City'
        $script:State['/Engine/Deck1/Track/ArtistName']      = 'M83'
        $script:State['/Engine/Deck1/CurrentBPM']           = 104.998
        $script:State['/Engine/Deck1/PlayState']            = 'true'
        $script:State['/Engine/Deck1/Loop/Active']          = 'false'
        $script:State['/Engine/Deck2/Track/SongName']       = 'Strobe'
        $script:State['/Engine/Deck2/CurrentBPM']           = 128.0
        $script:State['/Engine/Deck2/PlayState']            = 'false'
        $script:State['/Engine/Deck2/Loop/Active']          = 'true'
        $script:State['BeatInfo/Deck1/Phase']               = 0.25
        $script:State['BeatInfo/Deck1/BPM']                 = 104.998
        $script:State['BeatInfo/Deck2/Phase']               = 0.5
        $script:State['BeatInfo/Deck2/BPM']                 = 128.0
        $script:State['/Engine/Master/Crossfader/Position'] = -0.2
    }

    # Use an explicit localhost prefix so no elevation is needed
    $script:Api = Start-StagelinQApi -Port $script:TestPort `
        -Prefix "http://localhost:$($script:TestPort)/"
    Start-Sleep -Milliseconds 400
}

AfterAll {
    if ($script:Api) {
        Stop-StagelinQApi -Api $script:Api
    }
    Remove-Module StagelinQ -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------

Describe 'GET /health' {
    It 'returns HTTP 200' {
        $resp = Invoke-RestMethod "$($script:BaseUrl)/health"
        $resp | Should -Not -BeNullOrEmpty
    }

    It 'status field is "ok"' {
        $resp = Invoke-RestMethod "$($script:BaseUrl)/health"
        $resp.status | Should -Be 'ok'
    }

    It 'uptime is a non-negative number' {
        $resp = Invoke-RestMethod "$($script:BaseUrl)/health"
        $resp.uptime | Should -BeGreaterOrEqual 0
    }
}

# ---------------------------------------------------------------------------

Describe 'GET /state (full snapshot)' {
    BeforeAll {
        $script:StateSnap = Invoke-RestMethod "$($script:BaseUrl)/state"
    }

    It 'returns all seeded StateMap keys' {
        $script:StateSnap.'/Engine/Deck1/Track/SongName' | Should -Be 'Midnight City'
    }

    It 'returns all seeded BeatInfo keys' {
        $script:StateSnap.'BeatInfo/Deck1/Phase' | Should -Not -BeNullOrEmpty
    }

    It 'contains the crossfader key' {
        $script:StateSnap.'/Engine/Master/Crossfader/Position' | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------

Describe 'GET /state/{key} (single key lookup)' {
    It 'returns the value for a BeatInfo key' {
        # BeatInfo/Deck1/Phase — no leading slash, so the URL is clean
        $resp = Invoke-RestMethod "$($script:BaseUrl)/state/BeatInfo%2FDeck1%2FPhase"
        $resp | Should -Be 0.25
    }

    It 'returns 404 for a key that does not exist' {
        { Invoke-RestMethod "$($script:BaseUrl)/state/NoSuch%2FKey" -ErrorAction Stop } |
            Should -Throw
    }

    It '404 response body contains an error field' {
        try {
            Invoke-RestMethod "$($script:BaseUrl)/state/Missing%2FKey" -ErrorAction Stop
        } catch {
            $body = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            $body.error | Should -Not -BeNullOrEmpty
        }
    }
}

# ---------------------------------------------------------------------------

Describe 'GET /beats' {
    BeforeAll {
        $script:BeatsSnap = Invoke-RestMethod "$($script:BaseUrl)/beats"
    }

    It 'returns only keys that start with BeatInfo/' {
        $script:BeatsSnap.PSObject.Properties.Name |
            ForEach-Object { $_ | Should -BeLike 'BeatInfo/*' }
    }

    It 'does not include StateMap keys' {
        $script:BeatsSnap.PSObject.Properties.Name |
            Should -Not -Contain '/Engine/Deck1/Track/SongName'
    }

    It 'contains BeatInfo/Deck1/Phase' {
        $script:BeatsSnap.'BeatInfo/Deck1/Phase' | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------

Describe 'GET /decks' {
    BeforeAll {
        $script:DecksSnap = Invoke-RestMethod "$($script:BaseUrl)/decks"
    }

    It 'groups data under Deck1' {
        $script:DecksSnap.Deck1 | Should -Not -BeNullOrEmpty
    }

    It 'groups data under Deck2' {
        $script:DecksSnap.Deck2 | Should -Not -BeNullOrEmpty
    }

    It 'does not include any BeatInfo keys at the top level' {
        $script:DecksSnap.PSObject.Properties.Name |
            Where-Object { $_ -like 'BeatInfo*' } |
            Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------

Describe 'GET /debug' {
    It 'returns totalKeys as a positive integer' {
        $resp = Invoke-RestMethod "$($script:BaseUrl)/debug"
        $resp.totalKeys | Should -BeGreaterThan 0
    }

    It 'reports beatInfoKeys and stateMapKeys' {
        $resp = Invoke-RestMethod "$($script:BaseUrl)/debug"
        $resp.beatInfoKeys | Should -BeGreaterOrEqual 0
        $resp.stateMapKeys | Should -BeGreaterOrEqual 0
    }

    It 'totalKeys equals beatInfoKeys plus stateMapKeys' {
        $resp = Invoke-RestMethod "$($script:BaseUrl)/debug"
        ($resp.beatInfoKeys + $resp.stateMapKeys) | Should -Be $resp.totalKeys
    }
}

# ---------------------------------------------------------------------------

Describe 'GET /state (crossfader)' {
    BeforeAll {
        $script:XfadeSnap = Invoke-RestMethod "$($script:BaseUrl)/state"
    }

    It 'crossfader key is present' {
        $script:XfadeSnap.'/Engine/Master/Crossfader/Position' | Should -Not -BeNullOrEmpty
    }

    It 'crossfader value matches the seeded value' {
        $script:XfadeSnap.'/Engine/Master/Crossfader/Position' | Should -Be -0.2
    }

    It 'crossfader value is within -1..1' {
        $v = [double]$script:XfadeSnap.'/Engine/Master/Crossfader/Position'
        $v | Should -BeGreaterOrEqual -1
        $v | Should -BeLessOrEqual     1
    }

    It 'crossfader key is NOT present in /decks (no deck number in path)' {
        $decks = Invoke-RestMethod "$($script:BaseUrl)/decks"
        $allDeckKeys = $decks.PSObject.Properties |
            ForEach-Object { $_.Value.PSObject.Properties.Name }
        $allDeckKeys | Should -Not -Contain '/Engine/Master/Crossfader/Position'
    }
}

# ---------------------------------------------------------------------------

Describe 'GET /decks (play and loop state)' {
    BeforeAll {
        $script:DeckStateSnap = Invoke-RestMethod "$($script:BaseUrl)/decks"
    }

    It 'Deck1 contains the PlayState key' {
        $script:DeckStateSnap.Deck1.PSObject.Properties.Name |
            Should -Contain '/Engine/Deck1/PlayState'
    }

    It 'Deck1 PlayState is "true" (playing)' {
        $script:DeckStateSnap.Deck1.'/Engine/Deck1/PlayState' | Should -Be 'true'
    }

    It 'Deck2 PlayState is "false" (stopped)' {
        $script:DeckStateSnap.Deck2.'/Engine/Deck2/PlayState' | Should -Be 'false'
    }

    It 'Deck1 contains the Loop/Active key' {
        $script:DeckStateSnap.Deck1.PSObject.Properties.Name |
            Should -Contain '/Engine/Deck1/Loop/Active'
    }

    It 'Deck1 Loop/Active is "false" (loop off)' {
        $script:DeckStateSnap.Deck1.'/Engine/Deck1/Loop/Active' | Should -Be 'false'
    }

    It 'Deck2 Loop/Active is "true" (loop on)' {
        $script:DeckStateSnap.Deck2.'/Engine/Deck2/Loop/Active' | Should -Be 'true'
    }

    It 'play and loop state keys belong to their own deck only' {
        # Deck1 should not contain Deck2 keys and vice versa
        $deck1Keys = $script:DeckStateSnap.Deck1.PSObject.Properties.Name
        $deck2Keys = $script:DeckStateSnap.Deck2.PSObject.Properties.Name
        $deck1Keys | Where-Object { $_ -like '*Deck2*' } | Should -BeNullOrEmpty
        $deck2Keys | Where-Object { $_ -like '*Deck1*' } | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------

Describe 'Unknown routes' {
    It 'returns 404 for an unrecognised path' {
        { Invoke-RestMethod "$($script:BaseUrl)/nonexistent" -ErrorAction Stop } |
            Should -Throw
    }

    It '404 body contains an error field' {
        try {
            Invoke-RestMethod "$($script:BaseUrl)/whatever" -ErrorAction Stop
        } catch {
            $body = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            $body.error | Should -Not -BeNullOrEmpty
        }
    }
}
