$Zone = "3cx.us"
$RecordName = "siptest"
$NewAlias = "srv010010050051.generationsgaither.com"
$DnsServer = "srv010010050041.generationsgaither.com"

# 1. Find the existing CNAME record
$dnsRecord = Get-CimInstance -Namespace "root\MicrosoftDNS" `
                             -ClassName "MicrosoftDNS_CNAMEType" `
                             -ComputerName $DnsServer `
                             -Filter "OwnerName = '$RecordName.$Zone'"

if ($dnsRecord) {
    # 2. Update the record using the Modify method
    Invoke-CimMethod -InputObject $dnsRecord -MethodName "Modify" -Arguments @{
        PrimaryName = $NewAlias
    }
    Write-Host "Successfully updated CNAME to $NewAlias"
} else {
    Write-Error "CNAME record not found."
}