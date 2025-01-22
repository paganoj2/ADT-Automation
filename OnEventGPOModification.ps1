<#

.AUTHOR

JACOB PAGANO


.DESCRIPTION

Written to track Group Policy changes. This will send an e-mail alert containing the GPO name, the admin who modified and the GPO revision number.
This will send in table format with all events that were triggered in a 15 minute period.

.VERSION CONTROL

7/20/2024 - I was born.

7/20/2024 - Set as a scheduled task to run on all Domain Controllers in the Forest.




#>


# Initialize a list to store modified GPOs
$modifiedGPOslist = New-Object System.Collections.Generic.List[System.Object]

# Set the time window for checking modifications (last 15 minutes)
$last15minutes = (Get-Date).AddMinutes(-15)

# Get the event entries for GPO modifications
$eventEntries = Get-WinEvent -ProviderName 'Microsoft-Windows-Security-Auditing' -FilterXPath "*[System[EventID=5136] and EventData[Data[@Name='ObjectClass']='groupPolicyContainer'] and EventData[Data[@Name='AttributeLDAPDisplayName']='versionNumber'] and EventData[Data[@Name='OperationType']='%%14674']]" | Where-Object { $_.TimeCreated -gt $last15minutes }
# Add modified GPOs to the list
foreach ($entry in $eventEntries) {
    $ObjectDN = $entry.Properties[8].Value
    $VersionNo = $entry.Properties[13].Value
    $SID = $entry.Properties[2].Value
    [array]$ToAddress += (Get-ADObject -Filter "objectSid -eq '$SID'" -Properties mail).mail
    $GPOModifiedBy = $entry.Properties[3].Value
    $GPOModifiedByDomainName = $entry.Properties[4].Value
    $GPOId = [regex]::Match($ObjectDN, '(?<={)[^{}]+(?=})').Value
    $GPO = Get-GPO -id "{$GPOId}"
    $GPODisplayName = $GPO.DisplayName
    $modifiedGPOslist.Add([PSCustomObject]@{
        'GPO Name' = $GPODisplayName
        'GPO ID' = $GPOId
        'Modified By' = "$GPOModifiedByDomainName\$GPOModifiedBy"
        'Version Number' = "$VersionNo"
    })
}

# Create an HTML table for the modified GPOs list
$emailBody = @"
<html>
<head>
<style>
    table {
        border-collapse: collapse;
    }
    th, td {
        border: 1px solid black;
        padding: 8px;
        text-align: left;
    }
</style>
</head>
<body>
<p>[This is an automated message from A1 IT Service Solutions regarding Active Directory Operations]</p>
<p>
<p>The following Group Policy Objects have been modified in the past 15 minutes:</p>
<table>
    <tr>
        <th>GPO Name</th>
        <th>GPO ID</th>
        <th>Modified By</th>
        <th>GPO Version Number</th>
    </tr>
    $(
        $modifiedGPOslist | ForEach-Object {
            "<tr><td>$($_.'GPO Name')</td><td>$($_.'GPO ID')</td><td>$($_.'Modified By')</td><td>$($_.'Version Number')</td></tr>"
        }
    )
</table>
<p>If this change was intentional, and everyone is in the loop regarding this change, then no action is noecessary. If anybody receiving this e-mail is unaware of this change, then please initiate incident response and disable all accounts and GPOs involved.</p>

<p>A1 IT Service Solutions</p>
</body>
</html>
"@

# Send the email
$ForestDomain = (Get-ADDomain).Forest
$EAdmins = Get-ADGroupMember "Enterprise Admins" -Server $ForestDomain -Recursive | Get-ADUser -Properties mail


foreach ($admin in $EAdmins) {
    [array]$CCs += $admin.mail.toString()
}
$CCs += 'active-directory-management@a1its.org'

if (!$ToAddress) {
    $ToAddress = 'active-directory-management@a1its.org'
}

if($modifiedGPOslist){
Send-MailMessage -To $ToAddress -Cc $CCs -From 'doNotReply@a1its.org' -Subject 'WARNING: Group Policy Object Modification' -Body $emailBody -BodyAsHtml -SmtpServer 'DCMETSMTP001.RES.DS.A1' -Priority High
}
# SIG # Begin signature block
# MIISEwYJKoZIhvcNAQcCoIISBDCCEgACAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUg1fq9FuI+rmBA6bnFvEwnAhJ
# f/+ggg9rMIIHsTCCBZmgAwIBAgITNQAAACFv8bfVN7E2EQAAAAAAITANBgkqhkiG
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
# IwYJKoZIhvcNAQkEMRYEFCYrNWdWQOdyZ+tmRJbcrwZQffs9MA0GCSqGSIb3DQEB
# AQUABIIBAA16NCV8gFpao4SPR05xWwb9PrrQFi6GUNqSjsf0shChvmFgv6rxEMCr
# Hagf0lOTV6z61fByDQAWAFzfEjAlH30F8YXqJsksBh6EVfJuDHnTKphmxt+LZ/T0
# jyGP29DqkGNgNJ0TijTZX0fQIPAnNjbAcbokzNO0t2iqE1yN6DLUq2FYCPIphgOh
# i5e90bW8QEbQ2+AtfnMn3W/AmjgbF+iFx4A1VUJrrTmSrtuWW/YNmRqWD1J1oY46
# ijol5oIRXlthA5o4kHLx772U4a2KJi2YA6MUEZPWNfCx1I9w/RrwHNG+qO0XUTXH
# KTKY4qBxKZAyChEAPZbXXWWwUHig5LQ=
# SIG # End signature block
