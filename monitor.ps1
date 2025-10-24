<#
.SYNOPSIS
    A PowerShell 5.1 compatible script with a GUI to monitor a source 
    directory (including UNC paths) for file changes and verify replication
    to a list of web servers via HTTP/HTTPS.

.DESCRIPTION
    This tool provides a WPF interface to:
    1. Define a source path, file filter (*.xml, *.js, etc.), and a list of web servers.
    2. Start a monitor that uses .NET FileSystemWatcher.
    3. When a file is created, changed, or deleted, it logs the event.
    4. It then starts parallel background jobs (using ThreadJob) to check the
       replication status of that file on each web server.
    5. It checks for file existence using an HTTP HEAD request and logs the status code.
    6. All actions are logged to the main window.
    7. It includes a check for the 'ThreadJob' module and will prompt for
       installation if it's not found, as it is required for parallel checks.

.NOTES
    Author: Gemini
    Requires: PowerShell 5.1
    Dependencies: 'ThreadJob' module (script will offer to install)
#>

#region Prerequisite: Add WPF and Windows Forms Assemblies
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms # For MessageBox
#endregion

#region Prerequisite: Check and Install ThreadJob Module
function Ensure-ThreadJobModule {
    # --- ADDED: Force TLS 1.2 for web requests ---
    # This is crucial for PS 5.1 on older systems to talk to modern servers (like NuGet)
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    # --- END ADDED SECTION ---

    if (-not (Get-Module -ListAvailable -Name ThreadJob)) {
        $message = "The required 'ThreadJob' module is not found.`n`nThis module is necessary for running high-performance, parallel web checks.`n`nDo you want to install it from the PowerShell Gallery (requires internet)?"
        $result = [System.Windows.Forms.MessageBox]::Show($message, "Missing Dependency", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        
        if ($result -eq 'Yes') {
            try {
            # Check just the headers first. This is faster.
            $response = Invoke-WebRequest -Uri $targetUri -Method Head -TimeoutSec 10 -SkipCertificateCheck
            
            if ($response.StatusCode -eq 200) {
                $logSync.Log("`t[$server] SUCCESS: File found (HTTP 200).")
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
                    $errorMsg = "Failed to install the 'NuGet' provider. Error: $_`n`nCannot proceed with module installation. Please check your internet connection and try again."
                    [System.Windows.Forms.MessageBox]::Show($errorMsg, "Installation Failed", [System.Windows.Forms.MessageBoxButtons::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                    return $false # Stop the function
                }
                # --- END CORRECTED SECTION ---

                Install-Module -Name ThreadJob -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
                Write-Host "'ThreadJob' module installed successfully."
                # Import it for the current session
                Import-Module ThreadJob
            }
            catch {
                $errorMsg = "Failed to install 'ThreadJob' module. Error: $_`n`nScript will exit. Please install the module manually and try again."
                [System.Windows.Forms.MessageBox]::Show($errorMsg, "Installation Failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                return $false
            }
            finally {
                # Restore preference
                $ProgressPreference = 'Continue'
            }
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Script cannot run without the 'ThreadJob' module. Exiting.", "Dependency Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Exclamation)
            return $false
        }
    }
    return $true
}

# Run the dependency check. If it fails or user cancels, exit.
if (-not (Ensure-ThreadJobModule)) {
    # Exit the script cleanly if the dependency isn't met.
    return
}
#endregion

#region XAML GUI Definition
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="File Replication Monitor (PS 5.1)" Height="700" Width="800" MinHeight="450" MinWidth="600">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <!-- Configuration Section -->
        <GroupBox Header="Configuration" Grid.Row="0" Padding="5">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                
                <Label Content="_Source Path (UNC):" Grid.Row="0" Grid.Column="0" VerticalAlignment="Center" Target="{Binding ElementName=SourcePathBox}"/>
                <TextBox x:Name="SourcePathBox" Grid.Row="0" Grid.Column="1" Margin="5" VerticalAlignment="Center" ToolTip="Enter the full directory path to monitor (e.g., \\server\share\content)"/>
                
                <Label Content="_File Filter:" Grid.Row="1" Grid.Column="0" VerticalAlignment="Center" Target="{Binding ElementName=FilterBox}"/>
                <TextBox x:Name="FilterBox" Grid.Row="1" Grid.Column="1" Margin="5" VerticalAlignment="Center" Text="*.*" ToolTip="Enter the file pattern to watch (e.g., *.xml, *.js, data_*.dat)"/>
                
                <Label Content="_Web Servers (one per line):" Grid.Row="2" Grid.Column="0" VerticalAlignment="Top" Margin="0,5,0,0" Target="{Binding ElementName=ServerListBox}"/>
                <TextBox x:Name="ServerListBox" Grid.Row="2" Grid.Column="1" Margin="5" Height="100" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" ToolTip="Enter server base URLs (e.g., http://web01.example.com, https://web02.example.com)"/>
            </Grid>
        </GroupBox>
        
        <!-- Control Buttons -->
        <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,10,0,0">
            <Button x:Name="StartButton" Content="Start Monitoring" Width="150" Height="30" Margin="5" Background="#FF4CAF50" Foreground="White" FontWeight="Bold"/>
            <Button x:Name="StopButton" Content="Stop Monitoring" Width="150" Height="30" Margin="5" IsEnabled="False" Background="#FFF44336" Foreground="White" FontWeight="Bold"/>
        </StackPanel>
        
        <!-- Status Label -->
        <Label x:Name="StatusLabel" Grid.Row="2" Content="Status: Stopped" HorizontalAlignment="Center" Margin="0,5,0,10" FontSize="14" FontWeight="Bold" Foreground="#FF888888"/>
        
        <!-- Log Output -->
        <GroupBox Header="Event Log" Grid.Row="3" Padding="5">
            <TextBox x:Name="LogBox" IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12" Background="#FFF3F3F3"/>
        </GroupBox>
        
        <!-- Clear Log Button -->
        <Button x:Name="ClearLogButton" Content="Clear Log" Grid.Row="4" Width="100" Height="25" Margin="0,10,0,0" HorizontalAlignment="Right"/>
    </Grid>
</Window>
"@
#endregion

#region Create and Link GUI Elements
try {
    # Create the XAML reader
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $form = [System.Windows.Markup.XamlReader]::Load($reader)
}
catch {
    [System.Windows.Forms.MessageBox]::Show("Failed to load GUI: $_", "XAML Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    return
}

# Store controls in a hash table for easy access
$controls = @{}
$xaml.SelectNodes("//*[@x:Name]") | ForEach-Object {
    $controls[$_.x_Name] = $form.FindName($_.x_Name)
}

# Create global variables to hold the watcher and event subscribers
$global:fileWatcher = $null
$global:eventSubscribers = @()
#endregion

#region Helper Functions
# Helper to safely update the GUI from other threads
function Write-Log {
    param(
        [string]$Message
    )
    
    # This block ensures we are updating the GUI on its main thread
    $controls.LogBox.Dispatcher.Invoke([Action]{
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $controls.LogBox.AppendText("[$timestamp] $Message`n")
        $controls.LogBox.ScrollToEnd()
    }, [System.Windows.Threading.DispatcherPriority]::Background)
}

# Helper to update the status label
function Update-Status {
    param(
        [string]$Message,
        [string]$Color
    )
    
    $controls.StatusLabel.Dispatcher.Invoke([Action]{
        $controls.StatusLabel.Content = "Status: $Message"
        $controls.StatusLabel.Foreground = $Color
    }, [System.Windows.Threading.DispatcherPriority]::Background)
}
#endregion

#region Button: Start Monitoring
$controls.StartButton.Add_Click({
    # --- 1. Validate Input ---
    $sourcePath = $controls.SourcePathBox.Text
    $fileFilter = $controls.FilterBox.Text
    $servers = $controls.ServerListBox.Text.Split([string[]]@("`r`n", "`n"), [StringSplitOptions]::RemoveEmptyEntries)
    
    if (-not (Test-Path -Path $sourcePath)) {
        [System.Windows.Forms.MessageBox]::Show("The specified Source Path does not exist or is not accessible.", "Invalid Path", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    
    if ($servers.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please enter at least one web server URL.", "No Servers", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    
    # Store server list in a global var for the event handler to access
    $global:serverList = $servers
    $global:sourcePath = $sourcePath

    # --- 2. Configure FileSystemWatcher ---
    try {
        $global:fileWatcher = New-Object System.IO.FileSystemWatcher
        $global:fileWatcher.Path = $sourcePath
        $global:fileWatcher.Filter = $fileFilter
        $global:fileWatcher.IncludeSubdirectories = $true
        $global:fileWatcher.NotifyFilter = [System.IO.NotifyFilters]::FileName, [System.IO.NotifyFilters]::LastWrite
        
        # --- 3. Define the Action Block for Events ---
        # This script block will be executed when a file event fires
        $actionBlock = {
            param($event)
            
            $eventType = $event.SourceEventArgs.ChangeType
            $fullPath = $event.SourceEventArgs.FullPath
            $fileName = $event.SourceEventArgs.Name
            
            Write-Log "EVENT: [$eventType] $fileName"
            
            # We need to get the server list and source path from the global scope
            $serversToCheck = $global:serverList
            $basePath = $global:sourcePath
            
            # Calculate the relative path for the web server
            # e.g., \\server\share\css\style.css -> /css/style.css
            $relativePath = $fullPath.Replace($basePath, "").Replace("\", "/")
            if ($relativePath -notlike "/*") {
                $relativePath = "/$relativePath"
            }
            
            Write-Log "File: $relativePath. Starting replication check on $($serversToCheck.Count) server(s)..."
            
            # --- 4. Start Parallel Web Checks using ThreadJob ---
            $job = Start-ThreadJob -ScriptBlock {
                param($servers, $relPath, $fileEventType)
                
                $results = @()
                
                # This code runs in a separate thread
                foreach ($server in $servers) {
                    $uri = "$($server.TrimEnd('/'))$($relPath)"
                    $result = @{
                        Server = $server
                        Uri = $uri
                        StatusCode = $null
                        Status = "Error"
                    }
                    
                    try {
                        # We use -Method Head for efficiency. We don't need the file content, just its status.
                        # For 'Deleted' events, we expect a 404. For 'Created'/'Changed', we expect a 200.
                        Invoke-WebRequest -Uri $uri -Method Head -TimeoutSec 10 -UseBasicParsing
                        
                        # If the request succeeds, it means a 2xx status (like 200 OK)
                        $result.StatusCode = 200 # Note: $Error[0].Exception.Response.StatusCode is not available on success
                        
                        if ($fileEventType -eq 'Deleted') {
                            $result.Status = "FAIL (File still exists)"
                        } else {
                            $result.Status = "OK (File exists)"
                        }
                    }
                    catch {
                        # If the request fails (e.g., 404, 500, timeout), the error is in $_
                        $response = $_.Exception.Response
                        if ($response) {
                            $statusCode = [int]$response.StatusCode
                            $result.StatusCode = $statusCode
                            
                            if ($fileEventType -eq 'Deleted' -and $statusCode -eq 404) {
                                $result.Status = "OK (File deleted)"
                            } elseif ($fileEventType -ne 'Deleted' -and $statusCode -eq 404) {
                                $result.Status = "FAIL (File not found)"
                            } else {
                                $result.Status = "FAIL (HTTP $statusCode)"
                            }
                        } else {
                            $result.Status = "FAIL (No response/Timeout)"
                        }
                    }
                    $results += $result
                }
                return $results
            } -ArgumentList $serversToCheck, $relativePath, $eventType
            
            # --- 5. Asynchronously Handle Job Completion ---
            # We register an event on the job itself. This avoids blocking the GUI or the FileWatcher thread.
            $jobEvent = Register-ObjectEvent -InputObject $job -EventName StateChanged -Action {
                param($jobData)

                # Check if the job that fired the event is 'Completed'
                if ($jobData.SourceEventArgs.JobStateInfo.State -eq [System.Management.Automation.JobState]::Completed) {
                    $completedJob = $jobData.Sender
                    $results = Receive-Job -Job $completedJob
                    
                    Write-Log "CHECK COMPLETE for $($jobData.SourceEventArgs.JobStateInfo.Name):"
                    
                    foreach ($res in $results) {
                        Write-Log "  -> $($res.Server): $($res.Status) (URI: $($res.Uri))"
                    }
                    
                    # Clean up the event and job
                    Unregister-Event -SubscriptionId $jobData.SubscriptionId
                    Remove-Job -Job $completedJob
                }
                # Also handle failed jobs
                elseif ($jobData.SourceEventArgs.JobStateInfo.State -eq [System.Management.Automation.JobState]::Failed) {
                    $failedJob = $jobData.Sender
                    Write-Log "ERROR: Web check job failed: $($failedJob.JobStateInfo.Reason.Message)"
                    
                    Unregister-Event -SubscriptionId $jobData.SubscriptionId
                    Remove-Job -Job $failedJob
                }
            }
            # Add this job's event subscriber to the global list for cleanup
            $global:eventSubscribers += $jobEvent
        }
        
        # --- 6. Register Events ---
        $eventsToWatch = @("Created", "Changed", "Deleted", "Renamed")
        foreach ($event in $eventsToWatch) {
            $subscriber = Register-ObjectEvent -InputObject $global:fileWatcher -EventName $event -Action $actionBlock
            $global:eventSubscribers += $subscriber
        }
        
        # --- 7. Start Monitoring ---
        $global:fileWatcher.EnableRaisingEvents = $true
        
        # Update GUI state
        $controls.StartButton.IsEnabled = $false
        $controls.StopButton.IsEnabled = $true
        $controls.SourcePathBox.IsReadOnly = $true
        $controls.FilterBox.IsReadOnly = $true
        $controls.ServerListBox.IsReadOnly = $true
        
        Update-Status "Monitoring..." "#FF4CAF50"
        Write-Log "--- Monitoring started on $sourcePath (Filter: $fileFilter) ---"
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to start monitor: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})
#endregion

#region Button: Stop Monitoring
$controls.StopButton.Add_Click({
    Write-Log "--- Stopping monitor... ---"
    
    try {
        if ($global:fileWatcher) {
            $global:fileWatcher.EnableRaisingEvents = $false
            $global:fileWatcher.Dispose()
            $global:fileTwoWatcher = $null
        }
        
        # Unregister all FileSystemWatcher and Job events
        foreach ($subscriber in $global:eventSubscribers) {
            Unregister-Event -SubscriptionId $subscriber.Id
        }
        $global:eventSubscribers = @()
        
        # Clean up any lingering jobs
        Get-Job | Where-Object { $_.State -eq 'Running' } | Stop-Job
        Get-Job | Remove-Job
    }
    catch {
        Write-Log "Error during cleanup: $_"
    }
    
    # Update GUI state
    $controls.StartButton.IsEnabled = $true
    $controls.StopButton.IsEnabled = $false
    $controls.SourcePathBox.IsReadOnly = $false
    $controls.FilterBox.IsReadOnly = $false
    $controls.ServerListBox.IsReadOnly = $false
    
    Update-Status "Stopped" "#FFF44336"
    Write-Log "--- Monitor stopped. ---"
})
#endregion

#region Button: Clear Log
$controls.ClearLogButton.Add_Click({
    $controls.LogBox.Clear()
})
#endregion

#region Form Closing Event
$form.Add_Closing({
    # Ensure monitoring is stopped and resources are released
    if ($controls.StopButton.IsEnabled) {
        $controls.StopButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
    }
})
#endregion

#region Show GUI
# Show the form
Write-Host "Starting File Replication Monitor GUI..."
$form.ShowDialog() | Out-Null
#endregion




