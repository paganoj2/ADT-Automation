<#	
	.NOTES
	===========================================================================
	 Created on:   	12/12/2023 11:48 AM
	 Created by:   	Jacob Pagano
	 Organization: 	A1 IT Service Solutions
	 Filename:     	SetDefaultDomainDistributionGroups.ps1
	===========================================================================
	.DESCRIPTION
		This PowerShell script checks the default domain groups. I.E Domain Admins, Domain Computers and ensures that they are added to the Forest Distribution Groups.
#>
#Get the domain, this can be used to determine which TLOUs are options

$CurrentDC = (Get-ADDomainController -Identity $env:COMPUTERNAME).HostName
$PDC = (Get-ADDomain | Select-Object -Property PDCEmulator).PDCEmulator
if ($CurrentDC -ne $PDC)
{
	
	#Current Domain Controller isn't the PDC, exit...
	exit
	
}
[string]$global:Forest = (Get-ADDomainController).Forest
[string]$global:Domain = (Get-ADDomain).DNSRoot

#Select the PDC Emulator as the DC for all changes
$global:DC = (Get-ADDomain $Domain | Select-Object PDCEmulator).PDCEmulator
$ForestDC = (Get-ADDomain (Get-ADDomainController).Forest | Select-Object PDCEmulator).PDCEmulator

#Select the PDC Emulator as the DC for all changes
$global:DomainNetBIOSName = (Get-ADDomain $Domain | Select-Object NetBIOSName).NetBIOSName
$global:DomainRoot = (Get-ADDomain $Domain | Select-Object DNSRoot).DNSRoot

#Set Base DN
$baseDN = (Get-ADDomain $Domain).DistinguishedName
$forestbaseDN = (Get-ADForest $Forest).DistinguishedName


$DGroup1 = (Get-ADGroup "Domain Admins" -Server $DC).DistinguishedName
$DGroup2 = (Get-ADGroup "Domain Computers" -Server $DC).DistinguishedName
$DGroup3 = (Get-ADGroup "Domain Controllers" -Server $DC).DistinguishedName
$DGroup4 = (Get-ADGroup "Domain Users" -Server $DC).DistinguishedName
$DGroup5 = (Get-ADGroup "Domain Guests" -Server $DC).DistinguishedName


$FGroup1 = (Get-ADGroup "All Domain Admins Groups" -Server $ForestDC).DistinguishedName
$FGroup2 = (Get-ADGroup "All Domain Computers Groups" -Server $ForestDC).DistinguishedName
$FGroup3 = (Get-ADGroup "All Domain Controllers Groups" -Server $ForestDC).DistinguishedName
$FGroup4 = (Get-ADGroup "All Domain Users Groups" -Server $ForestDC).DistinguishedName
$FGroup5 = (Get-ADGroup "All Domain Guests Groups" -Server $ForestDC).DistinguishedName



Set-ADObject -Identity $FGroup1 -Add @{ "member" = $DGroup1 } -Server $ForestDC
Set-ADObject -Identity $FGroup2 -Add @{ "member" = $DGroup2 } -Server $ForestDC
Set-ADObject -Identity $FGroup3 -Add @{ "member" = $DGroup3 } -Server $ForestDC
Set-ADObject -Identity $FGroup4 -Add @{ "member" = $DGroup4 } -Server $ForestDC
Set-ADObject -Identity $FGroup5 -Add @{ "member" = $DGroup5 } -Server $ForestDC






# SIG # Begin signature block
# MIISEwYJKoZIhvcNAQcCoIISBDCCEgACAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUNsbDEo+Qm0hPSbQf3iyL7M8M
# 9XSggg9rMIIHsTCCBZmgAwIBAgITNQAAACFv8bfVN7E2EQAAAAAAITANBgkqhkiG
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
# IwYJKoZIhvcNAQkEMRYEFK/V2XkoIuN2fwR3gv+W8oW/S7yPMA0GCSqGSIb3DQEB
# AQUABIIBABcYb+H+FVjKjr9mDVn+SOKEogPHZIzr0280BP8YC/57WReWseH64rYq
# yW9OsE/Y/A7UVcQPeYgN/ZcU81H4cDkMeOlK7SekZVeo+hH5vgxKwCz1g9Be1Hwq
# wfJMhL0/lktuwgfM4CK0/DjqBItQ+AVX/aKD2szqv2YAesLIFatFgKRfnUurL78n
# TGT6O5cMuGZEVgR0sG0xFeqX+gK9nd9V1fCgmrJ2ENa4+45sd6j0eEXNOs2K3bo6
# Dg7KMW/2/2AP1HJjafzUBhOJnf07wQqYqHeay9FiR0RF+fWJTTYPfHf/rq9Wifjt
# EyRJM+BU7Hu8NsVjUNR/oDbNFmrvcIc=
# SIG # End signature block
