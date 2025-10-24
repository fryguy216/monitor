<#
.SYNOPSIS
    File Replication Monitor (PowerShell 5.1 Compatible)

.DESCRIPTION
    A PowerShell 5.1 script with a WPF GUI that monitors a source directory 
    (including UNC paths) for specified file changes. 
    
    When a change is detected, it uses parallel ThreadJobs to query a list of 
    web servers via HTTP/HTTPS to confirm if the file has replicated.

.NOTES
    Author:      Gemini
    Version:     1.1
    Requires:    PowerShell 5.1, .NET Framework 4.5+
    Dependencies: Automatically installs the 'ThreadJob' module if missing.
#>

#region Global Assembly and Type Definitions
# Load necessary .NET assemblies for WPF and Forms (for MessageBox)
try {
    Add-Type -AssemblyName PresentationFramework, System.Drawing, System.Windows.Forms
}
catch {
    Write-Error "Failed to load required .NET Assemblies. This script requires a Windows environment with .NET Framework."
    Exit 1
}
#endregion

#region Prerequisite: Check and Install ThreadJob Module
function Ensure-ThreadJobModule {
    # --- Force TLS 1.2 for web requests ---
    # This is crucial for PS 5.1 on older systems to talk to modern servers (like NuGet/PSGallery)
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-Warning "Could not set TLS 1.2. If module installation fails, this may be the cause."
    }

    if (-not (Get-Module -ListAvailable -Name ThreadJob)) {
        $message = "The required 'ThreadJob' module is not found.`n`nThis module is necessary for running high-performance, parallel web checks.`n`nDo you want to install it from the PowerShell Gallery (requires internet)?"
        $result = [System.Windows.Forms.MessageBox]::Show($message, "Module Required", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)

        if ($result -eq 'Yes') {
            try {
                Write-Host "Installing 'ThreadJob' module for the current user..."
                # Suppress progress bar for a cleaner console experience if run from there
                $ProgressPreference = 'SilentlyContinue'
                
                # --- Check for and install NuGet provider ---
                try {
                    # Get a list of *installed* package providers
                    $installedProviders = Get-PackageProvider | Select-Object -ExpandProperty Name
                    
                    if ('NuGet' -notin $installedProviders) {
                        Write-Host "NuGet package provider not found. Installing it non-interactively..."
                        # Install the provider for the current user, non-interactively
                        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force
                        Write-Host "NuGet provider installed."
                    } else {
                        Write-Host "NuGet provider is already installed."
                    }
                }
                catch {
                    # This catch block handles failures during the Install-PackageProvider step
                    # --- FIX 1: Made error message safer by getting Exception.Message ---
                    $errorMsg = "Failed to install the 'NuGet' provider. Error: $($_.Exception.Message)`n`nCannot proceed with module installation. Please check your internet connection and try again."
                    # --- FIX 2: Moved comma outside the ']' ---
                    [System.Windows.Forms.MessageBox]::Show($errorMsg, "Installation Failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                    return $false # Stop the function
                }
                # --- END NuGet Check ---

                Install-Module -Name ThreadJob -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
                Write-Host "'ThreadJob' module installed successfully."
            }
            catch {
                $errorMsg = "Failed to install the 'ThreadJob' module. Error: $_`n`nParallel checking will be disabled. Please install the module manually."
                [System.Windows.Forms.MessageBox]::Show($errorMsg, "Installation Failed", [System.Windows.Forms.MessageBoxButtons::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                return $false
            }
            finally {
                # Restore user's original preference
                $ProgressPreference = 'Continue'
            }
        }
        else {
            # User clicked 'No'
            return $false
        }
    }

    # Import it for the current session
    try {
        Import-Module -Name ThreadJob
        return $true
    }
    catch {
        Write-Error "Failed to import the 'ThreadJob' module even after installation."
        return $false
    }
}
#endregion

#region Thread-Safe GUI Updater Class
# This class ensures that updates to GUI elements from background threads
# (like FileSystemWatcher or ThreadJobs) are done safely.
class SynchronizedTextUpdater {
    [System.Windows.Threading.Dispatcher]$dispatcher
    [System.Windows.Controls.TextBox]$textBox
    [System.Windows.Controls.Primitives.StatusBarItem]$statusLabel

    SynchronizedTextUpdater(
        [System.Windows.Threading.Dispatcher]$dispatcher,
        [System.Windows.Controls.TextBox]$textBox,
        [System.Windows.Controls.Primitives.StatusBarItem]$statusLabel
    ) {
        $this.dispatcher = $dispatcher
        $this.textBox = $textBox
        $this.statusLabel = $statusLabel
    }

    # Log to the main text box
    Log([string]$message) {
        if ($this.dispatcher.CheckAccess()) {
            # We are on the GUI thread, update directly
            $this.textBox.AppendText("$(Get-Date -Format 'HH:mm:ss') - $message`n")
            $this.textBox.ScrollToEnd()
        }
        else {
            # We are on a background thread, invoke the update
            $this.dispatcher.Invoke(
                [Action[string]] {
                    param([string]$msg)
                    $this.textBox.AppendText("$(Get-Date -Format 'HH:mm:ss') - $msg`n")
                    $this.textBox.ScrollToEnd()
                },
                $message
            )
        }
    }

    # Set the status bar text
    SetText([string]$message) {
        if ($this.dispatcher.CheckAccess()) {
            $this.statusLabel.Content = $message
        }
        else {
            $this.dispatcher.Invoke(
                [Action[string]] {
                    param([string]$msg)
                    $this.statusLabel.Content = $msg
                },
                $message
            )
        }
    }
}
#endregion

# Global variable for the watcher
$global:FileSystemWatcher = $null

#region WPF XAML Definition
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="File Replication Monitor" Height="500" Width="700" MinHeight="400" MinWidth="500">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>
        
        <Grid Grid.Row="0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto" />
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
            </Grid.RowDefinitions>

            <Label Grid.Row="0" Grid.Column="0" Content="Source Path (UNC):" VerticalAlignment="Center" Margin="5" />
            <TextBox Grid.Row="0" Grid.Column="1" Name="pathBox" Margin="5" VerticalAlignment="Center" />

            <Label Grid.Row="1" Grid.Column="0" Content="File Filter:" VerticalAlignment="Center" Margin="5" />
            <TextBox Grid.Row="1" Grid.Column="1" Name="filterBox" Margin="5" VerticalAlignment="Center" ToolTip="e.g., *.xml, specific_file.dat" />

            <Label Grid.Row="2" Grid.Column="0" Content="Web Servers:" VerticalAlignment="Center" Margin="5" />
            <TextBox Grid.Row="2" Grid.Column="1" Name="serversBox" Height="60" Margin="5" VerticalAlignment="Center" TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                     ToolTip="One server URL per line, e.g., https://server1.com/files/" />

            <StackPanel Grid.Row="0" Grid.Column="2" Grid.RowSpan="3" Margin="10,5,5,5" VerticalAlignment="Top">
                <Button Name="startButton" Content="Start Monitoring" Margin="5" Padding="10,5" Background="#FF4CAF50" Foreground="White" FontWeight="Bold" />
                <Button Name="stopButton" Content="Stop Monitoring" Margin="5" Padding="10,5" Background="#FFF44336" Foreground="White" FontWeight="Bold" IsEnabled="False" />
            </StackPanel>
        </Grid>

        <TextBox Grid.Row="1" Name="logBox" Margin="5,10,5,5" IsReadOnly="True" VerticalScrollBarVisibility="Auto" 
                 FontFamily="Consolas" FontSize="12" Background="#FFF0F0F0" />

        <StatusBar Grid.Row="2" Margin="5,0,5,0">
            <StatusBarItem Name="statusBar" Content="Ready" />
        </StatusBar>
    </Grid>
</Window>
"@
#endregion

#region GUI Element Initialization
try {
    $reader = (New-Object System.Xml.XmlNodeReader $xaml)
    $Window = [System.Windows.Markup.XamlReader]::Load($reader)
}
catch {
    Write-Error "Failed to load WPF XAML. Error: $_"
    Exit 1
}

# Find all the named controls
$logBox = $Window.FindName("logBox")
$statusBar = $Window.FindName("statusBar")
$startButton = $Window.FindName("startButton")
$stopButton = $Window.FindName("stopButton")
$pathBox = $Window.FindName("pathBox")
$filterBox = $Window.FindName("filterBox")
$serversBox = $Window.FindName("serversBox")

# Create thread-safe updaters
$logSync = [SynchronizedTextUpdater]::new($Window.Dispatcher, $logBox, $null)
$statusSync = [SynchronizedTextUpdater]::new($Window.Dispatcher, $null, $statusBar)
#endregion

#region GUI Event Handlers

# --- Start Button Click ---
$startButton.Add_Click({
    param($sender, $e)

    $startButton.IsEnabled = $false
    $pathBox.IsEnabled = $false
    $filterBox.IsEnabled = $false
    $serversBox.IsEnabled = $false
    $statusSync.SetText("Starting...")

    $sourcePath = $pathBox.Text
    $filter = $filterBox.Text
    $serverListRaw = $serversBox.Text

    # --- Input Validation ---
    if ([string]::IsNullOrWhiteSpace($sourcePath) -or [string]::IsNullOrWhiteSpace($filter) -or [string]::IsNullOrWhiteSpace($serverListRaw)) {
        $logSync.Log("Error: Source Path, File Filter, and Web Servers cannot be empty.")
        $statusSync.SetText("Error: All fields are required.")
        $startButton.IsEnabled = $true
        $pathBox.IsEnabled = $true
        $filterBox.IsEnabled = $true
        $serversBox.IsEnabled = $true
        return
    }

    if (-not (Test-Path $sourcePath)) {
        $logSync.Log("Error: Source Path '$sourcePath' is not accessible.")
        $statusSync.SetText("Error: Source Path not found.")
        $startButton.IsEnabled = $true
        $pathBox.IsEnabled = $true
        $filterBox.IsEnabled = $true
        $serversBox.IsEnabled = $true
        return
    }

    $serverList = $serverListRaw.Split([string[]]@("`r`n", "`n"), [StringSplitOptions]::RemoveEmptyEntries)
    $logSync.Log("Monitoring path: $sourcePath")
    $logSync.Log("Using filter: $filter")
    $logSync.Log("Checking servers: $($serverList -join ', ')")

    # --- Define the Action Block for File Events ---
    # This block runs in the background event thread
    $action = {
        param($event)
        
        # Get thread-safe updaters and data from $using scope
        $logSync = $using:logSync
        $statusSync = $using:statusSync
        $serverList = $using:serverList
        $sourcePath = $using:sourcePath

        # Handle the event data
        $fullPath = $event.FullPath
        $name = $event.Name
        $changeType = $event.ChangeType

        if ($changeType -eq 'Renamed') {
            # For rename events, log both old and new
            $logSync.Log("File Event: Renamed - '$($event.OldName)' to '$name'")
        } else {
            $logSync.Log("File Event: $changeType - $fullPath")
        }
        
        $statusSync.SetText("Change detected: $name")

        # --- Define local helper function for web check ---
        # This function runs inside the ThreadJob
        function Check-FileReplication {
            param(
                [string]$server,
                [string]$fileName,
                [string]$fullSourcePath,
                [System.IO.FileSystemWatcherChangeTypes]$changeType
            )
            
            # Ensure the server URL ends with a slash
            if (-not $server.EndsWith('/')) { $server += '/' }
            $targetUri = $server + $fileName

            try {
                if ($changeType -eq 'Deleted') {
                    # For a delete, we expect a 404
                    $response = Invoke-WebRequest -Uri $targetUri -Method Head -TimeoutSec 10 -SkipCertificateCheck
                    # If we get anything *but* 404 (like 200), it's a failure.
                    return "[DELETE] `t[$server] FAILED: File still exists (HTTP $($response.StatusCode))."
                }
                else {
                    # For Create/Change/Rename, we expect a 200
                    $response = Invoke-WebRequest -Uri $targetUri -Method Head -TimeoutSec 10 -SkipCertificateCheck
                    
                    if ($response.StatusCode -eq 200) {
                        # --- Advanced Check: Compare Last-Modified ---
                        try {
                            $sourceFile = Get-Item -LiteralPath $fullSourcePath
                            $sourceWriteTime = $sourceFile.LastWriteTimeUtc
                            $serverWriteTime = [DateTime]$response.Headers.'Last-Modified'
                            
                            # Allow a small grace period (e.g., 5 seconds) for replication time skew
                            if ($sourceWriteTime -le $serverWriteTime.AddSeconds(5)) {
                                return "[MODIFIED] `t[$server] SUCCESS: File found (HTTP 200) and timestamp is current."
                            } else {
                                return "[MODIFIED] `t[$server] WARNING: File found, but is STALE. (Server: $serverWriteTime, Source: $sourceWriteTime)"
                            }
                        }
                        catch {
                            # Fallback if Get-Item fails (rare) or header is missing/invalid
                            return "[MODIFIED] `t[$server] SUCCESS: File found (HTTP 200). (Timestamp check failed: $_)"
                        }
                    }
                    else {
                        # This should not happen if status is 200, but as a fallback.
                        return "[MODIFIED] `t[$server] FAILED: File check returned unexpected status (HTTP $($response.StatusCode))."
                    }
                }
            }
            catch [System.Net.WebException] {
                $statusCode = [int]$_.Exception.Response.StatusCode
                if ($changeType -eq 'Deleted') {
                    if ($statusCode -eq 404) {
                        return "[DELETE] `t[$server] SUCCESS: File confirmed deleted (HTTP 404)."
                    } else {
                        return "[DELETE] `t[$server] FAILED: Unexpected HTTP $statusCode."
                    }
                }
                else {
                    # For Create/Change/Rename, a 404 means it's not replicated yet
                    if ($statusCode -eq 404) {
                        return "[MODIFIED] `t[$server] FAILED: File not found (HTTP 404)."
                    } else {
                        return "[MODIFIED] `t[$server] FAILED: HTTP $statusCode."
                    }
                }
            }
            catch {
                return "[ERROR] `t[$server] FAILED: $_.Exception.Message"
            }
        }
        # --- End helper function ---

        $logSync.Log("...Starting parallel replication check for '$name'...")
        
        # Start a job for each server
        foreach ($server in $serverList) {
            $checkScriptBlock = {
                param($server, $fileName, $fullSourcePath, $changeType)
                
                # Re-define the helper function within the ThreadJob scope
                function Check-FileReplication {
                    param(
                        [string]$server,
                        [string]$fileName,
                        [string]$fullSourcePath,
                        [System.IO.FileSystemWatcherChangeTypes]$changeType
                    )
                    
                    if (-not $server.EndsWith('/')) { $server += '/' }
                    $targetUri = $server + $fileName

                    try {
                        if ($changeType -eq 'Deleted') {
                            $response = Invoke-WebRequest -Uri $targetUri -Method Head -TimeoutSec 10 -SkipCertificateCheck
                            return "[DELETE] `t[$server] FAILED: File still exists (HTTP $($response.StatusCode))."
                        }
                        else {
                            $response = Invoke-WebRequest -Uri $targetUri -Method Head -TimeoutSec 10 -SkipCertificateCheck
                            
                            if ($response.StatusCode -eq 200) {
                                try {
                                    $sourceFile = Get-Item -LiteralPath $fullSourcePath
                                    $sourceWriteTime = $sourceFile.LastWriteTimeUtc
                                    # Ensure we parse the header as a DateTime object
                                    $serverWriteTime = [DateTime]$response.Headers.'Last-Modified'
                                    
                                    if ($sourceWriteTime -le $serverWriteTime.AddSeconds(5)) {
                                        return "[MODIFIED] `t[$server] SUCCESS: File found (HTTP 200) and timestamp is current."
                                    } else {
                                        return "[MODIFIED] `t[$server] WARNING: File found, but is STALE. (Server: $serverWriteTime, Source: $sourceWriteTime)"
                                    }
                                }
                                catch {
                                    return "[MODIFIED] `t[$server] SUCCESS: File found (HTTP 200). (Timestamp check failed: $_)"
                                }
                            }
                            else {
                                return "[MODIFIED] `t[$server] FAILED: File check returned unexpected status (HTTP $($response.StatusCode))."
                            }
                        }
                    }
                    catch [System.Net.WebException] {
                        $statusCode = 0
                        if ($_.Exception.Response) {
                            $statusCode = [int]$_.Exception.Response.StatusCode
                        }
                        
                        if ($changeType -eq 'Deleted') {
                            if ($statusCode -eq 404) {
                                return "[DELETE] `t[$server] SUCCESS: File confirmed deleted (HTTP 404)."
                            } else {
                                return "[DELETE] `t[$server] FAILED: Unexpected HTTP $statusCode. ($($_.Exception.Message))"
                            }
                        }
                        else {
                            if ($statusCode -eq 404) {
                                return "[MODIFIED] `t[$server] FAILED: File not found (HTTP 404)."
                            } else {
                                return "[MODIFIED] `t[$server] FAILED: HTTP $statusCode. ($($_.Exception.Message))"
                            }
                        }
                    }
                    catch {
                        return "[ERROR] `t[$server] FAILED: $_"
                    }
                } # End Check-FileReplication function in ThreadJob
                
                # Call the function
                Check-FileReplication -server $server -fileName $fileName -fullSourcePath $fullSourcePath -changeType $changeType
            } # End $checkScriptBlock
            
            # We pass $name, not $fullPath, as the filename to check on the server
            # We pass $fullPath so we can check Get-Item on it for timestamp
            Start-ThreadJob -ScriptBlock $checkScriptBlock -ArgumentList @($server, $name, $fullPath, $changeType) -Name "Check_$(Get-Random)"
        } # End foreach server

        # Wait for all jobs to finish
        while (Get-Job -State 'Running' | Where-Object { $_.Name -like "Check_*" }) {
            Start-Sleep -Milliseconds 250
        }

        $logSync.Log("...Replication check finished for '$name'...")
        
        # Collect and log results
        $jobs = Get-Job | Where-Object { $_.Name -like "Check_*" }
        foreach ($job in $jobs) {
            $result = Receive-Job $job
            $logSync.Log($result)
            Remove-Job $job
        }

        $statusSync.SetText("Monitoring...")
    } # --- End Action Block ---

    try {
        # --- Create and Configure FileSystemWatcher ---
        $global:FileSystemWatcher = New-Object System.IO.FileSystemWatcher($sourcePath, $filter)
        $watcher = $global:FileSystemWatcher # Local alias
        
        $watcher.IncludeSubdirectories = $false
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName, 
                                [System.IO.NotifyFilters]::LastWrite
        
        # Register for all event types
        $eventsToMonitor = @('Created', 'Changed', 'Deleted', 'Renamed')
        foreach ($event in $eventsToMonitor) {
            Register-ObjectEvent -InputObject $watcher -EventName $event -SourceIdentifier "File.$event" -Action $action
        }

        $watcher.EnableRaisingEvents = $true
        $logSync.Log("--- Monitoring started successfully ---")
        $statusSync.SetText("Monitoring...")
        $stopButton.IsEnabled = $true
    }
    catch {
        $logSync.Log("FATAL ERROR: Failed to start FileSystemWatcher. $_")
        $statusSync.SetText("Error: Could not start watcher.")
        $startButton.IsEnabled = $true
        $pathBox.IsEnabled = $true
        $filterBox.IsEnabled = $true
        $serversBox.IsEnabled = $true
    }
})

# --- Stop Button Click ---
$stopButton.Add_Click({
    param($sender, $e)
    
    $startButton.IsEnabled = $false
    $stopButton.IsEnabled = $false
    $statusSync.SetText("Stopping...")

    if ($null -ne $global:FileSystemWatcher) {
        $global:FileSystemWatcher.EnableRaisingEvents = $false
        
        # Unregister all our file events
        Get-EventSubscriber -SourceIdentifier "File.*" | Unregister-Event
        
        $global:FileSystemWatcher.Dispose()
        $global:FileSystemWatcher = $null
    }

    # Clean up any jobs that might be running
    try {
        Get-Job -Name "Check_*" | Stop-Job -ErrorAction SilentlyContinue | Remove-Job -ErrorAction SilentlyContinue
    }
    catch {
        $logSync.Log("Note: Error while cleaning up background jobs (this is usually safe): $_")
    }

    $logSync.Log("--- Monitoring stopped ---")
    $statusSync.SetText("Stopped")

    $startButton.IsEnabled = $true
    $pathBox.IsEnabled = $true
    $filterBox.IsEnabled = $true
    $serversBox.IsEnabled = $true
})

# --- Window Closing Event ---
$Window.Add_Closing({
    param($sender, $e)
    
    # Ensure monitoring is stopped and resources are cleaned up
    if ($stopButton.IsEnabled) {
        # Use RaiseEvent to trigger the existing Add_Click logic
        $stopButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
    }
})

#endregion

#region Script Main Execution
# Check for module and set initial status
$moduleReady = Ensure-ThreadJobModule
if (-not $moduleReady) {
    $statusSync.SetText("Ready (ThreadJob module not loaded)")
    $logSync.Log("Warning: 'ThreadJob' module not loaded. Checks will not be performed.")
    # We don't disable the start button, but the action block will fail
    # Let's actually disable it.
    $startButton.IsEnabled = $false
    $startButton.Content = "Module Missing"
    $startButton.ToolTip = "The 'ThreadJob' module is required. Please restart the script and allow installation."
    $logSync.Log("Error: Start button disabled. Please restart and install the 'ThreadJob' module.")
}
else {
    $statusSync.SetText("Ready")
}

# Show the window
$Window.ShowDialog() | Out-Null
#endregion


