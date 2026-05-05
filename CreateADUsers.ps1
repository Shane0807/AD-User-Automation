Import-Module ActiveDirectory

function Start-SleepWithProgress($seconds) {
    $doneDT = (Get-Date).AddSeconds($seconds)
    while($doneDT -gt (Get-Date)) {
        $secondsLeft = $doneDT.Subtract((Get-Date)).TotalSeconds
        $percent = ($seconds - $secondsLeft) / $seconds * 100
        Write-Progress -Activity "Sleeping" -Status "Sleeping..." -SecondsRemaining $secondsLeft -PercentComplete $percent
        [System.Threading.Thread]::Sleep(500)
    }
    Write-Progress -Activity "Sleeping" -Status "Sleeping..." -SecondsRemaining 0 -Completed
}

#Config
$UserCredential = Get-Credential
$DomainName = "company.local"
$GmailDomainName = "company.com"
$ExchangeName = "company.mail.onmicrosoft.com"
$ExchangeServer = "Exchange-Server"
$HomeDrive = "H:"
$DefaultPassword = "DefaultPasswordExample123"

#OPTIONAL#
#Replace code above with this for better security: $DefaultPassword = Read-Host "Enter default password" -AsSecureString


#Start Powershell Session with Exchange server
$Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri Http://$($ExchangeServer).company.com/PowerShellh -Authentication Kerberos -Credential $UserCredential
Import-PSSession $Session -DisableNameChecking


#Location will be Base OU name, then use a map
#Long Name, Short Name, Abbreviation
$BuildingNames = @{
    Headquarters = @("Headquarters", "HQ", "HQ")
    Office1 = @("Office1", "OF1","OF")
    ElementarySchool = @("Elementary School", "Elem", "ES")
    MiddleSchool = @("Middle School", "Mid", "MS")
    HighSchool = @("High School", "HS", "HS")
}

#Default groups for all staff members
$Groups = @(
    "VPN-Users",
    "Staff",
    "Email-Users",
    "MFA-Enabled"
)

#Import users to create from a csv
$NewUsers = Import-Csv $PSSCRIPTROOT\NewADUsers.csv
#Display users in Console
Write-Host $NewUsers

foreach ($User in $NewUsers)
{

    #User Config
    #split location in csv into an array and get location based off first word
    $LocationStrArray = ($User.Location -split " ")
    $Location = $BuildingNames.GetEnumerator().Where({$_.Value -match $LocationStrArray[0]}).Key
    #Get Aduser that matches the replacing field in the spreadsheet. escapes any apastrophes in their name
    $Replacing = ($User.Replacing -split " " -replace "'","''")
    $ReplacedADUser = Get-ADUser -Filter "SamAccountName -like '$($Replacing[0]).$($Replacing[1])'" | Select-Object Name,Mail,DistinguishedName,@{n='OU';e={$_.DistinguishedName -replace '^.*?,(?=[A-Z]{2}=)'}}
    $LowerCaseName = "$($User.FirstName.ToLower()).$($User.LastName.ToLower())"

    Write-Host "Creating User $($User.LastName), $($User.FirstName)"
    Write-Host "User location is $($Location)"

    #If there is a replaced user specified AND it is found in AD get their OU, else default ou for now
    if ($ReplacedADUser)
    {
        $OU = $ReplacedADUser.OU
    }
    else {
        $OU = "OU=NewUsers,OU=CompanyName,DC=Company,DC=org"
    }
    Write-Host "Set user OU to $($OU)"
    

    #assign location specific groups
    if (($BuildingNames.$Location[2] -eq $BuildingNames.Office1[2]) -or ($BuildingNames.$Location[2] -eq $BuildingNames.HighSchool[2]))
    {
        $UserSpecificGroups = @(
            "WEBSITE-ALL-STAFF",
            "Office.example",
            "$($User.License)")
    }
    else {
        Write-Host "Location isn't Office1 or Middle School"
        $UserSpecificGroups = @(
        "$($BuildingNames.$Location[2])-EXAMPLE-DIFFERENT-GROUP",
        "$($BuildingNames.$Location[1]).fac",
        "$($User.License)")
    }

    #New user parameters
    $NewADUserParameters = @{
        Name = "$($User.LastName), $($User.FirstName)"
        DisplayName = "$($User.LastName), $($User.FirstName)"
        GivenName = $User.FirstName
        Surname = $User.LastName
        sAMAccountName = $LowerCaseName
        UserPrincipalName = "$($LowerCaseName)@$($DomainName)"
        AccountPassword = ConvertTo-SecureString -String $DefaultPassword -AsPlainText -Force
        Path = $OU
        Enabled = $True
        ChangePasswordAtLogon = $True
        HomeDrive = $HomeDrive
        HomeDirectory = "\\$DomainName\scanto\$($LowerCaseName)"
        EmployeeID = $User.EmployeeID
        EmailAddress = "$($User.FirstName).$($User.LastName)@$($DomainName)"
        #Job Related Fields
        Description = "$($BuildingNames.$Location[0]) - $($User.Position)"
        Title = $User.Position
        #Department =
        #Manager = "John.Doe"
        OtherAttributes = @{
            gmail = "$($User.FirstName).$($User.LastName)@$($GmailDomainName)"
        }
    }

    #try to get the ad user, do nothing if they exist,
    #catch the error and create user, assign groups, create email
    #catch any other error that isn't identity not found
    try
    {
        $ADUser = Get-ADUser -Identity $LowerCaseName -ErrorAction Stop
        Write-Host "AD User already exists!"
        $ADUser
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException]
    {
        Write-Host "User account doesn't exist!"
        New-ADUser @NewADUserParameters

        Write-Host "Adding user specific groups"
        foreach ($Group in $UserSpecificGroups)
        {
            Add-ADGroupMember -Identity $Group -Members "$($LowerCaseName)"
        }

        Write-Host "Adding global groups"
        foreach ($Group in $Groups)
        {
            Add-ADGroupMember -Identity $Group -Members "$($LowerCaseName)"
        }

        Write-Host "Enabling user mailbox"
        Start-SleepWithProgress(10)
        Enable-RemoteMailbox "$($LowerCaseName)" -RemoteRoutingAddress "$($LowerCaseName)@$($ExchangeName)"

        if (![String]::IsNullOrEmpty($User.'Expiration Date'))
        {
            Set-ADAccountExpiration -Identity "$($LowerCaseName)" -DateTime $($User.'Expiration Date')
        }
    }
    catch
    {
        $_.Exception.Message
    }
}


Write-Host "All users created!"
Remove-PSSession $Session
Read-Host -Prompt "Press Enter to exit"