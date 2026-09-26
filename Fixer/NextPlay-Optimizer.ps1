$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
if (-not $isAdmin -or -not $isSta) {
    $self = $MyInvocation.MyCommand.Path
    if (-not $self) { $self = $PSCommandPath }
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $self)
    if (-not $isAdmin) {
        Start-Process -FilePath $ps -ArgumentList $arg -Verb RunAs
    } else {
        Start-Process -FilePath $ps -ArgumentList $arg
    }
    exit 0
}

$ErrorActionPreference = 'Continue'
$script:defaultOpen = $false

function Get-CafeRelease {
    $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = 0
    [void][int]::TryParse([string]$cv.CurrentBuildNumber, [ref]$build)
    $ubr = 0
    if ($null -ne $cv.UBR) { $ubr = [int]$cv.UBR }
    $display = ''
    if ($cv.DisplayVersion) { $display = [string]$cv.DisplayVersion }
    $product = [string]$cv.ProductName
    $profile = 'unsupported'
    $note = ''
    $known = $false
    if ($product -like '*Windows 11*' -and $build -ge 22631) {
        switch ($display) {
            '23H2' { $profile = '23H2'; $known = $true }
            '24H2' { $profile = '24H2'; $known = $true }
            '25H2' { $profile = '25H2'; $known = $true }
            '26H1' { $profile = '26H1'; $known = $true }
            '26H2' {
                $profile = '25H2'
                $known = $true
                $note = '26H2 etiketi. Germanium hatti, 25H2 politikalari uygulanir.'
            }
        }
        if (-not $known) {
            if ($build -ge 28000) { $profile = '26H1' }
            elseif ($build -ge 26200) { $profile = '25H2' }
            elseif ($build -ge 26100) { $profile = '24H2' }
            else { $profile = '23H2' }
            $note = 'Surum etiketinden secilemedi. Yapi numarasina gore profil: ' + $profile
        }
    }
    return @{
        Product = $product
        Display = $display
        Build   = $build
        Ubr     = $ubr
        Profile = $profile
        Note    = $note
    }
}

function Format-Release($Rel) {
    $ver = $Rel.Display
    if (-not $ver) { $ver = 'etiket yok' }
    return $Rel.Product + '   ' + $ver + '   ' + [string]$Rel.Build + '.' + [string]$Rel.Ubr
}

function Add-Log([string]$Text) {
    $script:logBox.AppendText($Text + "`r`n")
    $script:logBox.SelectionStart = $script:logBox.TextLength
    $script:logBox.ScrollToCaret()
    [Windows.Forms.Application]::DoEvents()
}

function Set-RegDword([string]$Key, [string]$Name, [int]$Value) {
    & reg.exe add $Key /v $Name /t REG_DWORD /d "$Value" /f | Out-Null
    if ($LASTEXITCODE -ne 0) { Add-Log ('Yazilamadi: ' + $Name) }
}

function Set-RegSz([string]$Key, [string]$Name, [string]$Value) {
    & reg.exe add $Key /v $Name /t REG_SZ /d $Value /f | Out-Null
    if ($LASTEXITCODE -ne 0) { Add-Log ('Yazilamadi: ' + $Name) }
}

function Set-UserDword([string]$Sub, [string]$Name, [int]$Value) {
    & reg.exe add ("HKCU\" + $Sub) /v $Name /t REG_DWORD /d "$Value" /f | Out-Null
    if ($script:defaultOpen) {
        & reg.exe add ("HKU\NLDefault\" + $Sub) /v $Name /t REG_DWORD /d "$Value" /f | Out-Null
    }
}

function Open-DefaultUser {
    $script:defaultOpen = $false
    $dat = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $dat)) {
        Add-Log 'Varsayilan kullanici dosyasi yok. Yalnizca bu oturum yazilacak.'
        return
    }
    & reg.exe unload HKU\NLDefault 2>&1 | Out-Null
    & reg.exe load HKU\NLDefault $dat 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $script:defaultOpen = $true
        Add-Log 'Yeni hesaplara da yazilacak.'
    } else {
        Add-Log 'Varsayilan kullanici acilamadi. Yalnizca bu oturum yazildi.'
    }
}

function Close-DefaultUser {
    if (-not $script:defaultOpen) { return }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    & reg.exe unload HKU\NLDefault 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Add-Log 'Varsayilan kullanici kapatilamadi. Oturumu kapat, sonra betigi yeniden calistir.' }
    $script:defaultOpen = $false
}

function Set-Svc([string]$Name, [string]$Start) {
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Log ($Name + ' yok')
        return
    }
    if ($Start -eq 'disabled') {
        & sc.exe config $Name start= disabled 2>&1 | Out-Null
        $code = $LASTEXITCODE
        & sc.exe stop $Name 2>&1 | Out-Null
    } else {
        & sc.exe config $Name start= demand 2>&1 | Out-Null
        $code = $LASTEXITCODE
        if ($Name -eq 'WSearch') { & sc.exe stop $Name 2>&1 | Out-Null }
    }
    if ($code -eq 0) { Add-Log ($Name + ' -> ' + $Start) }
    else { Add-Log ($Name + ' ayarlanamadi') }
}

function Set-AcValue([string]$Scheme, [string]$Sub, [string]$Setting) {
    & powercfg.exe /setacvalueindex $Scheme $Sub $Setting 0 | Out-Null
    if ($LASTEXITCODE -ne 0) { Add-Log ('Guc ayari atlandi: ' + $Setting) }
}

function Set-CafePower {
    Add-Log 'Guc'
    & powercfg.exe -h off | Out-Null
    if ($LASTEXITCODE -eq 0) { Add-Log 'Hazirda bekletme kapali' }
    else { Add-Log 'Hazirda bekletme kapatilamadi' }
    $active = & powercfg.exe /getactivescheme
    $guid = ''
    if ($active -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $guid = $Matches[1]
    }
    if (-not $guid) {
        Add-Log 'Aktif guc plani okunamadi'
        return
    }
    Set-AcValue $guid 'SUB_SLEEP' 'STANDBYIDLE'
    Set-AcValue $guid 'SUB_SLEEP' 'HIBERNATEIDLE'
    Set-AcValue $guid 'SUB_USB' 'USBSELECTIVESUSPEND'
    Set-AcValue $guid 'SUB_PCIEXPRESS' 'ASPM'
    Set-AcValue $guid 'SUB_DISK' 'DISKIDLE'
    & powercfg.exe /setactive $guid | Out-Null
    Add-Log 'Aktif planda uyku, USB ve PCIe tasarrufu kapali'
}

function Set-CafeServices {
    Add-Log 'Servisler'
    Set-Svc 'SysMain' 'disabled'
    Set-Svc 'defragsvc' 'disabled'
    Set-Svc 'sdrsvc' 'disabled'
    Set-Svc 'CscService' 'disabled'
    Set-Svc 'WSearch' 'demand'
    Set-Svc 'wuauserv' 'disabled'
    Set-Svc 'UsoSvc' 'disabled'
    Set-Svc 'WaaSMedicSvc' 'disabled'
    Set-Svc 'DiagTrack' 'disabled'
    Set-Svc 'diagsvc' 'disabled'
    Set-Svc 'diagnosticshub.standardcollector.service' 'disabled'
    Set-Svc 'dmwappushservice' 'disabled'
    Set-Svc 'RemoteRegistry' 'disabled'
    Set-Svc 'PcaSvc' 'disabled'
}

function Disable-CafeTasks {
    $names = @(
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        '\Microsoft\Windows\Application Experience\PcaPatchDbTask',
        '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        '\Microsoft\Windows\Application Experience\StartupAppTask',
        '\Microsoft\Windows\Application Experience\MareBackup',
        '\Microsoft\Windows\Autochk\Proxy',
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask',
        '\Microsoft\Windows\Defrag\ScheduledDefrag',
        '\Microsoft\Windows\Diagnosis\Scheduled',
        '\Microsoft\Windows\Diagnosis\RecommendedTroubleshootingScanner',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticResolver',
        '\Microsoft\Windows\DiskFootprint\Diagnostics',
        '\Microsoft\Windows\Feedback\Siuf\DmClient',
        '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
        '\Microsoft\Windows\Flighting\FeatureConfig\ReconcileFeatures',
        '\Microsoft\Windows\Flighting\FeatureConfig\UsageDataFlushing',
        '\Microsoft\Windows\Flighting\FeatureConfig\UsageDataReporting',
        '\Microsoft\Windows\Flighting\OneSettings\RefreshCache',
        '\Microsoft\Windows\Maps\MapsUpdateTask',
        '\Microsoft\Windows\Maps\MapsToastTask',
        '\Microsoft\Windows\Windows Error Reporting\QueueReporting',
        '\Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan',
        '\Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance',
        '\Microsoft\Windows\Windows Defender\Windows Defender Cleanup',
        '\Microsoft\Windows\Windows Defender\Windows Defender Verification',
        '\Microsoft\Windows\Windows Defender\MpIdleTask',
        '\Microsoft\Windows Defender\MP Scheduled Scan',
        '\Microsoft\Windows\CloudExperienceHost\CreateObjectTask',
        '\Microsoft\Windows\PI\Sqm-Tasks',
        '\Microsoft\Windows\NetTrace\GatherNetworkInfo',
        '\Microsoft\Windows\Sysmain\ResPriStaticDbSync',
        '\Microsoft\Windows\Sysmain\WsSwapAssessmentTask',
        '\Microsoft\Windows\WDI\ResolutionHost',
        '\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem',
        '\Microsoft\Windows\MemoryDiagnostic\ProcessMemoryDiagnosticEvents',
        '\Microsoft\Windows\MemoryDiagnostic\RunFullMemoryDiagnostic',
        '\Microsoft\Windows\SystemRestore\SR',
        '\Microsoft\Windows\Registry\RegIdleBackup',
        '\Microsoft\Windows\Maintenance\WinSAT',
        '\Microsoft\Windows\WindowsUpdate\Scheduled Start',
        '\Microsoft\Windows\UpdateOrchestrator\Schedule Scan',
        '\Microsoft\Windows\UpdateOrchestrator\Reboot',
        '\Microsoft\Windows\InstallService\ScanForUpdates',
        '\Microsoft\Windows\InstallService\ScanForUpdatesAsUser',
        '\Microsoft\Windows\InstallService\WakeUpAndScanForUpdates',
        '\Microsoft\Windows\InstallService\WakeUpAndContinueUpdates'
    )
    $ok = 0
    $miss = 0
    foreach ($name in $names) {
        & schtasks.exe /Change /TN $name /DISABLE 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok = $ok + 1 } else { $miss = $miss + 1 }
    }
    Add-Log ('Gorev: ' + [string]$ok + ' kapatildi, ' + [string]$miss + ' bu surumde yok')
}

function Set-CafeUser {
    Set-UserDword 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
    Set-UserDword 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 0
    Set-UserDword 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0
    Set-UserDword 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
    Set-UserDword 'Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
    Set-UserDword 'Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Set-UserDword 'System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-UserDword 'Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Set-UserDword 'Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    $cdm = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $flags = @(
        'SubscribedContent-338389Enabled',
        'SubscribedContent-310093Enabled',
        'SubscribedContent-338388Enabled',
        'SubscribedContent-353694Enabled',
        'SubscribedContent-353696Enabled',
        'SilentInstalledAppsEnabled',
        'SystemPaneSuggestionsEnabled'
    )
    foreach ($flag in $flags) { Set-UserDword $cdm $flag 0 }
}

function Clear-LegacyPolicies {
    Add-Log 'Eski policy'
    $keys = @(
        'HKLM\SOFTWARE\Policies',
        'HKCU\SOFTWARE\Policies',
        'HKLM\SOFTWARE\WOW6432Node\Policies',
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies',
        'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies'
    )
    foreach ($key in $keys) {
        & reg.exe delete $key /f 2>&1 | Out-Null
    }
    if ($script:defaultOpen) {
        & reg.exe delete 'HKU\NLDefault\Software\Policies' /f 2>&1 | Out-Null
        & reg.exe delete 'HKU\NLDefault\Software\Microsoft\Windows\CurrentVersion\Policies' /f 2>&1 | Out-Null
    }
    & reg.exe delete 'HKLM\SOFTWARE\Microsoft\Windows Defender' /v DisableAntiSpyware /f 2>&1 | Out-Null
    Add-Log 'Eski policy silindi. Bu betigin politikalari ardindan yazilir.'
}

function Set-DeviceReadyOff {
    Add-Log 'Cihaz hazir ekrani'
    Set-RegSz 'HKLM\SYSTEM\Setup' 'RespecializeCmdLine' ''
    $spp = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\Sysprep\Settings\sppnp'
    Set-RegDword $spp 'DoNotCleanUpNonPresentDevices' 1
    Set-RegDword $spp 'PersistAllDeviceInstalls' 1
}

function Set-BootExecuteEmpty {
    Add-Log 'Acilis disk taramasi'
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    New-ItemProperty -Path $path -Name 'BootExecute' -PropertyType MultiString -Value ([string[]]@()) -Force | Out-Null
    Add-Log 'BootExecute bos'
}

function Set-PhotoViewer {
    Add-Log 'Fotograf goruntuleyici'
    $key = 'HKLM\SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations'
    foreach ($ext in @('.tif', '.tiff', '.png', '.bmp', '.jpeg', '.jpg', '.ico')) {
        Set-RegSz $key $ext 'PhotoViewer.FileAssoc.Tiff'
    }
}

function Invoke-BaseProfile {
    Clear-LegacyPolicies
    Set-CafePower
    & bcdedit.exe /deletevalue '{current}' nx 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Add-Log 'DEP zorlamasi kaldirildi' }
    else { Add-Log 'DEP zaten varsayilan' }
    & fsutil.exe behavior set disablelastaccess 1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Add-Log 'NTFS son erisim damgasi kapali' }
    else { Add-Log 'NTFS damgasi ayarlanamadi' }
    Set-DeviceReadyOff
    Set-BootExecuteEmpty
    Set-PhotoViewer

    Add-Log 'Makine ayarlari'
    Set-RegDword 'HKLM\SYSTEM\CurrentControlSet\Control\CrashControl' 'CrashDumpEnabled' 3
    Set-RegDword 'HKLM\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' 0
    Set-RegDword 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'PlatformAoAcOverride' 0
    Set-RegDword 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'AITEnable' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableInventory' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisablePCA' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableUAR' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'HideRecommendedSection' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
    Set-RegDword 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableCocreator' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableGenerativeFill' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableImageCreator' 1

    $mm = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    & reg.exe add $mm /v NetworkThrottlingIndex /t REG_DWORD /d 0xffffffff /f | Out-Null
    Set-RegDword $mm 'SystemResponsiveness' 1
    Set-RegDword $mm 'NoLazyMode' 1
    Set-RegDword $mm 'AlwaysOn' 1
    $games = $mm + '\Tasks\Games'
    Set-RegDword $games 'GPU Priority' 8
    Set-RegDword $games 'Priority' 6
    Set-RegSz $games 'Scheduling Category' 'High'
    Set-RegSz $games 'SFIO Priority' 'High'
    $low = $mm + '\Tasks\Low Latency'
    Set-RegDword $low 'GPU Priority' 0
    Set-RegDword $low 'Priority' 8
    Set-RegSz $low 'Scheduling Category' 'Medium'
    Set-RegSz $low 'SFIO Priority' 'High'
    Set-RegDword 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows Media Foundation' 'EnableFrameServerMode' 0

    Set-CafeServices
    Disable-CafeTasks
    Add-Log 'Oturum ve yeni hesap'
    Set-CafeUser
    Add-Log 'Ortak profil bitti'
}

function Invoke-Profile24H2 {
    Add-Log '24H2 eki: Recall ve Click to Do'
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableSettingsAgent' 1
}

function Invoke-Profile25H2 {
    Add-Log '25H2 eki: ayri anahtar yok. Click to Do bu surumde varsayilan acik, 24H2 politikalari gecerli.'
}

function Invoke-Profile26H1 {
    Add-Log '26H1 eki: ozellikler 25H2 ile ayni. Ayri politika yok.'
}

function Invoke-CafeOptimize($Rel) {
    Open-DefaultUser
    Add-Log ('Profil ' + $Rel.Profile)
    Invoke-BaseProfile
    if ($Rel.Profile -eq '24H2' -or $Rel.Profile -eq '25H2' -or $Rel.Profile -eq '26H1') {
        Invoke-Profile24H2
    }
    if ($Rel.Profile -eq '25H2' -or $Rel.Profile -eq '26H1') {
        Invoke-Profile25H2
    }
    if ($Rel.Profile -eq '26H1') {
        Invoke-Profile26H1
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$script:release = Get-CafeRelease

$form = New-Object Windows.Forms.Form
$form.Text = 'NextPlay Optimizer'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object Drawing.Size(640, 560)
$form.BackColor = [Drawing.Color]::FromArgb(22, 24, 28)
$form.Font = New-Object Drawing.Font('Segoe UI', 10)

$version = New-Object Windows.Forms.Label
$version.SetBounds(16, 12, 608, 78)
$version.ForeColor = [Drawing.Color]::FromArgb(236, 232, 220)
$version.BackColor = $form.BackColor

$btn = New-Object Windows.Forms.Button
$btn.SetBounds(16, 96, 608, 44)
$btn.FlatStyle = 'Flat'
$btn.FlatAppearance.BorderSize = 0
$btn.BackColor = [Drawing.Color]::FromArgb(245, 185, 66)
$btn.ForeColor = [Drawing.Color]::FromArgb(28, 20, 6)
$btn.Text = 'Uygula'

$script:logBox = New-Object Windows.Forms.TextBox
$script:logBox.SetBounds(16, 152, 608, 348)
$script:logBox.Multiline = $true
$script:logBox.ReadOnly = $true
$script:logBox.ScrollBars = 'Vertical'
$script:logBox.BackColor = [Drawing.Color]::FromArgb(12, 14, 18)
$script:logBox.ForeColor = [Drawing.Color]::FromArgb(210, 214, 220)
$script:logBox.BorderStyle = 'None'
$script:logBox.Font = New-Object Drawing.Font('Consolas', 9)
$script:logBox.WordWrap = $false

$script:status = New-Object Windows.Forms.Label
$script:status.SetBounds(0, 512, 640, 48)
$script:status.ForeColor = [Drawing.Color]::FromArgb(220, 224, 230)
$script:status.BackColor = [Drawing.Color]::FromArgb(32, 36, 42)
$script:status.TextAlign = 'MiddleLeft'
$script:status.Padding = New-Object Windows.Forms.Padding(16, 0, 12, 0)

$head = Format-Release $script:release
if ($script:release.Profile -eq 'unsupported') {
    $version.ForeColor = [Drawing.Color]::FromArgb(255, 150, 130)
    $version.Text = "Desteklenmiyor`r`n" + $head + "`r`nYalnizca Windows 11 23H2 ve uzeri."
    $btn.Enabled = $false
    $script:status.Text = 'Windows 10 ve 23H2 alti calismaz.'
    $script:logBox.Text = "Bu betik 23H2, 24H2, 25H2 ve 26H1 icindir.`r`n"
} else {
    $version.Text = $head + "`r`nProfil: " + $script:release.Profile
    if ($script:release.Note) { $version.Text = $version.Text + "`r`n" + $script:release.Note }
    $script:status.Text = 'Surum algilandi. Uygula ile baslar.'
    $script:logBox.Text = "Surum sorulmaz. Pencere acilinca okundu.`r`n"
}

$form.Controls.Add($version)
$form.Controls.Add($btn)
$form.Controls.Add($script:logBox)
$form.Controls.Add($script:status)
$script:applyBtn = $btn
$script:mainForm = $form

$script:applyBtn.Add_Click({
    $script:applyBtn.Enabled = $false
    $script:mainForm.Cursor = [Windows.Forms.Cursors]::WaitCursor
    $script:status.Text = 'Uygulaniyor...'
    try {
        Invoke-CafeOptimize $script:release
        Add-Log ''
        Add-Log 'Bitti. GPU zamanlamasi ve gorev cubugu icin yeniden baslat.'
        $script:status.Text = 'Tamamlandi. Yeniden baslat.'
    } catch {
        Add-Log ('Hata: ' + $_.Exception.Message)
        $script:status.Text = 'Hata.'
    } finally {
        Close-DefaultUser
        $script:mainForm.Cursor = [Windows.Forms.Cursors]::Default
        if ($script:release.Profile -ne 'unsupported') { $script:applyBtn.Enabled = $true }
    }
})

[void]$form.ShowDialog()
