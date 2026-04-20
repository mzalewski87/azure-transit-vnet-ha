<powershell>
# Domain Controller Setup Script
# Installs AD DS and promotes the server to a domain controller
# Domain: ${domain_name}

$ErrorActionPreference = "Stop"

# Install AD DS feature
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

# Import AD DS module
Import-Module ADDSDeployment

# Promote to Domain Controller (new forest)
Install-ADDSForest `
    -DomainName "${domain_name}" `
    -DomainNetbiosName ($("${domain_name}".Split('.')[0]).ToUpper()) `
    -SafeModeAdministratorPassword (ConvertTo-SecureString "${admin_password}" -AsPlainText -Force) `
    -InstallDns:$true `
    -Force:$true `
    -NoRebootOnCompletion:$false
</powershell>
