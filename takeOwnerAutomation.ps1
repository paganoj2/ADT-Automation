<#
    .SYNOPSIS

    .DESCRIPTION
    Takes ownership of objects via a service account that has already been granted full control.  Any non standard permissions are removed from objects.  This 
    helps prevent anyone that has either been granted permissions through object creation, or other means from circumventing the delegation model.

    .NOTES

    File Name  : TakeOwnershipFixPermissions.ps1
    Author     : Tyler Guertin
    Contact    : tguertin@outlook.com
    Requires   : PowerShell Version 3.0 with Active Directory Modules
				
				
    .EXAMPLE

    Version:
    001 - 2016/09/26 - Someone finally cared enough about me to write this header.
    + Exemptions group is no longer a recursive query
    + Set path to C: before writing reports.

    2016-12-08 - Did an overhaul of the script.  Enough to count as a new version.  
    + Logging added
    + Fixed issue with group names containing "/"
	 
    2016-12-13 - Added variables $eventLogname, $eventLogSource
    
    2017-08-21 - Script now writes a csv of import values to the reportFilePath location.

    2017-08-25 - Added Date Flagged Report

#>

#This should only run on the domain PDC, get the current domain PDC and check if currently on the domain PDC.

$CurrentDC = (Get-ADDomainController -Identity $env:COMPUTERNAME).HostName
$PDC = (Get-ADDomain | Select-Object -Property PDCEmulator).PDCEmulator
if ($CurrentDC -ne $PDC){

#Current Domain Controller isn't the PDC, exit...
exit

}

#region TokenAdjuster

Try {
            [void][TokenAdjuster]
        } Catch {
            $AdjustTokenPrivileges = @"
            using System;
            using System.Runtime.InteropServices;

             public class TokenAdjuster
             {
              [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
              internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall,
              ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
              [DllImport("kernel32.dll", ExactSpelling = true)]
              internal static extern IntPtr GetCurrentProcess();
              [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
              internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr
              phtok);
              [DllImport("advapi32.dll", SetLastError = true)]
              internal static extern bool LookupPrivilegeValue(string host, string name,
              ref long pluid);
              [StructLayout(LayoutKind.Sequential, Pack = 1)]
              internal struct TokPriv1Luid
              {
               public int Count;
               public long Luid;
               public int Attr;
              }
              internal const int SE_PRIVILEGE_DISABLED = 0x00000000;
              internal const int SE_PRIVILEGE_ENABLED = 0x00000002;
              internal const int TOKEN_QUERY = 0x00000008;
              internal const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;
              public static bool AddPrivilege(string privilege)
              {
               try
               {
                bool retVal;
                TokPriv1Luid tp;
                IntPtr hproc = GetCurrentProcess();
                IntPtr htok = IntPtr.Zero;
                retVal = OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
                tp.Count = 1;
                tp.Luid = 0;
                tp.Attr = SE_PRIVILEGE_ENABLED;
                retVal = LookupPrivilegeValue(null, privilege, ref tp.Luid);
                retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
                return retVal;
               }
               catch (Exception ex)
               {
                throw ex;
               }
              }
              public static bool RemovePrivilege(string privilege)
              {
               try
               {
                bool retVal;
                TokPriv1Luid tp;
                IntPtr hproc = GetCurrentProcess();
                IntPtr htok = IntPtr.Zero;
                retVal = OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
                tp.Count = 1;
                tp.Luid = 0;
                tp.Attr = SE_PRIVILEGE_DISABLED;
                retVal = LookupPrivilegeValue(null, privilege, ref tp.Luid);
                retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
                return retVal;
               }
               catch (Exception ex)
               {
                throw ex;
               }
              }
             }
"@
            Add-Type $AdjustTokenPrivileges
        }

        #Activate necessary admin privileges to make changes without NTFS perms
        [void][TokenAdjuster]::AddPrivilege("SeRestorePrivilege") #Necessary to set Owner Permissions
        [void][TokenAdjuster]::AddPrivilege("SeBackupPrivilege") #Necessary to bypass Traverse Checking
        [void][TokenAdjuster]::AddPrivilege("SeTakeOwnershipPrivilege") #Necessary to override FilePermissions

#endregion TokenAdjuster

#region Functions

Import-Module ActiveDirectory
Import-Module \\DS.A1\NETLOGON\ENT\Modules\ImportExcel

Function Create-CustomACEObject{
  Param (
    [Parameter(Mandatory=$true)]
    [array]$ace		
  )
		
  $aceObjectType = ""
  $aceObjectType = $ace.objectTypeName.ToString()

  $hash = New-Object System.Collections.Specialized.OrderedDictionary
  $hash.Add("Name",$ace.Name.ToString())
  $hash.Add("DistinguishedName",$ace.DistinguishedName.ToString())
  $hash.Add("Path","")
  $hash.Add("Flag","")
  $hash.Add("ObjectTypeName",$aceObjectType)
  $hash.Add("ActiveDirectoryRights",$ace.ActiveDirectoryRights.ToString())
  $hash.Add("InheritanceType",$ace.InheritanceType.ToString())
  $hash.Add("ObjectType",$ace.ObjectType.ToString())
  $hash.Add("InheritedObjectType",$ace.InheritedObjectType.ToString())
  $hash.Add("ObjectFlags",$ace.ObjectFlags.ToString())
  $hash.Add("AccessControlType",$ace.AccessControlType.ToString())
  $hash.Add("IdentityReference",$ace.IdentityReference.Value)
  $hash.Add("IsInherited",$ace.IsInherited.ToString())
  $hash.Add("InheritanceFlags",$ace.InheritanceFlags.ToString())
  $hash.Add("PropagationFlags",$ace.PropagationFlags.ToString())
  $object = New-Object PSObject -Property $hash
		
  return $object

}

Function Create-CustomReportObject ($object){
	
  $ReportObject = New-Object PSObject
  #		$ReportObject | Add-Member -MemberType NoteProperty -Name "rundate" -Value $local:runDate
  $ReportObject | Add-Member -MemberType NoteProperty -Name "type" -Value ""
  $ReportObject | Add-Member -MemberType NoteProperty -Name "flag" -Value ""
  $ReportObject | Add-Member -MemberType NoteProperty -Name "name" -Value $object.name
  $ReportObject | Add-Member -MemberType NoteProperty -Name "oldOwner" -Value ""
  $ReportObject | Add-Member -MemberType NoteProperty -Name "newOwner" -Value ""
  $ReportObject | Add-Member -MemberType NoteProperty -Name "created" -Value $object.created	
  $ReportObject | Add-Member -MemberType NoteProperty -Name "path" -Value ""
  $ReportObject | Add-Member -MemberType NoteProperty -Name "distinguishedName" -Value $object.distinguishedName
  $ReportObject | Add-Member -MemberType NoteProperty -Name "objectGUID" -Value ($object.ObjectGUID.Guid)		
  $ReportObject.path = ((($object.CanonicalName).split("/"))[1..((($object.CanonicalName).split("/")).count-2)] -join "/")
		
  return $reportObject
}


Function Create-unknownObjectReportObject ($object){
	
  $ReportObject = New-Object PSObject
  #		$ReportObject | Add-Member -MemberType NoteProperty -Name "rundate" -Value $local:runDate
  $ReportObject | Add-Member -MemberType NoteProperty -Name "type" -Value ""
  $ReportObject | Add-Member -MemberType NoteProperty -Name "flag" -Value ""
  $ReportObject | Add-Member -MemberType NoteProperty -Name "name" -Value $object.name
  $ReportObject | Add-Member -MemberType NoteProperty -Name "oldOwner" -Value ""
  $ReportObject | Add-Member -MemberType NoteProperty -Name "newOwner" -Value ""
  $ReportObject | Add-Member -MemberType NoteProperty -Name "created" -Value $object.created	
  $ReportObject | Add-Member -MemberType NoteProperty -Name "path" -Value ""
  $ReportObject | Add-Member -MemberType NoteProperty -Name "distinguishedName" -Value $object.distinguishedName
  $ReportObject | Add-Member -MemberType NoteProperty -Name "objectGUID" -Value ($object.ObjectGUID.Guid)		
  $ReportObject.path = 'unknown'
		
  return $reportObject
}

#endregion Functions


#region Custom Variables

$Domain = (Get-ADDomain).DNSRoot
$baseDN = (Get-ADDomain $domain).DistinguishedName
$ForestDC = (Get-ADDomain (Get-ADDomainController).Forest | Select-Object PDCEmulator).PDCEmulator
$Forest = (Get-ADDomain).Forest
$ForestNetBiosName = (Get-ADDomain $Forest).NetBIOSName
$ForestbaseDN = (Get-ADDomain $Forest).DistinguishedName
$DomainController = $env:COMPUTERNAME
$DomainNetBiosName = (Get-ADDomain).NetBIOSName

#Script file path for save CSV, error log, and queryphase data file to be used for action scripts.


[string]$scriptFilePath = Split-Path -parent $MyInvocation.MyCommand.Definition # directory the script is running from.

# Import values from CSV file, this is to assist with cross domain and cross network script migration.
#region Import Values
	
#	do not provide a value for $importValuePath if you do not want this functionality.
[String]$importValuePath = $null
[array]$importedValues = $null
			
#endregion Import Values	
	
#Output
#ReportFilePath
[string]$reportFilePath = "\\$Domain\NETLOGON\Reports\takeOwner"

#LocalOutputFilePath
[string]$outputFilePath = "$scriptFilePath\Output"

#Object Types to Check
#Computers
[bool]$checkComputers = $true
#Users	  
[bool]$checkUsers = $true
#gMSAs
[bool]$checkgMSAs = $true
#Groups	  
[bool]$checkGroups = $true
#unkownObjects
[bool]$checkunknown0bjects = $true


#Modify ownership
[bool]$modifyOwnership = $true
	
#Remove non-standard ACEs 
[bool]$removeAces = $true

#Exemptions only apply to the permissions and inheritance portion, not ownership.
#Exemption groups 
[array]$exemptionGroups = 
"$DomainNetBiosName IA - Permissions Auditor Exemptions",
"Domain Admins"

if($domain -eq $forest){[array]$exemptionGroups += 
"Enterprise Admins",
"Schema Admins"
}
# DistinguishedName Exemptions
[array]$exemptionDNs =
"OU=Administrative-Groups,OU=Administration,OU=_Domain Administration,$baseDN",
"OU=Administrative-Groups,OU=Administration,OU=_Enterprise Administration,$ForestbaseDN"
"OU=Domain Controllers,$baseDN"

#Who the owner should be
[string]$desiredOwner_SamAccountName = "Domain Admins"

#verbose logging
[bool]$verboseLog = $true

#dateFlagged logging
[bool]$dateFlaggedLogging = $true

#flagableDateRangeInDays
[int]$flagableDateRangeInDays = 3

# The domain name that comes before the \ in a down-level logon name
[string]$downLevelLogonNameDomain = "$DomainNetBiosName"	

# OU DistinguishedNames to target for queries
[array]$targetOuDns = Get-ADOrganizationalUnit -Filter *

# DC to target
[string]$dc = (Get-ADDomainController -Filter * | Where-Object {$_.OperationMasterRoles -like "PDCEmulator"}).HostName
				
# Identity references that will be ignored for computer objects 
[array]$wellKnownForComputerObjects =
"$downLevelLogonNameDomain\Cert Publishers",
"$downLevelLogonNameDomain\Domain Admins",
"NT AUTHORITY\SELF",
"NT AUTHORITY\SYSTEM",
"S-1-5-32-548",  # "Account Operators"}                                                                                                                                                                                                                                                                                                                                                                                                   
"S-1-5-32-550",  # "Printer Operators"}     
"S-1-5-32-560" # "BUILTIN\Windows Authorization Access Group"

# Identity references that will be ignored for unknown objects
[array]$wellKnownForunknownObjects =
"$downLevelLogonNameDomain\Cert Publishers",
"$downLevelLogonNameDomain\Domain Admins",
"NT AUTHORITY\SELF",
"NT AUTHORITY\SYSTEM",
"S-1-5-32-548",  # "Account Operators"}                                                                                                                                                                                                                                                                                                                                                                                                   
"S-1-5-32-550",  # "Printer Operators"}     
"S-1-5-32-560" # "BUILTIN\Windows Authorization Access Group"
	
# Identity references that will be ignored for user objects 
[array]$wellKnownForUserObjects =
"$downLevelLogonNameDomain\Cert Publishers",
"$downLevelLogonNameDomain\Domain Admins",
"$downLevelLogonNameDomain\RAS and IAS Servers",
"NT AUTHORITY\SELF",
"NT AUTHORITY\SYSTEM",
"S-1-5-32-548",  # "Account Operators"}     
"S-1-5-32-560", # "BUILTIN\Windows Authorization Access Group"
"S-1-5-32-561" #BUILTIN\Terminal Server License Servers

# Identity references that will be ignored for gMSA objects 
[array]$wellKnownForgMSAObjects =
"$downLevelLogonNameDomain\Cert Publishers",
"$downLevelLogonNameDomain\Domain Admins",
"$downLevelLogonNameDomain\RAS and IAS Servers",
"NT AUTHORITY\SELF",
"NT AUTHORITY\SYSTEM",
"S-1-5-32-548",  # "Account Operators"}     
"S-1-5-32-560", # "BUILTIN\Windows Authorization Access Group"
"S-1-5-32-561" #BUILTIN\Terminal Server License Servers

# Identity references that will be ignored for group objects 
[array]$wellKnownForGroupObjects = 
"$downLevelLogonNameDomain\Domain Admins",
#		"NT AUTHORITY\SELF",
"NT AUTHORITY\SYSTEM",
"S-1-5-32-548",  # "Account Operators"}     
"S-1-5-32-560" # "BUILTIN\Windows Authorization Access Group"


#endregion Custom Variables

#region Script Config

#Test writing to eventlog

#Test Target OU DNs
"Testing Target OU DNs:" | Out-Host
foreach($dn in  $targetOuDns){
  Try{
    "   " + (get-adobject -Identity $dn).distinguishedName | Out-Host
  }Catch{
    "   Exemption DN path not found: $dn" | Out-Host
    "   Writing event and terminating script." | Out-Host
    ############################################################################ EXIT
    "     ########################################## EXIT due to bad input variable" | Out-Host
    Exit
  }
}

#rundate for report
[string]$runDate = (Get-Date).tostring("yyy.MM.dd_HH.mm.tt")
Set-Variable $runDate -Scope "local"

[string]$whoTheOwnerShouldBe = "$downLevelLogonNameDomain\$desiredOwner_SamAccountName"

#Who to change owner to if current owner is not correct
$adminRightsObject = $null
Try{  
  $adminRightsObject = Get-ADUser -Identity "$desiredOwner_SamAccountName" -Server $DC
 # $whoTheOwnerShouldBe = (Get-ADUser $desiredOwner_SamAccountName).samAccountName
}Catch{
  #silentlyContinue
}
    
#if failed to find a user, try a gmsa
if(!($adminRightsObject)){
  Try{
    $adminRightsObject = Get-ADServiceAccount -Identity "$desiredOwner_SamAccountName" -Server $DC -ErrorAction SilentlyContinue
  #  $whoTheOwnerShouldBe = (Get-ADServiceAccount $desiredOwner_SamAccountName).samAccountName
  }Catch{
    #silently continue
  }
}
 
    
#if failed to find a user and gmsa, try a group
if(!($adminRightsObject)){
  Try{
    $adminRightsObject = Get-ADGroup -Identity "$desiredOwner_SamAccountName" -Server $DC -ErrorAction SilentlyContinue
  #  $whoTheOwnerShouldBe = (Get-ADGroup $desiredOwner_SamAccountName).samAccountName
  }Catch{
    #silently continue
  }
}
 
#if unable to resolve user or group and change ownership is flagged, exit script.
if(!($adminRightsObject) -and ($modifyOwnership -eq $true)){
  Write-Output "Unable to resolve `$desiredOwner_SamAccountName $desiredOwner_SamAccountName and modifyOwnership is flagged TRUE. Exiting script."
  Exit
  ######################################################################### EXIT
}   
$adminRightsObjectSID = $adminRightsObject.SID

# Set AD path to specified DC
if(!((Get-Location).Path -eq "PreferedDC:\")){
  $null = New-PSDrive -Name PreferedDC -PSProvider ActiveDirectory -Server $dc -Scope Global -root "//RootDSE/"
  Set-Location PreferedDC:
}
	
$report = New-Object System.Collections.Generic.List[object]
$verboseLogReport = New-Object System.Collections.Generic.List[object]
	
$schemaIDGUID = @{}
$ErrorActionPreference = 'SilentlyContinue'
Get-ADObject -SearchBase (Get-ADRootDSE).schemaNamingContext -LDAPFilter '(schemaIDGUID=*)' -Properties name, schemaIDGUID |
ForEach-Object {$schemaIDGUID.add([System.GUID]$_.schemaIDGUID,$_.name)}
Get-ADObject -SearchBase "CN=Extended-Rights,$((Get-ADRootDSE).configurationNamingContext)" -LDAPFilter '(objectClass=controlAccessRight)' -Properties name, rightsGUID |
ForEach-Object {$schemaIDGUID.add([System.GUID]$_.rightsGUID,$_.name)}
$ErrorActionPreference = 'Continue'
	
# Gather exemption group exemptions
[array]$exemptions = foreach($group in $exemptionGroups){Get-ADGroupMember -Identity $group}
$exemptions = $exemptions | Sort-Object -Unique
	
# Gather distinguished name exemptions
$exemptions += foreach($dn in $exemptionDNs){Get-ADObject -SearchBase $dn -Filter *}
$exemptions = $exemptions | Sort-Object -Unique

#endregion Script Config


[int]$befounknownObjects =  [math]::Round(((Get-Process -Id $pid).ws / 1MB),2)

if($checkunknown0bjects){
New-PSDrive -Name ADDOM -PSProvider ActiveDirectory -Server $Domain -Scope Global -Root "//ROOTDSE/" | Out-Null

foreach($dn in $targetOUDns){
$unknownObjectsToCheck += Get-ADObject -Filter * -SearchBase $dn -Properties objectClass,created | Where {$_.objectClass -eq $null}
}
  $unknownObjectsToCheck = $unknownObjectsToCheck | Sort-Object -Unique
  $unknownObjectsToCheck = $unknownObjectsToCheck | Where-Object -FilterScript {$exemptions.ObjectGuid -notcontains $_.ObjectGuid}

  foreach($unknownObject in $unknownObjectsToCheck){



				
      $reportObject = $null
      $reportObject = Create-unknownObjectReportObject $unknownObject
      $reportObject.oldOwner = 'unknown'
      $reportObject.type = "OwnerunknownObject"
      $reportObject.path = 'unknown' 



        if($modifyOwnership){
				
    $acl = get-acl -Path "ADDOM:CN=Users,$baseDN"
    $acl.SetOwner([Security.Principal.NTaccount]($whoTheOwnerShouldBe))
    Start-Sleep -s 2
    $DN = $unknownObject.DistinguishedName
        try{
        set-acl -Path ADDOM:$DN -AclObject $acl
        $reportObject.newOwner = $whoTheOwnerShouldBe
        }catch{
          $ReportObject.flag= "failed"
        }				
      }
				
      $report.Add($reportObject)
    

    #endregion check unknown object Owner
    

    $null = dsacls $unknownObject.distinguishedName /resetdefaultDACL
    
      }

          	#region reset permissions to baseline.

         



}

[int]$afterunknownObjects =  [math]::Round(((Get-Process -Id $pid).ws / 1MB),2)

[int]$beforeComputers =  [math]::Round(((Get-Process -Id $pid).ws / 1MB),2)

if($checkComputers){	

  #region Computer Objects

  [array]$computerObjectsToCheck = $null
  foreach($dn in $targetOuDns){
    $computerObjectsToCheck += Get-ADComputer -Filter * -SearchBase $dn -SearchScope Subtree -Properties canonicalName,created
  }
  $computerObjectsToCheck = $computerObjectsToCheck | Sort-Object -Unique
  $computerObjectsToCheck = $computerObjectsToCheck | Where-Object -FilterScript {$exemptions.ObjectGuid -notcontains $_.ObjectGuid}

  foreach($computer in $computerObjectsToCheck){
		
    #region Check Computer Permissions	
		
    [array]$customAces = $null
    [array]$computerAces = $null
    [array]$baseLine = $null
    [array]$computerAces = (((Get-Acl -Path ("AD:\" + $computer.DistinguishedName) | `
          Select-Object -ExpandProperty Access | `
          where{$wellKnownForComputerObjects -notcontains $_.IdentityReference} | `
          Select-Object @{name='Name';expression={$computer.Name}}, `
          @{name='DistinguishedName';expression={$computer.DistinguishedName}}, `
          @{name='Path';expression={""}}, `
          @{name='Flag';expression={""}}, `
          @{name='objectTypeName';expression={if ($_.objectType.ToString() -eq '00000000-0000-0000-0000-000000000000') {'All'} Else {$schemaIDGUID.Item($_.objectType)}}}, `
    * )))    
		
    $customAces = $computerAces | where{$_.IsInherited -ne "True"} | %{Create-CustomACEObject $_}

							
    #region Computer Baseline
						
    #NT AUTHORITY\Authenticated Users - GenericRead
    $hash = New-Object System.Collections.Specialized.OrderedDictionary
    $hash.Add("Name",$computer.Name)
    $hash.Add("DistinguishedName",$computer.DistinguishedName)
    $hash.Add("Path","")
    $hash.Add("Flag","")
    $hash.Add("ObjectTypeName","All")
    $hash.Add("ActiveDirectoryRights","GenericRead")
    $hash.Add("InheritanceType","None")
    $hash.Add("ObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("InheritedObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("ObjectFlags","None")
    $hash.Add("AccessControlType","Allow")
    $hash.Add("IdentityReference","NT AUTHORITY\Authenticated Users")
    $hash.Add("IsInherited","False" )
    $hash.Add("InheritanceFlags","None" )
    $hash.Add("PropagationFlags","None")
    $object = New-Object PSObject -Property $hash
    $baseLine += $object
							
    #Everyone - User-Change-Password
    $hash = New-Object System.Collections.Specialized.OrderedDictionary
    $hash.Add("Name",$computer.Name)
    $hash.Add("DistinguishedName",$computer.DistinguishedName)
    $hash.Add("Path","")
    $hash.Add("Flag","")
    $hash.Add("ObjectTypeName","User-Change-Password")
    $hash.Add("ActiveDirectoryRights","ExtendedRight")
    $hash.Add("InheritanceType","None")
    $hash.Add("ObjectType","ab721a53-1e2f-11d0-9819-00aa0040529b")
    $hash.Add("InheritedObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("ObjectFlags","ObjectAceTypePresent")
    $hash.Add("AccessControlType","Allow")
    $hash.Add("IdentityReference","Everyone")
    $hash.Add("IsInherited","False" )
    $hash.Add("InheritanceFlags","None" )
    $hash.Add("PropagationFlags","None")
    $object = New-Object PSObject -Property $hash
    $baseLine += $object
						
    #endregion Computer Baseline
			
    #compare ACEs to baseline
    foreach($item in $baseLine){
      $customAces | where{$_ -like $item} | foreach{$_.Flag = "Matched"; $item.Flag = "Matched"}
    }	
				
    [array]$toRemove = $null
    $toRemove = $customAces | where {$_.flag -ne "Matched"} 
				
    if($verboseLog){
      foreach($customAceObject in $toRemove){
        $customAceObject.Path = ((($computer.CanonicalName).split("/"))[1..((($computer.CanonicalName).split("/")).count-2)] -join "/")
        $verboseLogReport.add($customAceObject)
      } 				
    }
				
    [string]$ldapDN = $null
    $ldapDN = "$dc/" + $computer.distinguishedName
    $ADObject = $null
    $ADObject =  [ADSI]("LDAP://" + $ldapDN)     
    [DirectoryServices.DirectoryEntryConfiguration]$SecOptions = $ADObject.get_Options();
    $SecOptions.SecurityMasks = [DirectoryServices.SecurityMasks]"Dacl"		

    $reportObject = $null
    $reportObject = Create-CustomReportObject $computer
    $reportObject.type = "Computer ACE Removal"
    $reportObject.path = ((($computer.CanonicalName).split("/"))[1..((($computer.CanonicalName).split("/")).count-2)] -join "/") 
			
			
    if($toRemove.count -ge 1){
      foreach($ace in $toRemove){
						
        $objectTypeGUID = (new-object Guid $ace.ObjectType)
        $inheritedTypeGUID = (new-object Guid $ace.InheritedObjectType)
						
        [array]$identityReference = ($computerAces | where {$_.IdentityReference -eq $ace.IdentityReference} | where{$_.ObjectType -eq $ace.ObjectType}  | where{$_.ObjectTypeName -eq $ace.ObjectTypeName} |  where{$_.AccessControlType -eq $ace.AccessControlType} |where{$_.ActiveDirectoryRights -eq $ace.ActiveDirectoryRights}).IdentityReference
        $aceToRemove = new-object System.DirectoryServices.ActiveDirectoryAccessRule ($identityReference[0]),($ace.ActiveDirectoryRights),($ace.AccessControlType),$objectTypeGUID,($ace.InheritanceType),$inheritedTypeGUID 

        $null = $ADObject.get_ObjectSecurity().RemoveAccessRule($aceToRemove)
      }	
      Try{
        if($removeAces){
          $ADObject.CommitChanges() 
        }	
      }Catch{
        $reportObject.flag = "failed"
      }
					
      $report.Add($reportObject)	
    }
	
    [array]$unmetBaseline = $null
    $unmetBaseline = $baseLine | where{$_.flag -ne "Matched"}
				
    if($unmetBaseline.count -ge 1){
      $reportObject = $null
      $reportObject = Create-CustomReportObject $computer
      $reportObject.type = "Computer Baseline"
      $reportObject.flag = "failed"
      $reportObject.path = ((($computer.CanonicalName).split("/"))[1..((($computer.CanonicalName).split("/")).count-2)] -join "/") 
      $report.Add($reportObject)
      $null = dsacls $computer.distinguishedName /resetDefaultDACL
    }
		
    #endregion Check Computer Permissions	
				
    #region Verify Inheritance
			
    if(($computerAces | where{$_.IsInherited -eq "True"}).count -lt 1){
      $reportObject = $null
      $reportObject = Create-CustomReportObject $computer
      $reportObject.type = "Inheritance"
      $reportObject.flag = "failed"
      $reportObject.path = ((($computer.CanonicalName).split("/"))[1..((($computer.CanonicalName).split("/")).count-2)] -join "/")
      $report.Add($reportObject)
      $null = dsacls $computer.distinguishedName /resetdefaultDACL
    }
		
    #endregion Verify Inheritance	

  }


  #endregion Computer Objects

}

[int]$afterComputers =  [math]::Round(((Get-Process -Id $pid).ws / 1MB),2)

if($checkUsers){

  #region User Objects

  [array]$allUserObjectsToCheck = $null
  foreach($dn in $targetOuDns){
	
    $allUserObjectsToCheck += Get-ADUser -Filter * -SearchBase $dn -SearchScope Subtree -Properties canonicalName,created
  }
  [array]$allUserObjectsToCheck = $allUserObjectsToCheck | Sort-Object -Unique
  $allUserObjectsToCheck = $allUserObjectsToCheck | Where-Object -FilterScript {$exemptions.ObjectGuid -notcontains $_.ObjectGuid}

  #region Check User Owner
	
  foreach($user in $allUserObjectsToCheck){
	
    [string]$currentOwner = $null
    $currentOwner = ((Get-Acl $user.distinguishedName).Owner)
    if($currentOwner -ne $whoTheOwnerShouldBe){
      #Does not have the correct owner, update owner
				
      $reportObject = $null
      $reportObject = Create-CustomReportObject $user
      $reportObject.oldOwner = $currentOwner
      $reportObject.type = "OwnerUser"
      $reportObject.path = ((($user.CanonicalName).split("/"))[1..((($user.CanonicalName).split("/")).count-2)] -join "/") 

      if($modifyOwnership){
				
        $ADObject =  [ADSI]("LDAP://$dc/" + ($user.distinguishedName -replace "/","\/"))     
        [DirectoryServices.DirectoryEntryConfiguration]$SecOptions = $ADObject.get_Options();
        $SecOptions.SecurityMasks = [DirectoryServices.SecurityMasks]"Owner"
        $ADObject.get_objectSecurity().SetOwner($adminRightsObjectSID)

        try{
          $ADObject.CommitChanges() 
          $reportObject.newOwner = $whoTheOwnerShouldBe
        }catch{
          $ReportObject.flag= "failed"
        }				
      }
				
      $report.Add($reportObject)
    }
		
  }		

  #endregion Check User Owner	
  #>	


  #region Check User Permissions

  foreach($user in $allUserObjectsToCheck){

    [array]$customAces = $null
    [array]$userAces = $null
    [array]$baseLine = $null
    [array]$userAces = (((Get-Acl -Path ("AD:\" + $user.DistinguishedName) | `
          Select-Object -ExpandProperty Access | `
          where{$wellKnownForUserObjects -notcontains $_.IdentityReference} | `
          Select-Object @{name='Name';expression={$user.Name}}, `
          @{name='DistinguishedName';expression={$user.DistinguishedName}}, `
          @{name='Path';expression={""}}, `
          @{name='Flag';expression={""}}, `
          @{name='objectTypeName';expression={if ($_.objectType.ToString() -eq '00000000-0000-0000-0000-000000000000') {'All'} Else {$schemaIDGUID.Item($_.objectType)}}}, `
    * )))   	
				
    $customAces = $userAces | where{$_.IsInherited -ne "True"} | %{Create-CustomACEObject $_}
		
    #region User Baseline
						
    #NT AUTHORITY\Authenticated Users - All : ReadControl 
    $hash = New-Object System.Collections.Specialized.OrderedDictionary
    $hash.Add("Name",$user.Name)
    $hash.Add("DistinguishedName",$user.DistinguishedName)
    $hash.Add("Path","")
    $hash.Add("Flag","")
    $hash.Add("ObjectTypeName","All")
    $hash.Add("ActiveDirectoryRights","ReadControl")
    $hash.Add("InheritanceType","None")
    $hash.Add("ObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("InheritedObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("ObjectFlags","None")
    $hash.Add("AccessControlType","Allow")
    $hash.Add("IdentityReference","NT AUTHORITY\Authenticated Users")
    $hash.Add("IsInherited","False" )
    $hash.Add("InheritanceFlags","None" )
    $hash.Add("PropagationFlags","None")
    $object = New-Object PSObject -Property $hash
    $baseLine += $object
						
    #NT AUTHORITY\Authenticated Users - General-Information : ReadProperty
    $hash = New-Object System.Collections.Specialized.OrderedDictionary
    $hash.Add("Name",$user.Name)
    $hash.Add("DistinguishedName",$user.DistinguishedName)
    $hash.Add("Path","")
    $hash.Add("Flag","")
    $hash.Add("ObjectTypeName","General-Information")
    $hash.Add("ActiveDirectoryRights","ReadProperty")
    $hash.Add("InheritanceType","None")
    $hash.Add("ObjectType","59ba2f42-79a2-11d0-9020-00c04fc2d3cf")
    $hash.Add("InheritedObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("ObjectFlags","ObjectAceTypePresent")
    $hash.Add("AccessControlType","Allow")
    $hash.Add("IdentityReference","NT AUTHORITY\Authenticated Users")
    $hash.Add("IsInherited","False" )
    $hash.Add("InheritanceFlags","None" )
    $hash.Add("PropagationFlags","None")
    $object = New-Object PSObject -Property $hash
    $baseLine += $object
						
    #NT AUTHORITY\Authenticated Users - Public Information : ReadProperty
    $hash = New-Object System.Collections.Specialized.OrderedDictionary
    $hash.Add("Name",$user.Name)
    $hash.Add("DistinguishedName",$user.DistinguishedName)
    $hash.Add("Path","")
    $hash.Add("Flag","")
    $hash.Add("ObjectTypeName","Public-Information")
    $hash.Add("ActiveDirectoryRights","ReadProperty")
    $hash.Add("InheritanceType","None")
    $hash.Add("ObjectType","e48d0154-bcf8-11d1-8702-00c04fb96050")
    $hash.Add("InheritedObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("ObjectFlags","ObjectAceTypePresent")
    $hash.Add("AccessControlType","Allow")
    $hash.Add("IdentityReference","NT AUTHORITY\Authenticated Users")
    $hash.Add("IsInherited","False" )
    $hash.Add("InheritanceFlags","None" )
    $hash.Add("PropagationFlags","None")
    $object = New-Object PSObject -Property $hash
    $baseLine += $object
						
    #NT AUTHORITY\Authenticated Users - Personal Information : ReadProperty
    $hash = New-Object System.Collections.Specialized.OrderedDictionary
    $hash.Add("Name",$user.Name)
    $hash.Add("DistinguishedName",$user.DistinguishedName)
    $hash.Add("Path","")
    $hash.Add("Flag","")
    $hash.Add("ObjectTypeName","Personal-Information")
    $hash.Add("ActiveDirectoryRights","ReadProperty")
    $hash.Add("InheritanceType","None")
    $hash.Add("ObjectType","77b5b886-944a-11d1-aebd-0000f80367c1")
    $hash.Add("InheritedObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("ObjectFlags","ObjectAceTypePresent")
    $hash.Add("AccessControlType","Allow")
    $hash.Add("IdentityReference","NT AUTHORITY\Authenticated Users")
    $hash.Add("IsInherited","False" )
    $hash.Add("InheritanceFlags","None" )
    $hash.Add("PropagationFlags","None")
    $object = New-Object PSObject -Property $hash
    $baseLine += $object						
						
    #NT AUTHORITY\Authenticated Users - Web-Information : ReadProperty
    $hash = New-Object System.Collections.Specialized.OrderedDictionary
    $hash.Add("Name",$user.Name)
    $hash.Add("DistinguishedName",$user.DistinguishedName)
    $hash.Add("Path","")
    $hash.Add("Flag","")
    $hash.Add("ObjectTypeName","Web-Information")
    $hash.Add("ActiveDirectoryRights","ReadProperty")
    $hash.Add("InheritanceType","None")
    $hash.Add("ObjectType","e45795b3-9455-11d1-aebd-0000f80367c1")
    $hash.Add("InheritedObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("ObjectFlags","ObjectAceTypePresent")
    $hash.Add("AccessControlType","Allow")
    $hash.Add("IdentityReference","NT AUTHORITY\Authenticated Users")
    $hash.Add("IsInherited","False" )
    $hash.Add("InheritanceFlags","None" )
    $hash.Add("PropagationFlags","None")
    $object = New-Object PSObject -Property $hash
    $baseLine += $object						
							
    #Everyone - User-Change-Password
    $hash = New-Object System.Collections.Specialized.OrderedDictionary
    $hash.Add("Name",$user.Name)
    $hash.Add("DistinguishedName",$user.DistinguishedName)
    $hash.Add("Path","")
    $hash.Add("Flag","")
    $hash.Add("ObjectTypeName","User-Change-Password")
    $hash.Add("ActiveDirectoryRights","ExtendedRight")
    $hash.Add("InheritanceType","None")
    $hash.Add("ObjectType","ab721a53-1e2f-11d0-9819-00aa0040529b")
    $hash.Add("InheritedObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("ObjectFlags","ObjectAceTypePresent")
    $hash.Add("AccessControlType","Allow")
    $hash.Add("IdentityReference","Everyone")
    $hash.Add("IsInherited","False" )
    $hash.Add("InheritanceFlags","None" )
    $hash.Add("PropagationFlags","None")
    $object = New-Object PSObject -Property $hash	
    $baseLine += $object
						
    #endregion User Baseline
							
    #compare ACEs to baseline
    foreach($item in $baseLine){
      $customAces | where{$_ -like $item} | foreach{$_.Flag = "Matched"; $item.Flag = "Matched"}
    }	
				
    [array]$toRemove = $null
    $toRemove = $customAces | where {$_.flag -ne "Matched"} 
				
    if($verboseLog){
      foreach($customAceObject in $toRemove){
        $customAceObject.Path = ((($user.CanonicalName).split("/"))[1..((($user.CanonicalName).split("/")).count-2)] -join "/")
        $verboseLogReport.add($customAceObject)
      } 
    }
				
    [string]$ldapDN = $null
    $ldapDN = "$dc/" + ($user.distinguishedName -replace "/","\/")
    $ADObject = $null
    $ADObject =  [ADSI]("LDAP://" + $ldapDN)     
    [DirectoryServices.DirectoryEntryConfiguration]$SecOptions = $ADObject.get_Options();
    $SecOptions.SecurityMasks = [DirectoryServices.SecurityMasks]"Dacl"		

    $reportObject = $null
    $reportObject = Create-CustomReportObject $user
    $reportObject.type = "User ACE Removal"
    $reportObject.path = ((($user.CanonicalName).split("/"))[1..((($user.CanonicalName).split("/")).count-2)] -join "/") 
			
		
    if($toRemove.count -ge 1){
      foreach($ace in $toRemove){
						
        $objectTypeGUID = (new-object Guid $ace.ObjectType)
        $inheritedTypeGUID = (new-object Guid $ace.InheritedObjectType)
						
        [array]$identityReference = ($userAces | where {$_.IdentityReference -eq $ace.IdentityReference} | where{$_.ObjectType -eq $ace.ObjectType}  | where{$_.ObjectTypeName -eq $ace.ObjectTypeName} |  where{$_.AccessControlType -eq $ace.AccessControlType} |where{$_.ActiveDirectoryRights -eq $ace.ActiveDirectoryRights}).IdentityReference
        $aceToRemove = new-object System.DirectoryServices.ActiveDirectoryAccessRule ($identityReference[0]),($ace.ActiveDirectoryRights),($ace.AccessControlType),$objectTypeGUID,($ace.InheritanceType),$inheritedTypeGUID 

        $null = $ADObject.get_ObjectSecurity().RemoveAccessRule($aceToRemove)
      }	
      Try{
        if($removeAces){
          $ADObject.CommitChanges() 
        }	
      }Catch{
        $reportObject.flag = "failed"
      }
					
      $report.Add($reportObject)	
    }
	
    [array]$unmetBaseline = $null
    $unmetBaseline = $baseLine | where{$_.flag -ne "Matched"}
				
    if($unmetBaseline.count -ge 1){
      $reportObject = $null
      $reportObject = Create-CustomReportObject $user
      $reportObject.type = "User Baseline"
      $reportObject.flag = "failed"
      $reportObject.path = ((($user.CanonicalName).split("/"))[1..((($user.CanonicalName).split("/")).count-2)] -join "/") 
      $report.Add($reportObject)
      $null = dsacls $user.distinguishedName /resetDefaultDACL
    }			

				
    #region Verify Inheritance
				
    if(($userAces  | where{$_.IsInherited -eq "True"}).count -lt 1){
      $reportObject = $null
      $reportObject = Create-CustomReportObject $user
      $reportObject.type = "Inheritance"
      $reportObject.flag = "failed"
      $reportObject.path = ((($user.CanonicalName).split("/"))[1..((($user.CanonicalName).split("/")).count-2)] -join "/")
      $report.Add($reportObject)
      $null = dsacls $user.distinguishedName /resetdefaultDACL
    }
			
    #endregion Verify Inheritance	

  }
	
  #endregion Check User Permissions

  #endregion User Objects

}

[int]$afterUsers =  [math]::Round(((Get-Process -Id $pid).ws / 1MB),2)

if($checkgMSAs){

  #region gMSA Objects

  [array]$allgMSAObjectsToCheck = $null
  foreach($dn in $targetOuDns){
	
    $allgMSAObjectsToCheck += Get-ADServiceAccount -Filter * -SearchBase $dn -SearchScope Subtree -Properties canonicalName,created
  }
  [array]$allgMSAObjectsToCheck = $allgMSAObjectsToCheck | Sort-Object -Unique
  $allgMSAObjectsToCheck = $allgMSAObjectsToCheck | Where-Object -FilterScript {$exemptions.ObjectGuid -notcontains $_.ObjectGuid}

  #region Check gMSA Owner
	
  foreach($gMSA in $allgMSAObjectsToCheck){
	
    [string]$currentOwner = $null
    $currentOwner = ((Get-Acl $gMSA.distinguishedName).Owner)
    if($currentOwner -ne $whoTheOwnerShouldBe){
      #Does not have the correct owner, update owner
				
      $reportObject = $null
      $reportObject = Create-CustomReportObject $gMSA
      $reportObject.oldOwner = $currentOwner
      $reportObject.type = "OwnergMSA"
      $reportObject.path = ((($gMSA.CanonicalName).split("/"))[1..((($gMSA.CanonicalName).split("/")).count-2)] -join "/") 

      if($modifyOwnership){
				
        $ADObject =  [ADSI]("LDAP://$dc/" + ($gMSA.distinguishedName -replace "/","\/"))     
        [DirectoryServices.DirectoryEntryConfiguration]$SecOptions = $ADObject.get_Options();
        $SecOptions.SecurityMasks = [DirectoryServices.SecurityMasks]"Owner"
        $ADObject.get_objectSecurity().SetOwner($adminRightsObjectSID)

        try{
          $ADObject.CommitChanges() 
          $reportObject.newOwner = $whoTheOwnerShouldBe
        }catch{
          $ReportObject.flag= "failed"
        }				
      }
				
      $report.Add($reportObject)
    }
		
  }		

  #endregion Check gMSA Owner	
  #>	


  #region Check gMSA Permissions

  foreach($gMSA in $allgMSAObjectsToCheck){

    [array]$customAces = $null
    [array]$gMSAAces = $null
    [array]$baseLine = $null
    [array]$gMSAAces = (((Get-Acl -Path ("AD:\" + $gMSA.DistinguishedName) | `
          Select-Object -ExpandProperty Access | `
          where{$wellKnownForgMSAObjects -notcontains $_.IdentityReference} | `
          Select-Object @{name='Name';expression={$gMSA.Name}}, `
          @{name='DistinguishedName';expression={$gMSA.DistinguishedName}}, `
          @{name='Path';expression={""}}, `
          @{name='Flag';expression={""}}, `
          @{name='objectTypeName';expression={if ($_.objectType.ToString() -eq '00000000-0000-0000-0000-000000000000') {'All'} Else {$schemaIDGUID.Item($_.objectType)}}}, `
    * )))   	
				
    $customAces = $gMSAAces | where{$_.IsInherited -ne "True"} | %{Create-CustomACEObject $_}
		
    #region gMSA Baseline

    #NT AUTHORITY\Authenticated Users - All : GenericRead
    $hash = New-Object System.Collections.Specialized.OrderedDictionary
    $hash.Add("Name",$gMSA.Name)
    $hash.Add("DistinguishedName",$gMSA.DistinguishedName)
    $hash.Add("Path","")
    $hash.Add("Flag","")
    $hash.Add("ObjectTypeName","All")
    $hash.Add("ActiveDirectoryRights","GenericRead")
    $hash.Add("InheritanceType","None")
    $hash.Add("ObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("InheritedObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("ObjectFlags","None")
    $hash.Add("AccessControlType","Allow")
    $hash.Add("IdentityReference","NT AUTHORITY\Authenticated Users")
    $hash.Add("IsInherited","False" )
    $hash.Add("InheritanceFlags","None" )
    $hash.Add("PropagationFlags","None")
    $object = New-Object PSObject -Property $hash
    $baseLine += $object	
    
    #Everyone - ExtendedRights - User-Force-Change-Password
    $hash = New-Object System.Collections.Specialized.OrderedDictionary
    $hash.Add("Name",$gMSA.Name)
    $hash.Add("DistinguishedName",$gMSA.DistinguishedName)
    $hash.Add("Path","")
    $hash.Add("Flag","")
    $hash.Add("ObjectTypeName","User-Force-Change-Password")
    $hash.Add("ActiveDirectoryRights","ExtendedRight")
    $hash.Add("InheritanceType","None")
    $hash.Add("ObjectType","00299570-246d-11d0-a768-00aa006e0529")
    $hash.Add("InheritedObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("ObjectFlags","ObjectAceTypePresent")
    $hash.Add("AccessControlType","Deny")
    $hash.Add("IdentityReference","Everyone")
    $hash.Add("IsInherited","False" )
    $hash.Add("InheritanceFlags","None" )
    $hash.Add("PropagationFlags","None")
    $object = New-Object PSObject -Property $hash
    $baseLine += $object						

    #Everyone - ReadProperty - MS-DS-ManagedPassword
    $hash = New-Object System.Collections.Specialized.OrderedDictionary
    $hash.Add("Name",$gMSA.Name)
    $hash.Add("DistinguishedName",$gMSA.DistinguishedName)
    $hash.Add("Path","")
    $hash.Add("Flag","")
    $hash.Add("ObjectTypeName","Ms-DS-ManagedPassword")
    $hash.Add("ActiveDirectoryRights","ReadProperty")
    $hash.Add("InheritanceType","None")
    $hash.Add("ObjectType","e362ed86-b728-0842-b27d-2dea7a9df218")
    $hash.Add("InheritedObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("ObjectFlags","ObjectAceTypePresent")
    $hash.Add("AccessControlType","Allow")
    $hash.Add("IdentityReference","Everyone")
    $hash.Add("IsInherited","False" )
    $hash.Add("InheritanceFlags","None" )
    $hash.Add("PropagationFlags","None")
    $object = New-Object PSObject -Property $hash
    $baseLine += $object													
    #endregion gMSA Baseline
							
    #compare ACEs to baseline
    foreach($item in $baseLine){
      $customAces | where{$_ -like $item} | foreach{$_.Flag = "Matched"; $item.Flag = "Matched"}
    }	
				
    [array]$toRemove = $null
    $toRemove = $customAces | where {$_.flag -ne "Matched"} 
				
    if($verboseLog){
      foreach($customAceObject in $toRemove){
        $customAceObject.Path = ((($gMSA.CanonicalName).split("/"))[1..((($gMSA.CanonicalName).split("/")).count-2)] -join "/")
        $verboseLogReport.add($customAceObject)
      } 
    }
				
    [string]$ldapDN = $null
    $ldapDN = "$dc/" + ($gMSA.distinguishedName -replace "/","\/")
    $ADObject = $null
    $ADObject =  [ADSI]("LDAP://" + $ldapDN)     
    [DirectoryServices.DirectoryEntryConfiguration]$SecOptions = $ADObject.get_Options();
    $SecOptions.SecurityMasks = [DirectoryServices.SecurityMasks]"Dacl"		

    $reportObject = $null
    $reportObject = Create-CustomReportObject $gMSA
    $reportObject.type = "gMSA ACE Removal"
    $reportObject.path = ((($gMSA.CanonicalName).split("/"))[1..((($gMSA.CanonicalName).split("/")).count-2)] -join "/") 
			
		
    if($toRemove.count -ge 1){
      foreach($ace in $toRemove){
						
        $objectTypeGUID = (new-object Guid $ace.ObjectType)
        $inheritedTypeGUID = (new-object Guid $ace.InheritedObjectType)
						
        [array]$identityReference = ($gMSAAces | where {$_.IdentityReference -eq $ace.IdentityReference} | where{$_.ObjectType -eq $ace.ObjectType}  | where{$_.ObjectTypeName -eq $ace.ObjectTypeName} |  where{$_.AccessControlType -eq $ace.AccessControlType} |where{$_.ActiveDirectoryRights -eq $ace.ActiveDirectoryRights}).IdentityReference
        $aceToRemove = new-object System.DirectoryServices.ActiveDirectoryAccessRule ($identityReference[0]),($ace.ActiveDirectoryRights),($ace.AccessControlType),$objectTypeGUID,($ace.InheritanceType),$inheritedTypeGUID 

        $null = $ADObject.get_ObjectSecurity().RemoveAccessRule($aceToRemove)
      }	
      Try{
        if($removeAces){
          $ADObject.CommitChanges() 
        }	
      }Catch{
        $reportObject.flag = "failed"
      }
					
      $report.Add($reportObject)	
    }
	
    [array]$unmetBaseline = $null
    $unmetBaseline = $baseLine | where{$_.flag -ne "Matched"}
				
    if($unmetBaseline.count -ge 1){
      $reportObject = $null
      $reportObject = Create-CustomReportObject $gMSA
      $reportObject.type = "gMSA Baseline"
      $reportObject.flag = "failed"
      $reportObject.path = ((($gMSA.CanonicalName).split("/"))[1..((($gMSA.CanonicalName).split("/")).count-2)] -join "/") 
      $report.Add($reportObject)
      $null = dsacls $gMSA.distinguishedName /resetDefaultDACL
    }
   
		

				
    #region Verify Inheritance
				
    if(($gMSAAces  | where{$_.IsInherited -eq "True"}).count -lt 1){
      $reportObject = $null
      $reportObject = Create-CustomReportObject $gMSA
      $reportObject.type = "Inheritance"
      $reportObject.flag = "failed"
      $reportObject.path = ((($gMSA.CanonicalName).split("/"))[1..((($gMSA.CanonicalName).split("/")).count-2)] -join "/")
      $report.Add($reportObject)
      $null = dsacls $gMSA.distinguishedName /resetdefaultDACL
    }
			
    #endregion Verify Inheritance	

  }
	
  #endregion Check gMSA Permissions

  #endregion gMSA Objects

}

[int]$aftergMSAs =  [math]::Round(((Get-Process -Id $pid).ws / 1MB),2)

if($checkGroups){

  #region Group Objects

  [array]$allGroupObjectsToCheck = $null
  foreach($dn in $targetOuDns){
	
    $allGroupObjectsToCheck += Get-ADGroup -Filter * -SearchBase $dn -SearchScope Subtree -Properties canonicalName,created
  }
  [array]$allGroupObjectsToCheck = $allGroupObjectsToCheck | Sort-Object -Unique
  $allGroupObjectsToCheck = $allGroupObjectsToCheck | Where-Object -FilterScript {$exemptions.ObjectGuid -notcontains $_.ObjectGuid}

  #region Check Group Owner
	
  foreach($group in $allGroupObjectsToCheck){
	
    [string]$currentOwner = $null
    $currentOwner = ((Get-Acl $group.distinguishedName).Owner)
    if($currentOwner -ne $whoTheOwnerShouldBe){
      #Does not have the correct owner, update owner
				
      $reportObject = $null			
      $reportObject = Create-CustomReportObject $group
      $reportObject.oldOwner = $currentOwner
      $reportObject.type = "OwnerGroup"
      $reportObject.path = ((($group.CanonicalName).split("/"))[1..((($group.CanonicalName).split("/")).count-2)] -join "/") 

      if($modifyOwnership){
				
        $ADObject =  [ADSI]("LDAP://$dc/" + ($group.distinguishedName -replace "/","\/"))     
        [DirectoryServices.DirectoryEntryConfiguration]$SecOptions = $ADObject.get_Options();
        $SecOptions.SecurityMasks = [DirectoryServices.SecurityMasks]"Owner"
        $ADObject.get_objectSecurity().SetOwner($adminRightsObjectSID)

        try{
          $ADObject.CommitChanges() 
          $reportObject.newOwner = $whoTheOwnerShouldBe
        }catch{
          $ReportObject.flag= "failed"
        }				
      }
				
      $report.Add($reportObject)
    }
		
  }		

  #endregion Check Group Owner

  #region Check Group Permissions
		
  foreach($group in $allGroupObjectsToCheck){
		
    [array]$customAces = $null
    [array]$groupAces = $null
    [array]$baseLine = $null
    [array]$groupAces = (((Get-Acl -Path ("AD:\" + $group.DistinguishedName) | `
          Select-Object -ExpandProperty Access | `
          where{$wellKnownForGroupObjects -notcontains $_.IdentityReference} | `
          Select-Object @{name='Name';expression={$group.Name}}, `
          @{name='DistinguishedName';expression={$group.DistinguishedName}}, `
          @{name='Path';expression={""}}, `
          @{name='Flag';expression={""}}, `
          @{name='objectTypeName';expression={if ($_.objectType.ToString() -eq '00000000-0000-0000-0000-000000000000') {'All'} Else {$schemaIDGUID.Item($_.objectType)}}}, `
    * )))    	
				
    $customAces = $groupAces | where{$_.IsInherited -ne "True"} | where{$_.ObjectTypeName -ne "Member"}| where{$_.ObjectTypeName -ne "Send-To"} | %{Create-CustomACEObject $_}

		
    #region Group Baseline
						
    #NT AUTHORITY\Authenticated Users - All : GenericRead 
    $hash = New-Object System.Collections.Specialized.OrderedDictionary
    $hash.Add("Name",$group.Name)
    $hash.Add("DistinguishedName",$group.DistinguishedName)
    $hash.Add("Path","")
    $hash.Add("Flag","")
    $hash.Add("ObjectTypeName","All")
    $hash.Add("ActiveDirectoryRights","GenericRead")
    $hash.Add("InheritanceType","None")
    $hash.Add("ObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("InheritedObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("ObjectFlags","None")
    $hash.Add("AccessControlType","Allow")
    $hash.Add("IdentityReference","NT AUTHORITY\Authenticated Users")
    $hash.Add("IsInherited","False" )
    $hash.Add("InheritanceFlags","None" )
    $hash.Add("PropagationFlags","None")
    $object = New-Object PSObject -Property $hash
    $baseLine += $object
						
    #NT AUTHORITY\SELF - All : GenericRead 
    $hash = New-Object System.Collections.Specialized.OrderedDictionary
    $hash.Add("Name",$group.Name)
    $hash.Add("DistinguishedName",$group.DistinguishedName)
    $hash.Add("Path","")
    $hash.Add("Flag","")
    $hash.Add("ObjectTypeName","All")
    $hash.Add("ActiveDirectoryRights","GenericRead")
    $hash.Add("InheritanceType","None")
    $hash.Add("ObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("InheritedObjectType","00000000-0000-0000-0000-000000000000")
    $hash.Add("ObjectFlags","None")
    $hash.Add("AccessControlType","Allow")
    $hash.Add("IdentityReference","NT AUTHORITY\SELF")
    $hash.Add("IsInherited","False" )
    $hash.Add("InheritanceFlags","None" )
    $hash.Add("PropagationFlags","None")
    $object = New-Object PSObject -Property $hash
    $baseLine += $object
						
    #endregion User Baseline
							
    #compare ACEs to baseline
    foreach($item in $baseLine){
      $customAces | where{$_ -like $item} | foreach{$_.Flag = "Matched"; $item.Flag = "Matched"}
    }	
				
    [array]$toRemove = $null
    $toRemove = $customAces | where {$_.flag -ne "Matched"} 
				
    if($verboseLog){
      foreach($customAceObject in $toRemove){
        $customAceObject.Path = ((($group.CanonicalName).split("/"))[1..((($group.CanonicalName).split("/")).count-2)] -join "/")
        $verboseLogReport.add($customAceObject)
      } 
    }
				
    [string]$ldapDN = $null
    $ldapDN = "$dc/" + ($group.distinguishedName -replace "/","\/")
    $ADObject = $null
    $ADObject =  [ADSI]("LDAP://" + $ldapDN)     
    [DirectoryServices.DirectoryEntryConfiguration]$SecOptions = $ADObject.get_Options();
    $SecOptions.SecurityMasks = [DirectoryServices.SecurityMasks]"Dacl"		

    $reportObject = $null			
    $reportObject = Create-CustomReportObject $group
    $reportObject.type = "Group ACE Removal"
    $reportObject.path = ((($group.CanonicalName).split("/"))[1..((($group.CanonicalName).split("/")).count-2)] -join "/") 
			
		
    if($toRemove.count -ge 1){
      foreach($ace in $toRemove){
						
        $objectTypeGUID = (new-object Guid $ace.ObjectType)
        $inheritedTypeGUID = (new-object Guid $ace.InheritedObjectType)
						
        [array]$identityReference = ($groupAces | where {$_.IdentityReference -eq $ace.IdentityReference} | where{$_.ObjectType -eq $ace.ObjectType}  | where{$_.ObjectTypeName -eq $ace.ObjectTypeName} |  where{$_.AccessControlType -eq $ace.AccessControlType} |where{$_.ActiveDirectoryRights -eq $ace.ActiveDirectoryRights}).IdentityReference
        $aceToRemove = new-object System.DirectoryServices.ActiveDirectoryAccessRule ($identityReference[0]),($ace.ActiveDirectoryRights),($ace.AccessControlType),$objectTypeGUID,($ace.InheritanceType),$inheritedTypeGUID 

        $null = $ADObject.get_ObjectSecurity().RemoveAccessRule($aceToRemove)
      }	
      Try{
        if($removeAces){
          $ADObject.CommitChanges() 
        }	
      }Catch{
        $reportObject.flag = "failed"
      }
					
      $report.Add($reportObject)	
    }
	
    [array]$unmetBaseline = $null
    $unmetBaseline = $baseLine | where{$_.flag -ne "Matched"}
				
    if($unmetBaseline.count -ge 1){
      $reportObject = $null				
      $reportObject = Create-CustomReportObject $group
      $reportObject.type = "Group Baseline"
      $reportObject.flag = "failed"
      $reportObject.path = ((($group.CanonicalName).split("/"))[1..((($group.CanonicalName).split("/")).count-2)] -join "/") 
      $report.Add($reportObject)
      $null = dsacls $group.distinguishedName /resetDefaultDACL
    }			

				
    #region Verify Inheritance
				
    if(($groupAces | where{$_.IsInherited -eq "True"}).count -lt 1){
      $reportObject = $null					
      $reportObject = Create-CustomReportObject $group
      $reportObject.type = "Inheritance"
      $reportObject.flag = "failed"
      $reportObject.path = ((($group.CanonicalName).split("/"))[1..((($group.CanonicalName).split("/")).count-2)] -join "/")
      $report.Add($reportObject)
      $null = dsacls $group.distinguishedName /resetdefaultDACL
    }
			
    #endregion Verify Inheritance	

  }
	
  #endregion Check Group Permissions
  #>

  #endregion Group Objects

}

[int]$afterGroups = [math]::Round(((Get-Process -Id $pid).ws / 1MB),2)


Set-Location C:\
if ($report){
$report | Export-Excel ($reportFilePath + "\Report_" + $runDate + ".xlsx")}

if ($verboseLogReport){
$verboseLogReport | Export-Excel ($reportFilePath + "\Verbose_" + $runDate + ".xlsx")}

#$report | Export-Csv -NoTypeInformation ($outputFilePath + "\Report_" + $runDate + ".csv")
#$report | Export-Csv -NoTypeInformation ($reportFilePath + "\Report_" + $runDate + ".csv")
#$verboseLogReport | Export-Csv -NoTypeInformation ($outputFilePath + "\Verbose_" + $runDate + ".csv")
#$verboseLogReport | Export-Csv -NoTypeInformation ($reportFilePath + "\Verbose_" + $runDate + ".csv")




#Date Flagged Report
if($dateFlaggedLogging){

  [array]$dateFlagged = $null
  $compareDate = (Get-Date).AddDays(-$flagableDateRangeInDays)
  [array]$dateFlagged = $report | where{(get-date($_.created)) -lt $compareDate} 
  
  if($dateFlagged.count -ge 2){
    $dateFlaggedReport = New-Object System.Collections.Generic.List[object]
    [array]$verboseObjects = $null
    $dateNow = (Get-Date).tostring("yyy.MM.dd_HH.mm.tt")
        
    foreach($object in $dateFlagged){
    
      $object | Add-Member -MemberType NoteProperty -name "DateLogged" -value $dateNow 
      $object | Add-Member -MemberType NoteProperty -name "ObjectTypeName" -value ""
      $object | Add-Member -MemberType NoteProperty -name "ActiveDirectoryRights" -value ""
      $object | Add-Member -MemberType NoteProperty -name "AccessControlType" -value ""
      $object | Add-Member -MemberType NoteProperty -name "IdentityReference" -value ""
      [array]$verboseObjects = $verboseLogReport | where{$_.distinguishedName -like $object.DistinguishedName}
      foreach($verboseObject in $verboseObjects){
        $verboseObject | Add-Member -MemberType NoteProperty -name "Type" -value $object.type -Force
        $verboseObject | Add-Member -MemberType NoteProperty -name "DateLogged" -value $dateNow -Force
        $verboseObject | Add-Member -MemberType NoteProperty -name "ObjectTypeName" -value $object.ObjectTypeName -Force
        $verboseObject | Add-Member -MemberType NoteProperty -name "oldOwner" -value $object.oldOwner -Force
        $verboseObject | Add-Member -MemberType NoteProperty -name "newOwner" -value $object.newOwner -Force
        $verboseObject | Add-Member -MemberType NoteProperty -name "created" -value $object.created -Force
        $verboseObject | Add-Member -MemberType NoteProperty -name "ObjectGUID" -value $object.objectGUID -Force
        $dateFlaggedReport.Add($verboseObject)
      }
      $dateFlaggedReport.Add($object)
    }
#    $dateFlaggedReport = $dateFlaggedReport | Sort-Object -Unique 
    $dateFlaggedReport = $dateFlaggedReport | Sort-Object -Property "DistinguishedName"
    $dateFlaggedReport | Export-Csv -NoTypeInformation ($outputFilePath + "\_DateFlagged.csv") -Append
    Get-ChildItem $reportFilePath | where{$_.name -like "_DateFlagged_*.csv"} | Remove-Item -Force
    Copy-Item ($outputFilePath + "\_DateFlagged.csv") ($reportFilePath + "\_DateFlagged_" + $runDate + ".csv")
  } 
}


#RunLog

[int]$reportObjectCount = $report.Count
[int]$verboseLogReportCount = $verboseLogReport.count
[int]$exemptionCount = $exemptions.Count
$exemptionDNsString = $exemptionDNs -join " `r`n"
$targetOuDnsString = $targetOuDns -join " `r`n"
$exemptionGroupsString = $exemptionGroups -join " `r`n"


"   " | Out-File "$outputFilePath\runlog.log" -Append
"-------------------------------------- " | Out-File "$outputFilePath\runlog.log" -Append
$runDate | Out-File "$outputFilePath\runlog.log" -Append
"Memory - Computers b: $beforeComputers a: $afterComputers" | Out-File "$outputFilePath\runlog.log" -Append
"Memory - Users a: $afterUsers" | Out-File "$outputFilePath\runlog.log" -Append
"Memory - Groups a: $afterGroups" | Out-File "$outputFilePath\runlog.log" -Append
"ReportObjectCount : $reportObjectCount"
"VerboseLogReport : $verboseLogReportCount"
(Get-Date).tostring("yyy.MM.dd_HH.mm.tt") | Out-File "$outputFilePath\runlog.log" -Append

$finalEvent = @"

$eventLogSource

-----------------------

Script Completed

ReportObjectCount: $reportObjectCount
VerboseLogReport: $verboseLogReportCount

Modify Ownership: $modifyOwnership
Remove ACEs: $removeAces

Check Computers: $checkComputers
Check Users: $checkUsers
Check Groups: $checkGroups

Target OUs:
$targetOuDnsString

Exemption DNs:
$exemptionDNsString

Exemption Groups:
$exemptionGroupsString

Exemption Count:
$exemptionCount

Memory usage before computers: $beforeComputers
Memory usage after computers: $afterComputers
Memory usage after users: $afterUsers
Memory usage after groups: $afterGroups

"@

# SIG # Begin signature block
# MIISEwYJKoZIhvcNAQcCoIISBDCCEgACAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUAe9PWR3I2ZnspbjqxO+6kpMv
# wNqggg9rMIIHsTCCBZmgAwIBAgITNQAAACFv8bfVN7E2EQAAAAAAITANBgkqhkiG
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
# IwYJKoZIhvcNAQkEMRYEFCUNMb/Bgmne+zarXTToXqOlWoVxMA0GCSqGSIb3DQEB
# AQUABIIBABaVGXkgVqV1NTBx+3ZS0GvBDpTaAUTLYZCoqHp6DadCIWEnyOo51noq
# f25Hzl3TSmF1vH8Scs6FTUweNobkZQ48Hi0I/t7cEjKyrH+R0DZKKCDNLz2vSU9b
# D5kphoAlYct6813Al9Movqjfw+N48MKImJwhSjTOuHyB0fvCxUI9/lty0vOZ28KN
# NCP7x3efe2w55i8VhnqAkn0QITfVEKOMj+cEhValMvQsYlPPIzkbMc3oBpwA9SXd
# eCA/nxRu8ZW8pPZNatFK0LB6DGDvJNMvwbX74jAVPjf8y3UNaQWWPuScPD8G8SqF
# CIPNd6tErzmrr4nc/a86ALPu/VbhvW0=
# SIG # End signature block
