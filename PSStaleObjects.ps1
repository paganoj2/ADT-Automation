#####################################################################################
#
#
#  Name: PsStaleObjects
#  Ver.: 11
#  Auth: AD Team / Tyler Guertin
#  Revised several times by Jacob Pagano
#  Notes:
#		Requires PS v3.0
#		
#
#
#
#	Still needs:
#		Validation of exemptions and possible emergency stops for different phases
#		Logging of errors
#
#
#  ChangeLog:
#			v1 03/9/2015  - I was born
#			v2 05/15/2015 - Added email portion to modify phase.
#           v3 5/15/2015 - Fixed issues with exemptions not applying and multiple email addresses.
#			v4 05/19/2015 - Modify Phase - Made changes to the actions taken portion to include description changed, disabled, sent email, along with failure of the same.
#						 + Modify Phase - Took the send email portion out of the disable object loop and put it directly in the foreach object to modify.
#			v5 05/27/2015 - Delete Phase - Fixed issue with Delete phase not correctly filtering disabled objects.
#						 + Delete Phase - Added -confirm:$false -recursive to Remove-ADObject.
#			v6 06/09/2015 - Changed format of rundate to year, month, day.
#						 + Included portion in user declared variables to create the output directory if the $scriptFilePath\output directory does not already exist. This 
#							really is not neccessary if the user declared variables are correctly set.  Even using $scriptFilePath was meant to simplify this already simple thing.
#			v7 06/17/2015 - Added "created" to the computer object query.
#						 + Set order of export values to select class,Exempt,Flag,Enabled,LastLogonTimestamp,Note,Name,SamAccountName,description,path,extensionAttribute14,ScriptAction,Created,DN,GUID,mail,pwdLastSet,info,OS
#			v8 03/29/2017 - Changed query phase filter from 61 to 35 days.
#			v9 11/16/2017 - Added the import from CSV option and cleaned up some of the portions that were no longer in use.
#           v10 5/20/2024 - Added an area to test ImportExcel availability.
#           v11 9/10/2024 - Added support for Azure AD logins. This will now check both Azure AD and Active Directory and use the most recent timestamp to determine if the user is stale.
#
#
#	To use on a different domain:
#		Update the function "zSend-Emails" to include appropriate email addresses.
#		Update the UserDeclaredVariables to have the appropriate values.
#
#####################################################################################
<#
    #####################################################################################
    ------------------------------------
    Query phase
    ------------------------------------

    The entire domain is queried against a lastLogonTimestamp filter.

    The exemption compares go as follows:

    1. Exempt OU structures (distinguishedName compare)

    2. Group membership to an exemption group

    3. Exempt prefix compare on samAccountName
    a. "svc.*"
    aa. password age check to validate



    Report objects should have:

    Exempt - Yes/No
    Flag - Stale User/Stale Computer/Exempt name match/etc
    OU - "direct OU name"
    Path - OU path off canonicalName



    ------------------------------------
    Modify phase
    ------------------------------------

    -verify still stale
    -recheck against exemptions

    -Disable in place
    -update description



    ------------------------------------
    Deletion phase
    ------------------------------------


    -verify still stale
    -verify still disabled
    -recheck against exemptions


    -delete
    -Fix descriptions


#>
#####################################################################################

#####################################################################################
#
#This block must be at the top of the script - do not move or put anything above it
#
param([string]$phase= "")
#param([string]$phase= "query")
#param([string]$phase= "Modify")
#param([string]$phase= "Delete")
#
#
#####################################################################################

Import-Module ActiveDirectory


# Make sure ImportExcel is available.
$LocalExcelModulePath = "C:\\Program Files\\WindowsPowerShell\\Modules\\ImportExcel"
$NetworkExcelModulePath = "\\DS.A1\\netlogon\\ENT\\Modules\\ImportExcel"
if((Test-Path $LocalExcelModulePath) -eq 0)
{
    RoboCopy /E "$NetworkExcelModulePath" "$LocalExcelModulePath"
}
Import-Module "$LocalExcelModulePath"

# Authenticate to Azure AD
$TenantId = "7cd17b7a-516a-4910-8d57-ff2c09c76c6b"
$AppClientId = "b97a11e5-7960-4bf2-9267-84ea0cb32063"
$ClientSecret = "CZh8Q~nfZmdBp3VH1iNLiPXjEz.LTTSiTpVFgaNP"

$RequestBody = @{client_id=$AppClientId;client_secret=$ClientSecret;grant_type="client_credentials";scope="https://graph.microsoft.com/.default";}
$OAuthResponse = Invoke-RestMethod -Method Post -Uri https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token -Body $RequestBody
$AccessToken = $OAuthResponse.access_token

# Form request headers with the acquired $AccessToken
$headers = @{"Content-Type"="application/json";"Authorization"="Bearer $AccessToken"}

# Function to retrieve Azure AD users and their most recent logon timestamp
Function Get-AzureADUsers {
    $ApiUrl = "https://graph.microsoft.com/beta/users?`$select=displayName,userPrincipalName,signInActivity"
    $Result = @()
    While ($ApiUrl -ne $Null) {
        $Response = Invoke-RestMethod -Method GET -Uri $ApiUrl -ContentType "application/json" -Headers $headers
        if ($Response.value) {
            $Users = $Response.value
            ForEach ($User in $Users) {
                $LastSignInDateTime = if ($User.signInActivity.lastSignInDateTime) { [DateTime]$User.signInActivity.lastSignInDateTime } else { $null }
                $LastNonInteractiveSignInDateTime = if ($User.signInActivity.lastNonInteractiveSignInDateTime) { [DateTime]$User.signInActivity.lastNonInteractiveSignInDateTime } else { $null }

                $MostRecentTimestamp = if ($LastSignInDateTime -and $LastNonInteractiveSignInDateTime) {
                    if ($LastSignInDateTime -gt $LastNonInteractiveSignInDateTime) { $LastSignInDateTime } else { $LastNonInteractiveSignInDateTime }
                } elseif ($LastSignInDateTime) {
                    $LastSignInDateTime
                } else {
                    $LastNonInteractiveSignInDateTime
                }

                $Result += New-Object PSObject -property $([ordered]@{ 
                    DisplayName = $User.displayName
                    UserPrincipalName = $User.userPrincipalName
                    MostRecentTimestamp = $MostRecentTimestamp
                })
            }
        }
        $ApiUrl = $Response.'@odata.nextlink'
    }
    return $Result
}


Function Get-AzureADTimestamp {
    param (
        [string]$userPrincipalName
    )

    # Retrieve Azure AD user by User Principal Name
    $ApiUrl = "https://graph.microsoft.com/beta/users?`$filter=userPrincipalName eq '$userPrincipalName'&`$select=displayName,userPrincipalName,signInActivity"
    $Response = Invoke-RestMethod -Method GET -Uri $ApiUrl -ContentType "application/json" -Headers $headers

    if ($Response.value -and $Response.value.Count -eq 1) {
        $User = $Response.value
        $LastSignInDateTime = if ($User.signInActivity.lastSignInDateTime) { [DateTime]$User.signInActivity.lastSignInDateTime } else { $null }
        $LastNonInteractiveSignInDateTime = if ($User.signInActivity.lastNonInteractiveSignInDateTime) { [DateTime]$User.signInActivity.lastNonInteractiveSignInDateTime } else { $null }

        $MostRecentTimestamp = if ($LastSignInDateTime -and $LastNonInteractiveSignInDateTime) {
            if ($LastSignInDateTime -gt $LastNonInteractiveSignInDateTime) { $LastSignInDateTime } else { $LastNonInteractiveSignInDateTime }
        } elseif ($LastSignInDateTime) {
            $LastSignInDateTime
        } else {
            $LastNonInteractiveSignInDateTime
        }

        return $MostRecentTimestamp
    } else {
        return $null
    }
}


# Function to retrieve and return the most recent lastLogonTimestamp from both AD and Azure AD
Function Get-CombinedLogonTimestamp {
    Param (
        [string]$userPrincipalName
    )

    # Retrieve AD user
    $adUser = Get-ADUser -Filter {UserPrincipalName -eq $userPrincipalName} -Properties lastLogonTimestamp

    # Retrieve Azure AD user
    $aadLogonTimestamp = Get-AzureADTimestamp -userPrincipalName $userPrincipalName

    # Convert AD lastLogonTimestamp to DateTime
    $adLogonTimestamp = if ($adUser.LastLogonTimestamp) { [DateTime]::FromFileTime($adUser.LastLogonTimestamp) } else { $null }

    # Determine the most recent timestamp
    $mostRecentTimestamp = if ($adLogonTimestamp -and $aadLogonTimestamp) {
        if ($adLogonTimestamp -gt $aadLogonTimestamp) { $adLogonTimestamp } else { $aadLogonTimestamp }
    } elseif ($adLogonTimestamp) {
        $adLogonTimestamp
    } else {
        $aadLogonTimestamp
    }

    return $mostRecentTimestamp
}


#This should only run on the domain PDC, get the current domain PDC and check if currently on the domain PDC.

$CurrentDC = (Get-ADDomainController -Identity $env:COMPUTERNAME).HostName
$PDC = (Get-ADDomain | Select-Object -Property PDCEmulator).PDCEmulator
if ($CurrentDC -ne $PDC){

#Current Domain Controller isn't the PDC, exit...
exit

}

#region Functions

Function zNew-StaleReportObject {

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
    "OS" = ""
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

# Function to compare AD and AAD users by User Principal Name and get the most recent timestamp
Function zGet-AndCompareStaleUsers {
    Param (
        [Parameter(Mandatory=$true)]
        [int]$daysToGoBack,
        [Parameter(Mandatory=$false)]
        [string]$searchBase
    )

    # Returns GUID of user objects that match the stale filter
    $staleFilter = (Get-Date).AddDays(-$daysToGoBack)
    $staleUsers = @()
    if ($searchBase) {
        $staleUsers += Get-ADUser -Filter {(whenCreated -lt $staleFilter) -and ((lastlogonTimestamp -lt $staleFilter) -or (lastlogonTimestamp -notlike "*"))} -SearchBase $searchBase -Server $Server
    } else {
        $staleUsers += Get-ADUser -Filter {(whenCreated -lt $staleFilter) -and ((lastlogonTimestamp -lt $staleFilter) -or (lastlogonTimestamp -notlike "*"))} -Server $Server
    }
    $adUsers = $staleUsers | ForEach-Object {
        New-Object PSObject -Property @{
            UserPrincipalName = $_.UserPrincipalName
            LastLogonTimestamp = $_.LastLogonTimestamp
            ObjectGUID = $_.ObjectGUID
        }
    }

    # Retrieve Azure AD users
    $aadUsers = Get-AzureADUsers

    # Compare users
    $combinedUsers = @()
    foreach ($adUser in $adUsers) {
        $aadUser = $aadUsers | Where-Object { $_.UserPrincipalName -eq $adUser.UserPrincipalName }
        if ($aadUser) {
            $adLogonTimestamp = if ($adUser.LastLogonTimestamp) { [DateTime]::FromFileTime($adUser.LastLogonTimestamp) } else { $null }
            $aadLogonTimestamp = $aadUser.MostRecentTimestamp

            $mostRecentTimestamp = if ($adLogonTimestamp -and $aadLogonTimestamp) {
                if ($adLogonTimestamp -gt $aadLogonTimestamp) { $adLogonTimestamp } else { $aadLogonTimestamp }
            } elseif ($adLogonTimestamp) {
                $adLogonTimestamp
            } else {
                $aadLogonTimestamp
            }

            $combinedUsers += [PSCustomObject]@{
                UserPrincipalName = $adUser.UserPrincipalName
                ADLastLogon = $adLogonTimestamp
                AADLastSignIn = $aadLogonTimestamp
                MostRecentTimestamp = $mostRecentTimestamp
                ObjectGUID = $adUser.ObjectGUID
            }
        } else {
            $combinedUsers += [PSCustomObject]@{
                UserPrincipalName = $adUser.UserPrincipalName
                ADLastLogon = $adUser.LastLogonTimestamp
                AADLastSignIn = $null
                MostRecentTimestamp = $adUser.LastLogonTimestamp
                ObjectGUID = $adUser.ObjectGUID
            }
        }
    }

    # Filter combined users based on logon timestamps
    $staleCombinedUsers = $combinedUsers | Where-Object {
        $_.MostRecentTimestamp -lt (Get-Date).AddDays(-$daysToGoBack)
    }

    return ($staleCombinedUsers).ObjectGUID.guid
}



Function zGet-StaleComputers {
	
  Param (
    [Parameter(Mandatory=$true)]
    [int]$daysToGoBack,
    [Parameter(Mandatory=$false)]
    [string]$searchBase
  )

  #returns guid of computer objects that match the stale filter
	
  $staleFilter = (Get-Date).AddDays(-$daysToGoBack)
	
  if($searchbase){
    [array]$staleComputers += Get-ADComputer -Filter {(whenCreated -lt $staleFilter) -and ((lastlogonTimestamp -lt $staleFilter) -or (lastlogonTimestamp -notlike "*"))} -SearchBase $searchBase -Server $Server
  }else{	
    [array]$staleComputers += Get-ADComputer -Filter {(whenCreated -lt $staleFilter) -and ((lastlogonTimestamp -lt $staleFilter) -or (lastlogonTimestamp -notlike "*"))} -Server $Server
  }
	
  return ($staleComputers).ObjectGUID.guid
}

Function zSet-StaleUserInfo {

  Param (
    [Parameter(Mandatory=$true)]
    [object]$blankReportObject,
    [Parameter(Mandatory=$true)]
    [string]$userGuid
  )

  #queries a user object guid and populates script specific values on a blank report object.
	
  $currentObject = Get-ADUser $userGuid -Properties CanonicalName,Created,Description,mail,lastLogonTimestamp,pwdLastSet,whenCreated,userPrincipalName

  #[string]$path = (((($currentObject.CanonicalName).split("/"))[1..((($currentObject.CanonicalName).split("/")).count-2)] -join "/"))
			
  $blankReportObject.Name = $currentObject.Name
  $blankReportObject.SamAccountName = $currentObject.SamAccountName
  $blankReportObject.Enabled = $currentObject.Enabled
  $blankReportObject.Created = $currentObject.created
  $blankReportObject.LastLogonTimestamp = Get-CombinedLogonTimestamp -userPrincipalName $currentObject.userPrincipalName
  $blankReportObject.pwdLastSet = ([DateTime]::FromFileTime([Int64]::Parse($currentObject.pwdLastSet)))
  $blankReportObject.description = $currentObject.description
  $blankReportObject.path = (((($currentObject.CanonicalName).split("/"))[1..((($currentObject.CanonicalName).split("/")).count-2)] -join "/"))
  $blankReportObject.DN = $currentObject.distinguishedName
  $blankReportObject.GUID = $userGuid
  $blankReportObject.mail = $currentObject.mail
  $blankReportObject.class = "user"
	
  return $blankReportObject

}

Function zSet-StaleComputerInfo {

  Param (
    [Parameter(Mandatory=$true)]
    [object]$blankReportObject,
    [Parameter(Mandatory=$true)]
    [string]$computerGuid
  )

  #queries a computer object guid and populates script specific values on a blank report object.
	
  $currentObject = Get-ADComputer $computerGuid -Properties CanonicalName,Created,Description,info,lastlogonTimestamp,OperatingSystem,pwdLastSet,whenCreated 
			
  $blankReportObject.Name = $currentObject.Name
  $blankReportObject.SamAccountName = $currentObject.SamAccountName
  $blankReportObject.Enabled = $currentObject.Enabled
  $blankReportObject.Created = $currentObject.created
  $blankReportObject.LastLogonTimestamp = ([DateTime]::FromFileTime([Int64]::Parse($currentObject.lastLogonTimeStamp)))
  $blankReportObject.pwdLastSet = ([DateTime]::FromFileTime([Int64]::Parse($currentObject.pwdLastSet)))
  $blankReportObject.OS = $currentObject.operatingSystem
  $blankReportObject.Description = $currentObject.Description
  $blankReportObject.info = $currentObject.info
  $blankReportObject.path = (((($currentObject.CanonicalName).split("/"))[1..((($currentObject.CanonicalName).split("/")).count-2)] -join "/"))
  $blankReportObject.DN = $currentObject.distinguishedName
  $blankReportObject.GUID = $computerGuid
  $blankReportObject.class = "computer"

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
	
    $passwordAgeFilter = ((Get-Date).addDays(-$pwdAgeLimitDays)).toFileTime()
		
    switch($prefix){
		
      svc. {
			
        $objectsToCompare | where {$_.Exempt -ne "Yes"} | where {$_.class -eq "user"} | where {$_.samAccountName -like ($prefix + "*")} | where {((Get-ADUser $_.GUID -Properties pwdLastSet).pwdLastSet) -lt $passwordAgeFilter} | %{$_.Flag = "old pwd"}
        $objectsToCompare | where {$_.Exempt -ne "Yes"} | where {$_.class -eq "user"} | where {$_.samAccountName -like ($prefix + "*")} | where {((Get-ADUser $_.GUID -Properties pwdLastSet).pwdLastSet) -ge $passwordAgeFilter} | where {$_.Flag -ne "old pwd"} | %{$_.Exempt = "Yes" ; $_.Flag = "Prefix exempt" ; $_.Note = "Prefix: $prefix"}
					
      }
	
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
Function zStale-Query {

  #Gather array of stale users and computers
		
  foreach($base in $searchBaseDNs){
  $pattern = '(?i)DC=\w{1,}?\b'
  $global:Domain = ([RegEx]::Matches($base, $pattern) | ForEach-Object { $_.Value }) -join ',' 
		
    [array]$report += zGet-AndCompareStaleUsers $lastLogonTimestampFilter -searchBase $base | where {$_ -ne $null} | %{zSet-staleUserInfo -ErrorAction "silentlycontinue" -blankReportObject (zNew-StaleReportObject) -userGuid $_}
			
    [array]$report += zGet-StaleComputers $lastLogonTimestampFilter -searchBase $base | where {$_ -ne $null} | %{zSet-staleComputerInfo -ErrorAction "silentlycontinue" -blankReportObject (zNew-StaleReportObject) -computerGuid $_}
  }
		
  $report = $report | Sort-Object -Property GUID -Unique
		
  if($report.count -ge 1){
		
    #Apply exemption filters
			
    #DN exemptions
    $report = zApply-DistinguishedNameExemptionFilter -exemptDNs $script:autoExemptDistinguishedNames -objectsToCompare $report
				
    #samAccountName prefix exemptions
    $report = zApply-SamAccountNameExemptionFilter -samAccountNamePrefixExemptions $script:autoExemptPrefix -objectsToCompare $report -pwdAgeLimitDays $pwdAgeLimitDays
		
    #groupMembership exemptions
    $report = zApply-GroupMembershipExemptionFilter -exemptionGroups $script:exemptionGroups -objectsToCompare $report
  }
  return $report

}

Function zSend-Emails ($emailTo, $emailAccountName, $emailSamAccountName, $accountName, $samAccountName, $domain) {



  $MessageSubject = "ATTENTION! Your account is about to be deleted for inactivity."
  $MessageBody = @"

[This is an automated message from A1 IT Service Solutions regarding your Active Directory account]

 

This message is to confirm that the following account was flagged as a stale object:

 

AccountName: $accountName

SamAccountName: $samAccountName

Domain Name: $domain

 

If you no longer need this account, you do not need to do anything. If this account is still needed, please log into it. If this account is disabled, please contact your system administrator or Enterprise Service Desk to re-enable it.

 

Please note that this is a no-reply email sent to all email addresses associated with the account.  If you believe you have received this email in error, please contact your System Administrator or open a ticket to notify the appropriate personnel of the misconfigured account.

 

If you have additional questions, visit the Stale Object Process Knowledge Base article at https://ntwk1.sharepoint.com/sites/DepartmentofTechnology/SitePages/Stale-Objects-Cleanup-Process.aspx

 

Sincerely,

 

A1 IT Service Solutions

 

"@

  Send-MailMessage -to $emailTo -cc $script:cc -from $script:MessageFrom -subject $MessageSubject -body $MessageBody -smtpServer $script:SmtpServer -priority High

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

$Domain = (Get-ADDomain).DNSRoot
$baseDN = (Get-ADDomain $domain).DistinguishedName
$ForestDC = (Get-ADDomain (Get-ADDomainController).Forest | Select-Object PDCEmulator).PDCEmulator
$Forest = (Get-ADDomain).Forest
$ForestNetBiosName = (Get-ADDomain $Forest).NetBIOSName
$ForestbaseDN = (Get-ADDomain $Forest).DistinguishedName
$DomainController = $env:COMPUTERNAME
$DomainNetBiosName = (Get-ADDomain).NetBIOSName
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
  [string]$reportFilePath = "\\$Domain\NETLOGON\Reports\PsStaleObjects"
    
  if($importedValues.valuename -contains "reportFilePath"){[string]$reportFilePath = ($importedValues | Where-Object{$_.ValueName -eq "reportFilePath"}).Value}

#Query
  # DistinguishedNames of the OUs to query - if this is $null, the query will fail and there will be no result. Values should be comma separated.
  [array]$script:searchBaseDNs = 
  "$baseDN"

  if($importedValues.valuename -contains "searchBaseDNs"){[array]$script:searchBaseDNs = (($importedValues | Where-Object{$_.ValueName -eq "searchbaseDNs"}).Value).Split(";") | ForEach-Object {$_.TrimStart()}}

#Exemptions
  #DistinguishedName exemptions - objects in these OU structure will be auto exempted by location
  [array]$script:autoExemptDistinguishedNames = 
  "CN=Users,$baseDN",
  "OU=Domain Controllers,$baseDN"
      
if($importedValues.valuename -contains "autoExemptDistinguishedNames"){[array]$script:autoExemptDistinguishedNames = (($importedValues | Where-Object{$_.ValueName -eq "autoExemptDistinguishedNames"}).Value).Split(";") | ForEach-Object {$_.TrimStart()}} 

#User Object SamAccountName exemption prefix - SamAccountNames that are "-like" the list below will be auto exempt
  [array]$script:autoExemptPrefix =
  "svc.",
  "svc0."
    
  if($importedValues.valuename -contains "autoExemptPrefix"){[array]$script:autoExemptPrefix = (($importedValues | Where-Object{$_.ValueName -eq "autoExemptPrefix"}).Value).Split(";") | ForEach-Object {$_.TrimStart()}}

# Hard Exemptions
#if there are one or more exemption groups, add them here.
  [array]$script:exemptionGroups = 
  "$domainNetBIOSName IA - Stale Computer Exemption",
  "$domainNetBIOSName IA - Stale User Exemption"
      
  if($importedValues.valuename -contains "exemptionGroups"){[array]$script:exemptionGroups = (($importedValues | Where-Object{$_.ValueName -eq "exemptionGroups"}).Value).Split(";") | ForEach-Object {$_.TrimStart()}}

#if there are one or more exemption CSVs, add them here. 
#- The requirement is column A on the CSV should be titled "samAccountName" and contain the exempt object samAccountNames.
#[array]$exemptionCSVs = "$scriptFilePath\exemptionTest.csv"

#StaleObjectFilter 
  # Last-Logon-Timestamp attribute is compared against number of days set here.  
  # STIG states 35 days as the stale account time
  # lastLogonTimestamp is updated when the value on the authenticating DC is greater 14 days minus random percentage of 5 days.
  # http://msdn.microsoft.com/en-us/library/ms676824(VS.85).aspx
  # To be safe, give a 14 day grace period
  [int]$script:lastLogonTimestampFilter = 35

  if($importedValues.valuename -contains "lastLogonTimestampFilter"){[int]$script:lastLogonTimestampFilter = ($importedValues | Where-Object{$_.ValueName -eq "lastLogonTimestampFilter"}).Value}
	
#Exempt SVC Account pwdAgeFilter
  #If an account is determined as exempt based on an "svc.*" prefix match, it will then have its pwdLastSet age compared to this filter to determine if it is stale
  [int]$script:pwdAgeLimitDays = (365 + $lastLogonTimestampFilter)

  if($importedValues.valuename -contains "pwdAgeLimitDays"){[int]$script:pwdAgeLimitDays = ($importedValues | Where-Object{$_.ValueName -eq "pwdAgeLimitDays"}).Value}

#Stale object description prefix
  #This string is put in front of the existing description on objects modified in the modify phase
  [string]$staleDescriptionPrefix = "STALE OBJECT ; "
  
  if($importedValues.valuename -contains "staleDescriptionPrefix"){[string]$staleDescriptionPrefix = ($importedValues | Where-Object{$_.ValueName -eq "staleDescriptionPrefix"}).Value}

#email Related

  $script:smtpServer  = "DCMETSMTP001.RES.DS.A1"
  if($importedValues.valuename -contains "smtpServer"){[string]$script:smtpServer = ($importedValues | Where-Object{$_.ValueName -eq "smtpServer"}).Value}
  
  $script:messageFrom = "doNotReply@a1its.org"
  if($importedValues.valuename -contains "messageFrom"){[string]$script:messageFrom = ($importedValues | Where-Object{$_.ValueName -eq "messageFrom"}).Value}
  
  [string[]]$script:cc = "active-directory-management@a1its.org"
  if($importedValues.valuename -contains "bcc"){[array]$script:cc = (($importedValues | Where-Object{$_.ValueName -eq "cc"}).Value).Split(";") | ForEach-Object {$_.TrimStart()}}
  
#endregion UserDeclaredVariables

switch ($phase) {

  Query { Write-Host "Query Phase"
	
    [array]$report = zStale-Query
			
    #Write Output
	if ($report){	
    #Report
    $report | select class,Exempt,Flag,Enabled,LastLogonTimestamp,Note,Name,SamAccountName,description,path,ScriptAction,Created,GUID,mail,pwdLastSet,info,OS | Export-Excel -AutoFilter -AutoSize -FreezeTopRow -Path ($reportFilePath + "\StaleObjects-QueryPhase-" + $runDate + ".xlsx")
			
    #Working Report	
    $report | select class,Exempt,Flag,Enabled,LastLogonTimestamp,Note,Name,SamAccountName,description,path,ScriptAction,Created,GUID,mail,pwdLastSet,info,OS | Export-Excel -AutoFilter -AutoSize -FreezeTopRow -Path ($reportFilePath + "\WorkingData.xlsx")
			
    #RunLog
    "$RunDate Phase: QueryPhase ; ReportCount: " + $report.Count + " ; ErrorCount: $errorCount"  | Out-File -FilePath $runLog -Append -Encoding ASCII	}		
  }
	
  Modify { Write-Host "Modify Phase"
	
    #Import WorkingData from query phase
    [array]$workingDataGuid = $null
    [array]$workingDataGuid = (Import-Excel "$reportFilePath\WorkingData.xlsx").guid
		
    if($workingDataGuid -eq $null){
		
      Write-Host "Unable to import `"WorkingData.xlsx`", stopping script" -BackgroundColor Red 
      "$runDate ModifyPhase ; Attempted Action: Import Working Data " | Out-File -FilePath $errorLog -Append -Encoding ASCII
      $errorCount + 1
      "$RunDate Phase: ModifyPhase ; FailedRun - No Import ; ErrorCount: $errorCount"  | Out-File -FilePath $runLog -Append -Encoding ASCII
      Exit 
    }
		
    #Validate still stale
	
    #Run Stale Objects Queries
    [array]$report = $null
    [array]$report = zStale-Query
			
    [array]$toModify = $null	
    [array]$toModify = $report | where{$workingDataGuid -contains $_.guid} | where{$_.Exempt -ne "Yes"}
			
    #Modify Description
    foreach($object in $toModify){
			
      [string]$newDescription = $null
      $newDescription = $staleDescriptionPrefix + $object.description
				
      Try{
        Set-ADObject $object.GUID -Description $newDescription 
        $object.scriptAction = $object.scriptAction + " Changed Description ;"
      }Catch [system.exception]{
        $exception = $_.exception.message.toString()
        Try{
          $object.scriptAction = $object.scriptAction + " Failed to change description ;"
          "$runDate SamAccountName:`'" + $object.SamAccountName + "`' ; Attempted Action: Modify Description ;  Error: " + $exception | Out-File -FilePath $errorLog -Append -Encoding ASCII
          $errorCount = $errorCount + 1
        }
        Catch{
          #do nothing
        }
      }
				
      #Disable Object	
      if($object.enabled -eq $true){
					
        Try{
          Disable-ADAccount $object.GUID
          $object.scriptAction = $object.scriptAction + " Disabled Object ;"
						
        }Catch [system.exception]{
          $exception = $_.exception.message.toString()
          Try{
            $object.scriptAction = $object.scriptAction + " Failed to disable object ;"
            "$runDate SamAccountName:`'" + $object.SamAccountName + "`' ; Attempted Action: Disable Object ;  Error: " + $exception | Out-File -FilePath $errorLog -Append -Encoding ASCII
            $errorCount = $errorCount + 1
          }
          Catch{
            #do nothing
          }
        }			
      }
			
      #Send email
			
      [string[]]$emailTo = $null
      [string[]]$emailTo = $object.mail
      if($emailTo.count -gt 0){
      write-host $emailto
        zSend-Emails -emailAccountName "accountName" -emailSamAccountName "accountSamAccountName" -emailTo $emailTo -accountName $object.Name -samAccountName $object.SamAccountName -domain $domain
      }
				
    }	
			
    #Write Output
	if ($toModify){	
    #Report
    $toModify | select class,Exempt,Flag,Enabled,LastLogonTimestamp,Note,Name,SamAccountName,description,path,ScriptAction,Created,GUID,mail,pwdLastSet,info,OS | Export-Excel -AutoFilter -AutoSize -FreezeTopRow -Path ($reportFilePath + "\StaleObjects-ModifyPhase-" + $runDate + ".xlsx")
				
    #Working Report	
    $toModify | select class,Exempt,Flag,Enabled,LastLogonTimestamp,Note,Name,SamAccountName,description,path,ScriptAction,Created,GUID,mail,pwdLastSet,info,OS | Export-Excel -AutoFilter -AutoSize -FreezeTopRow -Path ($reportFilePath + "\WorkingData.xlsx")			
			
    #RunLog
    "$RunDate Phase: ModifyPhase ; Modify Count: " + $toModify.Count + " ; ErrorCount: $errorCount"  | Out-File -FilePath $runLog -Append -Encoding ASCII	}
  }

  Delete { Write-Host "Delete Phase"
	
    #Import WorkingData from query phase
    [array]$workingDataGuid = $null
    [array]$workingDataGuid = (Import-Excel "$reportFilePath\WorkingData.xlsx").guid
		
    if($workingDataGuid -eq $null){
		
      Write-Host "Unable to import `"WorkingData.csv`", stopping script" -BackgroundColor Red 
      "$runDate DeletePhase ; Attempted Action: Import Working Data " | Out-File -FilePath $errorLog -Append -Encoding ASCII
      $errorCount + 1
      "$RunDate Phase: DeletePhase ; FailedRun - No Import ; ErrorCount: $errorCount"  | Out-File -FilePath $runLog -Append -Encoding ASCII			
      Exit 
    }
		
    #Validate still stale
	
    #Run Stale Objects Queries
    [array]$report = $null
    [array]$report = zStale-Query
			
    [array]$toDelete = $null	
    [array]$toDelete = $report | where{$workingDataGuid -contains $_.guid}	
			
    $toDelete = $toDelete | where{$_.Enabled -eq $false}
    $toDelete = $toDelete | where{$_.Description -like "$staleDescriptionPrefix*"}
    $toDelete = $toDelete | where{$_.Exempt -ne "Yes"}
		
    #Delete
		
    foreach($object in $toDelete){
		
      Try{
        Remove-ADObject $object.GUID -Confirm:$false -Recursive
        $object.scriptAction = $object.scriptAction + " Deleted Object ;"
      }Catch [system.exception]{
        $exception = $_.exception.message.toString()
        Try{
          $object.scriptAction = $object.scriptAction + " Failed to delete object ;"
          "$runDate SamAccountName:`'" + $object.SamAccountName + "`' ; Attempted Action: Delete Object ;  Error: " + $exception | Out-File -FilePath $errorLog -Append -Encoding ASCII
          $errorCount = $errorCount + 1
        }
        Catch{
          #do nothing
        }
      }				
    }
			
    #Fix descriptions on objects that are no longer considered Stale	
	
    [array]$toFix = (Import-Excel "$reportFilePath\WorkingData.xlsx").guid
			
    [array]$stillExistsToFix = $null
			
    foreach($guid in $toFix){
      Try{
        $object = $null
        $object = Get-ADObject $guid -Properties description | where{$_ -ne $null} | where {$_.description -like "$staleDescriptionPrefix*"} 
        $newDescription = $object.Description -replace $staleDescriptionPrefix,""
        if($newDescription -eq ""){
          $newDescription = " "
        }
        Set-ADObject -Identity $object.ObjectGUID -Description $newDescription

      }Catch{
        #do nothing
      }
    }		
	
    #Write Output
	if($toDelete){		
    #Report
    $toDelete | select class,Exempt,Flag,Enabled,LastLogonTimestamp,Note,Name,SamAccountName,description,path,ScriptAction,Created,GUID,mail,pwdLastSet,info,OS | Export-Excel -AutoFilter -AutoSize -FreezeTopRow -Path  ($reportFilePath + "\StaleObjects-DeletePhase-" + $runDate + ".xlsx")
			
    #RunLog
    "$RunDate Phase: DeletePhase ; Delete Count: " + $toDelete.Count + " ; ErrorCount: $errorCount"  | Out-File -FilePath $runLog -Append -Encoding ASCII	}
  }
	
  Default { Write-Host "I have no idea what I am doing"
	
    #RunLog
    "$RunDate Phase: I have no idea what I am doing"  | Out-File -FilePath $runLog -Append -Encoding ASCII
  }
}



		






# SIG # Begin signature block
# MIISEwYJKoZIhvcNAQcCoIISBDCCEgACAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUSuEdV7/9m8nUl2gTBJ4TuqrQ
# 5ZCggg9rMIIHsTCCBZmgAwIBAgITNQAAACFv8bfVN7E2EQAAAAAAITANBgkqhkiG
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
# IwYJKoZIhvcNAQkEMRYEFKVEmDjy/cwYShNeHiiycJG+QK84MA0GCSqGSIb3DQEB
# AQUABIIBAHShzQvUEoCZ+U1XSVe5P+DckcTjf/TZ0Jaei07CeAPelqKmwrR4m0e2
# r/qSti4BdGF6OGToxXGHIGIzHmYgRQ6fY/c8V7SCaG6EBHrDy8hOb5hHg63qOihw
# AzbL6ky819OF0rqqxyIIS6fmTPuJUr8zev4aVMoU8kjpwk8L8xMxUI8lKxHNc45i
# JFAch2i5FXbxfm0jH+kzb+VwLzdt1nknhbGYovuNQcEjiWZIhAa2Yn+C+zBhe3e7
# e+KLbU9dtCT5HfZP7LBuyVZfbTmc+T/rGANtR0lh0Zx8plLCXSO1tAn3uy5DmJX2
# OQCyfY5XuZNfBvxfUl35KQVLcmEMyKA=
# SIG # End signature block
