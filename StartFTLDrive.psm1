﻿function Start-FTLDrive {
    <#
    .SYNOPSIS
    This script will start an asynchronous search all servers in the test, dev, or 
    prod forests for "interesting things". Things of interest are defined in 
    separate scriptblock "module" files, to be stored in the "ServerSearchModules" 
    subdirectory. Output is a CSV file in the format: 
    computer,status,message

    .DESCRIPTION
    This cmdlet essentially is a job queuing tool for the execution of PowerShell 
    script blocks.  It will spawn parallel PowerShell jobs up to a limit specified 
    by the "ThrottleLimit" parameter, and collect output from these jobs based on
    the time specified in "CycleTime". 

    Each run of the script will produce two output files:
    - .\Logs\[ModuleName]-found.csv
    - .\Logs\[ModuleName]-failed.csv

    Currently Supported Modules:

    Name                      State        Function
    ------                    -------      ----------
    Find-AccountUsage         Broken       Searches for usage of named service accounts

    Find-IISService           Working      Detects the presence and state of IIS

    Find-SSHHostKeys          Working      Detects the presence of PuTTY SSHHostKeys registry 
                                        values on all local users.

    Find-SuspectASPFiles      Working      Detects the presense of suspicious content in ASP and 
                                        ASPX files on servers running IIS.

    Find-SuspectFileNames     Working      Detects the presense of suspicious file names on servers 
                                        running IIS and Apache

    Get-LocalAdministrators   Working      Enumerates all members of the local Administrators 
                                        security group

    Get-LocalUsers            Working      Enumerates all active local user accounts

    Restart-HealthService     Partial      Restarts the SCOM Health Service if it is hung.  Success
                                        reporting may not be working properyly.

    Start-GPUpdate            Working      Forces a GPUpdate on all computers

    Requires:
    - Remote Server Administration Tools need to be installed on the local 
    machine, with support for the ActiveDirectory PowerShell module enabled, 
    when using the "NamedScope" parameter.
    - The "ScriptModules" directory needs to be present, and must contain the 
    supporting "PSQueue.psm1" and "MyOrgComputers.psm1" script modules.
    - A "Logs" directory needs to be present to host output from the script.

    .PARAMETER Module
    Module that contains the logic for the Server Search.  Supported modules are contained within the 
    'Search Modules' subdirectory of the script directory.

    .PARAMETER Computer
    One or more computer names on which to perform the selected search.  Multiple computer names must 
    be provided as an array of strings.

    .PARAMETER NamedScope
    Name a scope from which to collect computer objects.  Must be on of 'Test', 'Dev', or 'Prod'.
    This is a Yale-specific parameter which will collect all managed computers form the matching
    Active Directory forest.

    .PARAMETER ThrottleLimit
    Optional parameter.  Default value is 50 simultaneous PowerShell worker jobs.

    .PARAMETER CycleTime
    Optional parameter.  Specifies the number of seconds to wait between checks on the status of 
    running PowerShell jobs.  Default value is 10 seconds.

    .PARAMETER Timeout
    Optional parameter.  Specifies the number of seconds to wait for remaining jobs to complete after 
    all jobs in the queue have been started.  Default value is 7200 seconds, or two hours.  This timeout 
    might need to be increased for some long-running modules, such as Find-EncryptedFiles.

    .EXAMPLE
    C:\PS> .\Invoke-ServerSearch.ps1 -NamedScope prod -Module Get-LocalUsers
    Runs the Get-LocalUsers search module on all computers in the "Prod" (or 
    production Active Directory) scope.

    .EXAMPLE
    C:\PS> .\Invoke-ServerSearch.ps1 -Computer 'BobJohnsonsPc' -Module Find-SuspectAspFiles
    Runs the Get-SuspectAspFiles search module on the computer "BobJohnsonsPc".

    .EXAMPLE
    C:\PS> $InterestingPCs = @('johnPC','ringoServer','paulsBox')
    C:\PS> $InterstingPCs | Invoke-ServerSearch.ps1 -Module Find-SuspectAspFiles -ThrottleLimit 100

    Runs the Get-SuspectAspFiles search module on the array of computers 
    "$InterestingPCs", using the pipeline as input. Sets the ThrottleLimit to 
    100 simultaneous PowerShell jobs.  

    .LINK
    https://git.yale.edu/inf-sa/security-scan

    .TODO
    - Rename to "Invoke-Superluminal", with alias superluminal, isl - Ansible for Windows!
    - Change to run as a module.
    - Make logging optional
    - Allow custom code blocks from the command line. (auto message formatting?)
    - Abstract named scope module, provide sample code.
    - Put it on GitHub!
    #>
    [cmdletbinding()]
    param (
        [parameter(Mandatory=$true)]
            #[ValidateSet('Find-EncryptedFiles','Find-IISService','Find-SSHHostKeys','Find-SuspectASPFiles',
            #    'Find-SuspectFileNames','Get-LocalAdministrators','Get-LocalUsers','Get-PSVersion','Restart-HealthService',
            #    'Start-GPUpdate')]
            [validateScript({Test-Path ('.\SearchModules\' + $_ + '.ps1')})]
            [string]$Module,

        [parameter(Mandatory=$false)]
            [int]$throttleLimit = 50,

        [parameter(Mandatory=$false)]
            [int]$cycleTime = 10,

        [Parameter(Mandatory=$False)]
            [int]$timeout = 7200,

        [Parameter(Mandatory=$True,ParameterSetName='scoped')]
            [ValidateSet('test','dev','prod')]
            [string]$NamedScope,

        [Parameter(Mandatory=$True,ParameterSetName='list',ValueFromPipeline=$true)]
            [string[]]$Computer
    )

    #Script initialization block:
    Begin {
        Set-PSDebug -Strict
        
        #Load the selected search module:
        $ModulePath = '.\SearchModules\' + $Module + '.ps1'

        ### Initialize Logging:
        $startTime = [datetime]::now
        $fileRoot = (Split-Path -Path $ModulePath -Leaf).Replace('.ps1','')
        $foundOutFile = '.\Logs\' + $fileRoot + '-found.csv'
        $failedOutFile = '.\Logs\' + $fileRoot + '-failed.csv'
        #Default log headers to be added to all CSV output
        $logHeaders = @('computer','status','message')

        if (-not (Test-Path .\Logs)) {New-Item -ItemType Directory -Name Logs | Out-Null}
        if (test-path $foundOutFile) {Remove-Item $foundOutFile -Confirm:$false -Force}
        if (test-path $failedOutFile) {Remove-Item $failedOutFile -Confirm:$false -Force}

        ### Import the selected script block:
        . $ModulePath

        # Check for module specific data headers:
        if (Get-Variable localHeaders -ErrorAction SilentlyContinue) {
            $logHeaders += $localHeaders
        } else {
            [string[]]$localHeaders = @()
        }

        ### Initialize and populate 'computers' array:
        [string[]]$computers = @()
        # Populate 'comptuers' when NamedScope parameter is used:
        if ($NamedScope) {
            try { Import-Module -name .\ScriptModules\MyOrgComputers.psm1 } catch {
                Throw "Failed to load the MyOrgComputers.psm1 script module."
            }
            write-host "A named scope was provided.  Searching:" $NamedScope
            $computers = Get-MyOrgComputers -scope $NamedScope
            Remove-Module MyOrgComputers
        }
    }

    #The 'Process' block is required to capture pipeline input:
    Process {
        #Populate 'computers' when pipeline or '-computer' parameter is used:
        foreach ($name in $computer) {
            $computers += $name
        }
    }

    #End block acts on data collected in the Begin or Process blocks:
    End {
        Write-Host 
        Write-Host 'Starting PowerShell Remoting Loop:' -Fore Cyan

        ### Start queue processing:
        # We are using a 'try' block to enable environment cleanup in case the user terminates the script prematurely:
        try {
        
            ### Import required PowerShell Script Modules:
            try { Import-Module -name .\ScriptMOdules\PSQueue.psm1 } catch {
                Throw "Failed to load the PSQueue.psm1 script module."
            }

            #$results object intended for debugging:
            #[pscustomobject[]]$results = @()
            Invoke-Queue -queue $computers -scriptBlock $block -maxWorkers $throttleLimit -cycleTime $cycleTime -timeout $timeout | ForEach-Object {
                #For debugging, capture to "results":
                #$results += $_

                #### Normalize the object to contain all standard headers and module-specific headers:
                #     (This is required to support Export-CSV, which gets angry if an input object is 
                #      missing field for a header in the current file.)
                $queueOut = $_ 
                # Discover properties of the current object in the pipeline:
                $outProps = $queueOut | Get-Member | Select-Object -ExpandProperty Name
                # Add any missing headers
                $logHeaders | ForEach-Object {if ($_ -notin $OutProps) {
                    Add-Member -InputObject $queueOut -MemberType NoteProperty -Name $_ -Value $null} 
                } 

                #if successful, write to $foundOutFile.  failures go to $failedOutFile
                if ($queueOut.status -match 'success') {
                    $queueOut | Select-Object -Property $logHeaders | Export-Csv -Path $foundOutFile -Append -NoTypeInformation
                } elseif ($queueOut.status -match 'failure') {
                    #if unsuccessful, write to $failedOutFile
                    $queueOut | Select-Object -Property $logHeaders | Export-Csv -Path $failedOutFile -Append -NoTypeInformation
                }

                #Also send to standard output:
                $queueOut
            }
        } finally { #If the user cancels during this loop, still force module cleanup:
            Remove-Module PSQueue
        }

        $endTime = [datetime]::Now
        $elapsedTime = $endTime - $startTime
        [string]$printTime = [string]($elapsedTime.days) + ' days ' + [string]($elapsedTime.hours) + `
            ' hours ' +  [string]($elapsedTime.minutes) + ' minutes ' + [string]($elapsedTime.seconds) `
            + ' seconds '
        
        write-host 'Elapsed Time:'  $printTime -ForegroundColor Cyan
    }
}

Export-ModuleMember -Function Start-FTLDrive