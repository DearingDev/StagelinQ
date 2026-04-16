$privateFiles = Get-ChildItem -Path "$PSScriptRoot/Private/*.ps1" -ErrorAction SilentlyContinue
$publicFiles  = Get-ChildItem -Path "$PSScriptRoot/Public/*.ps1"  -ErrorAction SilentlyContinue

foreach ($file in $privateFiles + $publicFiles) {
    . $file.FullName
}

# Shared thread-safe state store — written by stream runspaces, read by Get-StagelinQSnapshot and the API
$script:State      = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$script:ModuleRoot = $PSScriptRoot
