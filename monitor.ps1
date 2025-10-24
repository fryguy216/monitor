#Requires -Version 5.1
# No longer using #Requires for ThreadJob, as we will handle the dependency check manually.

param(
    [string]$UNCPath = '\\FileServer\Share\Path',
    [string]$WebServerUrls = @('http://webserver01', 'http://webserver02'),
    [string]$FileFilter = '*.xml',
    [string]$HashAlgorithm = 'SHA256'
)

# --- Dependency Check for ThreadJob Module ---
if (-not (Get-Module -ListAvailable -Name ThreadJob)) {
    Write-Host "The 'ThreadJob' module is required for parallel operations but is not installed." -ForegroundColor Yellow
    $prompt = Read-Host "Would you like to attempt to install it from the PowerShell Gallery? (Y/N)"
    if ($prompt -match '^') {
        try {
            Write-Host "Installing 'ThreadJob' module for the current user. This may take a moment..." -ForegroundColor Green
            # Install for the current user to avoid requiring admin rights
            Install-Module -Name ThreadJob -Force -Scope CurrentUser
            Write-Host "'ThreadJob' module installed successfully." -ForegroundColor Green
        }
        catch {
            Write-Host "Error: Failed to install the 'ThreadJob' module." -ForegroundColor Red
            Write-Host "Please ensure you have an internet connection and that your execution policy allows script installation." -ForegroundColor Red
            Write-Host "You can try installing it manually by running: Install-Module -Name ThreadJob -Scope CurrentUser" -ForegroundColor Red
            # Pause to allow the user to read the error before exiting.
            Read-Host "Press Enter to exit."
            exit
        }
    }
    else {
        Write-Host "Installation declined. The script cannot continue without the 'ThreadJob' module." -ForegroundColor Red
        Read-Host "Press Enter to exit."
        exit
    }
}

# --- ---
# The UI is defined using XAML for a clean separation of presentation and logic.
Add-Type -AssemblyName PresentationFramework
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="File Replication Monitor" Height="600" Width="950" WindowStartupLocation="CenterScreen">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Orientation="Vertical">
            <Label Content="UNC Path to Monitor:"/>
            <TextBox x:Name="UncPathTextBox" Text="$UNCPath"/>
        </StackPanel>

        <StackPanel Grid.Row="1" Orientation="Vertical" Margin="0,10,0,0">
            <Label Content="Web Server Base URLs (comma-separated):"/>
            <TextBox x:Name="WebServersTextBox" Text="$($WebServerUrls -join ',')" TextWrapping="Wrap"/>
        </StackPanel>

        <Grid Grid.Row="2" Margin="0,10,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Vertical">
                <Label Content="File Filter:"/>
                <TextBox x:Name="FileFilterTextBox" Text="$FileFilter"/>
            </StackPanel>
            <Button x:Name="StartButton" Content="Start Monitoring" Grid.Column="1" Width="120" Height="30" Margin="10,0,0,0" VerticalAlignment="Bottom"/>
            <Button x:Name="StopButton" Content="Stop Monitoring" Grid.Column="2" Width="120" Height="30" Margin="10,0,0,0" VerticalAlignment="Bottom" IsEnabled="False"/>
        </Grid>

        <DataGrid x:Name="LogDataGrid" Grid.Row="3" Margin="0,15,0,0" AutoGenerateColumns="False" IsReadOnly="True">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Timestamp" Binding="{Binding Timestamp}" Width="150"/>
                <DataGridTextColumn Header="File Path" Binding="{Binding FilePath}" Width="*"/>
                <DataGridTextColumn Header="Server" Binding="{Binding Server}" Width="150"/>
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="100"/>
                <DataGridTextColumn Header="Details" Binding="{Binding Details}" Width="2*"/>
            </DataGrid.Columns>
        </DataGrid>

        <StatusBar Grid.Row="4" Margin="0,5,0,0">
            <StatusBarItem>
                <TextBlock x:Name="StatusTextBlock" Text="Status: Stopped"/>
            </StatusBarItem>
        </StatusBar>
    </Grid>
</Window>
"@

# --- ---
# Global variables are used to maintain state across different parts of the script,
# including the UI thread and background jobs.

# HttpClient Singleton: A single instance is created and reused for all web requests
# to ensure performance and avoid socket exhaustion.
$global:HttpClient = New-Object System.Net.Http.HttpClient

# FileSystemWatcher: The core monitoring object.
$global:FileSystemWatcher = $null

# Log Collection: A synchronized ArrayList is used for thread-safe updates to the GUI's DataGrid.
$global:LogCollection =::Synchronized(@(New-Object System.Collections.ArrayList))

# --- ---

function Add-LogEntry {
    param(
        [string]$FilePath,
        [string]$Server,
        [string]$Status,
        [string]$Details
    )
    # The dispatcher is used to ensure UI updates happen on the main UI thread.
    $logEntry = [pscustomobject]@{
        Timestamp   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        FilePath    = $FilePath
        Server      = $Server
        Status      = $Status
        Details     = $Details
    }
    $script:Window.Dispatcher.InvokeAsync({
        $global:LogCollection.Insert(0, $logEntry)
    }) | Out-Null
}

function Invoke-Verification {
    param(
        [string]$SourceFullPath,
        [string]$WebServerUrl,
        [string]$HashAlgorithm
    )

    $fileName =::GetFileName($SourceFullPath)
    $remoteUrl = "$WebServerUrl/$fileName"
    
    try {
        # Tier 1: Header Check (ETag)
        Add-LogEntry -FilePath $fileName -Server $WebServerUrl -Status "Verifying" -Details "Performing HEAD request..."
        
        $headRequest =::new(::Head, $remoteUrl)
        $headResponse = $global:HttpClient.SendAsync($headRequest).GetAwaiter().GetResult()

        if (-not $headResponse.IsSuccessStatusCode) {
            Add-LogEntry -FilePath $fileName -Server $WebServerUrl -Status "Failed" -Details "HTTP $($headResponse.StatusCode.value__): File not found or inaccessible."
            return
        }

        $remoteETag = $headResponse.Headers.ETag.Tag
        $sourceHash = (Get-FileHash -Path $SourceFullPath -Algorithm $HashAlgorithm).Hash
        
        # Note: ETag format can be "hash" or W/"hash". We compare the core hash part.
        if ($remoteETag -and $remoteETag.Trim('"') -eq $sourceHash) {
            Add-LogEntry -FilePath $fileName -Server $WebServerUrl -Status "Success" -Details "ETag matches source hash."
            return
        }

        # Tier 2: In-Memory Hash Comparison
        Add-LogEntry -FilePath $fileName -Server $WebServerUrl -Status "Verifying" -Details "ETag mismatch or absent. Performing full hash comparison..."
        
        $getResponse = $global:HttpClient.GetAsync($remoteUrl).GetAwaiter().GetResult()
        if (-not $getResponse.IsSuccessStatusCode) {
            Add-LogEntry -FilePath $fileName -Server $WebServerUrl -Status "Failed" -Details "HTTP $($getResponse.StatusCode.value__): Failed to download file for hashing."
            return
        }

        $remoteBytes = $getResponse.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $memoryStream = New-Object System.IO.MemoryStream(,$remoteBytes)
        $remoteHash = (Get-FileHash -InputStream $memoryStream -Algorithm $HashAlgorithm).Hash
        $memoryStream.Close()

        if ($remoteHash -eq $sourceHash) {
            Add-LogEntry -FilePath $fileName -Server $WebServerUrl -Status "Success" -Details "Hash matches source file ($HashAlgorithm)."
        } else {
            Add-LogEntry -FilePath $fileName -Server $WebServerUrl -Status "Failed" -Details "Hash mismatch. Source: $sourceHash, Remote: $remoteHash"
        }
    }
    catch {
        Add-LogEntry -FilePath $fileName -Server $WebServerUrl -Status "Error" -Details "Exception during verification: $($_.Exception.Message)"
    }
}

function Start-Monitoring {
    param(
        [string]$Path,
        [string]$Servers,
        [string]$Filter
    )
    
    if (-not (Test-Path -Path $Path -PathType Container)) {
      ::Show("The specified UNC path does not exist or is not accessible.", "Error", "OK", "Error")
        return
    }

    $global:FileSystemWatcher = New-Object System.IO.FileSystemWatcher -Property @{
        Path                  = $Path
        Filter                = $Filter
        NotifyFilter          = 'LastWrite, FileName'
        IncludeSubdirectories = $false # Set to $true if needed
    }

    $action = {
        $sourcePath = $Event.SourceEventArgs.FullPath
        $servers = $using:Servers
        $hashAlgo = $using:HashAlgorithm

        Add-LogEntry -FilePath $sourcePath -Server "Monitor" -Status "Detected" -Details "File change detected. Starting verification..."

        foreach ($server in $servers) {
            Start-ThreadJob -ScriptBlock ${function:Invoke-Verification} -ArgumentList $sourcePath, $server, $hashAlgo
        }
    }

    Register-ObjectEvent -InputObject $global:FileSystemWatcher -EventName Created -SourceIdentifier "FileCreated" -Action $action
    Register-ObjectEvent -InputObject $global:FileSystemWatcher -EventName Changed -SourceIdentifier "FileChanged" -Action $action

    $global:FileSystemWatcher.EnableRaisingEvents = $true
    Add-LogEntry -FilePath $Path -Server "Monitor" -Status "Started" -Details "Monitoring for file changes."
}

function Stop-Monitoring {
    if ($global:FileSystemWatcher) {
        $global:FileSystemWatcher.EnableRaisingEvents = $false
        Unregister-Event -SourceIdentifier "FileCreated" -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier "FileChanged" -ErrorAction SilentlyContinue
        $global:FileSystemWatcher.Dispose()
        $global:FileSystemWatcher = $null
        Add-LogEntry -FilePath "N/A" -Server "Monitor" -Status "Stopped" -Details "Monitoring has been stopped."
    }
}

# --- ---

try {
    $reader = (New-Object System.Xml.XmlNodeReader $xaml)
    $script:Window =::Load($reader)

    # Find and store references to all named controls
    $controls = @{}
    $xaml.Window.SelectNodes("//*[@x:Name]") | ForEach-Object {
        $controls[$_.Name] = $script:Window.FindName($_.Name)
    }

    # Bind the DataGrid to the synchronized collection
    $controls.LogDataGrid.ItemsSource = $global:LogCollection

    # Attach event handlers to buttons
    $controls.StartButton.add_Click({
        $unc = $controls.UncPathTextBox.Text
        $servers = $controls.WebServersTextBox.Text -split ',' | ForEach-Object { $_.Trim() }
        $filter = $controls.FileFilterTextBox.Text

        $controls.StartButton.IsEnabled = $false
        $controls.StopButton.IsEnabled = $true
        $controls.StatusTextBlock.Text = "Status: Monitoring..."
        Start-Monitoring -Path $unc -Servers $servers -Filter $filter
    })

    $controls.StopButton.add_Click({
        Stop-Monitoring
        $controls.StartButton.IsEnabled = $true
        $controls.StopButton.IsEnabled = $false
        $controls.StatusTextBlock.Text = "Status: Stopped"
    })

    $script:Window.add_Closing({
        Stop-Monitoring
        $global:HttpClient.Dispose()
    })

    # Display the window
    $null = $script:Window.ShowDialog()
}
catch {
  ::Show("An error occurred while initializing the GUI: $($_.Exception.Message)", "Fatal Error", "OK", "Error")
}
