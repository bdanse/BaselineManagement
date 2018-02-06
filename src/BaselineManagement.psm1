﻿$Helpers = "$PsScriptRoot\Helpers\"
$Parsers = "$PsScriptRoot\Parsers\"

Get-ChildItem -Path $Helpers -Recurse -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Get-ChildItem -Path $Parsers -Recurse -Filter '*.ps1' | ForEach-Object { . $_.FullName }
<#
.Synopsis
   This is a universal ConvertTo-DSC function that converts GPO, SCMxml or SCMjson to DSC Configuration script.
.DESCRIPTION
   We utilize the type of object passed in to determine which function to call.  Directories are associated with GPO backups, Objects are associated with GPO objects or JSON objects and XML with XML.
.EXAMPLE
   dir .\<GPO Backup GUID> | ConvertTo-DSC
.EXAMPLE
   dir .\scm.xml | ConvertTo-DSC
.EXAMPLE
   dir .\scm.json | ConvertTo-DSC
.EXAMPLE
   Backup-GPO <GPO Name> | ConvertTo-DSC
.INPUd
   Any supported baseline to be converted into DSC.
.OUTPUTS
   Output will come from calling cmdlet ConvertFrom-GPO, ConvertFrom-SCM, and ConvertFrom-ASC.
.NOTES
   General notes
.COMPONENT
   The component this cmdlet belongs to
.ROLE
   The role this cmdlet belongs to
.FUNCTIONALITY
   The functionality that best describes this cmdlet
#>
function ConvertTo-DSC
{
    [CmdletBinding()]
    param
    (
        # This is the Path to either a SCM/JSON file or a GPO Backup directory.
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName="Path")]
        [ValidateScript({Test-Path $_})]
        [Alias("BackupDirectory")]
        [string]$Path,

        # This is either a GPO Backup object or a JSON/XML object.
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName="Object")]
        [Psobject]$Object,

        # This is the hard coded stage that you can just force it into the type of input.
        [Parameter()]
        [ValidateSet("ADMX", "GPO", "SCMxml", "ASCjson")]
        [string]$Type,
        
        # Output Path that will default to an Output directory under the current Path.
        [ValidateScript({Test-Path $_})]
        [string]$OutputPath = $(Join-Path $pwd.Path "Output"),

        # ComputerName for Node processing.
        [string]$ComputerName = "localhost",

        # This determines whether or not to output a ConfigurationScript in addition to the localhost.mof
        [switch]$OutputConfigurationScript
    )
        
    Process
    {
        $Parameter = $null
        # Determine the Type of input we are dealing with.
        switch($Type)
        {
            Default
            {
                Write-Verbose "Trying to determine type of input from ParameterSet $($PSCmdlet.ParameterSetName)"
                switch ($PSCmdlet.ParameterSetName)
                {
                    "Path"
                    {
                        $item = Get-Item -Path $Path
                        if ($item -is [System.IO.DirectoryInfo])
                        {
                            Write-Verbose "Assuming GPO since Directory was given for Path"
                            $Type = "GPO"
                        }
                        else
                        {
                            switch ($item.Extension)
                            {
                                ".json" { $Type = "ASCjson" }
                                ".xml" { $Type = "SCMxml" }
                            }
                        }    
                        
                        $parameter = $item
                    }

                    "Object"
                    {
                        switch ($Object)
                        {
                            {$_ -is [XML]} { $Type = "SCMxml" }
                            {$_ -is [Microsoft.GroupPolicy.GpoBackup]} { $Type = "GPO" } 
                            {$_ -is [PSCustomObject]} { Write-Verbose "Assuming JSON if object is a custom Object"; $Type = "SCMjson"}
                        }

                        $Parameter = $object
                    }
                }
            }
        }

        # Call the appropriate conversion function based on input.
        $scriptblock = [scriptblock]::Create('param($param) ConvertFrom-' + $Type + ' @param')
        # Pass our parameters (minus the Type) to our Conversion cmdlet.
        $PSBoundParameters.Remove("Type") | Out-Null
        return Invoke-Command -ScriptBlock $scriptblock -ArgumentList $PSBoundParameters
    }
}

<#
.Synopsis
   This cmdlet converts Backed Up GPOs into DSC Configuration Scripts. 
.DESCRIPTION
   This cmdlet will take the exported GPO and convert all internal settings into DSC Configurations.  
.EXAMPLE
   Backup-GPO <GPO Name> | ConvertFrom-GPO
.EXAMPLE
   dir .\<GPO GUID> | ConvertFrom-GPO
.INPUTS
   The GPO Object or directory.
.OUTPUTS
   This script will output a localhost.mof if successful and a failed Configuration Script file if failed.  It will also, on request, output the Configuration Script PS1 file.
.NOTES
   General notes
.COMPONENT
   The component this cmdlet belongs to
.ROLE
   The role this cmdlet belongs to
.FUNCTIONALITY
   The functionality that best describes this cmdlet
#>
function ConvertFrom-GPO
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        # This is the Path of the GPO Backup Directory.
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName = "Path")]
        [ValidateScript( {Test-Path $_})]
        [string]$Path,
        
        # This is the GPO Object returned from Backup-GPO.
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName = "GPO")]
        [Psobject]$GPO,

        # Output Path that will default to an Output directory under the current Path.
        [ValidateScript( {Test-Path $_})]
        [string]$OutputPath = $(Join-Path $pwd.Path "Output"),

        # ComputerName for Node processing.
        [string]$ComputerName = "localhost",

        # This determines whether or not to output a ConfigurationScript in addition to the localhost.mof
        [switch]$OutputConfigurationScript,

        [switch]$ShowPesterOutput
    )
    
    # If we are passed a GPO object, we can get the path to the files from that object.
    if ($PSCmdlet.ParameterSetName -eq "GPO")
    {
        Write-Verbose "Gathering GPO data from $($GPO.BackupDirectory)"
        $Path = $(Join-Path $GPO.BackupDirectory "{$($GPO.Id)}")
    }

    Write-Verbose "Gathering GPO Data from $Path"
    $polFiles = Get-ChildItem -Path $Path -Filter registry.pol -Recurse

    $AuditCSVs = Get-ChildItem -Path $Path -Filter Audit.csv -Recurse

    $GPTemplateINFs = Get-ChildItem -Path $Path -Filter GptTmpl.inf -Recurse
        
    $PreferencesDirectory = Get-ChildItem -Path $Path -Directory -Filter "Preferences" -Recurse

    # These are the DSC Resources needed for NON-preference based GPOS.
    $NeededModules = 'PSDesiredStateConfiguration', 'AuditPolicyDSC', 'SecurityPolicyDSC'

    if ($PreferencesDirectory -ne $null)
    {
        $PreferencesXMLs = Get-ChildItem -Path $PreferencesDirectory.FullName -Filter *.xml -Recurse

        if ($PreferencesXMLs -ne $null)
        {
            # These are the Preference Based DSC Resources.
            $NeededModules += 'xSMBShare', 'DSCR_PowerPlan', 'xScheduledTask', 'Carbon', 'PrinterManagement', 'rsInternationalSettings'
        }
    }
    
    # Start tracking Processing History.
    Clear-ProcessingHistory
    
    # Create the Configuration String
    $ConfigString = Write-DSCString -Configuration -Name "DSCFromGPO"
    # Add any resources
    $ConfigString += Write-DSCString -ModuleImport -ModuleName $NeededModules
    # Add Node Data
    $configString += Write-DSCString -Node -Name $ComputerName
    
    # Loop through each Pol file.
    foreach ($polFile in $polFiles)
    {
        if ((Get-Command "Read-PolFile" -ErrorAction SilentlyContinue) -ne $null)
        {
            # Reaad each POL file found.
            Write-Verbose "Reading Pol File ($($polFile.FullName))"
            Try
            {
                $registryPolicies = Read-PolFile -Path $polFile.FullName
            }
            Catch
            {
                Write-Error $_
            }
        }
        elseif ((Get-Command "Parse-PolFile" -ErrorAction SilentlyContinue) -ne $null)
        {
            # Reaad each POL file found.
            Write-Verbose "Reading Pol File ($($polFile.FullName))"
            Try
            {
                $registryPolicies = Parse-PolFile -Path $polFile.FullName
            }
            catch
            {
                Write-Error $_ 
            }
        }
        else
        {
            Write-Error "Cannot Parse Pol files! Please download and install GPRegistryPolicyParser from github here: https://github.com/PowerShell/GPRegistryPolicyParser"
            break
        }

        # Loop through every policy in the Pol File.
        Foreach ($Policy in $registryPolicies)
        {
            $Hive = @{User = "HKCU"; Machine = "HKLM"}
            
            # Convert each Policy Registry object into a Resource Block and add it to our Configuration string.
            $ConfigString += Write-GPORegistryPOLData -Data $Policy -Hive $Hive[$polFile.Directory.BaseName]
        }
    }
        
    # Loop through each Audit CSV in the GPO Directory.
    foreach ($AuditCSV in $AuditCSVs)
    {
        $otherSettingsCSV = @()
        foreach ($CSV in (Import-CSV -Path $AuditCSV.FullName))
        {
            switch ($CSV)
            {
                {$_.Subcategory -match "GlobalSacl"}
                {
                    $otherSettingsCSV += $CSV
                    break
                }
                    
                {!([string]::IsNullOrEmpty($_.'Subcategory GUID'))}
                {
                    $ConfigString += Write-GPOAuditCSVData -Entry $CSV
                    break
                }    

                {$_.Subcategory -match "^Option"}
                {
                    $ConfigString += Write-GPOAuditOptionCSVData -Entry $CSV
                    break
                }
                Default 
                {
                    Write-Warning  "ConvertFrom-GPO: $($CSV.SubCategory) is not currently supported"
                }
            }   
        }

        <# Still trying to figure out how to handle Resource SACLS
        if ($othersettingsCSV.count -gt 0)
        {
            $contents = ""
            for ($i = 0; $i -lt $othersettingsCSV.Count; $i++)
            {
                $setting = $othersettingsCSV[$i]
                $contents += "$($setting.'Machine Name'),$($setting.'Policy Target'),$($setting.Subcategory),$($setting.'Subcategory GUID'),$($setting.'Inclusion Setting'),$($setting.'Exclusion Setting'),$($setting.'Setting Value')"
                if (($i + 1) -lt $othersettingsCSV.Count)
                {
                    $contents += ","
                }
                $contents += "`n"
            }
            
            $tempCSVPath = "C:\windows\temp\polaudit.csv"
            $ConfigString += Write-DscString -Resource -Name "OtherAuditSettingsCSV" -Type File -Parameters @{DestinationPath=$tempCSVPath;Force=$true;Contents=$contents} 
            $ConfigString += Write-DscString -Resource -Name "AuditPolicyDSC: Other Audit Settings" -Type AuditPolicyCSV -Parameters @{IsSingleInstance = "Yes"; CsvPath = $tempCSVPath; DependsOn = "[File]OtherAuditSettingsCSV"} 
        } 
        #>
    }

    # Loop through all the GPTemplate files.
    foreach ($GPTemplateINF in $GPTemplateINFs)
    {
        Write-Verbose "Reading GPTmp.inf ($($GPTemplateINF.FullName))" 
        # GPTemp files are in INI format so this function converts it to a hashtable.
        $ini = Get-IniContent $GPTemplateINF.fullname

        # Loop through every heading.
        foreach ($key in $ini.Keys)
        {
            # Loop through every setting in the heading.
            foreach ($subKey in $ini[$key].Keys)
            {
                switch -regex ($key)
                {
                    "Service General Setting"
                    {
                        $ConfigString += Write-GPOServiceINFData -Service $subkey -ServiceData $ini[$key][$subKey]
                    }

                    "Registry Values"
                    {
                        $ConfigString += Write-GPORegistryINFData -Key $subkey -ValueData $ini[$key][$subKey]
                    }

                    "File Security"
                    {
                        $ConfigString += Write-GPOFileSecurityINFData -Path $subkey -ACLData $ini[$key][$subKey]
                    }
                
                    "Privilege Rights"
                    {
                        $ConfigString += Write-GPOPrivilegeINFData -Privilege $subkey -PrivilegeData $ini[$key][$subKey]
                    }
                
                    "Kerberos Policy"
                    {
                        if ($GlobalConflictEngine.ContainsKey("SecurityOption"))
                        {
                            $ConfigString += Write-GPONewSecuritySettingINFData -Key $subKey -SecurityData $ini[$key][$subkey]
                        }
                        else
                        {
                            $ConfigString += Write-GPOSecuritySettingINFData -Key $subKey -SecurityData $ini[$key][$subkey]
                        }
                    }
                
                    "Registry Keys"
                    {
                        $ConfigString += Write-GPORegistryACLINFData -Path $subkey -ACLData $ini[$key][$subKey]
                    }
                
                    "System Access"
                    {
                        if ($GlobalConflictEngine.ContainsKey("SecurityOption"))
                        {
                            $ConfigString += Write-GPONewSecuritySettingINFData -Key $subKey -SecurityData $ini[$key][$subkey]
                        }
                        else
                        {
                            $ConfigString += Write-GPOSecuritySettingINFData -Key $subKey -SecurityData $ini[$key][$subkey]
                        }
                    }

                    "Event Audit"
                    {
                        $ConfigString += Write-GPOAuditINFData -Key $subKey -AuditData $ini[$key][$subkey]
                    }

                    "(Version|signature|Unicode|Group Membership)"
                    {

                    }
                    
                    Default
                    {
                        Write-Warning "ConvertFrom-GPO:GPTemp.inf $key AND $subkey heading not yet supported"
                    }
                }
            }
        }

        # This has to be done separately because it can cause resource conflicts.
        if ($ini.ContainsKey("Group MemberShip"))
        {
            $groupMembership = @{}
            foreach ($KeyPair in $ini["Group Membership"].GetEnumerator())
            {
                $groupName, $Property = $KeyPair.Name -split "__"
                $GroupData = @()
                if (![String]::IsNullOrEmpty($KeyPair.Value))
                {
                    $GroupData = @(($KeyPair.Value -split "," | ForEach-Object { "$_" }) -join ",")
                }

                switch ($Property)
                {
                    "Members"
                    {
                        if ($groupMembership.ContainsKey($groupName))
                        {
                            $groupMembership[$groupName].Members += $GroupData
                        }
                        else
                        {
                            $groupMembership[$groupName] = @{}
                            $groupMembership[$groupName].GroupName = $groupName
                            $groupMembership[$groupName].Members = $GroupData
                        }
                    }

                    "MemberOf"
                    {
                        if ($GroupData.Count -gt 0)
                        {
                            foreach ($Group in $GroupData)
                            {
                                if ($groupMembership.ContainsKey($Group))
                                {
                                    $groupMembership[$group].MembersToInclude += $GroupData
                                }
                                else
                                {
                                    $groupMembership[$group] = @{}
                                    $groupMembership[$group].GroupName = $Group
                                    $groupMembership[$group].MembersToInclude = $GroupData
                                }       
                            }
                        }
                    }   

                    Default
                    {
                        Write-Warning "Group Membership: $Property is not a valid Property"
                        continue
                    }
                }
            }

            foreach ($Key in $GroupMembership.Keys)
            {
                $CommentOut = $false
                $configString += Write-DSCString -Resource -Name $Key -Parameters $GroupMemberShip[$key] -Type Group -CommentOut:$CommentOut
            }
        } 
    }

    # There is also SOMETIMES a RegistryXML file that contains some additional registry information.
    foreach ($XML in $PreferencesXMLs)
    {
        Write-Verbose "Reading $($XML.BaseName)XML ($($XML.FullName))"
        
        # Grab the XML info.
        [xml]$XMLContent = Get-Content $XML.FullName
        
        switch ($XML.BaseName)
        {
            "Files"
            {
                $Settings = (Select-Xml -XPath "//$_/File" -xml $XMLContent).Node

                # Loop through every registry setting.
                foreach ($Setting in $Settings)
                {
                    $ConfigString += Write-GPOFilesXMLData -XML $Setting
                }
            }

            "Folders"
            {
                $Settings = (Select-Xml -XPath "//$_/Folder" -xml $XMLContent).Node

                # Loop through every registry setting.
                foreach ($Setting in $Settings)
                {
                    $ConfigString += Write-GPOFoldersXMLData -XML $Setting
                }
            }

            "EnvironmentVariables"
            {
                $Settings = (Select-Xml -XPath "//$_/EnvironmentVariable" -xml $XMLContent).Node

                # Loop through every registry setting.
                foreach ($Setting in $Settings)
                {
                    $ConfigString += Write-GPOEnvironmentVariablesXMLData -XML $Setting
                }
            }

            "Groups"
            {
                $Settings = (Select-Xml -XPath "//Group" -xml $XMLContent).Node

                # Loop through every registry setting.
                foreach ($Setting in $Settings)
                {
                    $ConfigString += Write-GPOGroupsXMLData -XML $Setting
                }
            }
            
            "IniFiles"
            {
                $Settings = (Select-Xml -XPath "//$_" -Xml $XMLContent).Node
                foreach ($setting in $settings)
                {
                    $ConfigString += Write-GPOIniFileXMLData -XML $Setting
                }
            }
            
            "InternetSettings"
            {
                $Settings = (Select-Xml -XPath "//Reg" -xml $XMLContent).Node

                # Loop through every registry setting.
                foreach ($Setting in $Settings)
                {
                    $ConfigString += Write-GPOInternetSettingsXMLData -XML $Setting
                }
            }

            "NetworkOptions"
            {
                <#$Settings = (Select-Xml -XPath "//$_" -xml $XMLContent).Node

                # Loop through every registry setting.
                foreach ($Setting in $Settings)
                {
                    $ConfigString += Write-GPONetworkOptionsXMLData -XML $Setting
                }#>
                Write-Warning "ConvertFrom-GPO:$($XML.BaseName) XML file is not implemented yet."
            }

            "NetworkShareSettings"
            {
                $Settings = (Select-Xml -XPath "//$_/NetShare" -xml $XMLContent).Node

                # Loop through every registry setting.
                foreach ($Setting in $Settings)
                {
                    $ConfigString += Write-GPONetworkSharesXMLData -XML $Setting
                }
            }

            "PowerOptions"
            {
                $GlobalPowerOptions = (Select-Xml -XPath "//$_/GlobalPowerOptions" -xml $XMLContent).Node
                $PowerPlans = (Select-Xml -XPath "//$_/GlobalPowerOptionsV2" -xml $XMLContent).Node                    
                $PowerSchemes = (Select-Xml -XPath "//$_/PowerScheme" -xml $XMLContent).Node                    
                
                foreach ($PowerOption in $GlobalPowerOptions)
                {
                    $ConfigString += Write-GPOGlobalPowerOptionsXMLData -XML $PowerOption
                }

                foreach ($PowerPlan in $PowerPlans)
                {
                    $ConfigString += Write-GPOPowerPlanXMLData -XML $PowerPlan
                }

                foreach ($PowerScheme in $PowerSchemes)
                {
                    $ConfigString += Write-GPOPowerSchemeXMLData -XML $PowerScheme
                }

                Write-Warning "ConvertFrom-GPO:$($XML.BaseName) XML file is not implemented yet."
            }

            "Printers"
            {
                $Settings = (Select-Xml -XPath "//Printers" -xml $XMLContent).Node

                foreach ($Setting in $Settings)
                {
                    $ConfigString += Write-GPOPrintersXMLData -XML $Setting
                }
            }

            "RegionalOptions"
            {
                $Settings = (Select-Xml -XPath "//Regional" -xml $XMLContent).Node

                # Loop through every registry setting.
                foreach ($Setting in $Settings)
                {
                    $ConfigString += Write-GPORegionalOptionsXMLData -XML $Setting
                }
            }
            
            "Registry"
            {
                $Settings = (Select-Xml -XPath "//$_" -xml $XMLContent).Node

                # Loop through every registry setting.
                foreach ($Setting in $Settings)
                {
                    $ConfigString += Write-GPORegistryXMLData -XML $Setting
                }
            }

            "Services"
            {
                $Settings = (Select-Xml -XPath "//NTService" -xml $XMLContent).Node

                # Loop through every registry setting.
                foreach ($Setting in $Settings)
                {
                    $ConfigString += Write-GPONTServicesXMLData -XML $Setting
                }
            }

            "Shortcuts"
            {
                <#$Settings = (Select-Xml -XPath "//$_" -xml $XMLContent).Node

                # Loop through every registry setting.
                foreach ($Setting in $Settings)
                {
                    $ConfigString += Write-GPOShortcutsXMLData -XML $Setting
                }#>
                Write-Warning "ConvertFrom-GPO:$($XML.BaseName) XML file is not implemented yet."
            }

            "StartMenu"
            {
                <#$Settings = (Select-Xml -XPath "//$_" -xml $XMLContent).Node

                # Loop through every registry setting.
                foreach ($Setting in $Settings)
                {
                    $ConfigString += Write-GPOStartMenuXMLData -XML $Setting
                }#>
                Write-Warning "ConvertFrom-GPO:$($XML.BaseName) XML file is not implemented yet."
            }

            "ScheduledTasks"
            {
                $Settings = (Select-Xml -XPath "//ScheduledTasks/*" -xml $XMLContent).Node

                # Loop through every registry setting.
                foreach ($Setting in $Settings)
                {
                    $ConfigString += Write-GPOScheduledTasksXMLData -XML $Setting
                }
            }

            Default
            {
                Write-Warning "ConvertFrom-GPO:$($XML.BaseName) XML file is not implemented yet."
            }
        }
    }

    # Close out the Node Block and the configuration.
    $ConfigString += Write-DSCString -CloseNodeBlock 
    $ConfigString += Write-DSCString -CloseConfigurationBlock
    $ConfigString += Write-DSCString -InvokeConfiguration -Name DSCFromGPO -OutputPath $OutputPath
        
    # If the switch was specified, output a Configuration PS1 regardless of success or failure.
    if ($OutputConfigurationScript)
    {
        if (!(Test-Path $OutputPath))
        {
            mkdir $OutputPath
        }
                
        $Scriptpath = Join-Path $OutputPath "DSCFromGPO.ps1"
        Write-Verbose "Outputting Configuration SCript to $Scriptpath"
        $ConfigString | Out-File -FilePath $Scriptpath -Force -Encoding Utf8
    }

    # Create the MOF File if possible.
    $pass = Complete-Configuration -ConfigString $ConfigString -OutputPath $OutputPath
    
    if ($ShowPesterOutput)
    {
        # Write out a Summary of our parsing activities.
        Write-ProcessingHistory -Pass $Pass
    }

    if ($pass)
    {
        if ($OutputConfigurationScript)
        {
            Get-Item $Scriptpath
        }

        Get-Item $(Join-Path -Path $OutputPath -ChildPath "$ComputerName.mof") -ErrorAction SilentlyContinue
    }
    else
    {
        Get-Item $(Join-Path -Path $OutputPath -ChildPath "DSCFromGPO.ps1.error")
    }
}

<#
.Synopsis
   This cmdlet converts SCM baselines into DSC Configurations.
.DESCRIPTION
   This cmdlet will look at all of the settings in an SCM XML file and convert them into DSC resources inside of a configuration.
.EXAMPLE
   dir .\SCM.XML | ConvertFROM-SCM -OutputConfigurationScript
.EXAMPLE
   ConvertFrom-SCM -Path .\SCM.XML -OutputConfigurationScript.
.EXAMPLE
   [Xml]$xml = Get-Content .\SCM.XML
   ConvertFrom-SCM -XML $xml
.INPUTS
   Either the XML content of a SCM baseline or the file itself.
.OUTPUTS
   Success or failure will yield a localhost.mof or a failed configuration file as well as an optional ConfigurationScript ps1 file.
.NOTES
   General notes
.COMPONENT
   The component this cmdlet belongs to
.ROLE
   The role this cmdlet belongs to
.FUNCTIONALITY
   The functionality that best describes this cmdlet
#>
Function ConvertFrom-SCM
{
    [CmdletBinding()]
    param
    (
        # This is the XML object itself.
        [Parameter(Mandatory=$true, ParameterSetName="XML", ValueFromPipeLine=$true)]
        [XML]$XML,
        
        # This is the Path to the XML file.
        [Parameter(Mandatory=$true, ParameterSetName="Path", ValueFromPipeLine=$true)]
        [ValidateScript({Test-Path $_})]
        [String]$Path,

        # Output Path that will default to an Output directory under the current Path.
        [Parameter()]
        [String]$OutputPath = $(Join-Path $pwd.Path "output"),

        # ComputerName for Node processing.
        [string]$ComputerName = "localhost",

        # This determines whether or not to output a ConfigurationScript in addition to the localhost.mof
        [switch]$OutputConfigurationScript,

        [switch]$ShowPesterOutput
    )

    # If they passed in a path we have to grab the XML object from it.
    if ($PSCmdlet.ParameterSetName -eq "Path")
    {
        [XML]$XML = Get-Content $Path
    }

    # Grab the comments from the SCM Baline XML.
    $BaselineComment = $xml.SCMPackage.Baseline.Description.Trim()

    # Start tracking Processing History.
    Clear-ProcessingHistory
    
    # Create the Configuration String
    $ConfigString = Write-DSCString -Configuration -Name DSCFromSCM -Comment $BaselineComment
    # Add any resources
    $ConfigString += Write-DSCString -ModuleImport -ModuleName PSDesiredStateConfiguration, AuditPolicyDSC, SecurityPolicyDSC
    # Add Node Data
    $ConfigString += Write-DSCString -Node -Name $ComputerName
    
    # We need to setup a namespace to properly search the XML.
    $namespace = @{e="http://schemas.microsoft.com/SolutionAccelerator/SecurityCompliance"}
    
    # Grab all the DiscoveryInfo objects in the XML. They determine how to find the setting in question.
    $results = (Select-XML -XPath "//e:SettingDiscoveryInfo" -Xml $xml -Namespace $namespace).Node

    # If we found some DiscoveryInfo objects.
    if ($results -ne $null -and $results.Count -gt 0)
    {
        foreach ($node in $results)
        {
            $Setting = "../.."
            $SettingDiscoveryInfo = ".."
            
            # Set up some variables for easy manipulation of values.
            
            # This is how to find it (.Wmidiscoveryinfo -> class, name etc.) It's only one level back in GeneratedScript
            $settingDiscoveryInfo = $node.SelectNodes($SettingDiscoveryInfo)
                
            # Grab the ID/Name from the Setting value.
            $ID = $node.SelectNodes($Setting).id.Trim("{").TrimEnd("}")
            
            # Find the ValueData using the ID.
            $valueNodeData = (Select-XML -XPath "//e:SettingRef[@setting_ref='{$($id)}']" -Xml $xml -Namespace $namespace).Node
                        
            if ($valueNodeData -eq $null)
            {
                Write-Error "Could not find ValueNodeData of $id" 
                continue
            }
            
            # Determine the DiscoveryInfo Type.                       
            switch ($node.DiscoveryType)
            {
                "Registry" 
                {
                    $ConfigString += Write-SCMRegistryXMLData -DiscoveryData $node -ValueData $valueNodeData
                }
                
                "Script"
                {
                    $ConfigString += Write-SCMScriptXMLData -DiscoveryData $node -ValueData $valueNodeData
                }
                
                "WMI"
                {
                    if ($GlobalConflictEngine.ContainsKey("SecurityOption"))
                    {
                        $ConfigString += Write-SCMNewSecuritySettingXMLData -DiscoveryData $node -ValueData $valueNodeData
                    }
                    else
                    {
                        $ConfigString += Write-SCMSecuritySettingXMLData -DiscoveryData $node -ValueData $valueNodeData
                    }
                }

                "AdvancedAuditPolicy"
                {
                    $ConfigString += Write-SCMAuditXMLData -DiscoveryData $node -ValueData $valueNodeData
                }
                
                "GeneratedScript (User Rights Assignment)"
                {
                    $ConfigString += Write-SCMPrivilegeXMLData -DiscoveryData $node -ValueData $valueNodeData
                }
            }
        }
    }

    # Close out our configuration string.
    $ConfigString += Write-DSCString -CloseNodeBlock
    $ConfigString += Write-DSCString -CloseConfigurationBlock
    $ConfigString += Write-DSCString -InvokeConfiguration -Name DSCFromSCM -OutputPath $OutputPath
    
    # If the switch was specified.  Output a Configuration PS1 regardless of success/failure.
    if ($OutputConfigurationScript)
    {
        if (!(Test-Path $OutputPath))
        {
            mkdir $OutputPath
        }

        $Scriptpath = Join-Path $OutputPath "DSCFromSCM.ps1"
        $ConfigString | Out-File -FilePath $Scriptpath -Force -Encoding Utf8
    }

    # Try to compile the MOF file.
    $pass = Complete-Configuration -ConfigString $ConfigString -OutputPath $OutputPath
    
    # Write Summary Data on processing activities.
    Write-ProcessingHistory -Pass $Pass

    if ($pass)
    {
        if ($OutputConfigurationScript)
        {
            Get-Item $Scriptpath
        }

        Get-Item $(Join-Path -Path $OutputPath -ChildPath "$ComputerName.mof")
    }
    else
    {
        Get-Item $(Join-Path -Path $OutputPath -ChildPath "$($MyInvocation.MyCommand.Name).ps1.error")
    }
}

<#
.Synopsis
   This cmdlet converts from ASC JSON into DSC.
.DESCRIPTION
   This cmdlet will look at all baselines entries within an SCM JSON file and convert them to DSC.
.EXAMPLE
   ConvertFrom-ASC -Path .\ASC.Json
.EXAMPLE
   dir .\scm.json | ConvertFrom-ASC -OutputConfigurationScript
.INPUTS
   The ASC JSON File.
.OUTPUTS
   Success or Failure will yield detailed results along with a localhost.mof if successful or error file if unsuccessful.  It also yields a ConfigurationScript on request.
.NOTES
   General notes
.COMPONENT
   The component this cmdlet belongs to
.ROLE
   The role this cmdlet belongs to
.FUNCTIONALITY
   The functionality that best describes this cmdlet
#>
function ConvertFrom-ASC
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        # This is the Path to the JSON file.
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName = "Path")]
        [ValidateScript( {Test-Path $_})]
        [string]$Path,
        
        # Output Path that will default to an Output directory under the current Path.        
        [ValidateScript( {Test-Path $_})]
        [string]$OutputPath = $(Join-Path $pwd.Path "Output"),

        # ComputerName for Node processing.
        [string]$ComputerName = "localhost",

        # This determines whether or not to output a ConfigurationScript in addition to the localhost.mof
        [switch]$OutputConfigurationScript,

        [switch]$ShowPesterOutput
    )

    DynamicParam
    {
        if (Test-Path $Path)
        {
            $JSON = Get-Content -Path $Path | ConvertFrom-Json
            $JSONBaselines = @()
            $JSONBaselines = $JSON.baselinerulesets.baselineName
            $JSONBaselines = $null
                                    
            $attributes = new-object System.Management.Automation.ParameterAttribute
            $attributes.ParameterSetName = "__AllParameterSets"
            $attributes.Mandatory = $false

            $attributeCollection = new-object -Type System.Collections.ObjectModel.Collection[System.Attribute]
            $attributeCollection.Add($attributes)
            
            if ($JSONBaselines -eq $null)
            {
                return
            }

            $ValidateSet = new-object System.Management.Automation.ValidateSetAttribute($JSONBaselines)

            $attributeCollection.Add($ValidateSet)

            $dynParam1 = new-object -Type System.Management.Automation.RuntimeDefinedParameter("BaselineName", [string], $attributeCollection)

            $paramDictionary = new-object -Type System.Management.Automation.RuntimeDefinedParameterDictionary
            $paramDictionary.Add("BaselineName", $dynParam1)

            return $paramDictionary 
        }
    }
    
    Begin
    {
        $BaselineName = Read-BaselineName -Pattern '"baselineName": "(.*)"' -BaselineName $BaselineName -Path $Path

        if ($BaselineName -eq $null)
        {
            Throw "$BaselineName is not valid"
        }
    }

    Process 
    {
        # JSON can be tricky to parse, so we have to put it in a Try Block in case it's not properly formatted.   
        Try
        {
            $JSON = Get-Content -Path $Path | ConvertFrom-Json
        }
        Catch
        {
            Write-Error $_
            Write-Warning "Unable to parse JSON at path $Path - Exiting"
            continue
            return
        }
  
        $BaselineName = $PSBoundParameters.BaselineName  
        $RULES = $JSON.baselineRulesets.Where( {$_.BaselineName -eq $BaselineName}).RULES

        # Start tracking Processing History.
        Clear-ProcessingHistory
    
        # Create the Configuration String
        $ConfigString = Write-DSCString -Configuration -Name DSCFromASC
        # Add any resources
        $ConfigString += Write-DSCString -ModuleImport -ModuleName PSDesiredStateConfiguration, AuditPolicyDSC, SecurityPolicyDSC
        # Add Node Data
        $ConfigString += Write-DSCString -Node -Name $computername
    
        # JSON is pretty straightforward where it keeps the individual settings.
        # These are the registry settings.
        $registryPolicies = $RULES.BaselineRegistryRules

        # Loop through all the registry settings.
        Foreach ($Policy in $registryPolicies)
        {
            $ConfigString += Write-ASCRegistryJSONData -RegistryData $Policy
        }

        # Grab the Audit policies.
        $AuditPolicies = $RULES.BaselineAuditPolicyRule
    
        # Loop through the Audit Policies.
        foreach ($Policy in $AuditPolicies)
        {
            $ConfigString += Write-ASCAuditJSONData -AuditData $Policy
        }

        # Grab all the Security Policy Settings.
        $securityPolicies = $RULES.BaselineSecurityPolicyRule
    
        # Loop through the Security Policies.
        foreach ($Policy in $securityPolicies)
        {
            # Security Policies can have a variety of types as they are represenations of the GPTemp.inf.
            # Determine which one the current setting is and apply.
            switch ($Policy.SectionName)
            {
                "Service General Setting"
                {

                }

                "Registry Values"
                {

                }

                "File Security"
                {

                }
                
                "Privilege Rights"
                {            
                    $ConfigString += Write-ASCPrivilegeJSONData -PrivilegeData $Policy
                }
                
                "Kerberos Policy"
                {
                
                }
                
                "Registry Keys"
                {

                }
                
                "System Access"
                {
                    $ConfigString += Write-ASCSystemAccessJSONData -SystemAccessData $Policy
                }
            }
        }
    
        # Close out the Configuration block.
        $ConfigString += Write-DSCString -CloseNodeBlock
        $ConfigString += Write-DSCString -CloseConfigurationBlock
        $ConfigString += Write-DSCString -InvokeConfiguration -Name DSCFromASC -OutputPath $OutputPath
    
        # If the switch was specified, output a Configuration Script regardless of success/failure.
        if ($OutputConfigurationScript)
        {
            if (!(Test-Path $OutputPath))
            {
                mkdir $OutputPath
            }
        
            $Scriptpath = Join-Path $OutputPath "DSCFromASC.ps1"
            $ConfigString | Out-File -FilePath $Scriptpath -Force -Encoding Utf8
        }

        # Try to compile configuration.
        $pass = Complete-Configuration -ConfigString $ConfigString -OutputPath $OutputPath
    
        if ($ShowPesterOutput)
        {
            # Write out Summary data of parsing history.
            Write-ProcessingHistory -Pass $Pass
        }

        if ($pass)
        {
            if ($OutputConfigurationScript)
            {
                Get-Item $Scriptpath
            }

            Get-Item $(Join-Path -Path $OutputPath -ChildPath "$ComputerName.mof")
        }
        else
        {
            Get-Item $(Join-Path -Path $OutputPath -ChildPath "DSCFromASC.ps1.error")
        }
    }
}

<#
.Synopsis
   This cmdlet converts from ASC JSON into DSC.
.DESCRIPTION
   This cmdlet will look at all baselines entries within an SCM JSON file and convert them to DSC.
.EXAMPLE
   ConvertFrom-ASC -Path .\ASC.Json
.EXAMPLE
   dir .\scm.json | ConvertFrom-ASC -OutputConfigurationScript
.INPUTS
   The ASC JSON File.
.OUTPUTS
   Success or Failure will yield detailed results along with a localhost.mof if successful or error file if unsuccessful.  It also yields a ConfigurationScript on request.
.NOTES
   General notes
.COMPONENT
   The component this cmdlet belongs to
.ROLE
   The role this cmdlet belongs to
.FUNCTIONALITY
   The functionality that best describes this cmdlet
#>
function ConvertFrom-ASC
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        # This is the Path to the JSON file.
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName = "Path")]
        [ValidateScript( {Test-Path $_})]
        [string]$Path,
        
        # Output Path that will default to an Output directory under the current Path.        
        [ValidateScript( {Test-Path $_})]
        [string]$OutputPath = $(Join-Path $pwd.Path "Output"),

        # ComputerName for Node processing.
        [string]$ComputerName = "localhost",

        # This determines whether or not to output a ConfigurationScript in addition to the localhost.mof
        [switch]$OutputConfigurationScript, 

        [switch]$ShowPesterOutput
    )

    DynamicParam
    {
        if (Test-Path $Path)
        {
            $JSON = Get-Content -Path $Path | ConvertFrom-Json
            $JSONBaselines = @()
            $JSONBaselines = $JSON.baselinerulesets.baselineName
            #$JSONBaselines = $null
                                    
            $attributes = new-object System.Management.Automation.ParameterAttribute
            $attributes.ParameterSetName = "__AllParameterSets"
            $attributes.Mandatory = $false

            $attributeCollection = new-object -Type System.Collections.ObjectModel.Collection[System.Attribute]
            $attributeCollection.Add($attributes)
            
            if ($JSONBaselines -eq $null)
            {
                return
            }

            $ValidateSet = new-object System.Management.Automation.ValidateSetAttribute($JSONBaselines)

            $attributeCollection.Add($ValidateSet)

            $dynParam1 = new-object -Type System.Management.Automation.RuntimeDefinedParameter("BaselineName", [string], $attributeCollection)

            $paramDictionary = new-object -Type System.Management.Automation.RuntimeDefinedParameterDictionary
            $paramDictionary.Add("BaselineName", $dynParam1)

            return $paramDictionary 
        }
    }
    
    Begin
    {
        if(-not ($PSBoundParameters.BaselineName))
        {
            $BaselineName = Read-ASCBaselineName -Pattern '"baselineName": "(.*)"' -BaselineName $BaselineName -Path $Path
        }
        else
        {
            $BaselineName = $PSBoundParameters.BaselineName
        }
        

        if ($BaselineName -eq $null)
        {
            Throw "Select a Valid Baseline!"
        }
    }

    Process 
    {
        # JSON can be tricky to parse, so we have to put it in a Try Block in case it's not properly formatted.   
        Try
        {
            $JSON = Get-Content -Path $Path | ConvertFrom-Json
        }
        Catch
        {
            Write-Error $_
            Write-Warning "Unable to parse JSON at path $Path - Exiting"
            continue
            return
        }
  
        #$BaselineName = $PSBoundParameters.BaselineName  
        $RULES = $JSON.baselineRulesets.Where( {$_.BaselineName -eq $BaselineName}).RULES

        # Start tracking Processing History.
        Clear-ProcessingHistory
    
        # Create the Configuration String
        $ConfigString = Write-DSCString -Configuration -Name DSCFromASC
        # Add any resources
        $ConfigString += Write-DSCString -ModuleImport -ModuleName PSDesiredStateConfiguration, AuditPolicyDSC, SecurityPolicyDSC
        # Add Node Data
        $ConfigString += Write-DSCString -Node -Name $computername
    
        # JSON is pretty straightforward where it keeps the individual settings.
        # These are the registry settings.
        $registryPolicies = $RULES.BaselineRegistryRules

        # Loop through all the registry settings.
        Foreach ($Policy in $registryPolicies)
        {
            $ConfigString += Write-ASCRegistryJSONData -RegistryData $Policy
        }

        # Grab the Audit policies.
        $AuditPolicies = $RULES.BaselineAuditPolicyRules
    
        # Loop through the Audit Policies.
        foreach ($Policy in $AuditPolicies)
        {
            $ConfigString += Write-ASCAuditJSONData -AuditData $Policy
        }

        # Grab all the Security Policy Settings.
        $securityPolicies = $RULES.BaselineSecurityPolicyRules
    
        # Loop through the Security Policies.
        foreach ($Policy in $securityPolicies)
        {
            # Security Policies can have a variety of types as they are represenations of the GPTemp.inf.
            # Determine which one the current setting is and apply.
            switch ($Policy.SectionName)
            {
                "Service General Setting"
                {

                }

                "Registry Values"
                {
                    
                }

                "File Security"
                {

                }
                
                "Privilege Rights"
                {            

                    $ConfigString += Write-ASCPrivilegeJSONData -PrivilegeData $Policy
                }
                
                "Kerberos Policy"
                {
                
                }
                
                "Registry Keys"
                {

                    $ConfigString += Write-ASCPrivilegeJSONData -PrivilegeData $Policy
                }
                
                "System Access"
                {

                    $ConfigString += Write-ASCSystemAccessJSONData -SystemAccessData $Policy
                }
            }
        }
    
        # Close out the Configuration block.
        $ConfigString += Write-DSCString -CloseNodeBlock
        $ConfigString += Write-DSCString -CloseConfigurationBlock
        $ConfigString += Write-DSCString -InvokeConfiguration -Name DSCFromASC -OutputPath $OutputPath
    
        # If the switch was specified, output a Configuration Script regardless of success/failure.
        if ($OutputConfigurationScript)
        {
            if (!(Test-Path $OutputPath))
            {
                mkdir $OutputPath
            }
        
            $Scriptpath = Join-Path $OutputPath "DSCFromASC.ps1"
            $ConfigString | Out-File -FilePath $Scriptpath -Force -Encoding Utf8
        }

        # Try to compile configuration.
        $pass = Complete-Configuration -ConfigString $ConfigString -OutputPath $OutputPath
    
        if ($ShowPesterOutput)
        {
            # Write out Summary data of parsing history.
            Write-ProcessingHistory -Pass $Pass
        }

        if ($pass)
        {
            if ($OutputConfigurationScript)
            {
                Get-Item $Scriptpath
            }

            Get-Item $(Join-Path -Path $OutputPath -ChildPath "$ComputerName.mof")
        }
        else
        {
            Get-Item $(Join-Path -Path $OutputPath -ChildPath "DSCFromASC.ps1.error")
        }
    }
}

Function Read-ASCBaselineName
{
    [CmdletBinding()]
    param
    (

        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter()]
        [string]$BaselineName
    )

    if (!(Test-Path $Path))
    {
        Throw "$Path is not Valid!"
    }

    if (![string]::IsNullOrEmpty($BaselineName))
    {
        # Perform double validation on BaselineName just in case they typed something in and Dynamic Parameter Validation Failed.
        $Values = (Get-Item $Path | Select-String -Pattern $Pattern).Matches.Groups.Where({$_.Name -eq 1}).Value
        if ($Values -eq $null)
        {
            Throw "Could not get Baselines From ($($Path)) based on Pattern ($Pattern)"
        }
                
        if ($BaselineName -notin $Values)
        {
            Throw "$($BaselineName) is NOT a valid BaselineName"
            return $null
        }
        else
        {
            return $BaselineName
        }
    }
    else
    {
        $tmpValues = (Get-Item $Path | Select-String -Pattern $Pattern).Matches.Groups.Where({$_.Name -eq 1}).Value
                
        $i = 1 
        $message = "Select a baseline you want to convert: `n`n"

        $choices = $tmpValues | %{
            $message += "{0} {1}`n" -f $i, $_
            $i++

        } 
        $message += "`n"
        $message += "Enter baseline index number"
        $answer = Read-Host $message 

        $BaselineName = $tmpValues[$answer - 1]
        if($BaselineName)
        {
            return $BaselineName
        }
    }
}

Function Read-CSVBaselineName
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter()]
        [string]$OS,

        [Parameter()]
        [string]$ServerType
    )

    if (!(Test-Path $Path))
    {
        Throw "$Path is not Valid!"
    }
    
    Try { $CSV = Import-CSV -Path $Path } Catch { Throw $_ } 
    
    if ($Host.Name -match "ISE")
    {
        $MenuPath = Join-Path $PSScriptRoot "Menus\menu_input.txt"
        Remove-Item -Force -Path $MenuPath -ErrorAction SilentlyContinue

        if ([string]::IsNullOrEmpty($OS) -and !([string]::IsNullOrEmpty($ServerType)))
        {
            # Prompt for OS
            foreach ($o in (($CSV.Where({$_.ServerType -match "$ServerType"})) | group).Name)
            {
                "=$o" | Add-Content $MenuPath
            }        
        }
        elseif (!([string]::IsNullOrEmpty($OS)) -and ([string]::IsNullOrEmpty($ServerType)))
        {
            # Prompt for ServerType
            foreach ($S in (($CSV.Where({$_.Filter -match "$OS"})) | group).Name)
            {
                "=$s" | Add-Content $MenuPath
            }
        }
        else
        {
            # Prompt for Both
            $ServerTypes = ($CSV.'Server Type'.ForEach({$_ -replace "(\[|\])", ""}) -split ", " | Group).Name
            foreach ($type in $ServerTypes) 
            { 
                $type | Add-Content $MenuPath
                $Entries = $CSV.Where({$_.'Server Type' -match $type})
                $Filters = $Entries.Filter.Where({![string]::IsNullOrEmpty($_)})
                $Names = ($Filters.ForEach({($_.Replace("OSVersion = [", "").Replace("]", "") -split ",\s+")}) | group).Name
                $Names.ForEach({"=$_"}) | Add-Content $MenuPath
            }
        }

        $argPath = Join-path $PSScriptRoot "Menus\ISEMenu.ps1"
        $arguments = "-NoProfile -File " + $argPath
        $menuoutputpath = $(Join-Path $PSScriptRoot "Menus\menu_output.txt")
        Remove-Item -ErrorAction SilentlyContinue $menuoutputpath
        Start-Process  -Wait -FilePath powershell.exe -ArgumentList $arguments 
        if (Test-Path $menuoutputpath)
        {
            $result = (Get-Content $menuoutputpath)
        }
        else
        {
            Throw "Please Select a valid Baseline!"
            return $null
        }
    }
    else
    {
        # Prompt for Both
        $OSHash = [ordered]@{}
        $ServerTypes = ($CSV.'Server Type'.ForEach({$_ -replace "(\[|\])", ""}) -split ", " | Group).Name
        foreach ($type in $ServerTypes) 
        { 
            $OSHash[$Type] = [ordered]@{};
            $OSHash[$Type].Title = $Type
            $Entries = $CSV.Where({$_.'Server Type' -match $type})
            $Filters = $Entries.Filter.Where({![string]::IsNullOrEmpty($_)})
            $Names = ($Filters.ForEach({($_.Replace("OSVersion = [", "").Replace("]", "") -split ",\s+")}) | group).Name
            $Names.ForEach({
                            $OSHash[$type][$_] = @{};
                            $OSHash[$type][$_].Title = $_
                            $OSHash[$type][$_].Key = "$type|$_"
                          })
        }

        # Display our menu.
        $result = Show-Menu -sMenuTitle "Select a Valid Baseline" -hMenuEntries ([Ref]$OSHash)
    }

    if (![string]::IsNullOrEmpty($result))
    {
        if ($result -match "|")
        {
            $ServerType, $OS = $result -split "\|"
        }
        else
        {
            if ([string]::IsNullOrEmpty($OS)) 
            {
                $ServerType = $result
            }
            else
            {
                $OS = $result
            }
        }

        return @{OS=$OS;ServerType=$ServerType}
    }
    else
    {
        Throw "Please select a valid Baseline!"
        return $null
    }
}

<#
.Synopsis
   This cmdlet converts from ASC JSON into DSC.
.DESCRIPTION
   This cmdlet will look at all baselines entries within an Excel CSV (Need a correct nomenclature).
.EXAMPLE
   ConvertFrom-Excel -Path .\Source.csv
.EXAMPLE
   dir .\Source.csv | ConvertFrom-Excel -OutputConfigurationScript
.INPUTS
   The Excel CSV File.
.OUTPUTS
   Success or Failure will yield detailed results along with a localhost.mof if successful or error file if unsuccessful.  It also yields a ConfigurationScript on request.
.NOTES
   General notes
.COMPONENT
   The component this cmdlet belongs to
.ROLE
   The role this cmdlet belongs to
.FUNCTIONALITY
   The functionality that best describes this cmdlet
#>
function ConvertFrom-Excel
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        # This is the Path to the JSON file.
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateScript( {Test-Path $_})]
        [string]$Path,
        
        # Output Path that will default to an Output directory under the current Path.        
        [ValidateScript( {Test-Path $_})]
        [string]$OutputPath = $(Join-Path $pwd.Path "Output"),

        # ComputerName for Node processing.
        [string]$ComputerName = "localhost",

        # This determines whether or not to output a ConfigurationScript in addition to the localhost.mof
        [switch]$OutputConfigurationScript, 

        [switch]$ShowPesterOutput,

        [ValidateSet('WS2008', 'WS2008R2', 'WS2012', 'WS2012R2', 'WS2016')]
        [string]$OS,

        [ValidateSet('Domain Controller', 'Domain Member', 'Workgroup Member', 'Exclude', 'Inventory Setting')]
        [string]$ServerType
    )
    
    Begin
    {
        if (([string]::IsNullOrEmpty($OS)) -or ([string]::IsNullOrEmpty($ServerType)))
        {
            # One of the OS and ServerType was not specified, prompting will be necessary.
            $Baseline = Read-CSVBaselineName -OS $OS -ServerType $ServerType -Path $Path

            if ($Baseline -ne $null)
            {
                $OS = $Baseline.OS
                $ServerType = $Baseline.ServerType
            }
            else
            {
                Throw "Select a valid Baseline!"
            }
        }
    }

    Process 
    {
        # CSV can be tricky to parse, so we have to put it in a Try Block in case it's not properly formatted.   
        Try
        {
            $CSV = Import-CSV -Path $Path 
        }
        Catch
        {
            Write-Error $_
            Write-Warning "Unable to parse CSV at path $Path - Exiting"
            continue
            return
        }
  
        $Rules = $CSV.Where({$_.Filter -match $OS -and $_.'Server Type' -match $ServerType})
        
        # Start tracking Processing History.
        Clear-ProcessingHistory
    
        # Create the Configuration String
        $ConfigString = Write-DSCString -Configuration -Name DSCFromCSV
        # Add any resources
        $ConfigString += Write-DSCString -ModuleImport -ModuleName PSDesiredStateConfiguration, AuditPolicyDSC, SecurityPolicyDSC
        # Add Node Data
        $ConfigString += Write-DSCString -Node -Name $computername
    
        # Find all of our required settings.
        $registryPolicies = $RULES.Where({$_.DataSourceType -eq "Registry"})
        $securityPolicies = $RULES.Where({$_.DataSourceType -eq "Policy"})
        $auditPolicies = $RULES.Where({$_.DataSourceType -eq "Audit"})

        # Loop through all the registry settings.
        Foreach ($Policy in $registryPolicies)
        {
            $ConfigString += Write-RegistryCSVData -RegistryData $Policy
        }

        # Loop through the Audit Policies.
        foreach ($Policy in $AuditPolicies)
        {
            $ConfigString += Write-AuditCSVData -AuditData $Policy
        }

        # Loop through the Security Policies.
        foreach ($Policy in $securityPolicies)
        {
            # Security Policies can have a variety of types as they are represenations of the GPTemp.inf.
            # Determine which one the current setting is and apply.
            switch -regex ($Policy.DataSourceKey)
            {
                "Service General Setting"
                {

                }

                "Registry Values"
                {

                }

                "File Security"
                {

                }
                
                "Privilege Rights"
                {            
                    $ConfigString += Write-PrivilegeCSVData -PrivilegeData $Policy
                }
                
                "Kerberos Policy"
                {
                
                }
                
                "Registry Keys"
                {

                }
                
                "System Access"
                {

                }
            }
        }
    
        # Close out the Configuration block.
        $ConfigString += Write-DSCString -CloseNodeBlock
        $ConfigString += Write-DSCString -CloseConfigurationBlock
        $ConfigString += Write-DSCString -InvokeConfiguration -Name DSCFromCSV -OutputPath $OutputPath
    
        # If the switch was specified, output a Configuration Script regardless of success/failure.
        if ($OutputConfigurationScript)
        {
            if (!(Test-Path $OutputPath))
            {
                mkdir $OutputPath
            }
        
            $Scriptpath = Join-Path $OutputPath "DSCFromCSV.ps1"
            $ConfigString | Out-File -FilePath $Scriptpath -Force -Encoding Utf8
        }

        # Try to compile configuration.
        $pass = Complete-Configuration -ConfigString $ConfigString -OutputPath $OutputPath
    
        if ($ShowPesterOutput)
        {
            # Write out Summary data of parsing history.
            Write-ProcessingHistory -Pass $Pass
        }

        if ($pass)
        {
            if ($OutputConfigurationScript)
            {
                Get-Item $Scriptpath
            }

            Get-Item $(Join-Path -Path $OutputPath -ChildPath "$ComputerName.mof")
        }
        else
        {
            Get-Item $(Join-Path -Path $OutputPath -ChildPath "DSCFromCSV.ps1.error")
        }
    }
}

Export-ModuleMember -Function ConvertFrom-SCM, ConvertFrom-ASC, ConvertFrom-GPO, ConvertTo-DSC, ConvertFrom-Excel