#####################################################################################
#
#
#  Name: pwNeverExpires
#  Ver.: 1
#  Auth: Jacob Pagano
#  Notes:
#		Requires PS v3.0
#  Description:
#       This performs an audit on all active directory accounts in a domain and checks to see if "Password Never Expires" is active
#       on an active directory account. It then checks for the presence of an exemption group. If no group is present, it removes 
#       the password expiration from the account.
#		
#
#
#
#
#
#  ChangeLog:
#			v1 05/2/2024  - I was born
#
#	To use on a different domain:
#		Update the function "zSend-Emails" to include appropriate email addresses.
#		Update the UserDeclaredVariables to have the appropriate values.
#
#####################################################################################

Import-Module ActiveDirectory
Import-Module ImportExcel

#region Functions

Function zNew-ReportObject {

  #Template used for all stale objects report objects regardless of object type.
	
  $object = New-Object PSObject -Property @{
	
    "Exempt" = ""
    "Flag" = ""
    "Name" = ""
    "SamAccountName" = ""
    "Enabled" = ""
    "Created" = ""
    "LastLogonTimestamp" = ""
    "pwdLastSet" = ""
    "PasswordNeverExpires" = ""
    "description" = ""
    "info" = ""
    "path" = ""
    "DN" = ""
    "GUID" = ""
    "Note" = ""
    "mail" = ""
    "class" = ""
    "ScriptAction" = ""

  }

  return $object
}

Function zGet-PWNeverExpireUsers {

  Param (
    [Parameter(Mandatory=$true)]
    [int]$daysToGoBack,
    [Parameter(Mandatory=$false)]
    [string]$searchBase
  )

  if($searchbase){
    [array]$Users += Get-ADUser -Filter * -SearchBase $searchBase -Server $Server -Property Name,pwdLastSet,passwordNeverExpires,LastLogonTimestamp  | where { $_.passwordNeverExpires -eq "true" }
  }else{	
    [array]$Users += Get-ADUser -Filter * -Server $Server -Property Name,pwdLastSet,passwordNeverExpires,LastLogonTimestamp  | where { $_.passwordNeverExpires -eq "true" }
  }
	
  return ($Users).ObjectGUID.guid
}


Function zSet-PWNeverExpireUserInfo {

  Param (
    [Parameter(Mandatory=$true)]
    [object]$blankReportObject,
    [Parameter(Mandatory=$true)]
    [string]$userGuid
  )

  #queries a user object guid and populates script specific values on a blank report object.
	
  $currentObject = Get-ADUser $userGuid -Properties CanonicalName,Created,Description,mail,whenCreated,pwdLastSet,passwordNeverExpires,LastLogonTimestamp

  #[string]$path = (((($currentObject.CanonicalName).split("/"))[1..((($currentObject.CanonicalName).split("/")).count-2)] -join "/"))
			
  $blankReportObject.Name = $currentObject.Name
  $blankReportObject.SamAccountName = $currentObject.SamAccountName
  $blankReportObject.Enabled = $currentObject.Enabled
  $blankReportObject.Created = $currentObject.created
  $blankReportObject.LastLogonTimestamp = ([DateTime]::FromFileTime([Int64]::Parse($currentObject.lastLogonTimeStamp)))
  $blankReportObject.pwdLastSet = ([DateTime]::FromFileTime([Int64]::Parse($currentObject.pwdLastSet)))
  $blankReportObject.PasswordNeverExpires = $currentObject.PasswordNeverExpires
  $blankReportObject.description = $currentObject.description
  $blankReportObject.path = (((($currentObject.CanonicalName).split("/"))[1..((($currentObject.CanonicalName).split("/")).count-2)] -join "/"))
  $blankReportObject.DN = $currentObject.distinguishedName
  $blankReportObject.GUID = $userGuid
  $blankReportObject.mail = $currentObject.mail
  $blankReportObject.class = "user"
  return $blankReportObject

}


Function zApply-DistinguishedNameExemptionFilter {

  Param (
    [Parameter(Mandatory=$true)]
    [array]$exemptDNs,
    [Parameter(Mandatory=$true)]
    [array]$objectsToCompare
  )
	
  #Compares each report objects DistinguishedName to the exempt DistinguishedNames array and returns an updated array of report objects
  #Does not modify anything that is already set to ($_.Exempt -eq "True") - This is so exemption precedence is held
	
  foreach($exemptDN in $exemptDNs){

    $objectsToCompare | where {$_.Exempt -ne "Yes"} | where {$_.DN -like ("*" + $exemptDN)} | %{$_.Exempt = "Yes" ; $_.Flag = "DN Exempt" ; $_.Note = "DN: $exemptDN"}	

  }

  return $objectsToCompare
	
}

Function zApply-SamAccountNameExemptionFilter {

  Param (
    [Parameter(Mandatory=$true)]
    [array]$samAccountNamePrefixExemptions,
    [Parameter(Mandatory=$true)]
    [array]$objectsToCompare,
    [Parameter(Mandatory=$false)]
    [int]$pwdAgeLimitDays = 1000		
  )

  foreach ($prefix in $samAccountNamePrefixExemptions){
		
    switch($prefix){
	
      default{$objectsToCompare | where {$_.Exempt -ne "Yes"} | where {$_.class -eq "user"} | where {$_.samAccountName -like ($prefix + "*")} | %{$_.Exempt = "Yes" ; $_.Flag = "Prefix exempt"} }
	
    }
  }
	
  return $objectsToCompare
}

Function zApply-GroupMembershipExemptionFilter {

  Param (
    [Parameter(Mandatory=$true)]
    [array]$exemptionGroups,
    [Parameter(Mandatory=$true)]
    [array]$objectsToCompare		
  )
	
  foreach($group in $exemptionGroups){
	
    [array]$members = $null
    $members += (Get-ADGroupMember $group -Recursive).ObjectGuid.Guid
		
    if($members){
			
      foreach($member in $members){
			
        $objectsToCompare | where {$_.Exempt -ne "Yes"} | where{$_.GUID -eq $member} | %{$_.Exempt = "Yes" ; $_.Flag = "Group exempt"; $_.Note = $_.Note + "Exemption Group: $group"}
				
      }	
    }
  }
	
  return $objectsToCompare

}

#This function was created so other phases of the process can call the query phase without having to duplicate the steps it takes potentially causing inconsistencies
Function zPasswordNeverExpiresAccounts-Query {

  #Gather array of user accounts with non-expiring passwords.
		
  foreach($base in $searchBaseDNs){
  $pattern = '(?i)DC=\w{1,}?\b'
  $global:Domain = ([RegEx]::Matches($base, $pattern) | ForEach-Object { $_.Value }) -join ',' 
		
    [array]$report += zGet-PWNeverExpireUsers $lastLogonTimestampFilter -searchBase $base | where {$_ -ne $null} | %{zSet-PWNeverExpireUserInfo -ErrorAction "silentlycontinue" -blankReportObject (zNew-ReportObject) -userGuid $_}
			
  }
		
  $report = $report | Sort-Object -Property GUID -Unique
		
  if($report.count -ge 1){
		
    #Apply exemption filters
			
    #DN exemptions
    $report = zApply-DistinguishedNameExemptionFilter -exemptDNs $script:autoExemptDistinguishedNames -objectsToCompare $report
						
    #groupMembership exemptions
    $report = zApply-GroupMembershipExemptionFilter -exemptionGroups $script:exemptionGroups -objectsToCompare $report
  }
  return $report

}

Function zSend-Emails ($emailTo, $emailAccountName, $emailSamAccountName, $accountName, $samAccountName, $domain, $pwdLastSet) {



  $MessageSubject = "ATTENTION! An account of yours was removed from the non-expiring password list."
  $MessageBody = @"

[This is an automated message from A1 IT Service Solutions LLC regarding your Active Directory account or an Active Directory account that you manage]

 

This message is to confirm that the following account was flagged because the password is set to never expire:

 

AccountName: $accountName

SamAccountName: $samAccountName

Domain Name: $domain

Password Last Set: $pwdLastSet



To comply with Microsoft Best Practices and NSA Guidance, password expiration for this account has been turned on. 


If you need this account to have a non-expiring password, please request an exemption from your Information Assurance department or Cybersecurity Division.

 

Please note that this is a no-reply email sent to all email addresses associated with the account.  If you received this email in error, please contact the A1 IT Service Solutions or open a ticket to notify the appropriate personnel of the misconfigured account.


 

Sincerely,

 

A1 IT Service Solutions LLC

 

"@

  Send-MailMessage -to $emailTo -cc $script:cc -from $script:MessageFrom -subject $MessageSubject -body $MessageBody -smtpServer $script:SmtpServer -priority High	
}

function Get-NestedGroups {
    param (
    [Parameter()] $groupinput,
    [Parameter()] [Switch] $IncludeUsers
    )

    function Test-Nest ($funcinput) {
        foreach ( $group in $funcinput ) { 
    
            Get-ADGroup "$($group.name)" 
        
            $GetObjects = Get-ADGroupMember $group
            $GetGroups = $getobjects | Where-Object ObjectClass -eq "Group"
            
            if ($IncludeUsers) {
                $GetUsers = $getobjects | Where-Object ObjectClass -eq "User"
                if ( $GetUsers ) { foreach ($user in $GetUsers) { Write-host "$indent  ↳ $($user.name)" } }
                }

            if ( $getgroups ) { foreach ($group in $GetGroups) { Test-Nest $group } }
            
        }
    }
    
    $i = 1

    foreach ($group in $groupinput) {
        $progress = [math]::round(($i/$groupinput.count)*100) ; Write-Progress -Activity "Scanning for nested groups" -Status "$progress % ($i of $($groupinput.count)) Complete:" -PercentComplete $progress -currentoperation $group.name; $i++

        $GetObjects = Get-ADGroupMember $group
        $GetGroups = $getobjects | where objectclass -eq "Group"

        if ( $getgroups ) { 
            Write-Host "`n"$group.name
            
            foreach ( $group in $getgroups ) { Test-Nest $group }
            
            }
    }
}


#endregion Functions

#region UserDeclaredVariables

#Script file path and date format - default location to save CSV, error log, and queryphase data file to be used for action scripts.
[string]$scriptFilePath = Split-Path -parent $MyInvocation.MyCommand.Definition # directory the script is running from.
$RunDate = (Get-Date).tostring("yyy.MM.dd_HH.mm.tt")
        
#Output 

  #LocalOutputFilePath
  $outputFilePath = "$scriptFilePath\Output"

  #RunLog
  [string]$runLog = "$outputFilePath\runlog.log"
	
  #errorLog
  [string]$errorLog = "$outputFilePath\errorlog.log"
  [int]$errorCount = 0

[string]$domain = (Get-ADDomainController).domain


$baseDN = (Get-ADDomain $domain).DistinguishedName
$ForestDC = (Get-ADDomain (Get-ADDomainController).Forest | Select-Object PDCEmulator).PDCEmulator
$Forest = (Get-ADDomain).Forest
$ForestNetBiosName = (Get-ADDomain $Forest).NetBIOSName
$ForestbaseDN = (Get-ADDomain $Forest).DistinguishedName
$DomainController = $env:COMPUTERNAME
$global:DomainNetBiosName = (Get-ADDomain).NetBIOSName
$Server = Get-ADDomainController

        		
#This is here to make it so Thom does not have to verify the userDeclaredVariable that the user defines.
if(!(Test-Path "$scriptFilePath\Output")){
	
  New-Item "$scriptFilePath\Output" -ItemType directory -Force
}




# Import values from CSV file, this is to assist with cross domain and cross network script migration.
# Impported variable values will trump any put into this script.
    
#region Import Values
	
#	do not provide a value for $importValuePath if you do not want this functionality.
  [String]$importValuePath = $null
  [string]#$importValuePath = "$scriptFilePath\Import_Values_PsStaleObjects.csv"

  [array]$importedValues = $null
  if($importValuePath){
    [array]$importedValues = Import-Csv -Path $importValuePath
  }
		
#Report File Path - location where the XLSX report file will be written
  [string]$reportFilePath = "\\$Domain\NETLOGON\Reports\pwNeverExpires"

  if(!(Test-Path "$reportFilePath")){
	
  New-Item "$reportFilePath" -ItemType directory -Force
}
    
  if($importedValues.valuename -contains "reportFilePath"){[string]$reportFilePath = ($importedValues | Where-Object{$_.ValueName -eq "reportFilePath"}).Value}

#Query
  # DistinguishedNames of the OUs to query - if this is $null, the query will fail and there will be no result. Values should be comma separated.
  [array]$script:searchBaseDNs = 
  (Get-ADOrganizationalUnit -Filter * -Properties DistinguishedName | ? {(($_.DistinguishedName -like "*Users*") -or ($_.DistinguishedName -like "*Admin?User?Accounts*") -or ($_.DistinguishedName -like "*Service?Accounts*"))}).DistinguishedName

  if($importedValues.valuename -contains "searchBaseDNs"){[array]$script:searchBaseDNs = (($importedValues | Where-Object{$_.ValueName -eq "searchbaseDNs"}).Value).Split(";") | ForEach-Object {$_.TrimStart()}}

#Exemptions
  #DistinguishedName exemptions - objects in these OU structure will be auto exempted by location
  [array]$script:autoExemptDistinguishedNames = 
  "CN=Users,DC=DS,DC=A1",
  "OU=Domain Controllers,DC=DS,DC=A1"
      
if($importedValues.valuename -contains "autoExemptDistinguishedNames"){[array]$script:autoExemptDistinguishedNames = (($importedValues | Where-Object{$_.ValueName -eq "autoExemptDistinguishedNames"}).Value).Split(";") | ForEach-Object {$_.TrimStart()}} 

#User Object SamAccountName exemption prefix - SamAccountNames that are "-like" the list below will be auto exempt
  [array]$script:autoExemptPrefix = $null	
    
  if($importedValues.valuename -contains "autoExemptPrefix"){[array]$script:autoExemptPrefix = (($importedValues | Where-Object{$_.ValueName -eq "autoExemptPrefix"}).Value).Split(";") | ForEach-Object {$_.TrimStart()}}

# Hard Exemptions
#if there are one or more exemption groups, add them here.
  [array]$script:exemptionGroups = (Get-NestedGroups "$DomainNetBiosName IA - Password Never Expires Exemption").Name
  $script:exemptionGroups += (Get-ADGroup "Forest IA - Password Never Expires Exemption").Name
  $script:exemptionGroups += (Get-ADGroup "$DomainNetBiosName IA - Password Never Expires Exemption").Name
      
  if($importedValues.valuename -contains "exemptionGroups"){[array]$script:exemptionGroups = (($importedValues | Where-Object{$_.ValueName -eq "exemptionGroups"}).Value).Split(";") | ForEach-Object {$_.TrimStart()}}
	


#email Related

  $script:smtpServer  = "DCMETSMTP001.RES.DS.A1"
  if($importedValues.valuename -contains "smtpServer"){[string]$script:smtpServer = ($importedValues | Where-Object{$_.ValueName -eq "smtpServer"}).Value}
  
  $script:messageFrom = "doNotReply@a1its.org"
  if($importedValues.valuename -contains "messageFrom"){[string]$script:messageFrom = ($importedValues | Where-Object{$_.ValueName -eq "messageFrom"}).Value}
  
  $script:cc = "active-directory-management@a1its.org"
  if($importedValues.valuename -contains "cc"){[string]$script:cc = ($importedValues | Where-Object{$_.ValueName -eq "cc"}).Value}

  
#endregion UserDeclaredVariables

switch ($phase) {
	
  Default { Write-Host "Querying objects that have the 'Password Never Expires' flag set."
	
    [array]$report = zPasswordNeverExpiresAccounts-Query
			
    #Write Output
		if ($report){			
    #Working Report	
    $report | select class,Exempt,Flag,Enabled,Note,Name,SamAccountName,description,path,ScriptAction,Created,GUID,mail,info,LastLogonTimestamp,pwdLastSet,PasswordNeverExpires | Export-Excel -AutoFilter -AutoSize -FreezeTopRow -Path ($reportFilePath + "\pwNeverExpires-Query" + $runDate + ".xlsx")}

# Modification

Write-Host "Modifying objects that have the 'Password Never Expires' flag set."
	
    [array]$toModify = $report | where{$_.Exempt -ne "Yes"}
			
    #Set Account Not Delegated
    foreach($object in $toModify){
							
      Try{
        Set-ADUser $object.GUID -PasswordNeverExpires $false
        $object.scriptAction = $object.scriptAction + " Set Password Never Expires to False ;"
        $object.PasswordNeverExpires = "FALSE"
      }Catch [system.exception]{
        $exception = $_.exception.message.toString()
        Try{
          $object.scriptAction = $object.scriptAction + " Failed to Password Never Expires to False ;"
          "$runDate SamAccountName:`'" + $object.SamAccountName + "`' ; Attempted Action: Set Password to Never Expire ;  Error: " + $exception | Out-File -FilePath $errorLog -Append -Encoding ASCII
          $errorCount = $errorCount + 1
        }
        Catch{
          #do nothing
        }


      }
      if ($object){
        #Report
	    $object | select class,Exempt,Flag,Enabled,Note,Name,SamAccountName,description,path,ScriptAction,Created,GUID,mail,info,LastLogonTimestamp,pwdLastSet,PasswordNeverExpires | Export-Excel -AutoFilter -AutoSize -FreezeTopRow -Append -Path ($reportFilePath + "\pwNeverExpires-Modify" + $runDate + ".xlsx")
			}	
      }
	
      #Send email
			
      [string[]]$emailTo = $null
      [string[]]$emailTo = $object.mail
      $emailTo = $emailTo | sort -Unique
      if($emailTo.count -gt 0){
        zSend-Emails -emailAccountName "accountName" -emailSamAccountName "accountSamAccountName" -emailTo $emailTo -accountName $object.Name -samAccountName $object.SamAccountName -domain $domain -pwdLastSet $object.pwdLastSet
      }
				
    }	


			
    #Write Output
		
  }



		






# SIG # Begin signature block
# MIISEwYJKoZIhvcNAQcCoIISBDCCEgACAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUPsI669hg7z3kSugQ47fOexit
# vPiggg9rMIIHsTCCBZmgAwIBAgITNQAAACFv8bfVN7E2EQAAAAAAITANBgkqhkiG
# 9w0BAQsFADBrMRIwEAYKCZImiZPyLGQBGRYCQTExEjAQBgoJkiaJk/IsZAEZFgJE
# UzETMBEGCgmSJomT8ixkARkWA1JFUzEsMCoGA1UEAxMjQTEgU2VydmljZXMgYW5k
# IFNvbHV0aW9ucyBSb290IENBIDEwHhcNMjQxMTAxMjEyMjI1WhcNMjYxMTAxMjEz
# MjI1WjBaMRIwEAYKCZImiZPyLGQBGRYCQTExEjAQBgoJkiaJk/IsZAEZFgJEUzEw
# MC4GA1UEAxMnQTEgU2VydmljZXMgYW5kIFNvbHV0aW9ucyBJZGVudGl0eSBDQSAy
# MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAvkT6nAuwAyEerK1ubOY/
# uYx1ET8YGc34SkwuIeBPWsuXSj8K/EC4bonScctUL3+Hy/Fh7XtIGntH9I9l4chv
# XBez3rTWi9p+OvMIun0D7AFOqZgyHOZNu20WqdjqkV2p/JdEuGy8Oht4Nudva/PF
# iDDLhLN/SrtgGZeHVVX4hSbZ/FNHPUSfgGmRlnBsYVIVIj+vC57x2q8V+NtatcdR
# 3LDAa2CVcMr0dCwc5wRWLoE4m9xVes381gd7vMby4soOcynqVxn46UWbhuobzzV/
# NTVN5Myu7bHwFnSWjqqEfuqvwYc/w4PvuoQfdusmuPqOijymPFTX+yp253kEE6Jj
# 5aJHA5sDFcll45nwGWV0cqILSflJuQzOTjbVqUlzgOlROMRjaJKvZCaRK2JgvUxC
# ESmi8q311KW1FPgWdJlgIx6M1er7frBVAJdb8uRDdrTDv7M+ndabOu8isDZpxbCB
# BwsrBeVuHuIKovDeiDVmPfMnx1iRNU7xR13vlxuBq/XZFFC5noz9w8FYjdGmfziS
# q2U0jPvKlt9X5coCTxtWRUb0+TKfPMig6m99uUttrlfcbKO4bB6bT0RXDYdvHlRk
# rno0UPwJydEGO5B14gUNSMYJGRnDHOX3pGSHUpcy2wPTP/GZvSXl5wOOLAlH9BlW
# Yp4zmRyodDduAY2RkR0uKiECAwEAAaOCAl0wggJZMBAGCSsGAQQBgjcVAQQDAgEA
# MB0GA1UdDgQWBBRCukU5BVtJIjRduo5o9MwnCUZUsjAZBgkrBgEEAYI3FAIEDB4K
# AFMAdQBiAEMAQTAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNV
# HSMEGDAWgBQplPz4ifJvrFq2ZWIAPNHYe/purjCB6gYDVR0fBIHiMIHfMIHcoIHZ
# oIHWhoHTbGRhcDovLy9DTj1BMSUyMFNlcnZpY2VzJTIwYW5kJTIwU29sdXRpb25z
# JTIwUm9vdCUyMENBJTIwMSxDTj1EQ01FVENBMDAxLENOPUNEUCxDTj1QdWJsaWMl
# MjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxDTj1Db25maWd1cmF0aW9uLERD
# PURTLERDPUExP2NlcnRpZmljYXRlUmV2b2NhdGlvbkxpc3Q/YmFzZT9vYmplY3RD
# bGFzcz1jUkxEaXN0cmlidXRpb25Qb2ludDCB2wYIKwYBBQUHAQEEgc4wgcswgcgG
# CCsGAQUFBzAChoG7bGRhcDovLy9DTj1BMSUyMFNlcnZpY2VzJTIwYW5kJTIwU29s
# dXRpb25zJTIwUm9vdCUyMENBJTIwMSxDTj1BSUEsQ049UHVibGljJTIwS2V5JTIw
# U2VydmljZXMsQ049U2VydmljZXMsQ049Q29uZmlndXJhdGlvbixEQz1EUyxEQz1B
# MT9jQUNlcnRpZmljYXRlP2Jhc2U/b2JqZWN0Q2xhc3M9Y2VydGlmaWNhdGlvbkF1
# dGhvcml0eTANBgkqhkiG9w0BAQsFAAOCAgEAA+2zHGG0ctyA9J0eEZXVX+Z4+bJ6
# NnmOvx9ik9uNRGMTHNypB+mEFJd3RRS2MFCl/GYh/udIc9OQXt/ghoQv4pf+vAet
# y4wAOh4DS6QjvpexUX80Ytvfu0uZXV92X+xoLRzafMFE/LrgvJqR0rt8jXFx6J+i
# IDdM1ibsjOj2+Ql5AxXXyBxxsz016fARfzutv3LXAoER8zRFw9Kdg2F9Ok4niXB3
# ZIoCaCt5UxqwoWv5Mdx3GNY5vWY+iOINwKaaupymVlC6TuYI+bIHDBRhj8SFn2WC
# BpAQU2DmbmszY4IbqC8bTZwU2PEViDkkikbGTpWvt3hhE+owmV35X1iz6p6I5voi
# 15K8JhNvClerDWCpaU3dqImuifiGktg6lKeIG9VpxFIe7jCvgKMACl5nE2WIs0sS
# EqHMEohTnWU3Wk2eyCBNey+ohSdEQX7+wBD/37oWUQu17l07XZNzv8BJx4Ng+8+C
# xwqo4qIv8e98y5b0HNhCz3VJ/yfK+n4+tdGWRD0llaxYNLZsjJW/51Ay2+1LfhwV
# vhDYqyiOsRjnJfk/vh4dbZBs7dqRZciRVU7tiEjPJvjxLBaDDYBr5eJebD13h3lS
# dlUwVe+mYitgKn6AvV6KBZ9KWSKeLkHCO1Hro2XiIclb0qRrP6kCjVQOY1ntoSkv
# kuKLejBiMbrbG4QwggeyMIIFmqADAgECAhMcAAAABCy0NqBxfyQvAAAAAAAEMA0G
# CSqGSIb3DQEBDQUAMFoxEjAQBgoJkiaJk/IsZAEZFgJBMTESMBAGCgmSJomT8ixk
# ARkWAkRTMTAwLgYDVQQDEydBMSBTZXJ2aWNlcyBhbmQgU29sdXRpb25zIElkZW50
# aXR5IENBIDIwHhcNMjQxMTA2MDA1NjU0WhcNMjUxMTA2MDA1NjU0WjAaMRgwFgYD
# VQQDEw9qYWNvYi5wYWdhbm8uZWEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
# AoIBAQCotcvkPswYJQOgNNRA1LspaDYYeTEXAoPQdk+DbEguxt2/WUS+ywnTnTCx
# yVWkwOw6l3fNqsc//Mw77sfJnCEfCas6djxGtn9VLzYuRC5Y9zKy710YfZutHy92
# WhxsbFXdQKIiCkaqD0d8qo1l2GtMtqt9UvLRikHlqbxsanbbeVE/UcIu0U/VTv3M
# rc0ZdgVBqTnM2Z/Y6UlrjRx5hejBc/lLbu0f1MGLBjAWXEz7gCV2plFFo981aziD
# 1QbFuWML+eyn2QvmNvSgBv38MeUB8/XlxNbJP+TvzqZBq4oSghB27Q0YdpwPearq
# Wm2pK9nGVDPSoEU3gqW9ElRzE+xtAgMBAAGjggOvMIIDqzAdBgNVHQ4EFgQUuanp
# vQdu4/EMgTm9ATEGPL55jGYwHwYDVR0jBBgwFoAUQrpFOQVbSSI0XbqOaPTMJwlG
# VLIwge4GA1UdHwSB5jCB4zCB4KCB3aCB2oaB12xkYXA6Ly8vQ049QTElMjBTZXJ2
# aWNlcyUyMGFuZCUyMFNvbHV0aW9ucyUyMElkZW50aXR5JTIwQ0ElMjAyLENOPURD
# TUVUQ0EwMDIsQ049Q0RQLENOPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNl
# cnZpY2VzLENOPUNvbmZpZ3VyYXRpb24sREM9RFMsREM9QTE/Y2VydGlmaWNhdGVS
# ZXZvY2F0aW9uTGlzdD9iYXNlP29iamVjdENsYXNzPWNSTERpc3RyaWJ1dGlvblBv
# aW50MIHfBggrBgEFBQcBAQSB0jCBzzCBzAYIKwYBBQUHMAKGgb9sZGFwOi8vL0NO
# PUExJTIwU2VydmljZXMlMjBhbmQlMjBTb2x1dGlvbnMlMjBJZGVudGl0eSUyMENB
# JTIwMixDTj1BSUEsQ049UHVibGljJTIwS2V5JTIwU2VydmljZXMsQ049U2Vydmlj
# ZXMsQ049Q29uZmlndXJhdGlvbixEQz1EUyxEQz1BMT9jQUNlcnRpZmljYXRlP2Jh
# c2U/b2JqZWN0Q2xhc3M9Y2VydGlmaWNhdGlvbkF1dGhvcml0eTA9BgkrBgEEAYI3
# FQcEMDAuBiYrBgEEAYI3FQiCg9sQhPysLoednSKGkbMjg7TuHWSGr5FDhMKEDwIB
# ZAIBHjBXBgNVHSUEUDBOBgorBgEEAYI3FAICBggrBgEFBQcDBAYKKwYBBAGCNwoD
# BAYIKwYBBQUHAwMGCCsGAQUFBwMCBgorBgEEAYI3QwEBBgorBgEEAYI3QwECMA4G
# A1UdDwEB/wQEAwIHgDBrBgkrBgEEAYI3FQoEXjBcMAwGCisGAQQBgjcUAgIwCgYI
# KwYBBQUHAwQwDAYKKwYBBAGCNwoDBDAKBggrBgEFBQcDAzAKBggrBgEFBQcDAjAM
# BgorBgEEAYI3QwEBMAwGCisGAQQBgjdDAQIwMAYDVR0RBCkwJ6AlBgorBgEEAYI3
# FAIDoBcMFWphY29iLnBhZ2Fuby5lYUBEUy5BMTBPBgkrBgEEAYI3GQIEQjBAoD4G
# CisGAQQBgjcZAgGgMAQuUy0xLTUtMjEtMzU2ODUwODc5NS0yNjgyMjA0NTM0LTE2
# MzY2MTY0MDEtMTUyNTANBgkqhkiG9w0BAQ0FAAOCAgEAYjZXipRry+Xqruswl7lf
# PURFd092t+TJUoMBYoh/U4cMr+uizLVHgADF+kJKkMazqQBugIwku8FWjXZEgvPl
# rHQs9xYthlJK5yQ3OcN8EU2njA0Tkq1W2MJEz++9w8nDtLCyLA80cnNumnl8ZU8g
# JRU0FXCoFEotlnHsaoGnnlGqxmoAwvuF0+QWUQ14iBlPXCqnBHLeqFSnohUFiIqD
# sKuZ7zY8DNylD1ouJiVSA+fqAdXYRbNTHKMTk7K6+csPrUuma0kni7oYdjbGBO53
# oOsW2Mk9YKrVfb1aCnNtg3LBPVABgWJIB8EUMOrnxhcqWajMeKt98pgz7p5GVjX2
# 6dzYOTh9a2vhrTkZo/JMaujt21fPy7PKvxgvnnP2+bEVbyWKMg2RmsUWdyVExrv0
# mzm4OwyFe6AM3B4eKYAJHvs54vCE2UNUu5jlLhTFtnP8U8Or41wv0kg4Y2lVTK7O
# XMc22P5yOxnau+Ob5T2nMjKmf7GjlsI9CEtJVGyHXgEIT+r11mto5K9/ZhdjzMNB
# fvUAhrQxMD8wgdw6sphmhtnVWX+3FKB3YwBxIgFb4eBhIb4dJYNGKtuP3HhSvVdz
# B70IRb6WtdWxw1Z81AFhYYrEio67ImVtOcVDnrl5pjLZcN8R8SbEX2hBDeUwoNC7
# mbHJAq5CuJpGU8J0GSNh0KcxggISMIICDgIBATBxMFoxEjAQBgoJkiaJk/IsZAEZ
# FgJBMTESMBAGCgmSJomT8ixkARkWAkRTMTAwLgYDVQQDEydBMSBTZXJ2aWNlcyBh
# bmQgU29sdXRpb25zIElkZW50aXR5IENBIDICExwAAAAELLQ2oHF/JC8AAAAAAAQw
# CQYFKw4DAhoFAKB4MBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcN
# AQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUw
# IwYJKoZIhvcNAQkEMRYEFAjCDvxEnuxWrInPo4cxrJ3ofYETMA0GCSqGSIb3DQEB
# AQUABIIBAAj1qmnhrePmYrDNL5+UZn7/zXVOs2fO/8iM/dwPq6Syd61sRlXDiDH7
# 2ZpLhC6rtsfZ9tsmKR/K2+HSykfUhFOaV1udGodlz+zFGVcZSkFBt/ooTVB16n4y
# Iw5HRhhzme/AAcJ2lgloL1nQ0xBYDDz9bMX3Yt5cH53I9k/LnE37ikA/N5msNOde
# 6yMrrWgdwzkFVIi7wVEZJnI8n+v7RWbEpAaYeMUuy5Br6GPGoFhPCwPSSNruzH14
# tnYiM0ZUSEtb94pyUOi+fi9Cvt9kCvrt3lE/FeXUP/e4ItBhnPHG3Y8e2V7Yy6jt
# ALsCPTaTjxmb8//3fUJuZP/EAUlQzuA=
# SIG # End signature block
