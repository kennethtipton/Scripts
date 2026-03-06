# ============================================================================
# ADMINISTRATOR PRIVILEGE CHECK
# ============================================================================
# This block checks if the script is running with Administrator privileges
# If not, it relaunches itself with elevated permissions

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    # Get the current user's Windows identity and check if they have the Administrator role
    # If not an admin, start a new PowerShell process with elevated privileges
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit  # Exit the current non-elevated instance
}

# ============================================================================
# SCRIPT INITIALIZATION
# ============================================================================
# Display confirmation message that script is running with full privileges
Write-Host "Running with full privileges" -ForegroundColor Green

$applicationScriptName = '3CX_Template_Restore.ps1'
$applicationLogFileName = '3CX_Template_Restore'

# Set the base path for all general scripts
$scriptFolder = $PSScriptRoot
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $scriptFolder -ChildPath '..\..\..'))
$sharedFunctionsFolder = Join-Path -Path $repoRoot -ChildPath 'Functions'

# ============================================================================
# PREFLIGHT VALIDATION
# ============================================================================
# Validate script dependencies and expected helper commands before continuing.
$localFunctionScripts = @(
    (Join-Path -Path $scriptFolder -ChildPath 'Functions\UPDATE-CISCO_SPA5XX_DST_FOR_A_TIMEZONE.ps1'),
    (Join-Path -Path $scriptFolder -ChildPath 'Functions\RESTORE-TEMPLATE_DATA.ps1'),
    (Join-Path -Path $scriptFolder -ChildPath 'Functions\Get-RestoreTemplates.ps1'),
    (Join-Path -Path $scriptFolder -ChildPath 'Functions\Get-FixTemplates.ps1')
)

$sharedFunctionScripts = @(
    (Join-Path -Path $sharedFunctionsFolder -ChildPath 'Get-FileFolderInformation.ps1'),
    (Join-Path -Path $sharedFunctionsFolder -ChildPath 'Get-DaylightSavingTime.ps1'),
    (Join-Path -Path $sharedFunctionsFolder -ChildPath 'Write-AdvancedLog.ps1'),
    (Join-Path -Path $sharedFunctionsFolder -ChildPath 'Copy-FileWithOverwrite.ps1')
)

$requiredScriptPaths = @($localFunctionScripts + $sharedFunctionScripts)

$missingScriptPaths = $requiredScriptPaths | Where-Object { -not (Test-Path -Path $_) }
if ($missingScriptPaths.Count -gt 0) {
    $missingScriptPathsText = $missingScriptPaths -join "`r`n - "
    throw "Preflight failed. Missing required script dependencies:`r`n - $missingScriptPathsText"
}

# ============================================================================
# IMPORT FUNCTION LIBRARIES
# ============================================================================
# Dot-source (import) local and shared functions now that file paths are validated.
foreach ($dependencyScript in $requiredScriptPaths) {
    . $dependencyScript
}

$requiredCommands = @(
    'Update-CiscoDSTForTimezone',
    'Get-TemplateTypes',
    'Get-RestoreTemplates',
    'Get-FixTemplates',
    'Write-AdvancedLog',
    'Test-PathExists',
    'Copy-FileWithOverwrite'
)

$missingCommands = $requiredCommands | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) }
if ($missingCommands.Count -gt 0) {
    $missingCommandsText = $missingCommands -join ', '
    throw "Preflight failed. Missing required commands/functions: $missingCommandsText"
}

# ============================================================================
# LOG INITIALIZATION
# ============================================================================
# Write startup log entry for script execution tracking
Write-AdvancedLog -Message '3CX_Template_Restore.ps1 script started successfully.' `
    -ScriptName $applicationScriptName `
    -LogFileName $applicationLogFileName `
    -LogType 'INFO'

# ============================================================================
# PATH CONFIGURATION
# ============================================================================
# Set up folder paths for templates and data files

$scriptFolder = $PSScriptRoot  # Get the directory where this script is located
$templateSubfolderName = "Templates"  # Subfolder name for template files
$dataSubfolderName = "Data"  # Subfolder name for data files

# Construct full paths to Templates and Data folders
$savedTemplatesFolder = Join-Path -Path $scriptFolder -ChildPath $templateSubfolderName
$DataFolder = Join-Path -Path $scriptFolder -ChildPath $dataSubfolderName

# ============================================================================
# LOAD CONFIGURATION DATA
# ============================================================================
# Load the JSON configuration file containing restore template settings

$threeCXRestoreDataJSonFile = "$DataFolder\RESTORE_TEMPLATES_DATA.JSON"
# Read the entire JSON file as a single string
$threeCXRestoreDataJSon = Get-Content -Path $threeCXRestoreDataJSonFile -Raw
# Convert JSON string to PowerShell object for easy manipulation
$threeCXRestoreDataObject = ConvertFrom-Json -InputObject $threeCXRestoreDataJSon

# Validate destination template paths defined in the JSON config before any copy operations.
$configuredTemplateLocations = @($threeCXRestoreDataObject.tables.templatetypes.location)
$missingTemplateLocations = $configuredTemplateLocations | Where-Object { -not (Test-Path -Path $_) }
if ($missingTemplateLocations.Count -gt 0) {
    $missingLocationsText = $missingTemplateLocations -join "`r`n - "
    throw "Preflight failed. Missing destination template folders from configuration:`r`n - $missingLocationsText"
}

# ============================================================================
# EXTRACT DATA FROM CONFIGURATION
# ============================================================================
# Parse the configuration object to get different types of template information

# Get information about available template types (e.g., phone templates, provisioning templates)
$threeCXTemplatesInformation = Get-TemplateTypes -Config $threeCXRestoreDataObject -LogFileName $applicationLogFileName

# Get the list of templates to restore
$threeCXRestoreTemplates = Get-RestoreTemplates -Config $threeCXRestoreDataObject

# Get the list of templates that need fixing/modification
$threeCXFixRestoreTemplates = Get-FixTemplates -Config $threeCXRestoreDataObject

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================
# Initialize global variables for template processing
$global:threeCXTemplateType = ""  # Stores the current template type being processed
$global:threeCXTemplatePath = ""  # Stores the current template path being processed

# ============================================================================
# UNUSED FUNCTION (appears incomplete or for future use)
# ============================================================================
# This function creates a custom object but has incorrect parameter usage
# The parameters $Name and $Age are not defined in the function signature
function Copy-ToInformation {
    # Create a new PowerShell custom object
    $copyToInformation = New-Object PSObject
    # Add properties to the object (NOTE: $Name and $Age are not defined)
    $copyToInformation | Add-Member -MemberType NoteProperty -Name "Path" -Value $Name
    $copyToInformation | Add-Member -MemberType NoteProperty -Name "Overwrite" -Value $Age
    
    return $copyToInformation
}

# ============================================================================
# MAIN PROCESSING LOOP
# ============================================================================
# Clear the console for clean output
Clear-Host

# Loop through each template that needs to be restored
foreach ($threeCXRestoreTemplate in $threeCXRestoreTemplates) {
    
    # Extract properties from the current restore template
    $threeCXRestoreTemplateName = $threeCXRestoreTemplate.name  # Template filename
    $threeCXRestoreTemplateType = $threeCXRestoreTemplate.type  # Template type (e.g., phone, provisioning)
    $threeCXRestoreTemplateOverwrite = $threeCXRestoreTemplate.overwrite  # Whether to overwrite existing files
    
    # Build the full path to the saved template file
    $restoreTemplatePath = Join-Path -Path $savedTemplatesFolder -ChildPath $threeCXRestoreTemplateName
    
    # Check if the template file exists in the saved templates folder
    if (Test-PathExists -Path $restoreTemplatePath -Quiet) {
        
        # ====================================================================
        # APPLY FIX FUNCTIONS TO TEMPLATES
        # ====================================================================
        # Some templates need modifications before being restored
        # Loop through fix templates to find matching template name
        foreach ($threeCXfixRestoreTemplate in $threeCXFixRestoreTemplates) {
            
            # Check if this fix applies to the current template
            if ($threeCXFixRestoreTemplate.name -eq $threeCXRestoreTemplateName) {
                
                # Get the list of fix functions to apply
                $fixFunctions = $threeCXFixRestoreTemplate.functions
                
                # Execute each fix function on the template file
                foreach ($fixFunction in $fixFunctions) {
                    # Call the function dynamically using the call operator (&)
                    # Pass the template file path as parameter
                    # Suppress output with Out-Null
                    & $($fixFunction.name) -FilePath $restoreTemplatePath | Out-Null
                }
            }
        }

        # ====================================================================
        # DETERMINE DESTINATION PATH AND COPY TEMPLATE
        # ====================================================================
        # Find where this template should be copied based on its type
        foreach ($threeCXTemplateInformation in $threeCXTemplatesInformation) {
            
            # Extract template type information
            $threeCXTemplateType = $threeCXTemplateInformation.type
            $threeCXTemplateLocation = $threeCXTemplateInformation.location
            
            # Check if the current template type matches the restore template type
            if ($threeCXRestoreTemplateType -eq $threeCXTemplateType ) {
                
                # Build the destination path for the template
                $threeCXTemplatePath = Join-Path -Path $threeCXTemplateLocation -ChildPath $threeCXRestoreTemplateName
                
                # ============================================================
                # COPY SCENARIO 1: Source file ($restoreTemplatePath) exist, Destination file ($threeCXTemplatePath) exists, overwrite enabled
                # ============================================================
                # NOTE: There's a bug here - should use -eq instead of =
                if ((Test-PathExists -Path $threeCXTemplatePath -Quiet) -and 
                    (Test-PathExists -path $restoreTemplatePath -Quiet) -and 
                    ($threeCXRestoreTemplateOverwrite -eq $true)) {
                    # Copy the template file, overwriting the existing file
                    Copy-FileWithOverwrite -SourceFilePath $restoreTemplatePath `
                        -DestinationFilePath $threeCXTemplatePath `
                        -LogIt `
                        -LogFileName $applicationLogFileName `
                        -Overwrite
                    # Write log entry for overwrite copy operation
                    Write-AdvancedLog -Message "3CX_Template_Restore.ps1: Destination exists ($threeCXTemplatePath). Copying source ($restoreTemplatePath) over destination." `
                        -ScriptName '3CX_Template_Restore.ps1' `
                        -LogType 'INFO'
                }
                
                # ============================================================
                # COPY SCENARIO 2: Source file ($restoreTemplatePath) exist, Destination file ($threeCXTemplatePath) does not exists, overwrite enabled
                # ============================================================
                # NOTE: This condition has the same bug (-eq vs =)
                # This also creates redundancy with the previous condition
                if ((Test-PathExists -Path $restoreTemplatePath -Quiet) -and
                    (-not(Test-PathExists -Path $threeCXTemplatePath -Quiet)) -and
                    ($threeCXRestoreTemplateOverwrite -eq $true)) {
                    
                    # Copy the template file with overwrite
                    Copy-FileWithOverwrite -SourceFilePath $restoreTemplatePath `
                        -DestinationFilePath $threeCXTemplatePath `
                        -LogIt `
                        -LogFileName $applicationLogFileName `
                        -Overwrite

                    # Write log entry for new destination copy operation
                    Write-AdvancedLog -Message "3CX_Template_Restore.ps1: Destination missing ($threeCXTemplatePath). Copying source ($restoreTemplatePath) to destination." `
                        -ScriptName '3CX_Template_Restore.ps1' `
                        -LogType 'INFO'

                }
            }
            else {
                # Template type doesn't match - skip this location
                # Commented out debug line:
                #Write-Host "Not Equal: Testing Type $threeCXTemplateType against $threeCXRestoreTemplateType."
            }
        }
    }
    else {
        # Template file doesn't exist in the saved templates folder
        # Commented out notification:
        # Write-Host "The 3CX Restore Template Does Not Exist!"
    }
    
    # Separator for debugging (commented out):
    # Write-Host "============================================"
}

# ============================================================================
# SCRIPT END
# ============================================================================
# Script completes after processing all templates