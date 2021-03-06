<#
Скрипт для проверки состояния серверов.
Версия: 0.11
Автор: Любимов Роман
  
Параметры:
  serversFile - файл со списком серверов
  reportFile - файл с результатами выполнения
#>

Param (
	[string] $serversFile,
	[string] $reportFile
)

# Название свойства, определяющего подсветку строки в таблице
$danger = 'Danger'

# Файлы HTML-шаблонов
$templateTableFile = "$PSScriptRoot\Template_Table.html"
$templateGroupFile = "$PSScriptRoot\Template_Group.html"
$templateMainFile = "$PSScriptRoot\Template_Main.html"

#
# Функции для сбора данных
#

<#
Проверка свободного пространства на локальных дисках сервера.
Если свободное пространство - 10 ГБ и менее, то свойство $danger = $true.
Параметры:
  serverName - имя сервера
  minFreeSpace - минимальное свободное пространство в байтах
#>
function Get-DiskFreeSpace {
	Param(
		[String]$serverName,
		[String]$minFreeSpace
	)
	
	gwmi Win32_LogicalDisk -ComputerName $serverName -Filter "DriveType=3" |
		select Name, `
			@{Name = 'SizeGB'; Exp = {[Math]::Round($_.Size / 1GB, 2)}}, `
			@{Name = 'FreeSpaceGB'; Exp = {[Math]::Round($_.FreeSpace / 1GB, 2)}}, `
			@{Name = $danger; Exp = {$_.FreeSpace -lt $minFreeSpace}} |
		sort Name
}

<#
Проверка необходимости перезагрузки после установки обновлений средствами SCCM.
Если перезагрузка требуется, то свойство $danger = $true.
Параметры:
  serverName - имя сервера
#>
function Get-RebootPending {
	Param([String]$serverName)
	
	iwmi -ComputerName $serverName -Namespace "ROOT\ccm\ClientSDK" -Class CCM_ClientUtilities -Name DetermineIfRebootPending |
		select RebootPending, @{Name =$danger; Exp = {$_.RebootPending}}
}

<#
Проверка состояния сервисов.
Если тип запуска Auto и состояние отличается от Running, то свойство $danger = $true.
Параметры:
  serverName - имя сервера
  serviceName - имя (или начало имени) сервиса
#>
function Get-ServicesState {
	Param(
		[String]$serverName,
		[String]$serviceName
	)
	
	gwmi Win32_Service -ComputerName $serverName -Filter "DisplayName like '$serviceName%'" |
		select DisplayName, StartMode, State, @{Name = $danger; Exp = {$_.StartMode -eq 'Auto' -and $_.State -ne 'Running'}} |
		sort StartMode, DisplayName
}

<#
Проверка размера файла.
Если размер файла больше заданного, то свойство $danger = $true.
Параметры:
  filePath - путь к файлу (поддерживаются UNC-пути)
  maxSize - предельный размер файла в байтах
#>
function Get-FileSize {
	param(
		[String]$filePath,
		[String]$maxSize
	)
	
	Get-Item $filePath | select Name, @{Name = "LengthGB"; Exp = {[Math]::Round($_.Length / 1GB, 2)}}, @{Name = $danger; Exp = {$_.Length -gt $maxSize}}
}

<#
Проверка текущих алертов vCenter.
Параметры:
  serverName - имя сервера
#>
function Get-vCenterAlerts {
	Param([String]$serverName)
	
	$vcenterAlarms = @()

	Connect-VIServer -Server $serverName | Out-Null
	
	foreach ($dc in Get-Datacenter) {
		foreach ($ta in $dc.ExtensionData.TriggeredAlarmState) {
			$vcenterAlarms += "" | select @{Name = 'Datacenter'; Exp = {$dc.Name}}, `
				@{Name = 'Alarm'; Exp = {(Get-View $ta.Alarm).Info.Name}}, `
				@{Name = 'Object'; Exp = {(Get-View $ta.Entity).Name}}, `
				@{Name = 'Time'; Exp = {$ta.Time}}, `
				@{Name = 'Acknowledged'; Exp = {$ta.Acknowledged}}, `
				@{Name = 'AcknowledgedByUser'; Exp = {$ta.AcknowledgedByUser}}
		}
	}

	Disconnect-VIServer -Force -Confirm:$false | Out-Null
	
	$vcenterAlarms
}

#
# Функции для формирования HTML
#

<#
Возвращает HTML-таблицу.
Если у объекта свойство $danger = $true, то соответствующей строке таблицы присваивается CSS-класс 'danger'.
Параметры:
  objects - массив объектов, содержащий данные для таблицы
  properties - свойства, которые будут отображены в таблице
#>
function Make-HtmlTable {
	Param([Object[]]$objects,
		[String[]]$properties)
	
	"<table class=""table""><thead><tr>"
	$properties | % { "<th>$_</th>" }
	"</tr></thead><tbody>"
	foreach ($object in $objects) {
		"<tr class=""$(if ($object.Danger) {'danger'})"">"
		foreach ($property in $properties) {
			"<td>$($object.$property)</td>"
		}
		"</tr>"
	}
	"</tbody></table>"
}

<#
Возвращает HTML на основе шаблона.
Параметры:
  file - путь к файлу шаблона
  title - заголовок
  content - содержимое (HTML)
  date - дата
  group - идентификатор группы (для раскрывающейся области, должен быть уникальным)
#>
function Make-HtmlByTemplate {
	Param([string]$file,
		[string]$title,
		[string[]]$content,
		[string]$date,
		[string]$group)
	
	(Get-Content $file) -replace '_TITLE_', $title -replace '_CONTENT_', $content -replace '_DATE_', $date -replace '_GROUP_', $group
}

#
# Основная часть скрипта
#

clear

Set-PowerCLIConfiguration -InvalidCertificateAction:Ignore -DefaultVIServerMode:Single -Confirm:$false -Scope:Session | Out-Null

$date = Get-Date -format "dd.MM.yyyy HH:mm:ss"

$servers = Import-Csv $serversFile

$html = ""

$servers | % {
	$htmlTables = ""
	
	# Проверки для windows-серверов
	if ($_.Roles.Contains('windows')) {
		# Свободное место на локальных дисках
		$diskFreeSpace = Get-DiskFreeSpace -serverName $_.Name -minFreeSpace 10GB
		
		$htmlTables += Make-HtmlByTemplate -file $templateTableFile -title 'Свободное пространство на дисках' `
			-content (Make-HtmlTable -objects $diskFreeSpace -properties 'Name', 'SizeGB', 'FreeSpaceGB')
		
		# Необходимость перезагрузки
		$rebootPending = Get-RebootPending -serverName $_.Name
		
		$htmlTables += Make-HtmlByTemplate -file $templateTableFile -title 'Необходимость перезагрузки' `
			-content (Make-HtmlTable -objects $rebootPending -properties 'RebootPending')
		
		# Сервисы VMware
		if ($_.Roles.Contains('vmware_services')) {
			$vmwareServices = Get-ServicesState -serverName $_.Name -serviceName "VMware"
			
			$htmlTables += Make-HtmlByTemplate -file $templateTableFile -title 'Состояние сервисов VMware' `
				-content (Make-HtmlTable -objects $vmwareServices -properties 'DisplayName', 'StartMode', 'State')
		}
		
		# Сервисы MS SQL
		if ($_.Roles.Contains('mssql_services')) {
			$mssqlServices = Get-ServicesState -serverName $_.Name -serviceName "SQL"
			
			$htmlTables += Make-HtmlByTemplate -file $templateTableFile -title 'Состояние сервисов MS SQL' `
				-content (Make-HtmlTable -objects $mssqlServices -properties 'DisplayName', 'StartMode', 'State')
		}
		
		# Сервисы MS TMG
		if ($_.Roles.Contains('mstmg_services')) {
			$mstmgServices = Get-ServicesState -serverName $_.Name -serviceName "Microsoft Forefront TMG"
			
			$htmlTables += Make-HtmlByTemplate -file $templateTableFile -title 'Состояние сервисов MS TMG' `
				-content (Make-HtmlTable -objects $mstmgServices -properties 'DisplayName', 'StartMode', 'State')
		}
		
		# Сервисы SurfCop
		if ($_.Roles.Contains('surfcop_services')) {
			$surfcopServices = Get-ServicesState -serverName $_.Name -serviceName "Surfcop"
			
			$htmlTables += Make-HtmlByTemplate -file $templateTableFile -title 'Состояние сервисов SurfCop' `
				-content (Make-HtmlTable -objects $surfcopServices -properties 'DisplayName', 'StartMode', 'State')
		}
		
		# Размер локальной БД Proxy Inspector
		if ($_.Roles.Contains('pi_local_db')) {
			$piDBFilePath = "\\" + $_.Name + "\c$\ProgramData\ADVSoft\PI3Ent\db\pi3.dbtraffic"
			$piDB = Get-FileSize -filePath $piDBFilePath -maxSize 5GB
			
			$htmlTables += Make-HtmlByTemplate -file $templateTableFile -title 'Размер локальной БД Proxy Inspector' `
				-content (Make-HtmlTable -objects $piDB -properties 'Name', 'LengthGB')
		}
	}
	
	# Проверки для серверов VMware vCenter
	if ($_.Roles.Contains('vcenter_alerts')) {
		# Алерты vCenter
		$vcenterAlerts = Get-vCenterAlerts -serverName $_.Name
		
		$htmlTables += Make-HtmlByTemplate -file $templateTableFile -title 'Алерты vCenter' `
			-content (Make-HtmlTable -objects $vcenterAlerts `
			-properties 'Datacenter', 'Alarm', 'Object', 'Time', 'Acknowledged', 'AcknowledgedByUser')
	}
	
	# HTML для раскрывающейся области
	$html += Make-HtmlByTemplate -file $templateGroupFile -title ($_.Location + " " + $_.Description + " " + $_.Name) `
		-content $htmlTables -group $_.Name
}

# Формирование HTML-файла с результатами
Make-HtmlByTemplate -file $templateMainFile -date $date -content $html | Out-File $reportFile
