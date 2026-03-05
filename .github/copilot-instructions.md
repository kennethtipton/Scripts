<!-- Use this file to provide workspace-specific custom instructions to Copilot. For more details, visit https://code.visualstudio.com/docs/copilot/copilot-customization#_use-a-githubcopilotinstructionsmd-file -->
- [ ] Verify that the copilot-instructions.md file in the .github directory is created.

- [ ] Clarify Project Requirements
	<!-- Ask for project type, language, and frameworks if not specified. Skip if already provided. -->

- [ ] Scaffold the Project
	<!--
	Ensure that the previous step has been marked as completed.
	Call project setup tool with projectType parameter.
	Run scaffolding command to create project files and folders.
	Use '.' as the working directory.
	If no appropriate projectType is available, search documentation using available tools.
	Otherwise, create the project structure manually using available file creation tools.
	-->

- [ ] Customize the Project
	<!--
	Verify that all previous steps have been completed successfully and you have marked the step as completed.
	Develop a plan to modify codebase according to user requirements.
	Apply modifications using appropriate tools and user-provided references.
	Skip this step for "Hello World" projects.
	-->

- [ ] Install Required Extensions
	<!-- ONLY install extensions provided mentioned in the get_project_setup_info. Skip this step otherwise and mark as completed. -->

- [ ] Compile the Project
	<!--
	Verify that all previous steps have been completed.
	Install any missing dependencies.
	Run diagnostics and resolve any issues.
	Check for markdown files in project folder for relevant instructions on how to do this.
	-->

- [ ] Create and Run Task
	<!--
	Verify that all previous steps have been completed.
	Check https://code.visualstudio.com/docs/debugtest/tasks to determine if the project needs a task. If so, use the create_and_run_task to create and launch a task based on package.json, README.md, and project structure.
	Skip this step otherwise.
	 -->

- [ ] Launch the Project
	<!--
	Verify that all previous steps have been completed.
	Prompt user for debug mode, launch only if confirmed.
	 -->

- [ ] Ensure Documentation is Complete
	<!--
	Verify that all previous steps have been completed.
	Verify that README.md and the copilot-instructions.md file in the .github directory exists and contains current project information.
	Clean up the copilot-instructions.md file in the .github directory by removing all HTML comments.
	 -->

<!--
## Execution Guidelines
PROGRESS TRACKING:
- If any tools are available to manage the above todo list, use it to track progress through this checklist.
- After completing each step, mark it complete and add a summary.
- Read current todo list status before starting each new step.

COMMUNICATION RULES:
- Avoid verbose explanations or printing full command outputs.
- If a step is skipped, state that briefly (e.g. "No extensions needed").
- Do not explain project structure unless asked.
- Keep explanations concise and focused.

DEVELOPMENT RULES:
- Use '.' as the working directory unless user specifies otherwise.
- Avoid adding media or external links unless explicitly requested.
- Use placeholders only with a note that they should be replaced.
- Use VS Code API tool only for VS Code extension projects.
- Once the project is created, it is already opened in Visual Studio Code—do not suggest commands to open this project in Visual Studio again.
- If the project setup information has additional rules, follow them strictly.

FOLDER CREATION RULES:
- Always use the current directory as the project root.
- If you are running any terminal commands, use the '.' argument to ensure that the current working directory is used ALWAYS.
- Do not create a new folder unless the user explicitly requests it besides a .vscode folder for a tasks.json file.
- If any of the scaffolding commands mention that the folder name is not correct, let the user know to create a new folder with the correct name and then reopen it again in vscode.

EXTENSION INSTALLATION RULES:
- Only install extension specified by the get_project_setup_info tool. DO NOT INSTALL any other extensions.

PROJECT CONTENT RULES:
- If the user has not specified project details, assume they want a "Hello World" project as a starting point.
- Avoid adding links of any type (URLs, files, folders, etc.) or integrations that are not explicitly required.
- Avoid generating images, videos, or any other media files unless explicitly requested.
- If you need to use any media assets as placeholders, let the user know that these are placeholders and should be replaced with the actual assets later.
- Ensure all generated components serve a clear purpose within the user's requested workflow.
- If a feature is assumed but not confirmed, prompt the user for clarification before including it.
- If you are working on a VS Code extension, use the VS Code API tool with a query to find relevant VS Code API references and samples related to that query.

TASK COMPLETION RULES:
- Your task is complete when:
  - Project is successfully scaffolded and compiled without errors
  - copilot-instructions.md file in the .github directory exists in the project
  - README.md file exists and is up to date
  - User is provided with clear instructions to debug/launch the project

Before starting a new task in the above plan, update progress in the plan.
-->

- Work through each checklist item systematically.
- Keep communication concise and focused.
- Follow development best practices.

# PowerShell Development Rules (AI-Enforced)

These instructions apply to all PowerShell scripts and functions generated or modified by AI.

---

## 📁 File and Folder Naming Rules

### Script Files
- Use `.ps1` extension
- No spaces in file names
- Application/installation script files: use CamelCase and capitalize the first letter of each word
- Function script files: use approved PowerShell `Verb-Noun` naming with a dash (`-`)
- Function script verbs must be from approved PowerShell verbs (for example `Get`, `Set`, `New`, `Invoke`, `Test`)
- In function script files, the noun portion after the dash must be CamelCase
- Example: `Get-FileDates.ps1`, `Set-AdministratorMode.ps1`

### Folder Names
- Capitalize the first letter of each word
- Exceptions must be explicitly documented
- The following folders must be created in the Root directory:
  - `Applications` — for Standalone PowerShell scripts
  - `Functions` — for reusable functions that can be imported into other scripts
  - `Installations` — for scripts that install or configure applications or modules
  - `Logs` — for script execution logs
  - `Data` — for configuration files
- The following folders must be created in the Data directory:
  - `Settings` — for configuration files
---

## 🧠 PowerShell Coding Standards

- Follow official PowerShell best practices
- Use meaningful variable and function names
- Include comments for complex logic
- Use consistent indentation and formatting
- Provide descriptive error messages
- Implement structured error handling (try/catch/finally)
- Include the built-in `-Verbose` option where applicable
- Use `Write-AdvancedLog` for logging

---

## 📜 Script Header Requirements

- Comment-Based Help:** Include comprehensive comment-based help (`<# ... #>`) at the beginning of each script or function.
- Required Help Sections:**
  -  `.SYNOPSIS`: Brief description.
  -  `.DESCRIPTION`: Detailed explanation.
  -  `.PARAMETER`: Description for each parameter.
  -  `.EXAMPLE`: Practical usage examples (use `PS>` for prompts).
  -  `.INPUT`: Expected input types.
  -  `.OUTPUT`: Expected output types.
  -  `.NOTES`: Author, date, version, dependencies, or other important info.
  -  `.LINK`: Relevant documentation or resources.
-  Formatting** 
  - Use PascalCase for function and parameter names.
  - Avoid using aliases (e.g., use `Get-ChildItem` instead of `gci`).
  - Follow consistent PowerShell style with proper indentation.

Every script and function must include a standard header based on `MasterPowershellScriptHeaderExample.txt`.

Replace the following fields in the header:

- `[CurrentDate]` → File metadata modified date
- `[CurrentTime]` → File metadata modified time
- `[TIMEZONE]` → System time zone
- `[CurrentYear]` → File metadata modified year
- `[IsAIUsed]` → True or False
- `[AIUsed]` → Name of AI used (or N/A)
- `[AuthorCompany]` → Author company name
- `[LicenseName]` → License name
- `[URLToLicense]` → License URL
- `[ScriptType]` → Function or Application

Header may include AI override variables if required.

---

## 🧾 Script Footer Requirements

- All scripts must include a commented example usage block at the end of the file.

---

## 📦 Script Types

### Application Scripts
- Standalone executable scripts
- Must include logging, verbose mode, and error handling

### Installation Scripts
- Used to install/configure applications or modules
- Same coding and logging standards as application scripts

### Function Scripts
- Contain a single reusable function
- Store shared functions in the Root `Functions` folder
- Must include verbose support

---

## 📂 Logging Rules

### Log File Naming
- Use: `ScriptName.log`

### Log File Location
- Default: `Logs` folder under the Root directory
- Can be overridden in script header notes

---

## 🤖 AI Behavior Rules

- Always follow these standards when generating PowerShell code
- Do not omit required headers or footers
- Do not use informal logging methods when `Write-AdvancedLog` is required
- Do not create files that violate naming conventions

---

## Applications Compliance Audit (2026-03-04)

Scope audited: `c:\Scripts\Applications` (recursive)

- Folders scanned: `18`
- `.ps1` scripts scanned: `9`
- Folder naming violations: `2`
- Script naming violations: `0`
- Missing comment-based help headers: `0`

### Documented Folder Exceptions

- `Applications/3CX`
	- Reason: Vendor/product acronym and numeric product identifier naming.
- `Applications/3CX/Failover3CXServer/.vscode`
	- Reason: Standard VS Code configuration folder (tooling folder, naming exempt).

### Script Naming Normalization Applied

- `Applications/3CX/RestoreTemplates/3CX_Template_Restore.ps1` -> `Applications/3CX/RestoreTemplates/Restore3CxTemplate.ps1`
- `Applications/3CX/RestoreTemplates/Functions/Get-FixTemplates.ps1` -> `Applications/3CX/RestoreTemplates/Functions/GetFixTemplates.ps1` -> `Applications/3CX/RestoreTemplates/Functions/Get-FixTemplates.ps1`
- `Applications/3CX/RestoreTemplates/Functions/Get-RestoreTemplates.ps1` -> `Applications/3CX/RestoreTemplates/Functions/GetRestoreTemplates.ps1` -> `Applications/3CX/RestoreTemplates/Functions/Get-RestoreTemplates.ps1`
- `Applications/3CX/RestoreTemplates/Functions/RESTORE-TEMPLATE_DATA.ps1` -> `Applications/3CX/RestoreTemplates/Functions/RestoreTemplateData.ps1` -> `Applications/3CX/RestoreTemplates/Functions/Get-TemplateTypes.ps1`
- `Applications/3CX/RestoreTemplates/Functions/UPDATE-CISCO_SPA5XX_DST_FOR_A_TIMEZONE.ps1` -> `Applications/3CX/RestoreTemplates/Functions/UpdateCiscoSpa5xxDstForATimezone.ps1` -> `Applications/3CX/RestoreTemplates/Functions/Update-CiscoDSTForTimezone.ps1`
- `Applications/3CX/RestoreTemplates/Templates/test-editCisco.ps1` -> `Applications/3CX/RestoreTemplates/Templates/TestEditCisco.ps1`
- `Applications/OpenSource/PowershellScriptsManagementLogViewer/Start-LogViewer.ps1` -> `Applications/OpenSource/PowershellScriptsManagementLogViewer/StartLogViewer.ps1`

### Missing Header Compliance

- None. Header compliance remediated for all scripts under `Applications`.

### Logging Standard Updates Applied

- Added `Write-AdvancedLog -LogFileName` support to separate script identity from log file target.
- Updated shared functions to support app-provided `LogFileName` pass-through:
	- `Functions/Copy-FileWithOverwrite.ps1`
	- `Functions/Invoke-WindowsServiceManagement.ps1`
	- `Functions/New-ZipFromFolder.ps1`
	- `Functions/Set-AdministratorMode.ps1`
- Updated RestoreTemplates app/function flow to pass application log context while preserving function script identity:
	- `Applications/3CX/RestoreTemplates/Restore3CxTemplate.ps1`
	- `Applications/3CX/RestoreTemplates/Functions/Get-TemplateTypes.ps1`