#Requires -Version 5.1
<#
.SYNOPSIS
    Management GUI for SCCMDriverAutomation.

.DESCRIPTION
    A WPF front end for the existing scripts. It holds no deployment logic of its own:

      Models & versions  What each ring runs, the staged versions and the audit history, read from
                         the ledgers. Promote, roll back, block / unblock and hold / release run
                         Invoke-DriverPromotion.ps1, Invoke-DriverRollback.ps1 and
                         Set-DriverDeploymentState.ps1.
      Run                Preflight, dry run or full run as you, or start the SYSTEM scheduled task.
      Configuration      Edit Config\DriverAutomation.json. Changes are validated before saving.
                         Models can be picked from the vendor catalogs (Get-DriverCatalogModels.ps1)
                         instead of typed in.
      Logs, Run reports  CMTrace log viewer and the CSV report of each run.

    Every action runs the script in a separate Windows PowerShell process, exactly as you would from
    the command line, so the run lock, ledger, logging and event log behave the same way. The output
    appears in the panel at the bottom of the window.

    Run it on the site server. The GUI restarts itself elevated when needed, because the scripts
    require it. Promotion, rollback and runs started from the Run tab use your account, so it needs
    the ConfigMgr rights listed in REQUIREMENTS.md. The scheduled task keeps using the computer account.

.PARAMETER ConfigPath
    Configuration file to manage. Default: Config\DriverAutomation.json next to this script.

.EXAMPLE
    .\Start-DriverAutomationGUI.ps1
#>
[CmdletBinding()]
param (
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Config\DriverAutomation.json')
)

$ErrorActionPreference = 'Stop'
$ConfigPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($ConfigPath)
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# WPF needs an STA thread, and the scripts it drives need elevation. Restart once if either is missing.
$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA
if (-not $isAdmin -or -not $isSta) {
    $relaunch = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy {0} -File "{1}" -ConfigPath "{2}"' -f (Get-ExecutionPolicy), $PSCommandPath, $ConfigPath
    try {
        if ($isAdmin) {
            Start-Process -FilePath $powershellExe -ArgumentList $relaunch
        } else {
            Start-Process -FilePath $powershellExe -ArgumentList $relaunch -Verb RunAs
        }
    } catch {
        Write-Error "Unable to start the GUI elevated: $($_.Exception.Message)"
    }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
try {
    Import-Module -Name (Join-Path $PSScriptRoot 'Modules\SCCMDriverAutomation\SCCMDriverAutomation.psd1') -Force -DisableNameChecking
} catch {
    # The console is hidden when started from the shortcut, so report start-up failures in a window.
    [System.Windows.MessageBox]::Show("Unable to load the SCCMDriverAutomation module:`n`n$($_.Exception.Message)", 'SCCM Driver Automation', 'OK', 'Error') | Out-Null
    return
}

# Editable rows for the Models grid. Plain classes bind and edit reliably in a WPF DataGrid; Source
# keeps the original JSON entry so keys the GUI does not know about survive a save.
if (-not ('SDAGui.ModelRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Collections.ObjectModel;
namespace SDAGui {
    public class OsRow {
        public string Name { get; set; }
        public string Build { get; set; }
        public string Architecture { get; set; }
        public object Source { get; set; }
        public OsRow() { Name = "Windows 11"; Build = ""; Architecture = "x64"; }
    }
    public class ModelRow {
        public bool Enabled { get; set; }
        public string Vendor { get; set; }
        public string Model { get; set; }
        public string SystemIds { get; set; }
        public ObservableCollection<OsRow> OperatingSystems { get; set; }
        public object Source { get; set; }
        public ModelRow() { Enabled = true; Vendor = "Dell"; Model = ""; SystemIds = ""; OperatingSystems = new ObservableCollection<OsRow>(); }
    }
}
'@
}

# Rows for the "Add from vendor catalog" tab. The selection rules live here so ticking a model picks
# an OS for it, and unticking its last OS unticks the model, without a PowerShell handler per row.
if (-not ('SDAGui.CatalogModel' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
namespace SDAGui {
    public class CatalogItem : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        protected void Raise(string name) {
            PropertyChangedEventHandler handler = PropertyChanged;
            if (handler != null) { handler(this, new PropertyChangedEventArgs(name)); }
        }
    }
    public class CatalogOs : CatalogItem {
        private bool selected;
        private bool inConfig;
        public CatalogModel Parent { get; set; }
        public string Name { get; set; }
        public string Build { get; set; }
        public string Architecture { get; set; }
        public string Version { get; set; }
        public string Released { get; set; }
        public bool InConfig {
            get { return inConfig; }
            set { if (inConfig != value) { inConfig = value; Raise("InConfig"); Raise("InConfigText"); } }
        }
        public string InConfigText { get { return inConfig ? "Yes" : ""; } }
        public bool Selected {
            get { return selected; }
            set {
                if (selected == value) { return; }
                selected = value;
                Raise("Selected");
                if (Parent == null) { return; }
                if (value) { Parent.Selected = true; }
                else if (!Parent.HasSelectedOs()) { Parent.Selected = false; }
            }
        }
    }
    public class CatalogModel : CatalogItem {
        public static int SelectedCount;
        public static string PreferredOs = "Windows 11";
        public static string PreferredBuild = "";
        private bool selected;
        private string inConfig = "";
        public string Vendor { get; set; }
        public string Model { get; set; }
        public string SystemIds { get; set; }
        public string[] SystemIdList { get; set; }
        public string OsSummary { get; set; }
        public string Released { get; set; }
        public string SearchText { get; set; }
        public List<CatalogOs> OperatingSystems { get; private set; }
        public CatalogModel() { OperatingSystems = new List<CatalogOs>(); SystemIdList = new string[0]; Released = ""; }
        public string InConfig {
            get { return inConfig; }
            set { string v = value ?? ""; if (inConfig != v) { inConfig = v; Raise("InConfig"); } }
        }
        public bool HasSelectedOs() {
            foreach (CatalogOs os in OperatingSystems) { if (os.Selected) { return true; } }
            return false;
        }
        public bool Selected {
            get { return selected; }
            set {
                if (selected == value) { return; }
                selected = value;
                SelectedCount += value ? 1 : -1;
                Raise("Selected");
                if (value) {
                    if (!HasSelectedOs()) { SelectDefaultOs(); }
                } else {
                    foreach (CatalogOs os in OperatingSystems) { os.Selected = false; }
                }
            }
        }
        // The newest build of the preferred OS (x64 if there is one), else the newest OS the model has.
        // OperatingSystems is sorted newest first.
        private void SelectDefaultOs() {
            CatalogOs pick = null;
            foreach (CatalogOs os in OperatingSystems) {
                if (!string.Equals(os.Name, PreferredOs, StringComparison.OrdinalIgnoreCase)) { continue; }
                if (!string.IsNullOrEmpty(PreferredBuild) && !string.IsNullOrEmpty(os.Build) &&
                    !string.Equals(os.Build, PreferredBuild, StringComparison.OrdinalIgnoreCase)) { continue; }
                if (pick == null || (pick.Architecture != "x64" && os.Architecture == "x64")) { pick = os; }
            }
            if (pick == null && OperatingSystems.Count > 0) { pick = OperatingSystems[0]; }
            if (pick != null) { pick.Selected = true; }
        }
    }
}
'@
}

#region State
$script:AppRoot        = $PSScriptRoot           # folder holding the product scripts
$script:ConfigPath     = $ConfigPath
$script:PowerShellExe  = $powershellExe
$script:TaskName       = 'SCCM Driver Automation'          # as registered by Install-DriverAutomation.ps1
$script:TaskPath       = '\SCCMDriverAutomation\'
$script:Identity       = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$script:OutputDir      = Join-Path $env:TEMP 'SCCMDriverAutomation-GUI'
$script:Config         = $null    # validated configuration (Import-SDAConfig), used by the status view
$script:ConfigText     = $null    # configuration file text as last loaded or saved
$script:FormBaseline   = $null    # form contents right after loading, to detect unsaved edits
$script:ModelRows      = $null
$script:SettingControls = @{}
$script:Job            = $null    # the script process currently running, if any
$script:TickCount      = 0
$script:SuppressEvents = $false
$script:CatalogModels  = $null    # SDAGui.CatalogModel rows from the last catalog scan
$script:CatalogFile    = Join-Path $script:OutputDir 'CatalogModels.json'
#endregion State

#region Settings form definition
# Each entry becomes one field on the Configuration > Settings tab. Path is the JSON path.
$script:SettingSpec = @(
    @{ Path = 'General.DataRoot'; Type = 'Text'; Label = 'Data root'; Help = 'Logs, ledgers and working folders. Use a short path on a local fixed drive of this server.' }
    @{ Path = 'General.MinimumFreeSpaceGB'; Type = 'Int'; Label = 'Minimum free space (GB)'; Help = 'Checked on the data root and package source drives before each run.' }
    @{ Path = 'General.KeepDownloads'; Type = 'Bool'; Label = 'Keep vendor downloads'; Help = 'Keep the downloaded payloads after staging. Uses more disk.' }
    @{ Path = 'General.LogMaxSizeMB'; Type = 'Int'; Label = 'Log size (MB)'; Help = 'The log rolls over at this size.' }
    @{ Path = 'General.LogHistory'; Type = 'Int'; Label = 'Rolled logs to keep'; Help = '' }
    @{ Path = 'General.LockTimeoutMinutes'; Type = 'Int'; Label = 'Lock timeout (minutes)'; Help = 'How long a run or admin action waits for another one to finish.' }

    @{ Path = 'ConfigMgr.SiteCode'; Type = 'Text'; Label = 'Site code'; Help = 'Leave blank to detect it from the local SMS Provider.' }
    @{ Path = 'ConfigMgr.ProviderMachine'; Type = 'Text'; Label = 'SMS Provider server'; Help = 'Leave blank to detect it.' }
    @{ Path = 'ConfigMgr.CimProtocol'; Type = 'Choice'; Choices = @('Dcom', 'Wsman'); Label = 'Provider protocol'; Help = 'Dcom has no WinRM dependency.' }
    @{ Path = 'ConfigMgr.PackageSourceLocalRoot'; Type = 'Text'; Label = 'Package source (local path)'; Help = 'The package folder as a local path, when the share is on this server. Example: E:\Sources\DriverPackages. Leave blank when the share is on another server; content is then written to the UNC path directly.' }
    @{ Path = 'ConfigMgr.PackageSourceUncRoot'; Type = 'Text'; Label = 'Package source (UNC path)'; Help = 'The same folder as a UNC path. ConfigMgr packages point here. Example: \\CM01.corp.local\Sources$\DriverPackages' }
    @{ Path = 'ConfigMgr.ContentFormat'; Type = 'Choice'; Choices = @('WIM', 'Raw'); Label = 'Content format'; Help = 'WIM: one compressed image per version. Raw: extracted driver folders.' }
    @{ Path = 'ConfigMgr.ProductionNamePrefix'; Type = 'Text'; Label = 'Production package prefix'; Help = '' }
    @{ Path = 'ConfigMgr.PilotNamePrefix'; Type = 'Text'; Label = 'Pilot package prefix'; Help = "Must contain the word 'Pilot'." }
    @{ Path = 'ConfigMgr.ConsoleFolder'; Type = 'Text'; Label = 'Console folder'; Help = 'Packages are placed in <folder>\<Vendor>.' }
    @{ Path = 'ConfigMgr.DistributionPointGroups'; Type = 'List'; Label = 'Distribution point groups'; Help = 'One per line.' }
    @{ Path = 'ConfigMgr.DistributionPoints'; Type = 'List'; Label = 'Distribution points'; Help = 'Server FQDNs, one per line.' }
    @{ Path = 'ConfigMgr.PilotDistributionPointGroups'; Type = 'List'; Label = 'Pilot DP groups'; Help = 'Pilot packages go only to these groups and the Pilot DPs below. Leave both empty to use the lists above. Applies to Pilot packages created from now on.' }
    @{ Path = 'ConfigMgr.PilotDistributionPoints'; Type = 'List'; Label = 'Pilot distribution points'; Help = 'Server FQDNs, one per line.' }
    @{ Path = 'ConfigMgr.DistributionPriority'; Type = 'Choice'; Choices = @('High', 'Normal', 'Low'); Label = 'Distribution priority'; Help = '' }
    @{ Path = 'ConfigMgr.EnableBinaryDeltaReplication'; Type = 'Bool'; Label = 'Binary differential replication'; Help = 'Speeds up rollbacks, because older content is usually still on the DPs.' }
    @{ Path = 'ConfigMgr.AdoptExistingPackages'; Type = 'Bool'; Label = 'Adopt existing packages'; Help = 'Take over a single existing package with the same name instead of stopping. See the migration section of INSTRUCTIONS.md.' }

    @{ Path = 'Versioning.RetainVersions'; Type = 'Int'; Label = 'Versions to keep on disk'; Help = 'Per model and OS. Minimum 2, so a rollback target always exists.' }
    @{ Path = 'Versioning.PilotRing.Enabled'; Type = 'Bool'; Label = 'Use a Pilot ring'; Help = 'New versions go to the Pilot package first.' }
    @{ Path = 'Versioning.PilotRing.AutoPromoteAfterDays'; Type = 'Int'; Label = 'Promote to Production after (days)'; Help = '0 = promote manually.' }
    @{ Path = 'Versioning.PilotRing.SeedProductionOnFirstImport'; Type = 'Bool'; Label = 'Seed Production on first import'; Help = 'The first version of a new model goes to both rings.' }

    @{ Path = 'Network.ProxyMode'; Type = 'Choice'; Choices = @('None', 'WinHttp', 'System', 'Manual'); Label = 'Proxy mode'; Help = 'WinHttp uses the netsh winhttp proxy, which is what the SYSTEM task sees.' }
    @{ Path = 'Network.ProxyUrl'; Type = 'Text'; Label = 'Proxy URL'; Help = 'Manual mode only. Example: http://proxy.corp.local:8080' }
    @{ Path = 'Network.ProxyBypass'; Type = 'List'; Label = 'Proxy bypass'; Help = 'Manual mode only. One host pattern per line, * allowed.' }
    @{ Path = 'Network.ProxyAuthentication'; Type = 'Choice'; Choices = @('None', 'DefaultCredentials', 'StoredCredential'); Label = 'Proxy authentication'; Help = 'DefaultCredentials = the computer account. StoredCredential is set with Set-DriverAutomationProxyCredential.ps1.' }
    @{ Path = 'Network.TimeoutSeconds'; Type = 'Int'; Label = 'Connect timeout (seconds)'; Help = '' }
    @{ Path = 'Network.StallTimeoutSeconds'; Type = 'Int'; Label = 'Stall timeout (seconds)'; Help = 'Abort a download when no data arrives for this long.' }
    @{ Path = 'Network.RetryCount'; Type = 'Int'; Label = 'Retries'; Help = '' }
    @{ Path = 'Network.RetryDelaySeconds'; Type = 'Int'; Label = 'Retry delay (seconds)'; Help = '' }
    @{ Path = 'Network.AllowedDomains'; Type = 'List'; Label = 'Allowed download domains'; Help = 'Downloads from any other domain are refused. One per line.' }

    @{ Path = 'Security.VerifyCatalogSignature'; Type = 'Bool'; Label = 'Verify catalog signatures'; Help = 'Dell and HP catalog CABs must carry a trusted signature.' }
    @{ Path = 'Security.TrustedPublishers'; Type = 'List'; Label = 'Trusted publishers'; Help = 'Authenticode subject patterns, one per line.' }
    @{ Path = 'Security.DefenderScan'; Type = 'Bool'; Label = 'Scan with Microsoft Defender'; Help = 'Scan each payload and its extracted content.' }

    @{ Path = 'Extraction.TimeoutMinutes'; Type = 'Int'; Label = 'Extraction timeout (minutes)'; Help = '' }
)
$script:SettingSections = [ordered]@{
    General    = 'General'
    ConfigMgr  = 'Configuration Manager'
    Versioning = 'Versioning and rings'
    Network    = 'Network and proxy'
    Security   = 'Security'
    Extraction = 'Extraction'
}
#endregion Settings form definition

#region XAML
$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="SCCM Driver Automation" Width="1280" Height="860" MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="12">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="10,3"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="MinWidth" Value="80"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#FFE3E3E3"/>
      <Setter Property="Background" Value="White"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FF666666"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Top" Background="#FF1F3A5F" Padding="14,8">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Text="SCCM Driver Automation" Foreground="White" FontSize="16" FontWeight="SemiBold"/>
          <TextBlock x:Name="HeaderConfig" Foreground="#FFC8D6E5"/>
        </StackPanel>
        <TextBlock x:Name="HeaderTask" Grid.Column="1" Foreground="#FFC8D6E5" VerticalAlignment="Center" TextAlignment="Right"/>
      </Grid>
    </Border>
    <StatusBar DockPanel.Dock="Bottom">
      <StatusBarItem><TextBlock x:Name="StatusText"/></StatusBarItem>
    </StatusBar>
    <Grid Margin="8">
      <Grid.RowDefinitions>
        <RowDefinition Height="*" MinHeight="250"/>
        <RowDefinition Height="6"/>
        <RowDefinition Height="190" MinHeight="70"/>
      </Grid.RowDefinitions>
      <TabControl x:Name="MainTabs">

        <TabItem x:Name="StatusTab" Header="Models &amp; versions">
          <Grid Margin="6">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*" MinHeight="100"/>
              <RowDefinition Height="6"/>
              <RowDefinition Height="*" MinHeight="100"/>
            </Grid.RowDefinitions>
            <WrapPanel Margin="0,0,0,6">
              <Button x:Name="RefreshStatusButton" Content="Refresh"/>
              <Button x:Name="PromoteButton" Content="Promote to Production..."/>
              <Button x:Name="RollbackButton" Content="Roll back..."/>
              <Button x:Name="BlockButton" Content="Block version..."/>
              <Button x:Name="UnblockButton" Content="Unblock version..."/>
              <Button x:Name="HoldButton" Content="Hold ring..."/>
              <Button x:Name="ReleaseButton" Content="Release ring..."/>
            </WrapPanel>
            <DataGrid x:Name="TargetsGrid" Grid.Row="1">
              <DataGrid.RowStyle>
                <Style TargetType="DataGridRow">
                  <Style.Triggers>
                    <DataTrigger Binding="{Binding Flag}" Value="Hold"><Setter Property="Background" Value="#FFFFF4CE"/></DataTrigger>
                    <DataTrigger Binding="{Binding Flag}" Value="Inactive"><Setter Property="Foreground" Value="#FF8A8A8A"/></DataTrigger>
                  </Style.Triggers>
                </Style>
              </DataGrid.RowStyle>
              <DataGrid.Columns>
                <DataGridTextColumn Header="Model / OS" Binding="{Binding Target}" Width="2*"/>
                <DataGridTextColumn Header="Status" Binding="{Binding Status}"/>
                <DataGridTextColumn Header="Production" Binding="{Binding ProductionVersion}"/>
                <DataGridTextColumn Header="Prod. package" Binding="{Binding ProductionPackageID}"/>
                <DataGridTextColumn Header="Pilot" Binding="{Binding PilotVersion}"/>
                <DataGridTextColumn Header="Pilot package" Binding="{Binding PilotPackageID}"/>
                <DataGridTextColumn Header="Latest in catalog" Binding="{Binding LatestCatalog}"/>
                <DataGridTextColumn Header="Rollback target" Binding="{Binding RollbackTarget}"/>
                <DataGridTextColumn Header="Holds" Binding="{Binding Holds}"/>
                <DataGridTextColumn Header="Last checked" Binding="{Binding LastChecked}"/>
              </DataGrid.Columns>
            </DataGrid>
            <GridSplitter Grid.Row="2" HorizontalAlignment="Stretch" ResizeDirection="Rows" Background="Transparent"/>
            <TabControl Grid.Row="3">
              <TabItem Header="Versions">
                <DataGrid x:Name="VersionsGrid">
                  <DataGrid.RowStyle>
                    <Style TargetType="DataGridRow">
                      <Style.Triggers>
                        <DataTrigger Binding="{Binding Status}" Value="Blocked"><Setter Property="Background" Value="#FFF8DADA"/></DataTrigger>
                        <DataTrigger Binding="{Binding Status}" Value="Pruned"><Setter Property="Foreground" Value="#FF8A8A8A"/></DataTrigger>
                      </Style.Triggers>
                    </Style>
                  </DataGrid.RowStyle>
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Version" Binding="{Binding VersionId}"/>
                    <DataGridTextColumn Header="Vendor version" Binding="{Binding VendorVersion}"/>
                    <DataGridTextColumn Header="Released" Binding="{Binding ReleaseDate}"/>
                    <DataGridTextColumn Header="Status" Binding="{Binding Status}"/>
                    <DataGridTextColumn Header="Deployed to" Binding="{Binding DeployedTo}"/>
                    <DataGridTextColumn Header="Rollback target for" Binding="{Binding RollbackFor}"/>
                    <DataGridTextColumn Header="Content" Binding="{Binding Content}"/>
                    <DataGridTextColumn Header="Staged" Binding="{Binding Staged}"/>
                    <DataGridTextColumn Header="Notes" Binding="{Binding Notes}" Width="*"/>
                  </DataGrid.Columns>
                </DataGrid>
              </TabItem>
              <TabItem Header="History">
                <DataGrid x:Name="HistoryGrid">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Time" Binding="{Binding Time}"/>
                    <DataGridTextColumn Header="Action" Binding="{Binding Action}"/>
                    <DataGridTextColumn Header="Ring" Binding="{Binding Ring}"/>
                    <DataGridTextColumn Header="From" Binding="{Binding FromVersion}"/>
                    <DataGridTextColumn Header="To" Binding="{Binding ToVersion}"/>
                    <DataGridTextColumn Header="Package" Binding="{Binding PackageID}"/>
                    <DataGridTextColumn Header="By" Binding="{Binding Initiator}"/>
                    <DataGridTextColumn Header="Reason" Binding="{Binding Reason}" Width="*"/>
                  </DataGrid.Columns>
                </DataGrid>
              </TabItem>
            </TabControl>
          </Grid>
        </TabItem>

        <TabItem x:Name="RunTab" Header="Run">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="10" MaxWidth="900" HorizontalAlignment="Left">
              <GroupBox Header="Run now as you" Padding="10">
                <StackPanel>
                  <TextBlock x:Name="RunAsText" Style="{StaticResource Hint}"/>
                  <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <TextBlock Text="Vendors" Width="80" VerticalAlignment="Center"/>
                    <CheckBox x:Name="RunDell" Content="Dell" IsChecked="True" Margin="0,0,14,0"/>
                    <CheckBox x:Name="RunHP" Content="HP" IsChecked="True" Margin="0,0,14,0"/>
                    <CheckBox x:Name="RunLenovo" Content="Lenovo" IsChecked="True"/>
                  </StackPanel>
                  <DockPanel Margin="0,8,0,0">
                    <TextBlock Text="Models" Width="80" VerticalAlignment="Center"/>
                    <TextBox x:Name="RunModels"/>
                  </DockPanel>
                  <TextBlock Style="{StaticResource Hint}" Margin="80,2,0,0" Text="Optional. Separate with commas; wildcards are allowed (Latitude*, ThinkPad T14*). Leave blank for all enabled models."/>
                  <WrapPanel Margin="0,12,0,0">
                    <Button x:Name="PreflightButton" Content="Preflight check"/>
                    <Button x:Name="DryRunButton" Content="Dry run"/>
                    <Button x:Name="FullRunButton" Content="Full run"/>
                  </WrapPanel>
                  <TextBlock Style="{StaticResource Hint}" Margin="0,10,0,0">
                    <Run FontWeight="SemiBold">Preflight</Run> checks folders, the UNC share, the proxy, the vendor catalogs and ConfigMgr access.
                    <LineBreak/><Run FontWeight="SemiBold">Dry run</Run> reads the catalogs and reports what would change. It downloads no driver packs and changes nothing.
                    <LineBreak/><Run FontWeight="SemiBold">Full run</Run> downloads, stages and deploys new versions, like the scheduled task.
                  </TextBlock>
                </StackPanel>
              </GroupBox>
              <GroupBox Header="Scheduled task (runs as SYSTEM)" Margin="0,12,0,0" Padding="10">
                <StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="110"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="State" Margin="0,2"/>
                    <TextBlock Grid.Row="0" Grid.Column="1" x:Name="TaskStateText" Margin="0,2"/>
                    <TextBlock Grid.Row="1" Text="Schedule" Margin="0,2"/>
                    <TextBlock Grid.Row="1" Grid.Column="1" x:Name="TaskScheduleText" Margin="0,2"/>
                    <TextBlock Grid.Row="2" Text="Last run" Margin="0,2"/>
                    <TextBlock Grid.Row="2" Grid.Column="1" x:Name="TaskLastRunText" Margin="0,2"/>
                    <TextBlock Grid.Row="3" Text="Last result" Margin="0,2"/>
                    <TextBlock Grid.Row="3" Grid.Column="1" x:Name="TaskResultText" Margin="0,2"/>
                    <TextBlock Grid.Row="4" Text="Next run" Margin="0,2"/>
                    <TextBlock Grid.Row="4" Grid.Column="1" x:Name="TaskNextRunText" Margin="0,2"/>
                  </Grid>
                  <WrapPanel Margin="0,10,0,0">
                    <Button x:Name="StartTaskButton" Content="Start task now"/>
                    <Button x:Name="RefreshTaskButton" Content="Refresh"/>
                  </WrapPanel>
                  <TextBlock Style="{StaticResource Hint}" Margin="0,10,0,0" Text="Starting the task runs a full run as SYSTEM, with the same proxy and ConfigMgr identity (the computer account) as the schedule. Follow it on the Logs tab. Change the schedule with Install-DriverAutomation.ps1 -At / -DaysOfWeek."/>
                </StackPanel>
              </GroupBox>
            </StackPanel>
          </ScrollViewer>
        </TabItem>

        <TabItem x:Name="ConfigTab" Header="Configuration">
          <DockPanel Margin="6">
            <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,6">
              <Button x:Name="SaveConfigButton" Content="Save"/>
              <Button x:Name="ValidateConfigButton" Content="Validate"/>
              <Button x:Name="ReloadConfigButton" Content="Discard changes"/>
              <Button x:Name="NotepadConfigButton" Content="Open in Notepad"/>
            </WrapPanel>
            <TabControl x:Name="ConfigTabs">
              <TabItem x:Name="ConfigModelsTab" Header="Models">
                <Grid Margin="6">
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*" MinHeight="80"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="150"/>
                  </Grid.RowDefinitions>
                  <DockPanel Margin="0,0,0,6">
                    <Button x:Name="BrowseCatalogButton" Content="Add from vendor catalog..."/>
                    <Button x:Name="AddModelButton" Content="Add model"/>
                    <Button x:Name="RemoveModelButton" Content="Remove model"/>
                    <TextBlock Style="{StaticResource Hint}" VerticalAlignment="Center" Margin="8,0,0,0"
                               Text="Model must match the vendor catalog name. System IDs: Dell SystemSKU, HP baseboard product (platform ID), Lenovo first 4 characters of the machine type; separate with commas."/>
                  </DockPanel>
                  <DataGrid x:Name="ModelsGrid" Grid.Row="1" IsReadOnly="False">
                    <DataGrid.Columns>
                      <DataGridCheckBoxColumn Header="Enabled" Binding="{Binding Enabled, UpdateSourceTrigger=PropertyChanged}"/>
                      <DataGridComboBoxColumn Header="Vendor" SelectedItemBinding="{Binding Vendor}" Width="90">
                        <DataGridComboBoxColumn.ItemsSource>
                          <x:Array Type="sys:String"><sys:String>Dell</sys:String><sys:String>HP</sys:String><sys:String>Lenovo</sys:String></x:Array>
                        </DataGridComboBoxColumn.ItemsSource>
                      </DataGridComboBoxColumn>
                      <DataGridTextColumn Header="Model" Binding="{Binding Model}" Width="2*"/>
                      <DataGridTextColumn Header="System IDs" Binding="{Binding SystemIds}" Width="*"/>
                    </DataGrid.Columns>
                  </DataGrid>
                  <DockPanel Grid.Row="2" Margin="0,10,0,6">
                    <TextBlock Text="Operating systems for the selected model" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    <Button x:Name="AddOsButton" Content="Add OS"/>
                    <Button x:Name="RemoveOsButton" Content="Remove OS"/>
                    <TextBlock Style="{StaticResource Hint}" VerticalAlignment="Center" Margin="8,0,0,0" Text="Build (e.g. 24H2) is required for HP and Lenovo."/>
                  </DockPanel>
                  <DataGrid x:Name="OsGrid" Grid.Row="3" IsReadOnly="False"
                            ItemsSource="{Binding SelectedItem.OperatingSystems, ElementName=ModelsGrid}">
                    <DataGrid.Columns>
                      <DataGridComboBoxColumn Header="Operating system" SelectedItemBinding="{Binding Name}" Width="140">
                        <DataGridComboBoxColumn.ItemsSource>
                          <x:Array Type="sys:String"><sys:String>Windows 11</sys:String><sys:String>Windows 10</sys:String></x:Array>
                        </DataGridComboBoxColumn.ItemsSource>
                      </DataGridComboBoxColumn>
                      <DataGridTextColumn Header="Build" Binding="{Binding Build}" Width="100"/>
                      <DataGridComboBoxColumn Header="Architecture" SelectedItemBinding="{Binding Architecture}" Width="110">
                        <DataGridComboBoxColumn.ItemsSource>
                          <x:Array Type="sys:String"><sys:String>x64</sys:String><sys:String>Arm64</sys:String></x:Array>
                        </DataGridComboBoxColumn.ItemsSource>
                      </DataGridComboBoxColumn>
                    </DataGrid.Columns>
                  </DataGrid>
                </Grid>
              </TabItem>
              <TabItem x:Name="CatalogTab" Header="Add from vendor catalog">
                <Grid Margin="6">
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*" MinHeight="100"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="140"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <WrapPanel Margin="0,0,0,6">
                    <TextBlock Text="Catalogs" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <CheckBox x:Name="CatalogDell" Content="Dell" IsChecked="True" VerticalAlignment="Center" Margin="0,0,12,0"/>
                    <CheckBox x:Name="CatalogHP" Content="HP" IsChecked="True" VerticalAlignment="Center" Margin="0,0,12,0"/>
                    <CheckBox x:Name="CatalogLenovo" Content="Lenovo" IsChecked="True" VerticalAlignment="Center" Margin="0,0,12,0"/>
                    <Button x:Name="CatalogScanButton" Content="Scan catalogs"/>
                    <TextBlock x:Name="CatalogInfoText" Style="{StaticResource Hint}" VerticalAlignment="Center" Margin="4,0,0,0"/>
                  </WrapPanel>
                  <WrapPanel Grid.Row="1" Margin="0,0,0,6">
                    <TextBlock Text="Search" VerticalAlignment="Center" Margin="0,0,4,0"/>
                    <TextBox x:Name="CatalogSearch" Width="220" Margin="0,0,12,0" VerticalContentAlignment="Center"
                             ToolTip="Model name or system ID. With several words, all must match (e.g. 'latitude 7440' or '21HD')."/>
                    <TextBlock Text="Vendor" VerticalAlignment="Center" Margin="0,0,4,0"/>
                    <ComboBox x:Name="CatalogVendorFilter" Width="80" Margin="0,0,12,0"/>
                    <TextBlock Text="OS" VerticalAlignment="Center" Margin="0,0,4,0"/>
                    <ComboBox x:Name="CatalogOsFilter" Width="100" Margin="0,0,12,0"/>
                    <TextBlock Text="Build" VerticalAlignment="Center" Margin="0,0,4,0"/>
                    <ComboBox x:Name="CatalogBuildFilter" Width="70" Margin="0,0,12,0"/>
                    <TextBlock Text="Pack released" VerticalAlignment="Center" Margin="0,0,4,0"/>
                    <ComboBox x:Name="CatalogAgeFilter" Width="110" Margin="0,0,12,0"/>
                    <CheckBox x:Name="CatalogHideConfigured" Content="Hide configured models" VerticalAlignment="Center" Margin="0,0,12,0"/>
                    <CheckBox x:Name="CatalogSelectedOnly" Content="Ticked only" VerticalAlignment="Center"/>
                  </WrapPanel>
                  <DataGrid x:Name="CatalogGrid" Grid.Row="2">
                    <DataGrid.RowStyle>
                      <Style TargetType="DataGridRow">
                        <Style.Triggers>
                          <DataTrigger Binding="{Binding Selected}" Value="True"><Setter Property="Background" Value="#FFE2ECF7"/></DataTrigger>
                        </Style.Triggers>
                      </Style>
                    </DataGrid.RowStyle>
                    <DataGrid.Columns>
                      <DataGridTemplateColumn Header="Add" SortMemberPath="Selected">
                        <DataGridTemplateColumn.CellTemplate>
                          <DataTemplate><CheckBox IsChecked="{Binding Selected, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center"/></DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                      <DataGridTextColumn Header="Vendor" Binding="{Binding Vendor}"/>
                      <DataGridTextColumn Header="Model" Binding="{Binding Model}" Width="2*"/>
                      <DataGridTextColumn Header="System IDs" Binding="{Binding SystemIds}" Width="*"/>
                      <DataGridTextColumn Header="Driver packs for" Binding="{Binding OsSummary}" Width="2*"/>
                      <DataGridTextColumn Header="Newest pack" Binding="{Binding Released}"/>
                      <DataGridTextColumn Header="In configuration" Binding="{Binding InConfig}"/>
                    </DataGrid.Columns>
                  </DataGrid>
                  <DockPanel Grid.Row="3" Margin="0,8,0,4">
                    <TextBlock Text="Operating systems to add for the highlighted model" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <TextBlock Style="{StaticResource Hint}" VerticalAlignment="Center" Margin="10,0,0,0"
                               Text="Ticking a model ticks its newest build of the OS picked in the filter (Windows 11 if none). Change it here."/>
                  </DockPanel>
                  <DataGrid x:Name="CatalogOsGrid" Grid.Row="4" ItemsSource="{Binding SelectedItem.OperatingSystems, ElementName=CatalogGrid}">
                    <DataGrid.Columns>
                      <DataGridTemplateColumn Header="Add" SortMemberPath="Selected">
                        <DataGridTemplateColumn.CellTemplate>
                          <DataTemplate><CheckBox IsChecked="{Binding Selected, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center"/></DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                      <DataGridTextColumn Header="Operating system" Binding="{Binding Name}"/>
                      <DataGridTextColumn Header="Build" Binding="{Binding Build}"/>
                      <DataGridTextColumn Header="Architecture" Binding="{Binding Architecture}"/>
                      <DataGridTextColumn Header="Newest pack version" Binding="{Binding Version}"/>
                      <DataGridTextColumn Header="Released" Binding="{Binding Released}"/>
                      <DataGridTextColumn Header="In configuration" Binding="{Binding InConfigText}" Width="*"/>
                    </DataGrid.Columns>
                  </DataGrid>
                  <DockPanel Grid.Row="5" Margin="0,8,0,0">
                    <Button x:Name="CatalogAddButton" Content="Add ticked models to the configuration"/>
                    <Button x:Name="CatalogClearButton" Content="Clear ticks"/>
                    <TextBlock x:Name="CatalogSelectedText" VerticalAlignment="Center" Margin="4,0,0,0"/>
                  </DockPanel>
                </Grid>
              </TabItem>
              <TabItem Header="Settings">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                  <StackPanel x:Name="SettingsPanel" Margin="6" MaxWidth="1000" HorizontalAlignment="Left"/>
                </ScrollViewer>
              </TabItem>
            </TabControl>
          </DockPanel>
        </TabItem>

        <TabItem x:Name="LogsTab" Header="Logs">
          <DockPanel Margin="6">
            <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,6">
              <ComboBox x:Name="LogFileCombo" Width="260" Margin="0,0,10,0"/>
              <TextBlock Text="Filter" VerticalAlignment="Center" Margin="0,0,4,0"/>
              <TextBox x:Name="LogFilter" Width="200" Margin="0,0,10,0" VerticalContentAlignment="Center"/>
              <CheckBox x:Name="LogProblemsOnly" Content="Warnings and errors only" VerticalAlignment="Center" Margin="0,0,12,0"/>
              <CheckBox x:Name="LogAutoRefresh" Content="Auto-refresh" VerticalAlignment="Center" Margin="0,0,12,0"/>
              <Button x:Name="LogRefreshButton" Content="Refresh"/>
              <Button x:Name="LogCMTraceButton" Content="Open in CMTrace"/>
              <Button x:Name="LogFolderButton" Content="Open folder"/>
            </WrapPanel>
            <DataGrid x:Name="LogGrid">
              <DataGrid.RowStyle>
                <Style TargetType="DataGridRow">
                  <Style.Triggers>
                    <DataTrigger Binding="{Binding Severity}" Value="Error"><Setter Property="Background" Value="#FFF8DADA"/></DataTrigger>
                    <DataTrigger Binding="{Binding Severity}" Value="Warning"><Setter Property="Background" Value="#FFFFF4CE"/></DataTrigger>
                  </Style.Triggers>
                </Style>
              </DataGrid.RowStyle>
              <DataGrid.Columns>
                <DataGridTextColumn Header="Time" Binding="{Binding Time}"/>
                <DataGridTextColumn Header="Severity" Binding="{Binding Severity}"/>
                <DataGridTextColumn Header="Component" Binding="{Binding Component}"/>
                <DataGridTextColumn Header="Message" Binding="{Binding Message}" Width="*">
                  <DataGridTextColumn.ElementStyle>
                    <Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style>
                  </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
              </DataGrid.Columns>
            </DataGrid>
          </DockPanel>
        </TabItem>

        <TabItem x:Name="ReportsTab" Header="Run reports">
          <Grid Margin="6">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="250"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <DockPanel Margin="0,0,8,0">
              <Button x:Name="ReportRefreshButton" DockPanel.Dock="Top" Content="Refresh" HorizontalAlignment="Left" Margin="0,0,0,6"/>
              <ListBox x:Name="ReportList"/>
            </DockPanel>
            <DataGrid x:Name="ReportGrid" Grid.Column="1" AutoGenerateColumns="True">
              <DataGrid.RowStyle>
                <Style TargetType="DataGridRow">
                  <Style.Triggers>
                    <DataTrigger Binding="{Binding Status}" Value="Failed"><Setter Property="Background" Value="#FFF8DADA"/></DataTrigger>
                    <DataTrigger Binding="{Binding Status}" Value="Updated"><Setter Property="Background" Value="#FFE2F1DD"/></DataTrigger>
                    <DataTrigger Binding="{Binding Status}" Value="Staged"><Setter Property="Background" Value="#FFE2F1DD"/></DataTrigger>
                    <DataTrigger Binding="{Binding Status}" Value="UpdateAvailable"><Setter Property="Background" Value="#FFE2ECF7"/></DataTrigger>
                    <DataTrigger Binding="{Binding Status}" Value="Blocked"><Setter Property="Background" Value="#FFFFF4CE"/></DataTrigger>
                    <DataTrigger Binding="{Binding Status}" Value="Held"><Setter Property="Background" Value="#FFFFF4CE"/></DataTrigger>
                  </Style.Triggers>
                </Style>
              </DataGrid.RowStyle>
            </DataGrid>
          </Grid>
        </TabItem>
      </TabControl>

      <GridSplitter Grid.Row="1" HorizontalAlignment="Stretch" ResizeDirection="Rows" Background="Transparent"/>
      <DockPanel Grid.Row="2">
        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4">
          <TextBlock Text="Output" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <TextBlock x:Name="JobText" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#FF666666"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="CancelJobButton" Content="Stop" IsEnabled="False"/>
            <Button x:Name="ClearOutputButton" Content="Clear" Margin="0"/>
          </StackPanel>
        </DockPanel>
        <TextBox x:Name="OutputBox" IsReadOnly="True" FontFamily="Consolas" FontSize="12" Background="#FF1E1E1E" Foreground="#FFDCDCDC"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
      </DockPanel>
    </Grid>
  </DockPanel>
</Window>
'@

$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="560" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False" FontFamily="Segoe UI" FontSize="12">
  <StackPanel Margin="16">
    <TextBlock x:Name="MessageText" TextWrapping="Wrap" Margin="0,0,0,12"/>
    <StackPanel x:Name="RingPanel" Orientation="Horizontal" Margin="0,0,0,8">
      <TextBlock Text="Ring" Width="90" VerticalAlignment="Center"/>
      <ComboBox x:Name="RingCombo" Width="200"/>
    </StackPanel>
    <StackPanel x:Name="VersionPanel" Orientation="Horizontal" Margin="0,0,0,8">
      <TextBlock x:Name="VersionLabel" Width="90" VerticalAlignment="Center"/>
      <ComboBox x:Name="VersionCombo" Width="420" DisplayMemberPath="Text"/>
    </StackPanel>
    <StackPanel x:Name="OptionsPanel" Margin="90,0,0,8"/>
    <TextBlock Text="Reason (recorded in the ledger, the log and the event log)" Margin="0,4,0,4"/>
    <TextBox x:Name="ReasonBox" Height="56" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="OkButton" IsDefault="True" Padding="12,3" MinWidth="90" Margin="0,0,6,0"/>
      <Button Content="Cancel" IsCancel="True" Padding="12,3" MinWidth="90"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
#endregion XAML

#region Helpers
function New-GuiWindow {
    param ([Parameter(Mandatory)][string]$Xaml)

    $window = [System.Windows.Markup.XamlReader]::Parse($Xaml)
    $controls = @{}
    foreach ($match in [regex]::Matches($Xaml, 'x:Name="([^"]+)"')) {
        $name = $match.Groups[1].Value
        $controls[$name] = $window.FindName($name)
    }
    return @{ Window = $window; Controls = $controls }
}

function New-GuiThickness ([double]$Left, [double]$Top, [double]$Right, [double]$Bottom) {
    return (New-Object System.Windows.Thickness($Left, $Top, $Right, $Bottom))
}

function Show-GuiMessage {
    param (
        [Parameter(Mandatory)][string]$Text,
        [System.Windows.MessageBoxImage]$Icon = 'Information',
        [System.Windows.MessageBoxButton]$Buttons = 'OK'
    )
    return [System.Windows.MessageBox]::Show($script:Window, $Text, 'SCCM Driver Automation', $Buttons, $Icon)
}

function Set-GuiStatus ([string]$Text) {
    $ui.StatusText.Text = $Text
}

function Invoke-GuiSafely {
    <#
    .SYNOPSIS
        Runs an event handler body and shows any error instead of letting it escape into WPF.
    #>
    param ([Parameter(Mandatory)][scriptblock]$Action)
    try {
        & $Action
    } catch {
        Show-GuiMessage -Text $_.Exception.Message -Icon Error | Out-Null
    }
}

function Format-GuiDate ($Value) {
    $date = ConvertTo-SDADate $Value
    if ($null -eq $date) { return [string]$Value }
    return $date.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
}

function Get-GuiPathValue {
    param ([System.Collections.IDictionary]$Dictionary, [string]$Path)

    $current = $Dictionary
    foreach ($part in $Path.Split('.')) {
        if ($current -isnot [System.Collections.IDictionary] -or -not $current.Contains($part)) { return $null }
        $current = $current[$part]
    }
    return , $current
}

function Set-GuiPathValue {
    param ([System.Collections.IDictionary]$Dictionary, [string]$Path, $Value)

    $parts = $Path.Split('.')
    $current = $Dictionary
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        if (-not $current.Contains($parts[$i]) -or $current[$parts[$i]] -isnot [System.Collections.IDictionary]) {
            $current[$parts[$i]] = [ordered]@{}
        }
        $current = $current[$parts[$i]]
    }
    $current[$parts[-1]] = $Value
}

function Get-GuiLogsFolder {
    if ($script:Config) { return $script:Config.Paths.Logs }
    $root = $null
    if ($script:ConfigText) {
        try { $root = (ConvertFrom-Json -InputObject $script:ConfigText).General.DataRoot } catch { }
    }
    if (-not $root) { $root = (Get-SDADefaultConfig).General.DataRoot }
    return (Join-Path $root 'Logs')
}

function Read-GuiFileTail {
    param ([Parameter(Mandatory)][string]$Path, [long]$MaxBytes = 4MB)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    # ReadWrite/Delete sharing so a running script can keep appending and rolling the log.
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]'ReadWrite, Delete'))
    try {
        $stream.Position = [Math]::Max([long]0, $stream.Length - $MaxBytes)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        return $reader.ReadToEnd()
    } finally {
        $stream.Dispose()
    }
}
#endregion Helpers

#region JSON output
function Get-GuiJsonStringEnd {
    param ([string]$Json, [int]$Start)
    $i = $Start + 1
    while ($i -lt $Json.Length) {
        if ($Json[$i] -eq '\') { $i += 2; continue }
        if ($Json[$i] -eq '"') { return $i }
        $i++
    }
    return $Json.Length - 1
}

function Get-GuiJsonCloseIndex {
    param ([string]$Json, [int]$Start)
    $depth = 0
    $i = $Start
    while ($i -lt $Json.Length) {
        $c = $Json[$i]
        if ($c -eq '"') { $i = (Get-GuiJsonStringEnd -Json $Json -Start $i) + 1; continue }
        if ($c -eq '{' -or $c -eq '[') { $depth++ }
        elseif ($c -eq '}' -or $c -eq ']') { $depth--; if ($depth -eq 0) { return $i } }
        $i++
    }
    return $Json.Length - 1
}

function ConvertTo-GuiJson {
    <#
    .SYNOPSIS
        Serialises the configuration in the same readable layout as the shipped sample: two-space
        indentation and short scalar arrays on one line. Windows PowerShell's own ConvertTo-Json output
        is valid but hard to edit by hand.
    #>
    param ([Parameter(Mandatory)]$InputObject)

    $json = ConvertTo-Json -InputObject $InputObject -Depth 12 -Compress
    # Windows PowerShell escapes ' < > & as \u00xx. JSON does not require it; restore them for readability.
    $json = [regex]::Replace($json, '(?<!\\)((?:\\\\)*)\\u00(27|3c|3e|26)', {
            param($m) $m.Groups[1].Value + [string][char][Convert]::ToInt32($m.Groups[2].Value, 16)
        })

    $out = New-Object System.Text.StringBuilder
    $indent = 0
    $inlineEnd = -1
    $i = 0
    while ($i -lt $json.Length) {
        $c = $json[$i]
        if ($c -eq '"') {
            $end = Get-GuiJsonStringEnd -Json $json -Start $i
            [void]$out.Append($json, $i, $end - $i + 1)
            $i = $end + 1
            continue
        }
        if ($c -eq '{' -or $c -eq '[') {
            $close = Get-GuiJsonCloseIndex -Json $json -Start $i
            if ($close -eq $i + 1) {
                [void]$out.Append($c).Append($json[$close])
                $i = $close + 1
                continue
            }
            $inner = $json.Substring($i + 1, $close - $i - 1)
            if ($c -eq '[' -and $inlineEnd -lt 0 -and $inner.IndexOfAny([char[]]'{[') -lt 0 -and $inner.Length -le 100) {
                [void]$out.Append('[ ')
                $inlineEnd = $close
            } else {
                $indent++
                [void]$out.Append($c).Append("`r`n").Append('  ' * $indent)
            }
        } elseif ($c -eq '}' -or $c -eq ']') {
            if ($i -eq $inlineEnd) {
                [void]$out.Append(' ]')
                $inlineEnd = -1
            } else {
                $indent--
                [void]$out.Append("`r`n").Append('  ' * $indent).Append($c)
            }
        } elseif ($c -eq ',') {
            if ($inlineEnd -ge 0) { [void]$out.Append(', ') } else { [void]$out.Append(",`r`n").Append('  ' * $indent) }
        } elseif ($c -eq ':') {
            [void]$out.Append(': ')
        } else {
            [void]$out.Append($c)
        }
        $i++
    }
    return $out.ToString() + "`r`n"
}
#endregion JSON output

#region Running scripts
function ConvertTo-GuiLiteral ([string]$Value) {
    # PowerShell single-quoted literal. Curly quotes also end a literal in PowerShell, so double those too.
    $flat = $Value -replace '[\r\n]+', ' '
    return "'" + ($flat -replace '([''\u2018\u2019\u201A\u201B])', '$1$1') + "'"
}

function ConvertTo-GuiArgument ([string]$Value) {
    # Quote one argument for the Windows command line (CommandLineToArgvW rules).
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Write-GuiOutput ([string]$Text) {
    $box = $ui.OutputBox
    if ($box.Text.Length -gt 400000) { $box.Text = $box.Text.Substring($box.Text.Length - 200000) }
    $box.AppendText($Text)
    $box.ScrollToEnd()
}

function Start-GuiScript {
    <#
    .SYNOPSIS
        Runs one of the product scripts in a separate Windows PowerShell process. All output streams go
        to a file that the UI timer tails into the output panel.
    #>
    param (
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$Title,
        [System.Collections.IDictionary]$Arguments = @{},
        [string[]]$Switches = @(),
        [switch]$UseExitCode,
        [switch]$RefreshStatus,
        [scriptblock]$OnSuccess       # runs in the UI when the script exits with code 0
    )

    if ($script:Job) {
        Show-GuiMessage -Text 'Another action is still running. Wait for it to finish, or stop it, first.' -Icon Warning | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $script:OutputDir)) { New-Item -Path $script:OutputDir -ItemType Directory -Force | Out-Null }
    $outFile = Join-Path $script:OutputDir ('{0:yyyyMMdd-HHmmss}-{1}.log' -f (Get-Date), [System.IO.Path]::GetFileNameWithoutExtension($Script))

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('&')
    $parts.Add((ConvertTo-GuiLiteral (Join-Path $script:AppRoot $Script)))
    foreach ($key in $Arguments.Keys) {
        $parts.Add("-$key")
        $parts.Add(((@($Arguments[$key]) | ForEach-Object { ConvertTo-GuiLiteral ([string]$_) }) -join ','))
    }
    foreach ($flag in $Switches) { $parts.Add($flag) }
    $parts.Add('-ConfigPath')
    $parts.Add((ConvertTo-GuiLiteral $script:ConfigPath))

    # A script that throws is reported as exit code 2. Invoke-DriverAutomation.ps1 sets its own exit code.
    $exitStatement = if ($UseExitCode) { 'exit [int]$LASTEXITCODE' } else { 'exit 0' }
    $command = 'try {{ {0} *> {1}; {2} }} catch {{ ($_ | Out-String) | Out-File -LiteralPath {1} -Append; exit 2 }}' -f ($parts -join ' '), (ConvertTo-GuiLiteral $outFile), $exitStatement

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:PowerShellExe
    $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy {0} -Command {1}' -f (Get-ExecutionPolicy), (ConvertTo-GuiArgument $command)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = $script:AppRoot
    $process = [System.Diagnostics.Process]::Start($startInfo)

    $script:Job = @{
        Process       = $process
        OutFile       = $outFile
        Position      = [long]0
        Encoding      = $null
        Title         = $Title
        UseExitCode   = [bool]$UseExitCode
        RefreshStatus = [bool]$RefreshStatus
        OnSuccess     = $OnSuccess
        Started       = Get-Date
    }
    Write-GuiOutput ("`r`n=== {0} - started {1:HH:mm:ss} ===`r`n" -f $Title, (Get-Date))
    Set-GuiStatus "$Title is running."
    Update-GuiBusyState
}

function Receive-GuiJobOutput {
    $job = $script:Job
    if (-not $job -or -not (Test-Path -LiteralPath $job.OutFile)) { return }
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($job.OutFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]'ReadWrite, Delete'))
        $available = $stream.Length - $job.Position
        if ($available -le 0) { return }
        $buffer = New-Object byte[] ([int][Math]::Min($available, 4MB))
        $stream.Position = $job.Position
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $offset = 0
        if ($null -eq $job.Encoding) {
            # Windows PowerShell redirection writes UTF-16 LE with a BOM; fall back to UTF-8 otherwise.
            if ($read -lt 2) { return }
            if ($buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) { $job.Encoding = [System.Text.Encoding]::Unicode; $offset = 2 }
            elseif ($read -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) { $job.Encoding = [System.Text.Encoding]::UTF8; $offset = 3 }
            else { $job.Encoding = [System.Text.Encoding]::UTF8 }
        }
        if ($job.Encoding -eq [System.Text.Encoding]::Unicode) { $read -= ($read - $offset) % 2 }
        if ($read -le $offset) { return }
        $job.Position += $read
        Write-GuiOutput ($job.Encoding.GetString($buffer, $offset, $read - $offset))
    } catch {
        # The file can be briefly locked while PowerShell creates it; the next tick retries.
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Complete-GuiJob {
    Receive-GuiJobOutput
    $job = $script:Job
    $script:Job = $null
    $code = $job.Process.ExitCode
    $outcome = if ($job.UseExitCode) {
        switch ($code) { 0 { 'succeeded' } 1 { 'finished with failures (exit code 1)' } 2 { 'failed (exit code 2)' } default { "ended with exit code $code" } }
    } else {
        if ($code -eq 0) { 'succeeded' } else { "failed (exit code $code)" }
    }
    $minutes = ((Get-Date) - $job.Started).TotalMinutes
    Write-GuiOutput ("=== {0} - {1} after {2:N1} min ===`r`n" -f $job.Title, $outcome, $minutes)
    Set-GuiStatus "$($job.Title) $outcome."
    Update-GuiBusyState
    if ($job.RefreshStatus) { Update-StatusView }
    if ($code -eq 0 -and $job.OnSuccess) { Invoke-GuiSafely $job.OnSuccess }
    if ($code -ne 0) {
        Show-GuiMessage -Text "$($job.Title) $outcome. See the output panel for details." -Icon Warning | Out-Null
    }
}

function Stop-GuiJob {
    if (-not $script:Job) { return }
    $answer = Show-GuiMessage -Icon Warning -Buttons YesNo -Text ("Stop '{0}'?`n`nThe ledger is written atomically, so stopping is safe, but the model being processed is left unfinished until the next run." -f $script:Job.Title)
    if ($answer -ne 'Yes') { return }
    # /T also ends child processes (DISM, extractors).
    & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $script:Job.Process.Id /T /F | Out-Null
}

function Update-GuiBusyState {
    $busy = $null -ne $script:Job
    $ui.CancelJobButton.IsEnabled = $busy
    $ui.JobText.Text = if ($busy) { 'Running: {0} (started {1:HH:mm:ss})' -f $script:Job.Title, $script:Job.Started } else { '' }
    foreach ($name in @('PreflightButton', 'DryRunButton', 'FullRunButton', 'CatalogScanButton')) { $ui[$name].IsEnabled = -not $busy }
    Update-ActionButtons
}
#endregion Running scripts

#region Models & versions
function New-GuiTargetRow {
    param ($Target, $State, [bool]$Configured)

    $row = [ordered]@{
        Target = $Target.DisplayName; Vendor = $Target.Vendor; Model = $Target.Model; OSName = $Target.OSName
        OSBuild = $Target.OSBuild; Architecture = $Target.Architecture; Key = $Target.Key; Configured = $Configured
        Status = ''; Flag = ''; ProductionVersion = ''; ProductionPackageID = ''; PilotVersion = ''; PilotPackageID = ''
        LatestCatalog = ''; RollbackTarget = ''; Holds = ''; LastChecked = ''; State = $State; Candidates = @{}
    }
    if ($State) {
        $row.ProductionVersion = [string]$State.Deployed.Production
        $row.PilotVersion = [string]$State.Deployed.Pilot
        if ($State.Packages.Production) { $row.ProductionPackageID = [string]$State.Packages.Production.PackageID }
        if ($State.Packages.Pilot) { $row.PilotPackageID = [string]$State.Packages.Pilot.PackageID }
        if ($State.LastCatalog) { $row.LatestCatalog = '{0} ({1})' -f $State.LastCatalog.VendorVersion, $State.LastCatalog.ReleaseDate }
        $row.Holds = (@('Production', 'Pilot') | Where-Object { $State.Holds[$_] }) -join ', '
        $row.LastChecked = Format-GuiDate $State.LastChecked
        foreach ($ring in @('Production', 'Pilot')) {
            $candidate = Get-SDARollbackCandidate -State $State -Ring $ring
            if ($candidate) { $row.Candidates[$ring] = [string]$candidate.VersionId }
        }
        $row.RollbackTarget = [string]$row.Candidates['Production']
    }

    if (-not $Configured) { $row.Status = 'Removed from config'; $row.Flag = 'Inactive' }
    elseif (-not $Target.Enabled) { $row.Status = 'Disabled'; $row.Flag = 'Inactive' }
    elseif ($row.Holds) { $row.Status = 'On hold'; $row.Flag = 'Hold' }
    elseif (-not $State -or -not $State.LastChecked) { $row.Status = 'Not run yet' }
    elseif (-not $State.Deployed.Production -and -not $State.Deployed.Pilot) { $row.Status = 'Nothing deployed' }
    else { $row.Status = 'OK' }
    return [pscustomobject]$row
}

function Update-StatusView {
    $selectedKey = if ($ui.TargetsGrid.SelectedItem) { $ui.TargetsGrid.SelectedItem.Key } else { $null }
    $script:Config = $null
    try {
        $script:Config = Import-SDAConfig -Path $script:ConfigPath
    } catch {
        $ui.TargetsGrid.ItemsSource = $null
        Update-TargetDetails
        Set-GuiStatus 'The configuration has problems - fix them on the Configuration tab.'
        Show-GuiMessage -Icon Warning -Text ("The model list can't be shown until the configuration is fixed:`n`n{0}" -f $_.Exception.Message) | Out-Null
        return
    }

    $states = @{}
    foreach ($s in @(Get-SDAAllStates -Config $script:Config)) { if ($s) { $states[$s.Key] = $s } }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($target in @($script:Config.Targets)) {
        $rows.Add((New-GuiTargetRow -Target $target -State $states[$target.Key] -Configured $true))
        $states.Remove($target.Key)
    }
    # Ledgers for models no longer in the configuration can still be rolled back.
    foreach ($s in @($states.Values)) {
        $orphan = [pscustomobject]@{
            Vendor = $s.Vendor; Model = $s.Model; OSName = $s.OSName; OSBuild = $s.OSBuild; Architecture = $s.Architecture
            Key = $s.Key; Enabled = $false
            DisplayName = ('{0} {1} - {2}{3} {4}' -f $s.Vendor, $s.Model, $s.OSName, $(if ($s.OSBuild) { " $($s.OSBuild)" } else { '' }), $s.Architecture)
        }
        $rows.Add((New-GuiTargetRow -Target $orphan -State $s -Configured $false))
    }

    $ui.TargetsGrid.ItemsSource = $rows.ToArray()
    if ($selectedKey) { $ui.TargetsGrid.SelectedItem = $rows | Where-Object { $_.Key -eq $selectedKey } | Select-Object -First 1 }
    Update-TargetDetails
    Set-GuiStatus ('{0} model/OS target(s). Updated {1:HH:mm:ss}.' -f $rows.Count, (Get-Date))
}

function Update-TargetDetails {
    $row = $ui.TargetsGrid.SelectedItem
    if (-not $row -or -not $row.State) {
        $ui.VersionsGrid.ItemsSource = $null
        $ui.HistoryGrid.ItemsSource = $null
        Update-ActionButtons
        return
    }
    $state = $row.State

    $versions = foreach ($v in (@($state.Versions) | Sort-Object -Property @{ Expression = { Get-SDAVersionSortDate $_ } } -Descending)) {
        [pscustomobject]@{
            VersionId     = $v.VersionId
            VendorVersion = $v.VendorVersion
            ReleaseDate   = $v.ReleaseDate
            Status        = $v.Status
            DeployedTo    = (@('Production', 'Pilot') | Where-Object { $state.Deployed[$_] -eq $v.VersionId }) -join ', '
            RollbackFor   = (@('Production', 'Pilot') | Where-Object { $row.Candidates[$_] -eq $v.VersionId }) -join ', '
            Content       = $(if ($v.Status -eq 'Pruned') { 'Removed' } elseif ($v.StagedPath -and (Test-Path -LiteralPath $v.StagedPath)) { 'Present' } else { 'Missing' })
            Staged        = Format-GuiDate $v.StagedUtc
            Notes         = $v.BlockedReason
        }
    }
    $ui.VersionsGrid.ItemsSource = @($versions)

    $history = @($state.History)
    [array]::Reverse($history)
    $ui.HistoryGrid.ItemsSource = @(foreach ($h in $history) {
            [pscustomobject]@{
                Time = Format-GuiDate $h.TimestampUtc; Action = $h.Action; Ring = $h.Ring; FromVersion = $h.FromVersion
                ToVersion = $h.ToVersion; PackageID = $h.PackageID; Initiator = $h.Initiator; Reason = $h.Reason
            }
        })
    Update-ActionButtons
}

function Update-ActionButtons {
    $row = $ui.TargetsGrid.SelectedItem
    $idle = $null -eq $script:Job
    $hasVersions = $row -and $row.State -and @($row.State.Versions).Count -gt 0
    foreach ($name in @('PromoteButton', 'RollbackButton', 'BlockButton', 'UnblockButton')) { $ui[$name].IsEnabled = $idle -and [bool]$hasVersions }
    foreach ($name in @('HoldButton', 'ReleaseButton')) { $ui[$name].IsEnabled = $idle -and [bool]$row }
}

function Get-GuiTargetArguments ($Row) {
    $arguments = [ordered]@{ Vendor = $Row.Vendor; Model = $Row.Model; OperatingSystem = $Row.OSName; Architecture = $Row.Architecture }
    if ($Row.OSBuild) { $arguments.OSBuild = $Row.OSBuild }
    return $arguments
}

function New-GuiVersionItem ($Version, [string]$Prefix = '') {
    $text = '{0}{1}   (vendor {2}, released {3})' -f $Prefix, $Version.VersionId, $Version.VendorVersion, $Version.ReleaseDate
    return [pscustomobject]@{ Text = $text; Value = [string]$Version.VersionId }
}

function Get-GuiSortedVersions ($State, [string[]]$Status) {
    return @(@($State.Versions) | Where-Object { $Status -contains $_.Status } |
            Sort-Object -Property @{ Expression = { Get-SDAVersionSortDate $_ } } -Descending)
}

function Show-GuiActionDialog {
    <#
    .SYNOPSIS
        Collects the ring, version, options and reason for an action. Returns $null when cancelled.
    .PARAMETER VersionsByRing
        Version choices per ring (key '' when the action has no ring choice). Items have Text and Value;
        an empty Value means "let the script choose".
    #>
    param (
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$ConfirmText,
        [string[]]$Rings,
        [hashtable]$VersionsByRing,
        [string]$VersionLabel = 'Version',
        [object[]]$Options = @()
    )

    $dialog = New-GuiWindow -Xaml $dialogXaml
    $dlg = $dialog.Controls
    $dialog.Window.Owner = $script:Window
    $dialog.Window.Title = $Title
    $dlg.MessageText.Text = $Message
    $dlg.OkButton.Content = $ConfirmText
    $dlg.VersionLabel.Text = $VersionLabel

    $dlg.RingPanel.Visibility = if ($Rings) { 'Visible' } else { 'Collapsed' }
    $dlg.VersionPanel.Visibility = if ($VersionsByRing) { 'Visible' } else { 'Collapsed' }
    $checkBoxes = foreach ($option in $Options) {
        $box = New-Object System.Windows.Controls.CheckBox
        $box.Content = $option.Text
        $box.Tag = $option.Name
        $box.IsChecked = [bool]$option.Checked
        $box.Margin = New-GuiThickness 0 2 0 2
        [void]$dlg.OptionsPanel.Children.Add($box)
        $box
    }

    $fillVersions = {
        if (-not $VersionsByRing) { return }
        $key = if ($Rings) { [string]$dlg.RingCombo.SelectedItem } else { '' }
        $dlg.VersionCombo.ItemsSource = @($VersionsByRing[$key])
        $dlg.VersionCombo.SelectedIndex = if (@($VersionsByRing[$key]).Count) { 0 } else { -1 }
    }
    if ($Rings) {
        $dlg.RingCombo.ItemsSource = $Rings
        $dlg.RingCombo.SelectedIndex = 0
        $dlg.RingCombo.add_SelectionChanged({ & $fillVersions })
    }
    & $fillVersions

    $dlg.OkButton.add_Click({
            if ($VersionsByRing -and -not $dlg.VersionCombo.SelectedItem) {
                [System.Windows.MessageBox]::Show($dialog.Window, 'There is no version to choose for this ring.', $Title, 'OK', 'Warning') | Out-Null
                return
            }
            if ([string]::IsNullOrWhiteSpace($dlg.ReasonBox.Text)) {
                [System.Windows.MessageBox]::Show($dialog.Window, 'Enter a reason (for example a change or incident number).', $Title, 'OK', 'Warning') | Out-Null
                $dlg.ReasonBox.Focus() | Out-Null
                return
            }
            $dialog.Window.DialogResult = $true
        })
    $dlg.ReasonBox.Focus() | Out-Null

    if (-not $dialog.Window.ShowDialog()) { return $null }
    $result = @{
        Ring    = [string]$dlg.RingCombo.SelectedItem
        Version = $(if ($dlg.VersionCombo.SelectedItem) { [string]$dlg.VersionCombo.SelectedItem.Value } else { '' })
        Reason  = $dlg.ReasonBox.Text.Trim()
        Options = @{}
    }
    foreach ($box in @($checkBoxes)) { $result.Options[$box.Tag] = [bool]$box.IsChecked }
    return $result
}

function Invoke-GuiPromote {
    $row = $ui.TargetsGrid.SelectedItem
    $state = $row.State
    $production = [string]$state.Deployed.Production
    $pilot = [string]$state.Deployed.Pilot

    $items = New-Object System.Collections.Generic.List[object]
    if ($pilot -and $pilot -ne $production) { $items.Add([pscustomobject]@{ Text = "The current Pilot version ($pilot)"; Value = '' }) }
    foreach ($v in (Get-GuiSortedVersions -State $state -Status 'Available')) {
        if ($v.VersionId -ne $production) { $items.Add((New-GuiVersionItem $v)) }
    }

    $answer = Show-GuiActionDialog -Title 'Promote to Production' -ConfirmText 'Promote' -VersionsByRing @{ '' = $items.ToArray() } `
        -Message ("Points the Production package of {0} at the chosen version and updates the distribution points.`n`nProduction currently runs: {1}" -f $row.Target, $(if ($production) { $production } else { 'nothing' }))
    if (-not $answer) { return }

    $arguments = Get-GuiTargetArguments $row
    if ($answer.Version) { $arguments.Version = $answer.Version }
    $arguments.Reason = $answer.Reason
    Start-GuiScript -Script 'Invoke-DriverPromotion.ps1' -Title "Promote $($row.Target)" -Arguments $arguments -Switches '-Confirm:$false' -RefreshStatus
}

function Invoke-GuiRollback {
    $row = $ui.TargetsGrid.SelectedItem
    $state = $row.State
    $rings = @('Production', 'Pilot') | Where-Object { $state.Deployed[$_] }
    if (-not $rings) { Show-GuiMessage -Text 'Nothing is deployed to either ring yet, so there is nothing to roll back.' | Out-Null; return }

    $byRing = @{}
    foreach ($ring in $rings) {
        $items = New-Object System.Collections.Generic.List[object]
        $candidate = $row.Candidates[$ring]
        if ($candidate) { $items.Add([pscustomobject]@{ Text = "Previous version ($candidate)"; Value = '' }) }
        foreach ($v in (Get-GuiSortedVersions -State $state -Status 'Available')) {
            if ($v.VersionId -ne $state.Deployed[$ring] -and $v.VersionId -ne $candidate -and (Test-SDAVersionUsable -Version $v)) { $items.Add((New-GuiVersionItem $v)) }
        }
        $byRing[$ring] = $items.ToArray()
    }

    $answer = Show-GuiActionDialog -Title 'Roll back' -ConfirmText 'Roll back' -Rings $rings -VersionsByRing $byRing -VersionLabel 'Roll back to' `
        -Message ("Re-points the ring's package for {0} to an earlier version (same PackageID, so no task sequence changes) and updates the distribution points.`n`nProduction: {1}    Pilot: {2}" -f $row.Target, $(if ($state.Deployed.Production) { $state.Deployed.Production } else { '-' }), $(if ($state.Deployed.Pilot) { $state.Deployed.Pilot } else { '-' })) `
        -Options @(
            @{ Name = 'Block'; Text = "Block the version being replaced, so the schedule won't redeploy it"; Checked = $true }
            @{ Name = 'Hold'; Text = 'Hold the ring: no automatic changes until it is released'; Checked = $false }
        )
    if (-not $answer) { return }

    $arguments = Get-GuiTargetArguments $row
    $arguments.Ring = $answer.Ring
    if ($answer.Version) { $arguments.ToVersion = $answer.Version }
    $arguments.Reason = $answer.Reason
    $switches = @('-Confirm:$false')
    if (-not $answer.Options.Block) { $switches += '-NoBlock' }
    if ($answer.Options.Hold) { $switches += '-Hold' }
    Start-GuiScript -Script 'Invoke-DriverRollback.ps1' -Title "Roll back $($row.Target) ($($answer.Ring))" -Arguments $arguments -Switches $switches -RefreshStatus
}

function Invoke-GuiDeploymentState {
    param ([Parameter(Mandatory)][ValidateSet('Block', 'Unblock', 'Hold', 'Release')][string]$Action)

    $row = $ui.TargetsGrid.SelectedItem
    $state = $row.State
    $arguments = Get-GuiTargetArguments $row

    switch ($Action) {
        'Block' {
            $items = @(Get-GuiSortedVersions -State $state -Status 'Available' | ForEach-Object { New-GuiVersionItem $_ })
            if (-not $items) { Show-GuiMessage -Text 'There are no available versions to block.' | Out-Null; return }
            $answer = Show-GuiActionDialog -Title 'Block version' -ConfirmText 'Block' -VersionsByRing @{ '' = $items } `
                -Message "The scheduled run will never deploy or promote a blocked version of $($row.Target). This does not change what devices receive now; use Roll back for that."
            if (-not $answer) { return }
            $arguments.BlockVersion = $answer.Version
        }
        'Unblock' {
            $items = @(Get-GuiSortedVersions -State $state -Status 'Blocked' | ForEach-Object { New-GuiVersionItem $_ })
            if (-not $items) { Show-GuiMessage -Text 'No versions of this model are blocked.' | Out-Null; return }
            $answer = Show-GuiActionDialog -Title 'Unblock version' -ConfirmText 'Unblock' -VersionsByRing @{ '' = $items } `
                -Message "Makes the version eligible again. If it is still the newest release, the next run deploys it."
            if (-not $answer) { return }
            $arguments.UnblockVersion = $answer.Version
        }
        'Hold' {
            $rings = @('Production', 'Pilot') | Where-Object { -not ($state -and $state.Holds[$_]) }
            if (-not $rings) { Show-GuiMessage -Text 'Both rings are already on hold.' | Out-Null; return }
            $answer = Show-GuiActionDialog -Title 'Hold ring' -ConfirmText 'Hold' -Rings $rings `
                -Message "Freezes the ring for $($row.Target): no automatic deployments or promotions until it is released."
            if (-not $answer) { return }
            $arguments.HoldRing = $answer.Ring
        }
        'Release' {
            $rings = @('Production', 'Pilot') | Where-Object { $state -and $state.Holds[$_] }
            if (-not $rings) { Show-GuiMessage -Text 'Neither ring is on hold.' | Out-Null; return }
            $answer = Show-GuiActionDialog -Title 'Release ring' -ConfirmText 'Release' -Rings $rings `
                -Message "Removes the hold for $($row.Target). Automatic deployments resume on the next run."
            if (-not $answer) { return }
            $arguments.ReleaseRing = $answer.Ring
        }
    }
    $arguments.Reason = $answer.Reason
    Start-GuiScript -Script 'Set-DriverDeploymentState.ps1' -Title "$Action - $($row.Target)" -Arguments $arguments -RefreshStatus
}
#endregion Models & versions

#region Run
function Start-GuiRun {
    param ([Parameter(Mandatory)][ValidateSet('Preflight', 'DryRun', 'Full')][string]$Mode)

    $vendors = @(@('Dell', 'HP', 'Lenovo') | Where-Object { $ui["Run$_"].IsChecked })
    if (-not $vendors) { Show-GuiMessage -Text 'Select at least one vendor.' -Icon Warning | Out-Null; return }
    $models = @($ui.RunModels.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    if ($Mode -eq 'Full') {
        $answer = Show-GuiMessage -Icon Question -Buttons YesNo -Text ("A full run downloads and stages new driver packs and updates ConfigMgr packages for the selected models.`n`nIt runs as {0}, so the proxy and ConfigMgr see your account rather than the computer account the scheduled task uses. To test exactly what the schedule does, use 'Start task now' instead.`n`nContinue?" -f $script:Identity)
        if ($answer -ne 'Yes') { return }
    }

    $arguments = [ordered]@{}
    if ($vendors.Count -lt 3) { $arguments.Vendor = $vendors }
    if ($models) { $arguments.Model = $models }
    $switches = switch ($Mode) { 'Preflight' { @('-PreflightOnly') } 'DryRun' { @('-DryRun') } default { @() } }
    $title = switch ($Mode) { 'Preflight' { 'Preflight check' } 'DryRun' { 'Dry run' } default { 'Full run' } }
    Start-GuiScript -Script 'Invoke-DriverAutomation.ps1' -Title $title -Arguments $arguments -Switches $switches -UseExitCode -RefreshStatus
}

function Update-TaskView {
    $task = $null
    try { $task = Get-ScheduledTask -TaskName $script:TaskName -TaskPath $script:TaskPath -ErrorAction SilentlyContinue } catch { }
    if (-not $task) {
        foreach ($name in @('TaskScheduleText', 'TaskLastRunText', 'TaskResultText', 'TaskNextRunText')) { $ui[$name].Text = '-' }
        $ui.TaskStateText.Text = 'Not installed. Run Install-DriverAutomation.ps1 to register it.'
        $ui.StartTaskButton.IsEnabled = $false
        $ui.HeaderTask.Text = 'Scheduled task: not installed'
        return
    }

    $info = Get-ScheduledTaskInfo -InputObject $task
    $result = switch ([int64]$info.LastTaskResult) {
        0 { 'Success' }
        1 { 'Finished with failures (exit code 1)' }
        2 { 'Failed (exit code 2)' }
        267009 { 'Running' }
        267011 { 'Has not run yet' }
        default { 'Exit code 0x{0:X8}' -f [int64]$info.LastTaskResult }
    }
    $lastRun = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'Never' }
    $schedule = @(foreach ($trigger in @($task.Triggers)) {
            $at = try { ([datetime]$trigger.StartBoundary).ToString('HH:mm') } catch { '?' }
            if ($trigger.CimClass.CimClassName -eq 'MSFT_TaskWeeklyTrigger') { "Weekly at $at" } else { "Daily at $at" }
        }) -join '; '

    $ui.TaskStateText.Text = [string]$task.State
    $ui.TaskScheduleText.Text = $(if ($schedule) { "$schedule (plus up to 30 minutes random delay)" } else { 'No trigger' })
    $ui.TaskLastRunText.Text = $lastRun
    $ui.TaskResultText.Text = $(if ($lastRun -eq 'Never') { '-' } else { $result })
    $ui.TaskNextRunText.Text = $(if ($info.NextRunTime) { $info.NextRunTime.ToString('yyyy-MM-dd HH:mm') } else { '-' })
    $ui.StartTaskButton.IsEnabled = [string]$task.State -ne 'Running'
    $ui.HeaderTask.Text = 'Scheduled task: {0} - last run {1}{2}' -f $task.State, $lastRun, $(if ($lastRun -ne 'Never') { " ($result)" } else { '' })
}

function Start-GuiScheduledTask {
    $answer = Show-GuiMessage -Icon Question -Buttons YesNo -Text 'Start the scheduled task now? It performs a full run as SYSTEM for all enabled models.'
    if ($answer -ne 'Yes') { return }
    Start-ScheduledTask -TaskName $script:TaskName -TaskPath $script:TaskPath
    Set-GuiStatus 'Scheduled task started. Following DriverAutomation.log on the Logs tab.'
    Start-Sleep -Milliseconds 800
    Update-TaskView
    $ui.LogAutoRefresh.IsChecked = $true
    $ui.MainTabs.SelectedItem = $ui.LogsTab
    Update-LogFileList -Select 'DriverAutomation.log'
    Update-LogView
}
#endregion Run

#region Configuration
function New-GuiSettingsForm {
    $ui.SettingsPanel.Children.Clear()
    $script:SettingControls = @{}

    foreach ($section in $script:SettingSections.Keys) {
        $group = New-Object System.Windows.Controls.GroupBox
        $group.Header = $script:SettingSections[$section]
        $group.Margin = New-GuiThickness 0 0 0 10
        $group.Padding = New-GuiThickness 8 6 8 4
        $grid = New-Object System.Windows.Controls.Grid
        $labelColumn = New-Object System.Windows.Controls.ColumnDefinition
        $labelColumn.Width = New-Object System.Windows.GridLength(230)
        $grid.ColumnDefinitions.Add($labelColumn)
        $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))

        $rowIndex = 0
        foreach ($spec in @($script:SettingSpec | Where-Object { $_.Path.Split('.')[0] -eq $section })) {
            $rowDefinition = New-Object System.Windows.Controls.RowDefinition
            $rowDefinition.Height = [System.Windows.GridLength]::Auto
            $grid.RowDefinitions.Add($rowDefinition)

            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = $spec.Label
            $label.Margin = New-GuiThickness 0 6 8 0
            [System.Windows.Controls.Grid]::SetRow($label, $rowIndex)
            [void]$grid.Children.Add($label)

            switch ($spec.Type) {
                'Bool' {
                    $control = New-Object System.Windows.Controls.CheckBox
                    $control.VerticalAlignment = 'Center'
                }
                'Choice' {
                    $control = New-Object System.Windows.Controls.ComboBox
                    $control.ItemsSource = $spec.Choices
                    $control.Width = 200
                    $control.HorizontalAlignment = 'Left'
                }
                'List' {
                    $control = New-Object System.Windows.Controls.TextBox
                    $control.AcceptsReturn = $true
                    $control.Height = 62
                    $control.MaxWidth = 560
                    $control.VerticalScrollBarVisibility = 'Auto'
                }
                'Int' {
                    $control = New-Object System.Windows.Controls.TextBox
                    $control.Width = 90
                    $control.HorizontalAlignment = 'Left'
                }
                default {
                    $control = New-Object System.Windows.Controls.TextBox
                    $control.MaxWidth = 560
                }
            }
            $control.Margin = New-GuiThickness 0 4 0 0
            $script:SettingControls[$spec.Path] = $control

            $cell = New-Object System.Windows.Controls.StackPanel
            [void]$cell.Children.Add($control)
            if ($spec.Help) {
                $help = New-Object System.Windows.Controls.TextBlock
                $help.Text = $spec.Help
                $help.Foreground = [System.Windows.Media.Brushes]::DimGray
                $help.TextWrapping = 'Wrap'
                $help.MaxWidth = 560
                $help.HorizontalAlignment = 'Left'
                $help.Margin = New-GuiThickness 0 1 0 2
                [void]$cell.Children.Add($help)
            }
            [System.Windows.Controls.Grid]::SetRow($cell, $rowIndex)
            [System.Windows.Controls.Grid]::SetColumn($cell, 1)
            [void]$grid.Children.Add($cell)
            $rowIndex++
        }
        $group.Content = $grid
        [void]$ui.SettingsPanel.Children.Add($group)
    }
}

function Import-GuiConfigFile {
    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) { throw "Configuration file not found: $($script:ConfigPath)" }
    $text = [System.IO.File]::ReadAllText($script:ConfigPath)
    try {
        $doc = ConvertTo-SDAHashtable -InputObject (ConvertFrom-Json -InputObject $text)
    } catch {
        throw "The configuration file is not valid JSON, so the form can't load it. Fix it with 'Open in Notepad'.`n`n$($_.Exception.Message)"
    }
    $script:ConfigText = $text

    $effective = Merge-SDAHashtable -Default (Get-SDADefaultConfig) -Override $doc
    foreach ($spec in $script:SettingSpec) {
        $control = $script:SettingControls[$spec.Path]
        $value = Get-GuiPathValue -Dictionary $effective -Path $spec.Path
        switch ($spec.Type) {
            'Bool' { $control.IsChecked = [bool]$value }
            'Choice' { $control.SelectedItem = [string]$value }
            'List' { $control.Text = (@($value) | Where-Object { $_ }) -join "`r`n" }
            default { $control.Text = [string]$value }
        }
    }

    $script:ModelRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[SDAGui.ModelRow]'
    foreach ($m in @($doc['Models'] | Where-Object { $_ -is [System.Collections.IDictionary] })) {
        $modelRow = New-Object SDAGui.ModelRow
        $modelRow.Enabled = if ($m.Contains('Enabled')) { [bool]$m.Enabled } else { $true }
        $modelRow.Vendor = [string]$m.Vendor
        $modelRow.Model = [string]$m.Model
        $modelRow.SystemIds = (@($m.SystemIds) | Where-Object { $_ }) -join ', '
        $modelRow.Source = $m
        foreach ($os in @($m.OperatingSystems | Where-Object { $_ -is [System.Collections.IDictionary] })) {
            $osRow = New-Object SDAGui.OsRow
            $osRow.Name = [string]$os.Name
            $osRow.Build = [string]$os.Build
            $osRow.Architecture = if ($os.Architecture) { [string]$os.Architecture } else { 'x64' }
            $osRow.Source = $os
            $modelRow.OperatingSystems.Add($osRow)
        }
        $script:ModelRows.Add($modelRow)
    }
    $ui.ModelsGrid.ItemsSource = $script:ModelRows
    if ($script:ModelRows.Count) { $ui.ModelsGrid.SelectedIndex = 0 }

    $script:FormBaseline = try { ConvertTo-GuiJson (Get-GuiFormConfig) } catch { $null }
}

function Copy-GuiExtraKeys {
    # Carries over keys the form does not edit, so hand-added settings survive a save.
    param ($Source, [System.Collections.IDictionary]$Target, [string[]]$Known)
    if ($Source -isnot [System.Collections.IDictionary]) { return }
    foreach ($key in $Source.Keys) {
        if ($Known -notcontains $key -and -not $Target.Contains($key)) { $Target[$key] = $Source[$key] }
    }
}

function Get-GuiFormConfig {
    <#
    .SYNOPSIS
        Builds the configuration from the form on top of the file as loaded. Throws on unreadable fields.
    #>
    [void]$ui.OsGrid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true)
    [void]$ui.ModelsGrid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true)

    $doc = ConvertTo-SDAHashtable -InputObject (ConvertFrom-Json -InputObject $script:ConfigText)
    $problems = New-Object System.Collections.Generic.List[string]

    foreach ($spec in $script:SettingSpec) {
        $control = $script:SettingControls[$spec.Path]
        $value = $null
        $ok = $true
        switch ($spec.Type) {
            'Bool' { $value = [bool]$control.IsChecked }
            'Choice' { $value = [string]$control.SelectedItem }
            'List' { $value = @($control.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            'Int' {
                $number = 0
                if ([int]::TryParse($control.Text.Trim(), [ref]$number)) { $value = $number }
                else { $ok = $false; $problems.Add("$($spec.Label): '$($control.Text)' is not a whole number.") }
            }
            default { $value = $control.Text.Trim() }
        }
        if ($ok) { Set-GuiPathValue -Dictionary $doc -Path $spec.Path -Value $value }
    }

    $models = New-Object System.Collections.Generic.List[object]
    foreach ($m in $script:ModelRows) {
        $operatingSystems = New-Object System.Collections.Generic.List[object]
        foreach ($os in $m.OperatingSystems) {
            $osEntry = [ordered]@{ Name = [string]$os.Name }
            if (-not [string]::IsNullOrWhiteSpace($os.Build)) { $osEntry.Build = $os.Build.Trim().ToUpperInvariant() }
            $osEntry.Architecture = $(if ($os.Architecture) { [string]$os.Architecture } else { 'x64' })
            Copy-GuiExtraKeys -Source $os.Source -Target $osEntry -Known 'Name', 'Build', 'Architecture'
            $operatingSystems.Add($osEntry)
        }
        $entry = [ordered]@{
            Vendor           = [string]$m.Vendor
            Model            = ([string]$m.Model).Trim()
            SystemIds        = @([string]$m.SystemIds -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() })
            OperatingSystems = $operatingSystems.ToArray()
            Enabled          = [bool]$m.Enabled
        }
        Copy-GuiExtraKeys -Source $m.Source -Target $entry -Known 'Vendor', 'Model', 'SystemIds', 'OperatingSystems', 'Enabled'
        $models.Add($entry)
    }
    $doc['Models'] = $models.ToArray()

    if ($problems.Count) { throw ($problems -join "`n") }
    return $doc
}

function Get-GuiPathWarning {
    param ([string]$Label, [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if ($Path.StartsWith('\\')) { return "$Label '$Path' is a UNC path. Use a local path on this server$(if ($Label -like 'Package source*') { ', or leave it blank when the share is on another server' })." }
    try { $root = [System.IO.Path]::GetPathRoot($Path) } catch { return "$Label '$Path' is not a valid path." }
    if ($root -notmatch '^[A-Za-z]:\\$') { return "$Label '$Path' is not a full path such as D:\SCCMDriverAutomation." }
    $drive = New-Object System.IO.DriveInfo($root)
    if (-not $drive.IsReady) {
        return "$Label '$Path': drive $($root.TrimEnd('\')) does not exist on this computer. The scripts stop with 'Cannot find drive' until it does."
    }
    if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
        return "$Label '$Path' is on a $($drive.DriveType) drive. Use a local fixed drive; mapped drives are not visible to the SYSTEM task."
    }
}

function Test-GuiFormConfig {
    $result = @{ Json = $null; Errors = New-Object System.Collections.Generic.List[string]; Warnings = New-Object System.Collections.Generic.List[string] }
    try {
        $doc = Get-GuiFormConfig
    } catch {
        $result.Errors.Add($_.Exception.Message)
        return $result
    }
    $result.Json = ConvertTo-GuiJson $doc

    # Validate with the module's own rules by loading a temporary copy.
    $temp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($temp, $result.Json, (New-Object System.Text.UTF8Encoding($false)))
        [void](Import-SDAConfig -Path $temp)
    } catch {
        $result.Errors.Add($_.Exception.Message)
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }

    foreach ($warning in @(
            (Get-GuiPathWarning -Label 'Data root' -Path $doc.General.DataRoot),
            (Get-GuiPathWarning -Label 'Package source (local path)' -Path $doc.ConfigMgr.PackageSourceLocalRoot))) {
        if ($warning) { $result.Warnings.Add($warning) }
    }
    return $result
}

function Test-GuiConfigDirty {
    if (-not $script:ConfigText -or -not $script:ModelRows) { return $false }
    try { $current = ConvertTo-GuiJson (Get-GuiFormConfig) } catch { return $true }
    return $current -ne $script:FormBaseline
}

function Show-GuiValidation {
    $check = Test-GuiFormConfig
    if ($check.Errors.Count) {
        Show-GuiMessage -Icon Error -Text ("The configuration has problems:`n`n" + ($check.Errors -join "`n")) | Out-Null
    } elseif ($check.Warnings.Count) {
        Show-GuiMessage -Icon Warning -Text ("The configuration is valid, but check these on this server:`n`n- " + ($check.Warnings -join "`n- ")) | Out-Null
    } else {
        Show-GuiMessage -Text 'The configuration is valid.' | Out-Null
    }
}

function Save-GuiConfig {
    $check = Test-GuiFormConfig
    if ($check.Errors.Count) {
        Show-GuiMessage -Icon Error -Text ("The configuration was not saved:`n`n" + ($check.Errors -join "`n")) | Out-Null
        return $false
    }
    if ($check.Warnings.Count) {
        $answer = Show-GuiMessage -Icon Warning -Buttons YesNo -Text ("Check these on this server:`n`n- " + ($check.Warnings -join "`n- ") + "`n`nSave anyway?")
        if ($answer -ne 'Yes') { return $false }
    }
    if (Test-Path -LiteralPath $script:ConfigPath) { Copy-Item -LiteralPath $script:ConfigPath -Destination "$($script:ConfigPath).bak" -Force }
    [System.IO.File]::WriteAllText($script:ConfigPath, $check.Json, (New-Object System.Text.UTF8Encoding($false)))
    $script:ConfigText = $check.Json
    $script:FormBaseline = $check.Json
    Set-GuiStatus "Configuration saved. The previous file was kept as $(Split-Path -Leaf $script:ConfigPath).bak."
    Update-StatusView
    return $true
}

function Add-GuiModel {
    $modelRow = New-Object SDAGui.ModelRow
    $modelRow.OperatingSystems.Add((New-Object SDAGui.OsRow))
    $script:ModelRows.Add($modelRow)
    $ui.ModelsGrid.SelectedItem = $modelRow
    $ui.ModelsGrid.ScrollIntoView($modelRow)
    $ui.ModelsGrid.CurrentCell = New-Object System.Windows.Controls.DataGridCellInfo($modelRow, $ui.ModelsGrid.Columns[2])
    [void]$ui.ModelsGrid.BeginEdit()
}

function Remove-GuiModel {
    $modelRow = $ui.ModelsGrid.SelectedItem
    if (-not $modelRow) { return }
    $answer = Show-GuiMessage -Icon Question -Buttons YesNo -Text ("Remove '{0}' from the configuration?`n`nUpdates stop for this model. Its packages and ledger are kept, and it can still be rolled back from the Models & versions tab. To pause it instead, clear Enabled." -f $modelRow.Model)
    if ($answer -eq 'Yes') {
        [void]$ui.ModelsGrid.CancelEdit()
        [void]$script:ModelRows.Remove($modelRow)
    }
}
#endregion Configuration

#region Add from vendor catalog
$script:CatalogAges = [ordered]@{ 'Any time' = 0; 'Last 12 months' = 12; 'Last 2 years' = 24; 'Last 3 years' = 36 }
$script:CatalogSummary = ''

function ConvertTo-GuiModelKey ([string]$Vendor, [string]$Model) {
    # Same comparison as the resolvers: case and spacing ignored, leading vendor name optional.
    $name = ($Model -replace '\s+', ' ').Trim()
    $name = $name -replace "^(?i)$([regex]::Escape($Vendor))\s+", ''
    return ('{0}|{1}' -f $Vendor, $name).ToLowerInvariant()
}

function ConvertTo-GuiOsKey ([string]$Name, [string]$Build, [string]$Architecture) {
    if (-not $Architecture) { $Architecture = 'x64' }
    return ('{0}|{1}|{2}' -f $Name, $Build.Trim(), $Architecture).ToUpperInvariant()
}

function Get-GuiConfigLookup {
    $lookup = @{ Names = @{}; Ids = @{} }
    foreach ($row in $script:ModelRows) {
        if ([string]::IsNullOrWhiteSpace($row.Model)) { continue }
        $lookup.Names[(ConvertTo-GuiModelKey $row.Vendor $row.Model)] = $row
        foreach ($id in ([string]$row.SystemIds -split '[,;\s]+')) {
            if ($id) { $lookup.Ids[('{0}|{1}' -f $row.Vendor, $id).ToUpperInvariant()] = $row }
        }
    }
    return $lookup
}

function Find-GuiConfigModel {
    # The configured model a catalog model belongs to: same name, or a shared system ID.
    param ($Lookup, [string]$Vendor, [string]$Model, [string[]]$SystemIds)
    $row = $Lookup.Names[(ConvertTo-GuiModelKey $Vendor $Model)]
    if ($row) { return $row }
    foreach ($id in $SystemIds) {
        $row = $Lookup.Ids[('{0}|{1}' -f $Vendor, $id).ToUpperInvariant()]
        if ($row) { return $row }
    }
}

function Get-GuiCatalogOsSummary ($Model) {
    # "Windows 11: 25H2, 24H2; Windows 10: 22H2", or "Windows 11: x64, Arm64" for Dell.
    $names = [ordered]@{}
    foreach ($os in $Model.OperatingSystems) {
        if (-not $names.Contains($os.Name)) { $names[$os.Name] = New-Object System.Collections.Generic.List[string] }
        $token = if (-not $os.Build) { $os.Architecture } elseif ($os.Architecture -ne 'x64') { "$($os.Build) $($os.Architecture)" } else { $os.Build }
        if ($token -and -not $names[$os.Name].Contains($token)) { $names[$os.Name].Add($token) }
    }
    return ((@($names.Keys) | ForEach-Object { '{0}: {1}' -f $_, ($names[$_] -join ', ') }) -join '; ')
}

function Start-GuiCatalogScan {
    $vendors = @(@('Dell', 'HP', 'Lenovo') | Where-Object { $ui["Catalog$_"].IsChecked })
    if ($vendors.Count -eq 0) { Show-GuiMessage -Text 'Tick at least one vendor to scan.' | Out-Null; return }
    Start-GuiScript -Script 'Get-DriverCatalogModels.ps1' -Title 'Catalog scan' `
        -Arguments ([ordered]@{ Vendor = $vendors; OutFile = $script:CatalogFile }) -OnSuccess { Import-GuiCatalog }
}

function Import-GuiCatalog {
    if (-not (Test-Path -LiteralPath $script:CatalogFile)) { return }
    # Not @(...): Windows PowerShell returns a JSON array as one object, which @() would wrap again.
    $rows = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:CatalogFile))

    [SDAGui.CatalogModel]::SelectedCount = 0
    $byKey = @{}
    $models = New-Object 'System.Collections.Generic.List[SDAGui.CatalogModel]'
    $builds = @{}
    foreach ($r in $rows) {
        $key = ('{0}|{1}' -f $r.Vendor, $r.Model).ToLowerInvariant()
        $model = $byKey[$key]
        if ($null -eq $model) {
            $model = [SDAGui.CatalogModel]::new()
            $model.Vendor = [string]$r.Vendor
            $model.Model = [string]$r.Model
            $model.SystemIdList = [string[]]@($r.SystemIds | Where-Object { $_ })
            $model.SystemIds = $model.SystemIdList -join ', '
            $model.SearchText = ('{0} {1} {2}' -f $model.Vendor, $model.Model, ($model.SystemIdList -join ' ')).ToLowerInvariant()
            $byKey[$key] = $model
            $models.Add($model)
        }
        $os = [SDAGui.CatalogOs]::new()
        $os.Parent = $model
        $os.Name = [string]$r.OSName
        $os.Build = [string]$r.OSBuild
        $os.Architecture = [string]$r.Architecture
        $os.Version = [string]$r.Version
        $os.Released = [string]$r.ReleaseDate
        $model.OperatingSystems.Add($os)
        if ($os.Released -gt $model.Released) { $model.Released = $os.Released }
        if ($os.Build) { $builds[$os.Build] = $true }
    }
    foreach ($model in $models) { $model.OsSummary = Get-GuiCatalogOsSummary $model }
    $script:CatalogModels = $models

    $counts = @($models | Group-Object Vendor | ForEach-Object { '{0} {1:N0}' -f $_.Name, $_.Count }) -join ', '
    $script:CatalogSummary = 'Catalogs scanned {0:yyyy-MM-dd HH:mm}: {1} models.' -f (Get-Item -LiteralPath $script:CatalogFile).LastWriteTime, $counts

    # Builds newest first; '*' (any build) last.
    $current = [string]$ui.CatalogBuildFilter.SelectedItem
    $buildList = @('Any') + @($builds.Keys | Where-Object { $_ -ne '*' } | Sort-Object -Descending) + @($builds.Keys | Where-Object { $_ -eq '*' })
    $script:SuppressEvents = $true
    try {
        $ui.CatalogBuildFilter.ItemsSource = $buildList
        $ui.CatalogBuildFilter.SelectedItem = $(if ($buildList -contains $current) { $current } else { 'Any' })
    } finally {
        $script:SuppressEvents = $false
    }
    Update-GuiCatalogPreference
    Update-GuiCatalogInConfig
    Update-GuiCatalogView
}

function Update-GuiCatalogPreference {
    # Which OS ticking a model selects: the OS and build chosen in the filter.
    $os = [string]$ui.CatalogOsFilter.SelectedItem
    $build = [string]$ui.CatalogBuildFilter.SelectedItem
    [SDAGui.CatalogModel]::PreferredOs = $(if ($os -and $os -ne 'Any') { $os } else { 'Windows 11' })
    [SDAGui.CatalogModel]::PreferredBuild = $(if ($build -and $build -ne 'Any') { $build } else { '' })
}

function Update-GuiCatalogInConfig {
    if (-not $script:CatalogModels -or -not $script:ModelRows) { return }
    $lookup = Get-GuiConfigLookup
    foreach ($model in $script:CatalogModels) {
        $row = Find-GuiConfigModel -Lookup $lookup -Vendor $model.Vendor -Model $model.Model -SystemIds $model.SystemIdList
        if (-not $row) {
            if ($model.InConfig) {
                $model.InConfig = ''
                foreach ($os in $model.OperatingSystems) { $os.InConfig = $false }
            }
            continue
        }
        $configured = @{}
        foreach ($os in $row.OperatingSystems) { $configured[(ConvertTo-GuiOsKey $os.Name $os.Build $os.Architecture)] = $true }
        $count = 0
        foreach ($os in $model.OperatingSystems) {
            $os.InConfig = $configured.ContainsKey((ConvertTo-GuiOsKey $os.Name $os.Build $os.Architecture))
            if ($os.InConfig) { $count++ }
        }
        # A match on system ID alone means the vendor ships one pack for several models (HP platforms,
        # Lenovo Intel/AMD splits); adding this model extends that configured entry.
        $label = if ($lookup.Names.ContainsKey((ConvertTo-GuiModelKey $model.Vendor $model.Model))) { 'Yes' } else { "Via '$($row.Model)'" }
        $model.InConfig = if ($count -eq $model.OperatingSystems.Count) { $label } else { '{0} ({1} of {2} OS)' -f $label, $count, $model.OperatingSystems.Count }
    }
}

function Update-GuiCatalogView {
    if ($script:SuppressEvents) { return }
    if (-not $script:CatalogModels) {
        $ui.CatalogGrid.ItemsSource = $null
        $ui.CatalogInfoText.Text = 'No catalog data yet. Pick the vendors and click Scan catalogs. Only the catalogs are downloaded (a few MB), not driver packs.'
        Update-GuiCatalogCount
        return
    }

    $terms = @($ui.CatalogSearch.Text.ToLowerInvariant() -split '\s+' | Where-Object { $_ })
    $vendor = [string]$ui.CatalogVendorFilter.SelectedItem
    $os = [string]$ui.CatalogOsFilter.SelectedItem
    $build = [string]$ui.CatalogBuildFilter.SelectedItem
    $months = [int]$script:CatalogAges[[string]$ui.CatalogAgeFilter.SelectedItem]
    $since = if ($months) { (Get-Date).AddMonths(-$months).ToString('yyyy-MM-dd') } else { '' }
    $hideConfigured = [bool]$ui.CatalogHideConfigured.IsChecked
    $tickedOnly = [bool]$ui.CatalogSelectedOnly.IsChecked
    $filterOs = ($os -ne 'Any') -or ($build -ne 'Any') -or $since

    $list = New-Object System.Collections.Generic.List[object]
    :model foreach ($m in $script:CatalogModels) {
        if ($vendor -ne 'All' -and $m.Vendor -ne $vendor) { continue }
        if ($hideConfigured -and $m.InConfig) { continue }
        if ($tickedOnly -and -not $m.Selected) { continue }
        foreach ($term in $terms) { if (-not $m.SearchText.Contains($term)) { continue model } }
        if ($filterOs) {
            # At least one pack must fit the OS, build and age filters. Dell packs have no build.
            $fits = $false
            foreach ($o in $m.OperatingSystems) {
                if ($os -ne 'Any' -and $o.Name -ne $os) { continue }
                if ($build -ne 'Any' -and $o.Build -and $o.Build -ne $build) { continue }
                if ($since -and $o.Released -lt $since) { continue }
                $fits = $true
                break
            }
            if (-not $fits) { continue }
        }
        $list.Add($m)
    }
    $ui.CatalogGrid.ItemsSource = $list
    $ui.CatalogInfoText.Text = '{0} Showing {1:N0}.' -f $script:CatalogSummary, $list.Count
    Update-GuiCatalogCount
}

function Update-GuiCatalogCount {
    $count = [SDAGui.CatalogModel]::SelectedCount
    $ui.CatalogSelectedText.Text = switch ($count) { 0 { '' } 1 { '1 model ticked' } default { "$count models ticked" } }
    $ui.CatalogAddButton.IsEnabled = $count -gt 0
    $ui.CatalogClearButton.IsEnabled = $count -gt 0
}

function Clear-GuiCatalogSelection {
    if (-not $script:CatalogModels) { return }
    foreach ($m in $script:CatalogModels) { if ($m.Selected) { $m.Selected = $false } }
    Update-GuiCatalogCount
}

function Show-GuiCatalogTab {
    if (-not $script:CatalogModels -and (Test-Path -LiteralPath $script:CatalogFile)) { Import-GuiCatalog; return }
    Update-GuiCatalogInConfig
    Update-GuiCatalogView
}

function Add-GuiCatalogSelection {
    <#
    .SYNOPSIS
        Adds the ticked models and operating systems to the Models list. A model already in the
        configuration (same name or a shared system ID) gets the missing OS entries and system IDs.
    #>
    if ($null -eq $script:ModelRows) { throw 'The configuration is not loaded.' }
    $picked = @($script:CatalogModels | Where-Object { $_.Selected })
    if ($picked.Count -eq 0) { Show-GuiMessage -Text 'Tick at least one model first.' | Out-Null; return }

    [void]$ui.OsGrid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true)
    [void]$ui.ModelsGrid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true)
    $lookup = Get-GuiConfigLookup
    $newModels = 0
    $updatedModels = 0
    $newOs = 0
    foreach ($m in $picked) {
        $row = Find-GuiConfigModel -Lookup $lookup -Vendor $m.Vendor -Model $m.Model -SystemIds $m.SystemIdList
        $isNew = $null -eq $row
        $missingIds = @()
        if ($isNew) {
            $row = New-Object SDAGui.ModelRow
            $row.Vendor = $m.Vendor
            $row.Model = $m.Model
            $row.SystemIds = $m.SystemIds
            $row.Enabled = $true
        } else {
            $ids = @([string]$row.SystemIds -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() })
            $missingIds = @($m.SystemIdList | Where-Object { $ids -notcontains $_ })
            if ($missingIds.Count) { $row.SystemIds = (@($ids) + $missingIds) -join ', ' }
        }

        $configured = @{}
        foreach ($os in $row.OperatingSystems) { $configured[(ConvertTo-GuiOsKey $os.Name $os.Build $os.Architecture)] = $true }
        $added = 0
        foreach ($os in @($m.OperatingSystems | Where-Object { $_.Selected })) {
            $key = ConvertTo-GuiOsKey $os.Name $os.Build $os.Architecture
            if ($configured.ContainsKey($key)) { continue }
            $osRow = New-Object SDAGui.OsRow
            $osRow.Name = $os.Name
            $osRow.Build = $os.Build
            $osRow.Architecture = $os.Architecture
            $row.OperatingSystems.Add($osRow)
            $configured[$key] = $true
            $added++
        }
        $newOs += $added

        if ($isNew) {
            $script:ModelRows.Add($row)
            $newModels++
            $lookup.Names[(ConvertTo-GuiModelKey $row.Vendor $row.Model)] = $row
            foreach ($id in $m.SystemIdList) { $lookup.Ids[('{0}|{1}' -f $row.Vendor, $id).ToUpperInvariant()] = $row }
        } elseif ($added -or $missingIds.Count) {
            $updatedModels++
        }
    }

    Clear-GuiCatalogSelection
    try { $ui.ModelsGrid.Items.Refresh() } catch { }
    Update-GuiCatalogInConfig
    Update-GuiCatalogView

    if ($newModels -eq 0 -and $updatedModels -eq 0) {
        Show-GuiMessage -Text 'Everything you ticked is already in the configuration.' | Out-Null
        return
    }
    $summary = 'Added {0} new model(s) and {1} operating system entr{2}' -f $newModels, $newOs, $(if ($newOs -eq 1) { 'y' } else { 'ies' })
    if ($updatedModels) { $summary += " ($updatedModels existing model(s) updated)" }
    $answer = Show-GuiMessage -Icon Question -Buttons YesNo -Text ("$summary.`n`nSave the configuration now? The models then appear on the Models & versions tab as 'Not run yet', and the next run downloads their driver packs.`n`nChoose No to review them on the Models tab first.")
    if ($answer -eq 'Yes' -and (Save-GuiConfig)) {
        $ui.MainTabs.SelectedItem = $ui.StatusTab
        return
    }
    $ui.ConfigTabs.SelectedItem = $ui.ConfigModelsTab
    Set-GuiStatus "$summary. Review them on the Models tab, then click Save."
}
#endregion Add from vendor catalog

#region Logs and reports
function Update-LogFileList {
    param ([string]$Select)

    $folder = Get-GuiLogsFolder
    $current = if ($Select) { $Select } else { [string]$ui.LogFileCombo.SelectedItem }
    $files = @(if (Test-Path -LiteralPath $folder) {
            Get-ChildItem -LiteralPath $folder -Filter '*.log' -File | Sort-Object -Property LastWriteTime -Descending | ForEach-Object { $_.Name }
        })
    $script:SuppressEvents = $true
    try {
        $ui.LogFileCombo.ItemsSource = $files
        if ($current -and $files -contains $current) { $ui.LogFileCombo.SelectedItem = $current }
        elseif ($files -contains 'DriverAutomation.log') { $ui.LogFileCombo.SelectedItem = 'DriverAutomation.log' }
        elseif ($files) { $ui.LogFileCombo.SelectedIndex = 0 }
    } finally {
        $script:SuppressEvents = $false
    }
}

function Update-LogView {
    $name = [string]$ui.LogFileCombo.SelectedItem
    if (-not $name) { $ui.LogGrid.ItemsSource = $null; return }
    $text = Read-GuiFileTail -Path (Join-Path (Get-GuiLogsFolder) $name)

    $pattern = '(?s)<!\[LOG\[(?<msg>.*?)\]LOG\]!><time="(?<time>\d{1,2}:\d{2}:\d{2})[^"]*" date="(?<date>[^"]*)" component="(?<comp>[^"]*)" context="[^"]*" type="(?<type>\d)"'
    $filter = $ui.LogFilter.Text.Trim()
    $problemsOnly = [bool]$ui.LogProblemsOnly.IsChecked
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($match in [regex]::Matches($text, $pattern)) {
        $severity = switch ($match.Groups['type'].Value) { '3' { 'Error' } '2' { 'Warning' } default { 'Info' } }
        if ($problemsOnly -and $severity -eq 'Info') { continue }
        $message = $match.Groups['msg'].Value.Trim()
        $component = $match.Groups['comp'].Value
        if ($filter -and $message.IndexOf($filter, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -and
            $component.IndexOf($filter, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $dateParts = $match.Groups['date'].Value.Split('-')
        $date = if ($dateParts.Count -eq 3) { '{0}-{1}-{2}' -f $dateParts[2], $dateParts[0], $dateParts[1] } else { $match.Groups['date'].Value }
        $entries.Add([pscustomobject]@{ Time = "$date $($match.Groups['time'].Value)"; Severity = $severity; Component = $component; Message = $message })
    }
    $entries.Reverse()   # newest first
    $ui.LogGrid.ItemsSource = @($entries | Select-Object -First 5000)
}

function Find-GuiCMTrace {
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add((Join-Path $env:SystemRoot 'CCM\CMTrace.exe'))
    try {
        $siteInstall = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory'
        if ($siteInstall) { $candidates.Add((Join-Path $siteInstall 'tools\cmtrace.exe')) }
    } catch { }
    $candidates.Add((Join-Path $env:SystemRoot 'System32\CMTrace.exe'))
    foreach ($path in $candidates) { if (Test-Path -LiteralPath $path) { return $path } }
    return $null
}

function Open-GuiLogInCMTrace {
    $name = [string]$ui.LogFileCombo.SelectedItem
    if (-not $name) { return }
    $path = Join-Path (Get-GuiLogsFolder) $name
    $cmtrace = Find-GuiCMTrace
    if ($cmtrace) { Start-Process -FilePath $cmtrace -ArgumentList ('"{0}"' -f $path) }
    else { Invoke-Item -LiteralPath $path }
}

function Get-GuiReportsFolder {
    if ($script:Config) { return $script:Config.Paths.Reports }
    return (Join-Path (Get-GuiLogsFolder) 'Reports')
}

function Update-ReportList {
    $folder = Get-GuiReportsFolder
    $files = @(if (Test-Path -LiteralPath $folder) {
            Get-ChildItem -LiteralPath $folder -Filter 'Run-*.csv' -File | Sort-Object -Property LastWriteTime -Descending | ForEach-Object { $_.Name }
        })
    $ui.ReportList.ItemsSource = $files
    if ($files) { $ui.ReportList.SelectedIndex = 0 } else { $ui.ReportGrid.ItemsSource = $null }
}

function Show-GuiReport {
    $name = [string]$ui.ReportList.SelectedItem
    if (-not $name) { $ui.ReportGrid.ItemsSource = $null; return }
    $rows = @(Import-Csv -LiteralPath (Join-Path (Get-GuiReportsFolder) $name))
    # A DataTable binds reliably with auto-generated columns.
    $table = New-Object System.Data.DataTable
    if ($rows.Count) {
        $columns = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($column in $columns) { [void]$table.Columns.Add($column) }
        foreach ($r in $rows) {
            $dataRow = $table.NewRow()
            foreach ($column in $columns) { $dataRow[$column] = [string]$r.$column }
            $table.Rows.Add($dataRow)
        }
    }
    $ui.ReportGrid.ItemsSource = $table.DefaultView
}
#endregion Logs and reports

#region Window
$main = New-GuiWindow -Xaml $mainXaml
$script:Window = $main.Window
$ui = $main.Controls

$ui.HeaderConfig.Text = "Configuration: $($script:ConfigPath)"
$ui.RunAsText.Text = ("These run Invoke-DriverAutomation.ps1 as {0} and show the output below. Runs as SYSTEM are logged the same way." -f $script:Identity)
New-GuiSettingsForm

# Models & versions
$ui.RefreshStatusButton.add_Click({ Invoke-GuiSafely { Update-StatusView } })
$ui.TargetsGrid.add_SelectionChanged({ Invoke-GuiSafely { Update-TargetDetails } })
$ui.PromoteButton.add_Click({ Invoke-GuiSafely { Invoke-GuiPromote } })
$ui.RollbackButton.add_Click({ Invoke-GuiSafely { Invoke-GuiRollback } })
$ui.BlockButton.add_Click({ Invoke-GuiSafely { Invoke-GuiDeploymentState -Action Block } })
$ui.UnblockButton.add_Click({ Invoke-GuiSafely { Invoke-GuiDeploymentState -Action Unblock } })
$ui.HoldButton.add_Click({ Invoke-GuiSafely { Invoke-GuiDeploymentState -Action Hold } })
$ui.ReleaseButton.add_Click({ Invoke-GuiSafely { Invoke-GuiDeploymentState -Action Release } })

# Run
$ui.PreflightButton.add_Click({ Invoke-GuiSafely { Start-GuiRun -Mode Preflight } })
$ui.DryRunButton.add_Click({ Invoke-GuiSafely { Start-GuiRun -Mode DryRun } })
$ui.FullRunButton.add_Click({ Invoke-GuiSafely { Start-GuiRun -Mode Full } })
$ui.StartTaskButton.add_Click({ Invoke-GuiSafely { Start-GuiScheduledTask } })
$ui.RefreshTaskButton.add_Click({ Invoke-GuiSafely { Update-TaskView } })

# Configuration
$ui.SaveConfigButton.add_Click({ Invoke-GuiSafely { [void](Save-GuiConfig) } })
$ui.ValidateConfigButton.add_Click({ Invoke-GuiSafely { Show-GuiValidation } })
$ui.ReloadConfigButton.add_Click({
        Invoke-GuiSafely {
            if ((Test-GuiConfigDirty) -and (Show-GuiMessage -Icon Question -Buttons YesNo -Text 'Discard your unsaved changes and reload the file?') -ne 'Yes') { return }
            Import-GuiConfigFile
            Set-GuiStatus 'Configuration reloaded from disk.'
        }
    })
$ui.NotepadConfigButton.add_Click({
        Invoke-GuiSafely {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList ('"{0}"' -f $script:ConfigPath)
            Set-GuiStatus "After saving in Notepad, click 'Discard changes' here to reload the file."
        }
    })
$ui.AddModelButton.add_Click({ Invoke-GuiSafely { Add-GuiModel } })
$ui.BrowseCatalogButton.add_Click({ $ui.ConfigTabs.SelectedItem = $ui.CatalogTab })
$ui.ConfigTabs.add_SelectionChanged({
        param($sender, $e)
        if ($e.OriginalSource -ne $ui.ConfigTabs) { return }
        if ($ui.ConfigTabs.SelectedItem -eq $ui.CatalogTab) { Invoke-GuiSafely { Show-GuiCatalogTab } }
    })

# Add from vendor catalog
$ui.CatalogVendorFilter.ItemsSource = @('All', 'Dell', 'HP', 'Lenovo')
$ui.CatalogVendorFilter.SelectedIndex = 0
$ui.CatalogOsFilter.ItemsSource = @('Any', 'Windows 11', 'Windows 10')
$ui.CatalogOsFilter.SelectedIndex = 0
$ui.CatalogBuildFilter.ItemsSource = @('Any')
$ui.CatalogBuildFilter.SelectedIndex = 0
$ui.CatalogAgeFilter.ItemsSource = @($script:CatalogAges.Keys)
$ui.CatalogAgeFilter.SelectedItem = 'Last 2 years'
$ui.CatalogScanButton.add_Click({ Invoke-GuiSafely { Start-GuiCatalogScan } })
$ui.CatalogAddButton.add_Click({ Invoke-GuiSafely { Add-GuiCatalogSelection } })
$ui.CatalogClearButton.add_Click({ Invoke-GuiSafely { Clear-GuiCatalogSelection; Update-GuiCatalogView } })
$ui.CatalogSearch.add_TextChanged({ Invoke-GuiSafely { Update-GuiCatalogView } })
foreach ($name in @('CatalogVendorFilter', 'CatalogOsFilter', 'CatalogBuildFilter', 'CatalogAgeFilter')) {
    $ui[$name].add_SelectionChanged({ if (-not $script:SuppressEvents) { Invoke-GuiSafely { Update-GuiCatalogPreference; Update-GuiCatalogView } } })
}
foreach ($name in @('CatalogHideConfigured', 'CatalogSelectedOnly')) {
    $ui[$name].add_Click({ Invoke-GuiSafely { Update-GuiCatalogView } })
}
$ui.RemoveModelButton.add_Click({ Invoke-GuiSafely { Remove-GuiModel } })
$ui.AddOsButton.add_Click({
        Invoke-GuiSafely {
            $modelRow = $ui.ModelsGrid.SelectedItem
            if (-not $modelRow) { Show-GuiMessage -Text 'Select a model first.' | Out-Null; return }
            $modelRow.OperatingSystems.Add((New-Object SDAGui.OsRow))
        }
    })
$ui.RemoveOsButton.add_Click({
        Invoke-GuiSafely {
            $modelRow = $ui.ModelsGrid.SelectedItem
            $osRow = $ui.OsGrid.SelectedItem
            if ($modelRow -and $osRow -is [SDAGui.OsRow]) {
                [void]$ui.OsGrid.CancelEdit()
                [void]$modelRow.OperatingSystems.Remove($osRow)
            }
        }
    })

# Logs and reports
$ui.LogFileCombo.add_SelectionChanged({ if (-not $script:SuppressEvents) { Invoke-GuiSafely { Update-LogView } } })
$ui.LogFilter.add_TextChanged({ Invoke-GuiSafely { Update-LogView } })
$ui.LogProblemsOnly.add_Click({ Invoke-GuiSafely { Update-LogView } })
$ui.LogRefreshButton.add_Click({ Invoke-GuiSafely { Update-LogFileList; Update-LogView } })
$ui.LogCMTraceButton.add_Click({ Invoke-GuiSafely { Open-GuiLogInCMTrace } })
$ui.LogFolderButton.add_Click({
        Invoke-GuiSafely {
            $folder = Get-GuiLogsFolder
            if (-not (Test-Path -LiteralPath $folder)) { throw "The log folder $folder does not exist yet." }
            Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"{0}"' -f $folder)
        }
    })
$ui.ReportRefreshButton.add_Click({ Invoke-GuiSafely { Update-ReportList } })
$ui.ReportList.add_SelectionChanged({ Invoke-GuiSafely { Show-GuiReport } })

$ui.MainTabs.add_SelectionChanged({
        param($sender, $e)
        # SelectionChanged bubbles up from the grids and combo boxes inside the tabs; only react to tab changes.
        if ($e.OriginalSource -ne $ui.MainTabs) { return }
        Invoke-GuiSafely {
            if ($ui.MainTabs.SelectedItem -eq $ui.LogsTab) { Update-LogFileList; Update-LogView }
            elseif ($ui.MainTabs.SelectedItem -eq $ui.ReportsTab) { Update-ReportList }
            elseif ($ui.MainTabs.SelectedItem -eq $ui.RunTab) { Update-TaskView }
            elseif ($ui.MainTabs.SelectedItem -eq $ui.ConfigTab -and $ui.ConfigTabs.SelectedItem -eq $ui.CatalogTab) { Show-GuiCatalogTab }
        }
    })

# Output panel
$ui.CancelJobButton.add_Click({ Invoke-GuiSafely { Stop-GuiJob } })
$ui.ClearOutputButton.add_Click({ $ui.OutputBox.Clear() })

# Polls the running script's output, and refreshes the log view when auto-refresh is on.
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.add_Tick({
        try {
            if ($script:Job) {
                Receive-GuiJobOutput
                if ($script:Job.Process.HasExited) { Complete-GuiJob }
            }
            if ($ui.MainTabs.SelectedItem -eq $ui.ConfigTab -and $ui.ConfigTabs.SelectedItem -eq $ui.CatalogTab) { Update-GuiCatalogCount }
            $script:TickCount++
            if ($script:TickCount % 10 -eq 0) {
                if ($ui.LogAutoRefresh.IsChecked -and $ui.MainTabs.SelectedItem -eq $ui.LogsTab) { Update-LogView }
                if ($script:TickCount % 60 -eq 0) { Update-TaskView }
            }
        } catch {
            Set-GuiStatus "Background refresh failed: $($_.Exception.Message)"
        }
    })

$script:Window.add_Loaded({
        Invoke-GuiSafely { Import-GuiConfigFile }
        Invoke-GuiSafely { Update-StatusView }
        Invoke-GuiSafely { Update-TaskView }
        Update-GuiBusyState
        $timer.Start()
    })

$script:Window.add_Closing({
        param($sender, $e)
        try {
            if (Test-GuiConfigDirty) {
                $answer = Show-GuiMessage -Icon Question -Buttons YesNoCancel -Text 'Save your changes to the configuration before closing?'
                if ($answer -eq 'Cancel') { $e.Cancel = $true; return }
                if ($answer -eq 'Yes' -and -not (Save-GuiConfig)) { $e.Cancel = $true; return }
            }
            if ($script:Job) {
                Show-GuiMessage -Icon Information -Text ("'{0}' is still running and will finish in the background.`n`nIts output is in {1}" -f $script:Job.Title, $script:Job.OutFile) | Out-Null
            }
        } catch { }
        $timer.Stop()
    })

try {
    [void]$script:Window.ShowDialog()
} catch {
    [System.Windows.MessageBox]::Show("The GUI stopped unexpectedly:`n`n$($_.Exception.Message)", 'SCCM Driver Automation', 'OK', 'Error') | Out-Null
}
#endregion Window
